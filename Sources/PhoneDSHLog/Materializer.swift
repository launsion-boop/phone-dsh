// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the materialized copy.
//
// PLAN §2.3 (D8/D9/D18) and spec/v1/wal.md §6. The materialized copy
// is derived only from WAL records: complete writes use temp file + rename,
// mkdir creates directories with a mode, remove deletes a file or a whole
// subtree (the tombstone replays idempotently), chmod changes the mode, and an
// appended write uses the D9 rule (append when size == append_from, skip when
// the bytes are already there, otherwise defer the path for a VFS_RESYNC
// repair). `materialized_upto_mseq` never advances across a deferred record.

import Darwin
import Foundation
import PhoneDSHWire

/// Outcome of applying one WAL record to the materialized copy.
public enum MaterializeOutcome: Equatable, Sendable {
    /// The mutation was applied (or was already applied for a tombstone).
    case applied
    /// The D9 replay case: the appended bytes are already present. An
    /// epoch-close record also reports `skipped` and never moves the watermark.
    case skipped
    /// A path outside `home/` and `workspace/`; counted but not materialized.
    case ignored
    /// Appended base mismatch: the path is deferred until the worker sends a
    /// complete write (D8/D9).
    case baseMismatch(String)
    /// The fourth D9 verdict (wal.md §6.2): a later retained complete write or
    /// remove covers this appended record. It is not applied; the cover
    /// establishes the final state. The record blocks the contiguous watermark
    /// until the cover's mseq also reaches it.
    case settledSuperseded(supersededByMseq: UInt64)
}

/// Kind of the later retained record that covers a settled appended record
/// (wal.md §6.2, `spec/v1/golden/wal/replay/README.md` §2).
public enum SupersededCover: String, Equatable, Sendable {
    case completeWrite = "complete-write"
    case truncate
    case remove
    case ancestorRemove = "ancestor-remove"
    case repairWrite = "repair-write"
}

/// One path and the first retained mseq that is held by a base mismatch. The
/// host names both in the wal.md §5.2 failure detail.
public struct MaterializationHold: Equatable, Sendable {
    public var path: String
    public var mseq: UInt64

    public init(path: String, mseq: UInt64) {
        self.path = path
        self.mseq = mseq
    }
}

/// Per-record decision exposed for the replay fixture runner (wal.md §6.2 and
/// `spec/v1/golden/wal/replay/README.md`). Production does not consume it.
public enum MaterializeVerdict: Equatable, Sendable {
    case applied
    case skippedIdempotent
    case settledSuperseded(supersededByMseq: UInt64, cover: SupersededCover)
    case mismatchHeld
    case alreadyMaterialized
}

/// One decided retained record with the watermark observed after the decision.
public struct MaterializeDecision: Equatable, Sendable {
    public var mseq: UInt64
    public var verdict: MaterializeVerdict
    /// `materialized_upto_mseq` after this record's decision. A settled record
    /// keeps it below the record until its cover is also inside the prefix.
    public var materializedUptoMseq: UInt64

    public init(mseq: UInt64, verdict: MaterializeVerdict,
                materializedUptoMseq: UInt64) {
        self.mseq = mseq
        self.verdict = verdict
        self.materializedUptoMseq = materializedUptoMseq
    }
}

/// Summary of one materialization batch.
public struct MaterializeBatchReport: Equatable, Sendable {
    public var applied: Int
    public var skipped: Int
    public var ignored: Int
    public var settled: Int
    public var baseMismatchPaths: [String]
    public var deferredRecords: Int
    public var materializedUptoMseq: UInt64
    /// Paths and first held mseq after the batch (the wal.md §5.2 detail).
    public var baseMismatchRecords: [MaterializationHold]

    public init(applied: Int = 0,
                skipped: Int = 0,
                ignored: Int = 0,
                settled: Int = 0,
                baseMismatchPaths: [String] = [],
                deferredRecords: Int = 0,
                materializedUptoMseq: UInt64 = 0,
                baseMismatchRecords: [MaterializationHold] = []) {
        self.applied = applied
        self.skipped = skipped
        self.ignored = ignored
        self.settled = settled
        self.baseMismatchPaths = baseMismatchPaths
        self.deferredRecords = deferredRecords
        self.materializedUptoMseq = materializedUptoMseq
        self.baseMismatchRecords = baseMismatchRecords
    }
}

