// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: WAL-accounted recovery check.
//
// `restart_recovered` used to compare whole-tree SHA-256 snapshots of the
// materialized workspace taken before and after a perturbation, and to fail on
// any difference. D14 explicitly lets the in-flight turn keep writing while the
// host drains for park/restart, and every such write is acked into the WAL, so
// a legal drain-window write was reported as recovery corruption
// (`acked materialized files changed: …`). The check now rebuilds the expected
// workspace by replaying the WAL mutations in `(beforeAcked, afterAcked]` with
// the D9 materializer semantics and requires the materialized tree to equal
// that replay. A divergence with no WAL mutation behind it still fails loud,
// and a file may only disappear through a remove mutation.
//
// The replay starts from a byte copy of the materialized workspace frozen
// before the perturbation. The mechanism is generic: it only reads the WAL and
// the host watermarks, so every perturbation kind (park_resume,
// planned_restart, worker_kill, webcontent_kill) and every scenario uses the
// same rule. No scenario, prompt or file name is special-cased.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// One WAL mutation replayed across a recovery, in mseq order.
///
/// Recorded in `report.json` under `perturbations[].accounted_changes` so the
/// audit trail names which mseq accounted for each workspace change.
public struct ScenarioRecoveryChange: Encodable, Equatable, Sendable {
    /// The mseq that accounts for this change.
    public var mseq: UInt64
    /// `write`, `append`, `mkdir`, `remove` or `chmod` (D9 operations).
    public var op: String
    /// Absolute VFS path from the WAL record.
    public var path: String

    public init(mseq: UInt64, op: String, path: String) {
        self.mseq = mseq
        self.op = op
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case mseq, op, path
    }
}

/// Outcome of the WAL-accounted recovery comparison.
struct ScenarioRecoveryVerdict {
    var ok: Bool
    var detail: String
    var accounted: [ScenarioRecoveryChange]

    static func success(_ detail: String,
                        accounted: [ScenarioRecoveryChange]) -> ScenarioRecoveryVerdict {
        ScenarioRecoveryVerdict(ok: true, detail: detail, accounted: accounted)
    }

    static func failure(_ detail: String,
                        accounted: [ScenarioRecoveryChange] = []) -> ScenarioRecoveryVerdict {
        ScenarioRecoveryVerdict(ok: false, detail: detail, accounted: accounted)
    }
}

/// A frozen copy of the pre-perturbation materialized workspace. The copy is
/// the base the WAL replay runs on, so the real materialized tree may keep
/// changing while the check runs.
struct ScenarioRecoveryBase {
    let root: URL

    func discard() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Verifies a recovery by replaying the WAL instead of comparing raw snapshots.
enum ScenarioRecovery {
    /// How many diagnostics/snapshot reads the runner may make before it
    /// declares a divergence. A healthy host settles on the first read; the
    /// retries absorb a mutation that materializes between the watermark read
    /// and the snapshot read (or a materializer temporary file).
    static let maximumCheckAttempts = 20

    /// Pause between two recovery-check attempts.
    static let checkRetryInterval: TimeInterval = 0.05

