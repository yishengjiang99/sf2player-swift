// usage (from a gbk checkout): node --import tsx/esm <this file> <scenario.json> <out.f32>
// Renders a sf2-parity-render scenario through gbk's JS Sf2SynthEngine with gbk's *default* engine settings
// (unlike gbk src/sf2/parity.ts, sendCcModulators follows the scenario field, default true). Imports from the
// current working directory (the gbk checkout), so this file can live in sf2player-swift.
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
const gbk = (p: string) => pathToFileURL(resolve(process.cwd(), p)).href;
const { SF2SoundFont, STRICT, LENIENT } = await import(gbk("src/sf2/soundfont.ts"));
const { Sf2SynthEngine, sortEvents } = await import(gbk("src/sf2-renderer.ts"));
const [scenPath, outPath] = process.argv.slice(2);
const s = JSON.parse(readFileSync(scenPath, "utf8"));
const sf = new SF2SoundFont(new Uint8Array(readFileSync(s.font)), s.strict ? STRICT : LENIENT);
const sr = s.sampleRate ?? 44100, frames = s.frames ?? 44100;
const engine = new Sf2SynthEngine(sr, { maxVoices: s.maxVoices ?? 64 });
engine.effectsEnabled = s.effects ?? false;
if ("sendCcModulators" in engine) engine.sendCcModulators = s.sendCcModulators ?? true;
if (s.masterGainDb !== undefined) engine.masterGainDb = s.masterGainDb;
if (s.masterDynamics !== undefined) engine.masterDynamicsEnabled = s.masterDynamics;
if (s.trackPan !== undefined) engine.trackPan = s.trackPan;
if (s.trackFader !== undefined) engine.trackFader = s.trackFader;
if (s.programs) engine.loadPrograms(sf);
engine.setTrackStates((s.tracks ?? []).map((t: any) => ({
  trackIndex: t.trackIndex ?? 0, regions: t.preset !== undefined ? sf.regionList(t.preset) : undefined, pan: t.pan, gain: t.gain,
  cc7Volume: t.cc7Volume, cc10Pan: t.cc10Pan, cc11Expression: t.cc11Expression,
})));
for (const o of s.overrides ?? []) engine.setVoiceOverrides(o.trackIndex ?? -1, o.list ?? null);
const events = (s.events ?? []).map((e: any, i: number) => ({ ...e, frame: e.frame ?? 0, seq: e.seq ?? i, regions: e.preset !== undefined ? sf.regionList(e.preset) : undefined }));
const left = new Float32Array(frames), right = new Float32Array(frames);
let cursor = 0;
for (const e of sortEvents(events)) {
  const f = Math.max(0, Math.min(frames, e.frame ?? 0));
  if (f > cursor) { engine.renderRange(left.subarray(cursor, f), right.subarray(cursor, f)); cursor = f; }
  engine.dispatchEvent(e);
}
if (cursor < frames) engine.renderRange(left.subarray(cursor), right.subarray(cursor));
const out = new Float32Array(frames * 2);
for (let i = 0; i < frames; i++) { out[2 * i] = left[i]; out[2 * i + 1] = right[i]; }
writeFileSync(outPath, new Uint8Array(out.buffer));
