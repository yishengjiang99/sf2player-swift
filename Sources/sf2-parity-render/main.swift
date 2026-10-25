// SPDX-License-Identifier: AGPL-3.0-or-later
// usage: sf2-parity-render <scenario.json> <out.f32>
// Cross-engine parity tool: renders a scenario through Sf2SynthEngine `.spec` and writes interleaved
// little-endian Float32 L/R frames. gbk's scripts/parity-render.ts reads the same scenario format.
// Scenario: { font, sampleRate, frames, effects, sendCcModulators (default false), trackPan, trackFader, masterGainDb, masterDynamics, strict, programs, maxVoices,
//   tracks: [{trackIndex, preset, gain, pan, cc7Volume, cc10Pan, cc11Expression}], events: [{frame, type, channel, trackIndex,
//   note, velocity, controller, value, program, preset, cc7Volume, cc10Pan, cc11Expression (setControllers)}] }   (preset = preset index -> setPreset with that region list)
import Foundation
import SF2Engine

let a = CommandLine.arguments
guard a.count >= 3 else { FileHandle.standardError.write("usage: sf2-parity-render scenario.json out.f32\n".data(using: .utf8)!); exit(2) }
let scen = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[1]))) as! [String: Any]
func int(_ d: [String: Any], _ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
func dbl(_ d: [String: Any], _ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
let fontPath = scen["font"] as! String
let sr = dbl(scen, "sampleRate") ?? 44100
let frames = int(scen, "frames") ?? 44100
let strict = (scen["strict"] as? Bool) ?? false
let sf = try SF2SoundFont(data: Data(contentsOf: URL(fileURLWithPath: fontPath)), options: strict ? .strict : .lenient)
let engine = Sf2SynthEngine(outSr: sr, maxVoices: int(scen, "maxVoices") ?? 64)
engine.fidelity = .spec
engine.effectsEnabled = (scen["effects"] as? Bool) ?? false
// gbk's parity renderer turns its CC91/93 send fallback off; scripts/compare-gbk passes true (gbk's engine default).
engine.sendCcModulators = (scen["sendCcModulators"] as? Bool) ?? false
if let g = scen["masterGainDb"] as? Double { engine.masterGainDb = g }
if let d = scen["masterDynamics"] as? Bool { engine.masterDynamicsEnabled = d }
if let p = dbl(scen, "trackPan") { engine.trackPan = p }
if let f = dbl(scen, "trackFader") { engine.trackFader = f }
if (scen["programs"] as? Bool) ?? false { try engine.loadPrograms(from: sf) }
var tracks: [SF2TrackState] = []
for t in (scen["tracks"] as? [[String: Any]]) ?? [] {
    tracks.append(SF2TrackState(trackIndex: int(t, "trackIndex") ?? 0,
                                regions: try int(t, "preset").map { try sf.regionList(forPreset: $0, fidelity: .spec) },
                                cc7Volume: dbl(t, "cc7Volume"), cc10Pan: dbl(t, "cc10Pan"), cc11Expression: dbl(t, "cc11Expression"),
                                pan: dbl(t, "pan"), gain: dbl(t, "gain")))
}
engine.setTrackStates(tracks)
var events: [SF2SynthEvent] = []
for (i, e) in ((scen["events"] as? [[String: Any]]) ?? []).enumerated() {
    let kind: SF2SynthEvent.Kind
    var note = int(e, "note") ?? 0, vel = int(e, "velocity") ?? 0
    switch e["type"] as! String {
    case "noteOn": kind = .noteOn
    case "noteOff": kind = .noteOff
    case "setPreset": kind = .setPreset
    case "controlChange": kind = .controlChange; note = int(e, "controller") ?? note; vel = int(e, "value") ?? vel
    case "pitchBend": kind = .pitchBend; vel = int(e, "velocity") ?? ((int(e, "value") ?? 0) + 8192)
    case "programChange": kind = .programChange; note = int(e, "program") ?? note
    case "channelPressure": kind = .channelPressure; vel = int(e, "value") ?? vel
    case "polyPressure": kind = .polyPressure; vel = int(e, "value") ?? vel
    case "setControllers":
        var ev = SF2SynthEvent.setControllers(trackIndex: int(e, "trackIndex"), cc7Volume: dbl(e, "cc7Volume"), cc10Pan: dbl(e, "cc10Pan"),
                                              cc11Expression: dbl(e, "cc11Expression"), pan: dbl(e, "pan"), gain: dbl(e, "gain"))
        ev.frame = int(e, "frame") ?? 0; ev.seq = int(e, "seq") ?? i
        events.append(ev); continue
    default: continue
    }
    let regions = try int(e, "preset").map { try sf.regionList(forPreset: $0, fidelity: .spec) }
    events.append(SF2SynthEvent(kind: kind, frame: int(e, "frame") ?? 0, seq: int(e, "seq") ?? i, trackIndex: int(e, "trackIndex"),
                                channel: int(e, "channel"), note: note, velocity: vel, regions: regions))
}
var l = [Float](repeating: 0, count: frames), r = l
l.withUnsafeMutableBufferPointer { lp in
    r.withUnsafeMutableBufferPointer { rp in
        var cursor = 0
        for e in SF2EventOrder.sorted(events) {
            let f = max(0, min(frames, e.frame ?? 0))
            if f > cursor { engine.renderRange(lp.baseAddress! + cursor, rp.baseAddress! + cursor, f - cursor); cursor = f }
            engine.dispatchEvent(e)
        }
        if cursor < frames { engine.renderRange(lp.baseAddress! + cursor, rp.baseAddress! + cursor, frames - cursor) }
    }
}
var out = [Float](repeating: 0, count: frames * 2)
for i in 0 ..< frames { out[2 * i] = l[i]; out[2 * i + 1] = r[i] }
try out.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: a[2]))

