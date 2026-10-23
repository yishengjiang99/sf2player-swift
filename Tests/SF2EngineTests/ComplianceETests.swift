// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Matrix rows E-02...E-04: run-time error handling (sections 10.3 to 10.6).
final class ComplianceETests: XCTestCase {
    typealias B = SF2Builder

    func test_E02_unknownEnumeratorsIgnored() throws {
        let b = B.single(B.dc(100), instGens: [(99, 5), (61, 1), (Gen.pan, 10)], presetGens: [(200, 7)],
                         instMods: [.init(src: 0x0081, dest: 99, amount: 5), .init(src: 0x0055, dest: 48, amount: 5)])
        let sf = try SF2SoundFont(data: b.build(), options: .strict)
        let r = try sf.buildRegionsForPreset(0, fidelity: .spec)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].pan, 10)
        XCTAssertEqual(r[0].modulators ?? [], SF2Modulator.defaults201, "unknown modulators dropped, defaults kept")
        XCTAssertNil(try sf.specMergedGenerators(0)[0][99])
    }

    func test_E03_illegalValues() throws {
        // Illegal overridingRootKey (out of 0...127) -> default (-1 = header key); illegal original pitch -> 60.
        var b = B.single(B.dc(100), pitch: 200, instGens: [(Gen.overridingRootKey, 300)])
        var r = try SF2SoundFont(data: b.build(), options: .strict).buildRegionsForPreset(0, fidelity: .spec)[0]
        XCTAssertNil(r.overridingRootKey); XCTAssertEqual(r.originalKey, 60)
        // Out-of-range value generators clamp (10.5).
        b = B.single(B.dc(100), instGens: [(Gen.initialFilterFc, 100), (Gen.scaleTuning, 5000), (Gen.decayVolEnv, 20000)])
        r = try SF2SoundFont(data: b.build(), options: .strict).buildRegionsForPreset(0, fidelity: .spec)[0]
        XCTAssertEqual(r.initialFilterFcCents, 1500); XCTAssertEqual(r.scaleTuning, 1200); XCTAssertEqual(r.volEnv.decayTc, 8000)
    }

    func test_E04_missingTerminatorIgnoresZone() throws {
        // Zones without sampleID never sound; a note that matches nothing starts no voice.
        var b = B.single(B.dc(400), loop: (10, 390), instGens: [(Gen.keyRange, 0x3C30), (Gen.sampleModes, 1)])
        b.instruments[0].1.append(.init(gens: [(Gen.keyRange, 0x7F50)]))  // no sampleID -> ignored
        let r = try SpecRender(b)
        r.noteOn(100)
        XCTAssertEqual(r.engine.st.pointee.count, 0, "note-on ignored")
        r.noteOn(50)
        XCTAssertEqual(r.engine.st.pointee.count, 1)
    }
}
