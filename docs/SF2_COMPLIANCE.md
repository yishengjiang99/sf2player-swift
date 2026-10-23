# SoundFont 2.01 compliance matrix

Reference: SoundFont 2.01 Technical Specification, July 23 1998 (`sfspec21.pdf`). Scope: the
`SF2Fidelity.spec` path with `SF2LoadOptions.strict`. `.gbk` is a bit-exact port of gbk @ b43f004
and is intentionally *not* compliant.

`testComplianceMatrixIsCovered` (Tests/SF2EngineTests/ComplianceMatrixTests.swift) parses this table:
every test named must exist under `Tests/`; status must be `pass`, `n/a (reason)` or `pending`
(work in progress — the test reports pending rows and fails once `matrixMustBeComplete` is set).

| ID | § | requirement | test(s) | status |
|---|---|---|---|---|
| P-01 | §3.1, §10.1 | RIFF ckSize matches file (one pad byte allowed); truncated chunks rejected (strict) | test_P01_riffSizeMustMatchFile | pass |
| P-02 | §3.2, §4.1, §4.2 | Top-level order INFO, sdta, pdta; pdta order phdr pbag pmod pgen inst ibag imod igen shdr | test_P02_chunkOrderIsEnforced | pass |
| P-03 | §3.2, §10.2 | Unknown INFO sub-chunks ignored; unknown chunks elsewhere are structural errors | test_P03_unknownChunksIgnoredInInfoOnly | pass |
| P-04 | §5.1, §10.3 | ifil mandatory, 4 bytes, wMajor 2; higher wMinor accepted; exposed as `version`; GeneralUser GS loads strict | test_P04_ifilMandatoryAndVersioned, test_P04_generalUserGSLoadsStrict, test_P00_builderDefaultIsStrictValid | pass |
| P-05 | §5.2, §5.3, §5.6–5.11 | isng missing/unknown → EMU8000; INAM missing → unavailable; INFO strings zero-terminated, even, ≤256 (ICMT ≤65,536), Latin-1 | test_P05_infoStringRules | pass |
| P-06 | §5.4, §5.5, §7.10 | iver 4 bytes; ROM samples need irom; ROM zones never sound, smpl never read for them | test_P06_romSamplesNeedIromAndNeverSound | pass |
| P-07 | §4.2, §6 | smpl optional; smpl byte count even; sm24 parsed, used only for ifil ≥ 2.04 | test_P07_smplOptionalEvenAndSm24Gated | pass |
| P-08 | §7.2–7.10 | Record-size multiples (38/4/10/4/22/4/10/4/46) | test_P08_recordSizeMultiples | pass |
| P-09 | §7.1 | All nine pdta sub-chunks required | test_P09_allNinePdtaChunksRequired | pass |
| P-10 | §7.2, §7.6, §7.10 | phdr ≥ 2, inst ≥ 2, shdr ≥ 1 records | test_P10_minimumRecordCounts | pass |
| P-11 | §7.2, §7.3, §7.6, §7.7 | Bag/gen/mod indices monotonic; table sizes match terminal records | test_P11_indexConsistency | pass |
| P-12 | §7.5, §7.9 | instrument < inst.count−1 and sampleID < shdr.count−1 at load | test_P12_instrumentAndSampleReferencesInRange | pass |
| P-13 | §7.2, §7.6, §7.10 | Terminal records never played; orphans allowed; duplicate names kept | test_P13_terminalsNeverPlayedOrphansAndDuplicatesKept | pass |
| P-99 | §10.1 | Fuzz: 10,000 mutations load or throw SF2Error; regions + 1,024 rendered frames never trap | test_P99_parserNeverCrashes | pass |
| Z-01 | §7.3, §7.7 | Zone non-global iff last generator is instrument/sampleID; only first zone may be global (object with >1 zone) | test_Z01_globalZoneDetectedByLastGenerator | pass |
| Z-02 | §7.5, §7.9 | Generators after the terminal instrument/sampleID ignored | test_Z02_generatorsAfterTerminalIgnored | pass |
| Z-03 | §7.5, §7.9, §8.1.2 | keyRange only first; velRange only first or after keyRange | test_Z03_rangeGeneratorPositionRules | pass |
| Z-04 | §7.5 | Later duplicate generator in a zone replaces the earlier one | test_Z04_duplicateGeneratorLastWins | pass |
| Z-05 | §7.3, §7.7, §7.2, §7.6 | Non-first zone without terminal ignored; empty global ignored; zone-less objects ignored | test_Z05_incompleteZonesIgnored | pass |
| Z-06 | §10.7 | sampleID in preset zone / instrument in instrument zone ignored | test_Z06_illegalIndexGeneratorsIgnored | pass |
| Z-07 | §8.5 | Instrument-only generators ignored at preset level | test_Z07_instrumentOnlyGeneratorsIgnoredInPresets | pass |
| Z-08 | §8.1.2, §10.3 | Unused/reserved/unknown enumerators ignored at both levels | test_Z08_reservedGeneratorsIgnored | pass |
| Z-09 | §9.4 | Preset key/vel ranges intersect instrument ranges; empty → silent | test_Z09_presetRangesIntersect | pass |
| Z-10 | §8.5, §9.4 | Local replaces global; preset value adds to instrument value or default (§8.5 example) | test_Z10_presetAddsToInstrumentOrDefault | pass |
| Z-11 | §8.1.3, §10.5 | Single GenInfo table; summed values clamped to useful range | test_Z11_genInfoTableAndClamp | pass |
| Z-12 | §7.2 | First duplicate (preset, bank) active; preset > 127 / bank > 128 never playable | test_Z12_presetResolution | pass |
| S-01 | §6.1, §8.1.2 #48 | No normalization in .spec: level = raw/32768 | test_S01_specDoesNotNormalize | pass |
| S-02 | §7.10, §10.1 | Sample points within smpl, end > start; else silent (lenient) / reject (strict) | test_S02_samplePointsOutOfRange | pass |
| S-03 | §8.1.2 #0–4,12,45,50, §10.5 | Signed address offsets; clamp into the sample's own range keeping start < end | test_S03_signedAddressOffsets | pass |
| S-04 | §7.10 | sampleRate 0 → practical value, no division by zero | test_S04_zeroSampleRate | pass |
| S-05 | §7.10 | byOriginalPitch 128–255 → 60 | test_S05_unpitchedOriginalKey | pass |
| S-06 | §8.1.2 #58 | overridingRootKey −1/absent → header key | test_S06_overridingRootKeyMinusOneUsesHeader | pass |
| S-07 | §7.10 | chPitchCorrection signed cents (−4 example) | test_S07_pitchCorrection, test_S07_pitchCorrectionMeasured | pass |
| S-08 | §8.1.2 #54, §9.1.2, §6.2 | sampleModes low 2 bits; mode 3 loops while held then plays to end | test_S08_sampleModesLowBits | pass |
| S-09 | §7.10 | Loop sanity policy: loop iff loopEnd − loopStart ≥ 2 inside the sample; 48/32/8-point recommendations not enforced (“may”) | test_S09_loopSanityPolicy | pass |
| S-10 | §7.10 | Stereo pairs: one voice per zone, own pan, pitch from right zone; invalid link → mono | test_S10_stereoPairsOneVoicePerZone | pass |
| S-11 | §6.1 | Reads past end yield silence | test_S11_readPastEndIsSilent | pass |
| G-01 | §9.1.1, §8.1.2 #51/52/56/58 | Pitch formula, measured f0 ±1 cent | test_G01_measuredPitch | pass |
| G-02 | §8.1.1, §8.1.2 #46/47 | keynum / velocity substitution generators | test_G02_keynumVelocitySubstitution | pass |
| G-03 | §8.1.2 #33–40, §9.1.7 | Volume envelope shape and timing | test_G03_volumeEnvelopeShape, test_G03_releaseFromAttackUsesCurrentLevel | pass |
| G-04 | §8.1.2 #25–32 | Modulation envelope shape and timing (shape asserted on ModEnv directly; audio check via modEnvToPitch at sustain)| test_G04_modulationEnvelopeShape | pass |
| G-05 | §8.1.2 #31/32/39/40 | Key-number envelope scaling (erratum: #32/#40 say hold, mean decay) | test_G05_keynumEnvelopeScaling | pass |
| G-06 | §8.1.2 #21–24, §9.1.6 | Triangle LFOs, phase and frequency | test_G06_lfoTriangleFrequencyAndPhase | pass |
| G-07 | §8.1.2 #7/#11 | modEnvToPitch / modEnvToFilterFc | test_G07_modEnvToPitchAndFc | pass |
| G-08 | §8.1.2 #8/#9, §9.1.3 | Resonant LPF, DC gain −Q/2, bypass above 20 kHz with Q ≤ 0 (±1 dB) | test_G08_filterDcAndPeak | pass |
| G-09 | §8.1.2 #48 | initialAttenuation cB | test_G09_initialAttenuation | pass |
| G-10 | §8.1.2 #17 | Linear pan law (L/(L+R) ±0.0058 ≈ 0.1 dB) | test_G10_linearPanLaw | pass |
| G-11 | §8.1.2 #15/#16, §9.1.5 | Reverb/chorus sends and aux buses | test_G11_effectsSends | pass |
| G-12 | §8.1.2 #57 | exclusiveClass: fast release, same preset + channel | test_G12_exclusiveClassFastReleaseSamePresetChannel | pass |
| G-13 | §8.1.3 | Non-real-time generators fixed at note-on | test_G13_nonRealtimeGeneratorsFixedAtNoteOn | pass |
| M-01 | §8.2, §8.2.4 | Source word layout; type > 3 → ignore modulator | test_M01_sourceLayoutAndUnknownType | pass |
| M-02 | §8.2.1 | Undefined general / illegal CC sources → ignore modulator | test_M02_illegalSourcesIgnored | pass |
| M-03 | §8.2.1 | No-controller source outputs 1 | test_M03_noControllerIsOne | pass |
| M-04 | §8.2.2–8.2.4, §9.5.3 | Source mapping (Table 2: v/128) | test_M04_sourceMappingTable | pass |
| M-05 | §8.3 | Transform 0 only for < 2.04; 2 = abs for ≥ 2.04 | test_M05_transformVersionGated | pass |
| M-06 | §8.1.1 | Destination must be a value generator | test_M06_destinationMustBeValueGenerator | pass |
| M-07 | §8.4.10, §8.1.2 | Virtual pitch destination outside enumerator space; dest 59 ignored | test_M07_dest59Ignored | pass |
| M-08 | §9.5.1 | Output = amount·src·amtSrc | test_M08_modulatorOutput | pass |
| M-09 | §7.4, §7.8, §9.5.1 | Modulator identity and merge rules | test_M09_modulatorMergeRules | pass |
| M-10 | §8.4 | 2.01 default modulator list (10 entries, errata resolved) | test_M10_defaultModulators201 | pass |
| M-11 | §8.2.1 | Channel pressure, poly pressure, key, velocity sources fed | test_M11_liveSources | pass |
| M-12 | §10.5 | Modulated destinations re-clamped | test_M12_modulatedValuesReclamped | pass |
| MIDI-01 | §9.2 | Note-on velocity 0 = note-off | test_MIDI01_velocityZeroIsNoteOff | pass |
| MIDI-02 | §9.2 | CC64 sustain | test_MIDI02_sustainPedal | pass |
| MIDI-03 | §9.2 | CC67 sostenuto | test_MIDI03_sostenuto | pass |
| MIDI-04 | §9.2 | CC66 soft pedal (engine amounts: +60 cB, −600 cents Fc at note-on) | test_MIDI04_softPedal | pass |
| MIDI-05 | §9.2 | CC120 all sound off / CC123 all notes off | test_MIDI05_allSoundOffAllNotesOff | pass |
| MIDI-06 | §9.2 | CC121 reset all controllers | test_MIDI06_resetAllControllers | pass |
| MIDI-07 | §9.2, §7.2 | Bank select + program change | test_MIDI07_programChange | pass |
| MIDI-08 | §9.2, §9.6.3 | Data entry routed to RPN or NRPN | test_MIDI08_dataEntryRouting | pass |
| N-01 | §9.6.1 | NRPN MSB 120 selects SoundFont mode | test_N01_nrpnMode | pass |
| N-02 | §9.6.2 | NRPN LSB generator select + 100/1000/10000 accumulator | test_N02_nrpnSelectAccumulator | pass |
| N-03 | §9.6.2 | Unknown / non-realtime / non-value select ignored | test_N03_nrpnIllegalSelect | pass |
| N-04 | §9.6.3 | Data entry adds to generator on sounding and future voices | test_N04_nrpnDataEntryAdds | pass |
| N-05 | §9.6.3 | Per-generator scale: span halved until ≤ 8192 → 2^k native units per step (interpretation) | test_N05_nrpnRange | pass |
| N-06 | §9.6, §9.2 | CC121 clears NRPN offsets | test_N06_resetClearsNrpn | pass |
| E-01 | §10.1 | Structural errors name the rule and chunk; lenient collects warnings | test_E01_structuralErrorsNameRuleAndChunk | pass |
| E-02 | §10.3 | Unknown enumerators ignored, never fail the load | test_E02_unknownEnumeratorsIgnored | pass |
| E-03 | §10.4, §10.5 | Illegal values → default/ignore; out-of-range → clamp | test_E03_illegalValues | pass |
| E-04 | §10.6 | Missing required terminator → zone ignored; nothing sounds → note-on ignored | test_E04_missingTerminatorIgnoresZone | pass |
| X-01 | §11 | Silicon SoundFonts (ROM header format) | — | n/a (no ROM hardware in this engine) |
| X-02 | §5 (re-write clauses) | Rules for re-writing files | — | n/a (package is read-only; no writer) |
| X-03 | §7.10 | linkedSample circular lists | — | n/a (spec: not currently fully defined; treated as mono, see S-10) |
