// SPDX-License-Identifier: MIT

import Foundation

public struct RoutineMutation<Value: Sendable>: Sendable {
    public var value: Value
    public var events: [BotEvent]
    public var persistSnapshot: Bool
    public var botId: String
    public var snapshotEventId: String?

    public init(value: Value, events: [BotEvent] = [], persistSnapshot: Bool = true,
                botId: String, snapshotEventId: String? = nil) {
        self.value = value
        self.events = events
        self.persistSnapshot = persistSnapshot
        self.botId = botId
        self.snapshotEventId = snapshotEventId
    }
}

public protocol RoutineStore: Sendable {
    func read(botId: String) async throws -> RoutineDocument
    func mutate<Value: Sendable>(
        botId: String,
        _ body: @escaping @Sendable (inout RoutineDocument) throws -> RoutineMutation<Value>
    ) async throws -> Value
}

public struct SQLiteRoutineStore: RoutineStore, Sendable {
    public let domainStore: SQLiteDomainStore

    public init(domainStore: SQLiteDomainStore) {
        self.domainStore = domainStore
    }

    public func read(botId: String) async throws -> RoutineDocument {
        try await domainStore.routineDocument(botId: botId)
    }

    public func mutate<Value: Sendable>(
        botId: String,
        _ body: @escaping @Sendable (inout RoutineDocument) throws -> RoutineMutation<Value>
    ) async throws -> Value {
        try await domainStore.mutateRoutine(botId: botId, body)
    }
}

extension SQLiteDomainStore {
    func routineDocument(botId: String) throws -> RoutineDocument {
        let rows = try database.query(
            "SELECT payload FROM bot_events WHERE event_type IN ('routine.defined', 'routine.updated', 'routine.deleted') ORDER BY commit_seq ASC")
        let codec = BotEventEnvelopeCodec()
        var document = RoutineDocument()
        for row in rows {
            guard let payload = row["payload"]?.blob else {
                throw SQLiteDomainStoreError.corrupted("routine snapshot has no payload")
            }
            let event = try codec.decode(payload)
            if let snapshot = try DurableEventSnapshots.decode(RoutineDocument.self, from: event, botId: botId) {
                guard snapshot.version == 1 else {
                    throw SQLiteDomainStoreError.corrupted("unsupported routine snapshot version: \(snapshot.version)")
                }
                document = snapshot
            }
        }
        return document
    }

    func mutateRoutine<Value: Sendable>(
        botId: String,
        _ body: @escaping @Sendable (inout RoutineDocument) throws -> RoutineMutation<Value>
    ) async throws -> Value {
        let previous = try routineDocument(botId: botId)
        var document = previous
        let mutation = try body(&document)
        guard mutation.persistSnapshot || !mutation.events.isEmpty else { return mutation.value }

        let type: String
        if document.routines.count > previous.routines.count {
            type = "routine.defined"
        } else if document.routines.count < previous.routines.count {
            type = "routine.deleted"
        } else {
            type = "routine.updated"
        }
        let eventId = mutation.snapshotEventId ?? "routine-snapshot:\(UUID().uuidString.lowercased())"
        let snapshot = BotEvent(
            type: type, eventId: eventId, time: clock(), origin: .local(source: "scheduler"),
            traceId: "trace:\(eventId)",
            principal: BotPrincipal(botId: botId, sessionId: nil, kind: "routine"),
            causationId: nil, correlationId: botId,
            data: try DurableEventSnapshots.data(for: document, botId: botId)
        )
        _ = try await appendBatch([snapshot] + mutation.events)
        return mutation.value
    }
}
