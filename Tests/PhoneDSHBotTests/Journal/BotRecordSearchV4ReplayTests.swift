// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// Replays the real DSH v4 session shapes that broke A06: top-level
/// `data.content` text blocks on user/message, an assistant reasoning block,
/// and a session title. No string-content shortcut.
final class BotRecordSearchV4ReplayTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var service: BotRecordService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("v4-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/a06f2-gb-main.session.v4.jsonl")
        let data = try Data(contentsOf: fixture)
        try data.write(to: sessionURL, options: .atomic)
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        service = BotRecordService(store: store, gateway: gateway, workspaceRoot: root)
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRealV4UserContentBlocksAreSearchableAndRankFirst() async throws {
        let object = try await search("起床")
        let hits = try XCTUnwrap((object["data"] as? [String: Any])?["hits"] as? [[String: Any]])
        let refs = hits.compactMap { $0["ref"] as? String }
        XCTAssertTrue(refs.contains("record://session/gb-main#8"), "original user #8 must be searchable: \(refs)")
        XCTAssertTrue(refs.contains("record://session/gb-main#28"), "correcting user #28 must be searchable: \(refs)")
        XCTAssertFalse(refs.contains("record://session/gb-main#16"),
                       "assistant reasoning/tool-call block must not become final text: \(refs)")
        XCTAssertEqual(hits.first?["type"] as? String, "user/message",
                       "user/message must rank above assistant/title: \(hits.first ?? [:])")

        let correcting = try await search("更正")
        let correctingRefs = try XCTUnwrap(
            (correcting["data"] as? [String: Any])?["hits"] as? [[String: Any]])
            .compactMap { $0["ref"] as? String }
        XCTAssertTrue(correctingRefs.contains("record://session/gb-main#28"), "\(correctingRefs)")

        let read = await service.execute(
            arguments: ["read", "record://session/gb-main#8"], callerSessionID: "gb-main")
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertTrue(read.stdout.contains("请记住一件小事"),
                      "explicit read must still reach the original raw record")
    }

    func testUserTextBeginningWithBraceIsNotDropped() async throws {
        let line: [String: Any] = [
            "type": "user/message", "seq": 99, "time": 1_760_000_099_000,
            "data": [
                "content": [[
                    "type": "text", "text": "{\"user\":\"json\"} USER_JSON_MARKER",
                ]],
                "source": ["kind": "user", "rpcId": "user-action:marker"],
                "role": "user", "id": "marker",
            ],
        ]
        let encoded = try String(decoding: JSONSerialization.data(
            withJSONObject: line, options: [.sortedKeys]), as: UTF8.self)
        let existing = try String(contentsOf: sessionURL, encoding: .utf8)
        try (existing + encoded + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        let object = try await search("USER_JSON_MARKER")
        let hits = try XCTUnwrap((object["data"] as? [String: Any])?["hits"] as? [[String: Any]])
        XCTAssertTrue(hits.contains { $0["ref"] as? String == "record://session/gb-main#99" },
                      "JSON text that starts with { is ordinary user text: \(hits)")
    }

    private var sessionURL: URL {
        root.appendingPathComponent("materialized/home/sessions/gb-main/session.v4.jsonl")
    }

    private func search(_ query: String) async throws -> [String: Any] {
        let result = await service.execute(
            arguments: ["search", query], callerSessionID: "gb-main")
        XCTAssertEqual(result.exitCode, 0, result.stdout)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    }
}
