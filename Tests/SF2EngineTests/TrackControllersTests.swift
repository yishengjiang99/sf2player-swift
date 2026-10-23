// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Track CC7 / CC10 / CC11 reach the audio through channel controller state and the 2.01 default
/// modulators (8.4.5 / 8.4.6 / 8.4.7). Mirrors gbk test/track-controllers.test.ts.
final class TrackControllersTests: XCTestCase {
    typealias B = SF2Builder
    let sr = 44100.0

    private func regions() throws -> SF2RegionList {
        let b = B.single(B.sine(cycles: 100, n: 4410, amp: 16000), loop: (0, 4410), instGens: [(Gen.sampleModes, 1)])
        return try SF2SoundFont(data: b.build(), options: .strict).regionList(forPreset: 0)
    }
    private func engine() -> Sf2SynthEngine {
        let e = Sf2SynthEngine(outSr: sr, maxVoices: 16)
        e.masterDynamicsEnabled = false; e.masterGainDb = 0; e.effectsEnabled = false
        return e
    }
    private func measure(_ e: Sf2SynthEngine) -> (l: Double, r: Double) {
        let n = 8192 + 4096
        var L = [Float](repeating: 0, count: n), R = L
        e.renderRange(&L, &R)
        func db(_ x: [Float]) -> Double { var s = 0.0; for i in 8192 ..< n { s += Double(x[i]) * Double(x[i]) }; return 10 * log10(s / 4096 + 1e-30) }
        return (db(L), db(R))
    }
    private func trackRender(cc7: Double? = nil, cc10: Double? = nil, cc11: Double? = nil) throws -> (Sf2SynthEngine, (l: Double, r: Double)) {
        let e = engine()
        e.setTrackStates([SF2TrackState(trackIndex: 0, regions: try regions(), cc7Volume: cc7, cc10Pan: cc10, cc11Expression: cc11)])
        e.dispatchEvent(.noteOn(60, velocity: 127, trackIndex: 0, channel: 3))
        return (e, measure(e))
    }
    private func attDb(_ v: Double) -> Double { 40 * log10(128 / (v + 1)) }
    private func drop(_ v: Double) -> Double { attDb(v) - attDb(127) }

    func testCC7Level() throws {
        let full = try trackRender(cc7: 127).1
        for v in [100.0, 64, 32] {
            let m = try trackRender(cc7: v).1
            XCTAssertEqual(full.l - m.l, drop(v), accuracy: 0.1, "cc7=\(v)")
        }
        XCTAssertLessThan(try trackRender(cc7: 0).1.l, full.l - 80)
    }

    func testCC11LevelStacks() throws {
        let full = try trackRender(cc7: 127, cc11: 127).1
        XCTAssertEqual(full.l - (try trackRender(cc7: 127, cc11: 64).1.l), drop(64), accuracy: 0.1)
        XCTAssertEqual(full.l - (try trackRender(cc7: 64, cc11: 64).1.l), 2 * drop(64), accuracy: 0.2)
    }

    func testCC10Pan() throws {
        let c = try trackRender(cc10: 64).1
        XCTAssertEqual(c.l, c.r, accuracy: 0.2)
        let left = try trackRender(cc10: 0).1, right = try trackRender(cc10: 127).1
        XCTAssertGreaterThan(left.l - left.r, 30)
        XCTAssertGreaterThan(right.r - right.l, 30)
    }

    func testLiveSetControllers() throws {
        let (e, before) = try trackRender(cc7: 127)
        e.dispatchEvent(.setControllers(trackIndex: 0, cc7Volume: 64))
        let after = measure(e)
        XCTAssertEqual(before.l - after.l, drop(64), accuracy: 0.3)
        e.dispatchEvent(.setControllers(trackIndex: 0, cc10Pan: 0))
        let p = measure(e)
        XCTAssertGreaterThan(p.l - p.r, 30)

        let g = engine()
        g.setTrackStates([SF2TrackState(trackIndex: 0, regions: try regions())])
        g.dispatchEvent(.noteOn(60, velocity: 127, trackIndex: 0, channel: 5))
        g.dispatchEvent(.setControllers(cc7Volume: 127))
        let a = measure(g)
        g.dispatchEvent(.setControllers(cc11Expression: 64))
        let b = measure(g)
        g.dispatchEvent(.setControllers(cc10Pan: 127))
        let c = measure(g)
        XCTAssertEqual(g.controller(7, channel: 5), 127); XCTAssertEqual(g.controller(11, channel: 9), 64)
        XCTAssertEqual(a.r - b.r, drop(64), accuracy: 0.3)
        XCTAssertGreaterThan(c.r - c.l, 30)
    }

    func testDefaultsDoNotClobberInStreamCCs() throws {
        for explicit in [false, true] {
            let e = engine()
            e.setTrackStates([explicit
                ? SF2TrackState(trackIndex: 0, regions: try regions(), cc7Volume: 100, cc10Pan: 64, cc11Expression: 127)
                : SF2TrackState(trackIndex: 0, regions: try regions())])
            e.dispatchEvent(.controlChange(7, value: 40, trackIndex: 0, channel: 2))
            e.dispatchEvent(.noteOn(60, velocity: 127, trackIndex: 0, channel: 2))
            XCTAssertEqual(e.controller(7, channel: 2), 40)
        }
    }
}
