// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the materialized-copy
// invariant (D8/D9/D11).
//
// The materialized copy is derived only from WAL records. A completed write is
// acknowledged at level 1 and replayed into that copy; the strictly contiguous
// `materialized_upto_mseq` claims that every mutation at or below it is present
// with its last acknowledged content.
//
// G2-A09 broke exactly that invariant: a 16 MiB file that had been written,
// boundary-confirmed and re-verified during the run was absent from the final
// materialized workspace while later partial writes from the hung call were
// present, and the next recovery had no way to notice. This file makes the
// invariant checkable:
//
//   * rebuild the expected last state of every path whose base operation
//     (complete write, remove, mkdir) is retained in the WAL prefix, using the
//     same D9 semantics as the live materializer;
//   * compare it with the materialized copy;
//   * on divergence: rebuild the materialized copy from the WAL when the
//     retained history starts at mseq 1 (the same condition under which
//     wal.md §7.2 permits a WAL-only rebuild), otherwise throw `WAL_CORRUPT`
//     so the host fails loud instead of silently presenting lost data.
//
// The check is mechanism-only: it names no path, prompt or scenario. A stop or
// an abort calls it on the real WAL; a recovery calls it before it truncates a
// single segment, so the decision to delete WAL history is always backed by a
// verified materialized copy.

import Darwin
import Foundation
import PhoneDSHWire

/// Kind of one materialized-copy divergence.
public enum MaterializedInvariantKind: String, Equatable, Sendable {
    /// The WAL says the last acknowledged content is a file, the copy has none.
    case missingFile
    /// The WAL says the last acknowledged content is a directory, the copy has none.
    case missingDirectory
    /// The bytes differ from the last acknowledged content.
    case contentMismatch
    /// The mode differs from the last acknowledged content.
    case modeMismatch
    /// The WAL's last operation removed the path (or created it differently)
    /// but the copy still has it.
    case unexpectedFile
    case unexpectedDirectory
}

extension MaterializedInvariantKind: CustomStringConvertible {
    public var description: String { rawValue }
}

/// One divergence between the WAL prefix and the materialized copy.
public struct MaterializedInvariantViolation: Equatable, Sendable {
    /// Absolute VFS path under `/dsh/home` or `/dsh/workspace`.
    public var path: String
    public var kind: MaterializedInvariantKind
    public var expectedSize: Int?
    public var actualSize: Int?

    public init(path: String, kind: MaterializedInvariantKind,
                expectedSize: Int? = nil, actualSize: Int? = nil) {
        self.path = path
        self.kind = kind
        self.expectedSize = expectedSize
        self.actualSize = actualSize
    }

    /// Machine-readable reason form used by the host's `Failed` reason.
    public var machineDescription: String {
        var text = "\(kind.rawValue) \(path)"
        if let expectedSize { text += " expected_bytes=\(expectedSize)" }
        if let actualSize { text += " actual_bytes=\(actualSize)" }
        return text
    }
}

/// One local repair of a derived boot-metadata path. It is deliberately not a
/// full-tree rebuild: the watermark, the WAL and every other materialized path
/// are left exactly as they were.
public struct MaterializedInvariantLocalRepair: Equatable, Sendable {
    public var path: String
    public var kind: MaterializedInvariantKind
    public var expectedSize: Int
    public var expectedMode: UInt32
    public var expectedSha256: String
    public var actualSize: Int?
    public var actualMode: UInt32?
    public var actualSha256: String?
    /// The original bytes/mode were recorded under the workspace's private
    /// `recovery-backup/` tree before the first write. The record itself stays
    /// in the workspace; it is not exported to a host report or log.
    public var backupRecorded: Bool

    public init(path: String,
                kind: MaterializedInvariantKind,
                expectedSize: Int,
                expectedMode: UInt32,
                expectedSha256: String,
                actualSize: Int? = nil,
                actualMode: UInt32? = nil,
                actualSha256: String? = nil,
                backupRecorded: Bool = true) {
        self.path = path
        self.kind = kind
        self.expectedSize = expectedSize
        self.expectedMode = expectedMode
        self.expectedSha256 = expectedSha256
        self.actualSize = actualSize
        self.actualMode = actualMode
        self.actualSha256 = actualSha256
        self.backupRecorded = backupRecorded
    }

    /// Machine-readable local-recovery diagnostic (never carries the local
    /// workspace path or the backup contents).
    public var machineDescription: String {
        var text = "localRepair \(kind.rawValue) \(path)"
        text += " expected_bytes=\(expectedSize) expected_mode=\(String(expectedMode, radix: 8))"
        text += " expected_sha256=\(expectedSha256)"
        if let actualSize { text += " actual_bytes=\(actualSize)" }
        if let actualMode { text += " actual_mode=\(String(actualMode, radix: 8))" }
        if let actualSha256 { text += " actual_sha256=\(actualSha256)" }
        return text
    }
}

