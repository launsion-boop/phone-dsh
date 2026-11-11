// SPDX-License-Identifier: MIT

import Foundation

/// Read-only diagnostics for the incremental memory replay cache.
///
/// The feed counters (`fullReplayCount`, `incrementalReplayCount`,
/// `scannedEventCount`) are shared by every store attached to the same
/// `SQLiteDomainStore`, so a process scans the durable log once and then reads
/// only the newly committed delta. The store counters (`processedMemoryEventCount`,
/// `skippedEventIDs`, `lastProcessedCommitSeq`) describe one authority's view.
public struct BotMemoryReplayDiagnostics: Sendable, Equatable {
    /// Number of times the shared feed scanned the event log from commit 0.
    /// A stable value across repeated `facts()`/`recall()` calls means reads
    /// are incremental rather than a full replay per call.
    public let fullReplayCount: Int
    /// Number of scans that read newly committed events after the first scan.
    public let incrementalReplayCount: Int
    /// Number of durable events (of any type) read by the shared feed.
    public let scannedEventCount: Int
    /// Number of memory events this store has applied to its replay state.
    public let processedMemoryEventCount: Int
    /// Ids of memory events skipped because their payload did not decode.
    public let skippedEventIDs: [String]
    /// Commit sequence of the newest event applied by this store, or 0.
    public let lastProcessedCommitSeq: Int

    public init(
        fullReplayCount: Int,
        incrementalReplayCount: Int,
        scannedEventCount: Int,
        processedMemoryEventCount: Int,
        skippedEventIDs: [String],
        lastProcessedCommitSeq: Int
    ) {
        self.fullReplayCount = fullReplayCount
        self.incrementalReplayCount = incrementalReplayCount
        self.scannedEventCount = scannedEventCount
        self.processedMemoryEventCount = processedMemoryEventCount
        self.skippedEventIDs = skippedEventIDs
        self.lastProcessedCommitSeq = lastProcessedCommitSeq
    }
}

struct BotMemoryReplayFeedDiagnostics: Sendable, Equatable {
    let fullReplayCount: Int
    let incrementalReplayCount: Int
    let scannedEventCount: Int
}

/// One incremental, append-only view of the memory events (legacy facts and
/// document-tree versions) in a durable log.
///
/// The feed owns the SQLite cursor; each `SQLiteBotMemoryFactStore` keeps its
/// own index into the returned history. Consequently the first store to read
/// pays for the only full SQLite replay, and every other store (including a
/// store created later) consumes the same in-memory history and then only the
/// commit delta. The feed deliberately does not retain the event log: the
/// registry keys it weakly so test/reopened stores do not leak the actor.
actor BotMemoryReplayFeed {
    private let pageSize: Int
    private var cursor = 0
    private var history: [BotEvent] = []
    private var hasScanned = false
    private var fullReplayCount = 0
    private var incrementalReplayCount = 0
    private var scannedEventCount = 0

    init(pageSize: Int) {
        self.pageSize = max(1, pageSize)
    }

    /// Returns memory events starting at `index` and pulls any newly committed
    /// durable events first. `index` is an append-only index into this feed's
    /// history, not a commit sequence.
    func memoryEvents(from index: Int, eventLog: SQLiteDomainStore) async throws -> [BotEvent] {
        let head = try await eventLog.headCommitSeq()
        if !hasScanned {
            hasScanned = true
            fullReplayCount += 1
        } else if head > cursor {
            incrementalReplayCount += 1
        }
        while cursor < head {
            let page = try await eventLog.events(after: cursor, limit: pageSize)
            if page.isEmpty { break }
            for event in page {
                guard let commitSeq = event.commitSeq else {
                    throw BotMemoryFactStoreError.corrupted(
                        "durable memory event has no commitSeq")
                }
                cursor = commitSeq
                scannedEventCount += 1
                switch event.type {
                case "memory.written", "memory.forgotten",
             "memory.document_written", "memory.document_deleted":
                    history.append(event)
                default:
                    break
                }
                if cursor >= head { break }
            }
            if page.count < pageSize { break }
        }
        guard index < history.count else { return [] }
        return Array(history[index...])
    }

    func diagnostics() -> BotMemoryReplayFeedDiagnostics {
        BotMemoryReplayFeedDiagnostics(
            fullReplayCount: fullReplayCount,
            incrementalReplayCount: incrementalReplayCount,
            scannedEventCount: scannedEventCount
        )
    }
}

/// Process-wide registry keyed by durable log identity. Entries hold the log
/// weakly so a closed/reopened store starts from commit 0 with a fresh feed and
/// the previous test's history can be reclaimed.
final class BotMemoryReplayFeedRegistry: @unchecked Sendable {
    static let shared = BotMemoryReplayFeedRegistry()

    private final class Entry {
        weak var eventLog: SQLiteDomainStore?
        let feed: BotMemoryReplayFeed

        init(eventLog: SQLiteDomainStore, feed: BotMemoryReplayFeed) {
            self.eventLog = eventLog
            self.feed = feed
        }
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func feed(for eventLog: SQLiteDomainStore, pageSize: Int) -> BotMemoryReplayFeed {
        lock.lock()
        defer { lock.unlock() }
        purgeDeadEntriesLocked()
        let key = ObjectIdentifier(eventLog)
        if let entry = entries[key], entry.eventLog === eventLog {
            return entry.feed
        }
        let feed = BotMemoryReplayFeed(pageSize: pageSize)
        entries[key] = Entry(eventLog: eventLog, feed: feed)
        return feed
    }

    private func purgeDeadEntriesLocked() {
        guard !entries.isEmpty else { return }
        entries = entries.filter { $0.value.eventLog != nil }
    }
}
