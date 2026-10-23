// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// P-99: random mutations / truncations of fixture banks never trap, hang or read out of bounds.
final class FuzzTests: XCTestCase {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func fixtures() -> [[UInt8]] {
        typealias B = SF2Builder
        var a = B.single(B.sine(cycles: 10, n: 441), loop: (0, 441), instGens: [(Gen.sampleModes, 1), (Gen.pan, -200)],
                         presetGens: [(Gen.coarseTune, 2)], instMods: [.init(src: 0x0081, dest: 34, amount: 100)])
        a.instruments[0].1.insert(.init(gens: [(Gen.attackVolEnv, -1200)]), at: 0)
        var stereo = B.single(B.dc(200), loop: (10, 190))
        stereo.samples += B.dc(246, level: -3000)
        stereo.sampleHeaders[0].link = 1; stereo.sampleHeaders[0].type = 4
        stereo.sampleHeaders.append(.init(name: "R", start: 246, end: 446, loopStart: 256, loopEnd: 436, link: 0, type: 2))
        stereo.instruments[0].1.append(.init(gens: [(Gen.pan, 500), (Gen.sampleID, 1)]))
        var multi = B.single(B.noise(300), loop: (20, 280), instGens: [(Gen.keyRange, 0x4000), (Gen.exclusiveClass, 3)])
        multi.presets.append(("drums", 0, 128, [.init(gens: [(Gen.velRange, 0x7F40), (Gen.instrument, 0)],
                                                     mods: [.init(src: 0x0502, dest: 48, amount: 100)])]))
        return [a.bytes(), stereo.bytes(), multi.bytes()]
    }

    func test_P99_parserNeverCrashes() throws {
        var rng = SplitMix64(state: 0x5F2_201)
        let bases = Self.fixtures()
        var loaded = 0, rejected = 0
        let iterations = Int(ProcessInfo.processInfo.environment["SF2_FUZZ_ITERATIONS"] ?? "") ?? 10_000
        for it in 0 ..< iterations {
            var bytes = bases[it % bases.count]
            switch rng.next() % 4 {
            case 0: // single-byte mutations
                for _ in 0 ..< 1 + Int(rng.next() % 4) { bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next()) }
            case 1: // multi-byte run (sizes / indices)
                let at = Int(rng.next() % UInt64(bytes.count)), len = min(bytes.count - at, 1 + Int(rng.next() % 4))
                for i in 0 ..< len { bytes[at + i] = [0x00, 0xFF, 0x7F, 0x80][Int(rng.next() % 4)] }
            case 2: // truncation
                bytes.removeLast(Int(rng.next() % UInt64(bytes.count)))
            default: // insertion / deletion inside
                let at = Int(rng.next() % UInt64(bytes.count))
                if rng.next() % 2 == 0 { bytes.insert(UInt8(truncatingIfNeeded: rng.next()), at: at) } else { bytes.remove(at: at) }
            }
            for opts in [SF2LoadOptions.lenient, .strict] {
                let sf: SF2SoundFont
                do { sf = try SF2SoundFont(data: Data(bytes), options: opts) }
                catch is SF2Error { rejected += 1; continue }
                catch { XCTFail("iteration \(it): non-SF2Error \(error)"); continue }
                loaded += 1
                exercise(sf)
            }
        }
        XCTAssertGreaterThan(loaded, 0); XCTAssertGreaterThan(rejected, 0)
    }

    private func exercise(_ sf: SF2SoundFont) {
        for p in 0 ..< min(sf.presets.count, 8) {
            for fid in [SF2Fidelity.gbk, .spec] {
                guard let list = try? sf.regionList(forPreset: p, fidelity: fid) else { continue }
                let e = Sf2SynthEngine(outSr: 44100, maxVoices: 16)
                e.fidelity = fid
                e.setTrackStates([SF2TrackState(trackIndex: 0, regions: list)])
                for k in [36, 60, 96] { e.dispatchEvent(.noteOn(k, velocity: 100, trackIndex: 0, channel: 0)) }
                var l = [Float](repeating: 0, count: 1024), r = [Float](repeating: 0, count: 1024)
                e.renderRange(&l, &r)
                e.dispatchEvent(.noteOff(60, trackIndex: 0, channel: 0))
                e.renderRange(&l, &r)
            }
        }
    }
}
