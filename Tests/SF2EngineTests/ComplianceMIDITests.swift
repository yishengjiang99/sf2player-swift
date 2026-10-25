// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Matrix rows MIDI-xx, N-xx, M-11, G-02, G-12: channel functions, SoundFont NRPN, live sources.
final class ComplianceMIDITests: XCTestCase {
    typealias B = SF2Builder
    typealias A = Analysis

    private func held(_ extra: [(Int, Int)] = [], mods: [B.Mod] = []) -> B {
        B.single(B.dc(4000), loop: (100, 3900), instGens: [(Gen.sampleModes, 1), (Gen.releaseVolEnv, -2400)] + extra, instMods: mods)
    }
    private func voices(_ r: SpecRender) -> [Voice] {
        (0 ..< r.engine.st.pointee.count).map { r.engine.st.pointee.voices[Int(r.engine.st.pointee.order[$0])] }
    }
    private func releasing(_ r: SpecRender) -> [Bool] { voices(r).map { $0.volEnv.stage == .release } }

    func test_MIDI02_sustainPedal() throws {
        let r = try SpecRender(held())
        r.noteOn(60); r.cc(64, 127); r.noteOff(60)
        XCTAssertEqual(releasing(r), [false], "key-off deferred while CC64 >= 64")
        r.cc(64, 0)
        XCTAssertEqual(releasing(r), [true], "executed on pedal release")
    }

    func test_MIDI03_sostenuto() throws {
        let r = try SpecRender(held())
        r.noteOn(60)
        r.cc(66, 127)          // 60 is held now
        r.noteOn(62)           // pressed after: not held by sostenuto
        r.noteOff(60); r.noteOff(62)
        XCTAssertEqual(voices(r).map { $0.note }, [60, 62])
        XCTAssertEqual(releasing(r), [false, true])
        r.cc(64, 127); r.cc(64, 0)   // sustain cycling does not release a sostenuto note
        XCTAssertEqual(releasing(r)[0], false)
        r.cc(66, 0)
        XCTAssertEqual(releasing(r)[0], true)
    }

    func test_MIDI04_softPedal() throws {
        let r = try SpecRender(held([(Gen.initialFilterFc, 9000)]))
        r.noteOn(60); r.cc(67, 127); r.noteOn(62)
        let v = voices(r)
        XCTAssertEqual(v[1].initialFc, v[0].initialFc - Sf2SynthEngine.softPedalFcCents, accuracy: 1e-9)
        XCTAssertEqual(A.db(v[1].baseGain / v[0].baseGain), -Sf2SynthEngine.softPedalAttenuationCb / 10, accuracy: 0.01)
    }

    /// gbk 049f23a: MIDI 1.0 numbering. CC66 is sostenuto only (no soft-pedal effect), CC67 is the soft pedal only.
    func test_MIDI03_04_controllerNumbers() throws {
        let r = try SpecRender(held([(Gen.initialFilterFc, 9000)]))
        r.noteOn(60); r.cc(66, 127); r.noteOn(62)
        let v = voices(r)
        XCTAssertEqual(v[1].initialFc, v[0].initialFc, accuracy: 1e-9, "CC66 does not soften")
        XCTAssertEqual(v[1].baseGain, v[0].baseGain, accuracy: 1e-12)
        let q = try SpecRender(held())
        q.noteOn(60); q.cc(67, 127); q.noteOff(60)
        XCTAssertEqual(releasing(q), [true], "CC67 does not hold like sostenuto")
    }

    func test_MIDI05_allSoundOffAllNotesOff() throws {
        var r = try SpecRender(held())
        r.noteOn(60); r.noteOn(64); r.cc(64, 127)
        r.cc(123, 0)
        XCTAssertEqual(releasing(r), [false, false], "CC123 respects sustain")
        r.cc(64, 0)
        XCTAssertEqual(releasing(r), [true, true])
        r = try SpecRender(held())
        r.noteOn(60); r.cc(64, 127); r.cc(66, 127)
        r.cc(120, 0)
        XCTAssertEqual(r.render(1).l[0], 0, "CC120: no release tail, regardless of pedals")
        XCTAssertEqual(r.engine.st.pointee.count, 0)
    }