/// Result of one invariant pass.
public struct MaterializedInvariantReport: Equatable, Sendable {
    public var violations: [MaterializedInvariantViolation]
    /// Paths whose expected state was fully determined by the retained WAL.
    public var checkedPaths: Int
    /// Whether the retained WAL covers the whole mutation history from mseq 1.
    public var hasFullHistory: Bool
    /// Whether the materialized copy was rebuilt from the WAL.
    public var repaired: Bool
    /// The watermark the checked/repaired copy now holds.
    public var materializedUptoMseq: UInt64
    /// Exactly the derived boot-metadata paths restored in place, when the
    /// retained WAL still holds a complete base and contiguous suffix for
    /// them. Empty for a check that needed no repair.
    public var localRepairs: [MaterializedInvariantLocalRepair]

    public init(violations: [MaterializedInvariantViolation] = [],
                checkedPaths: Int = 0,
                hasFullHistory: Bool = false,
                repaired: Bool = false,
                materializedUptoMseq: UInt64 = 0,
                localRepairs: [MaterializedInvariantLocalRepair] = []) {
        self.violations = violations
        self.checkedPaths = checkedPaths
        self.hasFullHistory = hasFullHistory
        self.repaired = repaired
        self.materializedUptoMseq = materializedUptoMseq
        self.localRepairs = localRepairs
    }

    public var isClean: Bool { violations.isEmpty }
}

/// The stop/recovery invariant of the materialized copy (D8/D11/D18).
public enum MaterializedInvariant {
    /// Directory name of the repair's scratch tree under the workspace root.
    static let scratchName = "materialized.verify"
    /// Directory name the repair renames the old tree to while swapping.
    static let previousName = ".materialized.previous"
    /// Workspace-private root of the local-repair preimage records. It is not
    /// part of the VFS and never enters the boot overlay.
    static let recoveryBackupName = "recovery-backup"

    /// The complete set of paths eligible for local repair. These are DSH's
    /// two generated boot-metadata files: the WAL is the authority for their
    /// exact bytes and POSIX mode, and the live Worker republishes them through
    /// VFS_MUT when the image/profile changes.
    ///
    /// The boundary is deliberate. User files, Session JSONL, workspace
    /// sources and every other `/dsh/home` or `/dsh/workspace` path still fail
    /// `WAL_CORRUPT` even when a retained base could prove their bytes: a
    /// generic per-path rewrite would be indistinguishable from masking the
    /// first unsolved writer of user data. The check itself is still global;
    /// only the recovery action is scoped. This repair proves and restores a
    /// detectable retained divergence; it does not identify the first writer
    /// that made the old copy diverge.
    static let locallyRepairablePaths: Set<String> = [
        "/dsh/home/AGENTS.md",
        "/dsh/home/capabilities.json",
    ]

    /// Runs the invariant over `records` (the retained WAL, mutations and
    /// epoch-close records in any order) against the materialized copy under
    /// `paths.root`.
    ///
    /// A divergence is repaired by a full WAL replay when the retained history
    /// starts at mseq 1. When it starts above mseq 1 the copy is not rebuilt
    /// from an incomplete root; instead a divergence that is confined to the
    /// two generated boot-metadata paths and whose complete base plus
    /// contiguous suffix is retained is restored in place with a private
    /// preimage backup. Every other divergence still throws `WAL_CORRUPT`.
    ///
    /// - Parameters:
    ///   - materializedUptoMseq: the strictly contiguous watermark the copy
    ///     claims. Only records at or below it are compared.
    ///   - allowRepair: perform either the full rebuild or the scoped local
    ///     repair when possible. When `false`, a divergence always throws.
    /// - Throws: `LogError.corrupt` when the copy diverges and cannot be
    ///   proven and repaired (truncated history), with a machine-readable
    ///   path/kind reason.
    @discardableResult
    public static func checkAndRepair(
        paths: WorkspacePaths,
        records: [WALRecord],
        materializedUptoMseq: UInt64,
        allowRepair: Bool = true,
        bootIDHex: String = ""
    ) throws -> MaterializedInvariantReport {
        let mutations = records.filter { !$0.isEpochClose }.sorted { $0.mseq < $1.mseq }
        let fullHistory = hasFullHistory(mutations)
        let plans = try verificationPlans(mutations: mutations,
                                          materializedUptoMseq: materializedUptoMseq)
        if plans.isEmpty {
            return MaterializedInvariantReport(checkedPaths: 0,
                                               hasFullHistory: fullHistory,
                                               repaired: false,
                                               materializedUptoMseq: materializedUptoMseq)
        }
        var violations: [MaterializedInvariantViolation] = []
        for plan in plans {
            guard let expected = expectedState(plan) else { continue }
            violations.append(contentsOf: try compare(path: plan.path,
                                                      expected: expected,
                                                      materializedDirectory: paths.materializedDirectory))
        }
        if violations.isEmpty {
            return MaterializedInvariantReport(checkedPaths: plans.count,
                                               hasFullHistory: fullHistory,
                                               repaired: false,
                                               materializedUptoMseq: materializedUptoMseq)
        }
        guard allowRepair else {
            throw divergenceError(violations, fullHistory: fullHistory, localReason: nil)
        }
        if fullHistory {
            let watermark = try rebuildFromWAL(paths: paths, mutations: mutations,
                                               bootIDHex: bootIDHex)
            return MaterializedInvariantReport(violations: violations,
                                               checkedPaths: plans.count,
                                               hasFullHistory: true,
                                               repaired: true,
                                               materializedUptoMseq: watermark)
        }
        if let local = try localRepairIfPossible(paths: paths,
                                                 mutations: mutations,
                                                 plans: plans,
                                                 violations: violations,
                                                 materializedUptoMseq: materializedUptoMseq,
                                                 bootIDHex: bootIDHex) {
            return local
        }
        throw divergenceError(violations, fullHistory: fullHistory, localReason: nil)
    }

