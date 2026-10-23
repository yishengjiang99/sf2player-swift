// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Master bus (non-normative): gain, compressor, lookahead limiter, safety clip. Mirrors gbk test/master-bus.test.ts.
final class MasterBusTests: XCTestCase {
    typealias B = SF2Builder
    typealias A = Analysis
    let sr = 44100.0
    var ceiling: Double { pow(10, MasterBusParams().ceilingDb / 20) }

    private func engine(_ b: B, dyn: Bool? = nil, gainDb: Double? = nil) throws -> Sf2SynthEngine {
        let sf = try SF2SoundFont(data: b.build(), options: .strict)
        let e = Sf2SynthEngine(outSr: sr, maxVoices: 64)
        if let dyn { e.masterDynamicsEnabled = dyn }
        if let gainDb { e.masterGainDb = gainDb }
        e.setTrackStates([SF2TrackState(trackIndex: 0, regions: try sf.regionList(forPreset: 0))])
        return e
    }
    private func loud() -> B {
        B.single(B.sine(cycles: 100, n: 4410, amp: 32000), loop: (0, 4410),
                 instGens: [(Gen.sampleModes, 1), (Gen.reverbEffectsSend, 1000), (Gen.chorusEffectsSend, 1000)])
    }
    private func render(_ e: Sf2SynthEngine, _ n: Int) -> ([Float], [Float]) {
        var l = [Float](repeating: 0, count: n), r = l
        e.renderRange(&l, &r)
        return (l, r)
    }
    private func on(_ e: Sf2SynthEngine, _ k: Int) { e.dispatchEvent(.noteOn(k, velocity: 127, trackIndex: 0, channel: 0)) }

    func testDefaults() {
        let e = Sf2SynthEngine(outSr: sr)
        XCTAssertEqual(e.masterGainDb, -3); XCTAssertTrue(e.masterDynamicsEnabled)
        XCTAssertEqual(e.masterParams, MasterBusParams())
        let p = MasterBusParams()
        XCTAssertEqual([p.thresholdDb, p.ratio, p.kneeDb, p.attackMs, p.releaseMs, p.ceilingDb, p.limiterReleaseMs, p.lookaheadMs],
                       [-6, 4, 6, 5, 100, -0.3, 50, 1.5])
        XCTAssertEqual(e.masterLatencyFrames, 66)
    }

    func testDenseLoudChordStaysBelowCeiling() throws {
        for g in [-3.0, 0, 12, 40] {
            let e = try engine(loud(), gainDb: g)
            for k in 36 ..< 84 { on(e, k) }
            let (l, r) = render(e, Int(sr))
            var m: Float = 0
            for i in l.indices { XCTAssertTrue(l[i].isFinite && r[i].isFinite); m = max(m, abs(l[i]), abs(r[i])) }
            XCTAssertLessThanOrEqual(m, Float(ceiling), "gain \(g)")
            XCTAssertLessThan(m, 1)
            if g >= 12 { XCTAssertGreaterThan(m, 0.9) }
        }
        let off = try engine(loud(), dyn: false, gainDb: 0)
        for k in 36 ..< 84 { on(off, k) }
        XCTAssertGreaterThan(A.peakDB(render(off, Int(sr)).0), 0, "control: without the stage it clips")
    }

    func testQuietPassesAtGainOnly() throws {
        let q = { B.single(B.sine(cycles: 100, n: 4410, amp: 600), loop: (0, 4410), instGens: [(Gen.sampleModes, 1)]) }
        let a = try engine(q()), b = try engine(q(), dyn: false, gainDb: 0)
        on(a, 60); on(b, 60)
        let x = render(a, Int(sr)).0, y = render(b, Int(sr)).0
        XCTAssertEqual(A.rmsDB(x, from: 22050, count: 8820) - A.rmsDB(y, from: 22050, count: 8820), -3, accuracy: 0.01)
        let d = a.masterLatencyFrames
        for i in 10000 ..< 10100 { XCTAssertEqual(Double(x[i]), Double(y[i - d]) * pow(10, -3.0 / 20), accuracy: 1e-6) }
    }

