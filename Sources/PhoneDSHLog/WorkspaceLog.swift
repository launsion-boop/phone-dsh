// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: WAL v1, epochs and
// materialization.
//
// PLAN §2.3 (D7/D8/D9/D11/D17/D18/D19) and spec/v1/wal.md. This module
// owns the workspace directory under `Library/xl/<workspace_id>/`: WAL segment
// append, group commit and the two ack levels, epoch close with the fixed fsync
// order, the materialized copy, the boot overlay and cold recovery. The
// in-memory VFS stays the single authority; the WAL is its recovery log.
//
// W1-LOG owns the implementation; the types below are the public surface the
// loopback channel and the task controller consume.

import Foundation
import PhoneDSHWire

/// Acknowledgement levels of WAL v1 (PLAN §2.3, channel.md §3.2).
public enum AckLevel: UInt8, CaseIterable, Codable, Sendable {
    /// `write()` returned; a process kill does not lose the bytes.
    case write = 1
    /// The epoch closed with `F_FULLFSYNC` in the D18 order.
    case epochFsync = 2

    /// The channel representation of this level.
    public var wireLevel: PhoneDSHWire.AckLevel {
        switch self {
        case .write: return .write
        case .epochFsync: return .epochFsync
        }
    }

    /// Builds a log level from the channel representation.
    public init(wireLevel: PhoneDSHWire.AckLevel) {
        switch wireLevel {
        case .write: self = .write
        case .epochFsync: self = .epochFsync
        }
    }
}

/// One cumulative workspace acknowledgement.
public struct WorkspaceLogAck: Equatable, Sendable {
    public var level: AckLevel
    public var uptoMseq: UInt64

    public init(level: AckLevel, uptoMseq: UInt64) {
        self.level = level
        self.uptoMseq = uptoMseq
    }

    /// The VFS_ACK body sent on the ordered channel.
    public var wireBody: VfsAckBody {
        VfsAckBody(level: level.wireLevel, uptoMseq: uptoMseq)
    }
}

/// Configuration of one workspace log (PLAN §2.3, wal.md §1).
public struct WorkspaceLogConfiguration: Equatable, Sendable {
    /// Quotas of PLAN §2.3; an exceeded quota compacts droppable data first and
    /// then fails loud.
    public static let defaultWALQuotaBytes = 256 * 1024 * 1024
    public static let defaultJournalQuotaBytes = 64 * 1024 * 1024
    public static let defaultResponseLogQuotaBytes = 128 * 1024 * 1024
    /// A segment rolls before a mutation that would exceed 8 MiB (wal.md §1).
    public static let defaultSegmentRollBytes = 8 * 1024 * 1024
    /// Default single-file budget; budgets.md §4 (8 GiB tier). The host passes
    /// the tier/configured `single_file_limit` through the same field.
    public static let defaultSingleFileLimitBytes = WireLimits.defaultSingleFileLimitBytes
    /// An epoch closes every 30–60 s (D7); the codec default is 45 s.
    public static let defaultEpochIntervalSeconds: TimeInterval = 45
    public static let minimumEpochIntervalSeconds: TimeInterval = 30
    public static let maximumEpochIntervalSeconds: TimeInterval = 60
    /// Group-commit window and byte threshold (wal.md §5, PLAN §2.2).
    public static let defaultGroupCommitDelaySeconds: TimeInterval = 0.002
    public static let defaultGroupCommitBytes = 256 * 1024

    /// Workspace root, `Library/xl/<workspace_id>/`.
    public var root: URL
    public var walQuotaBytes: Int
    public var journalQuotaBytes: Int
    public var responseLogQuotaBytes: Int
    public var segmentRollBytes: Int
    /// Largest logical file the VFS may publish. One mutation carries at most
    /// `WireLimits.maxMutationDataBytes`, so a larger file arrives as a complete
    /// write plus appended suffixes; the host tracks the accepted logical size
    /// and refuses a chunk that would grow a file past this value
    /// (budgets.md §4).
    public var singleFileLimitBytes: Int
    public var epochIntervalSeconds: TimeInterval
    /// Longest time an append waits for a group-commit batch (2 ms).
    public var groupCommitDelay: TimeInterval
    /// Bytes that force an immediate group-commit flush (256 KiB).
    public var groupCommitBytes: Int