    private static func divergenceError(_ violations: [MaterializedInvariantViolation],
                                        fullHistory: Bool,
                                        localReason: String?) -> LogError {
        let summary = violations.prefix(4).map(\.machineDescription)
            .joined(separator: "; ")
        let suffix: String
        if let localReason {
            suffix = "; \(localReason)"
        } else if fullHistory {
            suffix = "; repair is disabled"
        } else {
            suffix = "; the retained history does not start at mseq 1 and no complete "
                + "retained base with a contiguous suffix proves a local repair"
        }
        return LogError.corrupt(
            "materialized copy diverges from the retained WAL: \(summary)" + suffix)
    }

    // MARK: - Scoped local repair

    private struct LocalRepairCandidate {
        var violation: MaterializedInvariantViolation
        var data: Data
        var mode: UInt32
        var actualData: Data?
        var actualMode: UInt32?
        var expectedSha256: String
    }

    private struct TargetInspection {
        var exists: Bool
        var isRegular: Bool
        var mode: UInt32?
        var data: Data?
    }

    private struct PreimageRecord: Codable {
        var schema: String
        var vfsPath: String
        var kind: String
        var bootID: String
        var originalState: String
        var originalSize: Int?
        var originalMode: UInt32?
        var originalSha256: String?
        var expectedSize: Int
        var expectedMode: UInt32
        var expectedSha256: String

        enum CodingKeys: String, CodingKey {
            case schema
            case vfsPath = "vfs_path"
            case kind
            case bootID = "boot_id"
            case originalState = "original_state"
            case originalSize = "original_size"
            case originalMode = "original_mode"
            case originalSha256 = "original_sha256"
            case expectedSize = "expected_size"
            case expectedMode = "expected_mode"
            case expectedSha256 = "expected_sha256"
        }
    }

