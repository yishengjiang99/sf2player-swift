// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// SF2Fidelity.spec: SoundFont 2.04 modulators, live MIDI channel controllers, filter Q, drums.
final class SpecFidelityTests: XCTestCase {
    private func firstVoice(_ e: Sf2SynthEngine) -> Voice { e.st.pointee.voices[Int(e.st.pointee.order[0])] }

    private func specEngine(_ regions: [SF2Region] = [makeRegion()]) -> Sf2SynthEngine {
        let e = Sf2SynthEngine(outSr: 44100)
        e.fidelity = .spec
        e.setTrackStates([SF2TrackState(trackIndex: 0, regions: SF2RegionList(regions))])
        return e
    }

    private func noteOn(_ e: Sf2SynthEngine, _ note: Int = 60, velocity: Int = 127, channel: Int = 0) {
        e.dispatchEvent(.noteOn(note, velocity: velocity, trackIndex: 0, channel: channel))
    }

    // MARK: curves

    func testConcaveCurveMatchesSpecEndpointsAndVelocitySquareLaw() {
        XCTAssertEqual(concave(0), 0)
        XCTAssertEqual(concave(1), 1)
        // velocity -> attenuation default (960 cB, concave negative) == (v/127)^2 in amplitude.
        for v in [16, 40, 64, 100, 127] {
            let cc = [UInt8](repeating: 0, count: 128)
            let atten = cc.withUnsafeBufferPointer { p in
                modValue(SF2Modulator.defaults[0], ModInputs(velocity: v, key: 60, cc: p.baseAddress!, pitchWheel: 8192,
                                                             pitchWheelSensitivity: 2, channelPressure: 0))
            }
            XCTAssertEqual(cbAttenToLin(atten), pow(Double(v) / 127, 2), accuracy: 1e-9, "v=\(v)")
        }
    }

    func testBipolarPanSourceAndSwitchCurve() {
        var cc = [UInt8](repeating: 0, count: 128)
        cc[10] = 0
        let pan = { (c: [UInt8]) in c.withUnsafeBufferPointer { p in
            modValue(SF2Modulator.defaults[5], ModInputs(velocity: 100, key: 60, cc: p.baseAddress!, pitchWheel: 8192,
                                                         pitchWheelSensitivity: 2, channelPressure: 0))
        } }
        XCTAssertEqual(pan(cc), -1000)
        cc[10] = 127
        XCTAssertEqual(pan(cc), 1000 * 63.0 / 64, accuracy: 1e-9)
        cc[10] = 64
        XCTAssertEqual(pan(cc), 0)
        XCTAssertEqual(modCurve(3, 0.49), 0)
        XCTAssertEqual(modCurve(3, 0.5), 1)
    }

    func testModulatorMergeRules() {
        // Instrument modulator identical to a default replaces it; a preset one adds to it.
        let instVel = SF2Modulator(src: 0x0502, dest: 48, amount: 480)
        let presetVel = SF2Modulator(src: 0x0502, dest: 48, amount: 100)
        let extra = SF2Modulator(src: 0x0102, dest: 34, amount: 7000)
        let merged = SF2Modulator.merge(instGlobal: [], instLocal: [instVel, extra], presetGlobal: [], presetLocal: [presetVel])
        XCTAssertEqual(merged.filter { $0.dest == 48 && $0.src == 0x0502 }.map(\.amount), [580])
        XCTAssertTrue(merged.contains(extra))
        XCTAssertEqual(merged.count, SF2Modulator.defaults.count + 1)
        // Local replaces global within the instrument level.
        let g = SF2Modulator(src: 0x0081, dest: 6, amount: 10), l = SF2Modulator(src: 0x0081, dest: 6, amount: 30)
        XCTAssertEqual(SF2Modulator.merge(instGlobal: [g], instLocal: [l], presetGlobal: [], presetLocal: [])
            .filter { $0.src == 0x0081 }.map(\.amount), [30])
    }

