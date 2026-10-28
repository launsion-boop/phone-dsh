// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the WAL writer.
//
// PLAN §2.3 (D3/D7/D8/D17/D18/D19) and spec/v1/wal.md §1–§5, §9–§10.
// `WALWriter` is the host-side append path: it allocates the persistent mseq,
// batches appends for at most 2 ms or 256 KiB, performs one write() per batch
// segment, resolves level-1 acks, closes epochs with F_FULLFSYNC in the D18
// order and enforces the WAL quota after compaction.

import Darwin
import Foundation
import PhoneDSHWire

/// One accepted append: the host-allocated mseq, the exact WAL record and the
/// level-1 acknowledgement that resolved it.
public struct WALAppendResult: Equatable, Sendable {
    public var mseq: UInt64
    public var record: WALRecord
    public var level: AckLevel
    /// Cumulative level-1 ack that was emitted for this batch.
    public var ackedUptoMseq: UInt64

    public init(mseq: UInt64, record: WALRecord,
                level: AckLevel = .write, ackedUptoMseq: UInt64) {
        self.mseq = mseq
        self.record = record
        self.level = level
        self.ackedUptoMseq = ackedUptoMseq
    }
}

/// Durable state a recovery pass hands to the writer. All fields come from the
/// manifest and the scanned WAL tail (wal.md §7.2, D17).
public struct WALWriterResumeState: Equatable, Sendable {
    public var nextMseq: UInt64
    public var lastMseq: UInt64
    public var durableMseq: UInt64
    public var lastDurableEpoch: UInt64
    public var startEpoch: UInt64
    public var materializedUptoMseq: UInt64
    public var truncatedTornTail: Bool

    public init(nextMseq: UInt64,
                lastMseq: UInt64,
                durableMseq: UInt64,
                lastDurableEpoch: UInt64,
                startEpoch: UInt64,
                materializedUptoMseq: UInt64,
                truncatedTornTail: Bool = false) {
        self.nextMseq = nextMseq
        self.lastMseq = lastMseq
        self.durableMseq = durableMseq
        self.lastDurableEpoch = lastDurableEpoch
        self.startEpoch = startEpoch
        self.materializedUptoMseq = materializedUptoMseq
        self.truncatedTornTail = truncatedTornTail
    }
}

/// Result of closing one epoch (D7/D18).
public struct WALEpochCloseResult: Equatable, Sendable {
    /// Epoch that was closed.
    public var epoch: UInt64
    /// `durable_upto` of the close record / level-2 ack.
    public var durableUpto: UInt64
    /// Largest durable mseq observed so far (this is `acked_mseq`-safe for HELLO
    /// `durable_mseq`).
    public var durableMseq: UInt64
    /// Epoch that is now open.
    public var nextEpoch: UInt64
    /// Segments that were F_FULLFSYNCed by this close.
    public var segments: [String]

    public init(epoch: UInt64, durableUpto: UInt64, durableMseq: UInt64,
                nextEpoch: UInt64, segments: [String]) {
        self.epoch = epoch
        self.durableUpto = durableUpto
        self.durableMseq = durableMseq
        self.nextEpoch = nextEpoch
        self.segments = segments
    }
}