/// Applies verified WAL records to `materialized/{home,workspace}` (wal.md §6).
public final class Materializer {
    public let paths: WorkspacePaths
    /// Directory that contains `home/` and `workspace/`. Recovery points this at
    /// `materialized.staging/` while rebuilding.
    public let materializedDirectory: URL
    public let homeDirectory: URL
    public let workspaceDirectory: URL

    /// Strictly contiguous watermark (wal.md §7).
    public private(set) var materializedUptoMseq: UInt64
    /// Highest mutation mseq this instance ever took in through ``apply(_:)``
    /// or ``apply(records:)``. It advances even while the contiguous watermark
    /// is held back by a deferred base mismatch, so the workspace log can hand
    /// the record it just appended directly to the materializer instead of
    /// re-reading and re-verifying the whole WAL from disk (G2-FIX-83).
    public private(set) var appliedThroughMseq: UInt64
    /// Paths whose appended base did not match and that await a repair.
    public private(set) var needsResyncPaths: Set<String> = []

    /// Internal test seam: invoked once after the D18 step-1 fsync pass made
    /// every changed file and directory durable, before the caller rewrites the
    /// manifest. Production leaves this nil.
    var onFsyncCompleted: (@Sendable () -> Void)?

    private var appliedMseqs: Set<UInt64> = []
    /// Settled-superseded records: mseq → the covering record's mseq. They are
    /// decided but not applied, so they stop the contiguous watermark until the
    /// cover is applied too (wal.md §6.2, §7.1).
    private var settledMseqs: [UInt64: UInt64] = [:]
    private var deferred: [UInt64: WALRecord] = [:]
    private var deferredByPath: [String: [UInt64]] = [:]
    private var dirtyFiles: Set<String> = []
    private var dirtyDirectories: Set<String> = []
    private var temporaryCounter: UInt64 = 0
    /// Blobs this instance already verified in this boot. Blobs are immutable,
    /// so a repeated reference (an appended chunk chain) needs no second hash.
    private var verifiedBlobURLs: [String: URL] = [:]
    /// Test seam used by the replay fixture runner and the host/drain failure
    /// detail. Production leaves it `nil`.
    internal var decisionObserver: (@Sendable (MaterializeDecision) -> Void)?

    /// Initializes a materializer whose contiguous watermark is also the
    /// highest record it has taken in.
    ///
    /// This is the original three-parameter signature and stays an explicit
    /// designated initializer: a test binary compiled against that signature
    /// keeps resolving this exact symbol even when an incremental build reuses
    /// its object file after ``appliedThroughMseq`` was introduced. Changing
    /// the signature in place instead of adding this overload made the
    /// `swift build --build-tests` link step fail with an undefined
    /// `__allocating_init(root:materializedUptoMseq:materializedDirectoryURL:)`
    /// for `PhoneDSHScenarioTests/ScenarioRecoveryTests.swift` (G2-FIX-83).
    public init(root: URL,
                materializedUptoMseq: UInt64 = 0,
                materializedDirectoryURL: URL? = nil) throws {
        self.paths = WorkspacePaths(root: root)
        self.materializedDirectory = materializedDirectoryURL ?? self.paths.materializedDirectory
        self.homeDirectory = self.materializedDirectory
            .appendingPathComponent("home", isDirectory: true)
        self.workspaceDirectory = self.materializedDirectory
            .appendingPathComponent("workspace", isDirectory: true)
        self.materializedUptoMseq = materializedUptoMseq
        self.appliedThroughMseq = materializedUptoMseq
        try LogFile.ensureDirectory(self.materializedDirectory)
        try LogFile.ensureDirectory(self.homeDirectory)
        try LogFile.ensureDirectory(self.workspaceDirectory)
    }

    /// Initializes a materializer that already replayed WAL records above the
    /// contiguous watermark.
    ///
    /// A recovery replay may take in records above the contiguous watermark (a
    /// deferred base mismatch holds the watermark but not the record set). The
    /// resumed facade starts from the WAL tail the recovery verified, so its
    /// next append can be applied in place. `appliedThroughMseq` is not
    /// defaulted so the three-argument calls above can never bind here.
    public convenience init(root: URL,
                            materializedUptoMseq: UInt64 = 0,
                            materializedDirectoryURL: URL? = nil,
                            appliedThroughMseq: UInt64?) throws {
        try self.init(root: root,
                      materializedUptoMseq: materializedUptoMseq,
                      materializedDirectoryURL: materializedDirectoryURL)
        self.appliedThroughMseq = max(self.materializedUptoMseq,
                                      appliedThroughMseq ?? self.materializedUptoMseq)
    }