    // MARK: live controllers

    func testCC7AndCC11ScaleSoundingVoice() {
        let e = specEngine()
        noteOn(e)
        let g0 = firstVoice(e).baseGain
        e.dispatchEvent(.controlChange(7, value: 50, trackIndex: 0, channel: 0))
        XCTAssertEqual(firstVoice(e).baseGain / g0, pow(50.0 / 100, 2), accuracy: 1e-9)
        e.dispatchEvent(.controlChange(11, value: 64, trackIndex: 0, channel: 0))
        XCTAssertEqual(firstVoice(e).baseGain / g0, pow(50.0 / 100, 2) * pow(64.0 / 127, 2), accuracy: 1e-9)
        // Another channel is unaffected.
        e.dispatchEvent(.controlChange(7, value: 1, trackIndex: 0, channel: 3))
        XCTAssertEqual(firstVoice(e).baseGain / g0, pow(50.0 / 100, 2) * pow(64.0 / 127, 2), accuracy: 1e-9)
    }

    func testCC10PansSoundingVoice() {
        let e = specEngine()
        noteOn(e)
        XCTAssertEqual(firstVoice(e).regionPanPos, 0, accuracy: 1e-12)
        e.dispatchEvent(.controlChange(10, value: 0, trackIndex: 0, channel: 0))
        XCTAssertEqual(firstVoice(e).regionPanPos, -1, accuracy: 1e-12)
        var l = [Float](repeating: 0, count: 64), r = [Float](repeating: 0, count: 64)
        e.renderRange(&l, &r)
        XCTAssertGreaterThan(abs(l[10]), 0.1)
        XCTAssertEqual(r[10], 0, accuracy: 1e-6)
    }

    func testPitchBendDefaultRangeAndRPN0() {
        let e = specEngine()
        noteOn(e)
        let r0 = firstVoice(e).baseRate
        e.dispatchEvent(.pitchBend(16383, trackIndex: 0, channel: 0))
        XCTAssertEqual(firstVoice(e).baseRate / r0, pow(2, (200 * 8191.0 / 8192) / 1200), accuracy: 1e-9)
        // RPN 0 = 12 semitones.
        for (c, v) in [(101, 0), (100, 0), (6, 12), (38, 0)] { e.dispatchEvent(.controlChange(c, value: v, trackIndex: 0, channel: 0)) }
        XCTAssertEqual(e.pitchBendRange(channel: 0), 12)
        e.dispatchEvent(.pitchBend(0, trackIndex: 0, channel: 0))
        XCTAssertEqual(firstVoice(e).baseRate / r0, 0.5, accuracy: 1e-9)
        e.dispatchEvent(.pitchBend(8192, trackIndex: 0, channel: 0))
        XCTAssertEqual(firstVoice(e).baseRate, r0, accuracy: 1e-12)
        e.dispatchEvent(.controlChange(121, value: 0, trackIndex: 0, channel: 0))
        XCTAssertEqual(e.pitchBend(channel: 0), 8192)
    }

    func testModWheelAddsVibrato() {
        let e = specEngine()
        noteOn(e)
        XCTAssertEqual(firstVoice(e).vibToPitch, 0)
        e.dispatchEvent(.controlChange(1, value: 127, trackIndex: 0, channel: 0))
        XCTAssertEqual(firstVoice(e).vibToPitch, 50, accuracy: 1e-9)
    }

    func testControllersIgnoredInGbkMode() {
        let e = Sf2SynthEngine(outSr: 44100)
        e.setTrackStates([SF2TrackState(trackIndex: 0, regions: SF2RegionList([makeRegion()]))])
        noteOn(e)
        let v0 = firstVoice(e)
        e.dispatchEvent(.controlChange(7, value: 10, trackIndex: 0, channel: 0))
        e.dispatchEvent(.pitchBend(0, trackIndex: 0, channel: 0))
        XCTAssertEqual(firstVoice(e).baseGain, v0.baseGain)
        XCTAssertEqual(firstVoice(e).baseRate, v0.baseRate)
        XCTAssertEqual(e.controller(7, channel: 0), 100)
    }

