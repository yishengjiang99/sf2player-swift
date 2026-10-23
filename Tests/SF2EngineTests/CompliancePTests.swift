// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Matrix rows P-xx / E-01: RIFF and chunk structure (sections 3 to 7, 10.1, 10.2).
final class CompliancePTests: XCTestCase {
    private func bank() -> SF2Builder { SF2Builder.single(SF2Builder.dc(100), loop: (10, 90)) }

    private func strictError(_ b: SF2Builder, file: StaticString = #filePath, line: UInt = #line) -> SF2StructuralError? {
        do { _ = try SF2SoundFont(data: b.build(), options: .strict); XCTFail("strict accepted", file: file, line: line); return nil }
        catch SF2Error.structural(let e) { return e }
        catch { XCTFail("unexpected \(error)", file: file, line: line); return nil }
    }

    private func strictLoads(_ b: SF2Builder, file: StaticString = #filePath, line: UInt = #line) -> SF2SoundFont? {
        do { return try SF2SoundFont(data: b.build(), options: .strict) }
        catch { XCTFail("strict rejected: \(error)", file: file, line: line); return nil }
    }

    func test_P00_builderDefaultIsStrictValid() throws {
        let sf = try XCTUnwrap(strictLoads(bank()))
        XCTAssertEqual(sf.warnings, [])
        XCTAssertEqual(sf.version, SF2SpecVersion(major: 2, minor: 1))
    }

    func test_P01_riffSizeMustMatchFile() throws {
        var b = bank()
        b.mutate = { bytes in let n = bytes.count - 8 + 2; bytes.replaceSubrange(4 ..< 8, with: SF2Builder.le32(n)) }
        XCTAssertEqual(strictError(b), .riffSize(declared: b.bytes().count - 6, actual: b.bytes().count - 8))
        let lenient = try SF2SoundFont(data: b.build())
        XCTAssertEqual(lenient.warnings.first, .riffSize(declared: b.bytes().count - 6, actual: b.bytes().count - 8))
        // A truncated file (LIST runs past EOF) is rejected in strict mode.
        var t = bank()
        t.mutate = { bytes in bytes.removeLast(20) }
        XCTAssertNotNil(strictError(t))
    }

    func test_P02_chunkOrderIsEnforced() {
        var b = bank()
        b.topOrder = ["sdta", "INFO", "pdta"]
        XCTAssertEqual(strictError(b), .chunkOrder("RIFF"))
        var p = bank()
        p.pdtaOrder = ["phdr", "pbag", "pgen", "pmod", "inst", "ibag", "imod", "igen", "shdr"]
        XCTAssertEqual(strictError(p), .chunkOrder("pdta"))
    }

    func test_P03_unknownChunksIgnoredInInfoOnly() {
        var b = bank()
        b.extraChunks = [("INFO", "IXYZ", [1, 2])]
        XCTAssertNotNil(strictLoads(b))
        for c in ["pdta", "sdta", "RIFF"] {
            var x = bank()
            x.extraChunks = [(c, "abcd", [0, 0])]
            XCTAssertEqual(strictError(x), .unknownChunk("abcd", in: c), c)
        }
    }

    func test_P04_ifilMandatoryAndVersioned() throws {
        var b = bank(); b.ifil = nil
        XCTAssertEqual(strictError(b), .missingChunk("ifil"))
        b.ifilBytes = [2, 0, 1, 0, 0, 0]
        XCTAssertEqual(strictError(b), .chunkSize("ifil", 6))
        b.ifilBytes = nil; b.ifil = (3, 0)
        XCTAssertEqual(strictError(b), .unsupportedVersion(major: 3, minor: 0))
        b.ifil = (2, 10)
        let sf = try XCTUnwrap(strictLoads(b))
        XCTAssertEqual(sf.version, SF2SpecVersion(major: 2, minor: 10))
        XCTAssertTrue(sf.specVersion.has204Features)
    }

