// SPDX-License-Identifier: MIT
// A `remove` of a directory takes its subtree with it. DSH's atomic write
// creates `.name.N.<uuid>.tmpdir/name.tmp`, renames it onto the target and
// removes the scratch directory; the WAL then holds the complete write of the
// scratch file followed by the `remove` of its parent, with no per-child
// tombstone. The materializer removes recursively, so the copy is right; the
// invariant must not report the scratch file as missing (seen on the phone as
// `WAL_CORRUPT: materialized copy diverges ... missingFile .../*.tmpdir/*.tmp`
// after a background park/resume, which failed the host).

import Foundation
import XCTest
import PhoneDSHLog
import PhoneDSHWire

final class MaterializedInvariantAncestorRemoveTests: XCTestCase {
    private func makeLog(_ root: URL) throws -> WorkspaceLog {
        try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                         bootID: LogTestSupport.bootID())
    }

    func testScratchFileUnderARemovedDirectoryIsExpectedAbsent() async throws {
        let root = LogTestSupport.root(for: self, name: "ancestor-remove")
        let log = try makeLog(root)
        let scratch = "/dsh/workspace/.build.py.1.0f5f2939.tmpdir"
        _ = try await log.append(LogTestSupport.mkdir(scratch))
        _ = try await log.append(LogTestSupport.write("\(scratch)/build.py.tmp", data: "print('hi')\n"))
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/build.py", data: "print('hi')\n"))
        let last = try await log.append(LogTestSupport.remove(scratch))
        _ = try await log.closeEpoch()

        let paths = WorkspacePaths(root: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.materializedDirectory.appendingPathComponent("workspace/.build.py.1.0f5f2939.tmpdir").path),
            "the materializer removes the scratch directory recursively")
        let records = try LogTestSupport.records(in: root)
        let report = try MaterializedInvariant.checkAndRepair(
            paths: paths, records: records, materializedUptoMseq: last, allowRepair: false)
        XCTAssertTrue(report.isClean, "a scratch file under a removed directory is absent by construction")
    }

    func testARecreatedFileAfterTheAncestorRemovalIsStillChecked() async throws {
        let root = LogTestSupport.root(for: self, name: "ancestor-remove-recreate")
        let log = try makeLog(root)
        let dir = "/dsh/workspace/out"
        _ = try await log.append(LogTestSupport.mkdir(dir))
        _ = try await log.append(LogTestSupport.write("\(dir)/a.txt", data: "one\n"))
        _ = try await log.append(LogTestSupport.remove(dir))
        _ = try await log.append(LogTestSupport.mkdir(dir))
        let last = try await log.append(LogTestSupport.write("\(dir)/a.txt", data: "two\n"))
        _ = try await log.closeEpoch()

        let paths = WorkspacePaths(root: root)
        let file = paths.materializedDirectory.appendingPathComponent("workspace/out/a.txt")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two\n")
        let records = try LogTestSupport.records(in: root)
        XCTAssertTrue(try MaterializedInvariant.checkAndRepair(
            paths: paths, records: records, materializedUptoMseq: last, allowRepair: false).isClean)

        // The recreated file is still verified against the record that made it:
        // a copy with the wrong bytes diverges.
        try Data("three\n".utf8).write(to: file)
        XCTAssertThrowsError(try MaterializedInvariant.checkAndRepair(
            paths: paths, records: records, materializedUptoMseq: last, allowRepair: false)) { error in
            XCTAssertTrue("\(error)".contains("contentMismatch") || "\(error)".contains("diverges"),
                          "unexpected error: \(error)")
        }
    }

    func testAMissingFileWithoutAnAncestorRemovalStillDiverges() async throws {
        let root = LogTestSupport.root(for: self, name: "ancestor-remove-control")
        let log = try makeLog(root)
        let last = try await log.append(LogTestSupport.write("/dsh/workspace/keep.txt", data: "keep\n"))
        _ = try await log.closeEpoch()

        let paths = WorkspacePaths(root: root)
        try FileManager.default.removeItem(
            at: paths.materializedDirectory.appendingPathComponent("workspace/keep.txt"))
        let records = try LogTestSupport.records(in: root)
        XCTAssertThrowsError(try MaterializedInvariant.checkAndRepair(
            paths: paths, records: records, materializedUptoMseq: last, allowRepair: false)) { error in
            XCTAssertTrue("\(error)".contains("missingFile"), "unexpected error: \(error)")
        }
    }

    func testNestedRemovalThenRecreationUsesOnlyTheLatestAncestorCut() async throws {
        let root = LogTestSupport.root(for: self, name: "nested-ancestor-recreate")
        let log = try makeLog(root)
        let outer = "/dsh/workspace/out"
        let inner = "\(outer)/nested"
        _ = try await log.append(LogTestSupport.mkdir(outer))
        _ = try await log.append(LogTestSupport.mkdir(inner))
        _ = try await log.append(LogTestSupport.write("\(inner)/value.txt", data: "before"))
        _ = try await log.append(LogTestSupport.remove(outer))
        _ = try await log.append(LogTestSupport.mkdir(outer))
        _ = try await log.append(LogTestSupport.mkdir(inner))
        let last = try await log.append(LogTestSupport.write("\(inner)/value.txt", data: "after"))
        _ = try await log.closeEpoch()

        let paths = WorkspacePaths(root: root)
        let file = paths.materializedDirectory.appendingPathComponent("workspace/out/nested/value.txt")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after")
        XCTAssertTrue(try MaterializedInvariant.checkAndRepair(
            paths: paths, records: LogTestSupport.records(in: root),
            materializedUptoMseq: last, allowRepair: false).isClean)
    }

    func testSamePathRemoveAndUnsettledWatermarkRemainAuthoritative() async throws {
        let root = LogTestSupport.root(for: self, name: "same-path-remove-watermark")
        let log = try makeLog(root)
        let path = "/dsh/workspace/item.txt"
        _ = try await log.append(LogTestSupport.write(path, data: "first"))
        let removed = try await log.append(LogTestSupport.remove(path))
        _ = try await log.closeEpoch()

        let paths = WorkspacePaths(root: root)
        let records = try LogTestSupport.records(in: root)
        XCTAssertTrue(try MaterializedInvariant.checkAndRepair(
            paths: paths, records: records, materializedUptoMseq: removed,
            allowRepair: false).isClean)

        let aboveWatermark = try await log.append(LogTestSupport.write(path, data: "unsettled"))
        _ = try await log.closeEpoch()
        let withUnsettledWrite = try LogTestSupport.records(in: root)
        XCTAssertTrue(try MaterializedInvariant.checkAndRepair(
            paths: paths, records: withUnsettledWrite,
            materializedUptoMseq: removed, allowRepair: false).isClean,
            "a path with a mutation above the contiguous watermark is not compared to the prefix")
        XCTAssertGreaterThan(aboveWatermark, removed)
    }

    func testGeneratedPlansMatchTheOriginalRemovalScanOracle() async throws {
        let root = LogTestSupport.root(for: self, name: "ancestor-remove-oracle")
        let log = try makeLog(root)
        for index in 0..<24 {
            let outer = "/dsh/workspace/generated-\(index)"
            let inner = "\(outer)/nested"
            _ = try await log.append(LogTestSupport.mkdir(outer))
            _ = try await log.append(LogTestSupport.write("\(inner)/value.txt", data: "v0"))
            if index.isMultiple(of: 3) {
                _ = try await log.append(LogTestSupport.remove("\(inner)/value.txt"))
            }
            _ = try await log.append(LogTestSupport.remove(outer))
            if index.isMultiple(of: 2) {
                _ = try await log.append(LogTestSupport.mkdir(outer))
                _ = try await log.append(LogTestSupport.mkdir(inner))
                _ = try await log.append(LogTestSupport.write("\(inner)/value.txt", data: "v1"))
            }
            if index.isMultiple(of: 5) {
                _ = try await log.append(LogTestSupport.write(
                    "/dsh/workspace/generated-siblings/file-\(index).txt", data: "s"))
            }
        }
        let watermark = try await log.append(LogTestSupport.write("/dsh/workspace/final.txt", data: "done"))
        _ = try await log.closeEpoch()

        let records = try LogTestSupport.records(in: root)
        XCTAssertEqual(records.filter { !$0.isEpochClose }.last?.mseq, watermark)
        let expectedPlanCount = originalRemovalScanPlanCount(records, watermark: watermark)
        let report = try MaterializedInvariant.checkAndRepair(
            paths: WorkspacePaths(root: root), records: records,
            materializedUptoMseq: watermark, allowRepair: false)
        XCTAssertEqual(report.checkedPaths, expectedPlanCount)
        XCTAssertTrue(report.isClean)
    }

    /// Bounded reference implementation of the original full-removal scan.
    private func originalRemovalScanPlanCount(_ records: [WALRecord], watermark: UInt64) -> Int {
        func isBase(_ body: VfsMutationBody) -> Bool {
            switch body.op {
            case .write: return !body.mflags.contains(.appended)
            case .remove, .mkdir: return true
            case .chmod: return false
            }
        }
        let mutations = records.filter { !$0.isEpochClose }.sorted { $0.mseq < $1.mseq }
        let relevant = mutations.filter { $0.mseq <= watermark }
        var byPath: [String: [(WALRecord, VfsMutationBody)]] = [:]
        for record in relevant {
            guard let body = try? record.mutationBody() else { continue }
            byPath[body.path, default: []].append((record, body))
        }
        let unsettled = Set(mutations.filter { $0.mseq > watermark }.compactMap {
            try? $0.mutationBody().path
        })
        let removals = relevant.compactMap { record -> (String, UInt64)? in
            guard let body = try? record.mutationBody(), body.op == .remove else { return nil }
            return (body.path, record.mseq)
        }
        var count = 0
        for (path, entries) in byPath where !unsettled.contains(path) {
            guard let baseIndex = entries.lastIndex(where: { isBase($0.1) }) else { continue }
            let baseMseq = entries[baseIndex].0.mseq
            let pathRecords = entries[baseIndex...].map(\.0)
            let cut = removals.filter {
                $0.0 != path && path.hasPrefix($0.0 + "/") && $0.1 > baseMseq
            }.map(\.1).max()
            if let cut {
                let after = pathRecords.filter { $0.mseq > cut }
                if after.isEmpty {
                    count += 1
                } else if after.contains(where: { record in
                    guard let body = try? record.mutationBody() else { return false }
                    return isBase(body)
                }) {
                    count += 1
                }
            } else {
                count += 1
            }
        }
        return count
    }
}
