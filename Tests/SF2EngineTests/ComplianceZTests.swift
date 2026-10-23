// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Matrix rows Z-xx: zones and the preset/instrument hierarchy (sections 7.3 to 9.4, 10.6, 10.7).
final class ComplianceZTests: XCTestCase {
    typealias B = SF2Builder

    private func spec(_ b: B, _ preset: Int = 0) throws -> [SF2Region] {
        try SF2SoundFont(data: b.build(), options: .strict).buildRegionsForPreset(preset, normalize: false, fidelity: .spec)
    }
    private func merged(_ b: B, _ preset: Int = 0) throws -> [[Int: Int]] {
        try SF2SoundFont(data: b.build(), options: .strict).specMergedGenerators(preset)
    }
    private func bank(inst: [[(Int, Int)]], preset: [[(Int, Int)]] = [[(Gen.instrument, 0)]]) -> B {
        var b = B.single(B.dc(100))
        b.instruments = [("i", inst.map { .init(gens: $0) })]
        b.presets = [("p", 0, 0, preset.map { .init(gens: $0) })]
        return b
    }

    func test_Z01_globalZoneDetectedByLastGenerator() throws {
        // First zone without terminal sampleID is the global zone (object has > 1 zone).
        var r = try spec(bank(inst: [[(Gen.pan, 100)], [(Gen.sampleID, 0)]]))
        XCTAssertEqual(r.map(\.pan), [100])
        // A single zone without a terminal is not a global zone and nothing sounds.
        r = try spec(bank(inst: [[(Gen.pan, 100)]]))
        XCTAssertEqual(r.count, 0)
        // A non-first zone without sampleID is not global and does not apply to later zones.
        r = try spec(bank(inst: [[(Gen.sampleID, 0)], [(Gen.pan, 300)], [(Gen.pan, 7), (Gen.sampleID, 0)]]))
        XCTAssertEqual(r.map(\.pan), [0, 7])
        // Preset level: a global preset zone is the first zone without an instrument generator.
        r = try spec(bank(inst: [[(Gen.sampleID, 0)]], preset: [[(Gen.pan, 50)], [(Gen.instrument, 0)]]))
        XCTAssertEqual(r.map(\.pan), [50])
    }

    func test_Z02_generatorsAfterTerminalIgnored() throws {
        let r = try spec(bank(inst: [[(Gen.sampleID, 0), (Gen.coarseTune, 5)]],
                              preset: [[(Gen.instrument, 0), (Gen.fineTune, 9)]]))
        XCTAssertEqual(r.map(\.coarseTune), [0])
        XCTAssertEqual(r.map(\.fineTune), [0])
    }

    func test_Z03_rangeGeneratorPositionRules() throws {
        let r = try spec(bank(inst: [
            [(Gen.pan, 1), (Gen.keyRange, 0x3C3C), (Gen.sampleID, 0)],                 // keyRange not first -> ignored
            [(Gen.keyRange, 0x4030), (Gen.velRange, 0x4010), (Gen.sampleID, 0)],       // both honored
            [(Gen.coarseTune, 1), (Gen.velRange, 0x4010), (Gen.sampleID, 0)],          // velRange after other -> ignored
            [(Gen.velRange, 0x2010), (Gen.sampleID, 0)],                               // velRange first -> honored
        ]))
        XCTAssertEqual(r.map(\.keyRange.0), [0, 48, 0, 0]); XCTAssertEqual(r.map(\.keyRange.1), [127, 64, 127, 127])
        XCTAssertEqual(r.map(\.velRange.0), [0, 16, 0, 16]); XCTAssertEqual(r.map(\.velRange.1), [127, 64, 127, 32])
    }

    func test_Z04_duplicateGeneratorLastWins() throws {
        let r = try spec(bank(inst: [[(Gen.pan, 100), (Gen.pan, -200), (Gen.sampleID, 0)]]))
        XCTAssertEqual(r.map(\.pan), [-200])
    }

    func test_Z05_incompleteZonesIgnored() throws {
        // Empty global zone (no generators, no modulators) is ignored; the local zone still plays.
        var r = try spec(bank(inst: [[], [(Gen.sampleID, 0)]]))
        XCTAssertEqual(r.count, 1)
        // Non-first preset zone without instrument is ignored (not applied as a global).
        r = try spec(bank(inst: [[(Gen.sampleID, 0)]], preset: [[(Gen.instrument, 0)], [(Gen.pan, 300)]]))
        XCTAssertEqual(r.map(\.pan), [0])
        // Preset with no zones: nothing, no error.
        var b = bank(inst: [[(Gen.sampleID, 0)]]); b.presets = [("empty", 0, 0, [])]
        XCTAssertEqual(try spec(b).count, 0)
    }

    func test_Z06_illegalIndexGeneratorsIgnored() throws {
        // sampleID in a preset zone and instrument in an instrument zone are ignored (10.7).
        let m = try merged(bank(inst: [[(Gen.instrument, 0), (Gen.pan, 4), (Gen.sampleID, 0)]],
                                preset: [[(Gen.sampleID, 0), (Gen.instrument, 0)]]))
        XCTAssertEqual(m.count, 1)
        XCTAssertNil(m[0][Gen.instrument])
        XCTAssertEqual(m[0][Gen.pan], 4)
    }

