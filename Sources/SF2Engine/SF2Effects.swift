// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// G-11 (section 8.1.2 #15/#16, 9.1.5): built-in reverb (Freeverb-style: 8 parallel lowpass-feedback
// combs + 4 series allpasses per channel) and chorus (two quadrature-modulated delay lines). Both run
// on the send buses only (dry level is unaffected) and mix back into the output by default
// (`Sf2SynthEngine.effectsEnabled`). All storage is allocated once; `process` is allocation-,
// lock- and ARC-free.

struct SF2EffectsRT {
    static let combTuning = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    static let allpassTuning = [556, 441, 341, 225]
    static let stereoSpread = 23

    let buf: UnsafeMutablePointer<Float>
    let total: Int
    // per delay line: offset into buf, length, index; 16 combs, 8 allpasses, 2 chorus lines
    let offs: UnsafeMutablePointer<Int>, lens: UnsafeMutablePointer<Int>, idx: UnsafeMutablePointer<Int>
    let combStore: UnsafeMutablePointer<Float>
    var chorusPhase = 0.0
    let sr: Double
    /// Reverb return scale (gbk 6c9eafc). Freeverb feeds the combs with the mono send x 0.015 x 2 and scales the
    /// wet return by 3 (scalewet), so FluidSynth's default return is level 0.9 x 3 = 2.7. The earlier port kept the
    /// input gain but dropped scalewet (return 0.35), ~18 dB below FluidSynth. reverbLevel 0.5 (the default) = 2.7,
    /// reverbLevel 1 = 5.4.
    static let reverbReturnMax = 5.4
    var roomFeedback: Float = 0.84, damp: Float = 0.2, reverbWet = Float(SF2EffectsRT.reverbReturnMax * 0.5)
    var chorusDepthSec = 0.004, chorusBaseSec = 0.012, chorusRateHz = 0.6
    var chorusWet = 0.7

    init(sr: Double) {
        self.sr = sr
        let scale = sr / 44100
        var lengths: [Int] = []
        for ch in 0 ..< 2 { for t in Self.combTuning { lengths.append(max(1, Int(Double(t + ch * Self.stereoSpread) * scale))) } }
        for ch in 0 ..< 2 { for t in Self.allpassTuning { lengths.append(max(1, Int(Double(t + ch * Self.stereoSpread) * scale))) } }
        let chorusLen = Int(0.05 * sr) + 4
        lengths += [chorusLen, chorusLen]
        let n = lengths.count
        offs = .allocate(capacity: n); lens = .allocate(capacity: n); idx = .allocate(capacity: n)
        var o = 0
        for i in 0 ..< n { offs[i] = o; lens[i] = lengths[i]; idx[i] = 0; o += lengths[i] }
        total = o
        buf = .allocate(capacity: o); buf.initialize(repeating: 0, count: o)
        combStore = .allocate(capacity: 16); combStore.initialize(repeating: 0, count: 16)
    }

