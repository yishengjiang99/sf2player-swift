// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Matrix rows G-xx and render-measured S-xx / MIDI-xx: the synthesis model, measured on audio.
final class ComplianceGTests: XCTestCase {
    typealias B = SF2Builder
    typealias A = Analysis

    /// 1 kHz looping sine at 44.1 kHz, root key 60 (100 cycles in 4410 points).
    private func sineBank(_ instGens: [(Int, Int)] = [], pitch: Int = 60) -> B {
        B.single(B.sine(cycles: 100, n: 4410), loop: (0, 4410), pitch: pitch, instGens: [(Gen.sampleModes, 1)] + instGens)
    }
    private func f0(_ b: B, key: Int) throws -> Double {
        let r = try SpecRender(b)
        r.noteOn(key)
        let out = r.render(r.seconds(0.6))
        return A.f0ZeroCrossing(out.l, sampleRate: 44100, from: 2205)
    }

    func test_G01_measuredPitch() throws {
        let cases: [([(Int, Int)], Int, Double, String)] = [
            ([], 60, 1000, "root"),
            ([], 72, 2000, "octave up"),
            ([(Gen.scaleTuning, 50)], 72, 1000 * pow(2, 0.5), "scaleTuning 50"),
            ([(Gen.scaleTuning, 0)], 84, 1000, "scaleTuning 0"),
            ([(Gen.coarseTune, -4)], 60, 1000 * pow(2, -4.0 / 12), "coarse -4"),
            ([(Gen.fineTune, -5)], 60, 1000 * pow(2, -5.0 / 1200), "fine -5"),
            ([(Gen.overridingRootKey, 69)], 69, 1000, "overridingRootKey 69 (8.1.2 #58)"),
        ]
        for (gens, key, hz, label) in cases {
            let got = try f0(sineBank(gens), key: key)
            XCTAssertEqual(A.cents(got, hz), 0, accuracy: 1, "\(label): \(got) Hz")
        }
        // autocorrelation estimator agrees
        let r = try SpecRender(sineBank()); r.noteOn(60)
        XCTAssertEqual(A.cents(A.f0Autocorrelation(r.render(20000).l, sampleRate: 44100, from: 4000), 1000), 0, accuracy: 1)
        // sample rate ratio: a 22050 Hz sample plays an octave lower
        var half = sineBank(); half.sampleHeaders[0].rate = 22050
        XCTAssertEqual(A.cents(try f0(half, key: 60), 500), 0, accuracy: 1)
    }

    func test_S07_pitchCorrectionMeasured() throws {
        var b = sineBank(); b.sampleHeaders[0].corr = -4
        XCTAssertEqual(A.cents(try f0(b, key: 60), 1000), -4, accuracy: 1)
    }

    func test_G09_initialAttenuation() throws {
        func level(_ cb: Int) throws -> Double {
            let r = try SpecRender(B.single(B.dc(4000), loop: (100, 3900), instGens: [(Gen.sampleModes, 1), (Gen.initialAttenuation, cb)]))
            r.noteOn(60)
            return A.rmsDB(r.render(4000).l, from: 2000)
        }
        let ref = try level(0)
        for cb in [60, 200, 480, 960] { XCTAssertEqual(try level(cb) - ref, -Double(cb) / 10, accuracy: 0.1, "\(cb) cB") }
    }

    func test_G10_linearPanLaw() throws {
        var sums: [Double] = []
        for (pan, lShare) in [(-500, 1.0), (-250, 0.75), (0, 0.5), (250, 0.25), (500, 0.0)] {
            let r = try SpecRender(B.single(B.dc(4000, level: 16384), loop: (100, 3900), instGens: [(Gen.sampleModes, 1), (Gen.pan, pan)]))
            r.noteOn(60)
            let o = r.render(3000)
            let l = Double(o.l[2000]), rr = Double(o.r[2000])
            XCTAssertEqual(l / (l + rr), lShare, accuracy: 0.0058, "pan \(pan): 8.1.2 #17 linear law") // ~0.1 dB at 50 %
            sums.append(l + rr)
        }
        for s in sums { XCTAssertEqual(A.db(s / sums[2]), 0, accuracy: 0.1, "L + R amplitude constant (linear law)") }
    }

