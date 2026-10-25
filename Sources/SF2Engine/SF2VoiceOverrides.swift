// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// Per-track / per-key-range SoundFont generator overrides layered on top of the SF2 zones (port of gbk
// src/sf2/voice-overrides.ts, gbk 4d788d7). Non-normative engine extension.
//
// An override targets one SF2 2.01 generator (8.1.2 ids) in native units:
//   .add: the amount is added to the zone's generator value (like an SF2 NRPN offset, 9.6).
//   .set: the zone's generator value is replaced (absolute, clamped to 8.1.3); modulators still add on top.
// Overrides are summed into the voice's modulator accumulator, so every result is clamped to the generator's
// range by the existing engine code. They apply at note-on; realtime generators of sounding voices can be
// refreshed on request (`Sf2SynthEngine.setVoiceOverrides(_:trackIndex:updateActive:)`).

public struct SF2VoiceOverride: Equatable, Sendable {
    public enum Mode: String, Sendable { case add, set }
    public var gen: Int
    public var mode: Mode
    public var value: Double
    /// Optional inclusive MIDI key range the override applies to.
    public var keyLo: Int?, keyHi: Int?
    public init(gen: Int, mode: Mode, value: Double, keyLo: Int? = nil, keyHi: Int? = nil) {
        self.gen = gen; self.mode = mode; self.value = value; self.keyLo = keyLo; self.keyHi = keyHi
    }

    /// Generators an override may target (gbk `VOICE_PARAMS`).
    public static let editableGenerators: Set<Int> = [33, 34, 35, 36, 37, 38, 39, 40, 25, 26, 27, 28, 29, 30, 7, 11, 8, 9,
                                                      21, 22, 5, 10, 13, 23, 24, 6, 51, 52, 56, 17, 48, 15, 16]

    /// gbk `validateOverride`: nil when valid, else the reason.
    public var validationError: String? {
        guard Self.editableGenerators.contains(gen) else { return "generator \(gen) is not an editable voice parameter" }
        guard let (lo, hi) = GenInfo.valueRange(gen) else { return "generator \(gen) has no value range" }
        guard value.isFinite else { return "value must be a finite number" }
        if mode == .set && (value < Double(lo) || value > Double(hi)) { return "generator \(gen): \(value) outside SF2 range [\(lo), \(hi)]" }
        if mode == .add && abs(value) > Double(hi - lo) { return "generator \(gen): offset \(value) exceeds range span \(hi - lo)" }
        for k in [keyLo, keyHi] { if let k, !(0 ... 127).contains(k) { return "key range must be 0..127" } }
        if let a = keyLo, let b = keyHi, a > b { return "keyLo must be <= keyHi" }
        return nil
    }
}

/// POD override for the real-time path.
struct OverrideRT { var gen: Int32; var set: Bool; var value: Double; var keyLo: Int32; var keyHi: Int32 }

extension VoiceRegion {
    /// The zone's (pre-modulator) value of a generator in native units (gbk `regionGenValue`).
    func genValue(_ gen: Int) -> Double {
        switch gen {
        case 5: return Double(modLfoToPitchCents); case 6: return Double(vibLfoToPitchCents); case 7: return Double(modEnvToPitchCents)
        case 8: return Double(initialFilterFcCents); case 9: return Double(initialFilterQCb); case 10: return Double(modLfoToFilterFcCents)
        case 11: return Double(modEnvToFilterFcCents); case 13: return Double(modLfoToVolumeCb); case 15: return Double(chorusSend)
        case 16: return Double(reverbSend); case 17: return Double(pan); case 21: return Double(modLfoDelayTc); case 22: return Double(modLfoFreqCents)
        case 23: return Double(vibLfoDelayTc); case 24: return Double(vibLfoFreqCents)
        case 25: return Double(modEnv.delayTc); case 26: return Double(modEnv.attackTc); case 27: return Double(modEnv.holdTc)
        case 28: return Double(modEnv.decayTc); case 29: return jsRound((1 - modEnv.sustain) * 1000)
        case 30: return Double(modEnv.releaseTc)
        case 31: return Double(keynumToModEnvHold); case 32: return Double(keynumToModEnvDecay)
        case 33: return Double(volEnv.delayTc); case 34: return Double(volEnv.attackTc); case 35: return Double(volEnv.holdTc)
        case 36: return Double(volEnv.decayTc); case 37: return Double(volEnv.sustainCb); case 38: return Double(volEnv.releaseTc)
        case 39: return Double(keynumToVolEnvHold); case 40: return Double(keynumToVolEnvDecay)
        case 48: return Double(initialAttenuationCb); case 51: return Double(coarseTune); case 52: return Double(fineTune)
        case 56: return Double(scaleTuning)
        default: return 0
        }
    }
}

/// JavaScript `Math.round` (half toward +infinity).
@inline(__always) func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

/// gbk `computeOverrideDeltas`: fills out[0..<61] with generator deltas. Returns whether any override applied.
@inline(__always) func computeOverrideDeltas(_ list: UnsafePointer<OverrideRT>?, _ count: Int, _ r: VoiceRegion, key: Int,
                                             _ out: UnsafeMutablePointer<Double>) -> Bool {
    for k in 0 ..< 61 { out[k] = 0 }
    guard let list, count > 0 else { return false }
    var any = false
    for i in 0 ..< count {
        let o = list[i]
        if o.keyLo >= 0 && key < Int(o.keyLo) { continue }
        if o.keyHi >= 0 && key > Int(o.keyHi) { continue }
        let g = Int(o.gen)
        guard g >= 0 && g < 61 else { continue }
        if o.set { out[g] = GenInfo.clamp(g, o.value) - r.genValue(g) } else { out[g] += o.value }
        any = true
    }
    return any
}
