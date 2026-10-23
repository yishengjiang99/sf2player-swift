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
    var roomFeedback: Float = 0.84, damp: Float = 0.2, reverbWet: Float = 0.35
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
        // reverb (mono-summed input like Freeverb, stereo output)
        let input = Float((revL + revR) * 0.5) * 0.03
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
