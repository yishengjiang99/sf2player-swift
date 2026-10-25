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

    private func voice0(_ r: SpecRender) -> Voice { r.engine.st.pointee.voices[Int(r.engine.st.pointee.order[0])] }

    /// gbk 4d788d7: CC91 / CC93 reach the sends of voices whose modulator list has no CC91 / CC93 send modulator.
    func test_sendCcModulatorFallback() throws {
        let wave = B.sine(cycles: 100, n: 4410)
        var b204 = B.single(wave, loop: (0, 4410), instGens: [(Gen.sampleModes, 1)])
        b204.ifil = (2, 4)                      // 2.04 defaults: no effects-send modulators
        for on in [true, false] {
            let r = try SpecRender(b204)
            r.engine.sendCcModulators = on
            r.cc(91, 127); r.cc(93, 64); r.noteOn(60)
            XCTAssertEqual(voice0(r).reverbAmt, on ? 0.2 * 127 / 128 : 0, accuracy: 1e-12)
            XCTAssertEqual(voice0(r).chorusAmt, on ? 0.2 * 64 / 128 : 0, accuracy: 1e-12)
            r.cc(91, 0)                          // live: follows the controller
            XCTAssertEqual(voice0(r).reverbAmt, 0, accuracy: 1e-12)
        }
        // 2.01 file: the default list already has 8.4.8 / 8.4.9, so the fallback must not double them.
        let r = try SpecRender(B.single(wave, loop: (0, 4410), instGens: [(Gen.sampleModes, 1)]))
        XCTAssertTrue(r.engine.sendCcModulators, "on by default (gbk)")
        r.cc(91, 127); r.noteOn(60)
        XCTAssertTrue(voice0(r).hasSendMods)
        XCTAssertEqual(voice0(r).reverbAmt, 0.2 * 127 / 128, accuracy: 1e-12)
    }

    /// gbk f28fcbf: per-engine track pan (stereo-input StereoPanner law) and 10 ms fader after the master bus.
    func test_trackOutputStage() throws {
        let wave = B.sine(cycles: 100, n: 4410)
        func run(_ setup: (Sf2SynthEngine) -> Void) throws -> (l: [Float], r: [Float]) {
            let r = try SpecRender(B.single(wave, loop: (0, 4410), instGens: [(Gen.sampleModes, 1), (Gen.pan, -200)]))
            setup(r.engine); r.noteOn(60); return r.render(4410)
        }
        let ref = try run { _ in }
        let same = try run { $0.trackPan = 0; $0.trackFader = 1 }
        XCTAssertEqual(ref.l, same.l, "identity is bit-exact"); XCTAssertEqual(ref.r, same.r)
        let left = try run { $0.trackPan = -1 }
        for i in stride(from: 0, to: 4410, by: 61) {
            XCTAssertEqual(left.l[i], ref.l[i] + ref.r[i], accuracy: 1e-6); XCTAssertEqual(left.r[i], 0, accuracy: 1e-7)
        }
        let half = try run { $0.trackPan = 0.5 }
        let g = Sf2SynthEngine.stereoPanGains(0.5)
        XCTAssertEqual(g.ll, cos(Double.pi / 4), accuracy: 1e-15); XCTAssertEqual(g.rr, 1)
        for i in stride(from: 0, to: 4410, by: 61) {
            XCTAssertEqual(Double(half.l[i]), Double(ref.l[i]) * g.ll, accuracy: 1e-6)
            XCTAssertEqual(Double(half.r[i]), Double(ref.l[i]) * g.lr + Double(ref.r[i]), accuracy: 1e-6)
        }
        // fader: 10 ms one-pole from 1 toward the target
        let e = Sf2SynthEngine(outSr: 44100)
        e.trackFader = 0.25
        var l = [Float](repeating: 0, count: 441), r = l
        e.renderRange(&l, &r)
        XCTAssertEqual(e.trackFaderCurrent, 0.25 + 0.75 * exp(-1), accuracy: 1e-3, "one time constant after 10 ms")
        l = [Float](repeating: 0, count: 44100); r = l
        e.renderRange(&l, &r)
        XCTAssertEqual(e.trackFaderCurrent, 0.25, "snaps to the target")
        e.trackFader = -3; XCTAssertEqual(e.trackFader, 0)
        e.trackPan = 7; XCTAssertEqual(e.trackPan, 1)
    }

    /// gbk 4d788d7: per-track / engine-wide generator overrides ("add" / "set", optional key range).
    func test_voiceOverrides() throws {
        let wave = B.sine(cycles: 100, n: 4410)
        let bank = B.single(wave, loop: (0, 4410), instGens: [(Gen.sampleModes, 1), (Gen.initialFilterFc, 10000)])
        func voices(_ r: SpecRender) -> [Voice] { (0 ..< r.engine.st.pointee.count).map { r.engine.st.pointee.voices[Int(r.engine.st.pointee.order[$0])] } }
        let ref = try SpecRender(bank); ref.noteOn(60)
        let base = voices(ref)[0]

        let r = try SpecRender(bank)
        r.engine.setVoiceOverrides([.init(gen: 8, mode: .set, value: 9000), .init(gen: 48, mode: .add, value: 60, keyLo: 60, keyHi: 64)], trackIndex: 0)
        r.engine.setVoiceOverrides([.init(gen: 48, mode: .add, value: 40)])          // engine-wide, sums with the track list
        r.noteOn(60); r.noteOn(70)
        let v = voices(r)
        XCTAssertEqual(v[0].initialFc, 9000, accuracy: 1e-9, "set replaces the zone value")
        XCTAssertEqual(v[1].initialFc, 9000, accuracy: 1e-9)
        XCTAssertEqual(A.db(v[0].baseGain / base.baseGain), -10, accuracy: 1e-6, "60 + 40 cB inside the key range")
        XCTAssertEqual(A.db(v[1].baseGain / base.baseGain), -4, accuracy: 1e-6, "key 70: engine-wide 40 cB only")
        // set is clamped to the 8.1.3 range
        let c = try SpecRender(bank)
        c.engine.setVoiceOverrides([.init(gen: 8, mode: .set, value: 99999)], trackIndex: 0); c.noteOn(60)
        XCTAssertEqual(voices(c)[0].initialFc, 13500, accuracy: 1e-9)
        // updateActive refreshes realtime generators of sounding voices; removing restores the zone
        let u = try SpecRender(bank); u.noteOn(60)
        u.engine.setVoiceOverrides([.init(gen: 8, mode: .add, value: -1200)], trackIndex: 0)
        XCTAssertEqual(voices(u)[0].initialFc, 10000, accuracy: 1e-9, "not applied to sounding voices by default")
        u.engine.setVoiceOverrides([.init(gen: 8, mode: .add, value: -1200)], trackIndex: 0, updateActive: true)
        XCTAssertEqual(voices(u)[0].initialFc, 8800, accuracy: 1e-9)
        XCTAssertEqual(u.engine.voiceOverrides(trackIndex: 0)?.count, 1)
        u.engine.setVoiceOverrides(nil, trackIndex: 0, updateActive: true)
        XCTAssertEqual(voices(u)[0].initialFc, 10000, accuracy: 1e-9)
        XCTAssertNil(u.engine.voiceOverrides(trackIndex: 0))
        // other tracks are untouched by a track list
        let o = try SpecRender(bank)
        o.engine.setVoiceOverrides([.init(gen: 8, mode: .set, value: 5000)], trackIndex: 3); o.noteOn(60)
        XCTAssertEqual(voices(o)[0].initialFc, 10000, accuracy: 1e-9)
        // validation (gbk validateOverride)
        XCTAssertNil(SF2VoiceOverride(gen: 8, mode: .set, value: 9000).validationError)
        XCTAssertNotNil(SF2VoiceOverride(gen: 53, mode: .add, value: 1).validationError, "sampleID is not editable")
        XCTAssertNotNil(SF2VoiceOverride(gen: 8, mode: .set, value: 20000).validationError)
        XCTAssertNotNil(SF2VoiceOverride(gen: 8, mode: .add, value: 1, keyLo: 70, keyHi: 60).validationError)
    }

    /// gbk 6c9eafc: BS.1770 integrated loudness / true peak and the whole-file gain choice.
    func test_loudnessMeterAndGain() {
        let sr = 48000.0, n = Int(sr * 5)
        let x = (0 ..< n).map { Float(0.1 * sin(2 * Double.pi * 997 * Double($0) / sr)) }
        let m = SF2LoudnessMeter(sampleRate: sr)
        m.push(x, x)
        let s = m.result()
        XCTAssertEqual(s.integratedLufs, -20, accuracy: 0.1, "-20 dBFS 997 Hz sine in both channels = -20 LUFS")
        XCTAssertEqual(s.samplePeakDbFS, -20, accuracy: 0.01)
        XCTAssertEqual(s.truePeakDbTP, -20, accuracy: 0.1)
        let loud = SF2LoudnessReport.choose(.gbkDefault, s, meter: m)
        XCTAssertEqual(loud.limitedBy, .loudness); XCTAssertEqual(loud.gainDb, 4, accuracy: 0.1)
        XCTAssertEqual(loud.outputLufs, -16, accuracy: 0.01)
        let capped = SF2LoudnessReport.choose(.loudness(targetLufs: -0.5), s, meter: m)
        XCTAssertEqual(capped.limitedBy, .truePeak); XCTAssertEqual(capped.outputTruePeakDbTP, -1, accuracy: 1e-9)
        XCTAssertEqual(SF2LoudnessReport.choose(.peak, s).gainDb, 19, accuracy: 0.1)
        XCTAssertEqual(SF2LoudnessReport.choose(.off, s).gainLinear, 1)
        let silent = SF2LoudnessMeter(sampleRate: sr); silent.push([Float](repeating: 0, count: 48000), [Float](repeating: 0, count: 48000))
        XCTAssertEqual(silent.result().integratedLufs, -.infinity)
        XCTAssertEqual(SF2LoudnessReport.choose(.gbkDefault, silent.result()).gainDb, 0)
    }

    /// gbk c728c6c: song renders end at the last event + tail (release kept), then one normalisation gain.
    func test_renderSongTailAndNormalize() throws {
        let wave = B.sine(cycles: 100, n: 4410)
        let sf = try SF2SoundFont(data: B.single(wave, loop: (0, 4410), instGens: [(Gen.sampleModes, 1), (Gen.releaseVolEnv, 0)]).build(), options: .strict)
        let tracks = [SF2TrackState(trackIndex: 0, regions: try sf.regionList(forPreset: 0, fidelity: .spec))]
        let events: [SF2SynthEvent] = [.noteOn(60, velocity: 100, frame: 0, trackIndex: 0, channel: 0), .noteOff(60, frame: 22050, seq: 1, trackIndex: 0, channel: 0)]
        let a = SF2OfflineRenderer.renderSong(sampleRate: 44100, tracks: tracks, events: events, tailSeconds: 2)
        XCTAssertEqual(a.musicFrames, 22050); XCTAssertEqual(a.buffer.length, 22050 + 88200)
        XCTAssertGreaterThan(A.rmsDB(Array(a.buffer.left[22050 ..< 22050 + 4410])), -40, "release tail kept (1 s release)")
        XCTAssertEqual(a.loudness.gainLinear, 1)
        let b = SF2OfflineRenderer.renderSong(sampleRate: 44100, tracks: tracks, events: events, tailSeconds: 2, normalize: .gbkDefault)
        let m = SF2LoudnessMeter(sampleRate: 44100); m.push(b.buffer.left, b.buffer.right)
        let out = m.result()
        if b.loudness.limitedBy == .loudness { XCTAssertEqual(out.integratedLufs, -16, accuracy: 0.05) }
        XCTAssertLessThanOrEqual(out.truePeakDbTP, -1 + 0.01)
        for i in stride(from: 0, to: a.buffer.length, by: 997) {
            XCTAssertEqual(Double(b.buffer.left[i]), Double(a.buffer.left[i]) * b.loudness.gainLinear, accuracy: 1e-6)
        }
    }
}
