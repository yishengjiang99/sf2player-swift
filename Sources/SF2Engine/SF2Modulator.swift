// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// SoundFont 2.04 modulators (section 8.2 to 8.5): source enumeration and curves, the default
// modulator set, and the instrument/preset merge rules. Used only by `SF2Fidelity.spec`.

/// Rendering rules. `.gbk` reproduces yishengjiang99/gbk bit for bit (no modulators, CC or pitch
/// bend, gbk generator merge). `.spec` follows SoundFont 2.04: zone override rules, default and file
/// modulators, live MIDI channel controllers (CC1/7/10/11, pitch bend + RPN 0 range), filter Q,
/// triangle LFOs at 8.176 Hz x 2^(cents/1200), key-number envelope scaling, per-channel presets.
public enum SF2Fidelity: Sendable { case gbk, spec }

/// One modulator (sfModList record). `src` / `amtSrc` are raw SFModulator words.
public struct SF2Modulator: Equatable, Sendable {
    public var src: UInt16
    public var dest: UInt16
    public var amount: Int16
    public var amtSrc: UInt16
    public var transform: UInt16

    public init(src: UInt16, dest: UInt16, amount: Int16, amtSrc: UInt16 = 0, transform: UInt16 = 0) {
        self.src = src; self.dest = dest; self.amount = amount; self.amtSrc = amtSrc; self.transform = transform
    }

    init(_ r: SF2ModRecord) {
        self.init(src: UInt16(truncatingIfNeeded: r.srcOper), dest: UInt16(truncatingIfNeeded: r.destOper),
                  amount: Int16(truncatingIfNeeded: r.amount), amtSrc: UInt16(truncatingIfNeeded: r.amtSrcOper),
                  transform: UInt16(truncatingIfNeeded: r.transOper))
    }

    /// 8.2.1: two modulators are identical when source, destination, amount source and transform match.
    func sameIdentity(_ o: SF2Modulator) -> Bool {
        src == o.src && dest == o.dest && amtSrc == o.amtSrc && transform == o.transform
    }

    /// Generator destinations; 59 is the virtual "initial pitch" (cents) of the default pitch-wheel modulator.
    public static let pitchDest: UInt16 = 59

    /// SF2.04 section 8.4 default modulators (reverb/chorus sends are omitted: no effects bus).
    public static let defaults: [SF2Modulator] = [
        SF2Modulator(src: 0x0502, dest: 48, amount: 960),            // 8.4.1 velocity -> attenuation (concave, negative)
        SF2Modulator(src: 0x0102, dest: 8, amount: -2400),           // 8.4.2 velocity -> filter cutoff (linear, negative)
        SF2Modulator(src: 0x000D, dest: 6, amount: 50),              // 8.4.3 channel pressure -> vibrato LFO pitch
        SF2Modulator(src: 0x0081, dest: 6, amount: 50),              // 8.4.4 CC1 mod wheel -> vibrato LFO pitch
        SF2Modulator(src: 0x0587, dest: 48, amount: 960),            // 8.4.5 CC7 volume -> attenuation (concave, negative)
        SF2Modulator(src: 0x028A, dest: 17, amount: 1000),           // 8.4.6 CC10 pan -> pan (linear, bipolar)
        SF2Modulator(src: 0x058B, dest: 48, amount: 960),            // 8.4.7 CC11 expression -> attenuation
        SF2Modulator(src: 0x020E, dest: pitchDest, amount: 12700, amtSrc: 0x0010), // 8.4.10 pitch wheel x sensitivity
    ]

