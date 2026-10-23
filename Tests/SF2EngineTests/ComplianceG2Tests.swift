// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Matrix rows G-05...G-08, G-13, S-09, S-10 (measured on rendered audio where practical).
final class ComplianceG2Tests: XCTestCase {
    typealias B = SF2Builder
    typealias A = Analysis
    let sr = 44100.0

    private func dcLevels(_ gens: [(Int, Int)], key: Int = 60, frames: Int) throws -> [Double] {
        let r = try SpecRender(B.single(B.dc(8000), loop: (100, 7900), instGens: [(Gen.sampleModes, 1)] + gens))
        r.noteOn(key)
        let out = r.render(frames).l
        let peak = out.map { abs(Double($0)) }.max()!
        return out.map { A.db(abs(Double($0)) / peak) }
    }

    func test_G05_keynumEnvelopeScaling() throws {
        // 8.1.2 #39 example: hold -7973 tc, keynumToVolEnvHold 50, key 36 -> 2^((-7973 + 50 * 24)/1200) = 20 ms.
        let e = try dcLevels([(Gen.holdVolEnv, -7973), (Gen.keynumToVolEnvHold, 50), (Gen.decayVolEnv, -1200), (Gen.sustainVolEnv, 1000),
                              (Gen.attackVolEnv, -12000)], key: 36, frames: 4410)
        let holdEnd = e.indices.first { $0 > 100 && e[$0] < -0.1 }!
        // decay -1200 tc = 0.5 s per 100 dB: -0.1 dB is reached 0.5 ms after the hold ends; attack + delay 2 ms
        XCTAssertEqual(Double(holdEnd) / sr, 0.002 + 0.020 + 0.0005, accuracy: 0.001)
        // key 60: no scaling -> hold = 2^(-7973/1200) = 10 ms
        let e60 = try dcLevels([(Gen.holdVolEnv, -7973), (Gen.keynumToVolEnvHold, 50), (Gen.decayVolEnv, -1200), (Gen.sustainVolEnv, 1000)],
                               frames: 4410)
        XCTAssertEqual(Double(e60.indices.first { $0 > 100 && e60[$0] < -0.1 }!) / sr, 0.002 + 0.01 + 0.0005, accuracy: 0.001)
        // decay scaling (#40; the spec text says "hold": erratum): keynumToVolEnvDecay 100, key 48 -> decay x2
        let d = try dcLevels([(Gen.decayVolEnv, -1200), (Gen.keynumToVolEnvDecay, 100), (Gen.sustainVolEnv, 1000)], key: 48, frames: 44100)
        XCTAssertEqual(d[Int((0.002 + 0.5) * sr)], -50, accuracy: 0.2, "decay 1 s per 100 dB after doubling")
        // mod-env key scaling reaches the voice (keynumToModEnvHold / Decay)
        let r = try SpecRender(B.single(B.dc(800), loop: (10, 790), instGens: [(Gen.sampleModes, 1), (Gen.holdModEnv, -1200),
                                                                              (Gen.keynumToModEnvHold, 100), (Gen.decayModEnv, 0),
                                                                              (Gen.keynumToModEnvDecay, -100)]))
        r.noteOn(48)
        let v = r.engine.st.pointee.voices[Int(r.engine.st.pointee.order[0])]
        XCTAssertEqual(v.modEnv.hold, 1.0, accuracy: 1e-9); XCTAssertEqual(v.modEnv.decay, 0.5, accuracy: 1e-9)
    }

    func test_G06_lfoTriangleFrequencyAndPhase() throws {
        // mod LFO -> volume +-60 cB, 16.352 Hz (1200 cents), 0.25 s delay (-2400 tc). Positive excursion = louder.
        let f = 8.176 * 2
        let e = try dcLevels([(Gen.modLfoToVolume, 60), (Gen.freqModLFO, 1200), (Gen.delayModLFO, -2400)], frames: 44100)
        let base = e[Int(0.2 * sr)]
        func at(_ t: Double) -> Double { e[Int((0.25 + t) * sr)] - base }
        XCTAssertEqual(at(0.0005), 6 * 4 * f * 0.0005, accuracy: 0.05, "starts at 0 after the delay, rising")
        XCTAssertEqual(at(1 / (4 * f)), 6, accuracy: 0.1, "rises to +1 first (quarter period)")
        XCTAssertEqual(at(1 / (2 * f)), 0, accuracy: 0.1)
        XCTAssertEqual(at(3 / (4 * f)), -6, accuracy: 0.1, "then down to -1")
        XCTAssertEqual(at(1 / f + 1 / (8 * f)), 3, accuracy: 0.1, "triangle: linear between extremes")
        // vibrato LFO -> pitch only: at a quarter period the pitch is +vibLfoToPitch
        let r = try SpecRender(B.single(B.sine(cycles: 100, n: 4410), loop: (0, 4410),
                                        instGens: [(Gen.sampleModes, 1), (Gen.vibLfoToPitch, 100), (Gen.freqVibLFO, -2400)]))
        r.noteOn(60)
        let o = r.render(44100).l
        // 2.044 Hz: quarter period 122 ms; measure f0 over +-5 ms around the crest
        let crest = Int((0.002 + 1 / (4 * 2.044)) * sr)
        // average of the triangle over the +-5 ms window around its crest: 1 - 2 f w
        XCTAssertEqual(A.cents(A.f0ZeroCrossing(o, sampleRate: sr, from: crest - 220, count: 441), 1000), 100 * (1 - 2 * 2.044 * 0.005), accuracy: 1)
        XCTAssertEqual(A.rmsDB(o, from: 20000, count: 4410) - A.rmsDB(o, from: 4410, count: 4410), 0, accuracy: 0.1, "no level change")
    }

