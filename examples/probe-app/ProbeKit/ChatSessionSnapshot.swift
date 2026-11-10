// SPDX-License-Identifier: MIT
// phone-dsh — App-side session list/title snapshot.
//
// The engine owns the authoritative session list, but a foreground resume or a
// cold rebuild takes a second or two. The drawer and the chat title used to be
// empty for that whole window. This value is the last successful projection,
// persisted by the App and rendered immediately; the engine refresh replaces
// it as soon as the session/list answer arrives.

import Foundation

/// One persisted session row. The fields mirror the projection the App needs
/// before the engine is reachable; it is deliberately not the wire schema.
public struct ChatSessionSnapshot: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var updatedAtMilliseconds: Double
        public var running: Bool
        public var blank: Bool
        public var cwd: String?
        public var parentSessionID: String?
        public var searchSnippet: String?

        public init(id: String, title: String, updatedAtMilliseconds: Double,
                    running: Bool, blank: Bool, cwd: String? = nil,
                    parentSessionID: String? = nil, searchSnippet: String? = nil) {
            self.id = id
            self.title = title
            self.updatedAtMilliseconds = updatedAtMilliseconds
            self.running = running
            self.blank = blank
            self.cwd = cwd
            self.parentSessionID = parentSessionID
            self.searchSnippet = searchSnippet
        }
    }

    public struct Workspace: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var path: String
        public var sessionIDs: [String]

        public init(id: String, title: String, path: String, sessionIDs: [String]) {
            self.id = id
            self.title = title
            self.path = path
            self.sessionIDs = sessionIDs
        }
    }

    public var sessions: [Session]
    public var workspaces: [Workspace]
    public var workspaceOrder: [String]
    public var pinnedSessionIDs: [String]
    public var archivedIDs: [String]

    public init(sessions: [Session] = [], workspaces: [Workspace] = [],
                workspaceOrder: [String] = [], pinnedSessionIDs: [String] = [],
                archivedIDs: [String] = []) {
        self.sessions = sessions
        self.workspaces = workspaces
        self.workspaceOrder = workspaceOrder
        self.pinnedSessionIDs = pinnedSessionIDs
        self.archivedIDs = archivedIDs
    }

    /// Stable JSON encoding for UserDefaults; no credential or transcript
    /// content is included.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decodes a previously written snapshot. A corrupt or legacy value is
    /// ignored instead of clearing the live list.
    public static func decode(_ data: Data) -> ChatSessionSnapshot? {
        try? JSONDecoder().decode(ChatSessionSnapshot.self, from: data)
    }

    /// The cached value is only useful while it still names rows; an empty
    /// snapshot is not persisted.
    public var isEmpty: Bool { sessions.isEmpty && workspaces.isEmpty }
}

// MARK: - Persisted roster envelope (P18)

/// Versioned wrapper for a persisted session-list projection.
///
/// `ChatSessionSnapshot` itself stays unwrapped so the phone's pre-existing
/// `dsh.management.sessionSnapshot.v1` value (and any rollback build reading it)
/// keeps working. A PC workspace writes this envelope under
/// `phone-dsh.pc.session-snapshot.<machineId>`, which lets a stale value be
/// dated and a future format be rejected instead of misread
/// (PC-20261110-pclink-pc-roster-snapshot).
public struct CachedSessionSnapshotEnvelope: Codable, Equatable, Sendable {
    /// The only format this build writes. An unknown `v` is ignored on read.
    public static let currentVersion = 1

    public var v: Int
    public var capturedAtMilliseconds: Double
    public var backend: String
    public var payload: ChatSessionSnapshot

    public init(capturedAt: Date, backend: BackendID, payload: ChatSessionSnapshot) {
        self.v = Self.currentVersion
        self.capturedAtMilliseconds = capturedAt.timeIntervalSince1970 * 1_000
        self.backend = backend.storageScope
        self.payload = payload
    }

    public var capturedAt: Date {
        Date(timeIntervalSince1970: capturedAtMilliseconds / 1_000)
    }
}

/// Reads and writes the roster cache. Every read tolerates the bare format so a
/// value written by an older build (or by hand) is still usable, and every
/// failure returns `nil` instead of erasing what is on screen.
public enum CachedSessionSnapshotCodec {
    public struct Stored: Equatable, Sendable {
        public var snapshot: ChatSessionSnapshot
        /// `nil` for a bare (unwrapped) value, which carries no date.
        public var capturedAt: Date?

        public init(snapshot: ChatSessionSnapshot, capturedAt: Date?) {
            self.snapshot = snapshot
            self.capturedAt = capturedAt
        }
    }

    public static func encode(_ snapshot: ChatSessionSnapshot,
                              backend: BackendID,
                              capturedAt: Date) -> Data? {
        guard !snapshot.isEmpty else { return nil }
        let envelope = CachedSessionSnapshotEnvelope(capturedAt: capturedAt,
                                                    backend: backend,
                                                    payload: snapshot)
        return try? JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) -> Stored? {
        if let envelope = try? JSONDecoder().decode(CachedSessionSnapshotEnvelope.self, from: data) {
            guard envelope.v == CachedSessionSnapshotEnvelope.currentVersion else { return nil }
            return Stored(snapshot: envelope.payload, capturedAt: envelope.capturedAt)
        }
        guard let bare = ChatSessionSnapshot.decode(data) else { return nil }
        return Stored(snapshot: bare, capturedAt: nil)
    }
}
