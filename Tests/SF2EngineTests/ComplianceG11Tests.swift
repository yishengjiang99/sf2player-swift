// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Matrix row G-11: chorus / reverb sends (8.1.2 #15/#16, 9.1.5 CC91/CC93 defaults), aux buses, built-in effects.
final class ComplianceG11Tests: XCTestCase {
    typealias B = SF2Builder
    typealias A = Analysis

    private func aux(_ r: SpecRender, _ n: Int) -> [[Float]] {
        let z = [Float](repeating: 0, count: n)
        var l = z, rr = z, a = z, b = z, c = z, d = z
        r.engine.renderRange(&l, &rr, reverbL: &a, reverbR: &b, chorusL: &c, chorusR: &d)
        return [l, rr, a, b, c, d]
    }

    func test_G11_effectsSends() throws {
        let wave = B.sine(cycles: 100, n: 4410)
        // generator sends: reverb 500 (50 %), chorus 250 (25 %); bus = send x panned dry signal
        let r = try SpecRender(B.single(wave, loop: (0, 4410), instGens: [(Gen.sampleModes, 1), (Gen.reverbEffectsSend, 500),
                                                                         (Gen.chorusEffectsSend, 250), (Gen.pan, -250)]))
        r.cc(91, 0); r.cc(93, 0)
        r.noteOn(60)
        let b = aux(r, 8820)
        for i in stride(from: 100, to: 8820, by: 97) {
            XCTAssertEqual(b[2][i], b[0][i] * 0.5, accuracy: 1e-6); XCTAssertEqual(b[3][i], b[1][i] * 0.5, accuracy: 1e-6)
            XCTAssertEqual(b[4][i], b[0][i] * 0.25, accuracy: 1e-6); XCTAssertEqual(b[5][i], b[1][i] * 0.25, accuracy: 1e-6)
        }
        XCTAssertGreaterThan(A.rmsDB(b[2], from: 4410), -40)

        // 9.1.5 defaults: CC91 -> reverb 200 x v/128 (0.1 % units), CC93 -> chorus 200 x v/128
        let r2 = try SpecRender(B.single(wave, loop: (0, 4410), instGens: [(Gen.sampleModes, 1)]))
        r2.cc(91, 127); r2.cc(93, 64)
        r2.noteOn(60)
        let c = aux(r2, 4410)
        let i = 3000
        XCTAssertEqual(Double(c[2][i]) / Double(c[0][i]), 0.2 * 127 / 128, accuracy: 1e-4)
        XCTAssertEqual(Double(c[4][i]) / Double(c[0][i]), 0.2 * 64 / 128, accuracy: 1e-4)

        // sends never change the dry level
        let dry = try SpecRender(B.single(wave, loop: (0, 4410), instGens: [(Gen.sampleModes, 1)]))
        dry.cc(91, 0); dry.cc(93, 0); dry.noteOn(60)
        let d = aux(dry, 4410)
        XCTAssertEqual(A.rmsDB(d[0], from: 2000), A.rmsDB(c[0], from: 2000), accuracy: 1e-3)

        // built-in effects: a tail remains after the dry voice ends; disabled -> silence
        func tail(_ on: Bool) throws -> Double {
            let t = try SpecRender(B.single(wave, loop: (0, 4410), instGens: [(Gen.sampleModes, 1), (Gen.reverbEffectsSend, 1000),
                                                                             (Gen.chorusEffectsSend, 1000), (Gen.releaseVolEnv, -6000)]))
            t.engine.effectsEnabled = on
            t.noteOn(60); _ = t.render(8820); t.noteOff(60); _ = t.render(22050)
            XCTAssertEqual(t.engine.st.pointee.count, 0, "dry voice finished")
            return A.rmsDB(t.render(4410).l)
        }
        XCTAssertGreaterThan(try tail(true), -80)
        XCTAssertLessThan(try tail(false), -200)

        // gbk output never carries effects
        XCTAssertFalse(Sf2SynthEngine(outSr: 44100).st.pointee.spec)
    }
}