    func test_G07_modEnvToPitchAndFc() throws {
        // sustain 0.5 x modEnvToFilterFc +1200 on a 6000-cent cutoff -> 6600 cents at sustain
        let r = try SpecRender(B.single(B.dc(800), loop: (10, 790), instGens: [(Gen.sampleModes, 1), (Gen.initialFilterFc, 6000),
                                                                              (Gen.modEnvToFilterFc, 1200), (Gen.sustainModEnv, 500)]))
        r.noteOn(60)
        _ = r.render(441)
        XCTAssertEqual(r.engine.st.pointee.voices[Int(r.engine.st.pointee.order[0])].lastFc, 6000 + 0.5 * 1200, accuracy: 1e-9)
        // pitch: measured in test_G04 (modEnvToPitch 1200 x sustain 0.5 = +600 cents)
    }

    /// Steady-state amplitude of a looped sine at `hz` through the voice filter (relative to unfiltered).
    private func response(hz: Double?, fcCents: Int, qCb: Int) throws -> Double {
        let wave = hz.map { B.sine(cycles: Int($0 / 10), n: 4410) } ?? B.dc(4410)
        func render(_ gens: [(Int, Int)]) throws -> [Float] {
            let r = try SpecRender(B.single(wave, loop: (0, 4410), instGens: [(Gen.sampleModes, 1)] + gens))
            r.noteOn(60)
            return r.render(22050).l
        }
        let f = try render([(Gen.initialFilterFc, fcCents), (Gen.initialFilterQ, qCb)]), u = try render([])
        if let hz { return A.db(A.goertzel(f, freq: hz, sampleRate: sr, from: 4410, count: 17640) / A.goertzel(u, freq: hz, sampleRate: sr, from: 4410, count: 17640)) }
        return A.rmsDB(f, from: 4410) - A.rmsDB(u, from: 4410)
    }

    func test_G08_filterDcAndPeak() throws {
        let fc = 1000.0
        let cents = Int((1200 * log2(fc / 8.176)).rounded())
        // Q = 100 cB: DC -5 dB, peak at fc +5 dB (re unity), 2 fc ~ analog 2-pole response - 5 dB. Tolerance +-1 dB (9.7).
        XCTAssertEqual(try response(hz: nil, fcCents: cents, qCb: 100), -5, accuracy: 1)
        XCTAssertEqual(try response(hz: fc, fcCents: cents, qCb: 100), 5, accuracy: 1)
        let g = pow(10, 0.5), q = ((g * g + g * (g * g - 1).squareRoot()) / 2).squareRoot()
        let analog2fc = A.db(1 / ((1 - 4.0) * (1 - 4.0) + 4 / (q * q)).squareRoot()) - 5
        XCTAssertEqual(try response(hz: 2 * fc, fcCents: cents, qCb: 100), analog2fc, accuracy: 1)
        // Q = 0: Butterworth, -3 dB at fc, DC unity
        XCTAssertEqual(try response(hz: nil, fcCents: cents, qCb: 0), 0, accuracy: 0.1)
        XCTAssertEqual(try response(hz: fc, fcCents: cents, qCb: 0), -3.01, accuracy: 1)
        // Fc 13500 cents (~19.9 kHz >= 0.45 sr) with Q 0: bypassed, flat (exactly unity at 10 kHz)
        XCTAssertEqual(try response(hz: 10000, fcCents: 13500, qCb: 0), 0, accuracy: 0.01)
    }

