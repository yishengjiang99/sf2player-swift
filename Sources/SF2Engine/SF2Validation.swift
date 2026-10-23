// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// SoundFont 2.01 structural rules (sections 3 to 7 and 10.1/10.2): load options, the `ifil`
// version, the INFO string rules and the pdta index-consistency checks. Strict loads throw the
// first violation; lenient loads keep it in `SF2SoundFont.warnings`.

/// How `SF2SoundFont` treats structurally unsound files (section 10.1).
public struct SF2LoadOptions: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case strict, lenient }
    public var mode: Mode
    public init(mode: Mode) { self.mode = mode }
    /// Reject structurally unsound files (section 10.1). Use with `SF2Fidelity.spec`.
    public static let strict = SF2LoadOptions(mode: .strict)
    /// Historical behavior (what `.gbk` callers and `SF2SoundFont(contentsOf:)` get by default).
    public static let lenient = SF2LoadOptions(mode: .lenient)
}

/// The `ifil` version. All version-aware behavior is decided here, not with scattered `if`s.
public struct SF2SpecVersion: Equatable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public init(major: Int, minor: Int) { self.major = major; self.minor = minor }
    public var description: String { "\(major).\(String(format: "%02d", minor))" }
    /// 2.04 features: sm24, modulator transform 2 (absolute value), modulator links, the 2.04 defaults.
    public var has204Features: Bool { major > 2 || (major == 2 && minor >= 4) }
    /// Section 8.3 (2.01 defines only linear = 0; 2.04 adds 2 = absolute value).
    public func isValidTransform(_ t: UInt16) -> Bool { t == 0 || (t == 2 && has204Features) }
}

/// A section 10.1 structural problem; names the rule and the chunk.
public enum SF2StructuralError: Error, Equatable, Sendable {
    case riffSize(declared: Int, actual: Int)
    case truncatedChunk(String)
    case chunkOrder(String)
    case unknownChunk(String, in: String)
    case missingChunk(String)
    case chunkSize(String, Int)
    case unsupportedVersion(major: Int, minor: Int)
    case oddSampleByteCount(Int)
    case recordSize(String, Int)
    case tooFewRecords(String, Int)
    case bagIndexNotMonotonic(String, Int)
    case indexCountMismatch(String, expected: Int, actual: Int)
    case instrumentOutOfRange(genIndex: Int, value: Int)
    case sampleOutOfRange(genIndex: Int, value: Int)
    case samplePointsOutOfRange(sample: Int)
    case romSampleWithoutIROM(sample: Int)
}

enum SF2InfoParser {
    struct Result { var info: [String: String]; var version: SF2SpecVersion?; var issues: [SF2StructuralError] }

    static let stringIDs: Set<String> = ["INAM", "isng", "irom", "ICRD", "IENG", "IPRD", "ICOP", "ICMT", "ISFT"]

    /// Latin-1 decode up to the first NUL; nil if unterminated, odd-length or too long (5.2 to 5.11).
    static func zstring(_ b: [UInt8], maxBytes: Int) -> String? {
        guard b.count % 2 == 0, b.count <= maxBytes, let z = b.firstIndex(of: 0) else { return nil }
        return String(b[..<z].map { Character(Unicode.Scalar($0)) })
    }

    static func parse(_ chunks: [(String, [UInt8])]) -> Result {
        var info: [String: String] = [:]
        var version: SF2SpecVersion?
        var issues: [SF2StructuralError] = []
        var sawIfil = false
        for (id, b) in chunks {
            switch id {
            case "ifil":
                sawIfil = true
                guard b.count == 4 else { issues.append(.chunkSize("ifil", b.count)); continue }
                let v = SF2SpecVersion(major: Int(b[0]) | Int(b[1]) << 8, minor: Int(b[2]) | Int(b[3]) << 8)
                if v.major != 2 { issues.append(.unsupportedVersion(major: v.major, minor: v.minor)) }
                version = v
                info["ifil"] = "\(v.major).\(v.minor)"
            case "iver":
                // 5.5: exactly 4 bytes; otherwise ignore the field.
                if b.count == 4 { info["iver"] = "\(Int(b[0]) | Int(b[1]) << 8).\(Int(b[2]) | Int(b[3]) << 8)" }
            case _ where stringIDs.contains(id):
                if let s = zstring(b, maxBytes: id == "ICMT" ? 65536 : 256) { info[id] = s }
            default:
                break // 3.2/10.2: unknown INFO sub-chunks are ignored.
            }
        }
        if !sawIfil { issues.insert(.missingChunk("ifil"), at: 0) }
        // 5.2: missing, unterminated or unknown sound engine -> EMU8000.
        let engines: Set<String> = ["EMU8000"]
        if info["isng"].map({ !engines.contains($0) }) ?? true { info["isng"] = "EMU8000" }
        return Result(info: info, version: version, issues: issues)
    }
}

