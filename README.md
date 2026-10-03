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

Real-time API (no allocation, locks or ARC): `EngineEvent`, `TrackRT`, `dispatch(_:)`,
`renderScheduled(...)` (pointer form), `setStoreRT`, `setTrackRT`, `resetTracksRT`,
`releaseAllRT`, `releaseTracksRT`, `setMaxVoicesRT`, `clearVoices`.

## SoundFont

`soundfont.lock` pins GeneralUser GS 2.0.2 (same URL and SHA-256 as both apps' `models.lock`).
`scripts/fetch-soundfont` downloads it into `models/` (gitignored). Tests that need it skip
without it, or use `SF2PLAYER_SF2=/path/to.sf2`.

## Tests

`swift test` on Linux or macOS. Bit-exact gbk parity tests (c_scale, ode-to-joy) live in
omr-sheet-cam `Packages/SF2Player` with the sequencing code they drive.
