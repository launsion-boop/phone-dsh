// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit

/// The connector kinds the Bot scans. The held-inbox `connector-update` item
/// and the persisted cursor both use these exact raw values.
public enum ConnectorKind: String, Codable, Sendable, Equatable, CaseIterable {
    case gmail
    case github
}

/// One metadata-only row inside a connector update.
///
/// Gmail fills `from`/`subject`; GitHub fills `repo`/`title`. `at` is the
/// message/notification timestamp in milliseconds. No body, snippet, diff or
/// attachment metadata is ever carried: the Bot reads content later through the
/// existing tools when its turn actually needs it.
public struct ConnectorMetadataItem: Codable, Sendable, Equatable {
    public var id: String
    public var at: Int64
    public var from: String?
    public var subject: String?
    public var repo: String?
    public var title: String?

    public init(id: String, at: Int64, from: String? = nil, subject: String? = nil,
                repo: String? = nil, title: String? = nil) {
        self.id = id
        self.at = at
        self.from = from
        self.subject = subject
        self.repo = repo
        self.title = title
    }
}

public enum ConnectorUpdateError: Error, Equatable, Sendable {
    case emptyConnector
    case missingCursor
    case cursorNotAdvanced
    case noItems
    case tooManyItems(Int)
    case duplicateItemID(String)
    case invalidItem
}

/// One durable `connector-update` held-inbox record (the frozen v2 shape).
///
/// Semantic rules from the contract:
/// - `requestId == <connector>:<cursorFrom>:<cursorTo>` is the dedupe key for
///   one cursor interval;
/// - `cursorFrom != cursorTo`; item ids are unique;
/// - `1...20` items and `count == items.count`; no body/content.
public struct ConnectorUpdateRecord: Sendable, Equatable, Codable {
    public static let kind = "connector-update"
    public static let maxItems = 20

    public var connector: ConnectorKind
    public var cursorFrom: String
    public var cursorTo: String
    public var items: [ConnectorMetadataItem]
    public var createdAt: Int64

    private enum CodingKeys: String, CodingKey {
        case connector, cursorFrom, cursorTo, items, createdAt
    }

    public init(connector: ConnectorKind, cursorFrom: String, cursorTo: String,
                items: [ConnectorMetadataItem], createdAt: Int64) throws {
        guard !cursorFrom.isEmpty else { throw ConnectorUpdateError.missingCursor }
        guard !cursorTo.isEmpty else { throw ConnectorUpdateError.missingCursor }
        guard cursorFrom != cursorTo else { throw ConnectorUpdateError.cursorNotAdvanced }
        guard !items.isEmpty else { throw ConnectorUpdateError.noItems }
        guard items.count <= Self.maxItems else {
            throw ConnectorUpdateError.tooManyItems(items.count)
        }
        var seen = Set<String>()
        for item in items {
            guard !item.id.isEmpty else { throw ConnectorUpdateError.invalidItem }
            guard seen.insert(item.id).inserted else {
                throw ConnectorUpdateError.duplicateItemID(item.id)
            }
        }
        self.connector = connector
        self.cursorFrom = cursorFrom
        self.cursorTo = cursorTo
        self.items = items
        self.createdAt = createdAt
    }