enum SF2Validator {
    static let pdtaOrder = ["phdr", "pbag", "pmod", "pgen", "inst", "ibag", "imod", "igen", "shdr"]

    static func validate(topOrder: [String], pdtaOrder order: [String], phdr: [SF2PresetHeader], pbag: [SF2Bag],
                         pmod: [SF2ModRecord], pgen: [SF2GenRecord], inst: [SF2InstrumentHeader], ibag: [SF2Bag],
                         imod: [SF2ModRecord], igen: [SF2GenRecord], shdr: [SF2SampleHeader], sampleCount: Int,
                         hasIROM: Bool) -> [SF2StructuralError] {
        var e: [SF2StructuralError] = []
        // P-02: INFO, sdta, pdta in that order (section 3.2/4.1).
        let known = topOrder.filter { ["INFO", "sdta", "pdta"].contains($0) }
        for need in ["INFO", "sdta", "pdta"] where !known.contains(need) { e.append(.missingChunk(need)) }
        if known != ["INFO", "sdta", "pdta"] && Set(known).count == 3 { e.append(.chunkOrder("RIFF")) }
        // P-09: all nine pdta sub-chunks; P-02 their order.
        for need in pdtaOrder where !order.contains(need) { e.append(.missingChunk(need)) }
        let pk = order.filter { pdtaOrder.contains($0) }
        if pk != pdtaOrder && Set(pk).count == pdtaOrder.count { e.append(.chunkOrder("pdta")) }
        // P-10: minimum records.
        if phdr.count < 2 { e.append(.tooFewRecords("phdr", phdr.count)) }
        if inst.count < 2 { e.append(.tooFewRecords("inst", inst.count)) }
        if shdr.count < 1 { e.append(.tooFewRecords("shdr", shdr.count)) }
        // P-11: monotonic bag indices and table sizes implied by the terminal records.
        func checkLevel(_ hdrName: String, _ bagNdx: [Int], _ bagName: String, _ bags: [SF2Bag],
                        _ genName: String, _ gens: Int, _ modName: String, _ mods: Int) {
            for i in bagNdx.indices.dropFirst() where bagNdx[i] < bagNdx[i - 1] { e.append(.bagIndexNotMonotonic(hdrName, i)) }
            if let last = bagNdx.last, bags.count != last + 1 {
                e.append(.indexCountMismatch(bagName, expected: last + 1, actual: bags.count))
            }
            for i in bags.indices.dropFirst() {
                if bags[i].genNdx < bags[i - 1].genNdx { e.append(.bagIndexNotMonotonic(genName, i)) }
                if bags[i].modNdx < bags[i - 1].modNdx { e.append(.bagIndexNotMonotonic(modName, i)) }
            }
            if let last = bags.last {
                if gens != last.genNdx + 1 { e.append(.indexCountMismatch(genName, expected: last.genNdx + 1, actual: gens)) }
                if mods != last.modNdx + 1 { e.append(.indexCountMismatch(modName, expected: last.modNdx + 1, actual: mods)) }
            }
        }
        if order.contains("phdr") && order.contains("pbag") {
            checkLevel("phdr", phdr.map(\.presetBagNdx), "pbag", pbag, "pgen", pgen.count, "pmod", pmod.count)
        }
        if order.contains("inst") && order.contains("ibag") {
            checkLevel("inst", inst.map(\.instBagNdx), "ibag", ibag, "igen", igen.count, "imod", imod.count)
        }
        // P-12: instrument / sampleID references (terminal records excluded).
        for (i, g) in pgen.enumerated() where g.oper == Gen.instrument {
            let v = Int(UInt16(truncatingIfNeeded: g.amount))
            if v >= inst.count - 1 { e.append(.instrumentOutOfRange(genIndex: i, value: v)) }
        }
        for (i, g) in igen.enumerated() where g.oper == Gen.sampleID {
            let v = Int(UInt16(truncatingIfNeeded: g.amount))
            if v >= shdr.count - 1 { e.append(.sampleOutOfRange(genIndex: i, value: v)) }
        }
        // S-02 / P-06: sample points inside smpl; ROM samples need irom.
        for (i, s) in shdr.dropLast().enumerated() {
            if s.sampleType & 0x8000 != 0 {
                if !hasIROM { e.append(.romSampleWithoutIROM(sample: i)) }
                continue
            }
            let pts = [s.start, s.end, s.startLoop, s.endLoop]
            if s.end <= s.start || pts.contains(where: { $0 > sampleCount }) { e.append(.samplePointsOutOfRange(sample: i)) }
        }
        return e
    }
}
