// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Matrix rows S-xx: samples (sections 6, 7.10, 8.1.2, 9.1).
final class ComplianceSTests: XCTestCase {
    typealias B = SF2Builder

    private func sf(_ b: B) throws -> SF2SoundFont { try SF2SoundFont(data: b.build(), options: .strict) }

    func test_S01_specDoesNotNormalize() throws {
        let f = try sf(B.single(B.dc(100, level: 8192)))
        let spec = try f.regionList(forPreset: 0, fidelity: .spec)
        XCTAssertEqual(spec.regions[0].sample.dataL[10], 0.25, "raw 8192 / 32768")
        let gbk = try f.regionList(forPreset: 0, fidelity: .gbk)
        XCTAssertEqual(gbk.regions[0].sample.dataL[10], 1.0, "gbk peak-normalizes (unchanged)")
    }

    func test_S05_unpitchedOriginalKey() throws {
        for p in [128, 200, 255] {
            let r = try sf(B.single(B.dc(100), pitch: p)).buildRegionsForPreset(0, fidelity: .spec)
            XCTAssertEqual(r[0].originalKey, 60, "pitch \(p)")
        }
        XCTAssertEqual(try sf(B.single(B.dc(100), pitch: 72)).buildRegionsForPreset(0, fidelity: .spec)[0].originalKey, 72)
    }

    func test_S06_overridingRootKeyMinusOneUsesHeader() throws {
        var r = try sf(B.single(B.dc(100), pitch: 64, instGens: [(Gen.overridingRootKey, -1)])).buildRegionsForPreset(0, fidelity: .spec)
        XCTAssertNil(r[0].overridingRootKey)
        XCTAssertEqual(r[0].originalKey, 64)
        r = try sf(B.single(B.dc(100), pitch: 64, instGens: [(Gen.overridingRootKey, 69)])).buildRegionsForPreset(0, fidelity: .spec)
        XCTAssertEqual(r[0].overridingRootKey, 69)
    }

    func test_S07_pitchCorrection() throws {
        var b = B.single(B.dc(100))
        b.sampleHeaders[0].corr = -4
        let r = try sf(b).buildRegionsForPreset(0, fidelity: .spec)
        XCTAssertEqual(r[0].fineTune, -4, "7.10 example: -4 cents added to tuning")
    }

    func test_S02_samplePointsOutOfRange() throws {
        var b = B.single(B.dc(100))
        b.sampleHeaders[0].end = 5000                      // past smpl
        XCTAssertThrowsError(try SF2SoundFont(data: b.build(), options: .strict)) {
            XCTAssertEqual($0 as? SF2Error, .structural(.samplePointsOutOfRange(sample: 0)))
        }
        XCTAssertEqual(try SF2SoundFont(data: b.build()).buildRegionsForPreset(0, fidelity: .spec).count, 0, "lenient: silent")
        var e = B.single(B.dc(100)); e.sampleHeaders[0].end = 0  // end <= start
        XCTAssertThrowsError(try SF2SoundFont(data: e.build(), options: .strict))
        XCTAssertEqual(try SF2SoundFont(data: e.build()).buildRegionsForPreset(0, fidelity: .spec).count, 0)
    }
}
