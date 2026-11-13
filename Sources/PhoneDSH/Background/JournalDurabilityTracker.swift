// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — durable journal positions for step pruning.
//
// PLAN §2.3/§2.4 (D13/D18), spec/v1/budgets.md §8 and spec/v1/exec.md §7. The
// journal emits a level-2 `JOURNAL_ACK` only after the epoch fsync, and the
// step machine may prune a terminal record only after that point. This tracker
// is the small, lock-isolated projection that turns the ack stream into a
// per-session watermark; it never acknowledges anything itself.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// Latest level-2 journal position per session.
///
/// The host subscribes once per runtime to `WorkspaceLog.journalAcks()` and
/// feeds every ack here. Level-1 acks are ignored: a journal entry that has only
/// been `write()`n is not yet in the discardable set (budgets.md §8).
actor JournalDurabilityTracker {
    private var durableJseqBySession: [String: UInt64] = [:]

    init() {}

    /// Records one cumulative `JOURNAL_ACK`. Only the epoch-fsync level moves
    /// the watermark; replays never lower it.
    func record(_ ack: JournalAck) {
        guard ack.level == .epochFsync else { return }
        durableJseqBySession[ack.sessionID] = max(
            durableJseqBySession[ack.sessionID] ?? 0, ack.uptoJseq)
    }

    /// Highest durable journal position of one session (0 when unknown).
    func durableJseq(sessionID: String) -> UInt64 {
        durableJseqBySession[sessionID] ?? 0
    }

    /// Snapshot for diagnostics and tests.
    func snapshot() -> [String: UInt64] {
        durableJseqBySession
    }
}
