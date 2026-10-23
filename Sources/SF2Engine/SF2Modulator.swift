// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// SoundFont 2.01 modulators (sections 8.2 to 8.5, 9.5; 2.04 additions gated by SF2SpecVersion): source enumeration and curves, the default
// modulator set, and the instrument/preset merge rules. Used only by `SF2Fidelity.spec`.

/// Rendering rules. `.gbk` reproduces yishengjiang99/gbk bit for bit (no modulators, CC or pitch
/// bend, gbk generator merge). `.spec` follows SoundFont 2.01 (2.04 behaviour only for files whose
/// ifil is >= 2.04, see `SF2SpecVersion`): zone override rules and 8.1.3 range clamping, the 2.01
/// default modulators plus file modulators, chapter 9 channel functions (sustain / sostenuto / soft
/// pedal, RPN 0 and NRPN, all-notes/sound-off, reset controllers, program change, channel and poly
/// pressure), exclusive classes, the 2.01 filter Q rule, linear pan, triangle LFOs, key-number
/// envelope scaling, and reverb / chorus sends (see docs/SF2_COMPLIANCE.md).
/// Rendering rules. There is one rule set: SoundFont 2.01 (`.spec`). `.gbk` is an alias of `.spec`.
/// The gbk JS engine (yishengjiang99/gbk, branch sf2-201-compliance) became a 2.01 port of this
/// engine, so the two are the same thing. See docs/SF2_COMPLIANCE.md "Fidelity".
public enum SF2Fidelity: Sendable {
    case spec
    /// Alias of `.spec`: the gbk engine is now SoundFont 2.01 compliant, and the old gbk-legacy rules are gone.
    public static let gbk: SF2Fidelity = .spec
}

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

    /// Virtual "Initial Pitch" destination (cents) of default modulator 8.4.10. It lives outside the
    /// file enumerator space (0...63, sfGenOper values a file can name as a value generator), so file data can never
    /// reach it (M-07; generator 59 is the reserved `unused5`).
    public static let pitchDest: UInt16 = 64
    /// Slots in a modulator destination accumulator (generators 0...63 plus `pitchDest`).
    public static let slotCount = 65

    /// SoundFont 2.04 default modulators as used before (8 entries: no effects-send defaults,
    /// velocity-to-filter without the switch amount source). Used for files with ifil >= 2.04.
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

    /// SoundFont 2.01 section 8.4: exactly ten default modulators. Errata resolved: 8.4.2's amount
    /// source is printed 0x502 but its field breakdown (type 3 switch, D=1, index 2) is 0x0D02;
    /// 8.4.6's printed destination "Initial Attenuation" is pan (#17) per its prose.
    public static let defaults201: [SF2Modulator] = [
        SF2Modulator(src: 0x0502, dest: 48, amount: 960),                    // 8.4.1
        SF2Modulator(src: 0x0102, dest: 8, amount: -2400, amtSrc: 0x0D02),   // 8.4.2
        SF2Modulator(src: 0x000D, dest: 6, amount: 50),                      // 8.4.3
        SF2Modulator(src: 0x0081, dest: 6, amount: 50),                      // 8.4.4
        SF2Modulator(src: 0x0587, dest: 48, amount: 960),                    // 8.4.5
        SF2Modulator(src: 0x028A, dest: 17, amount: 1000),                   // 8.4.6
        SF2Modulator(src: 0x058B, dest: 48, amount: 960),                    // 8.4.7
        SF2Modulator(src: 0x00DB, dest: 16, amount: 200),                    // 8.4.8 CC91 -> reverb send
        SF2Modulator(src: 0x00DD, dest: 15, amount: 200),                    // 8.4.9 CC93 -> chorus send
        SF2Modulator(src: 0x020E, dest: pitchDest, amount: 12700, amtSrc: 0x0010), // 8.4.10
    ]

    /// Default modulators for a file version (2.00/2.01 -> `defaults201`, >= 2.04 -> `defaults`).
    public static func defaults(for version: SF2SpecVersion) -> [SF2Modulator] {
        version.has204Features ? defaults : defaults201
    }

    /// 8.2 / 8.2.1 / 8.2.4: a source word is usable when its type is 0...3 and its index is defined in
    /// the general-controller palette (0, 2, 3, 10, 13, 14, 16) or is a legal MIDI CC.
    static func sourceIsValid(_ w: UInt16) -> Bool {
        if w >> 10 > 3 { return false }
        let idx = Int(w & 0x7F)
        if w & 0x80 != 0 {
            if [0, 6, 32, 38, 98, 99, 100, 101].contains(idx) || idx >= 120 || (33 ... 63).contains(idx) { return false }
            return true
        }
        return [0, 2, 3, 10, 13, 14, 16].contains(idx)
    }

    /// Whether a file modulator is applied at all (M-01, M-02, M-05, M-06, M-07). Invalid
    /// modulators are ignored entirely (they do not replace defaults either).
    static func isValid(_ m: SF2Modulator, version: SF2SpecVersion) -> Bool {
        sourceIsValid(m.src) && sourceIsValid(m.amtSrc) && version.isValidTransform(m.transform)
            && m.dest & 0x8000 == 0 && GenInfo.isValueGenerator(Int(m.dest))
    }

    /// 9.5: instrument-zone modulators (global then local, local replacing identical) replace identical
    /// defaults; preset-zone modulators (same rule) are added on top, identical ones summing amounts.
    static func merge(instGlobal: [SF2Modulator], instLocal: [SF2Modulator], presetGlobal: [SF2Modulator],
                      presetLocal: [SF2Modulator], version: SF2SpecVersion = SF2SpecVersion(major: 2, minor: 4)) -> [SF2Modulator] {
        func overlay(_ base: [SF2Modulator], _ top: [SF2Modulator]) -> [SF2Modulator] {
            var out = base
            for m in top where isValid(m, version: version) {
                if let i = out.firstIndex(where: { $0.sameIdentity(m) }) { out[i] = m } else { out.append(m) }
            }
            return out
        }
        let inst = overlay(overlay(defaults(for: version), instGlobal), instLocal)
        let preset = overlay(presetGlobal, presetLocal)
        var out = inst
        for m in preset {
            if let i = out.firstIndex(where: { $0.sameIdentity(m) }) {
                out[i].amount = Int16(clamping: Int(out[i].amount) + Int(m.amount))
            } else { out.append(m) }
        }
        return out.filter { $0.amount != 0 }
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
    var polyPressure: Int = 0
}

