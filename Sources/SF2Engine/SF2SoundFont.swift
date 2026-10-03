// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// Port of gbk sf2-parser.ts (parseSF2, getPreset, buildRegionsForPreset, makeRegionFromMerged,
// decodeSampleData, int16ToFloat32). Quirks are kept on purpose so renders match gbk:
// generator merge is "add everything except ranges/ids/sampleModes/exclusiveClass/rootKey",
// sustainModEnv is used as a 0..1 level (/1000), samples are peak-normalized per region,
// modulators are parsed but not applied.

public enum SF2Error: Error, Equatable {
    case notRIFF
    case notSoundFont
    case truncated(String)
    case missingTable(String)
    case missingSampleData
    case presetIndexOutOfRange(Int)
    case instrumentIndexOutOfRange(Int)
}

public struct SF2SampleHeader: Equatable, Sendable {
    public var sampleName: String
    public var start: Int
    public var end: Int
    public var startLoop: Int
    public var endLoop: Int
    public var sampleRate: Int
    public var originalPitch: Int
    public var pitchCorrection: Int
    public var sampleLink: Int
    public var sampleType: Int
}

public struct SF2PresetHeader: Equatable, Sendable {
    public var presetName: String
    public var preset: Int
    public var bank: Int
    public var presetBagNdx: Int
    public var library: Int
    public var genre: Int
    public var morphology: Int
}

public struct SF2InstrumentHeader: Equatable, Sendable {
    public var instName: String
    public var instBagNdx: Int
}

public struct SF2Bag: Equatable, Sendable { public var genNdx: Int; public var modNdx: Int }
public struct SF2GenRecord: Equatable, Sendable { public var oper: Int; public var amount: Int }
public struct SF2ModRecord: Equatable, Sendable {
    public var srcOper: Int
    public var destOper: Int
    public var amount: Int
    public var amtSrcOper: Int
    public var transOper: Int
}

/// SF2 generator operators (sfGenOper) used by the region builder.
enum Gen {
    static let startAddrsOffset = 0, endAddrsOffset = 1, startloopAddrsOffset = 2, endloopAddrsOffset = 3
    static let startAddrsCoarseOffset = 4, modLfoToPitch = 5, vibLfoToPitch = 6, modEnvToPitch = 7
    static let initialFilterFc = 8, initialFilterQ = 9, modLfoToFilterFc = 10, modEnvToFilterFc = 11
    static let endAddrsCoarseOffset = 12, modLfoToVolume = 13, chorusEffectsSend = 15, reverbEffectsSend = 16
    static let pan = 17, delayModLFO = 21, freqModLFO = 22, delayVibLFO = 23, freqVibLFO = 24
    static let delayModEnv = 25, attackModEnv = 26, holdModEnv = 27, decayModEnv = 28, sustainModEnv = 29
    static let releaseModEnv = 30, keynumToModEnvHold = 31, keynumToModEnvDecay = 32
    static let delayVolEnv = 33, attackVolEnv = 34, holdVolEnv = 35, decayVolEnv = 36, sustainVolEnv = 37
    static let releaseVolEnv = 38, keynumToVolEnvHold = 39, keynumToVolEnvDecay = 40, instrument = 41
    static let keyRange = 43, velRange = 44, startloopAddrsCoarseOffset = 45, keynum = 46, velocity = 47
    static let initialAttenuation = 48, endloopAddrsCoarseOffset = 50, coarseTune = 51, fineTune = 52
    static let sampleID = 53, sampleModes = 54, scaleTuning = 56, exclusiveClass = 57, overridingRootKey = 58
}

