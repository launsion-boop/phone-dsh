// SPDX-License-Identifier: MIT
// Persisted transcript tail (P18, PC-20261110-pclink-workspace-cache).
//
// The app paints the last settled transcript items before the engine or the
// relay answers. This file owns the on-disk shape, the size bounds and the
// legacy reader, so both the phone's historical bare array and the PC's new
// envelope go through one decoder that is unit-tested without the App.

import Foundation

/// One settled transcript row. Only display text is stored: no arguments, no
/// tool output beyond what the row already shows, no credentials.
public struct CachedTranscriptItem: Codable, Equatable, Sendable {
    public var id: String
    /// `ChatItem.Kind` rendered as a stable name; an unknown name is dropped on
    /// read so a future kind cannot corrupt the restore.
    public var kind: String
    public var title: String
    public var text: String

    public init(id: String, kind: String, title: String, text: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
    }
}

/// The versioned on-disk value.
public struct CachedTranscriptSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var v: Int
    public var capturedAtMilliseconds: Double
    public var backend: String
    public var sessionID: String
    /// Durable `seq` this tail ends at, when known. Used to resume the pump and
    /// to decide whether a cached tail is still adjacent to the live log.
    public var lastSeq: UInt64?
    public var items: [CachedTranscriptItem]

    public init(capturedAt: Date, backend: BackendID, sessionID: String,
                lastSeq: UInt64?, items: [CachedTranscriptItem]) {
        self.v = Self.currentVersion
        self.capturedAtMilliseconds = capturedAt.timeIntervalSince1970 * 1_000
        self.backend = backend.storageScope
        self.sessionID = sessionID
        self.lastSeq = lastSeq
        self.items = items
    }

    public var capturedAt: Date {
        Date(timeIntervalSince1970: capturedAtMilliseconds / 1_000)
    }
}

/// Writes bounded snapshots and reads both the envelope and the legacy bare
/// array. Every failure returns `nil`: a corrupt cache never clears the screen.
public enum CachedTranscriptCodec {
    /// Rows kept. The behaviour before this file; the renderer never shows more
    /// than a screenful of history on a cold paint anyway.
    public static let maxItems = 400
    /// File budget. The design bounds one snapshot at 512 KiB; the tail budget
    /// leaves room for JSON structure on top of the text it stores.
    public static let maxFileBytes = 512 * 1024
    /// One row cannot dominate the file (a tool result can be megabytes).
    public static let maxItemCharacters = 4_096

    public static func encode(items: [CachedTranscriptItem],
                              backend: BackendID,
                              sessionID: String,
                              lastSeq: UInt64?,
                              capturedAt: Date = Date()) -> Data? {
        let bounded = bounded(items)
        guard !bounded.isEmpty else { return nil }
        let snapshot = CachedTranscriptSnapshot(capturedAt: capturedAt, backend: backend,
                                               sessionID: sessionID, lastSeq: lastSeq,
                                               items: bounded)
        return try? JSONEncoder().encode(snapshot)
    }

    public static func decode(_ data: Data,
                              backend: BackendID,
                              sessionID: String) -> CachedTranscriptSnapshot? {
        if let snapshot = try? JSONDecoder().decode(CachedTranscriptSnapshot.self, from: data) {
            guard snapshot.v == CachedTranscriptSnapshot.currentVersion,
                  snapshot.sessionID == sessionID,
                  snapshot.backend == backend.storageScope else { return nil }
            return snapshot
        }
        // Legacy: the phone wrote a bare array before the envelope existed. It
        // carries no date, seq or backend, so the caller's scope is the only
        // authority for it.
        guard let legacy = try? JSONDecoder().decode([CachedTranscriptItem].self, from: data),
              !legacy.isEmpty else { return nil }
        return CachedTranscriptSnapshot(capturedAt: Date(timeIntervalSince1970: 0),
                                        backend: backend, sessionID: sessionID,
                                        lastSeq: nil, items: bounded(legacy))
    }

    /// Keeps the newest rows inside both the row and byte budgets. The oldest
    /// rows go first, so the newest exchange always survives.
    public static func bounded(_ items: [CachedTranscriptItem]) -> [CachedTranscriptItem] {
        let trimmed = items.suffix(maxItems).map { item -> CachedTranscriptItem in
            guard item.text.count > maxItemCharacters else { return item }
            var copy = item
            copy.text = String(item.text.prefix(maxItemCharacters)) + "…"
            return copy
        }
        var kept: [CachedTranscriptItem] = []
        var bytes = 0
        // Structural overhead per row: ids, kind, title and JSON punctuation.
        let overhead = 256
        for item in trimmed.reversed() {
            let cost = item.text.utf8.count + item.title.utf8.count
                + item.id.utf8.count + item.kind.utf8.count + overhead
            if bytes + cost > maxFileBytes { break }
            bytes += cost
            kept.append(item)
        }
        return kept.reversed()
    }
}