    /// Number of accepted records currently held back by base mismatches.
    public var deferredRecordCount: Int { deferred.count }

    /// Paths and the first held mseq in stable order. This is the observable
    /// form of a pending VFS_RESYNC (wal.md §5.1, §5.2).
    public var heldMismatches: [MaterializationHold] {
        deferredByPath.compactMap { path, mseqs in
            guard let first = mseqs.first else { return nil }
            return MaterializationHold(path: path, mseq: first)
        }.sorted { $0.path < $1.path }
    }

    /// Rewrites the contiguous watermark after a record was decided. A settled
    /// record may pass only once its covering record is itself applied and the
    /// whole block between the two is decided with every nested cover inside
    /// the same prefix (wal.md §6.2, §7.1).
    private func advanceWatermark() {
        while true {
            let next = materializedUptoMseq + 1
            if appliedMseqs.contains(next) {
                materializedUptoMseq = next
                continue
            }
            guard let cover = settledMseqs[next] else { return }
            guard closeableBlock(from: next, through: cover) else { return }
            materializedUptoMseq = cover
        }
    }

    /// True when every mseq in `from...through` is decided and every settled
    /// record inside has its own cover at or below `through`, so setting the
    /// watermark to `through` names no unapplied position.
    private func closeableBlock(from: UInt64, through: UInt64) -> Bool {
        var current = from
        while current <= through {
            if appliedMseqs.contains(current) {
                current += 1
                continue
            }
            guard let nestedCover = settledMseqs[current], nestedCover <= through else {
                return false
            }
            current += 1
        }
        return true
    }

    /// Applies one record. Mutations with `mseq <= materialized_upto_mseq` are
    /// replayed idempotently and do not move the watermark again.
    public func apply(_ record: WALRecord) throws -> MaterializeOutcome {
        try apply(record, coveredBy: nil)
    }

    /// Applies one record, optionally knowing from a retained-sequence
    /// lookahead that a later record already covers it. The supersession check
    /// runs before the base check (wal.md §6.2).
    private func apply(_ record: WALRecord,
                       coveredBy cover: SupersessionCover?) throws -> MaterializeOutcome {
        if record.isEpochClose {
            _ = try record.epochClose()
            return .skipped
        }
        noteAppliedThrough(record.mseq)
        // wal.md §14.4: a blob-backed write materializes exactly like its
        // inline form, with the verified blob bytes as `data`. A complete write
        // may clone the blob (COW); hard links are forbidden.
        var cloneSource: URL?
        let body: VfsMutationBody
        if record.isBlobWrite {
            guard let blob = try record.blobWrite() else {
                throw LogError.corrupt("blob-write record did not decode")
            }
            let url: URL
            if let cached = verifiedBlobURLs[blob.sha256Hex] {
                url = cached
            } else {
                url = try WorkspaceBlobStore(root: paths.root)
                    .verifiedURL(digest: blob.sha256Hex,
                                 expectedLength: Int(blob.blobLength))
                verifiedBlobURLs[blob.sha256Hex] = url
            }
            let data = try LogFile.readAll(url)
            body = VfsMutationBody(op: .write,
                                   mode: blob.mode,
                                   mflags: blob.mflags,
                                   appendFrom: blob.appendFrom,
                                   path: blob.path,
                                   data: data)
            if !blob.mflags.contains(.appended) {
                cloneSource = url
            }
        } else {
            body = try record.mutationBody()
        }
        guard let target = try resolve(body.path) else {
            markApplied(record.mseq)
            reportDecision(record.mseq, .applied)
            return .ignored
        }
        let path = body.path

        // wal.md §6.2: the fourth verdict is decided before the D9 base check.
        // The record is not applied and no resync is requested; the later cover
        // establishes the final state and the watermark waits for it. A record
        // already at or below the watermark is a plain idempotent replay, not a
        // new settlement.
        if let cover, record.mseq > materializedUptoMseq {
            settleSuperseded(record.mseq, cover: cover)
            return .settledSuperseded(supersededByMseq: cover.mseq)
        }

        // A complete write or a remove (of the path or an ancestor) that
        // arrives after a mismatch settles every held append it covers. This
        // is the live form of §6.2 (the retained-sequence form is above).
        if body.op == .write, !body.mflags.contains(.appended) {
            settleDeferredCovered(byCompleteWriteAt: record.mseq, path: path)
        } else if body.op == .remove {
            settleDeferredRemoved(byRemoveAt: record.mseq, path: path)
        }

        // While a path is deferred, only its own appended records are held
        // back; the complete write/remove paths above already settled them.
        // Other ops (chmod, mkdir) stay independent of the file's bytes.
        if body.op == .write, body.mflags.contains(.appended),
           let pending = deferredByPath[path], !pending.isEmpty {
            try deferRecord(record, path: path)
            reportDecision(record.mseq, .mismatchHeld)
            return .baseMismatch(path)
        }

        switch body.op {
        case .write:
            if body.mflags.contains(.appended) {
                switch try append(body, to: target) {
                case .applied:
                    markApplied(record.mseq)
                    reportDecision(record.mseq, .applied)
                    return .applied
                case .skipped:
                    markApplied(record.mseq)
                    reportDecision(record.mseq, .skippedIdempotent)
                    return .skipped
                case .baseMismatch:
                    try deferRecord(record, path: path)
                    reportDecision(record.mseq, .mismatchHeld)
                    return .baseMismatch(path)
                }
            } else {
                try fullWrite(body, to: target, cloneSource: cloneSource)
                markApplied(record.mseq)
                reportDecision(record.mseq, .applied)
                return .applied
            }
        case .mkdir:
            try makeDirectory(body, at: target)
            markApplied(record.mseq)
            reportDecision(record.mseq, .applied)
            return .applied
        case .remove:
            try remove(body, at: target)
            markApplied(record.mseq)
            reportDecision(record.mseq, .applied)
            return .applied
        case .chmod:
            try changeMode(body, at: target)
            markApplied(record.mseq)
            reportDecision(record.mseq, .applied)
            return .applied
        }
    }

