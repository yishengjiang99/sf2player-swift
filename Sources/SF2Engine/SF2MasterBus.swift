// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Master-bus parameters. This stage is non-normative: SoundFont 2.01 has no master output stage.
public struct MasterBusParams: Equatable, Sendable {
    public var thresholdDb = -6.0, ratio = 4.0, kneeDb = 6.0, attackMs = 5.0, releaseMs = 100.0
    public var ceilingDb = -0.3, limiterReleaseMs = 50.0, lookaheadMs = 1.5
    public init() {}
}

/// Master-bus dynamics, applied after the voice mix and the effect returns. It mirrors gbk
/// src/sf2/master-bus.ts operation for operation (cross-engine parity). The stages are:
/// 1. masterGain, applied by the engine.
/// 2. A stereo-linked feed-forward compressor: peak max(|L|,|R|), a soft-knee dB gain computer,
///    and one-pole attack/release coefficients exp(-1/(t sr)).
/// 3. A brickwall lookahead limiter: the ceiling defaults to -0.3 dBFS, the ring buffer is
///    preallocated, gain drops instantly to the window minimum, and it recovers through a
///    one-pole release.
/// 4. A safety soft clip: unity below 0.9 x ceiling, then a tanh knee bounded by the ceiling,
///    so the output is always below 1.0.
/// `process` does not allocate, lock or retain.
public struct MasterBusRT {
    public static let maxLookaheadMs = 10.0
    static let grEpsDb = 1e-6, limEps = 1e-9
    public let sampleRate: Double
    public private(set) var params = MasterBusParams()
    var aAtt = 0.0, aRel = 0.0, aLim = 0.0, ceiling = 1.0
    var grDb = 0.0, limGain = 1.0
    public private(set) var latencyFrames = 0
    let cap: Int
    let ringL: UnsafeMutablePointer<Double>, ringR: UnsafeMutablePointer<Double>, ringReq: UnsafeMutablePointer<Double>
    var pos = 0, posReq = 0
    public var outL = 0.0, outR = 0.0

    public init(sampleRate: Double, params: MasterBusParams = MasterBusParams()) {
        self.sampleRate = sampleRate
        cap = Int((Self.maxLookaheadMs * 1e-3 * sampleRate).rounded(.up)) + 1
        ringL = .allocate(capacity: cap); ringR = .allocate(capacity: cap); ringReq = .allocate(capacity: cap)
        latencyFrames = -1
        setParams(params)
    }

    /// Releases the ring buffers. Call this exactly once.
    public func free() { ringL.deallocate(); ringR.deallocate(); ringReq.deallocate() }

    public var compressorReductionDb: Double { grDb }
    public var gainReductionDb: Double { grDb - 20 * log10(limGain) }

    /// Not real-time: call from control code. It resets the state when the lookahead changes.
    public mutating func setParams(_ q: MasterBusParams) {
        var p = q
        p.ratio = max(1, p.ratio); p.kneeDb = max(0, p.kneeDb); p.ceilingDb = min(-0.01, p.ceilingDb)
        p.lookaheadMs = min(Self.maxLookaheadMs, max(0, p.lookaheadMs))
        let sr = sampleRate
        func coef(_ ms: Double) -> Double { ms > 0 ? exp(-1 / (ms * 1e-3 * sr)) : 0 }
        aAtt = coef(p.attackMs); aRel = coef(p.releaseMs); aLim = coef(p.limiterReleaseMs)
        ceiling = pow(10, p.ceilingDb / 20)
        let la = Int((p.lookaheadMs * 1e-3 * sr).rounded(.toNearestOrAwayFromZero))
        let changed = la != latencyFrames
        params = p; latencyFrames = la
        if changed { reset() }
    }

    public mutating func reset() {
        grDb = 0; limGain = 1; pos = 0; posReq = 0; outL = 0; outR = 0
        ringL.update(repeating: 0, count: cap); ringR.update(repeating: 0, count: cap); ringReq.update(repeating: 1, count: cap)
    }

    @inline(__always) public static func reductionDb(_ levelDb: Double, _ thresholdDb: Double, _ ratio: Double, _ kneeDb: Double) -> Double {
        let over = levelDb - thresholdDb, slope = 1 - 1 / ratio
        if kneeDb > 0 && 2 * over > -kneeDb && 2 * over < kneeDb { let t = over + kneeDb / 2; return slope * t * t / (2 * kneeDb) }
        return over > 0 ? slope * over : 0
    }

    @inline(__always) public static func softClip(_ x: Double, _ ceiling: Double) -> Double {
        let k = 0.9 * ceiling, a = x < 0 ? -x : x
        if !(a > k) { return a == a ? x : 0 }
        let y = k + (ceiling - k) * tanh((a - k) / (ceiling - k))
        return x < 0 ? -y : y
    }

    @inline(__always) public mutating func process(_ inL: Double, _ inR: Double) {
        var l = inL, r = inR
        if !(l <= 1e30 && l >= -1e30) { l = 0 }
        if !(r <= 1e30 && r >= -1e30) { r = 0 }
        let al = l < 0 ? -l : l, ar = r < 0 ? -r : r
        let peak = al > ar ? al : ar
        let target = peak > 1e-10 ? Self.reductionDb(20 * log10(peak), params.thresholdDb, params.ratio, params.kneeDb) : 0
        let a = target > grDb ? aAtt : aRel
        grDb = target + a * (grDb - target)
        if grDb < Self.grEpsDb { grDb = 0 }
        let cg = pow(10, -grDb / 20)
        let cl = l * cg, cr = r * cg
        let acl = cl < 0 ? -cl : cl, acr = cr < 0 ? -cr : cr
        let pk = acl > acr ? acl : acr
        let req = pk > ceiling ? ceiling / pk : 1
        var dl = cl, dr = cr, minReq = req
        let la = latencyFrames
        if la > 0 {
            let i = pos
            dl = ringL[i]; dr = ringR[i]
            ringL[i] = cl; ringR[i] = cr
            pos = i + 1 == la ? 0 : i + 1
            let j = posReq
            ringReq[j] = req
            posReq = j == la ? 0 : j + 1
            var k = 0
            while k <= la { let q = ringReq[k]; if q < minReq { minReq = q }; k += 1 }
        }
        if minReq < limGain { limGain = minReq } else {
            limGain = minReq + aLim * (limGain - minReq)
            if 1 - limGain < Self.limEps { limGain = 1 }
        }
        outL = Self.softClip(dl * limGain, ceiling)
        outR = Self.softClip(dr * limGain, ceiling)
    }
}