    /// Restores only ``locallyRepairablePaths`` when their retained base and
    /// every mseq through the watermark are present. Returns `nil` when any
    /// violation is outside that proof boundary, leaving the caller to fail
    /// loud with the full divergence.
    private static func localRepairIfPossible(
        paths: WorkspacePaths,
        mutations: [WALRecord],
        plans: [PathPlan],
        violations: [MaterializedInvariantViolation],
        materializedUptoMseq: UInt64,
        bootIDHex: String
    ) throws -> MaterializedInvariantReport? {
        var plansByPath: [String: PathPlan] = [:]
        for plan in plans {
            plansByPath[plan.path] = plan
        }
        // The two-path policy is all-or-nothing: if either derived file exists
        // on disk but its retained base/suffix cannot prove it, no local repair
        // may boot the workspace with one unproven metadata file.
        for policyPath in locallyRepairablePaths.sorted() {
            let target = try safeMaterializedTarget(path: policyPath, paths: paths)
            let inspection = try inspectMaterializedTarget(target)
            guard inspection.exists else { continue }
            guard let plan = plansByPath[policyPath],
                  provesLocalState(plan: plan,
                                   mutations: mutations,
                                   watermark: materializedUptoMseq),
                  let expected = expectedState(plan),
                  case .file = expected else {
                return nil
            }
        }
        var candidates: [LocalRepairCandidate] = []
        for violation in violations {
            guard locallyRepairablePaths.contains(violation.path) else { return nil }
            switch violation.kind {
            case .contentMismatch, .missingFile, .modeMismatch:
                break
            default:
                return nil
            }
            guard let plan = plansByPath[violation.path],
                  provesLocalState(plan: plan,
                                   mutations: mutations,
                                   watermark: materializedUptoMseq),
                  let expected = expectedState(plan),
                  case .file(let data, let mode) = expected,
                  mode <= 0o7777 else {
                return nil
            }
            let target = try safeMaterializedTarget(path: violation.path, paths: paths)
            let inspection = try inspectMaterializedTarget(target)
            switch violation.kind {
            case .missingFile:
                guard !inspection.exists else { return nil }
            case .contentMismatch, .modeMismatch:
                guard inspection.exists, inspection.isRegular else { return nil }
            default:
                return nil
            }
            candidates.append(LocalRepairCandidate(
                violation: violation,
                data: data,
                mode: mode,
                actualData: inspection.data,
                actualMode: inspection.mode,
                expectedSha256: SHA256.hash(data)))
        }
        guard !candidates.isEmpty else { return nil }

        // Every original preimage is made durable under the workspace-private
        // backup tree before the first materialized write. A failure here
        // leaves the copy untouched and aborts recovery.
        for candidate in candidates {
            do {
                try recordPreimage(paths: paths,
                                   candidate: candidate,
                                   bootIDHex: bootIDHex)
            } catch {
                throw divergenceError(
                    violations,
                    fullHistory: false,
                    localReason: "the preimage backup for \(candidate.violation.path) "
                        + "failed, so no recovery write was attempted: \(error)")
            }
        }

        let materializer: Materializer
        do {
            materializer = try Materializer(root: paths.root)
        } catch {
            throw divergenceError(
                violations,
                fullHistory: false,
                localReason: "the local recovery materializer could not open: \(error)")
        }
        var repairs: [MaterializedInvariantLocalRepair] = []
        for candidate in candidates {
            do {
                switch candidate.violation.kind {
                case .modeMismatch:
                    try materializer.repairMaterializedMode(
                        path: candidate.violation.path, mode: candidate.mode)
                default:
                    try materializer.repairMaterializedFile(
                        path: candidate.violation.path,
                        data: candidate.data,
                        mode: candidate.mode)
                }
            } catch {
                throw divergenceError(
                    violations,
                    fullHistory: false,
                    localReason: "the local recovery write for \(candidate.violation.path) "
                        + "failed after its preimage was recorded: \(error)")
            }
            repairs.append(MaterializedInvariantLocalRepair(
                path: candidate.violation.path,
                kind: candidate.violation.kind,
                expectedSize: candidate.data.count,
                expectedMode: candidate.mode,
                expectedSha256: candidate.expectedSha256,
                actualSize: candidate.actualData?.count,
                actualMode: candidate.actualMode,
                actualSha256: candidate.actualData.map(SHA256.hash)))
        }

        // The repair must itself prove the exact WAL state before it is
        // reported as successful.
        for candidate in candidates {
            let remaining = try compare(
                path: candidate.violation.path,
                expected: .file(candidate.data, mode: candidate.mode),
                materializedDirectory: paths.materializedDirectory)
            guard remaining.isEmpty else {
                throw divergenceError(
                    violations,
                    fullHistory: false,
                    localReason: "the local recovery write for \(candidate.violation.path) "
                        + "did not produce the retained bytes/mode")
            }
        }
        return MaterializedInvariantReport(violations: violations,
                                           checkedPaths: plans.count,
                                           hasFullHistory: false,
                                           repaired: false,
                                           materializedUptoMseq: materializedUptoMseq,
                                           localRepairs: repairs)
    }

    /// The path's last base and every global mutation mseq through the
    /// watermark must be retained. A hole could hide a later write to this
    /// path, so no local repair is allowed across it.
    private static func provesLocalState(plan: PathPlan,
                                         mutations: [WALRecord],
                                         watermark: UInt64) -> Bool {
        guard let base = plan.records.first?.mseq, base >= 1, watermark >= base else {
            return false
        }
        var previous = base - 1
        var sawBase = false
        for record in mutations {
            guard record.mseq <= watermark else { break }
            guard record.mseq >= base else { continue }
            if !sawBase {
                guard record.mseq == base else { return false }
                sawBase = true
            } else {
                guard record.mseq == previous + 1 else { return false }
            }
            previous = record.mseq
        }
        return sawBase && previous == watermark
    }

    /// Maps an allowed VFS path to a target without following a symlinked
    /// parent. Missing or non-directory parents are refused.
    private static func safeMaterializedTarget(path: String,
                                               paths: WorkspacePaths) throws -> URL {
        _ = try vfsURL(for: path, materializedDirectory: paths.materializedDirectory)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 4 else {
            throw LogError.materializationFailed("local recovery path has no file component")
        }
        guard LogFile.exists(paths.materializedDirectory),
              try LogFile.isDirectory(paths.materializedDirectory) else {
            throw LogError.materializationFailed("the materialized root is not a directory")
        }
        var cursor = paths.materializedDirectory
        for component in components.dropFirst(2).dropLast() {
            cursor.appendPathComponent(String(component))
            guard LogFile.exists(cursor), try LogFile.isDirectory(cursor) else {
                throw LogError.materializationFailed(
                    "local recovery refuses a missing or symlinked parent directory")
            }
        }
        return cursor.appendingPathComponent(String(components.last!))
    }

