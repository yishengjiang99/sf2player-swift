// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Matrix rows M-xx: modulators (sections 7.4, 7.8, 8.2 to 8.4, 9.5).
final class ComplianceMTests: XCTestCase {
    let v201 = SF2SpecVersion(major: 2, minor: 1), v204 = SF2SpecVersion(major: 2, minor: 4)

    private func value(_ m: SF2Modulator, cc: [Int: Int] = [:], velocity: Int = 100, key: Int = 60, wheel: Int = 8192,
                       pws: Double = 2, pressure: Int = 0, poly: Int = 0) -> Double {
        var c = [UInt8](repeating: 0, count: 128)
        for (k, v) in cc { c[k] = UInt8(v) }
        return c.withUnsafeBufferPointer {
            modValue(m, ModInputs(velocity: velocity, key: key, cc: $0.baseAddress!, pitchWheel: wheel, pitchWheelSensitivity: pws,
                                  channelPressure: pressure, polyPressure: poly))
        }
    }
    private func kept(_ m: SF2Modulator, _ v: SF2SpecVersion) -> Bool {
        SF2Modulator.merge(instGlobal: [], instLocal: [m], presetGlobal: [], presetLocal: [], version: v).contains(m)
    }

    func test_M01_sourceLayoutAndUnknownType() {
        XCTAssertTrue(kept(SF2Modulator(src: 0x0C81, dest: 34, amount: 10), v201), "type 3 switch is defined")
        XCTAssertFalse(kept(SF2Modulator(src: 0x1081, dest: 34, amount: 10), v201), "type 4 -> ignore")
        XCTAssertFalse(kept(SF2Modulator(src: 0x0081, dest: 34, amount: 10, amtSrc: 0x8002), v201), "amount-source type > 3 -> ignore")
        // bits: index 0-6, CC 7, D 8, P 9, type 10-15
        XCTAssertEqual(value(SF2Modulator(src: 0x0081, dest: 34, amount: 128), cc: [1: 64]), 64, accuracy: 1e-9)
        XCTAssertEqual(value(SF2Modulator(src: 0x0181, dest: 34, amount: 128), cc: [1: 63]), 64, accuracy: 1e-9)
        XCTAssertEqual(value(SF2Modulator(src: 0x0281, dest: 34, amount: 128), cc: [1: 0]), -128, accuracy: 1e-9)
    }

    func test_M02_illegalSourcesIgnored() {
        for idx in [1, 4, 5, 9, 11, 12, 15, 17, 127] {
            XCTAssertFalse(kept(SF2Modulator(src: UInt16(idx), dest: 34, amount: 10), v201), "general \(idx)")
        }
        for idx in [0, 2, 3, 10, 13, 14, 16] { XCTAssertTrue(kept(SF2Modulator(src: UInt16(idx), dest: 34, amount: 10), v201)) }
        for cc in [0, 6, 32, 38, 98, 99, 100, 101, 120, 127, 33, 63] {
            XCTAssertFalse(kept(SF2Modulator(src: 0x80 | UInt16(cc), dest: 34, amount: 10), v201), "CC\(cc)")
        }
        for cc in [1, 7, 31, 64, 97, 102, 119] { XCTAssertTrue(kept(SF2Modulator(src: 0x80 | UInt16(cc), dest: 34, amount: 10), v201)) }
    }

    func test_M03_noControllerIsOne() {
        XCTAssertEqual(value(SF2Modulator(src: 0, dest: 34, amount: 100)), 100)
        XCTAssertEqual(value(SF2Modulator(src: 0x0081, dest: 34, amount: 128, amtSrc: 0), cc: [1: 127]), 127, accuracy: 1e-9)
    }

