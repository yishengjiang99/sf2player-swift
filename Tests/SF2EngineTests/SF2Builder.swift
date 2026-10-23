// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
@testable import SF2Engine

/// Builds tiny SF2 files in memory (so parser tests run without the 32 MB bank).
/// Defaults produce a structurally valid SoundFont 2.01 file (passes `.strict`).
struct SF2Builder {
    struct Mod { var src: Int; var dest: Int; var amount: Int; var amtSrc = 0; var transform = 0 }
    struct Zone {
        var gens: [(Int, Int)]
        var mods: [Mod] = []
        init(gens: [(Int, Int)], mods: [Mod] = []) { self.gens = gens; self.mods = mods }
    }
    struct Sample { var name: String; var start, end, loopStart, loopEnd: Int; var rate = 44100; var pitch = 60; var corr = 0; var link = 0; var type = 1 }
    var samples: [Int16] = []
    var sampleHeaders: [Sample] = []
    var instruments: [(String, [Zone])] = []
    var presets: [(String, Int, Int, [Zone])] = []
    /// `ifil` (nil = omit the chunk); `ifilBytes` overrides the raw body.
    var ifil: (Int, Int)? = (2, 1)
    var ifilBytes: [UInt8]?
    var isng: String? = "EMU8000"
    var irom: String?
    var iver: (Int, Int)?
    var info: [(String, String)] = [("INAM", "Test Bank")]
    /// Raw INFO sub-chunks appended verbatim (id, body) for string-rule tests.
    var rawInfo: [(String, [UInt8])] = []
    var omitTable: String?
    /// Extra chunks: (container "RIFF" | "INFO" | "sdta" | "pdta", id, body).
    var extraChunks: [(String, String, [UInt8])] = []
    /// Top-level LIST order and pdta sub-chunk order overrides.
    var topOrder = ["INFO", "sdta", "pdta"]
    var pdtaOrder = ["phdr", "pbag", "pmod", "pgen", "inst", "ibag", "imod", "igen", "shdr"]
    /// Raw `smpl` body override (odd byte counts); `omitSmpl` drops the chunk.
    var smplBytes: [UInt8]?
    var omitSmpl = false
    /// Edits the finished file bytes (wrong ckSize, broken records, ...).
    var mutate: ((inout [UInt8]) -> Void)?

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255)] }
    static func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)] }
    static func name20(_ s: String) -> [UInt8] { Array((Array(s.utf8) + [UInt8](repeating: 0, count: 20)).prefix(20)) }
    static func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        Array(id.utf8) + le32(body.count) + body + (body.count % 2 == 1 ? [0] : [])
    }
    static func list(_ type: String, _ chunks: [UInt8]) -> [UInt8] { chunk("LIST", Array(type.utf8) + chunks) }
    static func zstr(_ s: String) -> [UInt8] { var b = Array(s.utf8) + [0]; if b.count % 2 == 1 { b.append(0) }; return b }
    private static func mod(_ m: Mod) -> [UInt8] {
        le16(m.src) + le16(m.dest) + le16(Int(UInt16(bitPattern: Int16(m.amount)))) + le16(m.amtSrc) + le16(m.transform)
    }

    /// Offsets of the pdta sub-chunks in the last `build()` are not tracked; use `chunkOffset` instead.
    static func chunkOffset(_ bytes: [UInt8], _ id: String) -> Int? {
        let t = Array(id.utf8)
        guard bytes.count >= 4 else { return nil }
        for i in 12 ..< bytes.count - 3 where Array(bytes[i ..< i + 4]) == t { return i }
        return nil
    }

    func bytes() -> [UInt8] {
        var infoChunks: [UInt8] = []
        if let ifilBytes { infoChunks += Self.chunk("ifil", ifilBytes) } else if let ifil { infoChunks += Self.chunk("ifil", Self.le16(ifil.0) + Self.le16(ifil.1)) }
        if let isng { infoChunks += Self.chunk("isng", Self.zstr(isng)) }
        for (k, v) in info { infoChunks += Self.chunk(k, Self.zstr(v)) }
        if let irom { infoChunks += Self.chunk("irom", Self.zstr(irom)) }
        if let iver { infoChunks += Self.chunk("iver", Self.le16(iver.0) + Self.le16(iver.1)) }
        for (k, b) in rawInfo { infoChunks += Self.chunk(k, b) }
        var smpl: [UInt8] = []
        for s in samples { smpl += Self.le16(Int(UInt16(bitPattern: s))) }
        if let smplBytes { smpl = smplBytes }
        var phdr: [UInt8] = [], pbag: [UInt8] = [], pgen: [UInt8] = [], pmod: [UInt8] = []
        var inst: [UInt8] = [], ibag: [UInt8] = [], igen: [UInt8] = [], imod: [UInt8] = []
        var bagCount = 0, genCount = 0, modCount = 0
        for (name, program, bank, zones) in presets {
            phdr += Self.name20(name) + Self.le16(program) + Self.le16(bank) + Self.le16(bagCount) + Self.le32(0) + Self.le32(0) + Self.le32(0)
            for z in zones {
                pbag += Self.le16(genCount) + Self.le16(modCount); bagCount += 1
                for (op, amt) in z.gens { pgen += Self.le16(op) + Self.le16(Int(UInt16(bitPattern: Int16(truncatingIfNeeded: amt)))); genCount += 1 }
                for m in z.mods { pmod += Self.mod(m); modCount += 1 }
            }
        }
        phdr += Self.name20("EOP") + Self.le16(0) + Self.le16(0) + Self.le16(bagCount) + Self.le32(0) + Self.le32(0) + Self.le32(0)
        pbag += Self.le16(genCount) + Self.le16(modCount)
        pgen += [0, 0, 0, 0]
        pmod += [UInt8](repeating: 0, count: 10)
        bagCount = 0; genCount = 0; modCount = 0
        for (name, zones) in instruments {
            inst += Self.name20(name) + Self.le16(bagCount)
            for z in zones {
                ibag += Self.le16(genCount) + Self.le16(modCount); bagCount += 1
                for (op, amt) in z.gens { igen += Self.le16(op) + Self.le16(Int(UInt16(bitPattern: Int16(truncatingIfNeeded: amt)))); genCount += 1 }
                for m in z.mods { imod += Self.mod(m); modCount += 1 }
            }
        }
        inst += Self.name20("EOI") + Self.le16(bagCount)
        ibag += Self.le16(genCount) + Self.le16(modCount)
        igen += [0, 0, 0, 0]
        imod += [UInt8](repeating: 0, count: 10)
        var shdr: [UInt8] = []
        for s in sampleHeaders {
            shdr += Self.name20(s.name) + Self.le32(s.start) + Self.le32(s.end) + Self.le32(s.loopStart) + Self.le32(s.loopEnd) + Self.le32(s.rate)
            shdr += [UInt8(s.pitch & 255), UInt8(bitPattern: Int8(s.corr))] + Self.le16(s.link) + Self.le16(s.type)
        }
        shdr += Self.name20("EOS") + [UInt8](repeating: 0, count: 26)
        let tables: [String: [UInt8]] = ["phdr": phdr, "pbag": pbag, "pmod": pmod, "pgen": pgen, "inst": inst,
                                         "ibag": ibag, "imod": imod, "igen": igen, "shdr": shdr]
        var pdta: [UInt8] = []
        for id in pdtaOrder where id != omitTable { pdta += Self.chunk(id, tables[id] ?? []) }
        func extras(_ c: String) -> [UInt8] { extraChunks.filter { $0.0 == c }.flatMap { Self.chunk($0.1, $0.2) } }
        var sdta = omitSmpl ? [] : Self.chunk("smpl", smpl)
        sdta += extras("sdta")
        let lists: [String: [UInt8]] = ["INFO": Self.list("INFO", infoChunks + extras("INFO")), "sdta": Self.list("sdta", sdta),
                                        "pdta": Self.list("pdta", pdta + extras("pdta"))]
        var body = Array("sfbk".utf8)
        for l in topOrder { body += lists[l] ?? [] }
        body += extras("RIFF")
        var out = Array("RIFF".utf8) + Self.le32(body.count) + body
        mutate?(&out)
        return out
    }

    func build() -> Data { Data(bytes()) }

    // MARK: synthetic waveforms with known analysis

    /// Constant level (gain / envelope measurements).
    static func dc(_ n: Int, level: Int16 = 16384) -> [Int16] { [Int16](repeating: level, count: n) }
    /// Sine with an exact integer number of cycles per `n` points (clean loops), amplitude `amp`.
    static func sine(cycles: Int, n: Int, amp: Double = 16384) -> [Int16] {
        (0 ..< n).map { Int16((amp * sin(2 * Double.pi * Double(cycles) * Double($0) / Double(n))).rounded()) }
    }
    /// White noise from a fixed-seed LCG (filter response).
    static func noise(_ n: Int, seed: UInt64 = 0x5EED, amp: Double = 16384) -> [Int16] {
        var s = seed
        return (0 ..< n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Int16(amp * (Double(s >> 11) / Double(1 << 53) * 2 - 1))
        }
    }
    /// Ramp: value i (sample offsets / loop points are readable from the output).
    static func ramp(_ n: Int) -> [Int16] { (0 ..< n).map { Int16(truncatingIfNeeded: $0) } }

    /// One-sample, one-instrument, one-preset valid bank around `wave` (46 guard zeros appended).
    static func single(_ wave: [Int16], loop: (Int, Int)? = nil, rate: Int = 44100, pitch: Int = 60,
                       instGens: [(Int, Int)] = [], presetGens: [(Int, Int)] = [],
                       instMods: [Mod] = [], presetMods: [Mod] = []) -> SF2Builder {
        var b = SF2Builder()
        b.samples = wave + [Int16](repeating: 0, count: 46)
        let l = loop ?? (0, 0)
        b.sampleHeaders = [.init(name: "s", start: 0, end: wave.count, loopStart: l.0, loopEnd: l.1, rate: rate, pitch: pitch)]
        b.instruments = [("i", [.init(gens: instGens + [(Gen.sampleID, 0)], mods: instMods)])]
        b.presets = [("p", 0, 0, [.init(gens: presetGens + [(Gen.instrument, 0)], mods: presetMods)])]
        return b
    }
}