    func test_P05_infoStringRules() throws {
        var b = bank()
        b.isng = nil; b.info = []
        var sf = try XCTUnwrap(strictLoads(b))
        XCTAssertEqual(sf.info["isng"], "EMU8000", "5.2: missing isng -> EMU8000")
        XCTAssertNil(sf.info["INAM"], "5.3: missing INAM -> name unavailable, not rejected")
        b.isng = "Unknown Engine"
        b.rawInfo = [("ICOP", Array("abc".utf8)),                  // odd length, unterminated -> ignored
                     ("ICMT", Array("abcd".utf8)),                 // even but unterminated -> ignored
                     ("IENG", Array("x".utf8) + [0] + Array([UInt8](repeating: 65, count: 300)) ), // > 256 -> ignored
                     ("ICRD", [0x45, 0xE9, 0, 0])]                 // Latin-1
        sf = try XCTUnwrap(strictLoads(b))
        XCTAssertEqual(sf.info["isng"], "EMU8000")
        XCTAssertNil(sf.info["ICOP"]); XCTAssertNil(sf.info["ICMT"]); XCTAssertNil(sf.info["IENG"])
        XCTAssertEqual(sf.info["ICRD"], "E\u{E9}")
    }

    func test_P06_romSamplesNeedIromAndNeverSound() throws {
        var b = bank()
        b.sampleHeaders[0].type = 0x8001
        b.sampleHeaders[0].start = 1_000_000; b.sampleHeaders[0].end = 1_000_100 // ROM offsets, not smpl
        XCTAssertEqual(strictError(b), .romSampleWithoutIROM(sample: 0))
        b.irom = "1MGM"; b.iver = (1, 0)
        let sf = try XCTUnwrap(strictLoads(b))
        XCTAssertEqual(sf.info["iver"], "1.0")
        XCTAssertEqual(try sf.buildRegionsForPreset(0, fidelity: .spec).count, 0)
        var v = bank(); v.rawInfo = [("iver", [1, 0, 0, 0, 0, 0])]
        XCTAssertNil(try XCTUnwrap(strictLoads(v)).info["iver"], "5.5: iver must be 4 bytes")
    }

    func test_P07_smplOptionalEvenAndSm24Gated() throws {
        var b = SF2Builder()
        b.omitSmpl = true
        b.instruments = [("empty", [])]
        b.presets = [("p", 0, 0, [.init(gens: [(Gen.instrument, 0)])])]
        let sf = try XCTUnwrap(strictLoads(b))
        XCTAssertEqual(sf.samples.count, 0)
        var o = bank(); o.smplBytes = [UInt8](repeating: 0, count: 201)
        o.sampleHeaders[0].end = 90; o.sampleHeaders[0].loopEnd = 80
        XCTAssertEqual(strictError(o), .oddSampleByteCount(201))
        var s = bank(); s.extraChunks = [("sdta", "sm24", [UInt8](repeating: 0, count: 146))]
        let s24 = try XCTUnwrap(strictLoads(s))
        XCTAssertNotNil(s24.sm24)
        XCTAssertFalse(s24.specVersion.has204Features, "sm24 is a 2.04 feature: unused for ifil 2.01")
    }

    func test_P08_recordSizeMultiples() {
        for table in SF2SoundFont.recordSizes.keys.sorted() {
            var b = bank()
            var size = 0
            b.tableEdit = { id, body in if id == table { body += [0, 0] } }
            let probe = b
            var sizes = probe
            sizes.tableEdit = { id, body in if id == table { body += [0, 0]; size = body.count } }
            _ = sizes.bytes()
            XCTAssertEqual(strictError(b), .recordSize(table, size), table)
        }
    }

    func test_P09_allNinePdtaChunksRequired() throws {
        for t in ["pmod", "imod", "pgen"] {
            var b = bank(); b.omitTable = t
            XCTAssertEqual(strictError(b), .missingChunk(t), t)
        }
        var b = bank(); b.omitTable = "pmod"
        XCTAssertEqual(try SF2SoundFont(data: b.build()).warnings.first, .missingChunk("pmod"), "lenient: warning only")
    }

