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