    /// Applies records in their given mseq order and reports the new watermark.
    ///
    /// The whole retained sequence is scanned first so the fourth verdict can
    /// see a later cover; a single-record ``apply(_:)`` keeps the live
    /// semantics (a mismatch defers the path until a covering record arrives).
    public func apply(records: [WALRecord]) throws -> MaterializeBatchReport {
        var report = MaterializeBatchReport()
        let covers = Self.supersessionCovers(for: records)
        for record in records {
            let outcome = try apply(record, coveredBy: covers[record.mseq])
            switch outcome {
            case .applied:
                report.applied += 1
            case .skipped:
                report.skipped += 1
            case .ignored:
                report.ignored += 1
            case .settledSuperseded:
                report.settled += 1
            case .baseMismatch:
                break
            }
        }
        let holds = heldMismatches
        report.baseMismatchRecords = holds
        report.baseMismatchPaths = holds.map(\.path)
        report.deferredRecords = deferred.count
        report.materializedUptoMseq = materializedUptoMseq
        return report
    }

    // MARK: - Retained-sequence supersession (wal.md §6.2)

    private struct SupersessionCover: Equatable {
        var mseq: UInt64
        var kind: SupersededCover
    }

    /// The earliest later retained complete write/remove covering each appended
    /// record. A complete write or remove covers every earlier record of the
    /// path, so the earliest such record is the cover; an appended record after
    /// the cover is outside it and is handled by its own entry.
    private static func supersessionCovers(
        for records: [WALRecord]
    ) -> [UInt64: SupersessionCover] {
        var bodies: [(mseq: UInt64, body: VfsMutationBody)] = []
        bodies.reserveCapacity(records.count)
        for record in records where !record.isEpochClose {
            guard let body = try? record.mutationBody() else { continue }
            bodies.append((record.mseq, body))
        }
        var covers: [UInt64: SupersessionCover] = [:]
        for (index, entry) in bodies.enumerated() where entry.body.op == .write
            && entry.body.mflags.contains(.appended) {
            var found: SupersessionCover?
            for later in bodies[(index + 1)...] where later.mseq > entry.mseq {
                let kind: SupersededCover
                switch later.body.op {
                case .write where !later.body.mflags.contains(.appended):
                    guard later.body.path == entry.body.path else { continue }
                    kind = .completeWrite
                case .remove:
                    if later.body.path == entry.body.path {
                        kind = .remove
                    } else if Self.isAncestor(later.body.path, of: entry.body.path) {
                        kind = .ancestorRemove
                    } else {
                        continue
                    }
                default:
                    continue
                }
                found = SupersessionCover(mseq: later.mseq, kind: kind)
                break
            }
            if let found {
                covers[entry.mseq] = found
            }
        }
        return covers
    }