    /// The durable payload is decoded through the same validating initializer,
    /// so a corrupted stored record fails closed instead of becoming a held
    /// item with impossible semantics.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            connector: try container.decode(ConnectorKind.self, forKey: .connector),
            cursorFrom: try container.decode(String.self, forKey: .cursorFrom),
            cursorTo: try container.decode(String.self, forKey: .cursorTo),
            items: try container.decode([ConnectorMetadataItem].self, forKey: .items),
            createdAt: try container.decode(Int64.self, forKey: .createdAt))
    }

    public var count: Int { items.count }
    public var requestID: String { "\(connector.rawValue):\(cursorFrom):\(cursorTo)" }
    /// Stable held item and durable event id. It is the cursor interval, so a
    /// crash between the record write and the enqueue replays into the same
    /// item instead of duplicating the update.
    public var itemID: String { Self.kind + ":" + requestID }
    public var digest: String {
        SHA256.hash(data: Data(requestID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The bounded human line the held block renders. Structured fields stay
    /// available on the item; this text is only the short summary and is
    /// escaped by `HeldMessages` like every other host-inserted field.
    public var text: String {
        let noun: String
        switch connector {
        case .gmail: noun = count == 1 ? "new message" : "new messages"
        case .github: noun = count == 1 ? "new notification" : "new notifications"
        }
        return "\(connector.rawValue): \(count) \(noun)"
    }
}

/// The cursor document for one connector.
///
/// The contract freezes `{version, connector, cursor, updatedAt, status,
/// lastError?}`; this type is the in-memory projection of that document. The
/// concrete JSON file store lives in the App wiring and is the only place the
/// on-disk envelope is encoded.
public struct ConnectorCursorState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case established
        case reset
    }

    public enum LastError: String, Codable, Sendable, Equatable {
        case cursorInvalid = "cursor-invalid"
        case cursorRegressed = "cursor-regressed"
        case scanFailed = "scan-failed"
    }

    public var version: Int
    public var connector: ConnectorKind
    public var cursor: String
    public var updatedAt: Int64
    public var status: Status
    public var lastError: LastError?

    public init(connector: ConnectorKind, cursor: String, updatedAt: Int64,
                status: Status = .established, lastError: LastError? = nil) {
        self.version = 1
        self.connector = connector
        self.cursor = cursor
        self.updatedAt = updatedAt
        self.status = status
        self.lastError = lastError
    }
}

/// One connector's delta page from its metadata client.
///
/// `cursor` is the new opaque cursor (Gmail historyId, GitHub
/// since/lastModified projection). `items` is already metadata-only and must
/// respect the 20-item cap; the scanner still truncates defensively.
public struct ConnectorDeltaPage: Sendable, Equatable {
    public var cursor: String
    public var items: [ConnectorMetadataItem]

    public init(cursor: String, items: [ConnectorMetadataItem] = []) {
        self.cursor = cursor
        self.items = items
    }
}

/// Failure classes a metadata client may report. Authorization failures are
/// skipped silently (the settings page already owns that state); an invalid
/// cursor resets to the server's head and emits nothing.
public enum ConnectorClientFailure: Error, Equatable, Sendable {
    case unauthorized
    case cursorInvalid(head: String?)
    case rateLimited
    case unavailable
    case invalidResponse
}

/// A metadata-only delta client for one connector. The App injects the real
/// Gmail/GitHub HTTP clients behind this seam; the Scan logic is pure.
public protocol ConnectorDeltaClient: Sendable {
    var connector: ConnectorKind { get }
    /// Fetch the changes after `cursor`. A nil cursor means "no cursor yet":
    /// the client returns the current server head with no items, which is how
    /// the first scan establishes a baseline without replaying history.
    func fetchDelta(cursor: ConnectorCursorState?) async throws -> ConnectorDeltaPage
}

/// Cursor persistence seam. The production store writes the frozen JSON
/// document; tests use an in-memory implementation.
public protocol ConnectorCursorStoring: Sendable {
    func cursor(for connector: ConnectorKind) async -> ConnectorCursorState?
    func save(_ state: ConnectorCursorState) async throws
    func clear(_ connector: ConnectorKind) async throws
}

/// Durable sink for one update. The implementation must write the record
/// before it enqueues the held item and must return `false` for an interval
/// that is already durable/in the inbox.
public protocol ConnectorUpdateEnqueuing: Sendable {
    func enqueue(_ update: ConnectorUpdateRecord) async throws -> Bool
}

public enum ConnectorScanOutcome: Sendable, Equatable {
    /// No cursor existed; the head was stored and nothing was emitted.
    case baselineEstablished
    /// The server had no new metadata; the cursor may have advanced.
    case noNewItems(cursorAdvanced: Bool)
    /// One `connector-update` record was durably enqueued.
    case enqueued(count: Int)
    /// The same cursor interval was already durable/in the inbox.
    case duplicate(count: Int)
    /// Corrupt, regressed or server-rejected cursor: reset to the head and
    /// emit nothing.
    case reset(reason: String)
    /// Not authorized / throttled: skip without prompting.
    case skipped(reason: String)
    case failed(reason: String)
}