/// 8.2.1 SFModulator source value after direction, polarity and curve. Mapping (section 9.5.3
/// Table 2): unipolar u = v/128 (7-bit) or v/16384 (14-bit), so the maximum is 127/128, not 1;
/// negative direction u = (max - v)/range. Bipolar b = 2u - 1 around the MIDI center (64 / 8192 -> 0,
/// 0 -> -1); the negative direction negates b; curves shape |b| and keep the sign.
/// Pitch-wheel sensitivity (index 16) is mapped s/127 so that amount 12700 x s/127 = s x 100 cents
/// (8.4.10 erratum: v/128 would give 198.4 cents for 2 semitones).
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
        case 0: return 1                                   // 8.2.1 no controller: 1 ("not a means to turn off")
        case 2: raw = Double(i.velocity)
        case 3: raw = Double(i.key)
        case 10: raw = Double(i.polyPressure)
        case 13: raw = Double(i.channelPressure)
        case 14: raw = Double(i.pitchWheel); range = 16384
        case 16:
            let x = min(1, i.pitchWheelSensitivity / 127)
            return modCurve(type, negative ? 1 - x : x)
        default: return 0
        }
    }
    if bipolar {
        var b = 2 * raw / range - 1
        if negative { b = -b }
        let s: Double = b < 0 ? -1 : 1
        return s * modCurve(type, min(1, abs(b)))
    }
    let x = negative ? (range - 1 - raw) / range : raw / range
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

/// Contribution of one modulator (9.5.1: amount x source x amount source, then transform).
/// The amount source "no controller" (0) maps to 1 (M-03/M-08).
@inline(__always) func modValue(_ m: SF2Modulator, _ i: ModInputs) -> Double {
    let s = modSourceValue(m.src, i)
    if s == 0 { return 0 }
    let a = m.amtSrc == 0 ? 1 : modSourceValue(m.amtSrc, i)
    let v = s * a * Double(m.amount)
    return m.transform == 2 ? abs(v) : v
}
