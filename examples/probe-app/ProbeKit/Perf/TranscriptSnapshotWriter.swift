// SPDX-License-Identifier: MIT
// Off-main transcript snapshot writer.
//
// `ChatModel.persistTranscriptSnapshot()` used to filter, map, JSON-encode and
// atomically write the whole transcript on the main actor. The main actor now
// only captures the immutable `items` array (a CoW retain) and this writer does
// the filter/map/encode/write on one serial utility queue. A submit that
// arrives while a write is already queued replaces that queued input, so a
// burst of turn-end / reload calls cannot queue a backlog: the latest snapshot
// wins.
//
// The on-disk format and location are unchanged: `CachedTranscriptCodec.encode`
// produces the bytes and the writer resolves the same WorkspaceStorage URL as
// before, on its own queue.

import Foundation

public final class TranscriptSnapshotWriter {
    public typealias SessionCheck = (BackendID, String) -> Bool

    public static let shared = TranscriptSnapshotWriter()

    public struct Stats: Equatable {
        public var writes: Int
        public var skipped: Int
        public var coalesced: Int
    }

    private struct Job {
        var items: [ChatItem]
        var backend: BackendID
        var sessionID: String
        var lastSeq: UInt64?
        var url: URL?
        var documentsDirectory: URL?
        var capturedAt: Date
        var epoch: UInt64
    }

    private let queue = DispatchQueue(label: "dev.phone-dsh.transcript-snapshot", qos: .utility)
    private let lock = NSLock()
    private let isCurrentSession: SessionCheck
    private var pending: Job?
    private var draining = false
    private var epoch: UInt64 = 0
    private var writes = 0
    private var skipped = 0
    private var coalesced = 0

    /// `isCurrentSession` is the stale-write sequence check. The production
    /// default asks the same durable authority that owns the snapshot path;
    /// tests inject their own session variable.
    public init(isCurrentSession: @escaping SessionCheck = { backend, session in
        WorkspaceStorage.currentSessionID(for: backend) == session
    }) {
        self.isCurrentSession = isCurrentSession
    }

    /// Captures the transcript without doing any O(items) work. Safe to call
    /// from the main actor; returns immediately. The snapshot URL (and its
    /// directory) is resolved on the writer queue.
    public func submit(items: [ChatItem], backend: BackendID, sessionID: String,
                       lastSeq: UInt64?, documentsDirectory: URL? = nil) {
        enqueue(Job(items: items, backend: backend, sessionID: sessionID,
                    lastSeq: lastSeq, url: nil,
                    documentsDirectory: documentsDirectory,
                    capturedAt: Date(), epoch: epoch))
    }

    /// Test seam: writes to an explicit URL. Production uses the overload
    /// above so no filesystem work runs on the caller's actor.
    public func submit(items: [ChatItem], backend: BackendID, sessionID: String,
                       lastSeq: UInt64?, url: URL, capturedAt: Date = Date()) {
        enqueue(Job(items: items, backend: backend, sessionID: sessionID,
                    lastSeq: lastSeq, url: url, documentsDirectory: nil,
                    capturedAt: capturedAt, epoch: epoch))
    }

    private func enqueue(_ job: Job) {
        lock.lock()
        if pending != nil { coalesced += 1 }
        pending = job
        let startDrain = !draining
        if startDrain { draining = true }
        lock.unlock()
        if startDrain {
            queue.async { [weak self] in
                self?.drain()
            }
        }
    }

    /// Drops a queued write and makes every in-flight job from the previous
    /// epoch fail its sequence check. Call on session switch, archive or
    /// local-data erase, before the new session state is published.
    public func invalidate() {
        lock.lock()
        epoch &+= 1
        pending = nil
        lock.unlock()
    }

    /// Blocks until the queue has drained every submit made before the call.
    public func waitForIdle() {
        queue.sync {}
    }

