// SPDX-License-Identifier: MIT

import Foundation

/// Durable write-before-enqueue transport for the read-only device task
/// result notice.
///
/// The device task journal records the terminal outcome before the device
/// report, but the held inbox is a separate SQLite snapshot. Writing the
/// notice event first, then enqueueing, and finally writing an acknowledgement
/// event closes the crash window without changing the held-inbox schema:
///
/// 1. `comm.inbound` with `deviceTaskResult` is appended.
/// 2. `WakeInbox.enqueue` inserts the item (deduped by `requestId`).
/// 3. `comm.reply` with `deviceTaskResultAck` marks the record delivered.
///
/// Startup replays every record without an acknowledgement. A record that was
/// already enqueued but not acknowledged re-enqueues as a duplicate; a record
/// whose item was consumed after acknowledgement is not resurrected.
public actor DeviceTaskResultOutbox {
    public static let recordEventType = "comm.inbound"
    public static let acknowledgementEventType = "comm.reply"

    private struct Pending {
        var botID: String
        var notice: DeviceTaskResultNotice
    }

    private let domain: SQLiteDomainStore
    private let now: @Sendable () -> Int64
    private var restored = false
    private var pending: [String: Pending] = [:]
    private var acknowledged: Set<String> = []

    public init(domain: SQLiteDomainStore,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.domain = domain
        self.now = now
    }

    public static func recordEventID(for notice: DeviceTaskResultNotice) -> String {
        "device-task-result:" + notice.digest
    }

    public static func acknowledgementEventID(for notice: DeviceTaskResultNotice) -> String {
        "device-task-result-ack:" + notice.digest
    }

    /// Appends the terminal record. The append is idempotent by event id, so a
    /// retry after a crash returns the existing sequence and does not add a
    /// second record.
    public func record(_ notice: DeviceTaskResultNotice, botID: String) async throws {
        let eventID = Self.recordEventID(for: notice)
        var data: [String: BotJSONValue] = [
            "botId": .string(botID),
            "deviceTaskResult": try BotJSONValue.parse(JSONEncoder().encode(notice)),
        ]
        if notice.status == .unknownOutcome {
            data["requiresReconciliation"] = .bool(true)
        }
        let event = BotEvent(
            type: Self.recordEventType, eventId: eventID, time: notice.createdAt,
            origin: .local(source: "comm-service"),
            traceId: "device-task-result:\(notice.digest)",
            principal: BotPrincipal(botId: botID, sessionId: nil, kind: "chat"),
            causationId: nil, correlationId: notice.requestID,
            data: .object(data))
        _ = try await domain.append(event)
        pending[eventID] = Pending(botID: botID, notice: notice)
        acknowledged.remove(eventID)
    }

    /// Records, enqueues, and acknowledges one notice. A duplicate enqueue is
    /// still acknowledged: the durable inbox item already exists.
    @discardableResult
    public func enqueue(_ notice: DeviceTaskResultNotice, botID: String,
                        in inbox: WakeInbox) async throws -> WakeInboxEnqueue {
        try await record(notice, botID: botID)
        let result = try await inbox.enqueue(try notice.wakeInboxItem())
        try await acknowledge(notice, botID: botID)
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
            _ = try await inbox.enqueue(try entry.notice.wakeInboxItem())
            try await acknowledge(entry.notice, botID: entry.botID)
            count += 1
        }
        return count
    }

    /// Test/visible state, without exposing the notice payload twice.
    public func pendingEventIDs(botID: String) -> [String] {
        pending.filter { $0.value.botID == botID && !acknowledged.contains($0.key) }
            .map(\.key).sorted()
    }

    private func acknowledge(_ notice: DeviceTaskResultNotice, botID: String) async throws {
        let recordID = Self.recordEventID(for: notice)
        let event = BotEvent(
            type: Self.acknowledgementEventType,
            eventId: Self.acknowledgementEventID(for: notice),
            time: max(now(), notice.createdAt),
            origin: .local(source: "comm-service"),
            traceId: "device-task-result-ack:\(notice.digest)",
            principal: BotPrincipal(botId: botID, sessionId: nil, kind: "chat"),
            causationId: recordID, correlationId: notice.requestID,
            data: .object([
                "botId": .string(botID),
                "deviceTaskResultAck": .string(recordID),
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
                          case let .string(recordID)? = data["deviceTaskResultAck"] else { continue }
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
              let value = data["deviceTaskResult"] else { return nil }
        let notice = try JSONDecoder().decode(DeviceTaskResultNotice.self, from: value.encoded())
        return Pending(botID: botID, notice: notice)
    }
}
