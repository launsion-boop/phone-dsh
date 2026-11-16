// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// A maintenance run calls `phone record` repeatedly. Every single result is
/// bounded, exposes total/first/next, and an identical unchanged call reuses a
/// short cached envelope instead of replaying the whole body.
final class BotRecordBoundsTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var service: BotRecordService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-bounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        service = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: root, now: { 1_000 })
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testLargeSessionReadIsBoundedWithHints() async throws {
        let huge = String(repeating: "A", count: 50_000) + "NEEDLE_END"
        try writeLog(lines: [
            line(seq: 0, type: "user/message", text: huge),
            line(seq: 1, type: "assistant/message", text: "short context"),
            line(seq: 2, type: "assistant/message", text: "next window"),
        ])
        let read = await service.execute(
            arguments: ["read", "record://session/gb-main#0", "--around", "0"], callerSessionID: "gb-main")
        XCTAssertEqual(read.exitCode, 0, read.stdout)
        XCTAssertLessThanOrEqual(read.stdout.unicodeScalars.count, BotRecordService.maximumReturnedChars)
        let object = try json(read.stdout)
        XCTAssertEqual(object["truncated"] as? Bool, true)
        XCTAssertEqual(object["first"] as? String, "record://session/gb-main#0")
        XCTAssertEqual(object["next"] as? String, "record://session/gb-main#1")
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertGreaterThan(data["totalChars"] as? Int ?? 0, 8_000)
        let lines = try XCTUnwrap(data["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.first?["ref"] as? String, "record://session/gb-main#0")
        XCTAssertEqual(lines.first?["truncated"] as? Bool, true)
        XCTAssertTrue((lines.first?["raw"] as? String ?? "").contains("AAAA"))
        XCTAssertFalse((lines.first?["raw"] as? String ?? "").contains("NEEDLE_END"))
    }

    func testLargeEventReadIsBounded() async throws {
        let sequence = try await store.append(BotEvent(
            type: "conversation.assistant_message",
            eventId: "large:\(UUID().uuidString)", time: 1_000,
            origin: .local(source: "runtime"), traceId: "trace-large",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object(["message": .object([
                "role": .string("assistant"),
                "text": .string(String(repeating: "B", count: 55_000)),
            ])])))
        let read = await service.execute(
            arguments: ["read", "record://event/\(sequence)"], callerSessionID: "gb-main")
        XCTAssertEqual(read.exitCode, 0, read.stdout)
        XCTAssertLessThanOrEqual(read.stdout.unicodeScalars.count, BotRecordService.maximumReturnedChars)
        let object = try json(read.stdout)
        XCTAssertEqual(object["truncated"] as? Bool, true)
        XCTAssertGreaterThan(object["totalChars"] as? Int ?? 0, 8_000)
        XCTAssertEqual(object["first"] as? String, "record://event/\(sequence)")
    }

    func testSearchReportsTotalFirstNextAndStaysBounded() async throws {
        var lines: [[String: Any]] = []
        for index in 0..<25 {
            lines.append(line(seq: index, type: "assistant/message", text: "MATCH_\(index) shared"))
        }
        try writeLog(lines: lines)
        let search = await service.execute(
            arguments: ["search", "MATCH_"], callerSessionID: "gb-main")
        XCTAssertEqual(search.exitCode, 0, search.stdout)
        XCTAssertLessThanOrEqual(search.stdout.unicodeScalars.count, BotRecordService.maximumReturnedChars)
        let object = try json(search.stdout)
        XCTAssertEqual(object["truncated"] as? Bool, true)
        XCTAssertEqual(object["total"] as? Int, 25)
        XCTAssertNotNil(object["next"] as? String)
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual((data["hits"] as? [[String: Any]])?.count, BotRecordService.maximumHits)
    }

    func testIdenticalUnchangedSearchIsACompactCacheHit() async throws {
        try writeLog(lines: (0..<10).map {
            line(seq: $0, type: "assistant/message", text: "CACHE_NEEDLE shared \($0)")
        })
        let first = await service.execute(
            arguments: ["search", "CACHE_NEEDLE"], callerSessionID: "gb-main")
        XCTAssertEqual(first.exitCode, 0, first.stdout)
        let firstLength = first.stdout.unicodeScalars.count

        let second = await service.execute(
            arguments: ["search", "CACHE_NEEDLE"], callerSessionID: "gb-main")
        XCTAssertEqual(second.exitCode, 0, second.stdout)
        let cached = try json(second.stdout)
        XCTAssertEqual(cached["cached"] as? Bool, true)
        XCTAssertEqual(cached["duplicate"] as? Bool, true)
        XCTAssertLessThan(second.stdout.unicodeScalars.count, firstLength / 2)
        XCTAssertNil((cached["data"] as? [String: Any])?["hits"])

        // A new durable event changes the event head: the same call must be
        // replayed, not served from the stale cache.
        _ = try await store.append(BotEvent(
            type: "conversation.assistant_message",
            eventId: "cache-invalidate:\(UUID().uuidString)", time: 2_000,
            origin: .local(source: "runtime"), traceId: "trace-cache",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object(["message": .object([
                "role": .string("assistant"),
                "text": .string("CACHE_NEEDLE new event"),
            ])])))
        let third = await service.execute(
            arguments: ["search", "CACHE_NEEDLE"], callerSessionID: "gb-main")
        XCTAssertEqual(third.exitCode, 0, third.stdout)
        let refreshed = try json(third.stdout)
        XCTAssertNil(refreshed["cached"])
        XCTAssertEqual(refreshed["total"] as? Int, 11)
    }


    func testNestedRecordToolResultIsNotReexpandedBySearch() async throws {
        let nested = try JSONSerialization.data(withJSONObject: [
            "ok": true, "tool": "record.search",
            "data": ["query": "NEEDLE", "hits": [[
                "ref": "record://session/gb-main#0",
                "snippet": "NEEDLE nested raw body that must not be searched again",
            ]]],
        ], options: [.sortedKeys])
        let nestedText = String(decoding: nested, as: UTF8.self)
        try writeLog(lines: [
            line(seq: 0, type: "assistant/message", text: "ASSISTANT_NEEDLE useful product"),
            [
                "type": "tool/result", "seq": 1, "time": 1_760_000_000_001,
                "data": ["message": ["role": "tool", "content": [[
                    "type": "text", "text": nestedText,
                ]]]],
            ],
        ])
        let search = await service.execute(
            arguments: ["search", "NEEDLE"], callerSessionID: "gb-main")
        XCTAssertEqual(search.exitCode, 0, search.stdout)
        let object = try json(search.stdout)
        let hits = try XCTUnwrap((object["data"] as? [String: Any])?["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?["ref"] as? String, "record://session/gb-main#0",
                       "only the useful assistant product matches; the nested record body is a projection")
        XCTAssertFalse(hits.contains { $0["type"] as? String == "tool/result" })

        let read = await service.execute(
            arguments: ["read", "record://session/gb-main#1"], callerSessionID: "gb-main")
        XCTAssertEqual(read.exitCode, 0, read.stdout)
        XCTAssertTrue(read.stdout.contains("NEEDLE nested raw body"),
                      "explicit read by ref still reaches the original raw record")
        XCTAssertLessThanOrEqual(read.stdout.unicodeScalars.count, BotRecordService.maximumReturnedChars)
    }

    func testEventAndSessionDuplicateIsDedupedWithAlsoAt() async throws {
        let time: Int64 = 1_760_000_000_000
        try writeLog(lines: [
            [
                "type": "assistant/message", "seq": 0, "time": time,
                "data": ["message": ["role": "assistant", "content": [[
                    "type": "text", "text": "DEDUPE_UNIQUE assistant product",
                ]]]],
            ],
        ])
        let sequence = try await store.append(BotEvent(
            type: "conversation.assistant_message", eventId: "dedupe:test", time: time,
            origin: .local(source: "runtime"), traceId: "trace-dedupe",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object(["message": .object([
                "role": .string("assistant"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("DEDUPE_UNIQUE assistant product"),
                ])]),
            ])])))
        let search = await service.execute(
            arguments: ["search", "DEDUPE_UNIQUE"], callerSessionID: "gb-main")
        XCTAssertEqual(search.exitCode, 0, search.stdout)
        let object = try json(search.stdout)
        XCTAssertEqual(object["total"] as? Int, 2)
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["deduped"] as? Int, 1)
        let hits = try XCTUnwrap((object["data"] as? [String: Any])?["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 1)
        let alsoAt = try XCTUnwrap(hits.first?["alsoAt"] as? [String])
        XCTAssertTrue(alsoAt.contains("record://event/\(sequence)") ||
                      hits.first?["ref"] as? String == "record://event/\(sequence)",
                      "the event/session pair must retain both refs, one as alsoAt")
    }
    // MARK: - Helpers

    private func line(seq: Int, type: String, text: String) -> [String: Any] {
        [
            "type": type, "seq": seq, "time": 1_760_000_000_000 + seq,
            "data": ["message": ["role": type == "user/message" ? "user" : "assistant",
                                 "content": [["type": "text", "text": text]]]],
        ]
    }

    private func writeLog(lines: [[String: Any]]) throws {
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let encoded = try [header] + lines
        let text = try encoded.map {
            String(decoding: try JSONSerialization.data(
                withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(
            to: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }

    private func json(_ stdout: String) throws -> [String: Any] {
        let data = try XCTUnwrap(stdout.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
