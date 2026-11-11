// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotRecordServiceTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var service: BotRecordService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-record-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-other", isDirectory: true),
            withIntermediateDirectories: true)
        store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        try await gateway.issueSession(botId: "bot-b", sessionId: "gb-other", kind: .chat)
        service = BotRecordService(store: store, gateway: gateway, workspaceRoot: root, now: { 1_000 })
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testSharedCompactionFixtureIsSearchableAndReadable() async throws {
        try writeCompactionFixture()
        let search = await service.execute(
            arguments: ["search", "PINEAPPLE_ORIGINAL"], callerSessionID: "gb-main")
        XCTAssertEqual(search.exitCode, 0, search.stdout)
        let searchObject = try json(search.stdout)
        XCTAssertEqual(searchObject["ok"] as? Bool, true)
        let hits = try XCTUnwrap((searchObject["data"] as? [String: Any])?["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.first?["ref"] as? String, "record://session/gb-main#3")

        let original = await service.execute(
            arguments: ["read", "record://session/gb-main#3"], callerSessionID: "gb-main")
        XCTAssertEqual(original.exitCode, 0, original.stdout)
        let originalLine = try line(original.stdout, ref: "record://session/gb-main#3")
        XCTAssertTrue((originalLine["raw"] as? String ?? "").contains("PINEAPPLE_ORIGINAL user statement"))
        XCTAssertEqual(originalLine["shadowedBy"] as? String, "record://session/gb-main#20")

        let checkpoint = await service.execute(
            arguments: ["read", "record://session/gb-main#20"], callerSessionID: "gb-main")
        XCTAssertEqual(checkpoint.exitCode, 0, checkpoint.stdout)
        let checkpointLine = try line(checkpoint.stdout, ref: "record://session/gb-main#20")
        let replaces = try XCTUnwrap(checkpointLine["replaces"] as? [String: Any])
        XCTAssertEqual(replaces["startRef"] as? String, "record://session/gb-main#3")
        XCTAssertEqual(replaces["endRef"] as? String, "record://session/gb-main#9")
    }


    func testProjectScopedSessionLogIsReadable() async throws {
        try writeCompactionFixture()
        let sessions = root.appendingPathComponent("materialized/home/sessions", isDirectory: true)
        let project = sessions.appendingPathComponent(
            "--dsh-workspace-.dshbot-agents-main--", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: sessions.appendingPathComponent("gb-main", isDirectory: true),
            to: project.appendingPathComponent("gb-main", isDirectory: true))
        let read = await service.execute(
            arguments: ["read", "record://session/gb-main#3"], callerSessionID: "gb-main")
        XCTAssertEqual(read.exitCode, 0, read.stdout)
        let line = try line(read.stdout, ref: "record://session/gb-main#3")
        XCTAssertTrue((line["raw"] as? String ?? "").contains("PINEAPPLE_ORIGINAL user statement"))
    }

    func testSearchIsScopedToTheCallerBot() async throws {
        try writeCompactionFixture()
        try writeLog(
            sessionID: "gb-other",
            events: [[
                "type": "user/message", "seq": 1, "time": 1_760_000_009_000,
                "data": [
                    "message": ["role": "user", "content": [["type": "text", "text": "PINEAPPLE_OTHER_BOT"]]],
                    "source": ["kind": "user", "rpcId": "bot-2"],
                ],
            ]])
        let scoped = await service.execute(
            arguments: ["search", "PINEAPPLE", "--session", "gb-main"], callerSessionID: "gb-main")
        XCTAssertEqual(scoped.exitCode, 0, scoped.stdout)
        XCTAssertFalse(scoped.stdout.contains("PINEAPPLE_OTHER_BOT"))

        let denied = await service.execute(
            arguments: ["search", "PINEAPPLE", "--session", "gb-other"], callerSessionID: "gb-main")
        XCTAssertEqual(denied.exitCode, 1)
        XCTAssertEqual(try errorCode(denied.stdout), "session_out_of_scope")

        let readDenied = await service.execute(
            arguments: ["read", "record://session/gb-other#1"], callerSessionID: "gb-main")
        XCTAssertEqual(readDenied.exitCode, 1)
        XCTAssertEqual(try errorCode(readDenied.stdout), "session_out_of_scope")

        let unclaimed = await service.execute(
            arguments: ["search", "PINEAPPLE"], callerSessionID: "gb-unclaimed")
        XCTAssertEqual(unclaimed.exitCode, 1)
        XCTAssertEqual(try errorCode(unclaimed.stdout), "unclaimed_session")
    }

    func testEventSearchAndReadStayInsideTheBot() async throws {
        try writeCompactionFixture()
        let eventSeq = try await appendEvent(
            type: "conversation.tool_result", botID: "bot-a", sessionID: "gb-main",
            originSeq: 5, data: .object([
                "message": .object([
                    "toolCallId": .string("call-1"),
                    "content": .array([.object(["type": .string("text"),
                                                "text": .string("PINEAPPLE_FETCH_RESULT")])]),
                ]),
            ]))
        let foreignSeq = try await appendEvent(
            type: "conversation.user_message", botID: "bot-b", sessionID: "gb-other",
            originSeq: 1, data: .object(["text": .string("PINEAPPLE_OTHER_BOT")]))

        let search = await service.execute(
            arguments: ["search", "PINEAPPLE_FETCH_RESULT"], callerSessionID: "gb-main")
        XCTAssertEqual(search.exitCode, 0, search.stdout)
        XCTAssertTrue(search.stdout.contains("record://event/\(eventSeq)"))
        XCTAssertFalse(search.stdout.contains("record://event/\(foreignSeq)"))

        let read = await service.execute(
            arguments: ["read", "record://event/\(eventSeq)"], callerSessionID: "gb-main")
        XCTAssertEqual(read.exitCode, 0, read.stdout)
        XCTAssertTrue(read.stdout.contains("conversation.tool_result"))

        let denied = await service.execute(
            arguments: ["read", "record://event/\(foreignSeq)"], callerSessionID: "gb-main")
        XCTAssertEqual(denied.exitCode, 1)
        XCTAssertEqual(try errorCode(denied.stdout), "session_out_of_scope")
    }

    func testEvidenceDerivationUsesTheReferencedRecord() async throws {
        try writeCompactionFixture()
        let userRef = "record://session/gb-main#3"
        let externalRef = "record://session/gb-main#4"
        let bashSeq = try await appendEvent(
            type: "conversation.tool_call", botID: "bot-a", sessionID: "gb-main",
            originSeq: 4, data: .object([
                "callId": .string("bash-call"), "name": .string("bash"),
                "arguments": .string("{}"),
            ]))
        let bashEventRef = "record://event/\(bashSeq)"
        let userEventSeq = try await appendEvent(
            type: "conversation.user_message", botID: "bot-a", sessionID: "gb-main",
            originSeq: 3, data: .object([
                "message": .object([
                    "role": .string("user"),
                    "content": .array([.object(["type": .string("text"),
                                                "text": .string("PINEAPPLE_ORIGINAL user statement")])]),
                ]),
                "source": .object(["kind": .string("user"), "rpcId": .string("bot-1")]),
            ]))
        let userEventRef = "record://event/\(userEventSeq)"

        let user = try await service.resolveEvidence(
            [userRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertEqual(user.trust, .user)
        XCTAssertEqual(user.refs, [userRef])

        let observation = try await service.resolveEvidence(
            [externalRef, userEventRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertEqual(observation.trust, .user)

        let externalOnly = try await service.resolveEvidence(
            [externalRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertEqual(externalOnly.trust, .observation)

        let bash = try await service.resolveEvidence(
            [bashEventRef], callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertEqual(bash.trust, .assistant)

        do {
            _ = try await service.resolveEvidence(
                ["record://event/999"], callerBotID: "bot-a", callerSessionID: "gb-main")
            XCTFail("unknown reference was accepted")
        } catch let error as BotRecordServiceError {
            XCTAssertEqual(error, .unknownRecord)
        }
        do {
            _ = try await service.resolveEvidence(
                [userRef], callerBotID: "bot-b", callerSessionID: "gb-other")
            XCTFail("foreign evidence was accepted")
        } catch let error as BotRecordServiceError {
            XCTAssertEqual(error, .unknownRecord)
        }
    }

    func testDeviceTaskResultEventDerivesObservationTrust() async throws {
        let resultSeq = try await appendEvent(
            type: DeviceTaskResultOutbox.recordEventType, botID: "bot-a", sessionID: "gb-main",
            originSeq: 8, data: .object([
                "deviceTaskResult": .object([
                    "deviceID": .string("device-1"),
                    "deviceDisplayName": .string("测试设备"),
                    "taskID": .string("task-1"),
                    "idempotencyKey": .string("idem-1"),
                    "goal": .string("打开页面"),
                    "status": .string("completed"),
                    "result": .string("页面已打开"),
                    "createdAt": .number(1_760_000_000_000),
                ]),
            ]))
        let evidence = try await service.resolveEvidence(
            ["record://event/\(resultSeq)"], callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertEqual(evidence.trust, .observation)

        // The acknowledgement is host bookkeeping, not an observation.
        let ackSeq = try await appendEvent(
            type: "comm.reply", botID: "bot-a", sessionID: "gb-main",
            originSeq: 9, data: .object([
                "deviceTaskResultAck": .string("device-task-result:\(resultSeq)"),
            ]))
        let ack = try await service.resolveEvidence(
            ["record://event/\(ackSeq)"], callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertEqual(ack.trust, .assistant)
    }

    func testUsageErrorsAndInvalidReferencesAreBounded() async throws {
        let missing = await service.execute(arguments: ["read"], callerSessionID: "gb-main")
        XCTAssertEqual(missing.exitCode, 2)
        XCTAssertEqual(try errorCode(missing.stdout), "invalid_arguments")
        let around = await service.execute(
            arguments: ["read", "record://session/gb-main#1", "--around", "21"],
            callerSessionID: "gb-main")
        XCTAssertEqual(around.exitCode, 2)
        XCTAssertEqual(try errorCode(around.stdout), "invalid_around")
        let reference = await service.execute(
            arguments: ["read", "record://session/gb-main"], callerSessionID: "gb-main")
        XCTAssertEqual(reference.exitCode, 2)
        XCTAssertEqual(try errorCode(reference.stdout), "invalid_reference")
        let since = await service.execute(
            arguments: ["search", "x", "--since", "yesterday"], callerSessionID: "gb-main")
        XCTAssertEqual(since.exitCode, 2)
        XCTAssertEqual(try errorCode(since.stdout), "invalid_since")
    }

    // MARK: - Helpers

    private func writeCompactionFixture() throws {
        let fixture = try BotGoldenFixture.rawObject("record-query.phone")
        let recall = try XCTUnwrap(fixture["compactionRecall"] as? [String: Any])
        let header = try XCTUnwrap(recall["header"] as? [String: Any])
        let events = try XCTUnwrap(recall["events"] as? [[String: Any]])
        try writeLog(sessionID: "gb-main", header: header, events: events)
    }

    private func writeLog(sessionID: String, header: [String: Any]? = nil,
                          events: [[String: Any]]) throws {
        var lines: [String] = []
        if let header {
            lines.append(String(decoding: try JSONSerialization.data(
                withJSONObject: header, options: [.sortedKeys]), as: UTF8.self))
        }
        for event in events {
            lines.append(String(decoding: try JSONSerialization.data(
                withJSONObject: event, options: [.sortedKeys]), as: UTF8.self))
        }
        let url = root.appendingPathComponent(
            "materialized/home/sessions/\(sessionID)/session.v4.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func appendEvent(type: String, botID: String, sessionID: String,
                             originSeq: Int, data: BotJSONValue) async throws -> Int {
        let event = BotEvent(
            type: type, eventId: "\(type):\(sessionID):\(originSeq):\(UUID().uuidString)",
            time: 1_760_000_000_000 + Int64(originSeq), origin: .dsh(sessionId: sessionID, seq: originSeq),
            traceId: "trace:\(sessionID):\(originSeq)",
            principal: BotPrincipal(botId: botID, sessionId: sessionID, kind: "chat"),
            causationId: nil, correlationId: sessionID, data: data)
        return try await store.append(event)
    }

    private func json(_ stdout: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(stdout.utf8)) as? [String: Any])
    }

    private func line(_ stdout: String, ref: String) throws -> [String: Any] {
        let object = try json(stdout)
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        let lines = try XCTUnwrap(data["lines"] as? [[String: Any]])
        return try XCTUnwrap(lines.first { $0["ref"] as? String == ref })
    }

    private func errorCode(_ stdout: String) throws -> String {
        let object = try json(stdout)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        return try XCTUnwrap(error["code"] as? String)
    }
}