    func test_P10_minimumRecordCounts() {
        var b = bank(); b.presets = []
        XCTAssertEqual(strictError(b), .tooFewRecords("phdr", 1))
        var i = SF2Builder(); i.samples = SF2Builder.dc(10); i.instruments = []; i.presets = [("p", 0, 0, [])]
        XCTAssertEqual(strictError(i), .tooFewRecords("inst", 1))
    }

    func test_P11_indexConsistency() {
        var two = bank()
        two.presets.append(("p2", 1, 0, two.presets[0].3))
        var m = two
        m.tableEdit = { id, body in if id == "phdr" { body.replaceSubrange(24 ..< 26, with: [2, 0]) } }
        XCTAssertEqual(strictError(m), .bagIndexNotMonotonic("phdr", 1))
        var g = bank()
        g.tableEdit = { id, body in if id == "pgen" { body += [0, 0, 0, 0] } }
        XCTAssertEqual(strictError(g), .indexCountMismatch("pgen", expected: 2, actual: 3))
        var md = bank()
        md.tableEdit = { id, body in if id == "imod" { body += [UInt8](repeating: 0, count: 10) } }
        XCTAssertEqual(strictError(md), .indexCountMismatch("imod", expected: 1, actual: 2))
        var bg = bank()
        bg.tableEdit = { id, body in if id == "ibag" { body.replaceSubrange(4 ..< 6, with: [0, 0]); body.replaceSubrange(0 ..< 2, with: [1, 0]) } }
        XCTAssertEqual(strictError(bg), .bagIndexNotMonotonic("igen", 1))
    }

    func test_P12_instrumentAndSampleReferencesInRange() throws {
        var b = bank(); b.presets[0].3[0].gens = [(Gen.instrument, 1)] // == inst.count - 1 (EOI)
        XCTAssertEqual(strictError(b), .instrumentOutOfRange(genIndex: 0, value: 1))
        var s = bank(); s.instruments[0].1[0].gens = [(Gen.sampleID, 1)] // EOS
        XCTAssertEqual(strictError(s), .sampleOutOfRange(genIndex: 0, value: 1))
        XCTAssertEqual(try SF2SoundFont(data: s.build()).buildRegionsForPreset(0, fidelity: .spec).count, 0,
                       "lenient .spec never plays the terminal EOS")
    }

    func test_P13_terminalsNeverPlayedOrphansAndDuplicatesKept() throws {
        var b = bank()
        b.instruments.append(("orphan", [.init(gens: [(Gen.sampleID, 0)])]))
        b.sampleHeaders.append(.init(name: "orphanS", start: 0, end: 50, loopStart: 0, loopEnd: 0))
        b.presets.append(("p", 0, 0, b.presets[0].3)) // duplicate name and (preset, bank)
        let sf = try XCTUnwrap(strictLoads(b))
        XCTAssertEqual(sf.presets.count, 2)
        XCTAssertEqual(sf.presets.map(\.presetName), ["p", "p"])
        XCTAssertThrowsError(try sf.buildRegionsForPreset(2, fidelity: .spec)) { XCTAssertEqual($0 as? SF2Error, .presetIndexOutOfRange(2)) }
    }

    func test_E01_structuralErrorsNameRuleAndChunk() throws {
        var b = bank()
        b.tableEdit = { id, body in if id == "pgen" { body += [0, 0] } }
        XCTAssertEqual(strictError(b), .recordSize("pgen", 10))
        let lenient = try SF2SoundFont(data: b.build())
        XCTAssertTrue(lenient.warnings.contains(.recordSize("pgen", 10)))
    }

    func test_P04_generalUserGSLoadsStrict() throws {
        guard let url = TestPaths.soundFontURL else { throw XCTSkip("no GeneralUser-GS.sf2") }
        let sf = try SF2SoundFont(contentsOf: url, options: .strict)
        XCTAssertEqual(sf.version, SF2SpecVersion(major: 2, minor: 1))
        XCTAssertEqual(sf.warnings, [])
        XCTAssertEqual(sf.info["INAM"], "GeneralUser GS 2.0.2")
    }
}
