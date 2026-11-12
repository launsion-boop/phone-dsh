// SPDX-License-Identifier: MIT
// Fixture-driven WAL replay conformance (wal.md §5.1, §6.2, §7.2, §10;
// spec/v1/golden/wal/replay/README.md).
//
// Every vector is installed as a real workspace: the materialized copy, the
// manifest checkpoint and real WAL segments. `RecoveryManager.recover()` then
// drives the production replay/invariant/rebuild code, and the Materializer's
// per-record decisions are compared with the fixture. Nothing here copies the
// rule's expected values into the implementation input.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class WALReplayFixtureTests: XCTestCase {
    // MARK: - Fixture shape

    private struct Content: Decodable {
        var contentUtf8: String?
        var contentHex: String?

        enum CodingKeys: String, CodingKey {
            case contentUtf8 = "content_utf8"
            case contentHex = "content_hex"
        }

        var data: Data {
            get throws {
                if let contentHex {
                    return try LogTestSupport.data(hex: contentHex)
                }
                guard let contentUtf8 else {
                    throw LogTestSupport.FixtureError(
                        description: "content is neither utf8 nor hex")
                }
                return Data(contentUtf8.utf8)
            }
        }
    }

    private struct RecordVector: Decodable {
        var mseq: UInt64
        var op: UInt8
        var path: String
        var appended: Bool
        var appendFrom: UInt64?
        var data: Content?

        enum CodingKeys: String, CodingKey {
            case mseq, op, path, appended
            case appendFrom = "append_from"
            case data
        }

        func mutation() throws -> VfsMutationBody {
            switch op {
            case 1:
                return VfsMutationBody(
                    op: .write,
                    mode: 0o644,
                    mflags: appended ? .appended : [],
                    appendFrom: appended ? (appendFrom ?? 0) : 0,
                    path: path,
                    data: try data?.data ?? Data())
            case 3:
                return VfsMutationBody(op: .remove, mode: 0, path: path)
            default:
                throw LogTestSupport.FixtureError(
                    description: "unsupported fixture op \(op)")
            }
        }
    }

    private struct VerdictVector: Decodable {
        var mseq: UInt64
        var verdict: String
        var cover: String?
        var supersededByMseq: UInt64?

        enum CodingKeys: String, CodingKey {
            case mseq, verdict, cover
            case supersededByMseq = "superseded_by_mseq"
        }
    }

    private struct CopyReplay: Decodable {
        var records: [VerdictVector]
        var materializedUptoMseq: UInt64
        var failed: Bool

        enum CodingKeys: String, CodingKey {
            case records
            case materializedUptoMseq = "materialized_upto_mseq"
            case failed
        }
    }

    private struct WatermarkStep: Decodable {
        var mseq: UInt64
        var materializedUptoMseq: UInt64

        enum CodingKeys: String, CodingKey {
            case mseq
            case materializedUptoMseq = "materialized_upto_mseq"
        }
    }

    private struct Expected: Decodable {
        var records: [VerdictVector]
        var materializedUptoMseq: UInt64
        var watermarkSteps: [WatermarkStep]?
        var tree: [String: Content]
        var failed: Bool
        var rebuiltFromWal: Bool?
        var copyReplay: CopyReplay?

        enum CodingKeys: String, CodingKey {
            case records
            case materializedUptoMseq = "materialized_upto_mseq"
            case watermarkSteps = "watermark_steps"
            case tree, failed
            case rebuiltFromWal = "rebuilt_from_wal"
            case copyReplay = "copy_replay"
        }
    }

    private struct ReplayVector: Decodable {
        var id: String
        var title: String
        var materializedUptoMseq: UInt64
        var copy: [String: Content]
        var records: [RecordVector]
        var expected: Expected

        enum CodingKeys: String, CodingKey {
            case id, title, copy, records, expected
            case materializedUptoMseq = "materialized_upto_mseq"
        }
    }

    // MARK: - Runner

    func testEveryReplayVectorDrivesRealRecovery() async throws {
        let root = try LogTestSupport.repoRoot()
        let directories = ["spec/v1/golden/wal/replay",
                           "spec/v1/golden/wal/replay-phone"]
            .map { root.appendingPathComponent($0) }
        var files: [URL] = []
        for directory in directories {
            files.append(contentsOf: try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" })
        }
        files.sort { $0.lastPathComponent < $1.lastPathComponent }
        // The shared set is 14 files; the phone-only closed-session rewrite is
        // the 15th (PC-20261112-bot-session-epoch). A missing or duplicated
        // vector must fail the runner instead of silently narrowing conformance.
        XCTAssertEqual(files.count, 15,
                       "expected the 15 frozen replay vectors, found \(files.count)")
        var seenIDs = Set<String>()
        for file in files {
            let vector = try JSONDecoder().decode(
                ReplayVector.self, from: Data(contentsOf: file))
            XCTAssertTrue(seenIDs.insert(vector.id).inserted,
                          "duplicate replay vector id \(vector.id)")
            do {
                try await run(vector, file: file)
            } catch {
                XCTFail("\(file.lastPathComponent) (\(vector.title)): \(error)")
            }
        }
    }

    private func run(_ vector: ReplayVector, file: URL) async throws {
        let root = LogTestSupport.root(for: self)
        let paths = WorkspacePaths(root: root)
        try paths.createDirectories()
        let bootID = LogTestSupport.bootID()
        let bootIDHex = bootID.map { String(format: "%02x", $0) }.joined()

        for (path, content) in vector.copy {
            let target = try materializedURL(path, paths: paths)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try content.data.write(to: target)
            _ = chmod(target.path, 0o644)
        }

        let manifestStore = ManifestStore(paths: paths)
        guard let firstMseq = vector.records.first?.mseq else {
            throw LogTestSupport.FixtureError(description: "vector has no records")
        }
        // The bootstrap manifest only lets WALWriter allocate from the
        // vector's first mseq; the real checkpoint is written afterwards.
        try manifestStore.write(Manifest(
            bootID: bootIDHex,
            materializedUptoMseq: 0,
            lastMseq: firstMseq - 1,
            lastDurableEpoch: 0,
            segments: []))
        do {
            let writer = try WALWriter(
                configuration: LogTestSupport.configuration(root: root),
                bootID: bootID)
            for record in vector.records {
                _ = try await writer.append(try record.mutation())
            }
            try await writer.flush()
        }
        let scan = try WALReader.scan(directory: paths.walDirectory)
        XCTAssertEqual(scan.mutationMseqs, vector.records.map(\.mseq),
                       "\(vector.id): planted WAL mseq sequence")
        let lastMseq = max(vector.materializedUptoMseq,
                           vector.records.map(\.mseq).max() ?? 0)
        try manifestStore.write(Manifest(
            bootID: bootIDHex,
            materializedUptoMseq: vector.materializedUptoMseq,
            lastMseq: lastMseq,
            lastDurableEpoch: 0,
            segments: WALSegmentLifecycle.manifestSegments(scan.segments.map {
                WALSegmentLifecycleRecord(segment: $0)
            })))

        let decisions = LockedValues<MaterializeDecision>()
        let manager = RecoveryManager(
            configuration: LogTestSupport.configuration(root: root),
            bootID: bootID,
            decisionObserver: { decisions.append($0) })
        let report = try manager.recover()
        let observed = decisions.values

        let tailCount = vector.records.filter {
            $0.mseq > vector.materializedUptoMseq
        }.count
        let tailDecisions = Array(observed.prefix(tailCount))
        let rebuilt = vector.expected.rebuiltFromWal ?? false
        XCTAssertEqual(report.rebuiltFromWal, rebuilt,
                       "\(vector.id): rebuilt_from_wal")

        var verdicts: [UInt64: MaterializeDecision] = [:]
        if rebuilt {
            // The rebuild replays the whole retained history from mseq 1.
            let rebuildDecisions = observed.suffix(vector.records.count)
            XCTAssertEqual(rebuildDecisions.count, vector.records.count,
                           "\(vector.id): rebuild decisions")
            for decision in rebuildDecisions {
                verdicts[decision.mseq] = decision
            }
        } else {
            for decision in tailDecisions {
                verdicts[decision.mseq] = decision
            }
            for record in vector.records where record.mseq <= vector.materializedUptoMseq {
                verdicts[record.mseq] = MaterializeDecision(
                    mseq: record.mseq,
                    verdict: .alreadyMaterialized,
                    materializedUptoMseq: vector.materializedUptoMseq)
            }
        }

        XCTAssertEqual(verdicts.count, vector.records.count,
                       "\(vector.id): every record has a verdict")

        // Per-record verdicts, in input order.
        XCTAssertEqual(vector.expected.records.count, vector.records.count,
                       "\(vector.id): expected verdict count")
        for (record, expected) in zip(vector.records, vector.expected.records) {
            XCTAssertEqual(record.mseq, expected.mseq,
                           "\(vector.id): verdict mseq order")
            guard let decision = verdicts[record.mseq] else {
                XCTFail("\(vector.id): mseq \(record.mseq) has no decision")
                continue
            }
            assertVerdict(decision.verdict, expected, id: vector.id,
                          mseq: record.mseq)
        }

        // Per-step conservative watermarks.
        if let steps = vector.expected.watermarkSteps {
            XCTAssertFalse(steps.isEmpty, "\(vector.id): empty watermark_steps")
            for step in steps {
                guard let decision = verdicts[step.mseq] else {
                    XCTFail("\(vector.id): no decision for watermark step \(step.mseq)")
                    continue
                }
                XCTAssertEqual(decision.materializedUptoMseq,
                               step.materializedUptoMseq,
                               "\(vector.id): watermark after mseq \(step.mseq)")
            }
        }

        XCTAssertEqual(report.materializedUptoMseq,
                       vector.expected.materializedUptoMseq,
                       "\(vector.id): final materialized_upto_mseq")
        XCTAssertEqual(!report.needsResync.isEmpty || !report.resyncHolds.isEmpty,
                       vector.expected.failed,
                       "\(vector.id): failed flag (pending repair)")

        // The given-copy replay is the first phase, before the §7.2 rebuild.
        if let copyReplay = vector.expected.copyReplay {
            var copyVerdicts: [UInt64: MaterializeDecision] = [:]
            for decision in tailDecisions {
                copyVerdicts[decision.mseq] = decision
            }
            for record in vector.records where record.mseq <= vector.materializedUptoMseq {
                copyVerdicts[record.mseq] = MaterializeDecision(
                    mseq: record.mseq,
                    verdict: .alreadyMaterialized,
                    materializedUptoMseq: vector.materializedUptoMseq)
            }
            XCTAssertEqual(copyReplay.records.count, vector.records.count,
                           "\(vector.id): copy_replay verdict count")
            for expected in copyReplay.records {
                guard let decision = copyVerdicts[expected.mseq] else {
                    XCTFail("\(vector.id): copy replay has no mseq \(expected.mseq)")
                    continue
                }
                assertVerdict(decision.verdict, expected, id: vector.id,
                              mseq: expected.mseq)
            }
            let lastWatermark = tailDecisions.last?.materializedUptoMseq
                ?? vector.materializedUptoMseq
            XCTAssertEqual(lastWatermark, copyReplay.materializedUptoMseq,
                           "\(vector.id): copy_replay watermark")
            XCTAssertEqual(tailDecisions.contains { decision in
                if case .mismatchHeld = decision.verdict { return true }
                return false
            }, copyReplay.failed, "\(vector.id): copy_replay failed")
        }

        // Final materialized tree.
        let tree = try materializedTree(paths: paths)
        var expectedTree: [String: Data] = [:]
        for (path, content) in vector.expected.tree {
            expectedTree[path] = try content.data
        }
        XCTAssertEqual(tree, expectedTree,
                       "\(vector.id): final materialized tree")
    }

    private func assertVerdict(_ verdict: MaterializeVerdict,
                               _ expected: VerdictVector,
                               id: String,
                               mseq: UInt64) {
        switch expected.verdict {
        case "applied":
            XCTAssertEqual(verdict, .applied, "\(id): mseq \(mseq) verdict")
        case "skipped-idempotent":
            XCTAssertEqual(verdict, .skippedIdempotent,
                           "\(id): mseq \(mseq) verdict")
        case "mismatch-held":
            XCTAssertEqual(verdict, .mismatchHeld, "\(id): mseq \(mseq) verdict")
        case "already-materialized":
            XCTAssertEqual(verdict, .alreadyMaterialized,
                           "\(id): mseq \(mseq) verdict")
        case "settled-superseded":
            guard case .settledSuperseded(let coverMseq, let cover) = verdict else {
                XCTFail("\(id): mseq \(mseq) expected settled-superseded, got \(verdict)")
                return
            }
            XCTAssertEqual(coverMseq, expected.supersededByMseq,
                           "\(id): mseq \(mseq) superseded_by_mseq")
            switch expected.cover {
            case "remove":
                XCTAssertEqual(cover, .remove, "\(id): mseq \(mseq) cover")
            case "ancestor-remove":
                XCTAssertEqual(cover, .ancestorRemove, "\(id): mseq \(mseq) cover")
            case "complete-write", "truncate", "repair-write":
                // The reference checker treats the three complete-write labels
                // as one family; the runner reports the exact one it observed.
                switch cover {
                case .completeWrite, .truncate, .repairWrite:
                    break
                default:
                    XCTFail("\(id): mseq \(mseq) expected a write cover, got \(cover)")
                }
            default:
                XCTFail("\(id): mseq \(mseq) invalid expected cover \(expected.cover ?? "nil")")
            }
        default:
            XCTFail("\(id): mseq \(mseq) unknown verdict \(expected.verdict)")
        }
    }

    // MARK: - Workspace helpers

    private func materializedURL(_ path: String,
                                 paths: WorkspacePaths) throws -> URL {
        guard path.hasPrefix("/dsh/") else {
            throw LogTestSupport.FixtureError(description: "non-VFS path \(path)")
        }
        return paths.materializedDirectory
            .appendingPathComponent(String(path.dropFirst("/dsh/".count)))
    }

    private func materializedTree(paths: WorkspacePaths) throws -> [String: Data] {
        var tree: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: paths.materializedDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []) else { return tree }
        let base = paths.materializedDirectory.standardizedFileURL.path
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            guard relative.hasPrefix("home/") || relative.hasPrefix("workspace/") else {
                continue
            }
            tree["/dsh/" + relative] = try Data(contentsOf: url)
        }
        return tree
    }
}