    func test_Z07_instrumentOnlyGeneratorsIgnoredInPresets() throws {
        let onlyInst = [0, 1, 2, 3, 4, 12, 45, 46, 47, 50, 54, 57, 58]
        let m = try merged(bank(inst: [[(Gen.sampleID, 0)]], preset: [onlyInst.map { ($0, 3) } + [(Gen.instrument, 0)]]))
        for g in onlyInst { XCTAssertNil(m[0][g], "gen \(g)") }
    }

    func test_Z08_reservedGeneratorsIgnored() throws {
        let reserved = [14, 18, 19, 20, 42, 49, 55, 59, 60, 61, 99, 1000]
        let m = try merged(bank(inst: [reserved.map { ($0, 5) } + [(Gen.sampleID, 0)]],
                                preset: [reserved.map { ($0, 5) } + [(Gen.instrument, 0)]]))
        for g in reserved { XCTAssertNil(m[0][g], "gen \(g)") }
    }

    func test_Z09_presetRangesIntersect() throws {
        let r = try spec(bank(inst: [[(Gen.keyRange, 0x5030), (Gen.sampleID, 0)], [(Gen.keyRange, 0x7F60), (Gen.sampleID, 0)]],
                              preset: [[(Gen.keyRange, 0x4028), (Gen.instrument, 0)]]))
        XCTAssertEqual(r.count, 1, "second zone 96..127 does not intersect 40..64")
        XCTAssertEqual(r[0].keyRange.0, 48); XCTAssertEqual(r[0].keyRange.1, 64)
    }

    func test_Z10_presetAddsToInstrumentOrDefault() throws {
        // 8.5 worked example: preset attackVolEnv +2400 on instrument default (-12000) -> -9600; on 1200 -> 3600.
        var r = try spec(bank(inst: [[(Gen.sampleID, 0)]], preset: [[(Gen.attackVolEnv, 2400), (Gen.instrument, 0)]]))
        XCTAssertEqual(r[0].volEnv.attackTc, -9600)
        r = try spec(bank(inst: [[(Gen.attackVolEnv, 1200), (Gen.sampleID, 0)]], preset: [[(Gen.attackVolEnv, 2400), (Gen.instrument, 0)]]))
        XCTAssertEqual(r[0].volEnv.attackTc, 3600)
        // Local replaces global at each level before the sum.
        r = try spec(bank(inst: [[(Gen.coarseTune, 10)], [(Gen.coarseTune, 2), (Gen.sampleID, 0)]],
                          preset: [[(Gen.coarseTune, 40)], [(Gen.coarseTune, 3), (Gen.instrument, 0)]]))
        XCTAssertEqual(r[0].coarseTune, 5)
    }

    func test_Z11_genInfoTableAndClamp() throws {
        XCTAssertEqual(GenInfo.table.count, 61)
        for id in [14, 18, 19, 20, 42, 49, 55, 59, 60] { XCTAssertNil(GenInfo.get(id)) }
        XCTAssertEqual(GenInfo.defaultValue(Gen.initialFilterFc), 13500)
        XCTAssertEqual(GenInfo.defaultValue(Gen.scaleTuning), 100)
        XCTAssertEqual(GenInfo.defaultValue(Gen.overridingRootKey), -1)
        for id in 0 ... 70 {
            let g = GenInfo.get(id)
            let r = GenInfo.valueRange(id)
            if let g, g.kind == .value { XCTAssertEqual(r?.0, g.min, "\(id)"); XCTAssertEqual(r?.1, g.max, "\(id)") } else { XCTAssertNil(r, "\(id)") }
        }
        let r = try spec(bank(inst: [[(Gen.initialAttenuation, 1400), (Gen.pan, 400), (Gen.fineTune, 99), (Gen.coarseTune, -120),
                                      (Gen.sustainVolEnv, 1440), (Gen.initialFilterQ, 900), (Gen.sampleID, 0)]],
                              preset: [[(Gen.initialAttenuation, 100), (Gen.pan, 300), (Gen.fineTune, 50), (Gen.coarseTune, -10),
                                        (Gen.sustainVolEnv, 200), (Gen.initialFilterQ, 200), (Gen.instrument, 0)]]))
        XCTAssertEqual(r[0].initialAttenuationCb, 1440)
        XCTAssertEqual(r[0].pan, 500)
        XCTAssertEqual(r[0].fineTune, 99)
        XCTAssertEqual(r[0].coarseTune, -120)
        XCTAssertEqual(r[0].volEnv.sustainCb, 1440)
        XCTAssertEqual(r[0].initialFilterQCb, 960)
    }

    func test_Z12_presetResolution() throws {
        var b = bank(inst: [[(Gen.sampleID, 0)]])
        let z = b.presets[0].3
        b.presets = [("first", 3, 0, z), ("dup", 3, 0, z), ("p200", 200, 0, z), ("b200", 4, 200, z), ("drum", 4, 128, z)]
        let sf = try SF2SoundFont(data: b.build(), options: .strict)
        XCTAssertEqual(sf.resolvePresetIndex(program: 3, bank: 0), 0, "first (preset, bank) is active")
        XCTAssertEqual(sf.presets.count, 5, "unplayable presets are kept")
        XCTAssertNil(sf.resolvePresetIndex(program: 200, bank: 0), "wPreset > 127 never playable")
        XCTAssertEqual(sf.resolvePresetIndex(program: 4, bank: 200), 4, "bank > 128 never playable; falls back (engine policy)")
        XCTAssertFalse(sf.isPlayable(3)); XCTAssertTrue(sf.isPlayable(4))
    }
}