    func testAttackReleaseWithin2Percent() {
        for (att, rel) in [(5.0, 100.0), (20.0, 300.0)] {
            var p = MasterBusParams(); p.attackMs = att; p.releaseMs = rel; p.lookaheadMs = 0
            var m = MasterBusRT(sampleRate: sr, params: p); defer { m.free() }
            for _ in 0 ..< Int(sr) { m.process(0.01, 0.01) }
            let target = MasterBusRT.reductionDb(0, -6, 4, 6)
            XCTAssertEqual(target, 4.5, accuracy: 1e-12)
            var i = 0
            while m.compressorReductionDb < (1 - exp(-1)) * target { m.process(1, -1); i += 1 }
            XCTAssertEqual(Double(i) / sr * 1000, att, accuracy: 0.02 * att)
            for _ in 0 ..< Int(sr) { m.process(1, -1) }
            i = 0
            while m.compressorReductionDb > exp(-1) * target { m.process(0.01, 0.01); i += 1 }
            XCTAssertEqual(Double(i) / sr * 1000, rel, accuracy: 0.02 * rel)
        }
    }

    func testLimiterBrickwallLookaheadRelease() {
        var p = MasterBusParams(); p.thresholdDb = 0; p.ratio = 1
        var m = MasterBusRT(sampleRate: sr, params: p); defer { m.free() }
        let la = m.latencyFrames
        var out: [Double] = []
        for i in 0 ..< Int(sr) { m.process(i >= 1000 && i < 1010 ? 4 : 0.5, 0); out.append(m.outL) }
        for v in out { XCTAssertLessThanOrEqual(abs(v), ceiling) }
        XCTAssertGreaterThan(out[1000 + la], 0.9 * ceiling)
        XCTAssertEqual(out[1000 + la - 1], 0.5 * ceiling / 4, accuracy: 1e-12, "lookahead: gain down before the spike")
        let after = 1010 + la, g0 = ceiling / 4
        let t63 = out.indices.first { $0 > after && out[$0] >= 0.5 * (g0 + (1 - g0) * (1 - exp(-1))) }!
        XCTAssertEqual(Double(t63 - after) / sr * 1000, 50, accuracy: 1)
        XCTAssertEqual(out.last!, 0.5, accuracy: 1e-6)
    }

    func testRecoversAfterLoudHit() {
        var m = MasterBusRT(sampleRate: sr); defer { m.free() }
        for _ in 0 ..< 4410 { m.process(3, 3) }
        XCTAssertGreaterThan(m.gainReductionDb, 6)
        for _ in 0 ..< 3 * Int(sr) { m.process(0.05, 0.05) }
        XCTAssertEqual(m.gainReductionDb, 0)
        XCTAssertEqual(m.outL, 0.05, accuracy: 1e-9)
    }

    func testNoNaNInfDenormal() {
        var m = MasterBusRT(sampleRate: sr); defer { m.free() }
        let inputs: [Double] = [.nan, .infinity, -.infinity, 1e300, -1e300, 1e-320, -5e-324, 0, 1e5]
        for k in 0 ..< 2000 {
            let x = inputs[k % inputs.count]
            m.process(x, -x)
            XCTAssertTrue(m.outL.isFinite && m.outR.isFinite)
            XCTAssertLessThanOrEqual(abs(m.outL), ceiling); XCTAssertLessThanOrEqual(abs(m.outR), ceiling)
        }
        for _ in 0 ..< 10 * Int(sr) { m.process(1e-310, 1e-310) }
        XCTAssertEqual(m.compressorReductionDb, 0); XCTAssertEqual(m.gainReductionDb, 0)
        for c in [ceiling, 0.5, 0.999] { for x in [0, 0.1, 0.89 * c, c, 2, 1e9, -1e9] {
            let y = MasterBusRT.softClip(x, c)
            XCTAssertLessThanOrEqual(abs(y), c); XCTAssertLessThan(abs(y), 1)
            if abs(x) <= 0.9 * c { XCTAssertEqual(y, x) }
        } }
        XCTAssertEqual(MasterBusRT.softClip(.nan, ceiling), 0)
    }

    func testMisconfigurationNeverReachesOne() throws {
        let e = try engine(loud(), gainDb: 60)
        var p = MasterBusParams(); p.ratio = 1; p.limiterReleaseMs = 0; p.lookaheadMs = 0; p.ceilingDb = 5
        e.masterParams = p
        for k in 48 ..< 72 { on(e, k) }
        let (l, r) = render(e, 22050)
        for i in l.indices { XCTAssertLessThan(abs(l[i]), 1); XCTAssertLessThan(abs(r[i]), 1) }
    }
}