    // MARK: velocity, filter

    func testVelocityLowersCutoffAndSetsGain() {
        let e = specEngine()
        noteOn(e, velocity: 127)
        noteOn(e, 61, velocity: 64)
        let vs = (0 ..< e.st.pointee.count).map { e.st.pointee.voices[Int(e.st.pointee.order[$0])] }
        let loud = vs.first { $0.note == 60 }!, soft = vs.first { $0.note == 61 }!
        XCTAssertEqual(loud.initialFc, 13500, accuracy: 1e-9)
        XCTAssertEqual(soft.initialFc, 13500 - 2400 * (1 - 64.0 / 127), accuracy: 1e-9)
        XCTAssertEqual(soft.baseGain / loud.baseGain, pow(64.0 / 127, 2), accuracy: 1e-9)
    }

    func testFilterQFromRegion() {
        var reg = makeRegion()
        reg.initialFilterQCb = 120
        reg.initialFilterFcCents = 6000
        let e = specEngine([reg])
        noteOn(e)
        let v = firstVoice(e)
        XCTAssertEqual(v.lpf.q, pow(10, (12 - 3.01) / 20), accuracy: 1e-9)
        // 0 cB stays Butterworth with unity compensation.
        let e0 = specEngine()
        noteOn(e0)
        XCTAssertEqual(firstVoice(e0).lpf.q, 0.7071, accuracy: 1e-4)
    }

    // MARK: channel presets (GM drums)

    func testChannelPresetOverridesTrackListInSpec() {
        let piano = makeRegion(keyRange: (0, 127))
        let drums = makeRegion(keyRange: (35, 81), exclusiveClass: 0)
        let e = specEngine([piano])
        e.dispatchEvent(SF2SynthEvent(kind: .setPreset, trackIndex: 0, channel: 9, regions: SF2RegionList([drums, drums])))
        e.dispatchEvent(.noteOn(36, velocity: 100, trackIndex: 0, channel: 9))
        XCTAssertEqual(e.voiceCount, 2)   // channel 9 list (two regions)
        e.dispatchEvent(.noteOn(60, velocity: 100, trackIndex: 0, channel: 0))
        XCTAssertEqual(e.voiceCount, 3)   // channel 0 falls back to the track list
    }

    // MARK: GeneralUser GS

    func testGeneralUserSpecRegionsCarryModulatorsAndDrumKit() throws {
        let sf = try SharedSoundFont.get()
        let piano = try sf.buildRegionsForPreset(0, fidelity: .spec)
        XCTAssertFalse(piano.isEmpty)
        XCTAssertTrue(piano.allSatisfy { ($0.modulators?.count ?? 0) >= SF2Modulator.defaults.count - 1 })
        guard let kit = sf.resolvePresetIndex(program: 0, bank: 128) else { return XCTFail("no bank 128 kit") }
        XCTAssertEqual(sf.presets[kit].bank, 128)
        let drums = try sf.regionList(forPreset: kit, fidelity: .spec)
        XCTAssertTrue(drums.regions.contains { $0.keyRange.0 <= 36 && 36 <= $0.keyRange.1 })
        // Spec render of a C4 piano note is finite and audible.
        let e = Sf2SynthEngine(outSr: 44100)
        e.fidelity = .spec
        e.setTrackStates([SF2TrackState(trackIndex: 0, regions: try sf.regionList(forPreset: 0, fidelity: .spec))])
        e.dispatchEvent(.noteOn(60, velocity: 100, trackIndex: 0, channel: 0))
        var l = [Float](repeating: 0, count: 4410), r = [Float](repeating: 0, count: 4410)
        e.renderRange(&l, &r)
        let peak = l.map { abs($0) }.max() ?? 0
        XCTAssertTrue(l.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(peak, 0.01)
    }
}