    func test_M04_sourceMappingTable() {
        func concave(_ x: Double) -> Double { x <= 0 ? 0 : x >= 1 ? 1 : min(1, -(20.0 / 96) * log10((1 - x) * (1 - x))) }
        func curve(_ t: Int, _ x: Double) -> Double {
            switch t { case 1: return concave(x); case 2: return 1 - concave(1 - x); case 3: return x >= 0.5 ? 1 : 0; default: return x }
        }
        func expected(_ v: Double, range: Double, t: Int, d: Bool, p: Bool) -> Double {
            if p { let b0 = 2 * v / range - 1; let b = d ? -b0 : b0; return (b < 0 ? -1 : 1) * curve(t, abs(b)) }
            return curve(t, d ? (range - 1 - v) / range : v / range)
        }
        for t in 0 ... 3 { for d in [false, true] { for p in [false, true] {
            let bits = UInt16(t << 10) | (d ? 0x100 : 0) | (p ? 0x200 : 0)
            for v in [0, 64, 127] {  // 7-bit CC1
                let got = value(SF2Modulator(src: bits | 0x81, dest: 34, amount: 1), cc: [1: v])
                XCTAssertEqual(got, expected(Double(v), range: 128, t: t, d: d, p: p), accuracy: 1e-12, "7-bit t\(t) d\(d) p\(p) v\(v)")
            }
            for v in [0, 8192, 16383] { // 14-bit pitch wheel
                let got = value(SF2Modulator(src: bits | 14, dest: 34, amount: 1), wheel: v)
                XCTAssertEqual(got, expected(Double(v), range: 16384, t: t, d: d, p: p), accuracy: 1e-12, "14-bit t\(t) d\(d) p\(p) v\(v)")
            }
        } } }
        // Table 2 endpoints: unipolar max 127/128, bipolar min -1, center 0.
        XCTAssertEqual(value(SF2Modulator(src: 0x0081, dest: 34, amount: 1), cc: [1: 127]), 127.0 / 128)
        XCTAssertEqual(value(SF2Modulator(src: 0x0181, dest: 34, amount: 1), cc: [1: 0]), 127.0 / 128, "negative: 0 -> 127/128")
        XCTAssertEqual(value(SF2Modulator(src: 0x0181, dest: 34, amount: 1), cc: [1: 127]), 0, "negative: 127 -> 0")
        XCTAssertEqual(value(SF2Modulator(src: 0x0281, dest: 34, amount: 1), cc: [1: 64]), 0)
        XCTAssertEqual(value(SF2Modulator(src: 0x0281, dest: 34, amount: 1), cc: [1: 0]), -1)
    }

    func test_M05_transformVersionGated() {
        let abs = SF2Modulator(src: 0x0081, dest: 34, amount: 10, transform: 2)
        XCTAssertFalse(kept(abs, v201)); XCTAssertTrue(kept(abs, v204))
        XCTAssertFalse(kept(SF2Modulator(src: 0x0081, dest: 34, amount: 10, transform: 1), v204))
        XCTAssertEqual(value(SF2Modulator(src: 0x0281, dest: 34, amount: 100, transform: 2), cc: [1: 0]), 100)
    }

    func test_M06_destinationMustBeValueGenerator() {
        for d in [0, 1, 2, 3, 4, 12, 41, 43, 44, 45, 46, 47, 50, 53, 54, 57, 58, 14, 42, 60, 61, 100, 0x8001] {
            XCTAssertFalse(kept(SF2Modulator(src: 0x0081, dest: UInt16(d), amount: 10), v201), "dest \(d)")
        }
        for d in [5, 8, 9, 15, 16, 17, 21, 34, 37, 48, 51, 52, 56] {
            XCTAssertTrue(kept(SF2Modulator(src: 0x0081, dest: UInt16(d), amount: 10), v201), "dest \(d)")
        }
    }

    func test_M07_dest59Ignored() throws {
        XCTAssertGreaterThanOrEqual(SF2Modulator.pitchDest, 64, "virtual pitch outside the enumerator space")
        XCTAssertFalse(kept(SF2Modulator(src: 0x0081, dest: 59, amount: 1200), v201))
        XCTAssertFalse(kept(SF2Modulator(src: 0x0081, dest: SF2Modulator.pitchDest, amount: 1200), v201), "file can't target it")
        XCTAssertTrue(SF2Modulator.defaults201.contains { $0.dest == SF2Modulator.pitchDest })
    }

    func test_M08_modulatorOutput() {
        let m = SF2Modulator(src: 0x0081, dest: 34, amount: 1000, amtSrc: 0x0082)
        XCTAssertEqual(value(m, cc: [1: 64, 2: 32]), 1000 * 0.5 * 0.25, accuracy: 1e-9)
    }

