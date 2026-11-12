// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the module facade.
//
// PLAN §2.3 (D7/D8/D9/D11/D17/D18/D19) and spec/v1/wal.md. The
// `WorkspaceLog` actor is what the loopback channel and the task controller
// call: append -> level-1 ack, epoch close -> level-2 ack, materialization,
// boot overlay, recovery report, journal and the per-prefix metrics of the
// memory proxy. Cold recovery runs on open so the actor is usable immediately.

import Foundation
import PhoneDSHStandardError
import PhoneDSHWire

/// HELLO positions the host needs after recovery (channel.md §4.1, D17).
public struct WorkspaceLogPositions: Equatable, Sendable {
    public var nextMseq: UInt64
    public var ackedMseq: UInt64
    public var durableMseq: UInt64
    public var lastDurableEpoch: UInt64

    public init(nextMseq: UInt64, ackedMseq: UInt64,
                durableMseq: UInt64, lastDurableEpoch: UInt64) {
        self.nextMseq = nextMseq
        self.ackedMseq = ackedMseq
        self.durableMseq = durableMseq
        self.lastDurableEpoch = lastDurableEpoch
    }
}

/// The workspace log facade (PLAN §2.3).
public actor WorkspaceLog: WorkspaceLogging {
    public let configuration: WorkspaceLogConfiguration
    public let bootID: Data
    public let paths: WorkspacePaths
    public let quotas: LogQuota

    private var writer: WALWriter
    private var materializer: Materializer
    private var journal: JournalLog
    private var recoveryReport: RecoveryReport
    private var logicalIndex: VfsLogicalIndex

    /// One or more mutations whose callers wait for the same group-commit
    /// write. The continuation receives one mseq per mutation, in input order.
    private struct QueuedAppend {
        var mutations: [VfsMutationBody]
        var continuation: CheckedContinuation<[UInt64], Error>
    }

    /// Mutations waiting for the next shared WAL write (W4 group commit).
    private var appendQueue: [QueuedAppend] = []
    private var appendDrainTask: Task<Void, Never>?
    private var draining = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var closing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var epochCloseObservers: [UUID: @Sendable (WALEpochCloseResult) async -> Void] = [:]
    private var emittedResyncPaths: Set<String> = []
    /// Resync paths left by cold recovery. The fresh Materializer starts at the
    /// recovered watermark and has not re-encountered the deferred records yet,
    /// so the paths and their first held mseq are kept until the repair settles
    /// them. Without this the first repair append would report a watermark gap
    /// with no pending resync and fail loud (wal.md §5.1, §10).
    private var recoveryResyncHolds: [String: UInt64] = [:]

    private nonisolated let ackHub = AckBroadcaster<WorkspaceLogAck>(replayLimit: 64)
    private nonisolated let journalAckHub = AckBroadcaster<JournalAck>(replayLimit: 64)
    private nonisolated let resyncHub = AckBroadcaster<String>()
    private var ackBridge: Task<Void, Never>?
    private var journalBridge: Task<Void, Never>?

    /// Runs cold recovery (wal.md §10) and opens the next epoch. The actor is
    /// usable as soon as the initializer returns.
    public init(configuration: WorkspaceLogConfiguration, bootID: Data) throws {
        guard bootID.count == 16 else {
            throw LogError.corrupt("boot_id must be 16 raw bytes")
        }
        self.configuration = configuration
        self.bootID = bootID
        self.paths = WorkspacePaths(root: configuration.root, cacheRoot: configuration.cacheRoot)
        self.quotas = LogQuota(configuration: configuration)
        // Recovery creates the directories *after* its startup sweep: creating
        // `materialized/` first would make an absent tree look present and
        // strand the only copy under `.materialized.previous`.
        let manager = RecoveryManager(configuration: configuration, bootID: bootID)
        var report = try manager.recover()
        // The writer reuses the verified segment state instead of scanning the
        // WAL again (W4). Drop the heavy records from the long-lived report.
        let recoveredSegments = report.segments
        report.segments = []
        self.recoveryReport = report
        for hold in report.resyncHolds {
            self.recoveryResyncHolds[hold.path] = hold.mseq
        }
        for path in report.needsResync where self.recoveryResyncHolds[path] == nil {
            // A legacy/staged report names the path without the held mseq. The
            // first unapplied record starts just above the recovered watermark;
            // the entry clears once that position is materialized.
            self.recoveryResyncHolds[path] = report.materializedUptoMseq &+ 1
        }
        self.emittedResyncPaths = Set(report.needsResync)

        let materializer = try Materializer(root: configuration.root,
                                            materializedUptoMseq: report.materializedUptoMseq,
                                            appliedThroughMseq: report.ackedMseq)
        self.materializer = materializer
        self.logicalIndex = try VfsLogicalIndex(
            paths: paths,
            materializedUptoMseq: report.materializedUptoMseq,
            singleFileLimitBytes: configuration.singleFileLimitBytes,
            quota: configuration.vfsQuota)

        let writer = try WALWriter(configuration: configuration,
                                   bootID: bootID,
                                   resumeState: WALWriterResumeState(
                                       nextMseq: report.nextMseq,
                                       lastMseq: report.ackedMseq,
                                       durableMseq: report.durableMseq,
                                       lastDurableEpoch: report.lastDurableEpoch,
                                       startEpoch: report.nextEpoch,
                                       materializedUptoMseq: report.materializedUptoMseq,
                                       truncatedTornTail: report.truncatedTornTail,
                                       segments: recoveredSegments))
        self.writer = writer

        let journal = try JournalLog(configuration: configuration, bootID: bootID)
        self.journal = journal

        // Subscribe the bridges synchronously, before the initializer returns:
        // `AckBroadcaster.stream()` registers its continuation immediately, so
        // no ack emitted by a later append can fall between writer creation and
        // bridge subscription. The bridge task itself may start later; the
        // AsyncStream buffers the acks until it does.
        let writerAcks = writer.acks()
        let journalAcks = journal.acks()
        let ackHub = self.ackHub
        self.ackBridge = Task {
            for await ack in writerAcks {
                ackHub.yield(ack)
            }
        }
        let journalAckHub = self.journalAckHub
        self.journalBridge = Task {
            for await ack in journalAcks {
                journalAckHub.yield(ack)
            }
        }
    }

    deinit {
        ackBridge?.cancel()
        journalBridge?.cancel()
    }

    // MARK: - VFS log

    /// Appends one structurally validated mutation, waits for the group-commit
    /// level-1 write, then applies the WAL prefix to the materialized copy.
    ///
    /// The accepted VFS logical size is checked first: a write that would grow
    /// one file past the configured single-file budget is refused as a
    /// resource error and consumes no mseq (budgets.md §4, channel.md §6).
    /// Under WAL quota pressure the host closes the epoch in D18 order and
    /// compacts droppable segments before retrying once; repeated rewrites of
    /// one large file therefore converge instead of entering Failed.
    ///
    /// Appends that arrive while another append is waiting for its level-1
    /// `write()` share that write (W4 group commit). The queue keeps the mseq
    /// order, and all mutations in one batch are validated before any byte is
    /// written, so a batch lands whole or not at all.
    public func append(_ mutation: VfsMutationBody) async throws -> UInt64 {
        await waitForClose()
        let mseqs = try await enqueueAppends([mutation])
        guard let first = mseqs.first else {
            throw LogError.corrupt("append returned no mseq")
        }
        return first
    }

    /// Appends several accepted mutations with one shared group-commit write
    /// (W4). The returned mseqs are in input order. A validation failure fails
    /// the whole batch before it consumes any mseq.
    public func appendBatch(_ mutations: [VfsMutationBody]) async throws -> [UInt64] {
        await waitForClose()
        guard !mutations.isEmpty else { return [] }
        return try await enqueueAppends(mutations)
    }

    private func enqueueAppends(_ mutations: [VfsMutationBody]) async throws
        -> [UInt64] {
        try await withCheckedThrowingContinuation { continuation in
            appendQueue.append(QueuedAppend(mutations: mutations,
                                            continuation: continuation))
            scheduleAppendDrain()
        }
    }

    private func scheduleAppendDrain() {
        guard appendDrainTask == nil else { return }
        appendDrainTask = Task { [weak self] in
            guard let self else { return }
            await self.drainAppendQueue()
        }
    }

    /// Drains every queued mutation as one WAL batch. The task is created once
    /// per drain; appends that arrive while the batch is in flight start the
    /// next drain after this one releases the queue.
    private func drainAppendQueue() async {
        let batch = appendQueue
        appendQueue.removeAll()
        guard !batch.isEmpty else {
            appendDrainTask = nil
            return
        }
        defer {
            appendDrainTask = nil
            if !appendQueue.isEmpty { scheduleAppendDrain() }
        }

        let mutations = batch.flatMap(\.mutations)
        do {
            for mutation in mutations {
                try logicalIndex.validate(mutation)
            }
            let results = try await appendBatchWithQuotaRecovery(mutations)
            for mutation in mutations {
                logicalIndex.apply(mutation)
                if ProcessInfo.processInfo.environment["PDSH_DEBUG_VFS"] == "1" {
                    Self.debugLogVFS(mutation, total: logicalIndex.totalBytes,
                                     sizes: logicalIndex.sizes)
                }
            }
            // D8 step 4: ack level 1 is already out; materialize from the exact
            // records the writer returned instead of re-reading the WAL.
            try await materializeAppendedBatch(results)
            var offset = 0
            for item in batch {
                let end = offset + item.mutations.count
                let slice = Array(results[offset..<end]).map(\.mseq)
                item.continuation.resume(returning: slice)
                offset = end
            }
        } catch {
            for item in batch {
                item.continuation.resume(throwing: error)
            }
        }
    }

    /// Forensic only (`PDSH_DEBUG_VFS=1`): one line per accepted mutation with
    /// the path, the increment and the cumulative logical bytes per prefix.
    /// This exists to settle whether a workspace quota is enforced; it is not
    /// a policy.
    private static func debugLogVFS(_ mutation: VfsMutationBody,
                                    total: Int,
                                    sizes: [String: Int]) {
        let prefixes = ["/dsh/workspace", "/dsh/home/sessions", "/dsh/tmp"]
        var sums: [String: Int] = [:]
        for (path, size) in sizes {
            guard let prefix = prefixes.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                continue
            }
            sums[prefix, default: 0] += size
        }
        let parts = prefixes.map { "\($0)=\(sums[$0] ?? 0)" }.joined(separator: " ")
        let increment = mutation.op == .write ? mutation.data.count : 0
        let line = "[vfs] op=\(mutation.op) path=\(mutation.path) +\(increment) total=\(total) \(parts)"
        PhoneDSHStandardError.write(line)
    }

    /// Cumulative WAL acks. A new subscriber receives the retained recent acks
    /// before later live ones, so the channel sees the current watermark even
    /// when it subscribes after an append.
    public nonisolated func acks() -> AsyncStream<WorkspaceLogAck> {
        ackHub.stream()
    }

    /// VFS_RESYNC requests for paths whose appended base did not match (D8).
    public nonisolated func resyncRequests() -> AsyncStream<String> {
        resyncHub.stream()
    }

    /// Waits for a cumulative ack (channel.md §8). Level 2 closes the epoch if
    /// no durable ack covers `upto` yet.
    public func barrier(level: AckLevel, upto: UInt64) async throws -> WorkspaceLogAck {
        switch level {
        case .write:
            return try await writer.barrier(level: .write, upto: upto)
        case .epochFsync:
            guard upto <= (await writer.lastMseq) else {
                throw LogError.invalidBarrier("mseq \(upto) was not appended")
            }
            if let ack = await writer.lastLevel2Ack, ack.uptoMseq >= upto {
                return ack
            }
            return try await closeEpoch()
        }
    }

    /// D18 epoch close: materialized fsync → WAL F_FULLFSYNC → manifest →
    /// journal F_FULLFSYNC → level-2 ack.
    public func closeEpoch() async throws -> WorkspaceLogAck {
        await beginClose()
        defer { endClose() }
        try await writer.flush()
        // D18 steps 1–5: fsync the materialized changes and hold the manifest
        // rewrite until `writer.closeEpoch` has appended the close record,
        // F_FULLFSYNCed every written segment and fsynced `wal/`.
        try await drainMaterialization(persistManifest: false)
        // D8: an unrepaired base mismatch at the epoch close closes admission
        // and makes the host Failed. Claiming a durable epoch while the
        // strictly contiguous watermark is below the accepted tail would make
        // the level-2 position a lie; fail loud instead.
        let acceptedTail = await writer.lastMseq
        guard materializer.materializedUptoMseq == acceptedTail else {
            let holds = pendingResyncHolds()
            let detail = holds.isEmpty
                ? ""
                : "; unrepaired base mismatch at "
                    + holds.map { "\($0.path) mseq \($0.mseq)" }.joined(separator: ", ")
            throw LogError.corrupt(
                "epoch close with an unrepaired base mismatch: materialized_upto "
                    + "\(materializer.materializedUptoMseq) is below the WAL tail \(acceptedTail)"
                    + detail)
        }
        try materializer.fsyncEpoch()
        await writer.setMaterializedUpto(materializer.materializedUptoMseq)
        let result = try await writer.closeEpoch(emitLevel2Ack: false)
        _ = try await journal.closeEpoch()
        await writer.confirmEpochDurable(result)
        // wal.md §12: the reclaim trigger is every successful D18 close, not
        // only the quota path. The level-2 ack is already durable here; the
        // manifest-first unlink below can only remove segments covered by it.
        _ = try await writer.compactDroppableSegments()
        recoveryReport.materializedUptoMseq = materializer.materializedUptoMseq
        await notifyEpochCloseObservers(result)
        return WorkspaceLogAck(level: .epochFsync, uptoMseq: result.durableUpto)
    }

    /// Registers a post-close observer. The response log uses it to reclaim
    /// bodies at the same trigger (gateway-security.md §11); observers run
    /// after the manifest and level-2 ack are durable. Returns an opaque id
    /// for ``removeEpochCloseObserver``.
    @discardableResult
    public func addEpochCloseObserver(
        _ observer: @escaping @Sendable (WALEpochCloseResult) async -> Void) -> UUID {
        let id = UUID()
        epochCloseObservers[id] = observer
        return id
    }

    public func removeEpochCloseObserver(_ id: UUID) {
        epochCloseObservers.removeValue(forKey: id)
    }

    private func notifyEpochCloseObservers(_ result: WALEpochCloseResult) async {
        for observer in epochCloseObservers.values {
            await observer(result)
        }
    }

    /// Closes the current epoch now and, when a mutation was appended while
    /// the close was running, closes the epoch that mutation opened as well.
    ///
    /// The caller owns the mutation source. A drain closes the epoch while
    /// the Worker channel may still be live, so a sink frame accepted during
    /// the close opens a new epoch behind the level-2 ack. This method repeats
    /// the D18 close until the returned ack covers the effective WAL tail
    /// (D17: `max(last_mseq, WAL tail)`), so the durable watermark can never
    /// stay below the on-disk tail.
    ///
    /// - Parameter maximumAttempts: total closes attempted before the call
    ///   fails loud. A quiesced source needs one; a frame that raced the close
    ///   needs two.
    public func closeEpochCoveringTail(
        maximumAttempts: Int = 4) async throws -> WorkspaceLogAck {
        let limit = max(1, maximumAttempts)
        var ack = try await closeEpoch()
        var closes = 1
        while true {
            let tail = await writer.lastMseq
            if ack.uptoMseq >= tail { return ack }
            guard closes < limit else {
                throw LogError.epochCoverageFailed(
                    "durable_upto \(ack.uptoMseq) is below the WAL tail \(tail) after \(closes) close(s)")
            }
            ack = try await closeEpoch()
            closes += 1
        }
    }

    /// Ensures an already-completed close still covers the effective WAL tail,
    /// closing another epoch only when it does not.
    ///
    /// This is the host-side seal used after the ordered channel is torn down
    /// (park/stop) and after the controller closed the epoch for a planned
    /// restart or a handoff. When no mutation opened a new epoch it is a
    /// no-op: it returns the current durable position without writing a
    /// level-2 ack or an empty epoch.
    public func sealEpochCoveringTail(
        maximumAttempts: Int = 4) async throws -> WorkspaceLogAck {
        let positions = await self.positions()
        if positions.durableMseq >= positions.ackedMseq {
            return WorkspaceLogAck(level: .epochFsync, uptoMseq: positions.durableMseq)
        }
        return try await closeEpochCoveringTail(maximumAttempts: maximumAttempts)
    }

    /// The terminal stop/abort invariant (D8/D11/D18).
    ///
    /// Closes the epoch when the accepted tail is not yet durable (the same
    /// D18 order as ``closeEpoch``), materializes the accepted prefix, and then
    /// proves that every file whose last mutation is at or below the materialized
    /// watermark is present with its last acknowledged content.
    ///
    /// When the retained WAL starts at mseq 1 the copy is rebuilt from it and
    /// the call succeeds; otherwise the divergence is `WAL_CORRUPT` and the
    /// host goes Failed — never a silent loss. This is called by the host on
    /// every teardown, including the abort/failed drain, so a stopped host can
    /// never leave an unrestricted open epoch behind an inverted manifest.
    public func sealForStop() async throws -> WorkspaceLogAck {
        // Close only when the accepted tail is not durable yet; a park that
        // already sealed does not write an empty epoch.
        var ack = try await sealEpochCoveringTail()
        // A terminal stop must leave `wal/` exactly equal to the manifest: the
        // header-only segment the D18 close creates for the next epoch is not
        // content and is discarded here instead of becoming a permanent orphan
        // (G2-FIX-69/120).
        _ = try await writer.discardCurrentEmptySegment()
        try await drainMaterialization()
        let acceptedTail = await writer.lastMseq
        guard materializer.materializedUptoMseq == acceptedTail else {
            let holds = pendingResyncHolds()
            let detail = holds.isEmpty
                ? ""
                : " at "
                    + holds.map { "\($0.path) mseq \($0.mseq)" }.joined(separator: ", ")
            throw LogError.corrupt(
                "stop invariant: materialized_upto \(materializer.materializedUptoMseq) "
                    + "is below the WAL tail \(acceptedTail); an unrepaired base mismatch remains"
                    + detail)
        }
        let scan = try WALReader.scan(directory: paths.walDirectory)
        let bootIDHex = bootID.map { String(format: "%02x", $0) }.joined()
        let report = try MaterializedInvariant.checkAndRepair(
            paths: paths,
            records: scan.segments.flatMap(\.records),
            materializedUptoMseq: materializer.materializedUptoMseq,
            allowRepair: true,
            bootIDHex: bootIDHex)
        if report.repaired {
            try await writer.recordMaterializedUpto(report.materializedUptoMseq)
            recoveryReport.materializedUptoMseq = report.materializedUptoMseq
            // The rebuild applied the whole retained WAL; the deferred set is
            // settled and no repair round trip is outstanding.
            emittedResyncPaths.removeAll()
        }
        if !report.localRepairs.isEmpty {
            recoveryReport.localRepairs.append(contentsOf: report.localRepairs)
        }
        recoveryReport.materializedUptoMseq = materializer.materializedUptoMseq
        let durableMseq = await writer.durableMseq
        let ackedMseq = await writer.lastMseq
        if durableMseq >= ackedMseq {
            ack = WorkspaceLogAck(level: .epochFsync, uptoMseq: durableMseq)
        }
        return ack
    }

    /// Applies the WAL prefix and returns the strictly contiguous watermark.
    public func materialize() async throws -> UInt64 {
        try await writer.flush()
        try await drainMaterialization()
        try await persistMaterializedWatermarkIfNeeded()
        return materializer.materializedUptoMseq
    }

    /// The boot overlay bytes: gzip-compressed ustar (wal.md §8, D21).
    public func packOverlay() async throws -> Data {
        _ = try await materialize()
        return try OverlayPacker(materializedDirectory: materializer.materializedDirectory).data()
    }

    /// Writes the boot overlay to `<root>/overlay-<boot_id>.tar` and returns
    /// it. The file name keeps the pre-D21 route contract; the bytes are the
    /// gzip member of D21.
    public func overlay(bootID: String) async throws -> URL {
        guard WireValidation.isValidBootID(bootID) else {
            throw LogError.corrupt("invalid boot id for the overlay name")
        }
        _ = try await materialize()
        // The overlay is a gzip of the whole materialized tree. Rebuilding it
        // on every boot made start-up O(workspace): a 100 MB workspace spent
        // ~10 s packing the same bytes again (measured on the phone). The tree
        // at a given materialized watermark is deterministic, so the cache is
        // valid exactly while that watermark is unchanged.
        let watermark = materializer.materializedUptoMseq
        let cacheDirectory = paths.overlayCacheDirectory
        try FileManager.default.createDirectory(at: cacheDirectory,
                                                withIntermediateDirectories: true)
        // One-time, re-entrant migration of the pre-W3 cache. The old files
        // stay in place until the new copy is verified; a kill between the two
        // moves repeats the copy on the next boot.
        Self.migrateLegacyOverlayCacheIfNeeded(root: paths.root,
                                               cacheDirectory: cacheDirectory)
        let cacheURL = Self.overlayCacheURL(in: cacheDirectory)
        let bootURL = paths.overlayURL(bootID: bootID)
        if !Self.overlayCacheIsValid(root: cacheDirectory, watermark: watermark) {
            _ = try OverlayPacker(materializedDirectory: materializer.materializedDirectory)
                .pack(to: cacheURL)
            try Self.writeOverlayCacheSidecar(root: cacheDirectory, watermark: watermark)
        }
        // Keep the documented per-boot name without repacking: a hard link is
        // O(1) and the cache file is only ever replaced by an atomic rename,
        // never modified in place.
        try Self.materializeBootOverlay(cache: cacheURL, boot: bootURL)
        // Both files are derived from the materialized tree and are rebuilt on
        // demand; they must not be uploaded as part of the device backup.
        Self.excludeFromBackup(cacheURL)
        Self.excludeFromBackup(bootURL)
        Self.pruneBootOverlays(root: paths.root, keeping: [cacheURL, bootURL])
        if cacheDirectory.standardizedFileURL != paths.root.standardizedFileURL {
            Self.pruneBootOverlays(root: cacheDirectory, keeping: [cacheURL, bootURL])
        }
        return bootURL
    }

    // MARK: - Boot overlay cache

    /// Marks an overlay tar as excluded from iCloud/device backup. The overlay
    /// is derived state (wal.md §8), so a restore can rebuild it; a refusal is
    /// best effort and changes no overlay behaviour.
    private static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    private static let overlayCacheFileName = "overlay-cache.tar"
    private static let overlayCacheSidecarFileName = "overlay-cache.json"
    private static let overlayCacheFormat = 1

    private struct OverlayCacheSidecar: Codable {
        var format: Int
        var watermark: UInt64
        var builtAt: String
    }

    static func overlayCacheURL(root: URL) -> URL {
        root.appendingPathComponent(overlayCacheFileName)
    }

    static func overlayCacheURL(in directory: URL) -> URL {
        directory.appendingPathComponent(overlayCacheFileName)
    }

    /// Moves a valid pre-W3 in-workspace cache into the cache directory. A
    /// missing backup or sidecar is ignored: the cache is derived and will be
    /// rebuilt from the materialized copy. The legacy files are removed only
    /// after both moves succeeded, and a retry is harmless.
    private static func migrateLegacyOverlayCacheIfNeeded(root: URL, cacheDirectory: URL) {
        let legacyDirectory = root
        guard legacyDirectory.standardizedFileURL != cacheDirectory.standardizedFileURL else {
            return
        }
        let legacyTar = overlayCacheURL(root: legacyDirectory)
        let legacySidecar = legacyDirectory.appendingPathComponent(overlayCacheSidecarFileName)
        let newTar = overlayCacheURL(in: cacheDirectory)
        let newSidecar = cacheDirectory.appendingPathComponent(overlayCacheSidecarFileName)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyTar.path),
              fileManager.fileExists(atPath: legacySidecar.path) else { return }
        guard !fileManager.fileExists(atPath: newTar.path),
              !fileManager.fileExists(atPath: newSidecar.path) else {
            // The new layout already won. The old copy is rollback evidence;
            // do not delete it here.
            return
        }
        do {
            try fileManager.moveItem(at: legacyTar, to: newTar)
            try fileManager.moveItem(at: legacySidecar, to: newSidecar)
        } catch {
            // Re-entrant: a partial migration leaves at most one new file and
            // the next call either sees both and validates, or rebuilds.
        }
    }

    private static func overlayCacheIsValid(root: URL, watermark: UInt64) -> Bool {
        let tar = overlayCacheURL(root: root)
        guard FileManager.default.fileExists(atPath: tar.path) else { return false }
        let sidecarURL = root.appendingPathComponent(overlayCacheSidecarFileName)
        guard let data = try? Data(contentsOf: sidecarURL),
              let sidecar = try? JSONDecoder().decode(OverlayCacheSidecar.self, from: data) else {
            return false
        }
        return sidecar.format == overlayCacheFormat && sidecar.watermark == watermark
    }

    private static func writeOverlayCacheSidecar(root: URL, watermark: UInt64) throws {
        let sidecar = OverlayCacheSidecar(
            format: overlayCacheFormat,
            watermark: watermark,
            builtAt: ISO8601DateFormatter().string(from: Date()))
        let data = try JSONEncoder().encode(sidecar)
        try LogFile.atomicWrite(data,
                                to: root.appendingPathComponent(overlayCacheSidecarFileName))
    }

    /// Gives this boot its documented `overlay-<boot_id>.tar` name by linking
    /// the cached tar; a copy is the fallback when linking is unavailable.
    private static func materializeBootOverlay(cache: URL, boot: URL) throws {
        try? FileManager.default.removeItem(at: boot)
        do {
            try FileManager.default.linkItem(at: cache, to: boot)
        } catch {
            try? FileManager.default.copyItem(at: cache, to: boot)
        }
    }

    /// Removes overlays of older boots; each one is as large as the workspace.
    private static func pruneBootOverlays(root: URL, keeping: [URL]) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return }
        let keep = Set(keeping.map(\.standardizedFileURL))
        for file in files where file.lastPathComponent.hasPrefix("overlay-")
            && file.pathExtension == "tar"
            && !keep.contains(file.standardizedFileURL) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Re-runs the materialization pass and returns the current recovery report.
    public func recover() async throws -> RecoveryReport {
        try await writer.flush()
        try await drainMaterialization()
        try await persistMaterializedWatermarkIfNeeded()
        var report = recoveryReport
        report.materializedUptoMseq = materializer.materializedUptoMseq
        report.nextMseq = await writer.nextMseq
        report.ackedMseq = await writer.lastMseq
        report.durableMseq = await writer.durableMseq
        report.lastDurableEpoch = await writer.lastDurableEpoch
        let writerTruncated = await writer.truncatedTornTail
        report.truncatedTornTail = recoveryReport.truncatedTornTail || writerTruncated
        report.needsResync = pendingResyncPaths()
        report.resyncHolds = pendingResyncHolds()
        return report
    }

    /// Paths that still await a VFS_RESYNC repair. The loopback service
    /// re-requests these after HELLO (channel.md §9.6, GAP-13).
    public func pendingResyncPaths() -> [String] {
        Set(recoveryResyncHolds.keys)
            .union(materializer.needsResyncPaths)
            .sorted()
    }

    /// The path and first held mseq of every pending repair (wal.md §5.2).
    public func pendingResyncHolds() -> [MaterializationHold] {
        var holds: [String: UInt64] = recoveryResyncHolds
        for hold in materializer.heldMismatches where holds[hold.path] == nil {
            holds[hold.path] = hold.mseq
        }
        return holds
            .map { MaterializationHold(path: $0.key, mseq: $0.value) }
            .sorted { $0.path < $1.path }
    }

    /// HELLO `next_mseq`, `acked_mseq` and `durable_mseq` (channel.md §4.1).
    public func positions() async -> WorkspaceLogPositions {
        WorkspaceLogPositions(nextMseq: await writer.nextMseq,
                              ackedMseq: await writer.lastMseq,
                              durableMseq: await writer.durableMseq,
                              lastDurableEpoch: await writer.lastDurableEpoch)
    }

    /// Host-only compaction used by the closed-session rewrite (wal.md §5.3,
    /// §9). The caller has already parked the Worker, closed the rewrite epoch
    /// in the D18 order and made the materialized copy durable; this method
    /// refuses to drop anything unless the materialized watermark covers the
    /// accepted tail.
    @discardableResult
    public func compactDroppableSegments() async throws -> [String] {
        await beginClose()
        defer { endClose() }
        try await writer.flush()
        let accepted = await writer.lastMseq
        guard materializer.materializedUptoMseq == accepted else {
            throw LogError.corrupt(
                "host compaction with materialized_upto \(materializer.materializedUptoMseq) "
                    + "below the accepted tail \(accepted)")
        }
        await writer.setMaterializedUpto(materializer.materializedUptoMseq)
        return try await writer.compactDroppableSegments()
    }

    // MARK: - Journal

    /// Appends one `0x30` record; the level-1 journal ack follows write().
    public func journalAppend(_ body: JournalBody) async throws -> UInt64 {
        try await journal.append(body)
    }

    /// Cumulative journal acks, coalesced at epoch close for level 2.
    public nonisolated func journalAcks() -> AsyncStream<JournalAck> {
        journalAckHub.stream()
    }

    /// The journal high-water mark of one session.
    public func journalLastJseq(sessionID: String) async -> UInt64 {
        await journal.lastJseq(sessionID: sessionID)
    }

    /// Validated persisted journal bodies, in file order, for projection
    /// recovery after a crash between append and the handler callback.
    public func recoveredJournalSnapshot() async -> [JournalBody] {
        await journal.recoveredSnapshot()
    }

    // MARK: - Metrics

    /// VFS bytes by the memory-proxy prefixes plus WAL/journal usage.
    public func metrics() async throws -> WorkspaceLogMetrics {
        var metrics = WorkspaceLogMetrics()
        metrics.workspaceBytes = try directorySize(materializer.workspaceDirectory)
        let sessions = materializer.homeDirectory.appendingPathComponent("sessions",
                                                                         isDirectory: true)
        metrics.homeSessionsBytes = try directorySize(sessions)
        let homeTotal = try directorySize(materializer.homeDirectory)
        metrics.otherBytes = max(0, homeTotal - metrics.homeSessionsBytes)
        metrics.tmpBytes = 0
        metrics.walBytes = await writer.walByteCount
        metrics.journalBytes = await journal.sizeInBytes()
        return metrics
    }

    /// Internal test seam: record-write counters prove a batch shared one
    /// `write()` (W4 group commit).
    internal func writerCountersForTesting() async -> (batchCount: Int,
                                                       recordWriteCount: Int) {
        (await writer.batchCount, await writer.recordWriteCount)
    }

    // MARK: - Quota recovery

    /// Appends one accepted batch, recovering from WAL quota pressure by
    /// closing the current epoch and compacting every droppable segment. At
    /// most two epoch closes run per batch; a still-full quota fails loud.
    private func appendBatchWithQuotaRecovery(_ mutations: [VfsMutationBody]) async throws
        -> [WALAppendResult] {
        var closes = 0
        while true {
            do {
                return try await writer.appendBatch(mutations)
            } catch let error as LogError {
                guard case .quotaExceeded = error,
                      closes < 2,
                      materializer.needsResyncPaths.isEmpty else {
                    throw error
                }
                closes += 1
                _ = try await closeEpoch()
                _ = try await writer.compactDroppableSegments()
            }
        }
    }

    // MARK: - Materialization internals

    /// Writes the manifest watermark after an explicit reconcile/materialize,
    /// where no per-mutation rewrite happens any more (W4, wal.md §13). The
    /// copy is fsynced first, exactly like D18 step 1.
    private func persistMaterializedWatermarkIfNeeded() async throws {
        let target = materializer.materializedUptoMseq
        guard await writer.materializedWatermark < target else { return }
        try materializer.fsyncEpoch()
        try await writer.recordMaterializedUpto(target)
    }

    /// Applies the records the writer just committed without re-reading the WAL.
    ///
    /// Before this path existed every accepted mutation re-materialized by
    /// scanning and re-verifying *every* WAL segment from disk. The level-1 ack
    /// stayed event-driven, but the ordered channel dispatches inbound frames
    /// sequentially, so the next frame (the tool journal's `0x30`) waited for
    /// that full re-verification. After a large sink write the whole history was
    /// large, and each tool-call boundary paid the rescan again and again — the
    /// fixed multi-second cadence G2-FIX-83 reports. The writer returns the
    /// records it wrote, so they are applied in place in constant extra work. A
    /// record gap (an adopted recovery tail, a concurrent epoch close) falls
    /// back to the verified full scan, so mseq ordering and D9 replay
    /// idempotence stay unchanged.
    ///
    /// W4: the manifest is no longer rewritten per mutation. The in-memory
    /// watermark advances here; `manifest.json` is written only at epoch close
    /// (or reconcile/segment deletion), after D18 step 1 has fsynced the copy
    /// (wal.md §13). A crash therefore replays from the last persisted watermark
    /// with the §6.2 idempotent rules instead of paying an fsync and a manifest
    /// rewrite per VFS mutation.
    private func materializeAppendedBatch(_ results: [WALAppendResult]) async throws {
        guard let lastResult = results.last else { return }
        guard lastResult.mseq > materializer.appliedThroughMseq else { return }
        // Recovery left a held replay the fresh Materializer has not seen. The
        // repair append is applied against the on-disk retained sequence (the
        // cover settles the held record), never one record in isolation.
        if !recoveryResyncHolds.isEmpty {
            try await drainMaterialization()
            emitResyncRequests()
            return
        }
        guard let firstResult = results.first,
              firstResult.mseq == materializer.appliedThroughMseq + 1 else {
            try await drainMaterialization()
            return
        }
        let before = materializer.materializedUptoMseq
        let report = try materializer.apply(records: results.map(\.record))
        guard report.materializedUptoMseq > before else {
            guard !materializer.needsResyncPaths.isEmpty else {
                // The records were taken in but the contiguous watermark could
                // not move and no base mismatch explains it: the accepted mseq
                // sequence has a hole. Advancing here or continuing silently
                // would make materialized_upto skip an unapplied mutation (D8).
                throw LogError.corrupt(
                    "mseq \(lastResult.mseq) was accepted but the materialized watermark "
                        + "\(report.materializedUptoMseq) did not advance and no resync is pending")
            }
            // A deferred base mismatch (D8/D9) takes the records in but holds
            // the contiguous watermark; the resync request it produced still
            // has to reach the Worker.
            emitResyncRequests()
            return
        }
        recoveryReport.materializedUptoMseq = report.materializedUptoMseq
        emitResyncRequests()
    }

    /// Internal test seam: observes the D18 step-1 fsync of a materialization
    /// batch before its manifest rewrite. Production leaves this nil.
    internal func setMaterializerFsyncObserverForTesting(
        _ observer: (@Sendable () -> Void)?) {
        materializer.onFsyncCompleted = observer
    }

    private func drainMaterialization(persistManifest: Bool = true) async throws {
        while true {
            while draining {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    drainWaiters.append(continuation)
                }
            }
            draining = true
            let caughtUp: Bool
            do {
                caughtUp = try await runMaterializationPasses(persistManifest: persistManifest)
            } catch {
                draining = false
                resumeDrainWaiters()
                throw error
            }
            draining = false
            resumeDrainWaiters()
            guard caughtUp else { break }
            // A record may have been appended after the last snapshot; loop
            // once more so append() never returns with its own record pending.
            if materializer.materializedUptoMseq >= (await writer.lastMseq) {
                break
            }
        }
    }

    /// Returns `false` when the contiguous watermark is held back by a base
    /// mismatch (a repair write is needed), `true` when the pass is caught up.
    private func runMaterializationPasses(persistManifest: Bool) async throws -> Bool {
        while true {
            let last = await writer.lastMseq
            let from = materializer.materializedUptoMseq + 1
            guard from <= last else { return true }
            let records = try WALReader.records(directory: paths.walDirectory, fromMseq: from)
            guard !records.isEmpty else { return true }
            guard let firstRecorded = records.first?.mseq, firstRecorded == from else {
                throw LogError.corrupt(
                    "the WAL does not contain mseq \(from) (first replayed mseq "
                        + "\(records.first?.mseq ?? 0)); the materialized watermark cannot advance")
            }
            let before = materializer.materializedUptoMseq
            let report = try materializer.apply(records: records)
            // wal.md §7.1/§13: a manifest rewrite may only happen after §5.2
            // step 1 has made every applied mutation durable. A recovery drain
            // persists the manifest, so fsync here. An epoch close defers both
            // the fsync and the rewrite to D18 steps 1/5 (`closeEpoch` calls
            // `materializer.fsyncEpoch()` before the manifest write).
            if persistManifest {
                try materializer.fsyncEpoch()
                try await writer.recordMaterializedUpto(report.materializedUptoMseq)
            } else {
                await writer.setMaterializedUpto(report.materializedUptoMseq)
            }
            recoveryReport.materializedUptoMseq = report.materializedUptoMseq
            syncRecoveryResyncHolds()
            emitResyncRequests()
            if report.materializedUptoMseq == before {
                // A deferred base mismatch holds the contiguous watermark;
                // later records of other paths are already applied.
                return false
            }
            if report.materializedUptoMseq >= last { return true }
        }
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func emitResyncRequests() {
        let current = materializer.needsResyncPaths
        for path in current.subtracting(emittedResyncPaths).sorted() {
            resyncHub.yield(path)
        }
        emittedResyncPaths = current
    }

    /// Drops recovery-held paths once the retained sequence has materialized
    /// past them and the Materializer owns the (now empty) deferred set. A
    /// still-held record stays listed for the drain detail.
    private func syncRecoveryResyncHolds() {
        guard !recoveryResyncHolds.isEmpty else { return }
        for path in recoveryResyncHolds.keys {
            guard let held = recoveryResyncHolds[path] else { continue }
            if !materializer.needsResyncPaths.contains(path),
               materializer.materializedUptoMseq >= held {
                recoveryResyncHolds.removeValue(forKey: path)
            }
        }
        recoveryReport.needsResync = pendingResyncPaths()
        recoveryReport.resyncHolds = pendingResyncHolds()
    }

    private func directorySize(_ url: URL) throws -> Int {
        guard LogFile.exists(url) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in false }) else {
            return 0
        }
        var total = 0
        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += values.fileSize ?? 0
            }
        }
        return total
    }

    // MARK: - Close gate

    private func waitForClose() async {
        while closing {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                closeWaiters.append(continuation)
            }
        }
    }

    private func beginClose() async {
        await waitForClose()
        closing = true
    }

    private func endClose() {
        closing = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
