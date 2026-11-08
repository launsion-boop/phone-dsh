// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

enum BotGrantTestError: Error, Equatable {
    case injectedPersistenceFailure
}

actor BotGrantTestEventLog: BotEventLog {
    private var stored: [BotEvent] = []
    private var failNext = false
    private var snapshotDelayNanoseconds: UInt64

    init(snapshotDelayNanoseconds: UInt64 = 0) {
        self.snapshotDelayNanoseconds = snapshotDelayNanoseconds
    }

    func seed(_ event: BotEvent) {
        let commitSeq = (stored.compactMap(\.commitSeq).max() ?? 0) + 1
        stored.append(event.assigningCommitSeq(commitSeq))
    }

    func failNextAppend() {
        failNext = true
    }

    func append(_ event: BotEvent) async throws -> Int {
        if failNext {
            failNext = false
            throw BotGrantTestError.injectedPersistenceFailure
        }
        try BotEventEnvelopeCodec.validate(event, mode: .append)
        if event.type == BotGrantSnapshot.eventType, snapshotDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: snapshotDelayNanoseconds)
        }
        let commitSeq = (stored.compactMap(\.commitSeq).max() ?? 0) + 1
        stored.append(event.assigningCommitSeq(commitSeq))
        return commitSeq
    }

    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        Array(stored.filter { ($0.commitSeq ?? 0) > commitSeq }
            .sorted { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }.prefix(limit))
    }

    func allEvents() -> [BotEvent] {
        stored
    }
}

func botGrantTestEvent(schemaVersion: Int = 1, type: String = "ui.notice",
                       data: BotJSONValue = .object([:])) -> BotEvent {
    BotEvent(schemaVersion: schemaVersion, type: type,
             eventId: "test-\(UUID().uuidString.lowercased())", time: 1_000,
             origin: .local(source: "ipc"), traceId: "trace-\(UUID().uuidString.lowercased())",
             principal: BotPrincipal(botId: "main", sessionId: nil, kind: "ipc"),
             causationId: nil, correlationId: nil, ignorable: true, data: data)
}
