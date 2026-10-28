// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: quota constants.
//
// PLAN §2.3 and spec/v1/wal.md §9. The WAL is limited to 256 MB and
// the journal to 64 MB. Overflow compacts droppable data first and then fails
// loud with `LogError.quotaExceeded`; nothing is silently evicted.

import Foundation

/// The two quota-managed logs of one workspace.
public struct LogQuota: Equatable, Sendable {
    /// PLAN §2.3: WAL ≤ 256 MB.
    public static let defaultWALBytes = 256 * 1024 * 1024
    /// PLAN §2.3: journal ≤ 64 MB.
    public static let defaultJournalBytes = 64 * 1024 * 1024

    public var walBytes: Int
    public var journalBytes: Int

    public init(walBytes: Int = LogQuota.defaultWALBytes,
                journalBytes: Int = LogQuota.defaultJournalBytes) {
        self.walBytes = walBytes
        self.journalBytes = journalBytes
    }

    public init(configuration: WorkspaceLogConfiguration) {
        self.walBytes = configuration.walQuotaBytes
        self.journalBytes = configuration.journalQuotaBytes
    }

    /// `true` when the WAL usage is over its budget.
    public func isWALExceeded(_ used: Int) -> Bool {
        used > walBytes
    }

    /// `true` when the journal usage is over its budget.
    public func isJournalExceeded(_ used: Int) -> Bool {
        used > journalBytes
    }

    /// Whether compaction must run before `additionalBytes` can be appended.
    public func needsWALCompaction(used: Int, additionalBytes: Int) -> Bool {
        used + additionalBytes > walBytes
    }

    /// Decides the WAL append of `additionalBytes`. Returns `true` when the
    /// caller must compact first; throws `.quotaExceeded` when even dropping
    /// `reclaimableBytes` would not fit.
    public func requireWALSpace(used: Int,
                                additionalBytes: Int,
                                reclaimableBytes: Int) throws -> Bool {
        let projected = used + additionalBytes
        guard projected > walBytes else { return false }
        guard projected - max(reclaimableBytes, 0) <= walBytes else {
            throw LogError.quotaExceeded(resource: .wal,
                                         limit: walBytes,
                                         used: projected)
        }
        return true
    }

    /// The journal has no safe droppable set (the tool journal is the record of
    /// side effects), so an overflow fails loud immediately.
    public func requireJournalSpace(used: Int, additionalBytes: Int) throws {
        let projected = used + additionalBytes
        guard projected <= journalBytes else {
            throw LogError.quotaExceeded(resource: .journal,
                                         limit: journalBytes,
                                         used: projected)
        }
    }
}
