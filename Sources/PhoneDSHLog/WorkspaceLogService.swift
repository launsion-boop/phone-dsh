// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the module facade.
//
// PLAN §2.3 (D7/D8/D9/D11/D17/D18/D19) and spec/v1/wal.md. The
// `WorkspaceLog` actor is what the loopback channel and the task controller
// call: append -> level-1 ack, epoch close -> level-2 ack, materialization,
// boot overlay, recovery report, journal and the per-prefix metrics of the
// memory proxy. Cold recovery runs on open so the actor is usable immediately.

import Foundation
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

    private var appending = false
    private var appendWaiters: [CheckedContinuation<Void, Never>] = []
    private var draining = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var closing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var emittedResyncPaths: Set<String> = []

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
        self.paths = WorkspacePaths(root: configuration.root)
        self.quotas = LogQuota(configuration: configuration)
        // Recovery creates the directories *after* its startup sweep: creating
        // `materialized/` first would make an absent tree look present and
        // strand the only copy under `.materialized.previous`.
        let manager = RecoveryManager(configuration: configuration, bootID: bootID)
        let report = try manager.recover()
        self.recoveryReport = report

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
                                       truncatedTornTail: report.truncatedTornTail))
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
    public func append(_ mutation: VfsMutationBody) async throws -> UInt64 {
        await waitForClose()
        await beginAppend()
        defer { endAppend() }
        try logicalIndex.validate(mutation)
        let result = try await appendWithQuotaRecovery(mutation)
        logicalIndex.apply(mutation)
        if ProcessInfo.processInfo.environment["PDSH_DEBUG_VFS"] == "1" {
            Self.debugLogVFS(mutation, total: logicalIndex.totalBytes, sizes: logicalIndex.sizes)
        }
        // D8: append to the WAL, ack level 1, then materialize. The writer hands
        // the exact record back, so the materialization step applies that record
        // in place instead of re-reading the whole WAL from disk (G2-FIX-83).
        try await materializeAppended(result)
        return result.mseq
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
        let line = "[vfs] op=\(mutation.op) path=\(mutation.path) +\(increment) total=\(total) \(parts)\n"
        FileHandle.standardError.write(Data(line.utf8))
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
            throw LogError.corrupt(
                "epoch close with an unrepaired base mismatch: materialized_upto "
                    + "\(materializer.materializedUptoMseq) is below the WAL tail \(acceptedTail)")
        }
        try materializer.fsyncEpoch()
        await writer.setMaterializedUpto(materializer.materializedUptoMseq)
        let result = try await writer.closeEpoch(emitLevel2Ack: false)
        _ = try await journal.closeEpoch()
        await writer.confirmEpochDurable(result)
        recoveryReport.materializedUptoMseq = materializer.materializedUptoMseq
        return WorkspaceLogAck(level: .epochFsync, uptoMseq: result.durableUpto)
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
            throw LogError.corrupt(
                "stop invariant: materialized_upto \(materializer.materializedUptoMseq) "
                    + "is below the WAL tail \(acceptedTail); an unrepaired base mismatch remains")
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
        let url = paths.overlayURL(bootID: bootID)
        _ = try OverlayPacker(materializedDirectory: materializer.materializedDirectory)
            .pack(to: url)
        return url
    }

    /// Re-runs the materialization pass and returns the current recovery report.
    public func recover() async throws -> RecoveryReport {
        try await writer.flush()
        try await drainMaterialization()
        var report = recoveryReport
        report.materializedUptoMseq = materializer.materializedUptoMseq
        report.nextMseq = await writer.nextMseq
        report.ackedMseq = await writer.lastMseq
        report.durableMseq = await writer.durableMseq
        report.lastDurableEpoch = await writer.lastDurableEpoch
        let writerTruncated = await writer.truncatedTornTail
        report.truncatedTornTail = recoveryReport.truncatedTornTail || writerTruncated
        report.needsResync = Set(recoveryReport.needsResync)
            .union(materializer.needsResyncPaths)
            .sorted()
        return report
    }

    /// Paths that still await a VFS_RESYNC repair. The loopback service
    /// re-requests these after HELLO (channel.md §9.6).
    public func pendingResyncPaths() -> [String] {
        Set(recoveryReport.needsResync)
            .union(materializer.needsResyncPaths)
            .sorted()
    }

    /// HELLO `next_mseq`, `acked_mseq` and `durable_mseq` (channel.md §4.1).
    public func positions() async -> WorkspaceLogPositions {
        WorkspaceLogPositions(nextMseq: await writer.nextMseq,
                              ackedMseq: await writer.lastMseq,
                              durableMseq: await writer.durableMseq,
                              lastDurableEpoch: await writer.lastDurableEpoch)
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

    // MARK: - Append serialization / quota recovery

    private func beginAppend() async {
        while appending {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                appendWaiters.append(continuation)
            }
        }
        appending = true
    }

    private func endAppend() {
        appending = false
        let waiters = appendWaiters
        appendWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Appends one accepted mutation, recovering from WAL quota pressure by
    /// closing the current epoch and compacting every droppable segment. At
    /// most two epoch closes run per append; a still-full quota fails loud.
    private func appendWithQuotaRecovery(_ mutation: VfsMutationBody) async throws
        -> WALAppendResult {
        var closes = 0
        while true {
            do {
                return try await writer.appendWithRecord(mutation)
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

    /// Applies the record the writer just committed without re-reading the WAL.
    ///
    /// Before this path existed every accepted mutation re-materialized by
    /// scanning and re-verifying *every* WAL segment from disk. The level-1 ack
    /// stayed event-driven, but the ordered channel dispatches inbound frames
    /// sequentially, so the next frame (the tool journal's `0x30`) waited for
    /// that full re-verification. After a large sink write the whole history was
    /// large, and each tool-call boundary paid the rescan again and again — the
    /// fixed multi-second cadence G2-FIX-83 reports. Appends are serialized on
    /// this actor and the writer returns the record it wrote, so the record can
    /// be applied in place in constant extra work. A record gap (an adopted
    /// recovery tail, a concurrent epoch close) falls back to the verified full
    /// scan, so mseq ordering and D9 replay idempotence stay unchanged.
    ///
    /// The per-record `fsyncEpoch` + manifest rewrite below is the same D18
    /// step-1/step-5 ordering the old full-scan pass performed, and the landed
    /// tests assert the manifest names the watermark once `append` returns. Its
    /// cost is bounded per mutation instead of growing with the WAL: the
    /// measured boundary p50 is ~7 ms for four mutations (≈1.8 ms per record),
    /// so a long session pays a constant, not the multiplicative rescan the
    /// defect produced (G2-FIX-83 P1 review note).
    private func materializeAppended(_ result: WALAppendResult) async throws {
        guard result.mseq > materializer.appliedThroughMseq else { return }
        guard result.mseq == materializer.appliedThroughMseq + 1 else {
            try await drainMaterialization()
            return
        }
        let before = materializer.materializedUptoMseq
        let report = try materializer.apply(records: [result.record])
        guard report.materializedUptoMseq > before else {
            guard !materializer.needsResyncPaths.isEmpty else {
                // The record was taken in but the contiguous watermark could
                // not move and no base mismatch explains it: the accepted mseq
                // sequence has a hole. Advancing here or continuing silently
                // would make materialized_upto skip an unapplied mutation (D8).
                throw LogError.corrupt(
                    "mseq \(result.mseq) was accepted but the materialized watermark "
                        + "\(report.materializedUptoMseq) did not advance and no resync is pending")
            }
            // A deferred base mismatch (D8/D9) takes the record in but holds
            // the contiguous watermark: no new materialized change is waiting
            // to become durable, so this mutation needs neither the D18 step-1
            // fsync nor a manifest rewrite. The resync request it produced
            // still has to reach the Worker.
            emitResyncRequests()
            return
        }
        // wal.md §7.1: the manifest may only name the new watermark after the
        // materialized changes of this batch are durable (D18 step 1).
        try materializer.fsyncEpoch()
        try await writer.recordMaterializedUpto(report.materializedUptoMseq)
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
            // wal.md §7.1: a manifest rewrite may only happen after §5.2
            // step 1 has made every applied mutation durable. Fsync the
            // materialized files and directories of this batch before the
            // manifest can name the new watermark; otherwise a power loss
            // would leave a manifest claiming an applied position whose files
            // and WAL records were lost. An epoch close defers the rewrite to
            // D18 step 5, after the WAL F_FULLFSYNC.
            try materializer.fsyncEpoch()
            if persistManifest {
                try await writer.recordMaterializedUpto(report.materializedUptoMseq)
            } else {
                await writer.setMaterializedUpto(report.materializedUptoMseq)
            }
            recoveryReport.materializedUptoMseq = report.materializedUptoMseq
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
