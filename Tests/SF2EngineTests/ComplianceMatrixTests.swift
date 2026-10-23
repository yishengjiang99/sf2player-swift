// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import XCTest

/// Keeps docs/SF2_COMPLIANCE.md honest: every row names tests that exist, and every row is
/// `pass` or `n/a (reason)`.
final class ComplianceMatrixTests: XCTestCase {
    /// Work-in-progress switch: while false, `pending` rows make this test skip (listing them)
    /// instead of fail. Set to true once every row is pass / n/a.
    static let matrixMustBeComplete = true

    struct Row { var id: String; var tests: [String]; var status: String }

    static func rows() throws -> [Row] {
        let url = TestPaths.repoRoot.appendingPathComponent("docs/SF2_COMPLIANCE.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line -> Row? in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 7, cells[1].range(of: #"^[A-Z]+-\d+$"#, options: .regularExpression) != nil else { return nil }
            let tests = cells[4] == "—" ? [] : cells[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return Row(id: cells[1], tests: tests, status: cells[5])
        }
    }

    static func testFunctionNames() throws -> Set<String> {
        let dir = TestPaths.repoRoot.appendingPathComponent("Tests")
        var names = Set<String>()
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        let re = try NSRegularExpression(pattern: #"func\s+(test\w+)\s*\("#)
        while let u = e?.nextObject() as? URL {
            guard u.pathExtension == "swift", let s = try? String(contentsOf: u, encoding: .utf8) else { continue }
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range(at: 1), in: s) { names.insert(String(s[r])) }
            }
        }
        return names
    }

    func testComplianceMatrixIsCovered() throws {
        let rows = try Self.rows()
        XCTAssertGreaterThan(rows.count, 80)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "duplicate IDs")
        let names = try Self.testFunctionNames()
        var pending: [String] = []
        for r in rows {
            let na = r.status.hasPrefix("n/a (") && r.status.hasSuffix(")")
            if r.status == "pending" { pending.append(r.id); continue }
            XCTAssertTrue(r.status == "pass" || na, "\(r.id): bad status '\(r.status)'")
            if !na { XCTAssertFalse(r.tests.isEmpty, "\(r.id): no test named") }
            for t in r.tests { XCTAssertTrue(names.contains(t), "\(r.id): test \(t) does not exist") }
        }
        if !pending.isEmpty {
            if Self.matrixMustBeComplete { XCTFail("pending rows: \(pending.joined(separator: ", "))") }
            else { throw XCTSkip("\(pending.count) pending rows: \(pending.joined(separator: ", "))") }
        }
    }
}
