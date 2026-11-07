// SPDX-License-Identifier: MIT

import Foundation

extension SQLiteDomainStore: BotEventLog {
    @discardableResult
    public func append(_ event: BotEvent) async throws -> Int {
        try BotEventEnvelopeCodec.validate(event, mode: .append)
        if BotEventEnvelopeCodec.isEphemeral(event.type) {
            if ephemeralBuffer.count == ephemeralCapacity {
                ephemeralBuffer.removeFirst()
                droppedEphemeral += 1
            }
            ephemeralBuffer.append(event)
            return 0
        }
        return try withTransaction {
            try insertDurableEvents([event])[0]
        }
    }

    public func appendBatch(_ events: [BotEvent]) async throws -> [Int] {
        guard !events.isEmpty else {
            throw SQLiteDomainStoreError.invalidTransition("appendBatch requires at least one event")
        }
        for event in events {
            try BotEventEnvelopeCodec.validate(event, mode: .append)
            guard !BotEventEnvelopeCodec.isEphemeral(event.type) else {
                throw SQLiteDomainStoreError.invalidTransition("ephemeral events cannot join a durable batch")
            }
        }
        return try withTransaction {
            try insertDurableEvents(events)
        }
    }

    public func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        try ensureOpen()
        guard commitSeq >= 0, limit > 0 else {
            throw SQLiteDomainStoreError.invalidCursor("after must be non-negative and limit must be positive")
        }
        let head = try currentHeadCommitSeq()
        guard commitSeq <= head else {
            throw SQLiteDomainStoreError.invalidCursor("cursor \(commitSeq) is ahead of head \(head)")
        }
        let rows = try database.query(
            "SELECT commit_seq, payload FROM bot_events WHERE commit_seq > ? ORDER BY commit_seq ASC LIMIT ?",
            bindings: [.integer(Int64(commitSeq)), .integer(Int64(limit))])
        let codec = BotEventEnvelopeCodec()
        var result: [BotEvent] = []
        var expected = commitSeq + 1
        for row in rows {
            guard let sequence = row["commit_seq"]?.integer, sequence == Int64(expected) else {
                throw SQLiteDomainStoreError.commitGap(
                    expected: expected, actual: Int(row["commit_seq"]?.integer ?? -1))
            }
            guard let payload = row["payload"]?.blob else {
                throw SQLiteDomainStoreError.corrupted("event \(expected) has no payload")
            }
            let event = try codec.decode(payload)
            guard event.commitSeq == expected else {
                throw SQLiteDomainStoreError.corrupted("event payload mismatch at commitSeq \(expected)")
            }
            result.append(event)
            expected += 1
        }
        return result
    }

    public func headCommitSeq() throws -> Int {
        try ensureOpen()
        return try currentHeadCommitSeq()
    }

    public func event(withId eventId: String) throws -> BotEvent? {
        try ensureOpen()
        let rows = try database.query(
            "SELECT payload FROM bot_events WHERE event_id = ?", bindings: [.text(eventId)])
        guard let payload = rows.first?["payload"]?.blob else { return nil }
        return try BotEventEnvelopeCodec().decode(payload)
    }

    public func ephemeralEvents(limit: Int = 256) throws -> [BotEvent] {
        try ensureOpen()
        guard limit >= 0 else {
            throw SQLiteDomainStoreError.invalidCursor("limit must not be negative")
        }
        return Array(ephemeralBuffer.suffix(limit))
    }

    public func droppedEphemeralCount() throws -> Int {
        try ensureOpen()
        return droppedEphemeral
    }

    func currentHeadCommitSeq() throws -> Int {
        let rows = try database.query("SELECT COALESCE(MAX(commit_seq), 0) AS head FROM bot_events")
        return Int(rows.first?["head"]?.integer ?? 0)
    }

    func insertDurableEvents(_ input: [BotEvent]) throws -> [Int] {
        guard !input.isEmpty else { return [] }
        var seen = Set<String>()
        for event in input {
            try BotEventEnvelopeCodec.validate(event, mode: .append)
            guard !BotEventEnvelopeCodec.isEphemeral(event.type) else {
                throw SQLiteDomainStoreError.invalidTransition("ephemeral event in durable insert")
            }
            guard seen.insert(event.eventId).inserted else {
                throw SQLiteDomainStoreError.invalidTransition("duplicate eventId in batch: \(event.eventId)")
            }
        }

        var existingSequences: [Int] = []
        for event in input {
            let rows = try database.query(
                "SELECT commit_seq FROM bot_events WHERE event_id = ?", bindings: [.text(event.eventId)])
            if let sequence = rows.first?["commit_seq"]?.integer {
                existingSequences.append(Int(sequence))
            }
        }
        if !existingSequences.isEmpty {
            guard input.count == 1, existingSequences.count == 1 else {
                throw SQLiteDomainStoreError.invalidTransition("a durable batch cannot contain committed eventIds")
            }
            return existingSequences
        }

        let explicitBatch = input.allSatisfy { $0.batch != nil }
        guard explicitBatch || input.allSatisfy({ $0.batch == nil }) else {
            throw SQLiteDomainStoreError.invalidTransition("either all events or none must carry a batch")
        }
        let batchId = "batch:\(UUID().uuidString.lowercased())"
        let events = explicitBatch ? input : input.enumerated().map { index, event in
            input.count > 1 ? event.assigningBatch(BotEventBatchRef(id: batchId, index: index, total: input.count)) : event
        }
        if explicitBatch, events.count > 1 {
            let ids = Set(events.compactMap { $0.batch?.id })
            guard ids.count == 1 else {
                throw SQLiteDomainStoreError.invalidTransition("batch id is not contiguous")
            }
            for (index, event) in events.enumerated() {
                guard event.batch?.index == index, event.batch?.total == events.count else {
                    throw SQLiteDomainStoreError.invalidTransition("batch index/total mismatch")
                }
            }
        }

        var next = try currentHeadCommitSeq() + 1
        var sequences: [Int] = []
        let codec = BotEventEnvelopeCodec()
        for event in events {
            let committed = event.assigningCommitSeq(next)
            let payload = try codec.encode(committed)
            try database.execute(
                "INSERT INTO bot_events(commit_seq, event_id, event_type, payload) VALUES (?, ?, ?, ?)",
                bindings: [
                    .integer(Int64(next)), .text(committed.eventId), .text(committed.type), .blob(payload),
                ])
            sequences.append(next)
            next += 1
            try checkCrashPoint("event-insert")
        }
        return sequences
    }
}
