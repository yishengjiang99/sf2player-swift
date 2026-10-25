// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Behaviours gbk's JS engine gained after the Oct 22 2026 parity pass (gbk 4a3da62 .. 19dbdb4), ported here.
final class GbkSyncTests: XCTestCase {
    typealias B = SF2Builder
    typealias A = Analysis

    private func impulseResponse(_ fx: inout SF2EffectsRT, _ l: Double, _ r: Double, frames: Int = 6000) -> [Double] {
        var out: [Double] = []
        for i in 0 ..< frames {
            let w = i == 0 ? fx.process(l, r, 0, 0) : fx.process(0, 0, 0, 0)
            out.append(w.0); out.append(w.1)
        }
        return out
    }

    /// gbk 6c9eafc: the reverb input is the mono send (L + R, buses are panned), and the return is FluidSynth's (2.7 default).
    func test_reverbMonoSendAndFluidSynthReturn() {
        var a = SF2EffectsRT(sr: 44100), b = SF2EffectsRT(sr: 44100)
        defer { a.free(); b.free() }
        XCTAssertEqual(a.reverbWet, Float(2.7))
        let panned = impulseResponse(&a, 0.25, 0.75), centre = impulseResponse(&b, 1, 0)
        XCTAssertEqual(panned, centre, "only L + R reaches the combs")
        XCTAssertGreaterThan(panned.map { abs($0) }.max()!, 0.001)
        // reverbLevel scales the return linearly: 1 -> 5.4 (twice the default 0.5)
        var c = SF2EffectsRT(sr: 44100); defer { c.free() }
        c.setParams(SF2EffectsParams(reverbLevel: 1))
        XCTAssertEqual(c.reverbWet, Float(5.4))
        let loud = impulseResponse(&c, 1, 0)
        for i in stride(from: 0, to: loud.count, by: 37) { XCTAssertEqual(loud[i], 2 * centre[i], accuracy: 1e-6) }
    }

    func test_setEffectParamsClampsAndSwitches() {
        var fx = SF2EffectsRT(sr: 48000); defer { fx.free() }
        fx.setParams(SF2EffectsParams(roomSize: 2, damping: -1, chorusLevel: 0.3, chorusDepthMs: 10, chorusRateHz: 100, chorusDelayMs: 5))
        XCTAssertEqual(fx.roomFeedback, Float(0.98)); XCTAssertEqual(fx.damp, 0)
        XCTAssertEqual(fx.chorusWet, 0.3); XCTAssertEqual(fx.chorusRateHz, 10)
        XCTAssertEqual(fx.chorusBaseSec, 0.005, accuracy: 1e-12)
        XCTAssertEqual(fx.chorusDepthSec, 0.0045, accuracy: 1e-12, "depth kept inside the base delay")
        // defaults reproduce the initial state
        var d = SF2EffectsRT(sr: 48000); defer { d.free() }
        let r0 = d.roomFeedback, d0 = d.damp, w0 = d.reverbWet
        d.setParams(.defaults)
        XCTAssertEqual(d.roomFeedback, r0); XCTAssertEqual(d.damp, d0); XCTAssertEqual(d.reverbWet, w0)
        let e = Sf2SynthEngine(outSr: 44100)
        e.setEffectParams(SF2EffectsParams(enabled: false)); XCTAssertFalse(e.effectsEnabled)
        e.setEffectParams(SF2EffectsParams(enabled: true)); XCTAssertTrue(e.effectsEnabled)
    }
}