    func test_MIDI06_resetAllControllers() throws {
        let r = try SpecRender(held())
        r.noteOn(60); r.cc(64, 127); r.cc(1, 90); r.engine.dispatchEvent(.channelPressure(80, channel: 0))
        for (c, v) in [(99, 120), (98, 48), (38, 0), (6, 80)] { r.cc(c, v) }
        XCTAssertNotEqual(r.engine.st.pointee.nrpn[48], 0)
        r.noteOff(60)
        r.cc(121, 0)
        XCTAssertEqual(r.engine.controller(64, channel: 0), 0); XCTAssertEqual(r.engine.controller(1, channel: 0), 0)
        XCTAssertEqual(r.engine.st.pointee.chans[0].pressure, 0)
        XCTAssertEqual(r.engine.st.pointee.nrpn[48], 0, "N-06 offsets cleared")
        XCTAssertEqual(releasing(r), [true], "sustain cleared -> deferred key-off executes")
        XCTAssertEqual(r.engine.controller(7, channel: 0), 100, "volume untouched (RP-015)")
    }

    func test_MIDI07_programChange() throws {
        var b = held()
        b.instruments.append(("i2", [.init(gens: [(Gen.sampleModes, 1), (Gen.pan, 300), (Gen.sampleID, 0)])]))
        b.presets = [("a", 0, 0, [.init(gens: [(Gen.instrument, 0)])]), ("b", 5, 0, [.init(gens: [(Gen.instrument, 1)])]),
                     ("b8", 5, 8, [.init(gens: [(Gen.pan, -100), (Gen.instrument, 1)])]),
                     ("drums", 0, 128, [.init(gens: [(Gen.pan, -400), (Gen.instrument, 1)])])]
        let r = try SpecRender(b)
        try r.engine.loadPrograms(from: SF2SoundFont(data: b.build(), options: .strict))
        r.engine.dispatchEvent(.programChange(5, channel: 0)); r.noteOn(60)
        XCTAssertEqual(voices(r).last?.regPan, 300)
        r.cc(0, 8); r.engine.dispatchEvent(.programChange(5, channel: 0)); r.noteOn(61)
        XCTAssertEqual(voices(r).last?.regPan, 200, "CC0 bank select applies at the next program change")
        r.engine.dispatchEvent(.programChange(0, channel: 9)); r.noteOn(62, channel: 9)
        XCTAssertEqual(voices(r).last?.regPan, -100, "channel 10 -> bank 128 percussion")
    }

    func test_MIDI08_dataEntryRouting() throws {
        let r = try SpecRender(held())
        for (c, v) in [(101, 0), (100, 0), (6, 7)] { r.cc(c, v) }
        XCTAssertEqual(r.engine.pitchBendRange(channel: 0), 7, "RPN 0")
        for (c, v) in [(99, 120), (98, 17), (6, 9)] { r.cc(c, v) }
        XCTAssertEqual(r.engine.pitchBendRange(channel: 0), 7, "NRPN data entry does not touch RPN 0")
        XCTAssertNotEqual(r.engine.st.pointee.nrpn[17], 0)
        for (c, v) in [(101, 0), (100, 0), (6, 3)] { r.cc(c, v) }
        XCTAssertEqual(r.engine.pitchBendRange(channel: 0), 3)
        XCTAssertEqual(r.engine.st.pointee.nrpn[17], Double((9 << 7) - 8192) * Sf2SynthEngine.nrpnScale(17), "RPN data not routed to NRPN")
    }

    func test_N01_nrpnMode() throws {
        let r = try SpecRender(held())
        for (c, v) in [(99, 1), (98, 48), (6, 80)] { r.cc(c, v) }
        XCTAssertEqual(r.engine.st.pointee.nrpn[48], 0, "MSB != 120: not a SoundFont NRPN")
        for (c, v) in [(99, 120), (98, 48), (6, 80)] { r.cc(c, v) }
        XCTAssertNotEqual(r.engine.st.pointee.nrpn[48], 0)
    }