/// A parsed SoundFont 2 bank. Immutable after init; thread-safe to share. Parse off the main
/// thread once (`SF2SoundFont.load(contentsOf:)`), then build regions per preset (cached).
public final class SF2SoundFont: @unchecked Sendable {
    public let info: [String: String]
    /// `smpl`: all 16-bit PCM samples concatenated (kept as Int16).
    public let samples: [Int16]
    /// Optional `sm24` low bytes (parsed, unused, like gbk).
    public let sm24: [UInt8]?
    public let riffSize: Int
    /// pdta tables, terminal records (EOP/EOI/EOS) included.
    public let phdr: [SF2PresetHeader]
    public let pbag: [SF2Bag]
    public let pmod: [SF2ModRecord]
    public let pgen: [SF2GenRecord]
    public let inst: [SF2InstrumentHeader]
    public let ibag: [SF2Bag]
    public let imod: [SF2ModRecord]
    public let igen: [SF2GenRecord]
    public let shdr: [SF2SampleHeader]

    private let cacheLock = NSLock()
    private var sampleCache: [SampleKey: SF2SampleBuffer] = [:]
    private var regionCache: [Int: SF2RegionList] = [:]

    /// Presets without the terminal EOP record (gbk `getPresetRows`). Index == preset index.
    public var presets: ArraySlice<SF2PresetHeader> { phdr.dropLast() }

    /// Reads and parses the file on a background task (never on the caller's thread).
    public static func load(contentsOf url: URL) async throws -> SF2SoundFont {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try SF2SoundFont(data: data)
        }.value
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        var info: [String: String] = [:]
        var smpl: [Int16]?
        var sm24: [UInt8]?
        var phdr: [SF2PresetHeader] = [], pbag: [SF2Bag] = [], pmod: [SF2ModRecord] = [], pgen: [SF2GenRecord] = []
        var inst: [SF2InstrumentHeader] = [], ibag: [SF2Bag] = [], imod: [SF2ModRecord] = [], igen: [SF2GenRecord] = []
        var shdr: [SF2SampleHeader] = []
        var riffSize = 0

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var r = ByteReader(raw)
            guard try r.fourCC() == "RIFF" else { throw SF2Error.notRIFF }
            riffSize = Int(try r.u32())
            guard try r.fourCC() == "sfbk" else { throw SF2Error.notSoundFont }