    /// Freezes the materialized workspace under `hostRoot`.
    static func captureBase(hostRoot: URL,
                            fileManager: FileManager = .default) throws -> ScenarioRecoveryBase {
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "pdsh-scenario-recovery-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("materialized/workspace",
                                                      isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = hostRoot.appendingPathComponent("materialized/workspace",
                                                     isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else {
            return ScenarioRecoveryBase(root: root)
        }
        for child in try fileManager.contentsOfDirectory(at: source,
                                                         includingPropertiesForKeys: nil) {
            // `.pdsh-tmp-*` is the materializer's atomic-write scratch file, not
            // a workspace file; a snapshot that raced a rename must not carry
            // it into the expected tree.
            guard !child.lastPathComponent.hasPrefix(".pdsh-tmp-") else { continue }
            try fileManager.copyItem(
                at: child,
                to: destination.appendingPathComponent(child.lastPathComponent))
        }
        return ScenarioRecoveryBase(root: root)
    }

    /// Rebuilds the expected post-recovery workspace from `base` plus the WAL
    /// mutations in `(replayFloor, afterAcked]` and requires `after` to be
    /// byte-identical to it.
    ///
    /// `replayFloor` is the pre-perturbation acked watermark, exactly the
    /// accounting window start. If the materialized copy was ever behind that
    /// watermark, the frozen snapshot only reaches the materialized cut, so the
    /// replay starts there instead to stay sound.
    ///
    /// - Parameters:
    ///   - hostRoot: the run's `host/` directory (holds `wal/` and
    ///     `materialized/`).
    ///   - base: the frozen pre-perturbation workspace copy.
    ///   - before: snapshot of `base` (used to name stale bytes on failure).
    ///   - beforeAcked: acked watermark on the host before the perturbation.
    ///   - beforeMaterialized: materialized watermark on the host before the
    ///     perturbation; every mutation at or below it is already in `base`.
    ///   - afterAcked: acked watermark after recovery.
    ///   - afterMaterialized: materialized watermark after recovery.
    ///   - after: post-recovery snapshot of the live materialized workspace.
    static func verify(hostRoot: URL,
                       base: ScenarioRecoveryBase,
                       before: MaterializedSnapshot,
                       beforeAcked: UInt64,
                       beforeMaterialized: UInt64,
                       afterAcked: UInt64,
                       afterMaterialized: UInt64,
                       after: MaterializedSnapshot) -> ScenarioRecoveryVerdict {
        // The acked watermark must never move backwards; this check predates
        // the WAL accounting and is kept verbatim.
        guard afterAcked >= beforeAcked else {
            return .failure("the acked mseq watermark moved backwards")
        }
        // The WAL replay below requires every acked mutation to have reached
        // the materialized copy. A host that reports Running while materialized
        // is behind acked has not finished recovery; never pass that state.
        guard afterMaterialized >= afterAcked else {
            return .failure("acked mseq \(afterAcked) is not materialized "
                + "(materialized_upto_mseq \(afterMaterialized)); recovery is incomplete")
        }
        let replayFloor = min(beforeAcked, beforeMaterialized)

        let records: [WALRecord]
        do {
            let scan = try WALReader.scan(
                directory: hostRoot.appendingPathComponent("wal", isDirectory: true))
            records = WALReader.records(in: scan.segments, fromMseq: replayFloor + 1)
                .filter { $0.mseq <= afterAcked }
                .sorted { $0.mseq < $1.mseq }
        } catch {
            return .failure("cannot read the WAL for the recovery accounting: \(error)")
        }

        // The WAL is the authority for the whole mseq range. A gap means a
        // mutation the run cannot account for; failing loud is the only honest
        // verdict (this also catches a truncated range under quota pressure).
        do {
            var expectedMseq = replayFloor + 1
            var missing: [UInt64] = []
            for record in records {
                while expectedMseq < record.mseq {
                    missing.append(expectedMseq)
                    expectedMseq += 1
                }
                expectedMseq = record.mseq + 1
            }
            while expectedMseq <= afterAcked {
                missing.append(expectedMseq)
                expectedMseq += 1
            }
            if let first = missing.first, let last = missing.last {
                let range = first == last ? "mseq \(first)" : "mseq \(first)...\(last)"
                return .failure("the WAL does not account for \(range) in "
                    + "(\(replayFloor), \(afterAcked)]; the recovery check cannot pass")
            }
        }

        var replay: [(record: WALRecord, change: ScenarioRecoveryChange)] = []
        for record in records {
            guard let body = try? record.mutationBody() else {
                return .failure("the WAL record at mseq \(record.mseq) has no mutation body")
            }
            guard relativeWorkspacePath(body.path) != nil else { continue }
            let op: String
            if body.mflags.contains(.appended) {
                op = "append"
            } else {
                switch body.op {
                case .write: op = "write"
                case .mkdir: op = "mkdir"
                case .remove: op = "remove"
                case .chmod: op = "chmod"
                }
            }
            replay.append((record, ScenarioRecoveryChange(
                mseq: record.mseq, op: op, path: body.path)))
        }
        let accounted = replay.map(\.change)

        // The frozen base may already contain mutations above the replay floor
        // (the materializer can apply a concurrent write between the watermark
        // read and the copy). Two WAL cases stay exactly reproducible anyway:
        // chmod changes no bytes, and an append later overwritten by a complete
        // write/remove has no effect on the final bytes. Dropping them from the
        // replay keeps the expected tree faithful; all remain in the audit
        // accounting above.
        var materializeRecords: [WALRecord] = []
        for (index, entry) in replay.enumerated() {
            guard let body = try? entry.record.mutationBody() else { continue }
            if body.op == .chmod { continue }
            if body.mflags.contains(.appended),
               replay[(index + 1)...].contains(where: { later in
                   guard let laterBody = try? later.record.mutationBody(),
                         laterBody.path == body.path else { return false }
                   if laterBody.op == .remove { return true }
                   return laterBody.op == .write
                       && !laterBody.mflags.contains(.appended)
               }) {
                continue
            }
            materializeRecords.append(entry.record)
        }

        let expected: MaterializedSnapshot
        do {
            expected = try replayWorkspace(base: base, records: materializeRecords)
        } catch let error as ScenarioRecoveryReplayError {
            return .failure(error.description, accounted: accounted)
        } catch {
            return .failure("the WAL replay failed: \(error)", accounted: accounted)
        }

        let issues = differences(before: before,
                                 expected: expected,
                                 after: after,
                                 accounting: accounted)
        if !issues.isEmpty {
            return .failure("the materialized workspace does not match the "
                + "WAL-accounted replay: \(issues.prefix(8).joined(separator: ", "))",
                accounted: accounted)
        }

        if accounted.isEmpty {
            return .success("WAL replay found no workspace mutation in "
                + "(\(replayFloor), \(afterAcked)]; the materialized workspace "
                + "matches the pre-perturbation snapshot", accounted: accounted)
        }
        let summary = accounted.prefix(6)
            .map { "\($0.mseq) \($0.op) \($0.path)" }
            .joined(separator: ", ")
        return .success("WAL replay accounted for \(accounted.count) workspace "
            + "mutation(s) in (\(replayFloor), \(afterAcked)]: \(summary); "
            + "the materialized workspace matches the replayed state", accounted: accounted)
    }

    // MARK: - Replay

    /// Replays the workspace mutations onto a private copy of `base` using the
    /// same `Materializer` the host uses (D9 write/append/remove/mkdir/chmod
    /// semantics), then returns the resulting snapshot.
    private static func replayWorkspace(base: ScenarioRecoveryBase,
                                        records: [WALRecord]) throws -> MaterializedSnapshot {
        let fileManager = FileManager.default
        let workRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "pdsh-scenario-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workRoot) }

        let materialized = workRoot.appendingPathComponent("materialized", isDirectory: true)
        try fileManager.createDirectory(at: materialized, withIntermediateDirectories: true)
        let source = base.root.appendingPathComponent("materialized/workspace",
                                                      isDirectory: true)
        let workspace = materialized.appendingPathComponent("workspace", isDirectory: true)
        if fileManager.fileExists(atPath: source.path) {
            try fileManager.copyItem(at: source, to: workspace)
        } else {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        }

        let materializer = try Materializer(root: workRoot)
        for record in records {
            do {
                _ = try materializer.apply(record)
            } catch {
                throw ScenarioRecoveryReplayError(
                    "the WAL replay of mseq \(record.mseq) failed: \(error)")
            }
        }
        if materializer.deferredRecordCount > 0 {
            let paths = materializer.needsResyncPaths.sorted().prefix(5).joined(separator: ", ")
            throw ScenarioRecoveryReplayError(
                "the WAL replay could not settle appended mutation(s) for \(paths); "
                + "the materialized base does not match the WAL")
        }
        return MaterializedSnapshot.read(workspaceRoot: workRoot)
    }

    // MARK: - Comparison

    private static func differences(before: MaterializedSnapshot,
                                    expected: MaterializedSnapshot,
                                    after: MaterializedSnapshot,
                                    accounting: [ScenarioRecoveryChange]) -> [String] {
        var lastChange: [String: ScenarioRecoveryChange] = [:]
        var removals: [String: ScenarioRecoveryChange] = [:]
        for change in accounting {
            guard let relative = relativeWorkspacePath(change.path) else { continue }
            lastChange[relative] = change
            if change.op == "remove" {
                removals[relative] = change
            }
        }

        func removal(for path: String) -> ScenarioRecoveryChange? {
            var components = path.split(separator: "/").map(String.init)
            while !components.isEmpty {
                if let change = removals[components.joined(separator: "/")] {
                    return change
                }
                components.removeLast()
            }
            return nil
        }

        var issues: [String] = []
        let paths = Set(expected.entries.keys)
            .union(after.entries.keys)
            .sorted()
        for path in paths {
            let expectedEntry = expected.entries[path]
            let actualEntry = after.entries[path]
            switch (expectedEntry, actualEntry) {
            case let (expected?, actual?) where expected == actual:
                continue
            case (_?, let actual?):
                if let change = lastChange[path] {
                    if let prior = before.entries[path], prior == actual {
                        issues.append("\(path) still materializes its pre-recovery bytes; "
                            + "WAL mseq \(change.mseq) \(change.op) was not applied")
                    } else {
                        issues.append("\(path) diverged from the WAL-accounted state at "
                            + "mseq \(change.mseq) (\(change.op))")
                    }
                } else {
                    issues.append("\(path) changed without a WAL mutation")
                }
            case (_?, nil):
                issues.append("\(path) disappeared without a remove mutation")
            case (nil, _?):
                if let change = lastChange[path] ?? removal(for: path) {
                    issues.append("\(path) was removed by WAL mseq \(change.mseq) "
                        + "but is still materialized")
                } else if before.entries[path] != nil {
                    issues.append("\(path) reappeared without a WAL mutation")
                } else {
                    issues.append("\(path) appeared without a WAL mutation")
                }
            case (nil, nil):
                continue
            }
        }
        return issues
    }

    /// `/dsh/workspace/<relative>` -> `<relative>`; `nil` for another root.
    private static func relativeWorkspacePath(_ vfsPath: String) -> String? {
        let prefix = "/dsh/workspace/"
        guard vfsPath.hasPrefix(prefix) else { return nil }
        let relative = String(vfsPath.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }
}

/// A WAL replay that cannot be trusted: naming the mseq/path makes the failure
/// auditable instead of a bare "changed" verdict.
private struct ScenarioRecoveryReplayError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