    private static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        guard ancestor != path else { return false }
        return path.hasPrefix(ancestor + "/")
    }

    private func settleSuperseded(_ mseq: UInt64, cover: SupersessionCover) {
        guard mseq > materializedUptoMseq else { return }
        settledMseqs[mseq] = cover.mseq
        if deferred.removeValue(forKey: mseq) != nil {
            for (path, mseqs) in Array(deferredByPath) {
                let remaining = mseqs.filter { $0 != mseq }
                if remaining.isEmpty {
                    deferredByPath.removeValue(forKey: path)
                    needsResyncPaths.remove(path)
                } else if remaining != mseqs {
                    deferredByPath[path] = remaining
                }
            }
        }
        advanceWatermark()
        reportDecision(mseq, .settledSuperseded(supersededByMseq: cover.mseq,
                                                cover: cover.kind))
    }

    /// Settles every deferred append of one path when a later complete write of
    /// that path arrives. The complete write contains the authoritative bytes,
    /// so the held appends are covered, not re-applied (wal.md §6.2).
    private func settleDeferredCovered(byCompleteWriteAt mseq: UInt64, path: String) {
        settleDeferred(paths: [path]) { _ in SupersessionCover(mseq: mseq,
                                                               kind: .repairWrite) }
    }

    /// Settles deferred appends of the removed path and of its whole subtree
    /// when a later remove arrives (wal.md §6.2).
    private func settleDeferredRemoved(byRemoveAt mseq: UInt64, path: String) {
        let covered = deferredByPath.keys.filter {
            $0 == path || Self.isAncestor(path, of: $0)
        }
        settleDeferred(paths: covered) { candidate in
            SupersessionCover(mseq: mseq,
                              kind: candidate == path ? .remove : .ancestorRemove)
        }
    }

    private func settleDeferred(
        paths: [String],
        cover: (String) -> SupersessionCover
    ) {
        var decided: [(mseq: UInt64, cover: SupersessionCover)] = []
        for path in paths.sorted() {
            guard let mseqs = deferredByPath[path], !mseqs.isEmpty else { continue }
            let recordCover = cover(path)
            for mseq in mseqs {
                guard deferred.removeValue(forKey: mseq) != nil else { continue }
                guard mseq > materializedUptoMseq else { continue }
                settledMseqs[mseq] = recordCover.mseq
                decided.append((mseq, recordCover))
            }
            deferredByPath.removeValue(forKey: path)
            needsResyncPaths.remove(path)
        }
        advanceWatermark()
        // Report after the settlement so the watermark reflects the same step.
        for entry in decided.sorted(by: { $0.mseq < $1.mseq }) {
            reportDecision(entry.mseq,
                           .settledSuperseded(supersededByMseq: entry.cover.mseq,
                                              cover: entry.cover.kind))
        }
    }

    /// D18 step 1: fsync every materialized file and directory changed since the
    /// previous epoch close, deepest directory first.
    public func fsyncEpoch() throws {
        for path in dirtyFiles.sorted() {
            let url = URL(fileURLWithPath: path)
            guard LogFile.exists(url), try LogFile.isRegularFile(url) else { continue }
            let descriptor = try LogFile.open(url, flags: O_RDONLY)
            do {
                try LogFile.fsync(fd: descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            Darwin.close(descriptor)
        }
        for path in dirtyDirectories.sorted(by: { pathDepth($0) > pathDepth($1) }) {
            let url = URL(fileURLWithPath: path)
            guard LogFile.exists(url) else { continue }
            try LogFile.fsyncDirectory(url)
        }
        onFsyncCompleted?()
        dirtyFiles.removeAll()
        dirtyDirectories.removeAll()
    }

    // MARK: - Local invariant repair

    /// Rewrites one materialized file through the same temp-file + `fchmod` +
    /// rename path as a live complete write, then fsyncs the file and its
    /// directory. Used only by `MaterializedInvariant`'s scoped local repair;
    /// the caller has already durably recorded the preimage.
    func repairMaterializedFile(path: String, data: Data, mode: UInt32) throws {
        guard let target = try resolve(path) else {
            throw LogError.materializationFailed(
                "local recovery names a path outside the materialized roots")
        }
        let body = VfsMutationBody(op: .write, mode: mode, path: path, data: data)
        try fullWrite(body, to: target)
        try fsyncEpoch()
    }

    /// Restores only the POSIX mode of one materialized file. Used when the
    /// retained bytes already match and rewriting them would be unnecessary.
    func repairMaterializedMode(path: String, mode: UInt32) throws {
        guard let target = try resolve(path) else {
            throw LogError.materializationFailed(
                "local recovery names a path outside the materialized roots")
        }
        try changeMode(VfsMutationBody(op: .chmod, mode: mode, path: path),
                       at: target)
        try fsyncEpoch()
    }

    // MARK: - Path mapping

    private func resolve(_ path: String) throws -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 3, components[0].isEmpty, components[1] == "dsh" else {
            return nil
        }
        let base: URL
        switch components[2] {
        case "home":
            base = homeDirectory
        case "workspace":
            base = workspaceDirectory
        default:
            // `/dsh/tmp/**` and every other root are never materialized.
            return nil
        }
        var url = base
        for component in components.dropFirst(3) {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw LogError.materializationFailed("invalid VFS path component")
            }
            url.appendPathComponent(String(component))
        }
        return url
    }

    // MARK: - Operations

    private func fullWrite(_ body: VfsMutationBody, to target: URL,
                           cloneSource: URL? = nil) throws {
        let directory = target.deletingLastPathComponent()
        let created = try LogFile.createDirectoryTree(directory)
        for url in created {
            dirtyDirectories.insert(url.path)
        }
        dirtyDirectories.insert(directory.path)

        temporaryCounter &+= 1
        let temporary = directory.appendingPathComponent(
            ".pdsh-tmp-\(getpid())-\(temporaryCounter)")
        try LogFile.unlink(temporary)
        // W6 §14.4: a complete blob-backed write may be a clonefile of the
        // blob (one physical copy, independent inode). Hard links are
        // forbidden; a filesystem without cloning falls back to a byte copy.
        var cloned = false
        if let cloneSource {
            let result = cloneSource.path.withCString { source in
                temporary.path.withCString { destination in
                    clonefile(source, destination, 0)
                }
            }
            cloned = result == 0
        }
        if !cloned {
            let descriptor = try LogFile.open(temporary,
                                              flags: O_WRONLY | O_CREAT | O_TRUNC,
                                              mode: 0o600)
            do {
                try LogFile.writeAll(fd: descriptor, data: body.data)
            } catch {
                Darwin.close(descriptor)
                try? LogFile.unlink(temporary)
                throw error
            }
            Darwin.close(descriptor)
        }
        do {
            let descriptor = try LogFile.open(temporary, flags: O_WRONLY)
            guard fchmod(descriptor, mode_t(body.mode)) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                try? LogFile.unlink(temporary)
                throw LogError.posix(operation: "fchmod", code: code)
            }
            Darwin.close(descriptor)
        } catch {
            try? LogFile.unlink(temporary)
            throw error
        }
        do {
            try LogFile.rename(temporary, to: target)
        } catch {
            try? LogFile.unlink(temporary)
            throw LogError.materializationFailed("complete write could not be renamed into place")
        }
        dirtyFiles.insert(target.path)
    }

    private enum AppendResult {
        case applied
        case skipped
        case baseMismatch
    }

    private func append(_ body: VfsMutationBody, to target: URL) throws -> AppendResult {
        guard LogFile.exists(target), try LogFile.isRegularFile(target) else {
            return .baseMismatch
        }
        let currentSize = try LogFile.size(target)
        let appendFrom = body.appendFrom
        let dataLength = body.data.count
        guard appendFrom <= UInt64(Int.max), dataLength <= Int.max - Int(appendFrom) else {
            return .baseMismatch
        }
        let start = Int(appendFrom)

        if currentSize == start {
            try appendBytes(body.data, at: start, mode: body.mode, to: target)
            return .applied
        }

        if currentSize >= start + dataLength {
            let existing = try readRange(target, offset: start, length: dataLength)
            if existing == body.data {
                return .skipped
            }
        } else if currentSize > start {
            // A kill during an appended write can leave only a prefix of the
            // record on disk. The WAL record is authoritative and level-1
            // durable, so finish the missing suffix instead of declaring a
            // base mismatch; this is the large-file crash-replay case.
            let presentLength = currentSize - start
            let present = try readRange(target, offset: start, length: presentLength)
            if present == body.data.prefix(presentLength) {
                try appendBytes(body.data.suffix(from: presentLength),
                                at: currentSize,
                                mode: body.mode,
                                to: target)
                return .applied
            }
        }
        return .baseMismatch
    }

    /// Appends `data` at `offset` and applies the mutation mode. Used by the
    /// exact-base case and by the torn-suffix replay above.
    private func appendBytes(_ data: Data, at offset: Int, mode: UInt32,
                             to target: URL) throws {
        let descriptor = try LogFile.open(target, flags: O_WRONLY)
        do {
            guard lseek(descriptor, off_t(offset), SEEK_SET) == off_t(offset) else {
                let code = errno
                Darwin.close(descriptor)
                throw LogError.posix(operation: "lseek", code: code)
            }
            try LogFile.writeAll(fd: descriptor, data: data)
            guard fchmod(descriptor, mode_t(mode)) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw LogError.posix(operation: "fchmod", code: code)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        Darwin.close(descriptor)
        dirtyFiles.insert(target.path)
        dirtyDirectories.insert(target.deletingLastPathComponent().path)
    }

    private func makeDirectory(_ body: VfsMutationBody, at target: URL) throws {
        let created = try LogFile.createDirectoryTree(target)
        for url in created {
            dirtyDirectories.insert(url.path)
        }
        try LogFile.setMode(target, mode: mode_t(body.mode))
        dirtyDirectories.insert(target.path)
        dirtyDirectories.insert(target.deletingLastPathComponent().path)
    }

    private func remove(_ body: VfsMutationBody, at target: URL) throws {
        guard LogFile.exists(target) else { return }
        let parent = target.deletingLastPathComponent()
        let wasDirectory = try LogFile.isDirectory(target)
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw LogError.materializationFailed("remove of a materialized path failed")
        }
        if wasDirectory {
            dirtyDirectories.insert(target.path)
        }
        dirtyDirectories.insert(parent.path)
    }

    private func changeMode(_ body: VfsMutationBody, at target: URL) throws {
        guard LogFile.exists(target) else {
            throw LogError.materializationFailed("chmod target is missing from the materialized copy")
        }
        try LogFile.setMode(target, mode: mode_t(body.mode))
        dirtyFiles.insert(target.path)
        dirtyDirectories.insert(target.deletingLastPathComponent().path)
        if (try? LogFile.isDirectory(target)) == true {
            dirtyDirectories.insert(target.path)
        }
    }

    // MARK: - Deferred records (D8 resync)

    @discardableResult
    private func deferRecord(_ record: WALRecord, path: String) throws -> MaterializeOutcome {
        if deferred[record.mseq] == nil {
            deferred[record.mseq] = record
            deferredByPath[path, default: []].append(record.mseq)
            needsResyncPaths.insert(path)
        }
        return .baseMismatch(path)
    }

    // MARK: - Helpers

    /// Records that a mutation mseq was taken in, independent of whether the
    /// contiguous watermark can advance over it.
    private func noteAppliedThrough(_ mseq: UInt64) {
        if mseq > appliedThroughMseq { appliedThroughMseq = mseq }
    }

    private func markApplied(_ mseq: UInt64) {
        guard mseq > materializedUptoMseq else { return }
        settledMseqs.removeValue(forKey: mseq)
        appliedMseqs.insert(mseq)
        advanceWatermark()
    }

    private func reportDecision(_ mseq: UInt64, _ verdict: MaterializeVerdict) {
        decisionObserver?(MaterializeDecision(mseq: mseq,
                                              verdict: verdict,
                                              materializedUptoMseq: materializedUptoMseq))
    }

    private func readRange(_ url: URL, offset: Int, length: Int) throws -> Data {
        let descriptor = try LogFile.open(url, flags: O_RDONLY)
        defer { Darwin.close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: length)
        var read = 0
        while read < length {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.pread(descriptor,
                                    base.advanced(by: read),
                                    length - read,
                                    off_t(offset + read))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw LogError.posix(operation: "pread", code: errno)
            }
            if count == 0 { break }
            read += count
        }
        guard read == length else {
            throw LogError.materializationFailed("short read of a materialized file")
        }
        return Data(buffer)
    }

    private func pathDepth(_ path: String) -> Int {
        path.split(separator: "/", omittingEmptySubsequences: true).count
    }
}
