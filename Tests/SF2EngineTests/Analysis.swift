// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
@testable import SF2Engine

/// Analytic measurements on rendered audio (spec behavior is asserted by measuring, not snapshots).
enum Analysis {
    static func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

    /// RMS in dB of `x[from ..< from + count]`.
    static func rmsDB(_ x: [Float], from: Int = 0, count: Int? = nil) -> Double {
        let n = min(count ?? x.count - from, x.count - from)
        guard n > 0 else { return -240 }
        var s = 0.0
        for i in from ..< from + n { s += Double(x[i]) * Double(x[i]) }
        return db((s / Double(n)).squareRoot())
    }

    /// Per-window RMS envelope in dB (window in frames).
    static func envelopeDB(_ x: [Float], window: Int) -> [Double] {
        stride(from: 0, to: x.count - window + 1, by: window).map { rmsDB(x, from: $0, count: window) }
    }

    /// Peak |x| in dB over a range.
    static func peakDB(_ x: [Float], from: Int = 0, count: Int? = nil) -> Double {
        let n = min(count ?? x.count - from, x.count - from)
        var p = 0.0
        for i in from ..< from + n { p = max(p, abs(Double(x[i]))) }
        return db(p)
    }

    /// f0 from linearly interpolated rising zero crossings (best for clean periodic signals).
    static func f0ZeroCrossing(_ x: [Float], sampleRate: Double, from: Int = 0, count: Int? = nil) -> Double {
        let n = min(count ?? x.count - from, x.count - from)
        var times: [Double] = []
        for i in from + 1 ..< from + n where x[i - 1] < 0 && x[i] >= 0 {
            let a = Double(x[i - 1]), b = Double(x[i])
            times.append(Double(i - 1) + (-a) / (b - a))
        }
        guard times.count >= 2 else { return 0 }
        return Double(times.count - 1) * sampleRate / (times.last! - times.first!)
    }

    /// f0 from the autocorrelation peak with parabolic interpolation (robust for complex tones).
    static func f0Autocorrelation(_ x: [Float], sampleRate: Double, from: Int = 0, count: Int = 8192,
                                  minHz: Double = 20, maxHz: Double = 5000) -> Double {
        let n = min(count, x.count - from)
        let minLag = max(1, Int(sampleRate / maxHz)), maxLag = min(n / 2, Int(sampleRate / minHz))
        guard maxLag > minLag + 2 else { return 0 }
        func r(_ lag: Int) -> Double {
            var s = 0.0
            for i in 0 ..< n - lag { s += Double(x[from + i]) * Double(x[from + i + lag]) }
            return s / Double(n - lag)
        }
        let rs = (minLag ... maxLag).map(r)
        // first local maximum above 0.9 of the global max (avoids octave errors)
        let gmax = rs.max() ?? 0
        var k = rs.indices.first { i in i > 0 && i < rs.count - 1 && rs[i] >= rs[i - 1] && rs[i] >= rs[i + 1] && rs[i] > 0.9 * gmax } ?? 0
        if k == 0 { k = rs.firstIndex(of: gmax) ?? 1 }
        k = max(1, min(rs.count - 2, k))
        let a = rs[k - 1], b = rs[k], c = rs[k + 1]
        let off = (a - 2 * b + c) == 0 ? 0 : 0.5 * (a - c) / (a - 2 * b + c)
        return sampleRate / (Double(minLag + k) + off)
    }

    static func cents(_ f: Double, _ ref: Double) -> Double { 1200 * log2(f / ref) }

    /// Single-bin DFT (Goertzel) amplitude of `freq` in `x` (a full-scale sine reads 1.0).
    static func goertzel(_ x: [Float], freq: Double, sampleRate: Double, from: Int = 0, count: Int? = nil) -> Double {
        let n = min(count ?? x.count - from, x.count - from)
        let w = 2 * Double.pi * freq / sampleRate
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in from ..< from + n { let s0 = Double(x[i]) + coeff * s1 - s2; s2 = s1; s1 = s0 }
        let re = s1 - s2 * cos(w), im = s2 * sin(w)
        return 2 * (re * re + im * im).squareRoot() / Double(n) / (freq == 0 ? 2 : 1)
    }

    /// L/R RMS ratio in dB.
    static func lrRatioDB(_ l: [Float], _ r: [Float], from: Int = 0, count: Int? = nil) -> Double {
        rmsDB(l, from: from, count: count) - rmsDB(r, from: from, count: count)
    }

    /// First window index (in frames) where the windowed level crosses `thresholdDB` in the given direction.
    static func firstCrossing(_ x: [Float], thresholdDB: Double, rising: Bool, window: Int = 16, from: Int = 0) -> Int? {
        var i = from
        while i + window <= x.count {
            let lv = peakDB(x, from: i, count: window)
            if rising ? lv >= thresholdDB : lv <= thresholdDB { return i }
            i += window
        }
        return nil
    }
}

/// Renders a `.spec` note from an in-memory bank.
struct SpecRender {
    let engine: Sf2SynthEngine
    let sampleRate: Double

    init(_ b: SF2Builder, preset: Int = 0, sampleRate: Double = 44100, maxVoices: Int = 64) throws {
        let sf = try SF2SoundFont(data: b.build(), options: .strict)
        engine = Sf2SynthEngine(outSr: sampleRate, maxVoices: maxVoices)
        engine.fidelity = .spec
        engine.setTrackStates([SF2TrackState(trackIndex: 0, regions: try sf.regionList(forPreset: preset, fidelity: .spec))])
        self.sampleRate = sampleRate
    }

    func noteOn(_ key: Int = 60, velocity: Int = 127, channel: Int = 0) {
        engine.dispatchEvent(.noteOn(key, velocity: velocity, trackIndex: 0, channel: channel))
    }
    func noteOff(_ key: Int = 60, channel: Int = 0) { engine.dispatchEvent(.noteOff(key, trackIndex: 0, channel: channel)) }
    func cc(_ c: Int, _ v: Int, channel: Int = 0) { engine.dispatchEvent(.controlChange(c, value: v, trackIndex: 0, channel: channel)) }

    func render(_ frames: Int) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: 0, count: frames), r = [Float](repeating: 0, count: frames)
        engine.renderRange(&l, &r)
        return (l, r)
    }
    func seconds(_ s: Double) -> Int { Int((s * sampleRate).rounded()) }
}
