// SPDX-License-Identifier: MIT
// Off-main writer for the interrupted-stream draft.
//
// The visible stream is applied on the main actor, but the draft is captured as
// a tiny value copy of the current streaming rows and written on one serial
// utility queue. Writes are throttled to one per second per session; the App's
// scene-phase hook and a turn boundary force an immediate flush. The main actor
// never encodes JSON and never touches the filesystem here.

import Foundation
import ProbeKit

public final class NativeStreamDraftStore {
    public static let shared = NativeStreamDraftStore()

    public struct Stats: Equatable {
        public var writes: Int
        public var skipped: Int
        public var consumed: Int
        public var coalesced: Int
    }

    private struct Key: Hashable {
        var backend: BackendID
        var sessionID: String
    }

    private struct Pending {
        var rows: [NativeStreamDraftItem]
        var force: Bool
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let documentsDirectory: URL?
    private let now: () -> Date
    private let writeInterval: TimeInterval
    private var latest: [Key: Pending] = [:]
    private var lastWrite: [Key: Date] = [:]
    private var draining = false
    private var writes = 0
    private var skipped = 0
    private var consumed = 0
    private var coalesced = 0

    /// `documentsDirectory` and `now` are test seams. Production resolves the
    /// same `WorkspaceStorage` path the transcript snapshot uses.
    public init(documentsDirectory: URL? = nil,
                writeInterval: TimeInterval = 1,
                now: @escaping () -> Date = Date.init,
                queue: DispatchQueue = DispatchQueue(label: "dev.phone-dsh.stream-draft",
                                                     qos: .utility)) {
        self.documentsDirectory = documentsDirectory
        self.writeInterval = writeInterval
        self.now = now
        self.queue = queue
    }

    /// Captures the current streaming rows. Safe on the main actor; the rows
    /// array holds at most one assistant and one reasoning row, so this is a
    /// value copy of the live text, not a transcript scan.
    public func submit(rows: [NativeStreamDraftItem],
                       backend: BackendID,
                       sessionID: String,
                       flushNow: Bool = false) {
        let key = Key(backend: backend, sessionID: sessionID)
        var startDrain = false
        lock.lock()
        if latest[key] != nil { coalesced += 1 }
        latest[key] = Pending(rows: rows, force: flushNow)
        let timestamp = now()
        let due = rows.isEmpty || flushNow
            || lastWrite[key].map { timestamp.timeIntervalSince($0) >= writeInterval } ?? true
        if due {
            if !draining {
                draining = true
                startDrain = true
            }
        } else {
            skipped += 1
        }
        lock.unlock()
        if startDrain {
            queue.async { [weak self] in self?.drain() }
        }
    }

    /// Drops any queued write for the session and deletes its draft file.
    public func delete(backend: BackendID, sessionID: String) {
        let key = Key(backend: backend, sessionID: sessionID)
        lock.lock()
        latest[key] = Pending(rows: [], force: true)
        let startDrain = !draining
        if startDrain { draining = true }
        lock.unlock()
        if startDrain {
            queue.async { [weak self] in self?.drain() }
        }
    }

    /// Removes the rows a reload found settled or covered by durable text. A
    /// row that was merely shown stays on disk for the next relaunch. The
    /// read-modify-write happens on the writer queue so it cannot race a
    /// streamed write for a new turn.
    public func consume(backend: BackendID, sessionID: String, itemIDs: [String]) {
        guard !itemIDs.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let key = Key(backend: backend, sessionID: sessionID)
            self.lock.lock()
            if var pending = self.latest[key] {
                let removed = Set(itemIDs)
                pending.rows.removeAll { removed.contains($0.itemID) }
                self.latest[key] = pending
            }
            self.lock.unlock()

            guard let file = self.read(backend: backend, sessionID: sessionID) else { return }
            let removed = Set(itemIDs)
            let remaining = file.items.filter { !removed.contains($0.itemID) }
            self.write(remaining, backend: backend, sessionID: sessionID)
            self.lock.lock()
            self.consumed += file.items.count - remaining.count
            self.lock.unlock()
        }
    }

    /// Synchronous read used by the history loader on its own detached task.
    /// It never waits for a queued write and treats any bad/foreign file as
    /// absent; a corrupt draft never blocks the transcript.
    public func load(backend: BackendID, sessionID: String) -> NativeStreamDraftFile? {
        guard let url = WorkspaceStorage.streamDraftURL(
            for: backend, sessionID: sessionID,
            documentsDirectory: documentsDirectory),
            let data = try? Data(contentsOf: url) else { return nil }
        return NativeStreamDraftCodec.decode(data, backend: backend, sessionID: sessionID)
    }

    /// Blocks until every submit/consume made before the call has drained.
    /// Test seam only; production never waits on this queue.
    public func waitForIdle() {
        queue.sync {}
    }

    public func stats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(writes: writes, skipped: skipped, consumed: consumed,
                     coalesced: coalesced)
    }

    private func drain() {
        while true {
            let timestamp = now()
            var jobs: [(Key, [NativeStreamDraftItem])] = []
            lock.lock()
            for (key, pending) in latest {
                let due = pending.rows.isEmpty || pending.force
                    || lastWrite[key].map {
                        timestamp.timeIntervalSince($0) >= writeInterval
                    } ?? true
                guard due else { continue }
                jobs.append((key, pending.rows))
                latest[key] = nil
            }
            if jobs.isEmpty {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()

            for (key, rows) in jobs {
                write(rows, backend: key.backend, sessionID: key.sessionID)
                lock.lock()
                // A settle/erase removed the file: the next new stream is the
                // first write of a fresh draft and must not wait a second.
                lastWrite[key] = rows.isEmpty ? nil : now()
                lock.unlock()
            }
        }
    }

    private func write(_ rows: [NativeStreamDraftItem],
                       backend: BackendID,
                       sessionID: String) {
        guard let url = WorkspaceStorage.streamDraftURL(
            for: backend, sessionID: sessionID,
            documentsDirectory: documentsDirectory) else {
            lock.lock(); skipped += 1; lock.unlock()
            return
        }
        guard !rows.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = NativeStreamDraftCodec.encode(items: rows,
                                                       backend: backend,
                                                       sessionID: sessionID)
        else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        WorkspaceStorage.excludeFromBackup(directory)
        guard (try? data.write(to: url, options: .atomic)) != nil else {
            lock.lock(); skipped += 1; lock.unlock()
            return
        }
        lock.lock()
        writes += 1
        lock.unlock()
    }

    private func read(backend: BackendID,
                      sessionID: String) -> NativeStreamDraftFile? {
        guard let url = WorkspaceStorage.streamDraftURL(
            for: backend, sessionID: sessionID,
            documentsDirectory: documentsDirectory),
            let data = try? Data(contentsOf: url) else { return nil }
        return NativeStreamDraftCodec.decode(data, backend: backend, sessionID: sessionID)
    }
}
