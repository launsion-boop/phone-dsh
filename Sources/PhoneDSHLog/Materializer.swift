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
}

/// Summary of one materialization batch.
public struct MaterializeBatchReport: Equatable, Sendable {
    public var applied: Int
    public var skipped: Int
    public var ignored: Int
    public var baseMismatchPaths: [String]
    public var deferredRecords: Int
    public var materializedUptoMseq: UInt64

    public init(applied: Int = 0,
                skipped: Int = 0,
                ignored: Int = 0,
                baseMismatchPaths: [String] = [],
                deferredRecords: Int = 0,
                materializedUptoMseq: UInt64 = 0) {
        self.applied = applied
        self.skipped = skipped
        self.ignored = ignored
        self.baseMismatchPaths = baseMismatchPaths
        self.deferredRecords = deferredRecords
        self.materializedUptoMseq = materializedUptoMseq
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
    private var deferred: [UInt64: WALRecord] = [:]
    private var deferredByPath: [String: [UInt64]] = [:]
    private var dirtyFiles: Set<String> = []
    private var dirtyDirectories: Set<String> = []
    private var temporaryCounter: UInt64 = 0

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

    /// Applies one record. Mutations with `mseq <= materialized_upto_mseq` are
    /// replayed idempotently and do not move the watermark again.
    public func apply(_ record: WALRecord) throws -> MaterializeOutcome {
        if record.isEpochClose {
            _ = try record.epochClose()
            return .skipped
        }
        noteAppliedThrough(record.mseq)
        let body = try record.mutationBody()
        guard let target = try resolve(body.path) else {
            markApplied(record.mseq)
            return .ignored
        }
        let path = body.path

        // While a path is deferred everything for it is held back in mseq order,
        // except the complete write that repairs the base (D8).
        if let pending = deferredByPath[path], !pending.isEmpty,
           !(body.op == .write && !body.mflags.contains(.appended)) {
            try deferRecord(record, path: path)
            return .baseMismatch(path)
        }

        switch body.op {
        case .write:
            if body.mflags.contains(.appended) {
                switch try append(body, to: target) {
                case .applied:
                    markApplied(record.mseq)
                    return .applied
                case .skipped:
                    markApplied(record.mseq)
                    return .skipped
                case .baseMismatch:
                    try deferRecord(record, path: path)
                    return .baseMismatch(path)
                }
            } else {
                try fullWrite(body, to: target)
                markApplied(record.mseq)
                // D8: the complete write is the new base; settle the path's
                // pending appended records in mseq order.
                _ = try settleDeferred(path: path)
                return .applied
            }
        case .mkdir:
            try makeDirectory(body, at: target)
            markApplied(record.mseq)
            return .applied
        case .remove:
            try remove(body, at: target)
            markApplied(record.mseq)
            return .applied
        case .chmod:
            try changeMode(body, at: target)
            markApplied(record.mseq)
            return .applied
        }
    }

    /// Applies records in their given mseq order and reports the new watermark.
    public func apply(records: [WALRecord]) throws -> MaterializeBatchReport {
        var report = MaterializeBatchReport()
        var mismatchPaths: [String] = []
        for record in records {
            let outcome = try apply(record)
            switch outcome {
            case .applied:
                report.applied += 1
            case .skipped:
                report.skipped += 1
            case .ignored:
                report.ignored += 1
            case .baseMismatch(let path):
                if !mismatchPaths.contains(path) {
                    mismatchPaths.append(path)
                }
            }
        }
        report.baseMismatchPaths = mismatchPaths
        report.deferredRecords = deferred.count
        report.materializedUptoMseq = materializedUptoMseq
        return report
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

    private func fullWrite(_ body: VfsMutationBody, to target: URL) throws {
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
        let descriptor = try LogFile.open(temporary,
                                          flags: O_WRONLY | O_CREAT | O_TRUNC,
                                          mode: 0o600)
        do {
            try LogFile.writeAll(fd: descriptor, data: body.data)
            guard fchmod(descriptor, mode_t(body.mode)) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                try? LogFile.unlink(temporary)
                throw LogError.posix(operation: "fchmod", code: code)
            }
        } catch {
            Darwin.close(descriptor)
            try? LogFile.unlink(temporary)
            throw error
        }
        Darwin.close(descriptor)
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

    /// Re-applies the deferred records of one path after its repair write.
    /// Returns `true` when every deferred record settled.
    @discardableResult
    private func settleDeferred(path: String) throws -> Bool {
        guard let mseqs = deferredByPath[path], !mseqs.isEmpty else {
            needsResyncPaths.remove(path)
            return true
        }
        var remaining: [UInt64] = []
        var settled = true
        for (index, mseq) in mseqs.enumerated() {
            guard let record = deferred[mseq] else { continue }
            let repaired = try applyDeferred(record)
            if repaired {
                deferred.removeValue(forKey: mseq)
                markApplied(mseq)
            } else {
                remaining = Array(mseqs[index...])
                settled = false
                break
            }
        }
        if settled {
            deferredByPath.removeValue(forKey: path)
            needsResyncPaths.remove(path)
        } else {
            deferredByPath[path] = remaining
            needsResyncPaths.insert(path)
        }
        return settled
    }

    /// Applies one deferred record; `false` means it still has a base mismatch.
    private func applyDeferred(_ record: WALRecord) throws -> Bool {
        if record.isEpochClose { return true }
        let body = try record.mutationBody()
        guard let target = try resolve(body.path) else { return true }
        switch body.op {
        case .write:
            if body.mflags.contains(.appended) {
                switch try append(body, to: target) {
                case .applied, .skipped:
                    return true
                case .baseMismatch:
                    return false
                }
            }
            try fullWrite(body, to: target)
            return true
        case .mkdir:
            try makeDirectory(body, at: target)
            return true
        case .remove:
            try remove(body, at: target)
            return true
        case .chmod:
            try changeMode(body, at: target)
            return true
        }
    }

    // MARK: - Helpers

    /// Records that a mutation mseq was taken in, independent of whether the
    /// contiguous watermark can advance over it.
    private func noteAppliedThrough(_ mseq: UInt64) {
        if mseq > appliedThroughMseq { appliedThroughMseq = mseq }
    }

    private func markApplied(_ mseq: UInt64) {
        guard mseq > materializedUptoMseq else { return }
        appliedMseqs.insert(mseq)
        while appliedMseqs.remove(materializedUptoMseq + 1) != nil {
            materializedUptoMseq += 1
        }
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
