// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// Port of the DSP pieces of gbk src/sf2-renderer.ts. All math in Double like JS numbers;
// samples are Float32 like the Float32Arrays. Caches below only skip recomputing values from
// identical inputs, so outputs are the same as recomputing every sample.

@inline(__always) func timecentsToSeconds(_ tc: Double) -> Double { pow(2, tc / 1200) }
@inline(__always) func centsToRatio(_ c: Double) -> Double { pow(2, c / 1200) }
@inline(__always) func cbAttenToLin(_ cb: Double) -> Double { pow(10, (-cb / 10) / 20) }
@inline(__always) func velToLin(_ vel: Double, _ curve: Double = 2.0) -> Double { pow(max(0, min(127, vel)) / 127, curve) }
@inline(__always) func fcCentsToHz(_ fc: Double) -> Double { 8.176 * pow(2, fc / 1200) }
@inline(__always) func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

let MIN_VOL_RELEASE_SEC = 0.06
let MIN_MOD_RELEASE_SEC = 0.02

public enum EnvStage: UInt8, Sendable {
    case idle, delay, attack, hold, decay, sustain, release
}

struct VolEnv {
    var sr: Double
    var stage: EnvStage = .idle
    var level = 0.0, t = 0.0, peak = 1.0
    var delay = 0.0, attack = 0.01, hold = 0.0, decay = 0.1, sustain = 0.5, release = 0.2, releaseStart = 0.0
    // log caches (same values Math.log would produce each sample)
    var logDecayStart = 0.0, logDecayEnd = log(0.5), logReleaseStart = log(1e-5)
    static let eps = 1e-5
    static let logEps = log(1e-5)

    init(sr: Double) {
        self.sr = sr
        logDecayStart = log(max(Self.eps, peak))
    }

    mutating func setFromSf2(_ e: SF2VolEnv) {
        delay = max(0, timecentsToSeconds(Double(e.delayTc)))
        attack = max(0, timecentsToSeconds(Double(e.attackTc)))
        hold = max(0, timecentsToSeconds(Double(e.holdTc)))
        decay = max(0, timecentsToSeconds(Double(e.decayTc)))
        release = max(MIN_VOL_RELEASE_SEC, timecentsToSeconds(Double(e.releaseTc)))
        let sustainDb = -Double(e.sustainCb) / 10
        sustain = min(1, max(0, pow(10, sustainDb / 20)))
        logDecayStart = log(max(Self.eps, peak))
        logDecayEnd = log(max(Self.eps, sustain))
    }

    mutating func noteOn() {
        stage = delay > 0 ? .delay : .attack
        t = 0
        level = 0
    }

    mutating func noteOff() {
        if stage == .idle { return }
        stage = .release
        t = 0
        releaseStart = level
        logReleaseStart = log(max(Self.eps, releaseStart))
    }

    @inline(__always) mutating func next() -> Double {
        let dt = 1 / sr
        switch stage {
        case .idle:
            level = 0
            return 0
        case .delay:
            t += dt
            if t >= delay { stage = .attack; t = 0 }
            level = 0
            return 0
        case .attack:
            if attack <= 0 {
                level = peak
                stage = hold > 0 ? .hold : .decay
                t = 0
                return level
            }
            t += dt
            let x = min(1, t / attack)
            level = peak * (1 - exp(-x * 6))
            if x >= 1 {
                level = peak
                stage = hold > 0 ? .hold : .decay
                t = 0
            }
            return level
        case .hold:
            t += dt
            level = peak
            if t >= hold { stage = .decay; t = 0 }
            return level
        case .decay:
            if decay <= 0 {
                level = sustain
                stage = .sustain
                t = 0
                return level
            }
            t += dt
            let x = min(1, t / decay)
            level = exp(logDecayStart + (logDecayEnd - logDecayStart) * x)
            if x >= 1 { level = sustain; stage = .sustain; t = 0 }
            return level
        case .sustain:
            level = sustain
            return level
        case .release:
            if release <= 0 { level = 0; stage = .idle; return 0 }
            t += dt
            let x = min(1, t / release)
            level = exp(logReleaseStart + (Self.logEps - logReleaseStart) * x)
            if x >= 1 { level = 0; stage = .idle }
            return level
        }
    }
}

