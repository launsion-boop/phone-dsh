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

    /// The host resolves the reserved value from the current turn's rpcId, not
    /// from a model-supplied seq. This is the E02 failure path: the model knows
    /// what the user said but not the session-log seq.
    func testCurrentUserTurnResolvesToTheOpeningUserMessageForUserWrite() async throws {
        let written = try await call([
            "action": "write", "path": "user/preferences/drinks.md",
            "content": "# Drinks\n\n- OAT_LATTE_B",
            "expected_version": 0,
            "evidence": ["current-user-turn"],
        ])
        XCTAssertNotEqual(written.isError, true,
                          "\(String(describing: written.structuredContent))")
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true))
        let memory = await runtime.memory(for: "bot-a")
        guard case let .document(document) = try await memory.read(path: "user/preferences/drinks.md") else {
            return XCTFail("expected document")
        }
        XCTAssertEqual(document.trust, "user")
        XCTAssertEqual(document.evidence, ["record://session/gb-main#3"],
                       "the stored evidence must be the host-resolved user message, never the reserved literal")
    }

    /// The reserved value can be combined with explicit references. The host
    /// places its own reference in the caller-supplied order and merges the
    /// user trust without dropping the explicit observation.
    func testCurrentUserTurnCombinesWithExplicitEvidence() async throws {
        let written = try await call([
            "action": "write", "path": "user/preferences/drinks.md",
            "content": "# Drinks\n\n- OAT_LATTE_B",
            "expected_version": 0,
            "evidence": ["current-user-turn", "record://session/gb-main#4"],
        ])
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true))
        let memory = await runtime.memory(for: "bot-a")
        guard case let .document(document) = try await memory.read(path: "user/preferences/drinks.md") else {
            return XCTFail("expected document")
        }
        XCTAssertEqual(document.trust, "user")
        XCTAssertEqual(document.evidence, ["record://session/gb-main#3", "record://session/gb-main#4"])
    }

    /// The host observation is per turn: starting the next user turn clears
    /// it, so a delayed call cannot reuse the previous user message as
    /// `current-user-turn`.
    func testCurrentUserTurnIsNotReusableInTheNextTurn() async throws {
        let written = try await call([
            "action": "write", "path": "user/preferences/drinks.md",
            "content": "# Drinks\n\n- AMERICANO_A",
            "expected_version": 0,
            "evidence": ["current-user-turn"],
        ])
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true))

        await runtime.beginTurn(sessionId: "gb-main", hidden: false,
                                origin: BotTurnOrigin(rpcId: "bot-2"))
        let arguments = try BotJSONValue.parse(
            JSONSerialization.data(withJSONObject: [
                "action": "replace", "path": "user/preferences/drinks.md",
                "find": "AMERICANO_A", "replace": "OAT_LATTE_B",
                "expected_version": 1, "evidence": ["current-user-turn"],
            ], options: [.sortedKeys]))
        let rejected = try await registerAndExecute(
            runtime, name: "UpdateMemory", arguments: arguments,
            sessionId: "gb-main", callId: UUID().uuidString)
        XCTAssertEqual(rejected.isError, true)
        XCTAssertEqual(rejected.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-evidence-invalid")
        let memory = await runtime.memory(for: "bot-a")
        guard case let .document(document) = try await memory.read(path: "user/preferences/drinks.md") else {
            return XCTFail("expected document")
        }
        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.content, "# Drinks\n\n- AMERICANO_A")
    }

    /// Hidden, held and `agent:` turns have no user-turn authority, so the
    /// reserved value must fail closed instead of falling back to the last
    /// user message observed in the session.
    func testCurrentUserTurnIsRejectedOutsideARealUserTurn() async throws {
        let cases: [(hidden: Bool, held: Bool, rpcId: String, label: String)] = [
            (true, false, "routine:run-1", "hidden"),
            (false, true, "held:digest-1", "held"),
            (false, false, "agent:call-1", "agent:"),
        ]
        for item in cases {
            let rejected = try await call([
                "action": "write", "path": "user/preferences/drinks.md",
                "content": "# Drinks\n\n- OAT_LATTE_B",
                "expected_version": 0,
                "evidence": ["current-user-turn"],
            ], hidden: item.hidden, held: item.held, rpcId: item.rpcId)
            XCTAssertEqual(rejected.isError, true, item.label)
            XCTAssertEqual(rejected.structuredContent?["error"]?["code"]?.stringValue,
                           "memory-evidence-invalid", item.label)
        }
        let memory = await runtime.memory(for: "bot-a")
        let userDocuments = try await memory.documents(scope: .user)
        XCTAssertFalse(userDocuments.contains { $0.path == "user/preferences/drinks.md" })
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

        // A guessed seq is still a normal reference and must be rejected when
        // the session log has no such line. The reserved literal is not a
        // fallback for a forged reference.
        let forgedSeq = try await call([
            "action": "write", "path": "user/preferences/drinks.md",
            "content": "伪造的当前消息序号", "expected_version": 0,
            "evidence": ["record://session/gb-main#999"],
        ])
        XCTAssertEqual(forgedSeq.isError, true)
        XCTAssertEqual(forgedSeq.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-evidence-invalid")
    }

    func testMaintainerWriteRejectsErasedEvidenceAsRecordErased() async throws {
        let first = try await call([
            "action": "write", "path": "agent/notes/secret.md", "content": "secret",
            "expected_version": 0,
        ])
        XCTAssertEqual(first.structuredContent?["ok"], .bool(true))
        let events = try await store.events(after: 0, limit: 100)
        let written = try XCTUnwrap(events.first {
            $0.type == "memory.document_written"
                && $0.data["path"]?.stringValue == "agent/notes/secret.md"
        })
        let sequence = try XCTUnwrap(written.commitSeq)
        let memory = await runtime.memory(for: "bot-a")
        let erased = try await memory.erase(path: "agent/notes/secret.md")
        XCTAssertTrue(erased.ok, erased.error ?? "")

        let maintainerSession = "gb-maintainer-0123456789abcdef0123456789abcdef"
        _ = try await runtime.issueSession(
            botId: "bot-a", sessionId: maintainerSession, kind: .maintainer)
        await runtime.beginMaintenanceTurn(
            sessionId: maintainerSession,
            batchID: "mm-0123456789abcdef0123456789abcdef")
        await runtime.beginTurn(sessionId: maintainerSession, hidden: true)
        let arguments = try BotJSONValue.parse(
            JSONSerialization.data(withJSONObject: [
                "action": "write", "path": "agent/notes/after-erased-evidence.md",
                "content": "must not be written", "expected_version": 0,
                "evidence": ["record://event/\(sequence)"],
            ], options: [.sortedKeys]))
        let rejected = try await registerAndExecute(
            runtime, name: "UpdateMemory", arguments: arguments,
            sessionId: maintainerSession, callId: UUID().uuidString)
        XCTAssertEqual(rejected.isError, true)
        XCTAssertEqual(rejected.structuredContent?["error"]?["code"]?.stringValue,
                       "record_erased")
        let documents = try await memory.documents(scope: .agent)
        XCTAssertFalse(documents.contains {
            $0.path == "agent/notes/after-erased-evidence.md"
        })
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

    /// S5 writes the device-task terminal record as `comm.inbound`; the
    /// integration trust fix must still work through S2's document write path.
    func testDeviceTaskResultEvidenceDerivesObservationThroughDocumentWrite() async throws {
        // S4's grant store fails closed on a non-empty event stream without a
        // snapshot. Production recovers at composition start; seed it here
        // before appending the integration's comm.inbound record.
        try await runtime.grants.recover()
        let commitSeq = try await store.append(BotEvent(
            type: DeviceTaskResultOutbox.recordEventType,
            eventId: "device-task-result:memory-evidence",
            time: 1_760_000_000_500,
            origin: .local(source: "comm-service"),
            traceId: "device-task-result:memory-evidence",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil,
            correlationId: "device-task-1",
            data: .object([
                "deviceTaskResult": .object([
                    "deviceID": .string("device-1"),
                    "taskID": .string("task-1"),
                    "status": .string("completed"),
                    "result": .string("页面已打开"),
                ]),
            ])))
        let ref = "record://event/\(commitSeq)"
        let written = try await call([
            "action": "write", "path": "agent/notes/device.md",
            "content": "设备任务完成：页面已打开", "expected_version": 0,
            "evidence": [ref],
        ])
        XCTAssertNotEqual(written.isError, true,
                          "\(String(describing: written.structuredContent))")
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true),
                       "\(String(describing: written.structuredContent))")
        let memory = await runtime.memory(for: "bot-a")
        guard case let .document(document) = try await memory.read(path: "agent/notes/device.md") else {
            return XCTFail("expected document")
        }
        XCTAssertEqual(document.trust, "observation")
        XCTAssertEqual(document.evidence, [ref])
    }

    // MARK: - Helpers

    private func call(
        _ fields: [String: Any],
        name: String = "UpdateMemory",
        hidden: Bool = false,
        held: Bool = false,
        rpcId: String = "bot-1"
    ) async throws -> BotMCPCallResult {
        let arguments = try BotJSONValue.parse(
            JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
        await runtime.beginTurn(sessionId: "gb-main", hidden: hidden, held: held,
                                origin: BotTurnOrigin(rpcId: rpcId))
        // The production host records the live session/follow user message
        // before the model can call UpdateMemory. The unit fixture feeds the
        // same host-observed event with seq 3 from writeSessionLog().
        await runtime.observeUserMessage(
            sessionId: "gb-main", seq: 3,
            source: ["kind": .string("user"), "rpcId": .string(rpcId)])
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