/// The host WAL writer actor (PLAN §2.3).
public actor WALWriter {
    // MARK: Public state

    public let configuration: WorkspaceLogConfiguration
    public let bootID: Data

    /// Next mseq that will be assigned; never reused (D17).
    public private(set) var nextMseq: UInt64
    /// Highest mseq ever allocated and accepted at level 1 (D17 `last_mseq`).
    public private(set) var lastMseq: UInt64
    /// Largest `durable_upto` among closed epochs (HELLO `durable_mseq`).
    public private(set) var durableMseq: UInt64
    /// Most recently closed epoch (manifest `last_durable_epoch`).
    public private(set) var lastDurableEpoch: UInt64
    /// Epoch that currently accepts appends.
    public private(set) var currentEpoch: UInt64
    /// Highest mseq whose batch write() returned (level-1 ack watermark).
    public private(set) var flushedUpto: UInt64
    /// Most recent level-2 ack; `nil` until an epoch has closed.
    public private(set) var lastLevel2Ack: WorkspaceLogAck?
    /// A torn tail was truncated or discarded during open (D19).
    public private(set) var truncatedTornTail: Bool
    /// Bytes dropped by the torn-tail rule during open.
    public private(set) var discardedTornTailBytes: Int

    // MARK: Test-visible counters

    /// Number of `write()` calls issued for record bytes (group-commit tests).
    private(set) var recordWriteCount = 0
    /// Number of record batches flushed.
    private(set) var batchCount = 0

    // MARK: Private state

    private struct SegmentState {
        var name: WALSegmentName
        var url: URL
        var header: WALSegmentHeader
        var byteCount: Int
        var mutationCount: Int
        var lastMutationMseq: UInt64
        var hasEpochClose: Bool
        var closeDurableUpto: UInt64

        /// The lifecycle facts of this segment; the manifest and truncation
        /// decisions are derived from them by ``WALSegmentLifecycle`` only.
        var lifecycle: WALSegmentLifecycleRecord {
            WALSegmentLifecycleRecord(file: name.manifestFile,
                                      epoch: name.epoch,
                                      segment: name.segment,
                                      firstMseq: header.firstMseq,
                                      lastMutationMseq: lastMutationMseq,
                                      hasRecords: mutationCount > 0 || hasEpochClose,
                                      hasEpochClose: hasEpochClose)
        }

        var manifestSegment: ManifestSegment {
            ManifestSegment(file: name.manifestFile,
                            epoch: name.epoch,
                            firstMseq: header.firstMseq,
                            lastMseq: lastMutationMseq)
        }
    }

    private struct PendingAppend {
        var mseq: UInt64
        var record: WALRecord
        var encoded: Data
        var continuation: CheckedContinuation<WALAppendResult, Error>
    }

    private struct BarrierWaiter {
        var upto: UInt64
        var continuation: CheckedContinuation<WorkspaceLogAck, Error>
    }

    private let paths: WorkspacePaths
    private let bootIDHex: String
    private let groupCommitDelay: TimeInterval
    private let groupCommitBytes: Int

    private var segments: [SegmentState]
    /// Epochs with a verified D18 close record. Only these may be truncated
    /// (wal.md §9); the set is rebuilt from the scan on open and extended by
    /// every close this writer performs.
    private var durableEpochs: Set<UInt64> = []
    private var currentSegmentIndex: Int
    private var currentFD: Int32 = -1
    private var epochWrittenSegmentNames: Set<String> = []
    private var materializedUpto: UInt64
    private var pending: [PendingAppend] = []
    private var pendingBytes = 0
    private var flushTask: Task<Void, Never>?
    private var barrierWaiters: [BarrierWaiter] = []
    private var failed = false
    private let ackBroadcaster = AckBroadcaster<WorkspaceLogAck>(replayLimit: 64)

    // MARK: Init / open

    /// Opens the workspace WAL, truncates a torn tail (D19), starts a new epoch
    /// and creates its segment 0. With `resumeState` the writer continues from a
    /// completed recovery pass instead of deriving the state itself.
    public init(configuration: WorkspaceLogConfiguration,
                bootID: Data,
                resumeState: WALWriterResumeState? = nil) throws {
        guard bootID.count == 16 else {
            throw LogError.corrupt("boot_id must be 16 raw bytes")
        }
        self.configuration = configuration
        self.bootID = bootID
        self.bootIDHex = bootID.map { String(format: "%02x", $0) }.joined()
        let workspacePaths = WorkspacePaths(root: configuration.root)
        self.paths = workspacePaths
        self.groupCommitDelay = max(configuration.groupCommitDelay, 0)
        self.groupCommitBytes = max(configuration.groupCommitBytes, 1)
        try workspacePaths.createDirectories()

        let scan = try WALReader.scan(directory: workspacePaths.walDirectory,
                                      truncateTornTail: true)
        let manifestStore = ManifestStore(paths: workspacePaths)
        let manifest = try manifestStore.read()

        var states: [SegmentState] = scan.segments.map { segment in
            SegmentState(name: segment.name,
                         url: segment.url,
                         header: segment.header,
                         byteCount: segment.byteCount,
                         mutationCount: segment.mutationCount,
                         lastMutationMseq: segment.lastMutationMseq,
                         hasEpochClose: segment.hasEpochClose,
                         closeDurableUpto: segment.epochClose?.durableUpto ?? 0)
        }
        let scannedLastMseq = scan.lastMutationMseq
        let resume: WALWriterResumeState
        if let resumeState {
            resume = resumeState
        } else {
            let lastMseq = max(manifest?.lastMseq ?? 0, scannedLastMseq)
            let lastDurableEpoch = max(manifest?.lastDurableEpoch ?? 0, scan.lastDurableEpoch)
            resume = WALWriterResumeState(
                nextMseq: lastMseq + 1,
                lastMseq: lastMseq,
                durableMseq: scan.durableMseq,
                lastDurableEpoch: lastDurableEpoch,
                startEpoch: max(lastDurableEpoch, scan.highestEpoch) + 1,
                materializedUptoMseq: manifest?.materializedUptoMseq ?? 0,
                truncatedTornTail: scan.truncatedTornTail)
        }

        guard resume.nextMseq >= 1, resume.lastMseq < UInt64.max else {
            throw LogError.corrupt("resume state has an invalid mseq range")
        }
        self.nextMseq = resume.nextMseq
        self.lastMseq = resume.lastMseq
        self.flushedUpto = resume.lastMseq
        self.durableMseq = resume.durableMseq
        self.lastDurableEpoch = resume.lastDurableEpoch
        self.currentEpoch = resume.startEpoch
        self.materializedUpto = resume.materializedUptoMseq
        self.durableEpochs = WALSegmentLifecycle.durableEpochs(
            of: states.map(\.lifecycle))
        self.truncatedTornTail = resume.truncatedTornTail || scan.truncatedTornTail
        self.discardedTornTailBytes = scan.discardedBytes
        let created = try WALWriter.createSegmentFile(paths: workspacePaths,
                                                      bootID: bootID,
                                                      epoch: resume.startEpoch,
                                                      segment: 0,
                                                      firstMseq: resume.nextMseq)
        states.append(created.state)
        self.segments = states
        self.currentSegmentIndex = states.count - 1
        self.currentFD = created.descriptor
    }

    /// Opens a writer over a workspace directory, truncating a torn tail and
    /// starting a new epoch (D19, wal.md §1).
    public static func open(configuration: WorkspaceLogConfiguration,
                            bootID: Data,
                            resumeState: WALWriterResumeState? = nil) throws -> WALWriter {
        try WALWriter(configuration: configuration,
                      bootID: bootID,
                      resumeState: resumeState)
    }

    deinit {
        if currentFD >= 0 {
            Darwin.close(currentFD)
        }
    }

    // MARK: Appends

    /// Appends one structurally validated mutation and returns its mseq after
    /// the group-commit write() completed (level 1).
    public func append(_ mutation: VfsMutationBody) async throws -> UInt64 {
        try await appendWithRecord(mutation).mseq
    }

    /// Appends one mutation and returns the record together with the level-1
    /// ack that resolved it.
    public func appendWithRecord(_ mutation: VfsMutationBody) async throws -> WALAppendResult {
        guard !failed else { throw LogError.closed }
        try mutation.validate()

        let mseq = nextMseq
        let record = try WALRecord(mseq: mseq, mutation: mutation)
        let encoded = record.encoded()
        try enforceQuota(additionalBytes: encoded.count)
        // Terminal seals discard a header-only tail segment (G2-FIX-69/120);
        // the next append opens the epoch again with the same epoch number.
        try ensureOpenSegment(firstMseq: mseq)

        nextMseq = mseq + 1
        lastMseq = mseq

        return try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingAppend(mseq: mseq,
                                         record: record,
                                         encoded: encoded,
                                         continuation: continuation))
            pendingBytes += encoded.count
            if pendingBytes >= groupCommitBytes {
                flushPending()
            } else {
                scheduleFlush()
            }
        }
    }

    /// Flushes every pending append now (level 1).
    public func flush() async throws {
        if failed { throw LogError.closed }
        flushPending()
        if failed { throw LogError.closed }
    }

    /// Waits for a cumulative ack at `level`. A level-1 barrier resolves once the
    /// write() of `upto` returned; a level-2 barrier closes the epoch if no
    /// durable ack covers `upto` yet.
    public func barrier(level: AckLevel, upto: UInt64) async throws -> WorkspaceLogAck {
        guard !failed else { throw LogError.closed }
        guard upto <= lastMseq else {
            throw LogError.invalidBarrier("mseq \(upto) was not appended (last \(lastMseq))")
        }
        switch level {
        case .write:
            if flushedUpto >= upto {
                return WorkspaceLogAck(level: .write, uptoMseq: flushedUpto)
            }
            return try await withCheckedThrowingContinuation { continuation in
                barrierWaiters.append(BarrierWaiter(upto: upto, continuation: continuation))
            }
        case .epochFsync:
            if flushedUpto < upto {
                _ = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<WorkspaceLogAck, Error>) in
                    barrierWaiters.append(BarrierWaiter(upto: upto, continuation: continuation))
                }
            }
            if let lastLevel2Ack, lastLevel2Ack.uptoMseq >= upto {
                return lastLevel2Ack
            }
            let result = try await closeEpoch()
            return WorkspaceLogAck(level: .epochFsync, uptoMseq: result.durableUpto)
        }
    }

    /// The cumulative ack stream: level 1 after every batch, level 2 only after
    /// an epoch close has completed the D18 order.
    public nonisolated func acks() -> AsyncStream<WorkspaceLogAck> {
        ackBroadcaster.stream()
    }

    // MARK: Epoch close (D7/D18)

    /// Closes the current epoch: appends the `op 0xFF` record with
    /// `durable_upto = lastMseq`, F_FULLFSYNCs every segment written in the
    /// epoch, fsyncs `wal/`, advances the epoch, rewrites the manifest and — by
    /// default — emits the level-2 ack.
    public func closeEpoch(emitLevel2Ack: Bool = true) async throws -> WALEpochCloseResult {
        guard !failed else { throw LogError.closed }
        if !pending.isEmpty {
            flushPending()
        }
        guard !failed else { throw LogError.closed }

        let closedEpoch = currentEpoch
        let durableUpto = lastMseq
        // An idle epoch (wal.md §1: header-only segment, close record only)
        // and an epoch re-opened after a terminal seal both need the segment
        // created lazily before the close record is appended.
        try ensureOpenSegment(firstMseq: nextMseq)
        let record = try WALRecord(epochClose: LogFile.currentTimeMilliseconds(),
                                   durableUpto: durableUpto)
        let encoded = record.encoded()
        try LogFile.writeAll(fd: currentFD, data: encoded)
        recordWriteCount += 1
        segments[currentSegmentIndex].byteCount += encoded.count
        segments[currentSegmentIndex].hasEpochClose = true
        segments[currentSegmentIndex].closeDurableUpto = durableUpto
        epochWrittenSegmentNames.insert(segments[currentSegmentIndex].name.fileName)

        // D18 step 3: F_FULLFSYNC every segment written in this epoch. The
        // close record may be the only record of an idle epoch.
        let written = epochWrittenSegmentNames.sorted()
        for fileName in written {
            guard let segment = segments.first(where: { $0.name.fileName == fileName }) else {
                throw LogError.corrupt("epoch segment \(fileName) vanished")
            }
            try LogFile.fullFsync(url: segment.url)
        }
        // D18 step 4.
        try LogFile.fsyncDirectory(paths.walDirectory)

        lastDurableEpoch = max(lastDurableEpoch, closedEpoch)
        durableEpochs.insert(closedEpoch)
        durableMseq = max(durableMseq, durableUpto)
        epochWrittenSegmentNames.removeAll()

        // The next epoch starts with a fresh segment 0 (wal.md §1).
        if currentFD >= 0 {
            Darwin.close(currentFD)
            currentFD = -1
        }
        currentEpoch += 1
        let nextSegment = try makeSegment(epoch: currentEpoch,
                                          segment: 0,
                                          firstMseq: nextMseq)
        segments.append(nextSegment)
        currentSegmentIndex = segments.count - 1

        // D18 step 5: manifest before the level-2 ack.
        try writeManifest()

        let result = WALEpochCloseResult(epoch: closedEpoch,
                                         durableUpto: durableUpto,
                                         durableMseq: durableMseq,
                                         nextEpoch: currentEpoch,
                                         segments: written)
        if emitLevel2Ack {
            confirmEpochDurable(result)
        }
        return result
    }

    /// Emits the level-2 ack for an epoch close that already completed its
    /// fsync and manifest writes. The facade uses this after the journal has
    /// also been epoch-synced, so level 2 covers both logs.
    public func confirmEpochDurable(_ result: WALEpochCloseResult) {
        let ack = WorkspaceLogAck(level: .epochFsync, uptoMseq: result.durableUpto)
        lastLevel2Ack = ack
        ackBroadcaster.yield(ack)
        resolveBarrierWaiters()
    }

    // MARK: Materialized watermark / manifest

    /// Records the strictly contiguous materialized watermark and rewrites the
    /// manifest atomically (wal.md §7.1). The caller must already have made the
    /// materialized changes durable (D18 step 1).
    public func recordMaterializedUpto(_ mseq: UInt64) async throws {
        let updated = max(materializedUpto, mseq)
        guard updated != materializedUpto else { return }
        materializedUpto = updated
        try writeManifest()
    }

    /// Advances the materialized watermark without rewriting the manifest.
    /// Used by the D18 close order, where the manifest is written only after
    /// the WAL segments have been F_FULLFSYNCed (step 5).
    public func setMaterializedUpto(_ mseq: UInt64) {
        materializedUpto = max(materializedUpto, mseq)
    }

    /// The materialized watermark the writer last persisted.
    public var materializedWatermark: UInt64 { materializedUpto }

    // MARK: Quota / compaction (wal.md §9)

    /// Total bytes of the WAL incl. headers.
    public var walByteCount: Int {
        segments.reduce(0) { $0 + $1.byteCount }
    }

    /// Segment file names in `<epoch, segment>` order.
    public func segmentFileNames() -> [String] {
        segments.sorted { $0.name < $1.name }.map(\.name.fileName)
    }

    /// Manifest view of the real WAL: every segment that holds at least one
    /// record (mutation or epoch close), with its actual header/range. The
    /// old epoch filter made the manifest list the previous empty epoch while
    /// `last_mseq`/`materialized_upto_mseq` advanced over an unlisted open
    /// epoch; recovery then unlinked the real segments (G2-A09). Header-only
    /// segments are not content and stay unlisted (wal.md §7).
    public func manifestSegments() -> [ManifestSegment] {
        WALSegmentLifecycle.manifestSegments(segments.map(\.lifecycle))
    }

    /// Drops every droppable segment (wal.md §9): all mutations at or below the
    /// materialized watermark, epoch closed in the D18 order, not the newest
    /// epoch-close segment and not the open epoch. The shorter manifest is
    /// written before the files are unlinked.
    @discardableResult
    public func compactDroppableSegments() throws -> [String] {
        guard !failed else { throw LogError.closed }
        if !pending.isEmpty {
            flushPending()
        }
        guard !failed else { throw LogError.closed }
        // A terminal seal may have discarded the header-only tail segment; the
        // next append recreates it, and there is nothing to compact before then.
        guard currentSegmentIndex >= 0, currentSegmentIndex < segments.count else {
            return []
        }

        let currentFile = segments[currentSegmentIndex].name.manifestFile
        let droppableFiles = Set(WALSegmentLifecycle.droppableRecords(
            segments.map(\.lifecycle),
            materializedUptoMseq: materializedUpto,
            durableEpochs: durableEpochs,
            currentFile: currentFile).map(\.file))
        var dropped: [SegmentState] = []
        var kept: [SegmentState] = []
        for segment in segments {
            if droppableFiles.contains(segment.name.manifestFile) {
                dropped.append(segment)
            } else {
                kept.append(segment)
            }
        }
        guard !dropped.isEmpty else { return [] }

        let previousSegments = segments
        let previousIndex = currentSegmentIndex
        let currentName = segments[currentSegmentIndex].name
        segments = kept
        if let index = kept.firstIndex(where: { $0.name == currentName }) {
            currentSegmentIndex = index
        } else {
            segments = previousSegments
            currentSegmentIndex = previousIndex
            return []
        }
        do {
            try writeManifest()
        } catch {
            segments = previousSegments
            currentSegmentIndex = previousIndex
            throw error
        }
        for segment in dropped {
            try LogFile.unlink(segment.url)
        }
        try LogFile.fsyncDirectory(paths.walDirectory)
        return dropped.map(\.name.fileName)
    }

    private func enforceQuota(additionalBytes: Int) throws {
        // Pending group-commit bytes count against the quota even though they
        // are not part of a segment state yet.
        let projected = walByteCount + pendingBytes + additionalBytes
        guard projected > configuration.walQuotaBytes else { return }
        _ = try compactDroppableSegments()
        let afterCompaction = walByteCount + pendingBytes + additionalBytes
        guard afterCompaction <= configuration.walQuotaBytes else {
            throw LogError.quotaExceeded(resource: .wal,
                                         limit: configuration.walQuotaBytes,
                                         used: afterCompaction)
        }
    }

    private func writeManifest() throws {
        // D17: `last_mseq` is the highest mseq *accepted at level 1*, not an
        // allocation whose batch has not reached the kernel yet. Using
        // `flushedUpto` keeps a crash from persisting an mseq that has no WAL
        // record, which would turn the next worker mseq into a spurious hole.
        let manifest = Manifest(bootID: bootIDHex,
                                materializedUptoMseq: materializedUpto,
                                lastMseq: max(flushedUpto, durableMseq),
                                lastDurableEpoch: lastDurableEpoch,
                                segments: manifestSegments())
        try WALSegmentLifecycle.assertConsistent(
            manifest, knownLastMseq: max(flushedUpto, durableMseq))
        try ManifestStore(paths: paths).write(manifest)
    }

    // MARK: Group commit internals

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let delay = groupCommitDelay
        flushTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.flushFromTimer()
        }
    }

    private func flushFromTimer() {
        flushTask = nil
        flushPending()
    }

    private func flushPending() {
        guard !pending.isEmpty, !failed else { return }
        let batch = pending
        pending.removeAll()
        pendingBytes = 0
        flushTask?.cancel()
        flushTask = nil

        do {
            try write(batch: batch)
            batchCount += 1
            let ack = WorkspaceLogAck(level: .write, uptoMseq: flushedUpto)
            for item in batch {
                item.continuation.resume(returning: WALAppendResult(
                    mseq: item.mseq,
                    record: item.record,
                    level: .write,
                    ackedUptoMseq: flushedUpto))
            }
            ackBroadcaster.yield(ack)
            resolveBarrierWaiters()
        } catch {
            failed = true
            for item in batch {
                item.continuation.resume(throwing: error)
            }
            failBarrierWaiters(error)
        }
    }

    private func write(batch: [PendingAppend]) throws {
        var chunk = Data()
        var chunkRecords = 0
        var chunkLastMseq: UInt64 = 0

        func emitChunk() throws {
            guard !chunk.isEmpty else { return }
            try LogFile.writeAll(fd: currentFD, data: chunk)
            recordWriteCount += 1
            segments[currentSegmentIndex].byteCount += chunk.count
            segments[currentSegmentIndex].mutationCount += chunkRecords
            segments[currentSegmentIndex].lastMutationMseq =
                max(segments[currentSegmentIndex].lastMutationMseq, chunkLastMseq)
            epochWrittenSegmentNames.insert(segments[currentSegmentIndex].name.fileName)
            chunk = Data()
            chunkRecords = 0
            chunkLastMseq = 0
        }

        for item in batch {
            let segment = segments[currentSegmentIndex]
            let segmentHasRecords = segment.mutationCount > 0 || chunkRecords > 0
            if segmentHasRecords,
               segment.byteCount + chunk.count + item.encoded.count > configuration.segmentRollBytes {
                try emitChunk()
                try rotateSegment(firstMseq: item.mseq)
            }
            chunk.append(item.encoded)
            chunkRecords += 1
            chunkLastMseq = item.mseq
        }
        try emitChunk()
        if let last = batch.last {
            flushedUpto = max(flushedUpto, last.mseq)
        }
    }

    private func rotateSegment(firstMseq: UInt64) throws {
        if currentFD >= 0 {
            Darwin.close(currentFD)
            currentFD = -1
        }
        let nextIndex = segments[currentSegmentIndex].name.segment + 1
        let state = try makeSegment(epoch: currentEpoch,
                                    segment: nextIndex,
                                    firstMseq: firstMseq)
        segments.append(state)
        currentSegmentIndex = segments.count - 1
    }

    /// Creates the current epoch's first segment when there is none. A normal
    /// epoch open creates it eagerly for compatibility with the landed tests;
    /// a terminal seal may discard a header-only tail segment, and the next
    /// append/close recreates it here instead of writing to a dead file.
    private func ensureOpenSegment(firstMseq: UInt64) throws {
        guard currentSegmentIndex < 0 || currentSegmentIndex >= segments.count else {
            if currentFD < 0,
               let index = segments.firstIndex(where: { $0.name.epoch == currentEpoch
                   && $0.name.segment == 0 }) {
                let descriptor = try LogFile.open(segments[index].url,
                                                  flags: O_WRONLY | O_APPEND)
                currentFD = descriptor
                currentSegmentIndex = index
            }
            return
        }
        let state = try makeSegment(epoch: currentEpoch, segment: 0, firstMseq: firstMseq)
        segments.append(state)
        currentSegmentIndex = segments.count - 1
    }

    /// Removes the current segment when it holds neither a mutation nor an
    /// epoch-close record. Called by the terminal stop seal so a stopped
    /// workspace never leaves an unlisted header-only tail segment behind
    /// (the parked G2-FIX-69/120 family). The next operation reopens the same
    /// epoch number, so no epoch is skipped.
    @discardableResult
    public func discardCurrentEmptySegment() throws -> String? {
        guard !failed,
              currentSegmentIndex >= 0,
              currentSegmentIndex < segments.count else { return nil }
        let segment = segments[currentSegmentIndex]
        guard segment.mutationCount == 0, !segment.hasEpochClose else { return nil }
        if currentFD >= 0 {
            Darwin.close(currentFD)
            currentFD = -1
        }
        try LogFile.unlink(segment.url)
        segments.remove(at: currentSegmentIndex)
        currentSegmentIndex = -1
        epochWrittenSegmentNames.remove(segment.name.fileName)
        try LogFile.fsyncDirectory(paths.walDirectory)
        return segment.name.fileName
    }

    private func makeSegment(epoch: UInt64,
                             segment: UInt64,
                             firstMseq: UInt64) throws -> SegmentState {
        let created = try Self.createSegmentFile(paths: paths,
                                                 bootID: bootID,
                                                 epoch: epoch,
                                                 segment: segment,
                                                 firstMseq: firstMseq)
        if currentFD >= 0 {
            Darwin.close(currentFD)
        }
        currentFD = created.descriptor
        return created.state
    }

    /// Creates a segment file and returns its state and descriptor. Static so
    /// the nonisolated actor initializer can use it without touching `self`.
    private static func createSegmentFile(paths: WorkspacePaths,
                                          bootID: Data,
                                          epoch: UInt64,
                                          segment: UInt64,
                                          firstMseq: UInt64) throws
        -> (state: SegmentState, descriptor: Int32) {
        let name = try WALSegmentName(epoch: epoch, segment: segment)
        let url = name.url(in: paths.walDirectory)
        let header = try WALSegmentHeader(firstMseq: firstMseq, bootID: bootID)
        let descriptor = try LogFile.open(url,
                                          flags: O_WRONLY | O_CREAT | O_EXCL,
                                          mode: 0o644)
        do {
            try LogFile.writeAll(fd: descriptor, data: header.encoded())
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        let state = SegmentState(name: name,
                                 url: url,
                                 header: header,
                                 byteCount: WALSegmentHeader.byteCount,
                                 mutationCount: 0,
                                 lastMutationMseq: 0,
                                 hasEpochClose: false,
                                 closeDurableUpto: 0)
        return (state, descriptor)
    }

    private func resolveBarrierWaiters() {
        guard !barrierWaiters.isEmpty else { return }
        var remaining: [BarrierWaiter] = []
        for waiter in barrierWaiters {
            if flushedUpto >= waiter.upto {
                let ack: WorkspaceLogAck
                if let lastLevel2Ack, lastLevel2Ack.uptoMseq >= waiter.upto {
                    ack = lastLevel2Ack
                } else {
                    ack = WorkspaceLogAck(level: .write, uptoMseq: flushedUpto)
                }
                waiter.continuation.resume(returning: ack)
            } else {
                remaining.append(waiter)
            }
        }
        barrierWaiters = remaining
    }

    private func failBarrierWaiters(_ error: Error) {
        let waiters = barrierWaiters
        barrierWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }
}