            while !r.eof {
                let id = try r.fourCC()
                let size = Int(try r.u32())
                let chunkStart = r.pos
                if id == "LIST" {
                    let listType = try r.fourCC()
                    let listEnd = min(chunkStart + size, raw.count)
                    switch listType {
                    case "INFO":
                        while r.pos < listEnd {
                            let sid = try r.fourCC()
                            let ssize = Int(try r.u32())
                            let start = r.pos
                            let bytes = try r.bytes(ssize)
                            var s = String(decoding: bytes, as: UTF8.self)
                            if s.contains("\u{FFFD}") { s = String(bytes.map { Character(Unicode.Scalar($0)) }) }
                            while s.hasSuffix("\0") { s.removeLast() }
                            info[sid] = s
                            r.pos = align2(start + ssize)
                        }
                    case "sdta":
                        while r.pos < listEnd {
                            let sid = try r.fourCC()
                            let ssize = Int(try r.u32())
                            let start = r.pos
                            if sid == "smpl" {
                                let n = ssize / 2
                                try r.need(n * 2, "smpl")
                                var out = [Int16](repeating: 0, count: n)
                                out.withUnsafeMutableBytes { dst in
                                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[start ..< start + n * 2]))
                                }
                                #if _endian(big)
                                for i in 0 ..< n { out[i] = Int16(littleEndian: out[i]) }
                                #endif
                                smpl = out
                            } else if sid == "sm24" {
                                sm24 = Array(try r.bytes(ssize))
                            }
                            r.pos = align2(start + ssize)
                        }
                    case "pdta":
                        while r.pos < listEnd {
                            let sid = try r.fourCC()
                            let ssize = Int(try r.u32())
                            let start = r.pos
                            try r.need(ssize, sid)
                            switch sid {
                            case "phdr":
                                phdr = try (0 ..< ssize / 38).map { _ in
                                    SF2PresetHeader(presetName: try r.zstr(20), preset: Int(try r.u16()), bank: Int(try r.u16()),
                                                    presetBagNdx: Int(try r.u16()), library: Int(try r.u32()),
                                                    genre: Int(try r.u32()), morphology: Int(try r.u32()))
                                }
                            case "pbag": pbag = try Self.readBags(&r, ssize)
                            case "ibag": ibag = try Self.readBags(&r, ssize)
                            case "pmod": pmod = try Self.readMods(&r, ssize)
                            case "imod": imod = try Self.readMods(&r, ssize)
                            case "pgen": pgen = try Self.readGens(&r, ssize)
                            case "igen": igen = try Self.readGens(&r, ssize)
                            case "inst":
                                inst = try (0 ..< ssize / 22).map { _ in
                                    SF2InstrumentHeader(instName: try r.zstr(20), instBagNdx: Int(try r.u16()))
                                }
                            case "shdr":
                                shdr = try (0 ..< ssize / 46).map { _ in
                                    SF2SampleHeader(
                                        sampleName: try r.zstr(20), start: Int(try r.u32()), end: Int(try r.u32()),
                                        startLoop: Int(try r.u32()), endLoop: Int(try r.u32()), sampleRate: Int(try r.u32()),
                                        originalPitch: Int(try r.u8()), pitchCorrection: Int(Int8(bitPattern: try r.u8())),
                                        sampleLink: Int(try r.u16()), sampleType: Int(try r.u16()))
                                }
                            default: break
                            }
                            r.pos = align2(start + ssize)
                        }
                    default:
                        r.pos = listEnd
                    }
                    r.pos = align2(r.pos)
                } else {
                    r.pos = align2(chunkStart + size)
                }
            }
        }

        let tables: [(String, Int)] = [("phdr", phdr.count), ("pbag", pbag.count), ("pgen", pgen.count), ("inst", inst.count),
                                       ("ibag", ibag.count), ("igen", igen.count), ("shdr", shdr.count)]
        for (name, count) in tables where count == 0 { throw SF2Error.missingTable(name) }

        self.info = info
        self.samples = smpl ?? []
        self.sm24 = sm24
        self.riffSize = riffSize
        self.phdr = phdr; self.pbag = pbag; self.pmod = pmod; self.pgen = pgen
        self.inst = inst; self.ibag = ibag; self.imod = imod; self.igen = igen; self.shdr = shdr
        if smpl == nil { throw SF2Error.missingSampleData }
    }

    private static func readBags(_ r: inout ByteReader, _ size: Int) throws -> [SF2Bag] {
        try (0 ..< size / 4).map { _ in SF2Bag(genNdx: Int(try r.u16()), modNdx: Int(try r.u16())) }
    }
    private static func readGens(_ r: inout ByteReader, _ size: Int) throws -> [SF2GenRecord] {
        try (0 ..< size / 4).map { _ in SF2GenRecord(oper: Int(try r.u16()), amount: Int(Int16(bitPattern: try r.u16()))) }
    }
    private static func readMods(_ r: inout ByteReader, _ size: Int) throws -> [SF2ModRecord] {
        try (0 ..< size / 10).map { _ in
            SF2ModRecord(srcOper: Int(try r.u16()), destOper: Int(try r.u16()), amount: Int(Int16(bitPattern: try r.u16())),
                         amtSrcOper: Int(try r.u16()), transOper: Int(try r.u16()))
        }
    }

    // MARK: - Presets

    /// gbk `resolvePresetIndex`: exact (program, bank), then bank 0, then any bank; nil if none.
    public func resolvePresetIndex(program: Int, bank: Int) -> Int? {
        let p = presets
        if let i = p.firstIndex(where: { $0.preset == program && $0.bank == bank }) { return i }
        if let i = p.firstIndex(where: { $0.preset == program && $0.bank == 0 }) { return i }
        if let i = p.firstIndex(where: { $0.preset == program }) { return i }
        return nil
    }

    /// gbk `presetOptions` name: `presetName || "(unnamed)"`.
    public func presetName(_ index: Int) -> String? {
        guard index >= 0, index < phdr.count - 1 else { return nil }
        let n = phdr[index].presetName
        return n.isEmpty ? "(unnamed)" : n
    }

    /// Cached `buildRegionsForPreset(index, {decodeToFloat32, normalize, includeStereoLinks: true})`.
    public func regionList(forPreset index: Int) throws -> SF2RegionList {
        cacheLock.lock()
        if let hit = regionCache[index] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let list = SF2RegionList(try buildRegionsForPreset(index))
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = regionCache[index] { return hit }
        regionCache[index] = list
        return list
    }

    public func buildRegionsForPreset(_ presetIndex: Int, normalize: Bool = true, includeStereoLinks: Bool = true) throws -> [SF2Region] {
        let last = phdr.count - 1
        guard presetIndex >= 0, presetIndex < last else { throw SF2Error.presetIndexOutOfRange(presetIndex) }
        let presetZones = zones(bags: pbag, gens: pgen, from: phdr[presetIndex].presetBagNdx, to: phdr[presetIndex + 1].presetBagNdx)
        let presetGlobal: [Int: Int] = (!presetZones.isEmpty && presetZones[0][Gen.instrument] == nil) ? presetZones[0] : [:]
        var regions: [SF2Region] = []
        for pz in presetZones {
            guard let instIndex = pz[Gen.instrument] else { continue }
            let instLast = inst.count - 1
            guard instIndex >= 0, instIndex < instLast else { throw SF2Error.instrumentIndexOutOfRange(instIndex) }
            let instZones = zones(bags: ibag, gens: igen, from: inst[instIndex].instBagNdx, to: inst[instIndex + 1].instBagNdx)
            let instGlobal: [Int: Int] = (!instZones.isEmpty && instZones[0][Gen.sampleID] == nil) ? instZones[0] : [:]
            for iz in instZones {
                guard iz[Gen.sampleID] != nil else { continue }
                let merged = Self.mergeGens(presetGlobal, pz, instGlobal, iz)
                if let region = makeRegion(merged, normalize: normalize, includeStereoLinks: includeStereoLinks) {
                    regions.append(region)
                }
            }
        }
        return regions
    }

    private func zones(bags: [SF2Bag], gens: [SF2GenRecord], from bagStart: Int, to bagEnd: Int) -> [[Int: Int]] {
        var out: [[Int: Int]] = []
        var bi = bagStart
        while bi < bagEnd {
            guard bi < bags.count else { break }
            let genStart = bags[bi].genNdx
            let genEnd = bi + 1 < bags.count ? bags[bi + 1].genNdx : gens.count
            var z: [Int: Int] = [:]
            var gi = genStart
            while gi < genEnd, gi < gens.count { z[gens[gi].oper] = gens[gi].amount; gi += 1 }
            out.append(z)
            bi += 1
        }
        return out
    }

    static func mergeGens(_ zones: [Int: Int]...) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for src in zones {
            for (k, v) in src {
                switch k {
                case Gen.keyRange, Gen.velRange, Gen.instrument, Gen.sampleID,
                     Gen.sampleModes, Gen.exclusiveClass, Gen.overridingRootKey:
                    out[k] = v
                default:
                    out[k] = (out[k] ?? 0) + v
                }
            }
        }
        return out
    }

    private func makeRegion(_ g: [Int: Int], normalize: Bool, includeStereoLinks: Bool) -> SF2Region? {
        guard let sampleID = g[Gen.sampleID], sampleID >= 0, sampleID < shdr.count else { return nil }
        let sh = shdr[sampleID]
        let n = samples.count
        func offset(_ fine: Int, _ coarse: Int) -> Int { (g[fine] ?? 0) + (g[coarse] ?? 0) * 32768 }
        let start = clampU32(sh.start + offset(Gen.startAddrsOffset, Gen.startAddrsCoarseOffset), 0, n)
        let end = clampU32(sh.end + offset(Gen.endAddrsOffset, Gen.endAddrsCoarseOffset), 0, n)
        let loopStart = clampU32(sh.startLoop + offset(Gen.startloopAddrsOffset, Gen.startloopAddrsCoarseOffset), 0, n)
        let loopEnd = clampU32(sh.endLoop + offset(Gen.endloopAddrsOffset, Gen.endloopAddrsCoarseOffset), 0, n)
        if end <= start { return nil }

        let dataL = sampleBuffer(start, end, normalize: normalize)
        var dataR: SF2SampleBuffer?
        if includeStereoLinks, sh.sampleLink != 0, sh.sampleLink < shdr.count {
            let other = shdr[sh.sampleLink]
            if other.sampleRate == sh.sampleRate {
                let sR = clampU32(other.start, 0, n), eR = clampU32(other.end, 0, n)
                if eR > sR { dataR = sampleBuffer(sR, eR, normalize: normalize) }
            }
        }

        func range(_ raw: Int?) -> (Int, Int) {
            guard let raw else { return (0, 127) }
            let u = raw & 0xFFFF
            return (u & 0xFF, (u >> 8) & 0xFF)
        }
        let len = dataL.count
        var region = SF2Region(
            keyRange: range(g[Gen.keyRange]), velRange: range(g[Gen.velRange]),
            sample: SF2SampleData(dataL: dataL, dataR: dataR, sampleRate: sh.sampleRate, start: 0, end: len,
                                  loopStart: max(0, min(loopStart - start, len)), loopEnd: max(0, min(loopEnd - start, len))),
            sampleModes: g[Gen.sampleModes] ?? 0,
            originalKey: sh.originalPitch,
            overridingRootKey: g[Gen.overridingRootKey].map { $0 & 0xFF },
            coarseTune: g[Gen.coarseTune] ?? 0,
            fineTune: (g[Gen.fineTune] ?? 0) + sh.pitchCorrection,
            scaleTuning: g[Gen.scaleTuning] ?? 100,
            initialAttenuationCb: g[Gen.initialAttenuation] ?? 0,
            pan: g[Gen.pan] ?? 0,
            volEnv: SF2VolEnv(delayTc: g[Gen.delayVolEnv] ?? -12000, attackTc: g[Gen.attackVolEnv] ?? -12000,
                              holdTc: g[Gen.holdVolEnv] ?? -12000, decayTc: g[Gen.decayVolEnv] ?? -12000,
                              sustainCb: g[Gen.sustainVolEnv] ?? 0, releaseTc: g[Gen.releaseVolEnv] ?? -12000),
            modEnv: SF2ModEnv(delayTc: g[Gen.delayModEnv] ?? -12000, attackTc: g[Gen.attackModEnv] ?? -12000,
                              holdTc: g[Gen.holdModEnv] ?? -12000, decayTc: g[Gen.decayModEnv] ?? -12000,
                              sustain: g[Gen.sustainModEnv].map { min(1, max(0, Double($0) / 1000)) } ?? 0,
                              releaseTc: g[Gen.releaseModEnv] ?? -12000),
            initialFilterFcCents: Self.sanitizeInitialFilterFcCents(g[Gen.initialFilterFc]),
            initialFilterQCb: g[Gen.initialFilterQ] ?? 0,
            modEnvToFilterFcCents: g[Gen.modEnvToFilterFc] ?? 0,
            modLfoToFilterFcCents: g[Gen.modLfoToFilterFc] ?? 0,
            modLfoDelayTc: g[Gen.delayModLFO] ?? -12000,
            modLfoFreqCents: g[Gen.freqModLFO] ?? 0,
            modLfoToPitchCents: g[Gen.modLfoToPitch] ?? 0,
            vibLfoDelayTc: g[Gen.delayVibLFO] ?? -12000,
            vibLfoFreqCents: g[Gen.freqVibLFO] ?? 0,
            vibLfoToPitchCents: g[Gen.vibLfoToPitch] ?? 0,
            exclusiveClass: g[Gen.exclusiveClass] ?? 0)
        if !(region.sample.loopEnd > region.sample.loopStart + 1) {
            region.sampleModes = 0
            region.sample.loopStart = 0
            region.sample.loopEnd = region.sample.end
        }
        return region
    }

    static func sanitizeInitialFilterFcCents(_ value: Int?) -> Int {
        guard let value else { return 13500 }
        if value < 1500 { return 13500 }
        return min(value, 13500)
    }

    /// int16ToFloat32, cached per (start, end, normalize): identical ranges decode identically.
    private func sampleBuffer(_ start: Int, _ end: Int, normalize: Bool) -> SF2SampleBuffer {
        let key = SampleKey(start: start, end: end, normalize: normalize)
        cacheLock.lock()
        if let hit = sampleCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let n = end - start
        let buf = SF2SampleBuffer(count: n)
        samples.withUnsafeBufferPointer { src in
            let p = buf.mutablePointer
            if !normalize {
                for i in 0 ..< n { p[i] = Float(Double(src[start + i]) / 32768) }
                return
            }
            var peak = 0
            for i in 0 ..< n { let v = abs(Int(src[start + i])); if v > peak { peak = v } }
            let denom = Double(peak > 0 ? peak : 32768)
            let scale = denom / 32768
            for i in 0 ..< n { p[i] = Float((Double(src[start + i]) / 32768) / scale) }
        }
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = sampleCache[key] { return hit }
        sampleCache[key] = buf
        return buf
    }

    private struct SampleKey: Hashable { var start: Int; var end: Int; var normalize: Bool }
}

