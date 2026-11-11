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

    func testUserWriteRequiresUserMessageEvidenceAndStoresTrust() async throws {
        let userRef = "record://session/gb-main#3"
        let written = try await call([
            "action": "write", "path": "user/profile.md",
            "content": "# Profile\n\n- 用户叫小林",
            "expected_version": 0,
            "evidence": [userRef],
        ])
        XCTAssertNotEqual(written.isError, true)
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true))
        let memory = await runtime.memory(for: "bot-a")
        guard case let .document(document) = try await memory.read(path: "user/profile.md") else {
            return XCTFail("expected document")
        }
        XCTAssertEqual(document.content, "# Profile\n\n- 用户叫小林")
        XCTAssertEqual(document.trust, "user")
        XCTAssertEqual(document.evidence, [userRef])
    }

    func testUserBoundaryRejectsMissingOrNonUserEvidence() async throws {
        let missing = try await call([
            "action": "write", "path": "user/profile.md",
            "content": "没有引用的用户事实", "expected_version": 0,
        ])
        XCTAssertEqual(missing.structuredContent?["ok"], .bool(false))
        XCTAssertEqual(missing.structuredContent?["code"]?.stringValue,
                       "memory-evidence-required")

        let observed = try await call([
            "action": "write", "path": "user/log/2025-10.md",
            "content": "网页观察", "expected_version": 0,
            "evidence": ["record://session/gb-main#4"],
        ])
        XCTAssertEqual(observed.structuredContent?["ok"], .bool(false))
        XCTAssertEqual(observed.structuredContent?["code"]?.stringValue,
                       "memory-evidence-required")

        let memory = await runtime.memory(for: "bot-a")
        let userDocuments = try await memory.documents(scope: .user)
        XCTAssertFalse(userDocuments.contains { !$0.path.hasSuffix("INDEX.md") })
    }

    func testObservationEvidenceWritesAgentScopeWithObservationTrust() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/weather.md",
            "content": "网页说今天下雨", "expected_version": 0,
            "evidence": ["record://session/gb-main#4"],
        ])
        XCTAssertNotEqual(written.isError, true)
        let memory = await runtime.memory(for: "bot-a")
        guard case let .document(document) = try await memory.read(path: "agent/notes/weather.md") else {
            return XCTFail("expected document")
        }
        XCTAssertEqual(document.trust, "observation")
        XCTAssertEqual(document.evidence, ["record://session/gb-main#4"])
    }

    func testInvalidOrForeignEvidenceFailsClosed() async throws {
        let invalid = try await call([
            "action": "write", "path": "agent/notes/a.md", "content": "坏引用",
            "expected_version": 0, "evidence": ["record://session/gb-main"],
        ])
        XCTAssertEqual(invalid.isError, true)
        XCTAssertEqual(invalid.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-evidence-invalid")

        let unknown = try await call([
            "action": "write", "path": "agent/notes/a.md", "content": "不存在的记录",
            "expected_version": 0, "evidence": ["record://event/999"],
        ])
        XCTAssertEqual(unknown.isError, true)
        XCTAssertEqual(unknown.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-evidence-invalid")
    }

    func testStaleVersionIsRejectedWithoutDowngrading() async throws {
        let first = try await call([
            "action": "write", "path": "agent/notes/a.md", "content": "one",
            "expected_version": 0,
        ])
        XCTAssertEqual(first.structuredContent?["version"], .number(1))
        let stale = try await call([
            "action": "write", "path": "agent/notes/a.md", "content": "two",
            "expected_version": 0,
        ])
        XCTAssertEqual(stale.structuredContent?["ok"], .bool(false))
        XCTAssertEqual(stale.structuredContent?["code"]?.stringValue,
                       "memory-version-conflict")
        XCTAssertEqual(stale.structuredContent?["current_version"], .number(1))
        let memory = await runtime.memory(for: "bot-a")
        guard case let .document(document) = try await memory.read(path: "agent/notes/a.md") else {
            return XCTFail("expected document")
        }
        XCTAssertEqual(document.content, "one")
    }

    func testReadMemoryDocumentDirectoryAndHistory() async throws {
        _ = try await call([
            "action": "write", "path": "agent/notes/a.md", "content": "v1",
            "expected_version": 0,
        ])
        _ = try await call([
            "action": "append", "path": "agent/notes/a.md", "content": "\nv2",
            "expected_version": 1,
        ])
        let read = try await call(["path": "agent/notes/a.md"], name: "ReadMemory")
        XCTAssertEqual(read.structuredContent?["kind"], .string("document"))
        XCTAssertEqual(read.structuredContent?["version"], .number(2))
        XCTAssertEqual(read.structuredContent?["content"], .string("v1\nv2"))
        XCTAssertNotNil(read.structuredContent?["evidence"])

        let history = try await call(
            ["path": "agent/notes/a.md", "version": 1], name: "ReadMemory")
        XCTAssertEqual(history.structuredContent?["version"], .number(1))
        XCTAssertEqual(history.structuredContent?["content"], .string("v1"))

        let listing = try await call(["path": "agent/notes"], name: "ReadMemory")
        XCTAssertEqual(listing.structuredContent?["kind"], .string("directory"))
        XCTAssertEqual(listing.structuredContent?["entries"]?.arrayValue?.count, 1)
    }

    // MARK: - Helpers

    private func call(
        _ fields: [String: Any],
        name: String = "UpdateMemory"
    ) async throws -> BotMCPCallResult {
        let arguments = try BotJSONValue.parse(
            JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
        await runtime.beginTurn(sessionId: "gb-main", hidden: false,
                                origin: BotTurnOrigin(rpcId: "bot-1"))
        return try await registerAndExecute(
            runtime, name: name, arguments: arguments,
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
