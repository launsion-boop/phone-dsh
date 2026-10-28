// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: WAL-accounted recovery check.
//
// Regression for the G2-B04 false failure: `restart_recovered` compared
// whole-tree SHA-256 snapshots taken before and after a park/restart, so a
// write the in-flight turn legally acked into the WAL during the D14 drain
// window was reported as `acked materialized files changed: …`. The fix
// replays the WAL mutations in `(beforeMaterialized, afterAcked]` onto the
// frozen pre-perturbation workspace and requires byte equality instead.
//
// The fixtures below are component-level: no WKWebView, model or screen is
// involved. `Materializer` produces the "host recovered" tree exactly the way
// the host does (D9 write/append/remove/mkdir/chmod), then `ScenarioRecovery`
// must reproduce it from the frozen base and the WAL. The same suite carries
// the tamper control (a divergence absent from the WAL must still fail) and
// pins the scripted mock-model selftest scenario that exercises the drain
// window end to end.

import Foundation
import XCTest
import PhoneDSHLog
import PhoneDSHWire
@testable import PhoneDSHScenario

final class PhoneDSHScenarioRecoveryTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pdsh-scenario-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
    }

    // MARK: - Fixtures

    @discardableResult
    private func write(_ relative: String, _ text: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A host root with the pre-perturbation files of the G2-B04 shape: three
    /// acked files the in-flight turn may rewrite, one file a mutation removes
    /// and one untouched file.
    private func makeHostRoot() throws -> URL {
        let root = sandbox.appendingPathComponent("host", isDirectory: true)
        let workspace = root.appendingPathComponent("materialized/workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try write("materialized/workspace/bill_a.py", "bill_a = 0\n", under: root)
        try write("materialized/workspace/bill_b.py", "keep\n", under: root)
        try write("materialized/workspace/main.py", "print('main')\n", under: root)
        try write("materialized/workspace/README.md", "# billing\n", under: root)
        return root
    }

    /// The mutations the session acked into the WAL while the host drained for
    /// the park. mseq 101 rewrites an existing file (the G2-B04 false-failure
    /// shape), 102 appends with D9 semantics, 103 creates a new file, 104
    /// removes an existing file, 105/106 exercise mkdir/chmod accounting.
    private static let drainWindowMutations: [(mseq: UInt64, mutation: VfsMutationBody)] = [
        (101, VfsMutationBody(op: .write, mode: 0o644,
                              path: "/dsh/workspace/bill_a.py",
                              data: Data("bill_a = 1\n".utf8))),
        (102, VfsMutationBody(op: .write, mode: 0o644,
                              mflags: .appended, appendFrom: 5,
                              path: "/dsh/workspace/bill_b.py",
                              data: Data("drain\n".utf8))),
        (103, VfsMutationBody(op: .write, mode: 0o644,
                              path: "/dsh/workspace/billing.py",
                              data: Data("billing = 1\n".utf8))),
        (104, VfsMutationBody(op: .remove, mode: 0,
                              path: "/dsh/workspace/main.py")),
        (105, VfsMutationBody(op: .mkdir, mode: 0o755,
                              path: "/dsh/workspace/pkg")),
        (106, VfsMutationBody(op: .chmod, mode: 0o600,
                              path: "/dsh/workspace/README.md")),
    ]

    /// Writes one verified WAL segment holding `mutations` and the epoch close
    /// record for the same durable watermark, exactly as the host writes it.
    @discardableResult
    private func writeWAL(hostRoot: URL,
                          firstMseq: UInt64,
                          mutations: [(mseq: UInt64, mutation: VfsMutationBody)],
                          epochClose: UInt64?) throws -> [WALRecord] {
        let bootID = Data(repeating: 0x5A, count: 16)
        let header = try WALSegmentHeader(firstMseq: firstMseq, bootID: bootID)
        var records: [WALRecord] = try mutations.map {
            try WALRecord(mseq: $0.mseq, mutation: $0.mutation)
        }
        if let epochClose {
            records.append(try WALRecord(epochClose: 1_790_000_000_000,
                                         durableUpto: epochClose))
        }
        let segment = try WALSegment(header: header, records: records)
        let directory = hostRoot.appendingPathComponent("wal", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = mutations.first?.mseq ?? firstMseq
        let fileName = String(format: "00000001.%06llu.xlwal", start % 1_000_000)
        try segment.encoded().write(to: directory.appendingPathComponent(fileName))
        return records.filter { !$0.isEpochClose }
    }

    /// Applies the WAL to the host root the way recovery does, and returns the
    /// materialized watermark the host would report. `fromMseq` is the
    /// watermark the pre-park materialized copy already reached.
    @discardableResult
    private func applyWAL(_ records: [WALRecord], hostRoot: URL,
                          fromMseq: UInt64 = 100) throws -> UInt64 {
        let materializer = try Materializer(root: hostRoot,
                                           materializedUptoMseq: fromMseq)
        for record in records {
            _ = try materializer.apply(record)
        }
        return materializer.materializedUptoMseq
    }

    // MARK: - Regression

    /// Pre-fix this fails with `acked materialized files changed: bill_a.py
    /// changed, bill_b.py changed, main.py disappeared`: the legal acked
    /// drain-window writes are reported as corruption. Post-fix the expected
    /// tree is the frozen base plus WAL mseq 101...106, and every observed
    /// change names its accounting mseq.
    func testLegalDrainWindowWritesAreAccountedByWALReplay() throws {
        let host = try makeHostRoot()
        let base = try ScenarioRecovery.captureBase(hostRoot: host)
        let before = MaterializedSnapshot.read(workspaceRoot: base.root)

        let records = try writeWAL(hostRoot: host,
                                   firstMseq: 101,
                                   mutations: Self.drainWindowMutations,
                                   epochClose: 106)
        let materialized = try applyWAL(records, hostRoot: host)
        let after = MaterializedSnapshot.read(workspaceRoot: host)

        // The write content itself is intact after recovery.
        XCTAssertEqual(after.entries["bill_a.py"]?.sha256,
                       MaterializedSnapshot.hex(of: Data("bill_a = 1\n".utf8)))
        XCTAssertEqual(after.entries["bill_b.py"]?.sha256,
                       MaterializedSnapshot.hex(of: Data("keep\ndrain\n".utf8)))
        XCTAssertEqual(after.entries["billing.py"]?.sha256,
                       MaterializedSnapshot.hex(of: Data("billing = 1\n".utf8)))
        XCTAssertNil(after.entries["main.py"], "the remove mutation must be materialized")

        let verdict = ScenarioRecovery.verify(
            hostRoot: host,
            base: base,
            before: before,
            beforeAcked: 100,
            beforeMaterialized: 100,
            afterAcked: 106,
            afterMaterialized: materialized,
            after: after)
        XCTAssertTrue(verdict.ok, verdict.detail)
        XCTAssertEqual(materialized, 106)

        // Every observed content change carries the mseq that accounted for it.
        let byPath = Dictionary(uniqueKeysWithValues: verdict.accounted.map { ($0.path, $0) })
        XCTAssertEqual(byPath["/dsh/workspace/bill_a.py"]?.mseq, 101)
        XCTAssertEqual(byPath["/dsh/workspace/bill_a.py"]?.op, "write")
        XCTAssertEqual(byPath["/dsh/workspace/bill_b.py"]?.mseq, 102)
        XCTAssertEqual(byPath["/dsh/workspace/bill_b.py"]?.op, "append")
        XCTAssertEqual(byPath["/dsh/workspace/billing.py"]?.mseq, 103)
        XCTAssertEqual(byPath["/dsh/workspace/main.py"]?.mseq, 104)
        XCTAssertEqual(byPath["/dsh/workspace/main.py"]?.op, "remove")
        XCTAssertTrue(verdict.detail.contains("101 write /dsh/workspace/bill_a.py"),
                      verdict.detail)
    }

    /// The real runner freezes its base right after `diagnostics()`, which
    /// materializes the acked tail: the base can already contain mutations above
    /// the acked watermark the replay starts from. Re-applying them must be an
    /// idempotent no-op (D9), never a false failure.
    func testReplayIsIdempotentWhenTheFrozenBaseIsAheadOfTheAckedWatermark() throws {
        let host = try makeHostRoot()
        // The host materialized mseq 101-102 before the acked watermark was
        // sampled (diagnostics: positions first, materialize second).
        let early = try writeWAL(hostRoot: host, firstMseq: 101,
                                 mutations: Array(Self.drainWindowMutations.prefix(2)),
                                 epochClose: nil)
        _ = try applyWAL(early, hostRoot: host)
        let base = try ScenarioRecovery.captureBase(hostRoot: host)
        let before = MaterializedSnapshot.read(workspaceRoot: base.root)

        let records = try writeWAL(hostRoot: host, firstMseq: 101,
                                   mutations: Self.drainWindowMutations,
                                   epochClose: 106)
        let materialized = try applyWAL(records, hostRoot: host)
        let after = MaterializedSnapshot.read(workspaceRoot: host)

        let verdict = ScenarioRecovery.verify(
            hostRoot: host,
            base: base,
            before: before,
            beforeAcked: 100,
            beforeMaterialized: 102,
            afterAcked: 106,
            afterMaterialized: materialized,
            after: after)
        XCTAssertTrue(verdict.ok, verdict.detail)
        XCTAssertEqual(verdict.accounted.first?.mseq, 101)
        XCTAssertTrue(verdict.detail.contains("(100, 106]"), verdict.detail)
    }

    /// The tamper control: a post-recovery divergence with no WAL mutation
    /// behind it must still fail loud and name the unaccounted paths.
    func testUnaccountedPostRecoveryDivergenceStillFails() throws {
        let host = try makeHostRoot()
        let base = try ScenarioRecovery.captureBase(hostRoot: host)
        let before = MaterializedSnapshot.read(workspaceRoot: base.root)
        let records = try writeWAL(hostRoot: host, firstMseq: 101,
                                   mutations: Self.drainWindowMutations,
                                   epochClose: 106)
        let materialized = try applyWAL(records, hostRoot: host)

        // Tamper in two shapes: a WAL-accounted path gets bytes no mutation
        // wrote, and a file with no mutation appears.
        try write("materialized/workspace/bill_b.py", "tampered\n", under: host)
        try write("materialized/workspace/tampered.py", "unaccounted\n", under: host)
        let after = MaterializedSnapshot.read(workspaceRoot: host)

        let verdict = ScenarioRecovery.verify(
            hostRoot: host,
            base: base,
            before: before,
            beforeAcked: 100,
            beforeMaterialized: 100,
            afterAcked: 106,
            afterMaterialized: materialized,
            after: after)
        XCTAssertFalse(verdict.ok, "a divergence absent from the WAL must still fail")
        XCTAssertTrue(verdict.detail.contains("bill_b.py"), verdict.detail)
        XCTAssertTrue(verdict.detail.contains("mseq 102"), verdict.detail)
        XCTAssertTrue(verdict.detail.contains("tampered.py"), verdict.detail)
        XCTAssertTrue(verdict.detail.contains("without a WAL mutation"), verdict.detail)
    }

    /// Stale re-materialization is the failure the check exists to catch: the
    /// WAL says bill_a.py changed, but the materialized copy still holds the
    /// pre-recovery bytes.
    func testStalePreRecoveryBytesAreNotAccepted() throws {
        let host = try makeHostRoot()
        let base = try ScenarioRecovery.captureBase(hostRoot: host)
        let before = MaterializedSnapshot.read(workspaceRoot: base.root)
        let records = try writeWAL(hostRoot: host, firstMseq: 101,
                                   mutations: Self.drainWindowMutations,
                                   epochClose: 106)
        let materialized = try applyWAL(records, hostRoot: host)
        try write("materialized/workspace/bill_a.py", "bill_a = 0\n", under: host)
        let after = MaterializedSnapshot.read(workspaceRoot: host)

        let verdict = ScenarioRecovery.verify(
            hostRoot: host,
            base: base,
            before: before,
            beforeAcked: 100,
            beforeMaterialized: 100,
            afterAcked: 106,
            afterMaterialized: materialized,
            after: after)
        XCTAssertFalse(verdict.ok, "stale pre-recovery bytes must not pass")
        XCTAssertTrue(verdict.detail.contains("bill_a.py"), verdict.detail)
        XCTAssertTrue(verdict.detail.contains("pre-recovery"), verdict.detail)
        XCTAssertTrue(verdict.detail.contains("mseq 101"), verdict.detail)
    }

    /// A missing WAL range cannot be waved through: the check fails loud
    /// instead of treating the gap as "no change".
    func testWALGapCannotPassAsAccounted() throws {
        let host = try makeHostRoot()
        let base = try ScenarioRecovery.captureBase(hostRoot: host)
        let before = MaterializedSnapshot.read(workspaceRoot: base.root)
        let first = try writeWAL(hostRoot: host, firstMseq: 101,
                                 mutations: [
                                    (101, VfsMutationBody(op: .write, mode: 0o644,
                                                          path: "/dsh/workspace/bill_a.py",
                                                          data: Data("bill_a = 1\n".utf8))),
                                    (102, VfsMutationBody(op: .write, mode: 0o644,
                                                          path: "/dsh/workspace/bill_b.py",
                                                          data: Data("one\n".utf8))),
                                 ],
                                 epochClose: nil)
        // A separate segment whose first mutation skips mseq 103.
        let bootID = Data(repeating: 0x5A, count: 16)
        let secondHeader = try WALSegmentHeader(firstMseq: 104, bootID: bootID)
        let secondSegment = try WALSegment(header: secondHeader, records: [
            try WALRecord(mseq: 104, mutation: VfsMutationBody(
                op: .write, mode: 0o644, path: "/dsh/workspace/bill_c.py",
                data: Data("bill_c = 1\n".utf8))),
            try WALRecord(mseq: 105, mutation: VfsMutationBody(
                op: .write, mode: 0o644, path: "/dsh/workspace/bill_b.py",
                data: Data("two\n".utf8))),
        ])
        try secondSegment.encoded().write(
            to: host.appendingPathComponent("wal/00000002.000000.xlwal"))
        _ = try applyWAL(first, hostRoot: host)

        let verdict = ScenarioRecovery.verify(
            hostRoot: host,
            base: base,
            before: before,
            beforeAcked: 100,
            beforeMaterialized: 100,
            afterAcked: 105,
            afterMaterialized: 105,
            after: MaterializedSnapshot.read(workspaceRoot: host))
        XCTAssertFalse(verdict.ok, "a WAL gap must fail, not pass")
        XCTAssertTrue(verdict.detail.contains("does not account for mseq 103"),
                      verdict.detail)
    }

    // MARK: - Report audit trail

    /// The report carries the accounting so a reviewer can see which mseq
    /// explains each post-recovery change.
    func testPerturbationReportEncodesTheAccountedChanges() throws {
        let report = ScenarioPerturbationReport(
            at: "during_first_tool",
            kind: "park_resume",
            recoveredMs: 20_507,
            ok: true,
            accountedChanges: [
                ScenarioRecoveryChange(mseq: 414, op: "write",
                                       path: "/dsh/workspace/bill_a.py"),
                ScenarioRecoveryChange(mseq: 415, op: "append",
                                       path: "/dsh/workspace/bill_b.py"),
            ],
            detail: "WAL replay accounted for 2 workspace mutation(s)")
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let changes = try XCTUnwrap(object["accounted_changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0]["mseq"] as? UInt64, 414)
        XCTAssertEqual(changes[0]["op"] as? String, "write")
        XCTAssertEqual(changes[0]["path"] as? String, "/dsh/workspace/bill_a.py")
        XCTAssertEqual(changes[1]["mseq"] as? UInt64, 415)
    }

    // MARK: - Selftest scenario wiring

    /// The runner gate (`scenarios.sh --only G2-SELFTEST`) must exercise the
    /// drain-window shape: a scripted mock model whose first tool call parks
    /// the host while its delayed command rewrites a file that already exists
    /// before the park (a new file would have been exempted by the old
    /// `differences()` check).
    func testSelftestScenarioCarriesTheDrainWindowParkResume() throws {
        let root = try XCTUnwrap(
            scenarioRepositoryRoot(startingAt: URL(fileURLWithPath: #filePath)),
            "cannot locate the repository root from #filePath")
        let catalog = try ScenarioCatalog.load(
            from: root.appendingPathComponent("scripts/ci/scenarios/selftest.json"))
        let scenario = try XCTUnwrap(catalog.scenarios.first { $0.id == "G2-SELFTEST" })
        let perturbations = scenario.perturbations ?? []
        XCTAssertTrue(perturbations.contains {
            $0.at == "during_first_tool" && $0.kind == "park_resume"
        }, "G2-SELFTEST must park during the first tool call; got \(perturbations)")
        XCTAssertNotNil(scenario.workspace.files?["bill_a.py"],
                        "the drain-window write must target a file that exists before the park")
        let command = try XCTUnwrap(scenario.mock?.toolCommand)
        XCTAssertTrue(command.contains("sleep"), command)
        XCTAssertTrue(command.contains("bill_a.py"), command)
        XCTAssertTrue(scenario.assertions.contains { $0.type == "restart_recovered" },
                      "the selftest must assert the recovery verdict")
    }
}