    func test_N02_nrpnSelectAccumulator() throws {
        let r = try SpecRender(held())
        r.cc(99, 120)
        for v in [100, 100, 50] { r.cc(98, v) }       // 250: unknown generator -> ignored
        XCTAssertEqual(r.engine.st.pointee.chans[0].nrpnSelect, -1)
        r.cc(98, 51)                                   // running status: 51, not 251
        XCTAssertEqual(r.engine.st.pointee.chans[0].nrpnSelect, 51)
        r.cc(98, 101); r.cc(98, 103); r.cc(98, 8)      // 1000 + 8 -> unknown, 103 ignored
        XCTAssertEqual(r.engine.st.pointee.chans[0].nrpnSelect, 51)
        r.cc(98, 8)
        XCTAssertEqual(r.engine.st.pointee.chans[0].nrpnSelect, 8)
    }

    func test_N03_nrpnIllegalSelect() throws {
        let r = try SpecRender(held())
        r.cc(99, 120); r.cc(98, 48)
        for g in [Gen.sampleID, Gen.keyRange, Gen.overridingRootKey, Gen.scaleTuning, Gen.startAddrsOffset, 14, 59] {
            r.cc(98, g)
            XCTAssertEqual(r.engine.st.pointee.chans[0].nrpnSelect, 48, "gen \(g) ignored, NRPN mode kept")
        }
        XCTAssertTrue(r.engine.st.pointee.chans[0].nrpnActive)
    }

    func test_N04_nrpnDataEntryAdds() throws {
        let r = try SpecRender(held())
        r.noteOn(60)
        let g0 = voices(r)[0].baseGain
        // initialAttenuation (#48) span 1440 <= 8192 -> 1 cB per step; +100 cB = data 0x2000 + 100
        for (c, v) in [(99, 120), (98, 48), (38, (8192 + 100) & 127), (6, (8192 + 100) >> 7)] { r.cc(c, v) }
        XCTAssertEqual(A.db(voices(r)[0].baseGain / g0), -10, accuracy: 0.01, "sounding voice")
        r.noteOn(64)
        XCTAssertEqual(A.db(voices(r)[1].baseGain / g0), -10, accuracy: 0.01, "future voice")
        r.cc(38, 0); r.cc(6, 64)                     // 0x2000 -> zero offset
        XCTAssertEqual(voices(r)[0].baseGain, g0, accuracy: 1e-12)
        // measured: +1200 cents via coarseTune? fineTune #52: span 198 -> 1 cent per step
        let s = try SpecRender(B.single(B.sine(cycles: 100, n: 4410), loop: (0, 4410), instGens: [(Gen.sampleModes, 1)]))
        s.noteOn(60)
        for (c, v) in [(99, 120), (98, 52), (38, (8192 + 50) & 127), (6, (8192 + 50) >> 7)] { s.cc(c, v) }
        XCTAssertEqual(A.cents(A.f0ZeroCrossing(s.render(22050).l, sampleRate: 44100, from: 2000), 1000), 50, accuracy: 1)
    }

    func test_N05_nrpnRange() {
        XCTAssertEqual(Sf2SynthEngine.nrpnScale(48), 1)      // 1440
        XCTAssertEqual(Sf2SynthEngine.nrpnScale(8), 2)       // 12000 -> 6000
        XCTAssertEqual(Sf2SynthEngine.nrpnScale(6), 4)       // 24000 -> 6000
        XCTAssertEqual(Sf2SynthEngine.nrpnScale(34), 4)      // 20000 -> 5000
        XCTAssertEqual(Sf2SynthEngine.nrpnScale(22), 4)      // 20500 -> 5125
        XCTAssertEqual(Sf2SynthEngine.nrpnScale(17), 1)      // 1000
        // end points: data 0 -> -8192 steps, 16383 -> +8191 steps
        let r = try! SpecRender(held())
        for (c, v) in [(99, 120), (98, 8), (38, 0), (6, 0)] { r.cc(c, v) }
        XCTAssertEqual(r.engine.st.pointee.nrpn[8], -8192 * 2)
        r.cc(38, 127); r.cc(6, 127)
        XCTAssertEqual(r.engine.st.pointee.nrpn[8], 8191 * 2)
    }