    /// Global parameters (gbk `SF2Effects.setParams`). Not real-time critical; allocation-free.
    mutating func setParams(_ p: SF2EffectsParams) {
        func c(_ x: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, x)) }
        if let v = p.roomSize, v.isFinite { roomFeedback = Float(0.7 + 0.28 * c(v, 0, 1)) }
        if let v = p.damping, v.isFinite { damp = Float(0.4 * c(v, 0, 1)) }
        if let v = p.reverbLevel, v.isFinite { reverbWet = Float(Self.reverbReturnMax * c(v, 0, 1)) }
        if let v = p.chorusLevel, v.isFinite { chorusWet = c(v, 0, 1) }
        if let v = p.chorusRateHz, v.isFinite { chorusRateHz = c(v, 0.01, 10) }
        // The delay line is 50 ms: keep base + depth inside it.
        if let v = p.chorusDelayMs, v.isFinite { chorusBaseSec = c(v, 1, 30) / 1000 }
        if let v = p.chorusDepthMs, v.isFinite { chorusDepthSec = c(v, 0, 10) / 1000 }
        if chorusDepthSec > chorusBaseSec - 0.0005 { chorusDepthSec = max(0, chorusBaseSec - 0.0005) }
    }

    func free() { buf.deallocate(); offs.deallocate(); lens.deallocate(); idx.deallocate(); combStore.deallocate() }

    func clear() {
        for i in 0 ..< total { buf[i] = 0 }
        for i in 0 ..< 16 { combStore[i] = 0 }
    }

    @inline(__always) private func comb(_ k: Int, _ x: Float) -> Float {
        let p = buf + offs[k]
        let y = p[idx[k]]
        combStore[k] = y * (1 - damp) + combStore[k] * damp
        p[idx[k]] = x + combStore[k] * roomFeedback
        idx[k] += 1; if idx[k] >= lens[k] { idx[k] = 0 }
        return y
    }

    @inline(__always) private func allpass(_ k: Int, _ x: Float) -> Float {
        let p = buf + offs[k]
        let b = p[idx[k]]
        p[idx[k]] = x + b * 0.5
        idx[k] += 1; if idx[k] >= lens[k] { idx[k] = 0 }
        return b - x
    }

    @inline(__always) private func chorusLine(_ line: Int, _ x: Double, _ ph: Double) -> Double {
        let p = buf + offs[line], n = lens[line]
        p[idx[line]] = Float(x)
        let d = (chorusBaseSec + chorusDepthSec * sin(2 * Double.pi * ph)) * sr
        var rp = Double(idx[line]) - d
        if rp < 0 { rp += Double(n) }
        let i0 = Int(rp) % n, i1 = (i0 + 1) % n, f = rp - Double(Int(rp))
        idx[line] += 1; if idx[line] >= n { idx[line] = 0 }
        return Double(p[i0]) + (Double(p[i1]) - Double(p[i0])) * f
    }

    /// One frame: reverb + chorus wet signals from the send buses.
    @inline(__always) mutating func process(_ revL: Double, _ revR: Double, _ choL: Double, _ choR: Double) -> (Double, Double) {
        // reverb: Freeverb / FluidSynth feed the combs with the MONO send x 0.03; the send buses are panned
        // (gL + gR = 1), so their sum (not their average) is the mono send (gbk 6c9eafc).
        let input = Float(revL + revR) * Float(0.03)
        var oL: Float = 0, oR: Float = 0
        for k in 0 ..< 8 { oL += comb(k, input); oR += comb(8 + k, input) }
        for k in 0 ..< 4 { oL = allpass(16 + k, oL); oR = allpass(20 + k, oR) }
        var l = Double(oL * reverbWet), r = Double(oR * reverbWet)
        // chorus: write, then read at a modulated delay (linear interpolation)
        chorusPhase += chorusRateHz / sr
        if chorusPhase >= 1 { chorusPhase -= 1 }
        l += chorusLine(24, choL, chorusPhase) * chorusWet
        r += chorusLine(25, choR, chorusPhase + 0.25) * chorusWet
        return (l, r)
    }
}

/// Global reverb / chorus parameters (gbk `EffectsParams`). `nil` fields are left unchanged by
/// `Sf2SynthEngine.setEffectParams(_:)`; values are clamped to the ranges below.
public struct SF2EffectsParams: Equatable, Sendable {
    /// `false` turns the built-in effects off (`effectsEnabled`).
    public var enabled: Bool?
    /// Freeverb room size 0...1 (comb feedback 0.7 + 0.28 x size). Default 0.5.
    public var roomSize: Double?
    /// High-frequency damping 0...1 (0.4 x damping per comb). Default 0.5.
    public var damping: Double?
    /// Reverb return level 0...1 (0.5 = FluidSynth's default return 2.7, 1 = 5.4). Default 0.5.
    public var reverbLevel: Double?
    /// Chorus return level 0...1. Default 0.7.
    public var chorusLevel: Double?
    /// Chorus modulation depth (0...10 ms, default 4), rate (Hz, default 0.6) and base delay (1...30 ms, default 12).
    public var chorusDepthMs: Double?, chorusRateHz: Double?, chorusDelayMs: Double?
    public init(enabled: Bool? = nil, roomSize: Double? = nil, damping: Double? = nil, reverbLevel: Double? = nil,
                chorusLevel: Double? = nil, chorusDepthMs: Double? = nil, chorusRateHz: Double? = nil, chorusDelayMs: Double? = nil) {
        self.enabled = enabled; self.roomSize = roomSize; self.damping = damping; self.reverbLevel = reverbLevel
        self.chorusLevel = chorusLevel; self.chorusDepthMs = chorusDepthMs; self.chorusRateHz = chorusRateHz; self.chorusDelayMs = chorusDelayMs
    }
    /// gbk `EFFECTS_DEFAULTS`.
    public static let defaults = SF2EffectsParams(enabled: true, roomSize: 0.5, damping: 0.5, reverbLevel: 0.5, chorusLevel: 0.7,
                                                  chorusDepthMs: 4, chorusRateHz: 0.6, chorusDelayMs: 12)
}