/// Synchronous, fork-safe appender for the W1 crash test.
///
/// After `fork()` only one thread exists and Swift concurrency cannot schedule
/// actor work, so the crash test uses this single-threaded writer. `append`
/// performs exactly one `write()` per record and returns when it did (the same
/// promise as a level-1 ack); callers `_exit(0)` without closing anything. It is
/// not used by the host append path.
public final class WALSynchronousAppender {
    private let paths: WorkspacePaths
    private let bootID: Data
    private let segmentRollBytes: Int
    private var segments: [WALSegmentFile]
    private var currentIndex: Int
    private var currentFD: Int32
    public private(set) var nextMseq: UInt64

    public init(configuration: WorkspaceLogConfiguration, bootID: Data) throws {
        guard bootID.count == 16 else {
            throw LogError.corrupt("boot_id must be 16 raw bytes")
        }
        let paths = WorkspacePaths(root: configuration.root)
        self.paths = paths
        self.bootID = bootID
        self.segmentRollBytes = configuration.segmentRollBytes
        let scanned = try Self.scanPOSIX(directory: paths.walDirectory)
        guard let last = scanned.last else {
            throw LogError.corrupt("no WAL segment to append to")
        }
        self.segments = scanned
        self.currentIndex = scanned.count - 1
        self.nextMseq = (scanned.map(\.lastMutationMseq).max() ?? 0) + 1
        self.currentFD = try LogFile.open(last.url, flags: O_WRONLY | O_APPEND)
    }

