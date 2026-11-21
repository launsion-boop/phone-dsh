// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit

/// The connector kinds the Bot scans. The held-inbox `connector-update` item,
/// the persisted cursor and the wake-demand key all use these raw values.
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
public struct ConnectorMetadataItem: Sendable, Equatable {
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

extension ConnectorMetadataItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, at, from, subject, repo, title
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        let allowed: Set<String> = ["id", "at", "from", "subject", "repo", "title"]
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw ConnectorUpdateError.invalidItem
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(Int64.self, forKey: .at)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(from, forKey: .from)
        try c.encodeIfPresent(subject, forKey: .subject)
        try c.encodeIfPresent(repo, forKey: .repo)
        try c.encodeIfPresent(title, forKey: .title)
    }

    public func validate() throws {
        guard !id.isEmpty, id.unicodeScalars.count <= 256 else {
            throw ConnectorUpdateError.invalidItem
        }
        guard at >= 0 else { throw ConnectorUpdateError.invalidItem }
        for value in [from, subject, repo, title].compactMap({ $0 })
        where value.unicodeScalars.count > 512 {
            throw ConnectorUpdateError.invalidItem
        }
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

/// One durable `connector-update` held-inbox record (contract §3.3.1).
///
/// Semantic rules: `requestId == <connector>:<cursorFrom>:<cursorTo>` is the
/// dedupe key for one cursor interval; `cursorFrom != cursorTo`; item ids are
/// unique; `1...20` items and `count == items.count`; no body/content.
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
        try Self.validateItems(items, connector: connector)
        try Self.validateCursor(cursorFrom, connector: connector)
        try Self.validateCursor(cursorTo, connector: connector)
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

    /// The bounded human line the held block renders from the structured item.
    public var text: String {
        let noun: String
        switch connector {
        case .gmail: noun = count == 1 ? "new message" : "new messages"
        case .github: noun = count == 1 ? "new notification" : "new notifications"
        }
        let cursor: String
        switch connector {
        case .gmail: cursor = "since history \(cursorFrom)"
        case .github: cursor = "since \(cursorFrom)"
        }
        return "\(connector.rawValue.capitalized): \(count) \(noun) \(cursor)."
    }

    /// The held-item schema validates cursor shapes per connector, so the
    /// shared factory rejects a wrong endpoint before it can be stored.
    public static func validateCursor(_ value: String, connector: ConnectorKind) throws {
        guard value.unicodeScalars.count <= ConnectorCursorCodec.maxCursorLength else {
            throw ConnectorUpdateError.invalidItem
        }
        switch connector {
        case .gmail:
            guard ConnectorCursorCodec.isValidHistoryId(value) else {
                throw ConnectorUpdateError.invalidItem
            }
        case .github:
            guard ConnectorCursorCodec.isValidSince(value) else {
                throw ConnectorUpdateError.invalidItem
            }
        }
    }

    static func validateItems(_ items: [ConnectorMetadataItem],
                              connector: ConnectorKind) throws {
        var seen = Set<String>()
        for item in items {
            guard !item.id.isEmpty else { throw ConnectorUpdateError.invalidItem }
            guard seen.insert(item.id).inserted else {
                throw ConnectorUpdateError.duplicateItemID(item.id)
            }
            try item.validate()
            switch connector {
            case .gmail:
                // Gmail's metadata members are from/subject; a repo/title is a
                // wrong-connector member and the closed schema rejects it.
                guard item.repo == nil, item.title == nil else {
                    throw ConnectorUpdateError.invalidItem
                }
            case .github:
                guard item.from == nil, item.subject == nil else {
                    throw ConnectorUpdateError.invalidItem
                }
            }
        }
    }
}

/// One connector's delta page: the upstream head plus metadata-only items.
public struct ConnectorDeltaPage: Sendable, Equatable {
    public var head: ConnectorCursorValue
    public var items: [ConnectorMetadataItem]

    public init(head: ConnectorCursorValue, items: [ConnectorMetadataItem] = []) {
        self.head = head
        self.items = items
    }
}

/// Failure classes a metadata client may report. An authorization failure is
/// skipped silently (the settings page already owns that state); an invalid
/// cursor resets to the server's head and emits nothing.
public enum ConnectorClientFailure: Error, Equatable, Sendable {
    case unauthorized
    case cursorInvalid(head: ConnectorCursorValue?)
    case rateLimited
    case unavailable
    case invalidResponse
}

/// A metadata-only delta client for one connector. The App injects the real
/// Gmail/GitHub HTTP clients behind this seam; the scan logic is pure.
public protocol ConnectorDeltaClient: Sendable {
    var connector: ConnectorKind { get }
    /// Fetch the head and changes after `cursor`. A nil cursor means "no usable
    /// cursor": the client returns the current server head with no items, which
    /// is how the first scan (and a corrupt/reset cursor) establishes a
    /// baseline without replaying history as new.
    func fetchDelta(cursor: ConnectorCursorState?) async throws -> ConnectorDeltaPage
}

/// Cursor persistence seam. The production store writes the frozen JSON
/// document; tests use an in-memory implementation.
///
/// `load` throws when the record exists but cannot be read (for example data
/// protection before the first unlock after a reboot). That is neither
/// "absent" nor "corrupt": the scan must be skipped with `gate`, leave the
/// file untouched, and retry after unlock.
public protocol ConnectorCursorStoring: Sendable {
    func load(_ connector: ConnectorKind) async throws -> ConnectorCursorLoad
    func save(_ state: ConnectorCursorState) async throws
    func clear(_ connector: ConnectorKind) async throws
}