    private static func inspectMaterializedTarget(_ target: URL) throws -> TargetInspection {
        var info = stat()
        guard lstat(target.path, &info) == 0 else {
            if errno == ENOENT {
                return TargetInspection(exists: false, isRegular: false, mode: nil, data: nil)
            }
            throw LogError.posix(operation: "lstat", code: errno)
        }
        let mode = UInt32(info.st_mode & mode_t(0o7777))
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return TargetInspection(exists: true, isRegular: false, mode: mode, data: nil)
        }
        let data = try readRegularFileNoFollow(target)
        return TargetInspection(exists: true, isRegular: true, mode: mode, data: data)
    }

    private static func readRegularFileNoFollow(_ url: URL) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw LogError.posix(operation: "open", code: errno)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw LogError.posix(operation: "fstat", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw LogError.materializationFailed("a recovery preimage is not a regular file")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw LogError.posix(operation: "read", code: errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// Records `<sha256>-<original_mode>.preimage` plus a sibling JSON record
    /// under `recovery-backup/<vfs path>/`. Restoring the preimage means copying
    /// that file back and applying `original_mode` (or removing the path when
    /// `original_state == "absent"`). The record never contains the local
    /// workspace path or the expected/actual metadata contents.
    private static func recordPreimage(paths: WorkspacePaths,
                                       candidate: LocalRepairCandidate,
                                       bootIDHex: String) throws {
        let relative = candidate.violation.path.hasPrefix("/dsh/")
            ? String(candidate.violation.path.dropFirst("/dsh/".count))
            : candidate.violation.path
        let backupRoot = paths.root.appendingPathComponent(recoveryBackupName, isDirectory: true)
        let pathDirectory = backupRoot.appendingPathComponent(relative, isDirectory: true)
        try ensurePrivateDirectory(backupRoot)
        try ensurePrivateSubdirectory(base: backupRoot, relative: relative)

        let baseName: String
        if let data = candidate.actualData {
            let digest = SHA256.hash(data)
            let mode = candidate.actualMode ?? 0
            baseName = "\(digest)-\(String(mode, radix: 8))"
            let preimage = pathDirectory.appendingPathComponent(baseName + ".preimage")
            if LogFile.exists(preimage) {
                let existing = try readRegularFileNoFollow(preimage)
                guard existing == data else {
                    throw LogError.materializationFailed(
                        "a recovery preimage already exists with different bytes")
                }
            } else {
                try LogFile.atomicWrite(
                    data,
                    to: preimage,
                    temporaryURL: pathDirectory.appendingPathComponent(baseName + ".tmp"),
                    mode: 0o600)
            }
            try LogFile.setMode(preimage, mode: 0o600)
        } else {
            baseName = "absent"
        }

        let record = PreimageRecord(
            schema: "materialized-recovery-backup/1",
            vfsPath: candidate.violation.path,
            kind: candidate.violation.kind.rawValue,
            bootID: bootIDHex,
            originalState: candidate.actualData == nil ? "absent" : "file",
            originalSize: candidate.actualData?.count,
            originalMode: candidate.actualMode,
            originalSha256: candidate.actualData.map(SHA256.hash),
            expectedSize: candidate.data.count,
            expectedMode: candidate.mode,
            expectedSha256: candidate.expectedSha256)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let recordData = try encoder.encode(record)
        let recordURL = pathDirectory.appendingPathComponent(baseName + ".json")
        try LogFile.atomicWrite(
            recordData,
            to: recordURL,
            temporaryURL: pathDirectory.appendingPathComponent(baseName + ".record.tmp"),
            mode: 0o600)
        try LogFile.setMode(recordURL, mode: 0o600)
        try LogFile.fsyncDirectory(pathDirectory)
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        let created = try LogFile.createDirectoryTree(url, mode: 0o700)
        for directory in created {
            try LogFile.setMode(directory, mode: 0o700)
        }
        guard LogFile.exists(url), try LogFile.isDirectory(url) else {
            throw LogError.materializationFailed(
                "a recovery backup path is not a directory")
        }
        try LogFile.setMode(url, mode: 0o700)
        try LogFile.fsyncDirectory(url.deletingLastPathComponent())
    }

    /// Creates backup subdirectories one component at a time from an already
    /// validated private directory. Each existing component is checked with
    /// `lstat`; a symlink is refused before a child could be created through it.
    private static func ensurePrivateSubdirectory(base: URL, relative: String) throws {
        var cursor = base
        for rawComponent in relative.split(separator: "/") {
            let component = String(rawComponent)
            guard component != ".", component != "..", !component.isEmpty else {
                throw LogError.materializationFailed(
                    "a recovery backup path has an invalid component")
            }
            let next = cursor.appendingPathComponent(component, isDirectory: true)
            if LogFile.exists(next) {
                guard try LogFile.isDirectory(next) else {
                    throw LogError.materializationFailed(
                        "a recovery backup path is not a directory")
                }
            } else {
                do {
                    try FileManager.default.createDirectory(
                        at: next,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                } catch {
                    throw LogError.materializationFailed(
                        "cannot create a recovery backup directory")
                }
            }
            try LogFile.setMode(next, mode: 0o700)
            try LogFile.fsyncDirectory(cursor)
            cursor = next
        }
    }

    /// Rebuilds `materialized/` from the full retained WAL into a scratch tree
    /// and swaps it into place. The caller must have established that the
    /// retained mutations start at mseq 1 and are contiguous.
    ///
    /// - Returns: the strictly contiguous watermark of the rebuilt tree.
    public static func rebuildFromWAL(paths: WorkspacePaths,
                                      mutations: [WALRecord],
                                      bootIDHex: String = "") throws -> UInt64 {
        let ordered = mutations.sorted { $0.mseq < $1.mseq }
        guard let first = ordered.first else { return 0 }
        guard first.mseq == 1 else {
            throw LogError.corrupt(
                "cannot rebuild the materialized copy: the retained history starts at mseq \(first.mseq)")
        }
        var previous: UInt64 = 0
        for record in ordered {
            guard record.mseq == previous + 1 else {
                throw LogError.corrupt(
                    "cannot rebuild the materialized copy: mseq \(previous) jumps to \(record.mseq)")
            }
            previous = record.mseq
        }
        let scratch = paths.root.appendingPathComponent(scratchName, isDirectory: true)
        try LogFile.removeTree(scratch)
        let materializer = try Materializer(root: paths.root,
                                            materializedUptoMseq: 0,
                                            materializedDirectoryURL: scratch)
        _ = try materializer.apply(records: ordered)
        try materializer.fsyncEpoch()
        let watermark = materializer.materializedUptoMseq
        guard watermark == previous else {
            throw LogError.corrupt(
                "materialized rebuild stopped at mseq \(watermark), the WAL tail is \(previous)")
        }

        // The exchange is crash safe: the marker makes the next recovery redo
        // the staged reconcile instead of treating a half-swapped copy as a
        // fresh workspace, and the old tree stays under `previousName` until
        // the new one is in place.
        let marker = paths.reconcileMarkerURL
        let boot = bootIDHex.isEmpty ? String(repeating: "0", count: 32) : bootIDHex
        let payload = "{\"boot_id\":\"\(boot)\",\"target_tail\":\(watermark),"
            + "\"materialized\":\(watermark),\"reason\":\"materialized-invariant\"}\n"
        try LogFile.atomicWrite(Data(payload.utf8), to: marker)
        try swapStagingIntoPlace(paths: paths, staging: scratch)
        try LogFile.unlink(marker)
        try LogFile.fsyncDirectory(paths.root)
        return watermark
    }

    /// Exchanges `staging` with `materialized/` through a rename, fsyncing the
    /// workspace root. The marker written by the caller makes the exchange
    /// crash-recoverable.
    static func swapStagingIntoPlace(paths: WorkspacePaths, staging: URL) throws {
        try LogFile.fsyncDirectory(staging)
        let previousRoot = paths.root.appendingPathComponent(previousName, isDirectory: true)
        try LogFile.removeTree(previousRoot)
        var movedOld = false
        if LogFile.exists(paths.materializedDirectory) {
            try LogFile.rename(paths.materializedDirectory, to: previousRoot)
            movedOld = true
        }
        do {
            try LogFile.rename(staging, to: paths.materializedDirectory)
        } catch {
            if movedOld, !LogFile.exists(paths.materializedDirectory) {
                try? LogFile.rename(previousRoot, to: paths.materializedDirectory)
            }
            throw error
        }
        try LogFile.fsyncDirectory(paths.root)
        try LogFile.removeTree(previousRoot)
        try LogFile.fsyncDirectory(paths.root)
    }

    /// Restores a materialized copy that a crash left under the repair's
    /// previous-tree name. Returns `true` when the tree was restored.
    @discardableResult
    static func restorePreviousTreeIfNeeded(paths: WorkspacePaths) -> Bool {
        let previousRoot = paths.root.appendingPathComponent(previousName, isDirectory: true)
        guard !LogFile.exists(paths.materializedDirectory),
              LogFile.exists(previousRoot) else { return false }
        guard (try? LogFile.rename(previousRoot, to: paths.materializedDirectory)) != nil else {
            return false
        }
        try? LogFile.fsyncDirectory(paths.root)
        return true
    }

    /// Sweeps the crash leftovers of the materialized-copy exchange at the
    /// start of recovery: `materialized.verify` (a rebuild scratch tree) and
    /// `.materialized.previous` (the old tree a swap renamed away).
    ///
    /// The order is load-bearing. When `materialized/` is absent but
    /// `.materialized.previous` exists, the crash happened between the two
    /// renames; the previous tree is renamed back **before** anything can
    /// create an empty `materialized/`, and it is never unlinked. Only once a
    /// materialized copy exists is the previous tree redundant and removed.
    static func sweepStartupLeftovers(paths: WorkspacePaths) throws {
        guard LogFile.exists(paths.root) else { return }
        let previousRoot = paths.root.appendingPathComponent(previousName, isDirectory: true)
        let scratch = paths.root.appendingPathComponent(scratchName, isDirectory: true)
        var changed = false
        if !LogFile.exists(paths.materializedDirectory), LogFile.exists(previousRoot) {
            try LogFile.rename(previousRoot, to: paths.materializedDirectory)
            changed = true
        }
        if LogFile.exists(paths.materializedDirectory), LogFile.exists(previousRoot) {
            try LogFile.removeTree(previousRoot)
            changed = true
        }
        if LogFile.exists(scratch) {
            try LogFile.removeTree(scratch)
            changed = true
        }
        if changed {
            try LogFile.fsyncDirectory(paths.root)
        }
    }

    // MARK: - Verification plan

    /// One path whose expected state is fully determined by the retained WAL.
    private struct PathPlan {
        var path: String
        /// Records from the last base operation (complete write, remove or
        /// mkdir) at or below the watermark, in mseq order.
        var records: [WALRecord]
        /// True when a `remove` of an ancestor directory, later than the
        /// path's last base, made the path absent and nothing recreated it:
        /// `records` is then empty and the expected state is `.absent`.
        var absentBase = false
    }

    /// A base operation replaces the path's state without depending on history
    /// that may have been legally truncated: a complete write, a remove (the
    /// tombstone is idempotent) or a mkdir. An appended write has no base of
    /// its own; a chmod changes a state it does not define.
    private static func isBase(_ body: VfsMutationBody) -> Bool {
        switch body.op {
        case .write: return !body.mflags.contains(.appended)
        case .remove, .mkdir: return true
        case .chmod: return false
        }
    }

    /// The WAL-only rebuild is legal only when the retained mutations are
    /// exactly `1...max` (wal.md §7.2). A first record at mseq 1 is not enough:
    /// a manifest can name the first segment while middle segments were already
    /// truncated, and rebuilding from such a gap would drop their files.
    private static func hasFullHistory(_ mutations: [WALRecord]) -> Bool {
        guard let first = mutations.first else { return true }
        guard first.mseq == 1 else { return false }
        var expected: UInt64 = 1
        for record in mutations {
            guard record.mseq == expected else { return false }
            expected += 1
        }
        return true
    }

    private static func verificationPlans(mutations: [WALRecord],
                                          materializedUptoMseq: UInt64) throws -> [PathPlan] {
        let relevant = mutations.filter { $0.mseq <= materializedUptoMseq }
        var byPath: [String: [(index: Int, record: WALRecord)]] = [:]
        for (index, record) in relevant.enumerated() {
            guard let body = try? record.mutationBody() else { continue }
            byPath[body.path, default: []].append((index, record))
        }
        // A path with a record above the watermark is still being applied
        // (another path may hold the contiguous watermark); comparing it
        // against the prefix would be unsound.
        var unsettled = Set<String>()
        for record in mutations where record.mseq > materializedUptoMseq {
            guard let body = try? record.mutationBody() else { continue }
            unsettled.insert(body.path)
        }
        // A `remove` takes the whole subtree of a directory with it: the
        // materializer removes recursively, and a rename or rmdir of a scratch
        // directory (DSH's atomic write: `.name.N.<uuid>.tmpdir/name.tmp`,
        // then the directory is removed) leaves no per-child tombstone in the
        // WAL. A path whose ancestor was removed after the path's last base is
        // therefore absent from that mseq on, unless later records recreate it.
        var latestRemovalMseqByPath: [String: UInt64] = [:]
        for record in relevant {
            guard let body = try? record.mutationBody(), body.op == .remove else { continue }
            latestRemovalMseqByPath[body.path] = record.mseq
        }
        var plans: [PathPlan] = []
        for (path, entries) in byPath where !unsettled.contains(path) {
            guard let baseIndex = entries.lastIndex(where: { entry in
                (try? entry.record.mutationBody()).map(isBase) ?? false
            }) else { continue }
            var records = entries[baseIndex...].map(\.record)
            var absentBase = false
            let baseMseq = records[0].mseq
            let ancestorRemoval = latestAncestorRemovalMseq(
                of: path, removalsByPath: latestRemovalMseqByPath)
                .flatMap { $0 > baseMseq ? $0 : nil }
            if let cut = ancestorRemoval {
                let after = records.filter { $0.mseq > cut }
                if after.isEmpty {
                    records = []
                    absentBase = true
                } else if let newBase = after.lastIndex(where: { record in
                    (try? record.mutationBody()).map(isBase) ?? false
                }) {
                    records = Array(after[newBase...])
                } else {
                    // Only appends or chmods survived the ancestor removal:
                    // the retained records do not determine the state.
                    continue
                }
            }
            plans.append(PathPlan(path: path, records: records, absentBase: absentBase))
        }
        return plans.sorted { $0.path < $1.path }
    }

    /// Finds the newest remove on a strict path ancestor. Looking up only
    /// component prefixes keeps planning proportional to the number of WAL
    /// removals plus the total path depth, rather than paths × removals.
    private static func latestAncestorRemovalMseq(
        of path: String,
        removalsByPath: [String: UInt64]
    ) -> UInt64? {
        var latest: UInt64?
        for separator in path.indices where path[separator] == "/" {
            guard separator != path.startIndex else { continue }
            let ancestor = String(path[..<separator])
            if let mseq = removalsByPath[ancestor], mseq > (latest ?? 0) {
                latest = mseq
            }
        }
        return latest
    }

    // MARK: - Expected state

    private enum ExpectedState {
        case file(Data, mode: UInt32)
        case directory(mode: UInt32)
        case absent
    }

    /// Replays one path's records from its last base using the D9 rule. `nil`
    /// means the retained records do not determine the state (an append whose
    /// base is missing or whose bytes do not line up), so the path is skipped
    /// rather than reported as a false divergence.
    private static func expectedState(_ plan: PathPlan) -> ExpectedState? {
        if plan.records.isEmpty { return plan.absentBase ? .absent : nil }
        var state: ExpectedState?
        for record in plan.records {
            guard let body = try? record.mutationBody() else { return nil }
            switch body.op {
            case .write:
                if body.mflags.contains(.appended) {
                    guard case .file(var data, _) = state else { return nil }
                    let appendFrom = Int(body.appendFrom)
                    guard appendFrom >= 0, appendFrom <= data.count else { return nil }
                    let payload = body.data
                    if data.count == appendFrom {
                        data.append(payload)
                    } else if data.count >= appendFrom + payload.count {
                        let start = data.index(data.startIndex, offsetBy: appendFrom)
                        let end = data.index(start, offsetBy: payload.count)
                        guard Data(data[start..<end]) == payload else { return nil }
                        // D9: already applied, skip.
                    } else if data.count > appendFrom {
                        let start = data.index(data.startIndex, offsetBy: appendFrom)
                        let prefix = Data(data[start...])
                        guard payload.starts(with: prefix) else { return nil }
                        data.append(payload.suffix(from: prefix.count))
                    }
                    state = .file(data, mode: body.mode)
                } else {
                    state = .file(body.data, mode: body.mode)
                }
            case .mkdir:
                state = .directory(mode: body.mode)
            case .remove:
                state = .absent
            case .chmod:
                switch state {
                case .file(let data, _):
                    state = .file(data, mode: body.mode)
                case .directory:
                    state = .directory(mode: body.mode)
                case .absent, .none:
                    return nil
                }
            }
        }
        return state
    }

    // MARK: - Compare

    private static func compare(path: String,
                                expected: ExpectedState,
                                materializedDirectory: URL) throws
        -> [MaterializedInvariantViolation] {
        guard let url = try? vfsURL(for: path,
                                    materializedDirectory: materializedDirectory) else {
            return []
        }
        let actualKind = try kind(of: url)
        switch expected {
        case .file(let data, let mode):
            guard actualKind == .file else {
                return [MaterializedInvariantViolation(
                    path: path,
                    kind: actualKind == .directory ? .unexpectedDirectory : .missingFile,
                    expectedSize: data.count)]
            }
            let actualSize = try LogFile.size(url)
            guard actualSize == data.count else {
                return [MaterializedInvariantViolation(
                    path: path, kind: .contentMismatch,
                    expectedSize: data.count, actualSize: actualSize)]
            }
            let actual = try LogFile.readAll(url)
            if actual != data {
                return [MaterializedInvariantViolation(
                    path: path, kind: .contentMismatch,
                    expectedSize: data.count, actualSize: actualSize)]
            }
            let actualMode = try LogFile.fileMode(url)
            if actualMode != mode_t(mode) {
                return [MaterializedInvariantViolation(
                    path: path, kind: .modeMismatch,
                    expectedSize: data.count, actualSize: actualSize)]
            }
            return []
        case .directory:
            guard actualKind == .directory else {
                return [MaterializedInvariantViolation(
                    path: path,
                    kind: actualKind == .file ? .unexpectedFile : .missingDirectory)]
            }
            return []
        case .absent:
            switch actualKind {
            case .file:
                return [MaterializedInvariantViolation(
                    path: path, kind: .unexpectedFile,
                    actualSize: try? LogFile.size(url))]
            case .directory:
                return [MaterializedInvariantViolation(
                    path: path, kind: .unexpectedDirectory)]
            case .absent:
                return []
            }
        }
    }

    private enum EntryKind { case file, directory, absent }

    private static func kind(of url: URL) throws -> EntryKind {
        guard LogFile.exists(url) else { return .absent }
        if try LogFile.isRegularFile(url) { return .file }
        if try LogFile.isDirectory(url) { return .directory }
        return .absent
    }

    /// Maps an absolute VFS path to the materialized tree. The caller has
    /// already validated the path grammar when the mutation was accepted, so a
    /// resolution failure here is a host defect.
    private static func vfsURL(for path: String,
                               materializedDirectory root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 3, components[0].isEmpty, components[1] == "dsh",
              components[2] == "home" || components[2] == "workspace" else {
            throw LogError.materializationFailed("the WAL names a non-materialized path")
        }
        var url = root.appendingPathComponent(String(components[2]), isDirectory: true)
        for component in components.dropFirst(3) {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw LogError.materializationFailed("invalid VFS path component")
            }
            url.appendPathComponent(String(component))
        }
        return url
    }
}
