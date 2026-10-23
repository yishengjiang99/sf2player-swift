// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// SoundFont 2.01 section 8.1.3 generator table: the single source of truth for kinds, defaults,
/// useful ranges, instrument-only (section 8.5) and real-time (non-`@`) flags. Used by the `.spec`
/// merge, clamping (section 10.5), the modulator destination check and NRPN selection.
struct GenInfo: Sendable {
    enum Kind: Sendable { case index, range, substitution, sample, value }
    var id: Int
    var kind: Kind
    var min: Int
    var max: Int
    var defaultValue: Int
    var instrumentOnly: Bool
    var realtime: Bool

    /// Index by generator id (0...60); nil for unused/reserved enumerators (14, 18, 19, 20, 42, 49, 55, 59, 60).
    static let table: [GenInfo?] = {
        var t = [GenInfo?](repeating: nil, count: 61)
        func v(_ id: Int, _ lo: Int, _ hi: Int, _ def: Int) { t[id] = GenInfo(id: id, kind: .value, min: lo, max: hi, defaultValue: def, instrumentOnly: false, realtime: true) }
        func s(_ id: Int, _ lo: Int, _ hi: Int, _ def: Int, realtime: Bool = true) {
            t[id] = GenInfo(id: id, kind: .sample, min: lo, max: hi, defaultValue: def, instrumentOnly: true, realtime: realtime)
        }
        let big = Int(Int16.max) * 32768
        s(0, 0, big, 0); s(1, -big, 0, 0); s(2, -big, big, 0); s(3, -big, big, 0); s(4, 0, Int(Int16.max), 0)
        v(5, -12000, 12000, 0); v(6, -12000, 12000, 0); v(7, -12000, 12000, 0)
        v(8, 1500, 13500, 13500); v(9, 0, 960, 0); v(10, -12000, 12000, 0); v(11, -12000, 12000, 0)
        s(12, Int(Int16.min), 0, 0); v(13, -960, 960, 0)
        v(15, 0, 1000, 0); v(16, 0, 1000, 0); v(17, -500, 500, 0)
        v(21, -12000, 5000, -12000); v(22, -16000, 4500, 0); v(23, -12000, 5000, -12000); v(24, -16000, 4500, 0)
        v(25, -12000, 5000, -12000); v(26, -12000, 8000, -12000); v(27, -12000, 5000, -12000); v(28, -12000, 8000, -12000)
        v(29, 0, 1000, 0); v(30, -12000, 8000, -12000); v(31, -1200, 1200, 0); v(32, -1200, 1200, 0)
        v(33, -12000, 5000, -12000); v(34, -12000, 8000, -12000); v(35, -12000, 5000, -12000); v(36, -12000, 8000, -12000)
        v(37, 0, 1440, 0); v(38, -12000, 8000, -12000); v(39, -1200, 1200, 0); v(40, -1200, 1200, 0)
        t[41] = GenInfo(id: 41, kind: .index, min: 0, max: 65535, defaultValue: 0, instrumentOnly: false, realtime: false)
        t[43] = GenInfo(id: 43, kind: .range, min: 0, max: 0x7F7F, defaultValue: 0x7F00, instrumentOnly: false, realtime: false)
        t[44] = GenInfo(id: 44, kind: .range, min: 0, max: 0x7F7F, defaultValue: 0x7F00, instrumentOnly: false, realtime: false)
        s(45, Int(Int16.min), Int(Int16.max), 0)
        t[46] = GenInfo(id: 46, kind: .substitution, min: 0, max: 127, defaultValue: -1, instrumentOnly: true, realtime: false)
        t[47] = GenInfo(id: 47, kind: .substitution, min: 0, max: 127, defaultValue: -1, instrumentOnly: true, realtime: false)
        v(48, 0, 1440, 0)
        s(50, Int(Int16.min), Int(Int16.max), 0)
        v(51, -120, 120, 0); v(52, -99, 99, 0)
        t[53] = GenInfo(id: 53, kind: .index, min: 0, max: 65535, defaultValue: 0, instrumentOnly: true, realtime: false)
        s(54, 0, 3, 0, realtime: false)
        t[56] = GenInfo(id: 56, kind: .value, min: 0, max: 1200, defaultValue: 100, instrumentOnly: false, realtime: false)
        s(57, 0, 127, 0, realtime: false)
        s(58, 0, 127, -1, realtime: false)
        return t
    }()

    @inline(__always) static func get(_ id: Int) -> GenInfo? { id >= 0 && id < table.count ? table[id] : nil }
    static func isDefined(_ id: Int) -> Bool { get(id) != nil }
    /// Section 8.1.1: modulator destinations are exclusively value generators.
    static func isValueGenerator(_ id: Int) -> Bool { get(id)?.kind == .value }
    static func defaultValue(_ id: Int) -> Int { get(id)?.defaultValue ?? 0 }
    /// Section 10.5: clamp a summed value generator to its useful range (others unchanged).
    @inline(__always) static func clamp(_ id: Int, _ x: Int) -> Int {
        guard let g = get(id), g.kind == .value else { return x }
        return Swift.max(g.min, Swift.min(g.max, x))
    }
    /// Real-time clamp (no array access, no ARC): value-generator ranges as a switch. Kept in sync
    /// with `table` by `test_Z11_genInfoTableAndClamp`.
    @inline(__always) static func valueRange(_ id: Int) -> (Int, Int)? {
        switch id {
        case 5, 6, 7, 10, 11: return (-12000, 12000)
        case 8: return (1500, 13500)
        case 9: return (0, 960)
        case 13: return (-960, 960)
        case 15, 16, 29: return (0, 1000)
        case 17: return (-500, 500)
        case 21, 23, 25, 27, 33, 35: return (-12000, 5000)
        case 22, 24: return (-16000, 4500)
        case 26, 28, 30, 34, 36, 38: return (-12000, 8000)
        case 31, 32, 39, 40: return (-1200, 1200)
        case 37, 48: return (0, 1440)
        case 51: return (-120, 120)
        case 52: return (-99, 99)
        case 56: return (0, 1200)
        default: return nil
        }
    }
    @inline(__always) static func clamp(_ id: Int, _ x: Double) -> Double {
        guard let (lo, hi) = valueRange(id) else { return x }
        return Swift.max(Double(lo), Swift.min(Double(hi), x))
    }
}