// PARITY_DUMP=<presetIndex>: print that preset's .spec regions (debugging cross-engine differences).
if let p = ProcessInfo.processInfo.environment["PARITY_DUMP"].flatMap(Int.init) {
    for r in try sf.regionList(forPreset: p, fidelity: .spec).regions {
        let m = (r.modulators ?? []).map { "\($0.src):\($0.dest):\($0.amount):\($0.amtSrc):\($0.transform)" }.joined(separator: ",")
        print("key \(r.keyRange.0)-\(r.keyRange.1) vel \(r.velRange.0)-\(r.velRange.1) len \(r.sample.dataL.count) rate \(r.sample.sampleRate) loop \(r.sample.loopStart)-\(r.sample.loopEnd) modes \(r.sampleModes) root \(r.overridingRootKey ?? r.originalKey) ct \(r.coarseTune) ft \(r.fineTune) st \(r.scaleTuning) att \(r.initialAttenuationCb) pan \(r.pan) ve \(r.volEnv.delayTc),\(r.volEnv.attackTc),\(r.volEnv.holdTc),\(r.volEnv.decayTc),\(r.volEnv.sustainCb),\(r.volEnv.releaseTc) me \(r.modEnv.delayTc),\(r.modEnv.attackTc),\(r.modEnv.holdTc),\(r.modEnv.decayTc),\(r.modEnv.sustain),\(r.modEnv.releaseTc) fc \(r.initialFilterFcCents) q \(r.initialFilterQCb) meFc \(r.modEnvToFilterFcCents) mlFc \(r.modLfoToFilterFcCents) ml \(r.modLfoDelayTc),\(r.modLfoFreqCents),\(r.modLfoToPitchCents) vl \(r.vibLfoDelayTc),\(r.vibLfoFreqCents),\(r.vibLfoToPitchCents) ex \(r.exclusiveClass) mePitch \(r.modEnvToPitchCents) mlVol \(r.modLfoToVolumeCb) kn \(r.keynumToVolEnvHold),\(r.keynumToVolEnvDecay),\(r.keynumToModEnvHold),\(r.keynumToModEnvDecay) ov \(r.keynumOverride ?? -1),\(r.velocityOverride ?? -1) send \(r.chorusSend),\(r.reverbSend) mods \(m)")
    }
}
