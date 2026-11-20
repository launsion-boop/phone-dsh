// SPDX-License-Identifier: MIT

import Foundation

/// Durable write-before-enqueue transport for one connector update.
///
/// Same crash-safety shape as the device-task result: the connector interval
/// is written as a durable `comm.inbound` record first, the held inbox item is
/// enqueued (deduped by `requestId`), then a `comm.reply` acknowledgement
/// marks the record delivered. A process crash at any point replays the record
/// into the same item instead of losing or duplicating the update:
///
/// 1. `comm.inbound` with `connectorUpdate` is appended (deterministic event id
///    from the cursor interval);
/// 2. `WakeInbox.enqueue` inserts the item, or finds the same `requestId`;
/// 3. `comm.reply` with `connectorUpdateAck` marks the interval delivered.
///
/// A record that was enqueued but not acknowledged re-enqueues as a duplicate;
/// a record whose item was already consumed after acknowledgement is never
/// resurrected.
public actor ConnectorUpdateOutbox {
    public static let recordEventType = "comm.inbound"
    public static let acknowledgementEventType = "comm.reply"

    private struct Pending {
        var botID: String
        var update: ConnectorUpdateRecord
    }

    private let domain: SQLiteDomainStore
    private let now: @Sendable () -> Int64
    private var restored = false
    private var pending: [String: Pending] = [:]
    private var acknowledged: Set<String> = []

    public init(domain: SQLiteDomainStore,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1000)
                }) {
        self.domain = domain
        self.now = now
    }

    public static func recordEventID(for update: ConnectorUpdateRecord) -> String {
        "connector-update:" + update.digest
    }

    public static func acknowledgementEventID(for update: ConnectorUpdateRecord) -> String {
        "connector-update-ack:" + update.digest
    }

    public static func wakeInboxItem(_ update: ConnectorUpdateRecord) throws -> WakeInboxItem {
        try WakeInboxItem(
            id: update.itemID,
            kind: ConnectorUpdateRecord.kind,
            text: update.text,
            requestId: update.requestID,
            createdAt: update.createdAt,
            connector: update.connector.rawValue,
            cursorFrom: update.cursorFrom,
            cursorTo: update.cursorTo,
            count: update.count,
            items: update.items)
    }

    /// Appends the terminal record. The append is idempotent by event id, so a
    /// retry after a crash returns the existing sequence and does not add a
    /// second record.
    public func record(_ update: ConnectorUpdateRecord, botID: String) async throws {
        let eventID = Self.recordEventID(for: update)
        var data: [String: BotJSONValue] = [
            "botId": .string(botID),
            "connectorUpdate": try BotJSONValue.parse(JSONEncoder().encode(update)),
        ]
        data["connector"] = .string(update.connector.rawValue)
        let event = BotEvent(
            type: Self.recordEventType, eventId: eventID, time: update.createdAt,
            origin: .local(source: "comm-service"),
            traceId: "connector-update:\(update.digest)",
            principal: BotPrincipal(botId: botID, sessionId: nil, kind: "chat"),
            causationId: nil, correlationId: update.requestID,
            data: .object(data))
        _ = try await domain.append(event)
        pending[eventID] = Pending(botID: botID, update: update)
        acknowledged.remove(eventID)
    }

    /// Records, enqueues, and acknowledges one update. A duplicate enqueue is
    /// still acknowledged: the durable inbox item already exists.
    @discardableResult
    public func enqueue(_ update: ConnectorUpdateRecord, botID: String,
                        in inbox: WakeInbox) async throws -> WakeInboxEnqueue {
        try await record(update, botID: botID)
        let item = try Self.wakeInboxItem(update)
        let result = try await inbox.enqueue(item)
        try await acknowledge(update, botID: botID)
        return result
    }

    /// Startup replay for one Bot. Returns the number of records whose enqueue
    /// was attempted (including deduped survivors).
    @discardableResult
    public func redeliver(botID: String, in inbox: WakeInbox) async throws -> Int {
        try await restoreIfNeeded()
        var count = 0
        for (eventID, entry) in pending.sorted(by: { $0.key < $1.key })
        where entry.botID == botID && !acknowledged.contains(eventID) {
            _ = try await inbox.enqueue(try Self.wakeInboxItem(entry.update))
            try await acknowledge(entry.update, botID: entry.botID)
            count += 1
        }
        return count
    }

    /// Test/visible state, without exposing the update payload twice.
    public func pendingEventIDs(botID: String) -> [String] {
        pending.filter { $0.value.botID == botID && !acknowledged.contains($0.key) }
            .map(\.key).sorted()
    }

    private func acknowledge(_ update: ConnectorUpdateRecord, botID: String) async throws {
        let recordID = Self.recordEventID(for: update)
        let event = BotEvent(
            type: Self.acknowledgementEventType,
            eventId: Self.acknowledgementEventID(for: update),
            time: max(now(), update.createdAt),
            origin: .local(source: "comm-service"),
            traceId: "connector-update-ack:\(update.digest)",
            principal: BotPrincipal(botId: botID, sessionId: nil, kind: "chat"),
            causationId: recordID, correlationId: update.requestID,
            data: .object([
                "botId": .string(botID),
                "connectorUpdateAck": .string(recordID),
            ]))
        _ = try await domain.append(event)
        acknowledged.insert(recordID)
    }

    private func restoreIfNeeded() async throws {
        guard !restored else { return }
        var cursor = 0
        while true {
            let events = try await domain.events(after: cursor, limit: 500)
            if events.isEmpty { break }
            for event in events {
                guard let next = event.commitSeq, next > cursor else { continue }
                cursor = next
                switch event.type {
                case Self.recordEventType:
                    guard let entry = try Self.pending(from: event) else { continue }
                    pending[event.eventId] = entry
                case Self.acknowledgementEventType:
                    guard case let .object(data) = event.data,
                          case let .string(recordID)? = data["connectorUpdateAck"] else { continue }
                    acknowledged.insert(recordID)
                default:
                    continue
                }
            }
            if events.count < 500 { break }
        }
        restored = true
    }

    private static func pending(from event: BotEvent) throws -> Pending? {
        guard case let .object(data) = event.data,
              case let .string(botID)? = data["botId"],
              let value = data["connectorUpdate"] else { return nil }
        let update = try JSONDecoder().decode(ConnectorUpdateRecord.self, from: value.encoded())
        return Pending(botID: botID, update: update)
    }
}

/// Adapter from the pure scanner sink protocol to the durable outbox + one
/// Bot's held inbox.
public actor ConnectorUpdateInboxSink: ConnectorUpdateEnqueuing {
    private let outbox: ConnectorUpdateOutbox
    private let inbox: WakeInbox
    private let botID: String

    public init(outbox: ConnectorUpdateOutbox, inbox: WakeInbox, botID: String) {
        self.outbox = outbox
        self.inbox = inbox
        self.botID = botID
    }

    public func enqueue(_ update: ConnectorUpdateRecord) async throws -> Bool {
        let result = try await outbox.enqueue(update, botID: botID, in: inbox)
        return !result.duplicate
    }
}