/// Durable sink for one update. The implementation must write the record
/// before it enqueues the held item and must return `false` for an interval
/// that is already durable/in the inbox.
public protocol ConnectorUpdateEnqueuing: Sendable {
    func enqueue(_ record: ConnectorUpdateRecord) async throws -> Bool
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
/// What one completed connector step produced: the per-connector results and
/// the records this pass newly made durable. The step uses `results` to tell a
/// fully gated pass (all connectors unreadable) from a pass that did work.
public struct ConnectorSweepResult: Sendable, Equatable {
    public var results: [ConnectorScanResult]
    public var enqueued: [ConnectorUpdateRecord]

    public init(results: [ConnectorScanResult] = [], enqueued: [ConnectorUpdateRecord] = []) {
        self.results = results
        self.enqueued = enqueued
    }
}

public struct ConnectorScanBatch: Sendable, Equatable {
    public var results: [ConnectorScanResult]
    public var enqueued: [ConnectorUpdateRecord]

    public init(results: [ConnectorScanResult] = [], enqueued: [ConnectorUpdateRecord] = []) {
        self.results = results
        self.enqueued = enqueued
    }
}

/// The connector incremental scan (PLAN §2.5, contract §3.3).
///
/// Pure orchestration over injected clients/cursors/sink:
/// 1. no stored cursor → fetch the head and only establish the cursor;
/// 2. otherwise fetch metadata after the cursor; an empty result persists the
///    new head without a held item;
/// 3. a Gmail historyId / GitHub `since` advance becomes exactly one
///    `connector-update` record, capped at 20 unique items, keyed by its cursor
///    interval (write-before-enqueue lives in the sink);
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
        let load: ConnectorCursorLoad
        do {
            load = try await cursors.load(connector)
        } catch is CancellationError {
            return (.skipped(reason: "cancelled"), nil)
        } catch {
            // The record exists but cannot be read (data protection/permission).
            // Leave it and the demand untouched; retry after unlock.
            return (.skipped(reason: "gate"), nil)
        }
        let requestCursor: ConnectorCursorState?
        switch load {
        case .absent, .corrupt: requestCursor = nil
        case .stored(let state): requestCursor = state
        }
        do {
            let page = try await client.fetchDelta(cursor: requestCursor)
            return try await apply(page, load: load, requestCursor: requestCursor,
                                   connector: connector)
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

    private func apply(_ page: ConnectorDeltaPage,
                       load: ConnectorCursorLoad,
                       requestCursor: ConnectorCursorState?,
                       connector: ConnectorKind)
    async throws -> (ConnectorScanOutcome, ConnectorUpdateRecord?) {
        let nowMs = now()
        let decision = ConnectorScanTransition.decide(
            connector: connector, stored: load, head: page.head, now: nowMs)

        guard decision.emitConnectorUpdate else {
            do {
                try await cursors.save(decision.record)
            } catch {
                return (.failed(reason: "cursor_store"), nil)
            }
            switch (load, decision.record.lastError) {
            case (.absent, _):
                return (.baselineEstablished, nil)
            case (_, .cursorInvalid):
                return (.reset(reason: "cursor-invalid"), nil)
            case (_, .cursorRegressed):
                return (.reset(reason: "cursor-regressed"), nil)
            default:
                let advanced: Bool
                switch (requestCursor?.cursor, page.head) {
                case (.gmail(let old), .gmail(let new)):
                    advanced = old != new
                case (.github(let old, _), .github(let new, _)):
                    advanced = new > old
                default:
                    advanced = false
                }
                return (.noNewItems(cursorAdvanced: advanced), nil)
            }
        }

        // An advancing cursor without metadata (for example every notification
        // in the page was filtered out) still advances: the head is what the
        // upstream says is now current, and a held item requires 1...20 items.
        let items = Self.normalized(page.items)
        guard !items.isEmpty else {
            do {
                try await cursors.save(decision.record)
            } catch {
                return (.failed(reason: "cursor_store"), nil)
            }
            return (.noNewItems(cursorAdvanced: true), nil)
        }
        guard let previous = requestCursor else {
            return (.failed(reason: "invalid_cursor"), nil)
        }
        let record: ConnectorUpdateRecord
        do {
            record = try ConnectorUpdateRecord(
                connector: connector,
                cursorFrom: previous.cursor.intervalEndpoint,
                cursorTo: page.head.intervalEndpoint,
                items: items,
                createdAt: nowMs)
        } catch {
            return (.failed(reason: "invalid_update"), nil)
        }
        let enqueued: Bool
        do {
            enqueued = try await sink.enqueue(record)
        } catch {
            return (await markScanFailure(connector: connector, reason: "enqueue"), nil)
        }
        // Only now may the cursor advance. A crash before this write re-scans
        // the interval; the `connector:cursorFrom:cursorTo` key is the dedupe.
        try? await cursors.save(decision.record)
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
            if let head, head.connector == connector {
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
        if let load = try? await cursors.load(connector),
           case .stored(let stored) = load {
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
}
