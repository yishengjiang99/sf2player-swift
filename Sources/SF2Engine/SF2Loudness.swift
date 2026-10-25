// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// Port of gbk src/audio/loudness.ts (gbk 6c9eafc): ITU-R BS.1770-4 / EBU R128 integrated loudness (K-weighting,
// 400 ms blocks with 75 % overlap, -70 LUFS absolute and -10 LU relative gates) plus a 4x-oversampled true-peak
// estimate, used to choose ONE whole-file gain (CC / velocity dynamics and section contrasts are preserved).
// Offline only (allocates per 100 ms sub-block).

public struct SF2LoudnessStats: Equatable, Sendable {
    public var integratedLufs: Double, truePeakDbTP: Double, samplePeakDbFS: Double
}

public final class SF2LoudnessMeter {
    struct Biquad { var b0, b1, b2, a1, a2: Double }
    let sampleRate: Double
    let channels: Int
    private let s1: Biquad, s2: Biquad
    private var z: [Double]
    private var sub: [Double] = []
    private var acc = 0.0, accN = 0
    private let subLen: Int
    private var hist: [[Double]]
    private var hi = 0
    private let kern: [[Double]]
    private var tp = 0.0, sp = 0.0
    static let taps = 16, phases = 4

    /// - Parameter channels: 1 (the signal is measured as (L + R) / 2, like a mono encode) or 2.
    public init(sampleRate: Double, channels: Int = 2) {
        self.sampleRate = sampleRate; self.channels = channels == 1 ? 1 : 2
        // Stage 1: high shelf (+4 dB, ~1.68 kHz). Stage 2: RLB high-pass (~38 Hz). Same derivation as libebur128.
        var f0 = 1681.974450955533, Q = 0.7071752369554196
        let G = 3.999843853973347
        var K = tan(Double.pi * f0 / sampleRate)
        let Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q + K * K
        s1 = Biquad(b0: (Vh + Vb * K / Q + K * K) / a0, b1: 2 * (K * K - Vh) / a0, b2: (Vh - Vb * K / Q + K * K) / a0,
                    a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q + K * K) / a0)
        f0 = 38.13547087602444; Q = 0.5003270373238773; K = tan(Double.pi * f0 / sampleRate)
        a0 = 1 + K / Q + K * K
        s2 = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q + K * K) / a0)
        z = [Double](repeating: 0, count: self.channels * 4)
        subLen = Int((sampleRate * 0.1).rounded(.toNearestOrAwayFromZero))
        hist = [[Double]](repeating: [Double](repeating: 0, count: Self.taps), count: self.channels)
        var k: [[Double]] = []
        for ph in 1 ..< Self.phases {
            let frac = Double(ph) / Double(Self.phases)
            k.append((0 ..< Self.taps).map { t in
                let x = Double(t) - Double(Self.taps / 2 - 1) - frac
                let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                return sinc * 0.5 * (1 + cos(Double.pi * x / Double(Self.taps / 2 + 1)))
            })
        }
        kern = k
    }

    /// Feeds the signal exactly as it will be encoded, pre-gain.
    public func push(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        let a = s1, b = s2
        for i in 0 ..< n {
            var e = 0.0
            for c in 0 ..< channels {
                let x = channels == 1 ? (Double(l[i]) + Double(r[i])) * 0.5 : Double(c == 0 ? l[i] : r[i])
                let ax = abs(x); if ax > sp { sp = ax }
                hist[c][hi] = x
                for k in kern {
                    var s = 0.0
                    for t in 0 ..< Self.taps { s += k[t] * hist[c][(hi + 1 + t) % Self.taps] }
                    let as_ = abs(s); if as_ > tp { tp = as_ }
                }
                let o = c * 4
                var y = a.b0 * x + z[o]; z[o] = a.b1 * x - a.a1 * y + z[o + 1]; z[o + 1] = a.b2 * x - a.a2 * y
                let y2 = b.b0 * y + z[o + 2]; z[o + 2] = b.b1 * y - b.a1 * y2 + z[o + 3]; z[o + 3] = b.b2 * y - b.a2 * y2
                y = y2; e += y * y
            }
            hi = (hi + 1) % Self.taps
            acc += e; accN += 1
            if accN == subLen { sub.append(acc / Double(subLen)); acc = 0; accN = 0 }
        }
    }

    public func push(_ l: [Float], _ r: [Float]) {
        l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in push(lp.baseAddress!, rp.baseAddress!, min(l.count, r.count)) } }
    }

    /// Integrated loudness after a gain of `gainDb` (the -70 LUFS gate is not gain-invariant).
    public func integrated(atGainDb gainDb: Double) -> Double { integrated(pow(10, gainDb / 10)) }

    private func integrated(_ powGain: Double) -> Double {
        var blocks: [Double] = []
        if sub.count >= 4 { for i in 0 ... sub.count - 4 { blocks.append(powGain * (sub[i] + sub[i + 1] + sub[i + 2] + sub[i + 3]) / 4) } }
        func L(_ ms: Double) -> Double { -0.691 + 10 * log10(ms) }
        let abs_ = blocks.filter { $0 > 0 && L($0) > -70 }
        guard !abs_.isEmpty else { return -.infinity }
        let rel = L(abs_.reduce(0, +) / Double(abs_.count)) - 10
        let gated = abs_.filter { L($0) > rel }
        return gated.isEmpty ? -.infinity : L(gated.reduce(0, +) / Double(gated.count))
    }

    public func result() -> SF2LoudnessStats {
        func db(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -.infinity }
        return SF2LoudnessStats(integratedLufs: integrated(1), truePeakDbTP: db(max(tp, sp)), samplePeakDbFS: db(sp))
    }
}

