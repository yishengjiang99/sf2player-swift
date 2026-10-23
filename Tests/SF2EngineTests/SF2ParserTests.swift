// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

final class SF2ParserTests: XCTestCase {
    /// One sample (ramp peaking at 16384), one instrument with a global zone, one preset with a global zone.
    private func basicBank() -> SF2Builder {
        var b = SF2Builder()
        let ramp: [Int16] = (0 ..< 200).map { (i: Int) -> Int16 in Int16((i - 100) * 16384 / 100) }
        b.samples = ramp + [Int16](repeating: 0, count: 46)
        b.sampleHeaders = [.init(name: "ramp", start: 0, end: 200, loopStart: 50, loopEnd: 150, pitch: 62, corr: -7)]
        b.instruments = [("inst", [
            .init(gens: [(Gen.coarseTune, 1), (Gen.pan, -100), (Gen.attackVolEnv, -1200)]),                // global
            .init(gens: [(Gen.keyRange, 0x4830), (Gen.sampleModes, 1), (Gen.fineTune, 5), (Gen.sampleID, 0)]), // 48..72
            .init(gens: [(Gen.keyRange, 0x7F49), (Gen.startAddrsOffset, 10), (Gen.sustainModEnv, 250), (Gen.initialFilterFc, 900),
                         (Gen.sampleID, 0)]),
        ])]
        b.presets = [("Test Piano", 0, 0, [
            .init(gens: [(Gen.coarseTune, 2), (Gen.initialAttenuation, 30)]), // global
            .init(gens: [(Gen.velRange, 0x7F10), (Gen.instrument, 0)]),
        ])]
        return b
    }

    func testParsesTablesAndInfo() throws {
        let sf = try SF2SoundFont(data: basicBank().build())
        XCTAssertEqual(sf.info["INAM"], "Test Bank")
        XCTAssertEqual(sf.samples.count, 246)
        XCTAssertEqual(sf.phdr.count, 2)
        XCTAssertEqual(sf.presets.count, 1)
        XCTAssertEqual(sf.phdr[0].presetName, "Test Piano")
        XCTAssertEqual(sf.shdr[0].pitchCorrection, -7)
        XCTAssertEqual(sf.inst.last?.instName, "EOI")
    }

    func testRegionMergeFollowsSpecRules() throws {
        let sf = try SF2SoundFont(data: basicBank().build())
        let regions = try sf.buildRegionsForPreset(0)
        XCTAssertEqual(regions.count, 2)
        let a = regions[0]
        XCTAssertEqual(a.keyRange.0, 48); XCTAssertEqual(a.keyRange.1, 72)
        XCTAssertEqual(a.velRange.0, 16); XCTAssertEqual(a.velRange.1, 127)
        XCTAssertEqual(a.coarseTune, 3, "additive: preset global 2 + inst global 1")
        XCTAssertEqual(a.fineTune, 5 - 7, "fineTune + sample pitchCorrection")
        XCTAssertEqual(a.initialAttenuationCb, 30)
        XCTAssertEqual(a.pan, -100)
        XCTAssertEqual(a.originalKey, 62)
        XCTAssertNil(a.overridingRootKey)
        XCTAssertEqual(a.volEnv.attackTc, -1200)
        XCTAssertEqual(a.volEnv.decayTc, -12000)
        XCTAssertEqual(a.sampleModes, 1)
        XCTAssertEqual(a.sample.end, 200)
        XCTAssertEqual(a.sample.loopStart, 50); XCTAssertEqual(a.sample.loopEnd, 150)
        XCTAssertEqual(a.initialFilterFcCents, 13500)
        // peak-normalized: |-16384| -> 1.0
        XCTAssertEqual(a.sample.dataL[0], -1.0)
        XCTAssertEqual(a.sample.dataL[150], Float((Double(Int16(50 * 16384 / 100)) / 32768) / 0.5))

        let b = regions[1]
        XCTAssertEqual(b.sample.end, 190, "startAddrsOffset trims the copy")
        XCTAssertEqual(b.sample.loopStart, 40)
        XCTAssertEqual(b.modEnv.sustain, 0.75, "2.01 #29: sustainModEnv 250 = 25 % below full scale (gbk-legacy read it as a level)")
        XCTAssertEqual(b.initialFilterFcCents, 1500, "E-03: clamped to the 8.1.3 minimum (gbk-legacy opened the filter)")
        XCTAssertEqual(b.sampleModes, 0)
    }

    func testLoopSanityAndNegativeOffsetClamp() throws {
        var bank = basicBank()
        bank.sampleHeaders[0].loopEnd = 51 // loopEnd <= loopStart + 1 -> loop disabled
        bank.instruments[0].1[2].gens.insert((Gen.startAddrsOffset, -20), at: 0) // overridden later in-zone (last wins)
        bank.instruments[0].1.append(.init(gens: [(Gen.startAddrsCoarseOffset, -1), (Gen.sampleID, 0)])) // wraps -> clamps -> dropped
        let regions = try SF2SoundFont(data: bank.build()).buildRegionsForPreset(0)
        XCTAssertEqual(regions.count, 3, "S-03: a negative coarse offset clamps to the sample start; the zone is kept (gbk-legacy dropped it)")
        XCTAssertEqual(regions[0].sampleModes, 0)
        XCTAssertEqual(regions[0].sample.loopStart, 0)
        XCTAssertEqual(regions[0].sample.loopEnd, regions[0].sample.end)
        XCTAssertEqual(clampU32(-1, 0, 100), 100)
        XCTAssertEqual(clampU32(50, 0, 100), 50)
    }

