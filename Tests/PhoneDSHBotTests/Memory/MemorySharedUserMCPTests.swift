// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class MemorySharedUserMCPTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var runtime: BotMCPRuntime!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-user-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        try writeSessionLog()
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        try await gateway.issueSession(botId: "bot-b", sessionId: "gb-second", kind: .chat)
        let records = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: root)
        runtime = BotMCPRuntime(store: store, gateway: gateway,
                                recordEvidence: records, now: { 1_760_000_000_000 })
        let provenance = BotProvenanceService(eventLog: store, resolver: records)
        await runtime.installProvenance(provenance)
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testSecondBotReadsAndRecallsSharedUserMemoryThroughMCP() async throws {
        let writeArguments = BotJSONValue.object([
            "action": .string("write"),
            "path": .string("user/profile.md"),
            "content": .string("# Profile\n- Americano"),
            "expected_version": .number(0),
            "evidence": .array([.string(BotMemoryAuthorizer.currentUserTurnEvidence)]),
        ])
        await runtime.beginTurn(sessionId: "gb-main", hidden: false,
                                origin: BotTurnOrigin(rpcId: "bot-1"))
        await runtime.observeUserMessage(
            sessionId: "gb-main", seq: 3,
            source: ["kind": .string("user"), "rpcId": .string("bot-1")])
        let write = try await call("UpdateMemory", writeArguments,
                                   sessionId: "gb-main", callId: UUID().uuidString)
        XCTAssertEqual(write.structuredContent?["ok"], .bool(true),
                       "\(String(describing: write.structuredContent))")

        // D07 repeat-2 shape: the second Bot first asks for the root listing.
        let rootArguments = BotJSONValue.object(["path": .string("user/")])
        let root = try await call("ReadMemory", rootArguments,
                                  sessionId: "gb-second", callId: UUID().uuidString)
        let entries = root.structuredContent?["entries"]?.arrayValue ?? []
        XCTAssertTrue(entries.contains { $0["path"]?.stringValue == "user/profile.md" },
                      "ReadMemory user/ must list shared documents: \(String(describing: root.structuredContent))")

        let readArguments = BotJSONValue.object(["path": .string("user/profile.md")])
        let read = try await call("ReadMemory", readArguments,
                                  sessionId: "gb-second", callId: UUID().uuidString)
        XCTAssertEqual(read.structuredContent?["content"]?.stringValue,
                       "# Profile\n- Americano",
                       "second Bot must read the shared user document: \(String(describing: read.structuredContent))")

        let recallArguments = BotJSONValue.object([
            "query": .string("Americano"), "limit": .number(10),
        ])
        let recall = try await call("RecallMemory", recallArguments,
                                    sessionId: "gb-second", callId: UUID().uuidString)
        let hits = recall.structuredContent?["hits"]?.arrayValue ?? []
        XCTAssertEqual(hits.first?["path"]?.stringValue, "user/profile.md",
                       "second Bot must recall shared user content: \(String(describing: recall.structuredContent))")
    }

    private func writeSessionLog() throws {
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let user: [String: Any] = [
            "type": "user/message", "seq": 3, "time": 1_760_000_000_000,
            "data": [
                "message": ["role": "user", "content": [
                    ["type": "text", "text": "我周报喜欢先结论、后风险、最后计划"]]],
                "source": ["kind": "user", "rpcId": "bot-1"],
            ],
        ]
        let lines = [header, user].map {
            String(decoding: try! JSONSerialization.data(
                withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }

    private func call(_ name: String, _ arguments: BotJSONValue,
                      sessionId: String, callId: String) async throws -> BotMCPCallResult {
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
            callId: callId, name: name, arguments: arguments)
        return await runtime.execute(
            name: name, arguments: arguments,
            context: BotMCPRequestContext(callId: callId))
    }
}