    func test_N06_resetClearsNrpn() throws {
        let r = try SpecRender(held())
        for (c, v) in [(99, 120), (98, 17), (6, 90)] { r.cc(c, v) }
        r.cc(121, 0)
        XCTAssertEqual(r.engine.st.pointee.nrpn[17], 0)
        XCTAssertFalse(r.engine.st.pointee.chans[0].nrpnActive)
    }

    func test_M11_liveSources() throws {
        let r = try SpecRender(held(mods: [.init(src: 0x000D, dest: 48, amount: 128), .init(src: 0x000A, dest: 17, amount: 128),
                                           .init(src: 0x0003, dest: 8, amount: -1280)]))
        r.noteOn(60)
        r.engine.dispatchEvent(.channelPressure(64, channel: 0))
        let v0 = voices(r)[0]
        r.engine.dispatchEvent(.channelPressure(0, channel: 0))
        XCTAssertEqual(A.db(v0.baseGain / voices(r)[0].baseGain), -6.4, accuracy: 0.01, "channel pressure 64 -> 64 cB")
        r.engine.dispatchEvent(.polyPressure(note: 60, value: 127, channel: 0))
        XCTAssertEqual(voices(r)[0].regionPanPos, 127.0 / 500, accuracy: 1e-9, "poly pressure on its own key")
        r.engine.dispatchEvent(.polyPressure(note: 61, value: 0, channel: 0))
        XCTAssertEqual(voices(r)[0].regionPanPos, 127.0 / 500, accuracy: 1e-9, "other keys do not affect it")
        XCTAssertEqual(voices(r)[0].initialFc, 13500 - 1280 * 60.0 / 128, accuracy: 1e-9, "key number source")
    }

    func test_G02_keynumVelocitySubstitution() throws {
        // keynum 72 on a 1 kHz root-60 sine: plays 2 kHz for any key; velocity 64 replaces 127 in the default modulator.
        let b = B.single(B.sine(cycles: 100, n: 4410), loop: (0, 4410), instGens: [(Gen.sampleModes, 1), (Gen.keynum, 72), (Gen.velocity, 64)])
        let r = try SpecRender(b)
        r.noteOn(48, velocity: 127)
        let o = r.render(22050)
        XCTAssertEqual(A.cents(A.f0ZeroCrossing(o.l, sampleRate: 44100, from: 2000), 2000), 0, accuracy: 1)
        let ref = try SpecRender(B.single(B.sine(cycles: 100, n: 4410), loop: (0, 4410), instGens: [(Gen.sampleModes, 1)]))
        ref.noteOn(60, velocity: 64)
        XCTAssertEqual(voices(r)[0].baseGain, voices(ref)[0].baseGain, accuracy: 1e-12, "velocity substitution feeds the modulators")
        r.noteOff(48)
        XCTAssertEqual(releasing(r), [true], "note-off still matches the real MIDI key")
    }

    func test_G12_exclusiveClassFastReleaseSamePresetChannel() throws {
        let b = B.single(B.dc(4000), loop: (100, 3900), instGens: [(Gen.sampleModes, 1), (Gen.exclusiveClass, 5), (Gen.releaseVolEnv, 2400)])
        let r = try SpecRender(b)
        r.noteOn(42); _ = r.render(441)
        r.noteOn(42, channel: 1)                 // other channel: untouched
        r.noteOn(46)                             // same class, same preset, same channel -> 42 on ch 0 terminated
        let v = voices(r)
        XCTAssertEqual(v.map { $0.volEnv.stage == .release }, [true, false, false])
        let out = r.render(441)                   // 10 ms
        _ = out
        XCTAssertEqual(r.engine.st.pointee.count, 2, "terminated within ~5 ms despite a 4 s release")
    }
}