    func test_S03_signedAddressOffsets() throws {
        let ramp = (0 ..< 200).map { Int16($0 * 100) }
        func region(_ gens: [(Int, Int)]) throws -> SF2Region {
            var b = B.single(ramp, loop: (50, 150), instGens: gens)
            b.samples += (0 ..< 100).map { _ in Int16(-7) }           // a neighbor sample's data
            b.sampleHeaders.append(.init(name: "n", start: 246, end: 346, loopStart: 0, loopEnd: 0))
            return try SF2SoundFont(data: b.build(), options: .strict).buildRegionsForPreset(0, normalize: false, fidelity: .spec)[0]
        }
        var r = try region([(Gen.startAddrsOffset, 10)])
        XCTAssertEqual(r.sample.dataL[0], Float(1000) / 32768); XCTAssertEqual(r.sample.end, 190)
        r = try region([(Gen.startAddrsOffset, -20)])               // negative: clamped to the sample's start, not wrapped
        XCTAssertEqual(r.sample.dataL.count, 200); XCTAssertEqual(r.sample.dataL[0], 0)
        r = try region([(Gen.endAddrsOffset, 80)])                  // cannot extend into the neighbor
        XCTAssertEqual(r.sample.dataL.count, 200)
        XCTAssertFalse((0 ..< r.sample.dataL.count).contains { r.sample.dataL[$0] == Float(-7) / 32768 })
        r = try region([(Gen.endAddrsOffset, -50)])
        XCTAssertEqual(r.sample.dataL.count, 150)
        r = try region([(Gen.startloopAddrsOffset, -10), (Gen.endloopAddrsOffset, 5)])
        XCTAssertEqual(r.sample.loopStart, 40); XCTAssertEqual(r.sample.loopEnd, 155)
        r = try region([(Gen.endAddrsCoarseOffset, -1)])            // -32768: clamped, start < end kept
        XCTAssertGreaterThan(r.sample.end, r.sample.start)
    }

    func test_S04_zeroSampleRate() throws {
        var b = sineBank(); b.sampleHeaders[0].rate = 0
        let r = try SpecRender(b); r.noteOn(60)
        let o = r.render(4410)
        XCTAssertTrue(o.l.allSatisfy(\.isFinite))
        let reg = try SF2SoundFont(data: b.build(), options: .strict).buildRegionsForPreset(0, fidelity: .spec)[0]
        XCTAssertEqual(reg.sample.sampleRate, 400, "nearest practical value")
    }

    func test_S08_sampleModesLowBits() throws {
        func sounding(_ mode: Int, frames: Int = 3000) throws -> Double {
            let r = try SpecRender(B.single(B.dc(200), loop: (20, 180), instGens: [(Gen.sampleModes, mode)]))
            r.noteOn(60)
            return A.rmsDB(r.render(frames).l, from: frames - 200)
        }
        XCTAssertGreaterThan(try sounding(1), -20)
        XCTAssertGreaterThan(try sounding(5), -20, "only the low two bits count: 5 -> 1")
        XCTAssertLessThan(try sounding(0), -200)
        XCTAssertLessThan(try sounding(2), -200, "2 = no loop")
        XCTAssertLessThan(try sounding(6), -200)
        // mode 3: loops while held; after key-off plays through to the end.
        let r = try SpecRender(B.single(B.dc(200), loop: (20, 180), instGens: [(Gen.sampleModes, 3), (Gen.releaseVolEnv, 1200)]))
        r.noteOn(60)
        XCTAssertGreaterThan(A.rmsDB(r.render(3000).l, from: 2800), -20)
        r.noteOff(60)
        let tail = r.render(1000).l
        XCTAssertLessThan(A.rmsDB(tail, from: 400), -200, "sample end reached within one pass (< 200 frames)")
    }

    func test_S11_readPastEndIsSilent() throws {
        var b = B.single(B.dc(100), instGens: [(Gen.releaseVolEnv, 1200)])
        b.samples = B.dc(100) + B.dc(46, level: 30000) // guard points deliberately non-zero
        let r = try SpecRender(b); r.noteOn(60)
        let o = r.render(400)
        XCTAssertEqual(o.l[150], 0); XCTAssertEqual(o.l[399], 0)
    }

    func test_MIDI01_velocityZeroIsNoteOff() throws {
        let r = try SpecRender(B.single(B.dc(4000), loop: (100, 3900), instGens: [(Gen.sampleModes, 1)]))
        r.noteOn(60)
        _ = r.render(100)
        r.noteOn(60, velocity: 0)
        XCTAssertLessThan(A.rmsDB(r.render(6000).l, from: 5800), -90)
    }
}