/// JS `clampU32`: `x >>> 0` (ToUint32 wraps negatives) then clamp to [lo, hi].
@inline(__always) func clampU32(_ x: Int, _ lo: Int, _ hi: Int) -> Int {
    let u = Int(UInt32(truncatingIfNeeded: x))
    if u < lo { return lo }
    if u > hi { return hi }
    return u
}

@inline(__always) func align2(_ p: Int) -> Int { (p + 1) & ~1 }

struct ByteReader {
    let raw: UnsafeRawBufferPointer
    var pos = 0
    init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }
    var eof: Bool { pos >= raw.count }
    func need(_ n: Int, _ what: String) throws {
        if n < 0 || pos + n > raw.count { throw SF2Error.truncated(what) }
    }
    mutating func u8() throws -> UInt8 { try need(1, "u8"); defer { pos += 1 }; return raw[pos] }
    mutating func u16() throws -> UInt16 {
        try need(2, "u16"); defer { pos += 2 }
        return UInt16(raw[pos]) | UInt16(raw[pos + 1]) << 8
    }
    mutating func u32() throws -> UInt32 {
        try need(4, "u32"); defer { pos += 4 }
        return UInt32(raw[pos]) | UInt32(raw[pos + 1]) << 8 | UInt32(raw[pos + 2]) << 16 | UInt32(raw[pos + 3]) << 24
    }
    mutating func fourCC() throws -> String {
        try need(4, "fourCC"); defer { pos += 4 }
        return String(bytes: raw[pos ..< pos + 4].map { $0 }, encoding: .isoLatin1) ?? ""
    }
    mutating func bytes(_ n: Int) throws -> UnsafeRawBufferPointer.SubSequence {
        let e = min(raw.count, pos + max(0, n))
        defer { pos = e }
        return raw[pos ..< e]
    }
    mutating func zstr(_ maxBytes: Int) throws -> String {
        try need(maxBytes, "zstr")
        var e = pos
        while e < pos + maxBytes, raw[e] != 0 { e += 1 }
        let s = String(bytes: raw[pos ..< e].map { $0 }, encoding: .isoLatin1) ?? ""
        pos += maxBytes
        return s
    }
}
