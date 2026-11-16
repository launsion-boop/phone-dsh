// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// COMPACT `stored_with_provenance`: a real chat turn writing an agent
/// playbook without an evidence argument is anchored to the host-observed
/// current user turn, so the live document still carries a record reference.
final class MemoryCompactProvenanceTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var runtime: BotMCPRuntime!
    private var records: BotRecordService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try writeSessionLog()
        try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        records = BotRecordService(store: store, gateway: gateway, workspaceRoot: root)
        runtime = BotMCPRuntime(store: store, gateway: gateway,
                                recordEvidence: records, now: { 1_760_000_000_000 })
        let provenance = BotProvenanceService(eventLog: store, resolver: records)
        await runtime.installProvenance(provenance)
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testEvidenceLessChatWriteIsAnchoredToTheCurrentUserTurn() async throws {
        await runtime.beginTurn(sessionId: "gb-main", hidden: false,
                                origin: BotTurnOrigin(rpcId: "bot-1"))
        await runtime.observeUserMessage(
            sessionId: "gb-main", seq: 8,
            source: ["kind": .string("user"), "rpcId": .string("bot-1")])
        let arguments = BotJSONValue.object([
            "action": .string("write"),
            "path": .string("agent/playbook/weekly.md"),
            "content": .string("# 周报做法\n- 成果 → 风险 → 下周计划"),
            "expected_version": .number(0),
        ])
        let callId = UUID().uuidString
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callId, name: "UpdateMemory", arguments: arguments)
        let result = await runtime.execute(
            name: "UpdateMemory", arguments: arguments,
            context: BotMCPRequestContext(callId: callId))
        XCTAssertEqual(result.structuredContent?["ok"], .bool(true),
                       "\(String(describing: result.structuredContent))")

        let events = try await store.events(after: 0, limit: 200)
        let written = try XCTUnwrap(events.first {
            $0.type == "memory.document_written"
                && $0.data["path"]?.stringValue == "agent/playbook/weekly.md"
        })
        XCTAssertEqual(written.data["evidence"]?.arrayValue?.compactMap(\.stringValue),
                       ["record://session/gb-main#8"])
        XCTAssertEqual(written.data["trust"]?.stringValue, "user")
        XCTAssertNotNil(written.data["derivation"]?.objectValue,
                        "the host-derived anchor must still get the Plan A derivation")

        // Combined read view: the production ReadMemory returns the artifact
        // source status derived by L, not a second host-constructed carrier.
        let readArguments = BotJSONValue.object([
            "path": .string("agent/playbook/weekly.md"),
        ])
        let readCall = UUID().uuidString
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: readCall, name: "ReadMemory", arguments: readArguments)
        let read = await runtime.execute(
            name: "ReadMemory", arguments: readArguments,
            context: BotMCPRequestContext(callId: readCall))
        let statuses = read.structuredContent?["source_statuses"]?.arrayValue ?? []
        XCTAssertEqual(statuses.first?["ref"]?.stringValue, "record://session/gb-main#8",
                       "ReadMemory source_statuses must name the host anchor: \(String(describing: read.structuredContent))")
        XCTAssertEqual(statuses.first?["trust"]?.stringValue, "user")
    }

    func testExplicitEvidenceIsNotReplacedByTheImplicitAnchor() async throws {
        await runtime.beginTurn(sessionId: "gb-main", hidden: false,
                                origin: BotTurnOrigin(rpcId: "bot-2"))
        await runtime.observeUserMessage(
            sessionId: "gb-main", seq: 8,
            source: ["kind": .string("user"), "rpcId": .string("bot-2")])
        let arguments = BotJSONValue.object([
            "action": .string("write"),
            "path": .string("agent/notes/explicit.md"),
            "content": .string("# note"),
            "expected_version": .number(0),
            "evidence": .array([.string(BotMemoryAuthorizer.currentUserTurnEvidence)]),
        ])
        let callId = UUID().uuidString
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callId, name: "UpdateMemory", arguments: arguments)
        let result = await runtime.execute(
            name: "UpdateMemory", arguments: arguments,
            context: BotMCPRequestContext(callId: callId))
        XCTAssertEqual(result.structuredContent?["ok"], .bool(true))
        let events = try await store.events(after: 0, limit: 200)
        let written = try XCTUnwrap(events.first {
            $0.type == "memory.document_written"
                && $0.data["path"]?.stringValue == "agent/notes/explicit.md"
        })
        XCTAssertEqual(written.data["evidence"]?.arrayValue?.compactMap(\.stringValue),
                       ["record://session/gb-main#8"])
    }

    private func writeSessionLog() throws {
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let user: [String: Any] = [
            "type": "user/message", "seq": 8, "time": 1_760_000_000_000,
            "data": [
                "message": ["role": "user", "content": [
                    ["type": "text", "text": "记住我的周报做法"]]],
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
}