struct ModEnv {
    var sr: Double
    var stage: EnvStage = .idle
    var level = 0.0, t = 0.0
    var delay = 0.0, attack = 0.01, hold = 0.0, decay = 0.1, sustain = 0.0, release = 0.2, releaseStart = 0.0

    init(sr: Double) { self.sr = sr }

    mutating func setFromSf2(_ e: SF2ModEnv) {
        delay = max(0, timecentsToSeconds(Double(e.delayTc)))
        attack = max(0, timecentsToSeconds(Double(e.attackTc)))
        hold = max(0, timecentsToSeconds(Double(e.holdTc)))
        decay = max(0, timecentsToSeconds(Double(e.decayTc)))
        release = max(MIN_MOD_RELEASE_SEC, timecentsToSeconds(Double(e.releaseTc)))
        sustain = min(1, max(0, e.sustain))
    }

    mutating func noteOn() { stage = delay > 0 ? .delay : .attack; t = 0; level = 0 }

    mutating func noteOff() {
        if stage == .idle { return }
        stage = .release
        t = 0
        releaseStart = level
    }

    @inline(__always) mutating func next() -> Double {
        let dt = 1 / sr
        switch stage {
        case .idle:
            level = 0
            return 0
        case .delay:
            t += dt
            if t >= delay { stage = .attack; t = 0 }
            level = 0
            return 0
        case .attack:
            if attack <= 0 {
                level = 1
                stage = hold > 0 ? .hold : .decay
                t = 0
                return level
            }
            t += dt
            let x = min(1, t / attack)
            level = x
            if x >= 1 { level = 1; stage = hold > 0 ? .hold : .decay; t = 0 }
            return level
        case .hold:
            t += dt
            level = 1
            if t >= hold { stage = .decay; t = 0 }
            return level
        case .decay:
            if decay <= 0 { level = sustain; stage = .sustain; t = 0; return level }
            t += dt
            let x = min(1, t / decay)
            level = lerp(1, sustain, x)
            if x >= 1 { level = sustain; stage = .sustain; t = 0 }
            return level
        case .sustain:
            level = sustain
            return level
        case .release:
            if release <= 0 { level = 0; stage = .idle; return 0 }
            t += dt
            let x = min(1, t / release)
            level = lerp(releaseStart, 0, x)
            if x >= 1 { level = 0; stage = .idle }
            return level
        }
    }
}

struct LFO {
    var sr: Double
    var phase = 0.0
    var freqHz = 5.0
    var delayLeft = 0.0

    init(sr: Double) { self.sr = sr }

    mutating func set(freqHz: Double, delaySec: Double) {
        self.freqHz = max(0, freqHz)
        delayLeft = max(0, delaySec)
    }

    @inline(__always) mutating func next() -> Double {
        if delayLeft > 0 {
            delayLeft -= 1 / sr
            return 0
        }
        phase += (2 * Double.pi * freqHz) / sr
        if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        return sin(phase)
    }
}

struct TwoPoleLPF {
    var sr: Double
    var z1L = 0.0, z2L = 0.0, z1R = 0.0, z2R = 0.0
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    init(sr: Double) { self.sr = sr }

    @inline(__always) mutating func setCutoffHz(_ hz: Double) {
        let clamped = max(5, min(hz, sr * 0.45))
        let q = 0.7071
        let w0 = (2 * Double.pi * clamped) / sr
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2 * q)
        let a0 = 1 + alpha
        b0 = ((1 - cosw0) / 2) / a0
        b1 = (1 - cosw0) / a0
        b2 = ((1 - cosw0) / 2) / a0
        a1 = (-2 * cosw0) / a0
        a2 = (1 - alpha) / a0
    }

    @inline(__always) mutating func processL(_ x: Double) -> Double {
        let y = b0 * x + z1L
        z1L = b1 * x - a1 * y + z2L
        z2L = b2 * x - a2 * y
        return y
    }

    @inline(__always) mutating func processR(_ x: Double) -> Double {
        let y = b0 * x + z1R
        z1R = b1 * x - a1 * y + z2R
        z2R = b2 * x - a2 * y
        return y
    }
}