    func testStereoLinkLoadsTheLinkedSampleAsRight() throws {
        var bank = basicBank()
        bank.samples += (0 ..< 100).map { _ in Int16(1000) }
        bank.sampleHeaders[0].link = 1
        bank.sampleHeaders.append(.init(name: "right", start: 246, end: 346, loopStart: 250, loopEnd: 340, link: 0, type: 2))
        let r = try SF2SoundFont(data: bank.build()).buildRegionsForPreset(0)[0]
        // S-10: stereo is one voice per zone (each zone plays its own sample), so no right buffer is
        // attached. gbk-legacy loaded the linked sample as dataR.
        XCTAssertNil(r.sample.dataR)
    }

    func testSampleBuffersAreSharedAcrossIdenticalRanges() throws {
        let sf = try SF2SoundFont(data: basicBank().build())
        let a = try sf.buildRegionsForPreset(0), b = try sf.buildRegionsForPreset(0)
        XCTAssertTrue(a[0].sample.dataL === b[0].sample.dataL)
        XCTAssertTrue(try sf.regionList(forPreset: 0) === sf.regionList(forPreset: 0))
    }

    func testErrors() throws {
        XCTAssertThrowsError(try SF2SoundFont(data: Data("RIFX0000".utf8))) { XCTAssertEqual($0 as? SF2Error, .notRIFF) }
        var bank = basicBank()
        bank.omitTable = "shdr"
        XCTAssertThrowsError(try SF2SoundFont(data: bank.build())) { XCTAssertEqual($0 as? SF2Error, .missingTable("shdr")) }
        let sf = try SF2SoundFont(data: basicBank().build())
        XCTAssertThrowsError(try sf.buildRegionsForPreset(1)) { XCTAssertEqual($0 as? SF2Error, .presetIndexOutOfRange(1)) }
    }

    func testResolvePresetIndexFallbacks() throws {
        var bank = basicBank()
        bank.presets.append(("Bank8 Piano", 0, 8, bank.presets[0].3))
        bank.presets.append(("Only Bank 128", 5, 128, bank.presets[0].3))
        let sf = try SF2SoundFont(data: bank.build())
        XCTAssertEqual(sf.resolvePresetIndex(program: 0, bank: 8), 1)
        XCTAssertEqual(sf.resolvePresetIndex(program: 0, bank: 3), 0, "falls back to bank 0")
        XCTAssertEqual(sf.resolvePresetIndex(program: 5, bank: 0), 2, "any bank")
        XCTAssertNil(sf.resolvePresetIndex(program: 9, bank: 0))
    }

    // MARK: GeneralUser GS (skips without the bank)

    func testGeneralUserGSMatchesGbkParse() throws {
        let sf = try SharedSoundFont.get()
        XCTAssertEqual(sf.info["INAM"], "GeneralUser GS 2.0.2")
        XCTAssertEqual(sf.phdr.count, 288)
        XCTAssertEqual(sf.shdr.count, 921)
        XCTAssertEqual(sf.samples.count, 16_048_567)
        XCTAssertEqual(sf.phdr[0].presetName, "Marimba")
        // values printed by gbk parseSF2 / buildRegionsForPreset(0)
        let r = try sf.buildRegionsForPreset(0)
        XCTAssertEqual(r.count, 152)
        XCTAssertEqual(r[0].keyRange.1, 48); XCTAssertEqual(r[0].velRange.0, 121)
        XCTAssertEqual(r[0].sample.dataL.count, 17464)
        XCTAssertEqual(r[0].sample.loopStart, 17230); XCTAssertEqual(r[0].sample.loopEnd, 17400)
        XCTAssertEqual(r[0].fineTune, 18)
        XCTAssertEqual(r[0].volEnv, SF2VolEnv(delayTc: -12000, attackTc: -16332, holdTc: -498, decayTc: 3916, sustainCb: 1000, releaseTc: 3916))
        XCTAssertEqual(r[0].initialFilterFcCents, 11810)
        XCTAssertEqual(r[0].sample.dataL[100], -0.000213623046875)
        XCTAssertNil(r[0].sample.dataR)
        XCTAssertEqual(r.reduce(0) { $0 + $1.sample.dataL.count }, 1_881_468)
        let violin = sf.resolvePresetIndex(program: 40, bank: 0)
        XCTAssertEqual(violin, 33)
        XCTAssertEqual(sf.presetName(33), "Violin")
        XCTAssertEqual(try sf.buildRegionsForPreset(33).count, 156)
        XCTAssertNotNil(sf.info["ICMT"]?.range(of: "License v2.0"))
    }

    func testAsyncLoad() async throws {
        guard let url = TestPaths.soundFontURL else { throw XCTSkip("no GeneralUser-GS.sf2") }
        let sf = try await SF2SoundFont.load(contentsOf: url)
        XCTAssertEqual(sf.presets.count, 287)
    }
}
