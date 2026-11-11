// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import PhoneDSHBot

final class BotEventStorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-event-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeV2Database(file: URL) throws -> (BotEvent, BotEvent) {
        let first = BotEvent(
            type: "ui.notice", eventId: "v2-first", commitSeq: 1, time: 1_000,
            origin: .local(source: "user"), traceId: "trace-v2-first",
            principal: BotPrincipal(botId: "main", sessionId: nil, kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object(["text": .string("v2 payload first")]))
        let second = BotEvent(
            type: "ui.notice", eventId: "v2-second", commitSeq: 2, time: 2_000,
            origin: .local(source: "user"), traceId: "trace-v2-second",
            principal: BotPrincipal(botId: "main", sessionId: nil, kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object(["text": .string("v2 payload second")]))
        let codec = BotEventEnvelopeCodec()
        let firstPayload = try codec.encode(first)
        let secondPayload = try codec.encode(second)

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        guard let handle else { return (first, second) }
        defer { sqlite3_close_v2(handle) }
        let schema = """
            CREATE TABLE bot_events (
                commit_seq INTEGER PRIMARY KEY CHECK (commit_seq > 0),
                event_id TEXT NOT NULL UNIQUE,
                event_type TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE TABLE bot_user_action_nonces (
                bot_id TEXT NOT NULL,
                nonce TEXT NOT NULL,
                event_id TEXT NOT NULL UNIQUE REFERENCES bot_events(event_id),
                created_commit_seq INTEGER NOT NULL CHECK (created_commit_seq > 0),
                PRIMARY KEY(bot_id, nonce)
            );
            PRAGMA user_version=2;
            """
        XCTAssertEqual(sqlite3_exec(handle, schema, nil, nil, nil), SQLITE_OK)
        try insert(handle: handle, sequence: 1, event: first, payload: firstPayload)
        try insert(handle: handle, sequence: 2, event: second, payload: secondPayload)
        let nonce = """
            INSERT INTO bot_user_action_nonces(bot_id, nonce, event_id, created_commit_seq)
            VALUES ('main', 'nonce-v2', 'v2-first', 1);
            """
        XCTAssertEqual(sqlite3_exec(handle, nonce, nil, nil, nil), SQLITE_OK)
        return (first, second)
    }

    private func insert(handle: OpaquePointer, sequence: Int, event: BotEvent,
                        payload: Data) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO bot_events(commit_seq, event_id, event_type, payload) VALUES (?, ?, ?, ?)"
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(sequence))
        sqlite3_bind_text(statement, 2, event.eventId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 3, event.type, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(payload.count),
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func testV2ToV3MigrationSplitsPayloadAndIsIdempotent() async throws {
        let file = root.appendingPathComponent("domain.sqlite")
        let (first, second) = try makeV2Database(file: file)
        let eventsBefore = [first, second]

        let store = try SQLiteDomainStore(fileURL: file, now: { 5_000 })
        let migrated = try await store.events(after: 0, limit: 10)
        XCTAssertEqual(migrated, eventsBefore)
        let head = try await store.headCommitSeq()
        XCTAssertEqual(head, 2)
        try await store.verifyIntegrity()
        try await store.close()

        XCTAssertEqual(try scalar("PRAGMA user_version", file: file), "3")
        let headers = try query("SELECT name, type FROM sqlite_master WHERE name = 'bot_events'",
                                file: file)
        XCTAssertEqual(headers.first?["type"], "view")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM bot_event_headers", file: file), "2")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM bot_event_payloads", file: file), "2")
        let payload = try query(
            """
            SELECT p.payload, h.payload_size
            FROM bot_event_payloads AS p
            JOIN bot_event_headers AS h ON h.commit_seq = p.commit_seq
            WHERE p.commit_seq = 1
            """, file: file).first
        XCTAssertEqual(payload?["payload_size"], "27")
        let digest = try scalar("SELECT payload_digest FROM bot_event_headers WHERE commit_seq = 1",
                                file: file)
        let expected = SHA256.hash(data: Data(#"{"text":"v2 payload first"}"#.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expected)
        let nonce = try query(
            "SELECT event_id FROM bot_user_action_nonces WHERE bot_id = 'main' AND nonce = 'nonce-v2'",
            file: file)
        XCTAssertEqual(nonce.first?["event_id"], "v2-first")

        // Reopen twice: the migration is idempotent and the header sequence
        // still has no gap.
        for _ in 0..<2 {
            let reopened = try SQLiteDomainStore(fileURL: file, now: { 6_000 })
            let reopenedEvents = try await reopened.events(after: 0, limit: 10)
            XCTAssertEqual(reopenedEvents, eventsBefore)
            try await reopened.verifyIntegrity()
            try await reopened.close()
            XCTAssertEqual(try scalar("PRAGMA user_version", file: file), "3")
        }
    }

    func testPayloadSplitKeepsSequenceAndErasedReadsAreExplicit() async throws {
        let file = root.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let marker = "EVENT_PAYLOAD_MARKER_55"
        let sentinel = BotEvent(
            type: "ui.notice", eventId: "erase-me-sentinel",
            time: 1_000, origin: .local(source: "user"), traceId: "trace-sentinel",
            principal: BotPrincipal(botId: "main", sessionId: nil, kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object(["text": .string(marker)]))
        let sequence = try await store.append(sentinel)
        let targets = try await store.erasureTargets(for: [sequence])
        XCTAssertEqual(targets.first?.type, "ui.notice")
        XCTAssertEqual(targets.first?.payloadBytes, 34)
        let data = BotErasureEventData(
            erasureId: "erase-document-1",
            reason: "test",
            atMS: 2_000,
            targets: [BotErasureEventData.Target(kind: "memory", scope: "agent")],
            erasedEvents: targets.map {
                BotErasureEventData.ErasedEvent(record: $0.record, type: $0.type,
                                                digest: $0.digest, payloadBytes: $0.payloadBytes)
            })
        let erasure = BotEvent(
            type: "erasure", eventId: "erasure-test", time: 2_000,
            origin: .local(source: "user"), traceId: "trace-erasure-test",
            principal: BotPrincipal(botId: "main", sessionId: nil, kind: "ipc"),
            causationId: nil, correlationId: nil,
            data: try JSONEncoder().encode(data).botJSONValue())
        let commit = try await store.erasePayloads([sequence], erasureEvent: erasure, atMS: 2_000)
        XCTAssertEqual(commit.erased.count, 1)
        try await store.verifyIntegrity()

        let read = try await store.events(after: 0, limit: 10)
        XCTAssertEqual(read.map(\.commitSeq), [sequence, commit.erasureCommitSeq])
        XCTAssertTrue(read[0].isErasedPayload)
        XCTAssertEqual(read[0].erasureCommitSeq, commit.erasureCommitSeq)
        XCTAssertFalse(read[1].isErasedPayload)
        XCTAssertEqual(read[1].type, "erasure")

        // The legacy reader view reconstructs a decodable envelope with the
        // erased sentinel, not the original content.
        try await store.close()
        let viewRows = try query("SELECT payload FROM bot_events ORDER BY commit_seq", file: file)
        let payloadText = try XCTUnwrap(viewRows.first?["payload"])
        let payload = try XCTUnwrap(payloadText.data(using: .utf8))
        let decoded = try BotEventEnvelopeCodec().decode(payload)
        XCTAssertTrue(decoded.isErasedPayload)
        let databaseBytes = try Data(contentsOf: file)
        XCTAssertNil(databaseBytes.range(of: Data(marker.utf8)))
    }

    func testHeaderAndPayloadTablesRejectNonErasureMutation() async throws {
        let file = root.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let sequence = try await store.append(BotEvent(
            type: "ui.notice", eventId: "append-only-header",
            time: 1_000, origin: .local(source: "user"), traceId: "trace-append-only",
            principal: BotPrincipal(botId: "main", sessionId: nil, kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object(["text": .string("APPEND_ONLY_MARKER_77")])))
        XCTAssertEqual(sequence, 1)
        try await store.close()

        // Headers are append-only; payloads may only become the erasure
        // sentinel and may never be deleted.
        XCTAssertThrowsError(try execute(
            "UPDATE bot_event_headers SET event_type = 'ui.system_event' WHERE commit_seq = 1", file: file))
        XCTAssertThrowsError(try execute(
            "DELETE FROM bot_event_headers WHERE commit_seq = 1", file: file))
        XCTAssertThrowsError(try execute(
            "DELETE FROM bot_event_payloads WHERE commit_seq = 1", file: file))
        XCTAssertThrowsError(try execute(
            "UPDATE bot_event_payloads SET payload = X'00' WHERE commit_seq = 1", file: file))
        XCTAssertThrowsError(try execute(
            "UPDATE bot_event_payloads SET payload = NULL WHERE commit_seq = 1", file: file))

        XCTAssertEqual(try scalar(
            "SELECT event_type FROM bot_event_headers WHERE commit_seq = 1", file: file), "ui.notice")
        XCTAssertEqual(try scalar(
            "SELECT COUNT(*) FROM bot_event_payloads WHERE payload IS NOT NULL", file: file), "1")
        XCTAssertEqual(try scalar(
            "SELECT COUNT(*) FROM bot_event_payloads WHERE erasure_commit_seq IS NOT NULL",
            file: file), "0")
    }

    // MARK: - raw SQLite helpers

    private func execute(_ sql: String, file: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "BotEventStorageTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unable to open test database"])
        }
        defer { sqlite3_close_v2(handle) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "sqlite error \(result)"
            sqlite3_free(message)
            throw NSError(domain: "BotEventStorageTests", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    private func scalar(_ sql: String, file: URL) throws -> String? {
        try query(sql, file: file).first?.values.first
    }

    private func query(_ sql: String, file: URL) throws -> [[String: String]] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        guard let handle else { return [] }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                if let text = sqlite3_column_text(statement, index) {
                    row[name] = String(cString: text)
                } else {
                    row[name] = ""
                }
            }
            rows.append(row)
        }
        return rows
    }
}

private extension Data {
    func botJSONValue() throws -> BotJSONValue {
        try JSONDecoder().decode(BotJSONValue.self, from: self)
    }
}