    func test_G13_nonRealtimeGeneratorsFixedAtNoteOn() throws {
        // CC2 -> scaleTuning (#56, '@'): applies at note-on, not while sounding; CC1 -> attenuation (real-time) does.
        let b = B.single(B.sine(cycles: 100, n: 4410), loop: (0, 4410), instGens: [(Gen.sampleModes, 1)],
                         instMods: [.init(src: 0x0082, dest: 56, amount: -128)])  // CC2 (CC1 has the default vibrato modulator)
        let r = try SpecRender(b)
        r.cc(2, 64)                      // scaleTuning 100 - 64 = 36 at note-on
        r.noteOn(72)
        var o = r.render(22050).l
        XCTAssertEqual(A.cents(A.f0ZeroCrossing(o, sampleRate: sr, from: 2000), 1000), 12 * 36, accuracy: 1)
        r.cc(2, 0)
        o = r.render(22050).l
        XCTAssertEqual(A.cents(A.f0ZeroCrossing(o, sampleRate: sr, from: 2000), 1000), 12 * 36, accuracy: 1, "fixed at note-on")
        // NRPN cannot select non-real-time generators (N-03) and modulators cannot target index/range/sample ones (M-06).
        XCTAssertFalse(GenInfo.get(Gen.scaleTuning)!.realtime)
        for g in [43, 44, 46, 47, 54, 56, 57, 58] { XCTAssertFalse(GenInfo.get(g)!.realtime, "\(g)") }
    }

    func test_S09_loopSanityPolicy() throws {
        func region(_ loop: (Int, Int)) throws -> SF2Region {
            try SF2SoundFont(data: B.single(B.dc(100), loop: loop, instGens: [(Gen.sampleModes, 1)]).build(), options: .strict)
                .buildRegionsForPreset(0, fidelity: .spec)[0]
        }
        XCTAssertEqual(try region((50, 51)).sampleModes, 0, "loop shorter than 2 points: unlooped")
        XCTAssertEqual(try region((60, 40)).sampleModes, 0, "inverted loop: unlooped")
        let short = try region((10, 20))
        XCTAssertEqual(short.sampleModes, 1, "loops < 32 points / no guard points still loop (7.10 'may')")
        XCTAssertEqual(short.sample.loopStart, 10); XCTAssertEqual(short.sample.loopEnd, 20)
        // measured: the loop plays [loopStart, loopEnd), the loop end point itself is never played (6.2)
        let ramp = (0 ..< 100).map { Int16($0 * 100) }
        let r = try SpecRender(B.single(ramp, loop: (10, 20), instGens: [(Gen.sampleModes, 1)]))
        r.noteOn(60)
        let o = r.render(400).l
        let tailMax = o[200...].map { abs($0) }.max()!, tailMin = o[200...].map { abs($0) }.min()!
        XCTAssertEqual(Double(tailMin / tailMax), 10.0 / 19, accuracy: 0.01, "values 10...19 only")
    }

    func test_S10_stereoPairsOneVoicePerZone() throws {
        var b = B()
        b.samples = B.sine(cycles: 100, n: 4410) + [Int16](repeating: 0, count: 46) + B.dc(4410, level: -8000) + [Int16](repeating: 0, count: 46)
        b.sampleHeaders = [.init(name: "L", start: 0, end: 4410, loopStart: 0, loopEnd: 4410, link: 1, type: 4),
                           .init(name: "R", start: 4456, end: 8866, loopStart: 4456, loopEnd: 8866, link: 0, type: 2)]
        b.instruments = [("st", [.init(gens: [(Gen.sampleModes, 1)]),
                                 .init(gens: [(Gen.pan, -500), (Gen.coarseTune, 12), (Gen.sampleID, 0)]),
                                 .init(gens: [(Gen.pan, 500), (Gen.sampleID, 1)])])]
        b.presets = [("p", 0, 0, [.init(gens: [(Gen.instrument, 0)])])]
        let r = try SpecRender(b)
        r.noteOn(60)
        XCTAssertEqual(r.engine.st.pointee.count, 2, "one voice per zone (no doubled stereo voices)")
        let o = r.render(22050)
        XCTAssertEqual(A.cents(A.f0ZeroCrossing(o.l, sampleRate: sr, from: 2000), 1000), 0, accuracy: 1,
                       "left voice uses the right zone's pitch (its own coarse +12 is replaced)")
        XCTAssertLessThan(o.r[1000...].max()!, 0, "right channel: only the right sample (negative DC), panned by its own zone")
        XCTAssertLessThan(abs(A.goertzel(o.r, freq: 1000, sampleRate: sr, from: 2000, count: 19845)), 1e-5, "no left-sample content on the right")
        // invalid link (partner type not complementary) -> mono: own pitch kept
        var bad = b; bad.sampleHeaders[1].type = 1
        let m = try SpecRender(bad); m.noteOn(60)
        XCTAssertEqual(A.cents(A.f0ZeroCrossing(m.render(22050).l, sampleRate: sr, from: 2000), 2000), 0, accuracy: 1)
        // linkedSample (8) is undefined in 2.01 -> mono
        var linked = b; linked.sampleHeaders[0].type = 8; linked.sampleHeaders[1].type = 8
        let k = try SpecRender(linked); k.noteOn(60)
        XCTAssertEqual(A.cents(A.f0ZeroCrossing(k.render(22050).l, sampleRate: sr, from: 2000), 2000), 0, accuracy: 1)
    }
}