    public init(root: URL,
                walQuotaBytes: Int = WorkspaceLogConfiguration.defaultWALQuotaBytes,
                journalQuotaBytes: Int = WorkspaceLogConfiguration.defaultJournalQuotaBytes,
                responseLogQuotaBytes: Int = WorkspaceLogConfiguration.defaultResponseLogQuotaBytes,
                segmentRollBytes: Int = WorkspaceLogConfiguration.defaultSegmentRollBytes,
                singleFileLimitBytes: Int = WorkspaceLogConfiguration.defaultSingleFileLimitBytes,
                epochIntervalSeconds: TimeInterval = WorkspaceLogConfiguration.defaultEpochIntervalSeconds,
                groupCommitDelay: TimeInterval = WorkspaceLogConfiguration.defaultGroupCommitDelaySeconds,
                groupCommitBytes: Int = WorkspaceLogConfiguration.defaultGroupCommitBytes) {
        self.root = root
        self.walQuotaBytes = walQuotaBytes
        self.journalQuotaBytes = journalQuotaBytes
        self.responseLogQuotaBytes = responseLogQuotaBytes
        self.segmentRollBytes = segmentRollBytes
        self.singleFileLimitBytes = singleFileLimitBytes
        self.epochIntervalSeconds = epochIntervalSeconds
        self.groupCommitDelay = groupCommitDelay
        self.groupCommitBytes = groupCommitBytes
    }
}

/// Result of cold recovery (wal.md §10): the durable positions the host needs
/// for HELLO (`next_mseq`, `acked_mseq`, `durable_mseq`).
public struct WorkspaceLogRecovery: Equatable, Sendable {
    public var materializedUptoMseq: UInt64
    public var nextMseq: UInt64
    public var durableMseq: UInt64
    public var lastDurableEpoch: UInt64
    public var truncatedTornTail: Bool
    /// Effective WAL tail `max(last_mseq, WAL tail)`; HELLO `acked_mseq` (D17).
    public var ackedMseq: UInt64
    /// Epoch the writer opens after recovery.
    public var nextEpoch: UInt64
    /// Number of WAL records replayed into the materialized copy.
    public var replayedRecords: Int
    /// Segments removed by recovery truncation/compaction.
    public var droppedSegments: [String]
    /// Paths whose appended base did not match; the host requests VFS_RESYNC.
    public var needsResync: [String]
    /// This process boot differs from the manifest boot (wal.md §10).
    public var coldRecovery: Bool
    /// A staged reconcile was redone because of `reconcile.inprogress`.
    public var reconciled: Bool
    /// Derived boot-metadata paths restored in place from a retained complete
    /// base when the WAL history had been compacted below mseq 1. This is a
    /// diagnostic only; the WAL watermark and all other paths are unchanged.
    public var localRepairs: [MaterializedInvariantLocalRepair]

    public init(materializedUptoMseq: UInt64,
                nextMseq: UInt64,
                durableMseq: UInt64,
                lastDurableEpoch: UInt64,
                truncatedTornTail: Bool = false,
                ackedMseq: UInt64 = 0,
                nextEpoch: UInt64 = 1,
                replayedRecords: Int = 0,
                droppedSegments: [String] = [],
                needsResync: [String] = [],
                coldRecovery: Bool = false,
                reconciled: Bool = false,
                localRepairs: [MaterializedInvariantLocalRepair] = []) {
        self.materializedUptoMseq = materializedUptoMseq
        self.nextMseq = nextMseq
        self.durableMseq = durableMseq
        self.lastDurableEpoch = lastDurableEpoch
        self.truncatedTornTail = truncatedTornTail
        self.ackedMseq = ackedMseq
        self.nextEpoch = nextEpoch
        self.replayedRecords = replayedRecords
        self.droppedSegments = droppedSegments
        self.needsResync = needsResync
        self.coldRecovery = coldRecovery
        self.reconciled = reconciled
        self.localRepairs = localRepairs
    }
}

/// The recovery report of `WorkspaceLog.recover()` (wal.md §10).
public typealias RecoveryReport = WorkspaceLogRecovery

/// The workspace log service used by the loopback channel and the task
/// controller. Implemented by `WorkspaceLog`.
public protocol WorkspaceLogging: Sendable {
    /// Appends one accepted mutation to the WAL and returns the host-allocated
    /// mseq. The append must return only after `write()` completed (level 1).
    func append(_ mutation: VfsMutationBody) async throws -> UInt64

    /// Cumulative acknowledgements, coalesced by the 2 ms group commit and by
    /// epoch close (level 2 only). A subscriber that starts after an append or
    /// close first receives the retained recent acks, so the current watermark
    /// is never missed.
    func acks() -> AsyncStream<WorkspaceLogAck>

    /// Closes the current epoch in the D18 order and returns the level-2 ack
    /// for `durable_upto`.
    func closeEpoch() async throws -> WorkspaceLogAck

    /// Applies the WAL prefix to the materialized copy and returns the new
    /// strictly contiguous `materialized_upto_mseq`.
    func materialize() async throws -> UInt64

    /// Waits for a cumulative ack at `level` for `upto`.
    func barrier(level: AckLevel, upto: UInt64) async throws -> WorkspaceLogAck

    /// Packs `materialized/home/` and `materialized/workspace/` as a
    /// gzip-compressed ustar overlay (wal.md §8, D21).
    func packOverlay() async throws -> Data

    /// Cold recovery: manifest, segment scan, torn-tail truncation and replay.
    func recover() async throws -> WorkspaceLogRecovery
}
