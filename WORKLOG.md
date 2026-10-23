# WORKLOG — branch sf2-201-compliance

Resume notes for the SoundFont 2.01 compliance work (see docs/SF2_COMPLIANCE.md for the matrix).

## Baseline (step 0) — 2026-10-22, Linux, Swift 6.4, GeneralUser GS 2.0.2 fetched
`swift test`: **45 tests executed, 0 failures, 0 skipped** (XCTest); swift-testing: 0 tests.
Saved as /workspace/sf2-baseline.txt (box only; may be lost).

## Log
- Chunk 1: SF2LoadOptions (.strict/.lenient), SF2SpecVersion, SF2StructuralError, validator
  (P-01..P-13, E-01). GeneralUser GS 2.0.2 loads strict with zero warnings (no STOP).
  Note: P-group code was written before its tests in this chunk (tests added right after,
  all exercised by mutation fixtures); later items follow red→green.
  SF2Builder moved to Tests/SF2EngineTests/SF2Builder.swift and extended (pmod/imod per zone,
  ifil/isng/irom/iver, extra chunks, order overrides, odd smpl, tableEdit/mutate hooks, waveforms).
  Matrix test: `pending` rows make testComplianceMatrixIsCovered *skip* until
  `matrixMustBeComplete` is flipped to true.

## Decisions
- Lenient keeps legacy `info` decoding (UTF-8 then Latin-1) so `.gbk` callers see no change;
  strict uses the §5 rules (Latin-1, terminated, even, length caps). Strict maps every
  unknown `isng` (incl. GeneralUser's "E-mu 10K2") to "EMU8000" per §5.2.
- Lenient still throws `missingTable`/`missingSampleData` like before; strict allows absent smpl (§6).
- New `SF2Error.structural` case is additive but breaks exhaustive `switch`es downstream.
- Chunk 2: Z-01..Z-12 (specObject/specMergedZones, GenInfo table, clamp), S-01/05/06/07.
- Chunk 3: M-01..M-10. Version-aware defaults (`SF2Modulator.defaults(for:)`: 10 entries for 2.01,
  previous 8 for >= 2.04), modulator validity filter, virtual pitch dest moved 59 -> 64
  (`slotCount` 65), no-controller = 1, Table 2 mapping (v/128). Removed the illegal
  modulator->sample-offset application (M-06).
  **Spec-path test expectations changed** (SpecFidelityTests: CC7/CC11, velocity, mod wheel,
  offline CC7) from the /127 law to Table 2 (helper `t2Gain`); no `.gbk` expectation touched.
  Errata decided: pitch-wheel sensitivity mapped s/127 (12700 x s/127 = 100 s cents) — Table 2
  v/128 would give 198.4 cents at 2 semitones; bipolar max is 63/64 (b = 2u-1), Table 2 prints 127/128;
  §8.4.1/8.4.2 prose "velocity 1 -> 127/128" vs (127-v)/128 = 126/128 — followed the formula.
- Chunk 4: Analysis.swift + SpecRender; G-01/G-09/G-10 (linear pan law in .spec only), S-02/03/04/08/11,
  MIDI-01; fuzz P-99 (found a trap: non-finite read position from pathological tuning -> now reads
  silence/finishes; values that were finite before are untouched, so .gbk output unchanged).
  ASan run of the fuzz test: no memory errors; LeakSanitizer reports 873 bytes in XCTest's own
  test-registration closures (run with ASAN_OPTIONS=detect_leaks=0 to silence).
- Chunk 5: G-03/G-04 spec envelopes (VolEnv/ModEnv `spec` flag; gbk curves untouched), fastRelease/kill.
- Chunk 6: MIDI-02..08, N-01..06, M-11, G-02, G-12 (engine channel functions, NRPN, new events
  programChange / channelPressure / polyPressure, `loadPrograms(from:)`).
- Chunk 7: G-05..G-08, G-13, S-09, S-10. Filter Q per 8.1.2 #9 (DC -Q/2, peak +Q/2) with bypass at
  Fc >= min(20 kHz, 0.45 sr) and Q <= 0; LFOs always run in .spec; timecent sums clamped to 8.1.3
  (so -32768 tc in synthetic test regions now means 1 ms: two SpecFidelityTests sample indices moved,
  expected values unchanged; testFilterQFromRegion expects the new q formula). Stereo pairs: one
  voice per zone, left zone takes the right zone's pitch.
- Chunk 8: G-11 (sends, aux-bus renderRange, built-in reverb/chorus, `effectsEnabled`); every matrix
  row now pass or n/a and `matrixMustBeComplete = true`; `scripts/diff-fluidsynth` + `sf2-spec-render`
  dev executable + optional CI job (continue-on-error); docs/diff-report.md from CI run 39891233946;
  README + doc comments updated (2.01, fidelity modes, strict loading, effects, new events).

## sf2-201-gbk-sync (2026-10-22)
- `.gbk` is now an alias of `.spec` (`SF2Fidelity.gbk == .spec`). The gbk JS engine is a 2.01 port of this engine, at gbk branch sf2-201-compliance (pin: see docs/SF2_COMPLIANCE.md, "gbk pin").
  - Tests that asserted gbk-legacy behaviour were updated to the 2.01 values, with the reason in each message:
    - S-01: no normalization.
    - Parser: sustainModEnv is an attenuation (0.75), and filter Fc is clamped to 1500 rather than opened.
    - The coarse offset is clamped and the zone kept (3 regions).
    - Stereo is one voice per zone, so there is no dataR.
    - Track pan is linear and CC10 comes from events.
    - Default-engine controllers apply. Offline `.gbk` output equals `.spec` output.
    - G-11: every engine is spec.
- Master bus (non-normative) is in SF2MasterBus.swift, mirroring gbk src/sf2/master-bus.ts:
  - Stages: gain -3 dB, then compressor -6 dBFS 4:1 knee 6 dB 5/100 ms, then lookahead limiter (-0.3 dBFS, 50 ms, 1.5 ms), then safety clip.
  - API: `masterGainDb`, `masterDynamicsEnabled`, `masterParams`, `masterLatencyFrames`.
  - Applied in renderRange and renderScheduled, for every fidelity. The aux-bus renderRange is pre-master.
  - Compliance SpecRender and the SpecFidelity helper turn it off and set gain to 0 dB. SF2OfflineRenderer gained `masterDynamicsEnabled` and `masterGainDb` parameters.
  - The sf2-spec-render WAV writer clamps to +/-1 before int16.
- swift test: 138 tests, 0 failures, 4 skipped.
- CI fix: GU parse expected values (testGeneralUserGSMatchesGbkParse, skipped locally before) now match gbk 2.01 values (81 regions, attack -12000, 1_113_969 points, violin 145); G11 temp-engine use-after-free fixed (failed on macOS).

## 2026-10-22 (pre-merge fixes, mirrors gbk 305615f)
- `.spec` track CC7/CC10/CC11 now reach the audio: engine-wide `.setControllers` writes all 16 channels' controller
  state; track values (non-default `SF2TrackState` / `setTrackRT`, or any track `.setControllers` CC) are written into
  each channel the track plays on (first noteOn per channel, then live), through the 2.01 default modulators.
  Power-on defaults never clobber in-stream CCs, so SF2Player plans (100/64/127) render unchanged.
- sf2-parity-render reads track cc7Volume/cc10Pan/cc11Expression and setControllers events.
- TrackControllersTests (5). gbk pin -> 305615f. 143 tests, 0 failures locally; GU parity 22 scenarios worst 1.4e-14.
