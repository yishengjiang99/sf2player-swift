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
