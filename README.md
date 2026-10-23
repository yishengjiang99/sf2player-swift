# SF2Engine (sf2player-swift)

Shared SoundFont 2 rendering engine for **AI Camera - Music Reader**
([omr-sheet-cam](https://github.com/yishengjiang99/omr-sheet-cam)) and **AI Music Radar**
([earsheet](https://github.com/yishengjiang99/earsheet)). Swift port of
[yishengjiang99/gbk](https://github.com/yishengjiang99/gbk) @ `b43f004` (`sf2-parser.ts`,
`src/sf2-renderer.ts`). AGPL-3.0-or-later.

Scope: the engine only, meaning SF2 parsing, regions, samples, voices, envelopes, LFOs, the filter,
modulators and the offline renderer for engine events. MIDI file reading, sequencing (SMF to engine
events), the real-time player, playlists and UI stay in each app (`Packages/SF2Player` there
depends on this package and re-exports it).

## Use

Both apps pin an exact revision:

```swift
.package(url: "https://github.com/yishengjiang99/sf2player-swift.git", revision: "<sha>"),
// target dependency:
.product(name: "SF2Engine", package: "sf2player-swift"),
```

```swift
import SF2Engine
let sf = try SF2SoundFont(contentsOf: url)
let engine = Sf2SynthEngine(outSr: 44100, maxVoices: 64)
engine.setTrackStates([SF2TrackState(trackIndex: 0, regions: try sf.regionList(forPreset: 0))])
engine.dispatchEvent(.noteOn(60, velocity: 100, trackIndex: 0))
engine.renderRange(&left, &right)
```

## Fidelity modes

- `.gbk` (default): bit-for-bit port of gbk's renderer. Unchanged by the compliance work.
- `.spec`: SoundFont **2.01** (`docs/SF2_COMPLIANCE.md` maps every spec requirement to a test).
  Files with `ifil >= 2.04` additionally get the 2.04 behaviour, decided in one place (`SF2SpecVersion`).

```swift
let sf = try SF2SoundFont(data: data, options: .strict)   // .lenient (default) repairs and records `warnings`
engine.fidelity = .spec
engine.loadPrograms(from: sf)                              // program change / bank select per channel
engine.dispatchEvent(.programChange(40, channel: 1))
engine.dispatchEvent(.channelPressure(90, channel: 1))
engine.dispatchEvent(.polyPressure(64, value: 90, channel: 1))
```

Strict loading throws `SF2Error.structural(_)` for any chapter 4-7 violation (chunk order or size,
record sizes, index monotonicity, sample bounds, version). Lenient loading applies the repairs the
spec allows and lists them in `sf.warnings`.

Effects: each `.spec` voice feeds reverb and chorus send buses (`reverbEffectsSend` /
`chorusEffectsSend`, CC91 / CC93 via the default modulators). `renderRange` mixes in a built-in
reverb and chorus (`engine.effectsEnabled = false` turns them off); the aux overload
`renderRange(l, r, reverbL:, reverbR:, chorusL:, chorusR:, count)` returns the dry mix plus the raw
send buses for a host's own effects. Both are real-time safe.

Real-time API (no allocation, locks or ARC): `EngineEvent`, `TrackRT`, `dispatch(_:)`,
`renderScheduled(...)` (pointer form), `setStoreRT`, `setTrackRT`, `resetTracksRT`,
`releaseAllRT`, `releaseTracksRT`, `setMaxVoicesRT`, `clearVoices`.

## SoundFont

`soundfont.lock` pins GeneralUser GS 2.0.2 (same URL and SHA-256 as both apps' `models.lock`).
`scripts/fetch-soundfont` downloads it into `models/` (gitignored). Tests that need it skip
without it, or use `SF2PLAYER_SF2=/path/to.sf2`.

## Tests

`swift test` on Linux or macOS. Compliance rows are tested with synthetic fonts (`SF2Builder`)
and measured on rendered audio (`Analysis`); `ComplianceMatrixTests` fails if any row is pending.
`scripts/diff-fluidsynth` (needs `fluidsynth`) writes `diff-report.md`, a comparison of the `.spec`
path with FluidSynth (run informationally in CI). Bit-exact gbk parity tests (c_scale, ode-to-joy) live in
omr-sheet-cam `Packages/SF2Player` with the sequencing code they drive.