    /// 9.5: instrument-zone modulators (global then local, local replacing identical) replace identical
    /// defaults; preset-zone modulators (same rule) are added on top.
    static func merge(instGlobal: [SF2Modulator], instLocal: [SF2Modulator], presetGlobal: [SF2Modulator],
                      presetLocal: [SF2Modulator]) -> [SF2Modulator] {
        func overlay(_ base: [SF2Modulator], _ top: [SF2Modulator]) -> [SF2Modulator] {
            var out = base
            for m in top {
                if let i = out.firstIndex(where: { $0.sameIdentity(m) }) { out[i] = m } else { out.append(m) }
            }
            return out
        }
        let inst = overlay(overlay(defaults, instGlobal), instLocal)
        let preset = overlay(presetGlobal, presetLocal)
        // Preset modulators add to the instrument ones; an identical pair sums its amounts.
        var out = inst
        for m in preset {
            if let i = out.firstIndex(where: { $0.sameIdentity(m) }) {
                out[i].amount = Int16(clamping: Int(out[i].amount) + Int(m.amount))
            } else { out.append(m) }
        }
        // Drop links (dest bit 15) and amount-0 records; they contribute nothing here.
        return out.filter { $0.dest & 0x8000 == 0 && $0.amount != 0 && $0.dest < 64 }
    }
}

/// Controller state a modulator source reads (one MIDI channel plus the note).
struct ModInputs {
    var velocity: Int
    var key: Int
    var cc: UnsafePointer<UInt8>       // 128 controllers
    var pitchWheel: Int                // 0...16383, 8192 = center
    var pitchWheelSensitivity: Double  // semitones
    var channelPressure: Int
}

/// 8.2.1 SFModulator source value after direction, polarity and curve, in -1...1. Unipolar sources
/// span 0...max (full scale reached); bipolar ones are centered on the MIDI center (64 / 8192), so
/// CC10 = 64 and an unbent wheel give exactly 0 and the lowest value gives exactly -1.
@inline(__always) func modSourceValue(_ word: UInt16, _ i: ModInputs) -> Double {
    let index = Int(word & 0x7F)
    let isCC = word & 0x80 != 0
    let negative = word & 0x100 != 0
    let bipolar = word & 0x200 != 0
    let type = Int(word >> 10)
    var raw: Double, range = 128.0
    if isCC {
        raw = Double(i.cc[index])
    } else {
        switch index {
        case 0: return 1                                   // no controller: constant 1 (amount used as-is)
        case 2: raw = Double(i.velocity)
        case 3: raw = Double(i.key)
        case 10: raw = 0                                   // poly pressure: not tracked
        case 13: raw = Double(i.channelPressure)
        case 14: raw = Double(i.pitchWheel); range = 16384
        case 16: return modCurve(type, negative ? 1 - i.pitchWheelSensitivity / 127 : i.pitchWheelSensitivity / 127)
        default: return 0
        }
    }
    if bipolar {
        var b = 2 * raw / range - 1
        if negative { b = -b }
        let s: Double = b < 0 ? -1 : 1
        return s * modCurve(type, min(1, abs(b)))
    }
    var x = raw / (range - 1)
    if negative { x = 1 - x }
    return modCurve(type, x)
}

/// Curve types on 0...1: 0 linear, 1 concave, 2 convex, 3 switch.
@inline(__always) func modCurve(_ type: Int, _ x: Double) -> Double {
    switch type {
    case 1: return concave(x)
    case 2: return 1 - concave(1 - x)
    case 3: return x >= 0.5 ? 1 : 0
    default: return x
    }
}

/// SF2 concave curve: -(20/96) log10((1 - x)^2), clipped to 0...1.
@inline(__always) func concave(_ x: Double) -> Double {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    return min(1, -(20.0 / 96.0) * log10((1 - x) * (1 - x)))
}

/// Contribution of one modulator (8.2: source x amount-source x amount, then transform).
@inline(__always) func modValue(_ m: SF2Modulator, _ i: ModInputs) -> Double {
    if m.src & 0xFF == 0 { return 0 }                      // primary source "no controller": no output
    let s = modSourceValue(m.src, i)
    if s == 0 { return 0 }
    let a = m.amtSrc == 0 ? 1 : modSourceValue(m.amtSrc, i)
    let v = s * a * Double(m.amount)
    return m.transform == 2 ? abs(v) : v
}