    public func stats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(writes: writes, skipped: skipped, coalesced: coalesced)
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending, job.epoch == epoch else {
                pending = nil
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            perform(job)
        }
    }

    private func perform(_ job: Job) {
        guard isCurrentSession(job.backend, job.sessionID) else {
            lock.lock(); skipped += 1; lock.unlock()
            return
        }
        let destination = job.url ?? WorkspaceStorage.transcriptSnapshotURL(
            for: job.backend, sessionID: job.sessionID,
            documentsDirectory: job.documentsDirectory)
        guard let destination else {
            lock.lock(); skipped += 1; lock.unlock()
            return
        }
        // Display-only interrupted-stream rows are not part of the durable
        // tail. Keeping them out of the snapshot is also what prevents a
        // second launch from painting the draft twice.
        let settled = job.items.filter { !$0.streaming && !$0.isInterruptedDraft }
        guard !settled.isEmpty else { return }
        let cached = settled.map { item in
            CachedTranscriptItem(id: item.id,
                                 kind: item.kind.cachedTranscriptKindName,
                                 title: item.title,
                                 text: item.text)
        }
        guard let data = CachedTranscriptCodec.encode(items: cached,
                                                      backend: job.backend,
                                                      sessionID: job.sessionID,
                                                      lastSeq: job.lastSeq,
                                                      capturedAt: job.capturedAt)
        else { return }

        // Sequence check immediately before touching the filesystem: a switch
        // or erase that happened during the encode must not publish this job.
        lock.lock()
        let stillCurrentEpoch = job.epoch == epoch
        lock.unlock()
        guard stillCurrentEpoch else {
            lock.lock(); skipped += 1; lock.unlock()
            return
        }

        let directory = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        WorkspaceStorage.excludeFromBackup(directory)
        guard (try? data.write(to: destination, options: .atomic)) != nil else { return }

        lock.lock()
        writes += 1
        lock.unlock()

        // Repair the narrow erase race (erase removed the tree between the
        // check above and the write): a file for a session the durable store
        // no longer names is stale local data.
        if !isCurrentSession(job.backend, job.sessionID) {
            try? FileManager.default.removeItem(at: destination)
            lock.lock(); skipped += 1; lock.unlock()
        }

        // The cache is rebuildable: bound it off the main thread so a long
        // history of opened sessions cannot grow without limit (P18).
        let backend = job.backend
        let sessionID = job.sessionID
        Task.detached(priority: .utility) {
            WorkspaceStorage.evictTranscriptSnapshots(for: backend, keeping: sessionID)
        }
    }
}

public extension ChatItem.Kind {
    /// The stable on-disk name used by `CachedTranscriptItem.kind`. Kept in one
    /// place so the writer and the reader cannot drift.
    var cachedTranscriptKindName: String {
        switch self {
        case .user: return "user"
        case .context: return "context"
        case .assistant: return "assistant"
        case .reasoning: return "reasoning"
        case .image: return "image"
        case .toolCall: return "toolCall"
        case .toolResult(let isError): return isError ? "toolError" : "toolResult"
        case .systemEvent: return "systemEvent"
        case .turnError: return "turnError"
        case .maxTokens: return "maxTokens"
        case .unknown: return "unknown"
        case .status: return "status"
        }
    }
}

public enum CachedTranscriptItemKind {
    /// Reads the same stable names back. An unknown name returns nil so a
    /// future row kind cannot corrupt the restore.
    public static func chatKind(from name: String) -> ChatItem.Kind? {
        switch name {
        case "user": return .user
        case "context": return .context
        case "assistant": return .assistant
        case "reasoning": return .reasoning
        case "image": return .image
        case "toolCall": return .toolCall
        case "toolResult": return .toolResult(isError: false)
        case "toolError": return .toolResult(isError: true)
        case "systemEvent": return .systemEvent
        case "turnError": return .turnError
        case "maxTokens": return .maxTokens
        case "unknown": return .unknown
        case "status": return .status
        default: return nil
        }
    }
}