public struct ConnectorScanResult: Sendable, Equatable {
    public var connector: ConnectorKind
    public var outcome: ConnectorScanOutcome

    public init(connector: ConnectorKind, outcome: ConnectorScanOutcome) {
        self.connector = connector
        self.outcome = outcome
    }
}

/// One full scan pass: per-connector outcomes plus the records this pass made
/// newly durable (already enqueued), so the caller can consider a proactive
/// candidate and open the main Bot's held wake without re-reading the store.
public struct ConnectorScanBatch: Sendable, Equatable {
    public var results: [ConnectorScanResult]
    public var enqueued: [ConnectorUpdateRecord]

    public init(results: [ConnectorScanResult] = [], enqueued: [ConnectorUpdateRecord] = []) {
        self.results = results
        self.enqueued = enqueued
    }
}

/// The connector incremental scan (PLAN §2.5).
///
/// Pure orchestration over injected clients/cursors/sink:
/// 1. no stored cursor → fetch the head and only establish the cursor;
/// 2. otherwise fetch metadata after the cursor; an empty page advances the
///    cursor with no held item;
/// 3. a non-empty page becomes exactly one `connector-update` record, capped
///    at 20 unique items, keyed by its cursor interval (write-before-enqueue
///    lives in the sink);
/// 4. the cursor advances only after the sink produced the durable item.
public actor ConnectorDeltaScanner {
    private let clients: [any ConnectorDeltaClient]
    private let cursors: any ConnectorCursorStoring
    private let sink: any ConnectorUpdateEnqueuing
    private let now: @Sendable () -> Int64

    public init(clients: [any ConnectorDeltaClient],
                cursors: any ConnectorCursorStoring,
                sink: any ConnectorUpdateEnqueuing,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1000)
                }) {
        self.clients = clients
        self.cursors = cursors
        self.sink = sink
        self.now = now
    }

    /// Scans every configured connector in order. One connector's failure never
    /// blocks another; the result list preserves the client order.
    public func scanBatch() async -> ConnectorScanBatch {
        var batch = ConnectorScanBatch()
        for client in clients {
            let (outcome, record) = await scan(client)
            batch.results.append(ConnectorScanResult(connector: client.connector,
                                                     outcome: outcome))
            if let record { batch.enqueued.append(record) }
        }
        return batch
    }

    /// Convenience wrapper for callers that only need the outcomes.
    public func scan() async -> [ConnectorScanResult] {
        await scanBatch().results
    }

    private func scan(_ client: any ConnectorDeltaClient)
    async -> (ConnectorScanOutcome, ConnectorUpdateRecord?) {
        let connector = client.connector
        let stored = await cursors.cursor(for: connector)
        do {
            let page = try await client.fetchDelta(cursor: stored)
            return try await apply(page, stored: stored, connector: connector)
        } catch let failure as ConnectorClientFailure {
            return (await handle(failure, connector: connector), nil)
        } catch is CancellationError {
            return (.skipped(reason: "cancelled"), nil)
        } catch {
            // Type names only: a client error can carry a URL or a token
            // fragment and the report is diagnostic surface.
            return (.failed(reason: String(describing: type(of: error))), nil)
        }
    }

    private func apply(_ page: ConnectorDeltaPage, stored: ConnectorCursorState?,
                       connector: ConnectorKind)
    async throws -> (ConnectorScanOutcome, ConnectorUpdateRecord?) {
        guard !page.cursor.isEmpty else {
            return (await markScanFailure(connector: connector, reason: "empty_cursor"), nil)
        }
        let nowMs = now()
        // First scan: establish the cursor, never replay history as new.
        guard let stored, !stored.cursor.isEmpty else {
            try await cursors.save(ConnectorCursorState(
                connector: connector, cursor: page.cursor, updatedAt: nowMs))
            return (.baselineEstablished, nil)
        }
        // An unchanged head means "nothing new since the last scan": keep the
        // cursor and emit nothing. Check it before the regression rule, which
        // must only fire for a cursor that actually moved backwards.
        guard page.cursor != stored.cursor else {
            return (.noNewItems(cursorAdvanced: false), nil)
        }
        if let regression = Self.regression(connector: connector,
                                            previous: stored.cursor,
                                            next: page.cursor) {
            try? await cursors.save(ConnectorCursorState(
                connector: connector, cursor: page.cursor, updatedAt: nowMs,
                status: .reset, lastError: .cursorRegressed))
            return (.reset(reason: regression), nil)
        }
        let items = Self.normalized(page.items)
        guard !items.isEmpty else {
            do {
                try await cursors.save(ConnectorCursorState(
                    connector: connector, cursor: page.cursor, updatedAt: nowMs))
            } catch {
                return (.failed(reason: "cursor_store"), nil)
            }
            return (.noNewItems(cursorAdvanced: true), nil)
        }
        let record: ConnectorUpdateRecord
        do {
            record = try ConnectorUpdateRecord(
                connector: connector, cursorFrom: stored.cursor,
                cursorTo: page.cursor, items: items, createdAt: nowMs)
        } catch {
            return (.failed(reason: "invalid_update"), nil)
        }
        let enqueued: Bool
        do {
            enqueued = try await sink.enqueue(record)
        } catch {
            // The cursor stays where it was; the next scan retries the same
            // interval and the sink's dedupe key prevents a second item.
            return (await markScanFailure(connector: connector, reason: "enqueue"), nil)
        }
        // Only now may the cursor advance. A crash before this write re-scans
        // the interval; the `connector:cursorFrom:cursorTo` key is the dedupe.
        try? await cursors.save(ConnectorCursorState(
            connector: connector, cursor: page.cursor, updatedAt: nowMs))
        return enqueued
            ? (.enqueued(count: items.count), record)
            : (.duplicate(count: items.count), nil)
    }

    private func handle(_ failure: ConnectorClientFailure,
                        connector: ConnectorKind) async -> ConnectorScanOutcome {
        switch failure {
        case .unauthorized:
            // Settings already shows the authorization state; a wake scan never
            // prompts. The stored cursor is kept for a later re-authorization.
            return .skipped(reason: "unauthorized")
        case .rateLimited:
            return .skipped(reason: "rate-limited")
        case .cursorInvalid(let head):
            let nowMs = now()
            if let head, !head.isEmpty {
                try? await cursors.save(ConnectorCursorState(
                    connector: connector, cursor: head, updatedAt: nowMs,
                    status: .reset, lastError: .cursorInvalid))
            } else {
                try? await cursors.clear(connector)
            }
            return .reset(reason: "cursor-invalid")
        case .unavailable:
            return .failed(reason: "unavailable")
        case .invalidResponse:
            return .failed(reason: "invalid_response")
        }
    }

    private func markScanFailure(connector: ConnectorKind,
                                 reason: String) async -> ConnectorScanOutcome {
        if let stored = await cursors.cursor(for: connector) {
            try? await cursors.save(ConnectorCursorState(
                connector: connector, cursor: stored.cursor,
                updatedAt: now(), status: stored.status, lastError: .scanFailed))
        }
        return .failed(reason: reason)
    }

    /// At most 20 unique item ids, order preserved. Duplicate ids inside one
    /// page must not become two rows in one held item.
    static func normalized(_ items: [ConnectorMetadataItem]) -> [ConnectorMetadataItem] {
        var seen = Set<String>()
        var result: [ConnectorMetadataItem] = []
        for item in items where !item.id.isEmpty {
            guard seen.insert(item.id).inserted else { continue }
            result.append(item)
            if result.count == ConnectorUpdateRecord.maxItems { break }
        }
        return result
    }

    /// Gmail history ids are decimal uint64 values: a cursor that goes
    /// backwards is corrupt and must reset to the server's head. GitHub's
    /// opaque watermark has no local ordering, so it is never "regressed" here.
    static func regression(connector: ConnectorKind, previous: String, next: String) -> String? {
        guard connector == .gmail,
              let old = UInt64(previous), let new = UInt64(next) else { return nil }
        return new <= old ? "cursor-regressed" : nil
    }
}