public enum SF2Normalize: Sendable, Equatable {
    case off, peak
    /// Integrated loudness target (LUFS), capped by the true-peak ceiling.
    case loudness(targetLufs: Double)
    /// gbk's default for agent / export renders: -16 LUFS, true peak <= -1 dBTP.
    public static let gbkDefault = SF2Normalize.loudness(targetLufs: -16)
}

public struct SF2LoudnessReport: Equatable, Sendable {
    public enum Limit: String, Sendable { case loudness, truePeak, none }
    public var mode: SF2Normalize
    public var truePeakCeilingDbTP: Double
    public var input: SF2LoudnessStats
    /// Exact gain applied to every sample.
    public var gainDb: Double, gainLinear: Double
    public var outputLufs: Double, outputTruePeakDbTP: Double
    public var limitedBy: Limit

    public static let truePeakCeilingDbTP = -1.0
    /// Upper bound for loudness make-up gain (peak mode is uncapped).
    public static let maxGainDb = 40.0

    /// gbk `chooseGain`: one whole-file gain from measured stats (re-gated at the candidate gain when a meter is given).
    public static func choose(_ mode: SF2Normalize, _ s: SF2LoudnessStats, ceiling: Double = truePeakCeilingDbTP,
                              meter: SF2LoudnessMeter? = nil) -> SF2LoudnessReport {
        var gainDb = 0.0, limitedBy = Limit.none
        if mode != .off && s.truePeakDbTP.isFinite {
            let peakRoom = ceiling - s.truePeakDbTP
            switch mode {
            case .peak: gainDb = peakRoom; limitedBy = .truePeak
            case .loudness(let target):
                if s.integratedLufs.isFinite {
                    var want = target - s.integratedLufs
                    if let meter {
                        for _ in 0 ..< 8 {
                            let err = target - meter.integrated(atGainDb: want)
                            if !err.isFinite || abs(err) < 0.005 { break }
                            want += err
                        }
                    }
                    if want <= peakRoom { gainDb = want; limitedBy = .loudness } else { gainDb = peakRoom; limitedBy = .truePeak }
                } else { gainDb = peakRoom; limitedBy = .truePeak }
                if gainDb > maxGainDb { gainDb = maxGainDb; limitedBy = .none }
            case .off: break
            }
        }
        let outL = meter != nil && s.integratedLufs.isFinite ? meter!.integrated(atGainDb: gainDb) : s.integratedLufs + gainDb
        return SF2LoudnessReport(mode: mode, truePeakCeilingDbTP: ceiling, input: s, gainDb: gainDb, gainLinear: pow(10, gainDb / 20),
                                 outputLufs: outL, outputTruePeakDbTP: s.truePeakDbTP + gainDb, limitedBy: limitedBy)
    }
}
