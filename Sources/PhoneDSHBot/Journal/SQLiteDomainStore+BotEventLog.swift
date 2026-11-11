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
            """
            SELECT h.commit_seq, h.header_meta, p.payload, p.erasure_commit_seq
            FROM bot_event_headers AS h
            LEFT JOIN bot_event_payloads AS p ON p.commit_seq = h.commit_seq
            WHERE h.commit_seq > ? ORDER BY h.commit_seq ASC LIMIT ?
            """,
            bindings: [.integer(Int64(commitSeq)), .integer(Int64(limit))])
        let codec = BotEventEnvelopeCodec()
        var result: [BotEvent] = []
        var expected = commitSeq + 1
        for row in rows {
            guard let sequence = row["commit_seq"]?.integer, sequence == Int64(expected) else {
                throw SQLiteDomainStoreError.commitGap(
                    expected: expected, actual: Int(row["commit_seq"]?.integer ?? -1))
            }
            let event = try Self.decodeEventRow(row, codec: codec)
            guard event.commitSeq == expected else {
                throw SQLiteDomainStoreError.corrupted("event header mismatch at commitSeq \(expected)")
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
            """
            SELECT h.commit_seq, h.header_meta, p.payload, p.erasure_commit_seq
            FROM bot_event_headers AS h
            LEFT JOIN bot_event_payloads AS p ON p.commit_seq = h.commit_seq
            WHERE h.event_id = ?
            """,
            bindings: [.text(eventId)])
        guard let row = rows.first else { return nil }
        return try Self.decodeEventRow(row, codec: BotEventEnvelopeCodec())
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

    /// The header/digest/size of each durable event the caller intends to
    /// erase. Refuses a missing sequence; an already erased sequence is
    /// returned with `payloadBytes == 0` so a retried erasure stays idempotent.
    public func erasureTargets(for commitSeqs: [Int]) throws -> [BotEventErasureTarget] {
        try ensureOpen()
        var seen = Set<Int>()
        var targets: [BotEventErasureTarget] = []
        for sequence in commitSeqs.sorted() where seen.insert(sequence).inserted {
            guard sequence >= 1 else {
                throw SQLiteDomainStoreError.invalidTransition("commitSeq must be positive")
            }
            let rows = try database.query(
                """
                SELECT h.event_type, h.payload_digest, h.payload_size, p.payload
                FROM bot_event_headers AS h
                LEFT JOIN bot_event_payloads AS p ON p.commit_seq = h.commit_seq
                WHERE h.commit_seq = ?
                """,
                bindings: [.integer(Int64(sequence))])
            guard let row = rows.first,
                  let type = row["event_type"]?.text,
                  let digest = row["payload_digest"]?.text,
                  let size = row["payload_size"]?.integer else {
                throw SQLiteDomainStoreError.invalidTransition(
                    "event \(sequence) does not exist")
            }
            let bytes = row["payload"]?.blob?.count ?? 0
            targets.append(BotEventErasureTarget(
                commitSeq: sequence,
                type: type,
                digest: digest,
                payloadBytes: bytes == 0 ? 0 : Int(size)))
        }
        return targets
    }

    /// Clears the payloads named by `commitSeqs` and appends the `erasure`
    /// event in the same transaction. Headers, ids, types and digests stay.
    /// After the commit the caller still has to run ``secureEraseStorage()``;
    /// this method does it and throws if the WAL cannot be truncated.
    @discardableResult
    public func erasePayloads(_ commitSeqs: [Int], erasureEvent: BotEvent,
                              atMS: Int64) async throws -> BotEventErasureCommit {
        try ensureOpen()
        guard erasureEvent.type == "erasure" else {
            throw SQLiteDomainStoreError.invalidTransition("erasure requires an erasure event")
        }
        guard !commitSeqs.isEmpty else {
            throw SQLiteDomainStoreError.invalidTransition("erasure requires at least one payload")
        }
        try BotEventEnvelopeCodec.validate(erasureEvent, mode: .append)
        guard !BotEventEnvelopeCodec.isEphemeral(erasureEvent.type) else {
            throw SQLiteDomainStoreError.invalidTransition("erasure must be durable")
        }
        let targets = try erasureTargets(for: commitSeqs)
        let pending = targets.filter { $0.payloadBytes > 0 }
        let commit = try withTransaction { () -> BotEventErasureCommit in
            let erasureSequence = try insertDurableEvents([erasureEvent])[0]
            for target in pending {
                try database.execute(
                    """
                    UPDATE bot_event_payloads
                    SET payload = NULL, erased_at = ?, erasure_commit_seq = ?
                    WHERE commit_seq = ? AND payload IS NOT NULL
                    """,
                    bindings: [
                        .integer(atMS), .integer(Int64(erasureSequence)),
                        .integer(Int64(target.commitSeq)),
                    ])
                let rows = try database.query(
                    "SELECT payload, erasure_commit_seq FROM bot_event_payloads WHERE commit_seq = ?",
                    bindings: [.integer(Int64(target.commitSeq))])
                guard let row = rows.first,
                      row["payload"]?.blob == nil,
                      row["erasure_commit_seq"]?.integer == Int64(erasureSequence) else {
                    throw SQLiteDomainStoreError.invalidTransition(
                        "event \(target.commitSeq) payload was not erased")
                }
            }
            return BotEventErasureCommit(erasureCommitSeq: erasureSequence, erased: targets)
        }
        try secureEraseStorage()
        return commit
    }

    /// Checkpoints the WAL into the database, VACUUMs the file so freed pages
    /// cannot retain the cleared bytes, then truncates the WAL again. This is
    /// deliberately outside the erasure transaction.
    public func secureEraseStorage() throws {
        try ensureOpen()
        _ = try database.query("PRAGMA wal_checkpoint(TRUNCATE)")
        _ = try database.query("PRAGMA secure_delete=ON")
        try database.execute("VACUUM")
        _ = try database.query("PRAGMA wal_checkpoint(TRUNCATE)")
        try? SQLiteDatabase.applyFileAttributes(to: fileURL)
    }

    func currentHeadCommitSeq() throws -> Int {
        let rows = try database.query(
            "SELECT COALESCE(MAX(commit_seq), 0) AS head FROM bot_event_headers")
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
                "SELECT commit_seq FROM bot_event_headers WHERE event_id = ?",
                bindings: [.text(event.eventId)])
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
            let payload = try codec.encodeData(committed.data)
            let header = try codec.encode(committed.assigningData(.object([:])))
            try database.execute(
                """
                INSERT INTO bot_event_headers(commit_seq, event_id, event_type,
                                              payload_digest, payload_size, header_meta)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .integer(Int64(next)), .text(committed.eventId), .text(committed.type),
                    .text(SQLiteDatabase.payloadDigest(payload)),
                    .integer(Int64(payload.count)), .blob(header),
                ])
            try database.execute(
                "INSERT INTO bot_event_payloads(commit_seq, payload) VALUES (?, ?)",
                bindings: [.integer(Int64(next)), .blob(payload)])
            sequences.append(next)
            next += 1
            try checkCrashPoint("event-insert")
        }
        return sequences
    }

    private static func decodeEventRow(_ row: [String: SQLiteValue],
                                       codec: BotEventEnvelopeCodec) throws -> BotEvent {
        guard let sequence = row["commit_seq"]?.integer,
              let headerData = row["header_meta"]?.blob else {
            throw SQLiteDomainStoreError.corrupted("event header row is incomplete")
        }
        var event = try codec.decode(headerData)
        guard event.commitSeq == Int(sequence) else {
            throw SQLiteDomainStoreError.corrupted("event header mismatch at commitSeq \(sequence)")
        }
        if let payload = row["payload"]?.blob {
            event = event.assigningData(try codec.decodeData(payload))
        } else {
            guard let erasureSequence = row["erasure_commit_seq"]?.integer,
                  erasureSequence > sequence else {
                throw SQLiteDomainStoreError.corrupted(
                    "event \(sequence) has neither payload nor a valid erasure")
            }
            event = event.assigningData(.object([
                "$erased": .bool(true),
                "$erasureCommitSeq": .number(Double(erasureSequence)),
            ]))
        }
        try BotEventEnvelopeCodec.validate(event)
        return event
    }
}
