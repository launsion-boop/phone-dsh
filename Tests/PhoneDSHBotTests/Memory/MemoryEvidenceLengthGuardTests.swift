// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// Pre-write version of the maintenance "document not longer than evidence"
/// check. It is generic, uses a real record reader, and fails only when an
/// observation/record-backed write is longer than its cited readable text.
final class MemoryEvidenceLengthGuardTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var service: BotRecordService!
    private var memory: BotMemory!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-length-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .maintainer)
        service = BotRecordService(store: store, gateway: gateway, workspaceRoot: root)
        try writeSessionLog()
        memory = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "main"),
            botID: "main", recordReading: service)
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testLongMaintainerDocumentFailsBeforeAnEvent() async throws {
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .maintainer,
            source: BotMemorySource(kind: .maintenance, sessionID: "gb-main"),
            trust: .user, isMainBot: true, batchID: "mm-test")
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/notes/too-long.md",
                content: "用户每天早上七点起床，这个事实已经被重复展开成一段明显超过引用的正文。",
                expectedVersion: 0, evidence: ["record://session/gb-main#1"]),
            context: context)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, "memory-document-longer-than-evidence")
        XCTAssertEqual(result.actual, "用户每天早上七点起床，这个事实已经被重复展开成一段明显超过引用的正文。".unicodeScalars.count)
        XCTAssertEqual(result.limit, "用户每天早上七点起床。".unicodeScalars.count)
        let events = try await store.events(after: 0, limit: 100)
        XCTAssertFalse(events.contains {
            $0.type == "memory.document_written"
                && $0.data["path"]?.stringValue == "agent/notes/too-long.md"
        })

        // Shortening in the same turn passes and persists.
        let shortened = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/notes/too-long.md",
                content: "用户每天早上七点起床。",
                expectedVersion: 0, evidence: ["record://session/gb-main#1"]),
            context: context)
        XCTAssertTrue(shortened.ok, "\(String(describing: shortened.code))")
    }

    func testOrdinaryUserWriteIsNotSubjectToTheGuard() async throws {
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .user, isMainBot: true)
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "user/profile.md",
                content: "这是一段普通用户写，长度不受记录原文限制。",
                expectedVersion: 0, evidence: ["record://session/gb-main#1"]),
            context: context)
        XCTAssertTrue(result.ok, "\(String(describing: result.code))")
    }

    func testEvidenceLessTriggerWriteIsNotSubjectToTheGuard() async throws {
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .maintainer,
            source: BotMemorySource(kind: .maintenance, sessionID: "gb-main"),
            trust: .assistant, isMainBot: true)
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/notes/trigger-only.md",
                content: "没有证据的维护推断，不触发长度守卫。",
                expectedVersion: 0),
            context: context)
        XCTAssertTrue(result.ok, "\(String(describing: result.code))")
    }

    private func writeSessionLog() throws {
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let line: [String: Any] = [
            "type": "user/message", "seq": 1, "time": 1_760_000_001_000,
            "data": [
                "message": ["role": "user", "content": [[
                    "type": "text", "text": "用户每天早上七点起床。",
                ]]],
                "source": ["kind": "user", "rpcId": "user-action:test"],
            ],
        ]
        let text = try [header, line].map {
            String(decoding: try JSONSerialization.data(
                withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(
            to: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }
}