    func test_M09_modulatorMergeRules() throws {
        let vel = SF2Modulator(src: 0x0502, dest: 48, amount: 960)
        let a = SF2Modulator(src: 0x0081, dest: 34, amount: 100), a2 = SF2Modulator(src: 0x0081, dest: 34, amount: 300)
        let b = SF2Modulator(src: 0x0082, dest: 34, amount: 50)
        func merge(_ ig: [SF2Modulator], _ il: [SF2Modulator], _ pg: [SF2Modulator] = [], _ pl: [SF2Modulator] = []) -> [SF2Modulator] {
            SF2Modulator.merge(instGlobal: ig, instLocal: il, presetGlobal: pg, presetLocal: pl, version: v201)
        }
        // instrument global replaces identical default
        XCTAssertEqual(merge([SF2Modulator(src: 0x0502, dest: 48, amount: 480)], []).filter { $0.sameIdentity(vel) }.map(\.amount), [480])
        // instrument local replaces identical global
        XCTAssertEqual(merge([a], [a2]).filter { $0.sameIdentity(a) }.map(\.amount), [300])
        // non-identical instrument modulators are added
        XCTAssertEqual(merge([a], [b]).count, SF2Modulator.defaults201.count + 2)
        // preset local replaces identical preset global, then sums into the identical instrument modulator
        XCTAssertEqual(merge([], [a], [a2], [SF2Modulator(src: 0x0081, dest: 34, amount: 7)]).filter { $0.sameIdentity(a) }.map(\.amount), [107])
        // preset modulator identical to a default sums into it
        XCTAssertEqual(merge([], [], [], [SF2Modulator(src: 0x0502, dest: 48, amount: 40)]).filter { $0.sameIdentity(vel) }.map(\.amount), [1000])
        // non-identical preset modulators are added
        XCTAssertEqual(merge([], [], [], [b]).count, SF2Modulator.defaults201.count + 1)
        // identity includes transform (9.5.1; 7.4 omits it)
        XCTAssertFalse(a.sameIdentity(SF2Modulator(src: 0x0081, dest: 34, amount: 100, transform: 2)))
        // within a zone a later duplicate replaces the earlier one (file path)
        var bank = SF2Builder.single(SF2Builder.dc(100), instMods: [.init(src: 0x81, dest: 34, amount: 10), .init(src: 0x81, dest: 34, amount: 20)])
        bank.ifil = (2, 1)
        let r = try SF2SoundFont(data: bank.build(), options: .strict).buildRegionsForPreset(0, fidelity: .spec)
        XCTAssertEqual((r[0].modulators ?? []).filter { $0.sameIdentity(a) }.map(\.amount), [20])
    }

    func test_M10_defaultModulators201() throws {
        let d = SF2Modulator.defaults(for: v201)
        XCTAssertEqual(d.count, 10)
        XCTAssertEqual(d.map(\.src), [0x0502, 0x0102, 0x000D, 0x0081, 0x0587, 0x028A, 0x058B, 0x00DB, 0x00DD, 0x020E])
        XCTAssertEqual(d.map(\.dest), [48, 8, 6, 6, 48, 17, 48, 16, 15, SF2Modulator.pitchDest])
        XCTAssertEqual(d.map(\.amount), [960, -2400, 50, 50, 960, 1000, 960, 200, 200, 12700])
        XCTAssertEqual(d.map(\.amtSrc), [0, 0x0D02, 0, 0, 0, 0, 0, 0, 0, 0x0010])
        XCTAssertEqual(SF2Modulator.defaults(for: v204).count, 8, "2.04 files keep the previous set")
        // velocity-to-filter amount source is a negative unipolar switch: velocity 127 -> 0, 1 -> 1.
        XCTAssertEqual(value(d[1], velocity: 127), 0)
        XCTAssertEqual(value(d[1], velocity: 1), -2400 * 126.0 / 128, accuracy: 1e-9)
        // Defaults apply at the instrument level only: a 2.01 bank's region gets exactly the 10.
        let r = try SF2SoundFont(data: SF2Builder.single(SF2Builder.dc(100)).build(), options: .strict).buildRegionsForPreset(0, fidelity: .spec)
        XCTAssertEqual(r[0].modulators ?? [], d)
    }
}

extension ComplianceMTests {
    func test_M12_modulatedValuesReclamped() throws {
        let b = SF2Builder.single(SF2Builder.dc(400), loop: (10, 390), instGens: [(Gen.sampleModes, 1), (Gen.initialFilterFc, 9000)],
                                  instMods: [.init(src: 0x0081, dest: 8, amount: 20000), .init(src: 0x0082, dest: 8, amount: -32000)])
        let r = try SpecRender(b)
        r.noteOn(60)
        func fc() -> Double { r.engine.st.pointee.voices[Int(r.engine.st.pointee.order[0])].initialFc }
        XCTAssertEqual(fc(), 9000 - 2400 * 0, accuracy: 1e-9, "velocity 127 -> default vel-to-filter 0")
        r.cc(1, 127)
        XCTAssertEqual(fc(), 13500, "clamped to 13500 after summation")
        r.cc(1, 0); r.cc(2, 127)
        XCTAssertEqual(fc(), 1500, "clamped to 1500")
    }
}