    deinit {
        if currentFD >= 0 {
            Darwin.close(currentFD)
        }
    }

    /// Appends one mutation; returns after the record's `write()` returned.
    public func append(_ mutation: VfsMutationBody) throws -> UInt64 {
        try mutation.validate()
        let mseq = nextMseq
        let record = try WALRecord(mseq: mseq, mutation: mutation)
        let encoded = record.encoded()
        var segment = segments[currentIndex]
        if segment.mutationCount > 0,
           segment.byteCount + encoded.count > segmentRollBytes {
            Darwin.close(currentFD)
            let name = try WALSegmentName(epoch: segment.epoch, segment: segment.segment + 1)
            let url = name.url(in: paths.walDirectory)
            let header = try WALSegmentHeader(firstMseq: mseq, bootID: bootID)
            let descriptor = try LogFile.open(url,
                                              flags: O_WRONLY | O_CREAT | O_EXCL,
                                              mode: 0o644)
            do {
                try LogFile.writeAll(fd: descriptor, data: header.encoded())
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            currentFD = descriptor
            segment = WALSegmentFile(name: name,
                                     url: url,
                                     header: header,
                                     records: [],
                                     byteCount: WALSegmentHeader.byteCount,
                                     validByteCount: WALSegmentHeader.byteCount,
                                     tornTailBytes: 0)
            segments.append(segment)
            currentIndex = segments.count - 1
        }
        try LogFile.writeAll(fd: currentFD, data: encoded)
        let updated = WALSegmentFile(name: segment.name,
                                     url: segment.url,
                                     header: segment.header,
                                     records: segment.records + [record],
                                     byteCount: segment.byteCount + encoded.count,
                                     validByteCount: segment.validByteCount + encoded.count,
                                     tornTailBytes: 0)
        segments[currentIndex] = updated
        nextMseq = mseq + 1
        return mseq
    }

    /// Closes the descriptor; the crash-test child never calls this.
    public func close() {
        if currentFD >= 0 {
            Darwin.close(currentFD)
            currentFD = -1
        }
    }

    // MARK: - Fork-safe POSIX scan
    //
    // A forked child may only touch async-signal-safe state, so this scan avoids
    // Foundation's directory and file abstractions and uses opendir/read/close
    // directly. Record decoding itself is pure Swift + Data.

    private static func scanPOSIX(directory: URL) throws -> [WALSegmentFile] {
        guard let directoryHandle = directory.path.withCString({ Darwin.opendir($0) }) else {
            throw LogError.posix(operation: "opendir", code: errno)
        }
        defer { closedir(directoryHandle) }
        var names: [WALSegmentName] = []
        while let entry = readdir(directoryHandle) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 256) {
                    String(cString: $0)
                }
            }
            if let parsed = WALSegmentName(fileName: name) {
                names.append(parsed)
            }
        }
        names.sort()
        var segments: [WALSegmentFile] = []
        for name in names {
            let url = name.url(in: directory)
            let data = try readAllPOSIX(url)
            guard data.count >= WALSegmentHeader.byteCount else { continue }
            let header = try WALSegmentHeader.decode(Data(data.prefix(WALSegmentHeader.byteCount)))
            var records: [WALRecord] = []
            var offset = WALSegmentHeader.byteCount
            while offset + 8 <= data.count {
                let length = Int(data.uint32BigEndian(at: offset))
                guard length >= 8, offset + 8 + length <= data.count else { break }
                let recordData = data.subdata(in: offset..<(offset + 8 + length))
                guard let record = try? WALRecord.decode(recordData) else { break }
                records.append(record)
                offset += 8 + length
            }
            segments.append(WALSegmentFile(name: name,
                                           url: url,
                                           header: header,
                                           records: records,
                                           byteCount: data.count,
                                           validByteCount: offset,
                                           tornTailBytes: data.count - offset))
        }
        return segments
    }

    private static func readAllPOSIX(_ url: URL) throws -> Data {
        let descriptor = try LogFile.open(url, flags: O_RDONLY)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw LogError.posix(operation: "fstat", code: errno)
        }
        let size = Int(info.st_size)
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < size {
                let count = Darwin.read(descriptor, base.advanced(by: offset), size - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw LogError.posix(operation: "read", code: errno)
                }
                if count == 0 { break }
                offset += count
            }
            if offset != size {
                throw LogError.posix(operation: "read", code: EIO)
            }
        }
        return data
    }
}
