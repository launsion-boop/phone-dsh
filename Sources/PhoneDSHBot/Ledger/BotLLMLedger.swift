// SPDX-License-Identifier: MIT

import Foundation

public actor BotLLMLedger {
    private let eventLog: any BotEventLog
    private let makeEventId: @Sendable () -> String

    public init(
        eventLog: any BotEventLog,
        eventId: @escaping @Sendable () -> String = { "ledger.usage_recorded:\(UUID().uuidString.lowercased())" }
    ) {
        self.eventLog = eventLog
        self.makeEventId = eventId
    }

    @discardableResult
    public func append(_ record: BotLLMLedgerRecord) async throws -> Int {
        try record.validate()
        let eventId = makeEventId()
        let data = try BotJSONValue.parse(JSONEncoder.botSorted.encode(record))
        guard case .object = data else {
            throw BotLLMLedgerError(field: "record", message: "ledger event data must be an object")
        }
        let principalKind: String
        switch record.purpose {
        case .workerTurn: principalKind = "task"
        case .watchdog: principalKind = "watchdog"
        default: principalKind = "chat"
        }
        guard let date = BotLLMLedgerRecord.date(from: record.ts) else {
            throw BotLLMLedgerError(field: "ts", message: "timestamp must be an ISO-8601 date")
        }
        let event = BotEvent(
            type: "ledger.usage_recorded",
            eventId: eventId,
            time: Int64((date.timeIntervalSince1970 * 1_000).rounded()),
            origin: .local(source: "runtime"),
            traceId: "trace:\(eventId)",
            principal: BotPrincipal(
                botId: record.botId, sessionId: record.sessionId, kind: principalKind),
            causationId: nil,
            correlationId: record.sessionId,
            data: data)
        return try await eventLog.append(event)
    }

    public func records(after commitSeq: Int = 0, limit: Int = 1_000) async throws -> [BotLLMLedgerRecord] {
        guard limit > 0 else {
            throw SQLiteDomainStoreError.invalidCursor("limit must be positive")
        }
        var records: [BotLLMLedgerRecord] = []
        var cursor = commitSeq
        while records.count < limit {
            let events = try await eventLog.events(after: cursor, limit: 1_000)
            if events.isEmpty { break }
            for event in events {
                cursor = event.commitSeq ?? cursor
                guard event.type == "ledger.usage_recorded" else { continue }
                records.append(try JSONDecoder().decode(BotLLMLedgerRecord.self, from: event.data.encoded()))
                if records.count == limit { break }
            }
            if events.count < 1_000 { break }
        }
        return records
    }
}

private extension JSONEncoder {
    static var botSorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
