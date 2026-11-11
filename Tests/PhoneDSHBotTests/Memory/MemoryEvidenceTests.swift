// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class MemoryEvidenceTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var service: BotRecordService!
    private var runtime: BotMCPRuntime!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        try writeSessionLog()
        store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        service = BotRecordService(store: store, gateway: gateway, workspaceRoot: root)
        runtime = BotMCPRuntime(store: store, gateway: gateway,
                                recordEvidence: service, now: { 1_000 })
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testProfileWriteRequiresUserMessageEvidenceAndStoresTrust() async throws {
        let userRef = "record://session/gb-main#3"
        let written = try await call([
            "action": "write", "fact": "用户叫小林", "scope": "user", "tier": "profile",
            "evidence": [userRef],
        ])
        XCTAssertNotEqual(written.isError, true)
        let facts = try await runtime.memory(for: "bot-a").facts(scope: .user)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].trust, .string("user"))
        XCTAssertEqual(facts[0].evidence, [userRef])
    }

    func testUserBoundaryRejectsMissingOrNonUserEvidence() async throws {
        let missing = try await call([
            "action": "write", "fact": "没有引用的用户事实", "scope": "user", "tier": "log",
        ])
        XCTAssertEqual(missing.structuredContent?["ok"], .bool(false))
        XCTAssertEqual(missing.structuredContent?["code"]?.stringValue,
                       "memory-evidence-required")

        let observed = try await call([
            "action": "write", "fact": "网页观察", "scope": "user", "tier": "log",
            "evidence": ["record://session/gb-main#4"],
        ])
        XCTAssertEqual(observed.structuredContent?["ok"], .bool(false))
        XCTAssertEqual(observed.structuredContent?["code"]?.stringValue,
                       "memory-evidence-required")

        let facts = try await runtime.memory(for: "bot-a").facts(scope: .user)
        XCTAssertTrue(facts.isEmpty)
    }

    func testObservationEvidenceWritesAgentScopeWithObservationTrust() async throws {
        let written = try await call([
            "action": "write", "fact": "网页说今天下雨", "scope": "agent", "tier": "log",
            "evidence": ["record://session/gb-main#4"],
        ])
        XCTAssertNotEqual(written.isError, true)
        let facts = try await runtime.memory(for: "bot-a").facts(scope: .agent)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].trust, .string("observation"))
        XCTAssertEqual(facts[0].evidence, ["record://session/gb-main#4"])
    }

    func testInvalidOrForeignEvidenceFailsClosed() async throws {
        let invalid = try await call([
            "action": "write", "fact": "坏引用", "scope": "agent", "tier": "log",
            "evidence": ["record://session/gb-main"],
        ])
        XCTAssertEqual(invalid.isError, true)
        XCTAssertEqual(invalid.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-evidence-invalid")

        let unknown = try await call([
            "action": "write", "fact": "不存在的记录", "scope": "agent", "tier": "log",
            "evidence": ["record://event/999"],
        ])
        XCTAssertEqual(unknown.isError, true)
        XCTAssertEqual(unknown.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-evidence-invalid")

        let forget = try await call([
            "action": "forget", "fact": "坏引用", "scope": "agent",
            "evidence": ["record://session/gb-main#3"],
        ])
        XCTAssertEqual(forget.isError, true)
        XCTAssertEqual(forget.structuredContent?["error"]?["code"]?.stringValue,
                       "invalid_arguments")
    }

    // MARK: - Helpers

    private func call(_ fields: [String: Any]) async throws -> BotMCPCallResult {
        let arguments = try BotJSONValue.parse(
            JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
        await runtime.beginTurn(sessionId: "gb-main", hidden: false,
                                origin: BotTurnOrigin(rpcId: "bot-1"))
        return try await registerAndExecute(
            runtime, name: "UpdateMemory", arguments: arguments,
            sessionId: "gb-main", callId: UUID().uuidString)
    }

    private func writeSessionLog() throws {
        let events: [[String: Any]] = [
            [
                "type": "user/message", "seq": 3, "time": 1_760_000_000_300,
                "data": [
                    "message": ["role": "user", "content": [["type": "text", "text": "我叫小林"]]],
                    "source": ["kind": "user", "rpcId": "bot-1"],
                ],
                "surfaceOp": "append",
            ],
            [
                "type": "tool/call", "seq": 4, "time": 1_760_000_000_400,
                "data": ["turn": 1, "step": 1, "callId": "call-1",
                         "name": "web_fetch", "arguments": "{\"url\":\"https://example.com\"}"],
            ],
        ]
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let lines = try [header] + events
        let text = try lines.map { object in
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                   as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(
            to: root.appendingPathComponent("materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }
}
