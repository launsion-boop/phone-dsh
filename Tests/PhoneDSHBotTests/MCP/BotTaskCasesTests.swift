// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Conformance for the frozen `task-cases.phone.json` vector.
///
/// The lifecycle cases drive the real `BotMCPRuntime` tool layer and the real
/// `BotDSHRemoteRuntime` over scripted DSH frames; the restore cases seed the
/// real SQLite event store with a frozen `persistedTask` snapshot. No expected
/// value is copied from this file into the vector.
final class BotTaskCasesTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try BotGoldenFixture.rawObject("task-cases.phone")
    }

    private func object(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private func cases(_ group: String) throws -> [[String: Any]] {
        guard let list = try fixture()[group] as? [[String: Any]] else {
            throw BotGoldenFixture.FixtureError(description: "task-cases.phone.\(group)")
        }
        return list
    }

    private func json(_ value: Any) throws -> BotJSONValue {
        try BotJSONValue.parse(JSONSerialization.data(withJSONObject: value))
    }

    private func substitute(_ value: Any, _ tokens: [String: String]) -> Any {
        if let text = value as? String {
            var result = text
            for (token, replacement) in tokens {
                result = result.replacingOccurrences(of: token, with: replacement)
            }
            return result
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { substitute($0, tokens) }
        }
        if let array = value as? [Any] {
            return array.map { substitute($0, tokens) }
        }
        return value
    }

    private func scripted(_ specs: [[String: Any]]) -> [BotScriptedEvent] {
        specs.map { spec in
            switch spec["type"] as? String {
            case "assistant": return .assistant(spec["text"] as? String ?? "")
            case "end": return .end(spec["reason"] as? String ?? "completed",
                                    turn: spec["turn"] as? Int ?? 1)
            default: return .turn(spec["turn"] as? Int ?? 1)
            }
        }
    }

    private func transport(_ setup: [String: Any]?) -> BotScriptedRemoteTransport {
        var scripts: [String: [[BotScriptedEvent]]] = [:]
        for (sessionID, groups) in setup?["scripts"] as? [String: Any] ?? [:] {
            scripts[sessionID] = (groups as? [[[String: Any]]] ?? [])
                .map { scripted($0) }
        }
        return BotScriptedRemoteTransport(scripts: scripts)
    }

    private func makeParent(_ runtime: BotMCPRuntime, sessionID: String,
                            kind: BotSessionKind) async throws -> BotResolvedToolCall {
        let principal = try await runtime.issueSession(
            botId: "main", sessionId: sessionID, kind: kind)
        let arguments = BotJSONValue.object(["prompt": .string("parent")])
        let callID = UUID().uuidString
        let attribution = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionID,
            callId: callID, name: "Task", arguments: arguments)
        guard let call = BotResolvedToolCall(
            sessionId: sessionID, callId: callID, agentId: "main",
            principal: principal, attribution: attribution) else {
            throw BotMCPError.unauthorized
        }
        return call
    }

    private func execute(_ fixture: BotMCPTestFixture, name: String,
                         sessionID: String, kind: BotSessionKind,
                         arguments: BotJSONValue) async throws -> BotMCPCallResult {
        // The parent call already issued and claimed this session. Issuing it
        // again would rotate the incarnation and make the live task look like
        // it belongs to a different principal (`ownedTask` is fail-closed).
        let callID = "task-case-\(UUID().uuidString)"
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionID,
            callId: callID, name: name, arguments: arguments)
        return await fixture.runtime.execute(
            name: name, arguments: arguments,
            context: BotMCPRequestContext(callId: callID))
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition did not become true", file: file, line: line)
    }

    private func resultFields(_ result: BotMCPCallResult) throws -> [String: BotJSONValue] {
        guard case .object(let fields)? = result.structuredContent else {
            throw BotGoldenFixture.FixtureError(description: "result has no object")
        }
        return fields
    }

    private func recordValue(_ fields: [String: BotJSONValue]) -> BotJSONValue {
        var record = fields
        record.removeValue(forKey: "authorization")
        return .object(record)
    }

    private func assertAuthorization(_ fields: [String: BotJSONValue],
                                     _ expected: [String: Any], _ name: String) {
        guard case .object(let auth)? = fields["authorization"] else {
            XCTFail("\(name): missing authorization")
            return
        }
        XCTAssertEqual(auth["canWriteOutsideWorkspace"], .bool(false), "\(name): auth write")
        XCTAssertEqual(auth["canNetworkWrite"], .bool(false), "\(name): auth network")
        XCTAssertEqual(auth["canDelegateTasks"], .bool(false), "\(name): auth delegate")
        XCTAssertTrue(auth["workspaceRoot"]?.stringValue?.hasSuffix(
            expected["workspaceRootSuffix"] as? String ?? "") == true,
                      "\(name): workspace root")
        XCTAssertEqual(auth["allowedWriteDirectories"]?.arrayValue?.count,
                       expected["allowedWriteDirectoriesCount"] as? Int,
                       "\(name): write directories")
    }

    private func assertPersistedTask(_ events: [BotEvent], _ expected: [String: Any],
                                     _ name: String) {
        let snapshots = events.compactMap { event -> [String: BotJSONValue]? in
            event.data["persistedTask"]?.objectValue
        }
        guard let latest = snapshots.last else {
            XCTFail("\(name): no persistedTask event")
            return
        }
        for (key, value) in expected {
            let wrapped = ["value": value]
            let parsed = try? BotJSONValue.parse(
                JSONSerialization.data(withJSONObject: wrapped))
            XCTAssertEqual(latest[key], parsed?["value"],
                           "\(name): persistedTask.\(key)")
        }
    }

    private func assertRecordEvents(_ fixture: BotMCPTestFixture,
                                    _ caseSpec: [String: Any],
                                    taskID: String, sessionID: String) async throws {
        let expect = object(caseSpec["expect"])
        let events = try await botEvents(fixture.store).filter { $0.type.hasPrefix("task.") }
        let order = expect["eventOrder"] as? [String] ?? []
        var index = 0
        for event in events where index < order.count && event.type == order[index] {
            index += 1
        }
        XCTAssertEqual(index, order.count,
                       "\(caseSpec["name"] as? String ?? "?"): task event order")
        if let persisted = expect["persistedTask"] as? [String: Any] {
            let tokens = ["<taskId>": taskID, "<sessionId>": sessionID]
            assertPersistedTask(events, substitute(persisted, tokens) as? [String: Any] ?? [:],
                                caseSpec["name"] as? String ?? "?")
        }
    }

    private func waitForRequest(_ transport: BotScriptedRemoteTransport,
                                _ expected: String) async throws {
        try await waitUntil {
            transport.promptRequestIds.contains { $0.requestId == expected }
        }
    }

    private func cleanupStop(_ remote: BotDSHRemoteRuntime,
                             _ transport: BotScriptedRemoteTransport,
                             taskID: String, sessionID: String,
                             parent: BotResolvedToolCall) async throws {
        let stopping = Task {
            try await remote.stop(taskId: taskID, parent: parent)
        }
        try await waitUntil { transport.cancellations.contains(sessionID) }
        transport.resume(sessionID)
        _ = try await stopping.value
    }

    // MARK: - Lifecycle

    private func runLifecycle(_ caseSpec: [String: Any]) async throws {
        let name = caseSpec["name"] as? String ?? "?"
        let setup = object(caseSpec["setup"])
        let parentSession = setup["parentSessionId"] as? String ?? "gb-main"
        let parentKind = BotSessionKind(rawValue: setup["parentKind"] as? String ?? "chat") ?? .chat
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = transport(setup)
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime,
                                                       now: { 1_000 })
        if let parentTurn = setup["parentTurn"] as? [[String: Any]] {
            transport.queue(sessionId: parentSession, events: scripted(parentTurn))
            _ = try await remote.sendUserMessage("parent")
        }
        // Issue the parent *after* the visible parent turn: ensureMainSession
        // re-issues the chat token and would rotate an earlier incarnation.
        let parent = try await makeParent(fixture.runtime, sessionID: parentSession,
                                          kind: parentKind)
        for session in setup["pause"] as? [String] ?? [] {
            transport.pause(session)
        }

        var started: BotTaskRecord?
        if let start = setup["start"] as? [String: Any] {
            started = try await remote.start(request: BotTaskRequest(
                parent: parent,
                title: start["taskTitle"] as? String ?? "task",
                prompt: start["prompt"] as? String ?? "work",
                asynchronous: start["async"] as? Bool ?? true,
                timeoutMs: start["timeoutMs"] as? Int ?? 30_000))
            if let record = started {
                try await waitUntil {
                    transport.promptHistory.contains { $0.sessionId == record.sessionId }
                }
            }
        }

        let kind = caseSpec["kind"] as? String ?? "start"
        let expect = object(caseSpec["expect"])
        for session in setup["resume"] as? [String] ?? [] {
            transport.resume(session)
        }
        var result: BotMCPCallResult
        switch kind {
        case "start":
            result = try await execute(fixture, name: "Task",
                                       sessionID: parentSession, kind: parentKind,
                                       arguments: try json(caseSpec["arguments"] ?? [:]))
        case "await":
            let arguments = try json(substitute(caseSpec["arguments"] ?? [:],
                                                ["<taskId>": started?.taskId ?? ""]))
            let clock = Date()
            result = try await execute(fixture, name: "AwaitTask",
                                       sessionID: parentSession, kind: parentKind,
                                       arguments: arguments)
            if let limit = expect["elapsedUnderMs"] as? Int {
                XCTAssertLessThan(Date().timeIntervalSince(clock) * 1_000,
                                  Double(limit), "\(name): AwaitTask honoured timeout_ms")
            }
        default:
            let arguments = try json(substitute(caseSpec["arguments"] ?? [:],
                                                ["<taskId>": started?.taskId ?? ""]))
            if expect["stopAsync"] as? Bool == true, let record = started {
                let stopping = Task {
                    try await execute(fixture, name: "StopSubagent",
                                      sessionID: parentSession, kind: parentKind,
                                      arguments: arguments)
                }
                try await waitUntil { transport.cancellations.contains(record.sessionId) }
                transport.resume(record.sessionId)
                result = try await stopping.value
            } else {
                result = try await execute(fixture, name: "StopSubagent",
                                           sessionID: parentSession, kind: parentKind,
                                           arguments: arguments)
            }
        }

        XCTAssertNotEqual(result.isError, true, "\(name): \(botTeamResultText(result))")
        let fields = try resultFields(result)
        let taskID = fields["task_id"]?.stringValue ?? started?.taskId ?? ""
        let sessionID = fields["sessionId"]?.stringValue ?? started?.sessionId ?? ""
        let tokens = ["<taskId>": taskID, "<sessionId>": sessionID]
        let expectedRecord = try json(substitute(expect["record"] ?? [:], tokens))
        XCTAssertEqual(recordValue(fields), expectedRecord, "\(name): task record")
        if let authorization = expect["authorization"] as? [String: Any] {
            assertAuthorization(fields, authorization, name)
        } else {
            XCTAssertNil(fields["authorization"], "\(name): StopSubagent has no authorization")
        }
        if expect["text"] as? String == "@canonicalJSON@" {
            XCTAssertEqual(try BotJSONValue.parse(Data(botTeamResultText(result).utf8)),
                           result.structuredContent, "\(name): canonical JSON text")
        }

        for request in expect["requestIds"] as? [String] ?? [] {
            let expected = substitute(request, tokens) as? String ?? request
            if expected.hasPrefix("task-settled:") {
                try await waitForRequest(transport, expected)
            }
            XCTAssertTrue(transport.promptRequestIds.contains { $0.requestId == expected },
                          "\(name): missing request id \(expected)")
        }
        try await assertRecordEvents(fixture, caseSpec, taskID: taskID, sessionID: sessionID)

        if expect["cleanup"] as? String == "stop", let record = started {
            try await cleanupStop(remote, transport, taskID: record.taskId,
                                  sessionID: record.sessionId, parent: parent)
        }
        if let cancelled = expect["cancelledSession"] as? String {
            XCTAssertTrue(transport.cancellations.contains(cancelled),
                          "\(name): stop must cancel the task turn")
        }
        if expect["noResult"] as? Bool == true {
            XCTAssertNil(fields["result"], "\(name): stopped record keeps no result")
        }
    }

    func testValidTaskCases() async throws {
        for caseSpec in try cases("valid") {
            try await runLifecycle(caseSpec)
        }
    }

    func testInvalidTaskCases() async throws {
        for caseSpec in try cases("invalid") {
            let name = caseSpec["name"] as? String ?? "?"
            let setup = object(caseSpec["setup"])
            let setupSession = setup["parentSessionId"] as? String ?? "gb-main"
            let setupKind = BotSessionKind(rawValue: setup["parentKind"] as? String ?? "chat") ?? .chat
            let parentSession = setup["executeSessionId"] as? String ?? setupSession
            let parentKind = setupKind
            let fixture = try makeBotMCPFixture()
            defer { fixture.cleanup() }
            let transport = transport(setup)
            let remote = try await BotDSHRemoteRuntime(transport: transport,
                                                       runtime: fixture.runtime, now: { 1_000 })
            if let parentTurn = setup["parentTurn"] as? [[String: Any]] {
                transport.queue(sessionId: setupSession, events: scripted(parentTurn))
                _ = try await remote.sendUserMessage("parent")
            }
            let setupParent = try await makeParent(fixture.runtime, sessionID: setupSession,
                                                    kind: setupKind)
            if parentSession != setupSession {
                _ = try await makeParent(fixture.runtime, sessionID: parentSession,
                                         kind: parentKind)
            }
            for session in setup["pause"] as? [String] ?? [] {
                transport.pause(session)
            }
            var started: BotTaskRecord?
            if let start = setup["start"] as? [String: Any] {
                started = try await remote.start(request: BotTaskRequest(
                    parent: setupParent,
                    title: start["taskTitle"] as? String ?? "task",
                    prompt: start["prompt"] as? String ?? "work",
                    asynchronous: start["async"] as? Bool ?? true,
                    timeoutMs: start["timeoutMs"] as? Int ?? 30_000))
            }
            let kind = caseSpec["kind"] as? String ?? "start"
            let tool = kind == "start" ? "Task" : kind == "await" ? "AwaitTask" : "StopSubagent"
            let arguments = try json(substitute(caseSpec["arguments"] ?? [:],
                                                ["<taskId>": started?.taskId ?? ""]))
            let result: BotMCPCallResult
            do {
                result = try await execute(fixture, name: tool, sessionID: parentSession,
                                           kind: parentKind, arguments: arguments)
            } catch let error as BotMCPError {
                // The task tools normally turn a thrown error into a failure
                // result. A thrown one is still a contract failure here.
                let expect = object(caseSpec["expect"])
                XCTAssertEqual(botMCPMessage(error), expect["text"] as? String,
                               "\(name): thrown error")
                continue
            }
            let expect = object(caseSpec["expect"])
            let expectedError = object(object(expect["structured"])["error"])
            XCTAssertEqual(result.isError, true, "\(name): expected failure")
            if let error = result.structuredContent?["error"] {
                XCTAssertEqual(error["code"]?.stringValue,
                               expectedError["code"] as? String, "\(name): code")
                XCTAssertEqual(error["message"]?.stringValue,
                               expectedError["message"] as? String, "\(name): message")
            } else {
                XCTFail("\(name): missing structured error")
            }
            if expect["cleanup"] as? String == "stop", let record = started {
                // The caller that failed may not own the task (foreign
                // session); the setup parent always does.
                try await cleanupStop(remote, transport, taskID: record.taskId,
                                      sessionID: record.sessionId, parent: setupParent)
            }
        }
    }

    private func botMCPMessage(_ error: BotMCPError) -> String {
        switch error {
        case .invalidRequest(let message), .unavailable(let message): return message
        case .unauthorized: return "Unauthorized"
        case .unknownTool(let name): return "未知工具：\(name)"
        case .unattributed: return "这次调用无法归属到会话"
        case .crossSessionDenied: return "请求的会话不属于当前调用方"
        case .timeout: return "操作超时了"
        }
    }

    // MARK: - persistedTask restore

    private func seed(_ fixture: BotMCPTestFixture, _ caseSpec: [String: Any]) async throws {
        for event in caseSpec["seedEvents"] as? [[String: Any]] ?? [] {
            let principal = BotGatewayPrincipal(
                botId: "main", sessionId: event["principalSessionId"] as? String ?? "gb-main",
                kind: BotSessionKind(rawValue: event["principalKind"] as? String ?? "chat") ?? .chat,
                expiresAt: Int64.max)
            _ = try await fixture.runtime.eventWriter.append(
                type: event["type"] as? String ?? "task.updated",
                principal: principal,
                data: try json(event["data"] ?? [:]),
                eventId: event["eventId"] as? String ?? UUID().uuidString)
        }
    }

    func testRestoreCases() async throws {
        for caseSpec in try cases("restoreCases") {
            let name = caseSpec["name"] as? String ?? "?"
            let expect = object(caseSpec["expect"])
            let fixture = try makeBotMCPFixture()
            defer { fixture.cleanup() }
            // `recover()` appends the empty grant snapshot when the log is
            // empty; without it a seeded task event would look like a corrupt
            // grant history (`missingSnapshot`) to the runtime initializer.
            _ = try await fixture.runtime.grants.recover()
            try await seed(fixture, caseSpec)
            let wakeScripts = caseSpec["wakeScripts"] as? [String: Any] ?? [:]
            var scripts: [String: [[BotScriptedEvent]]] = [:]
            for (session, groups) in wakeScripts {
                scripts[session] = (groups as? [[[String: Any]]] ?? []).map { scripted($0) }
            }
            let transport = BotScriptedRemoteTransport(scripts: scripts)
            let remote = try await BotDSHRemoteRuntime(transport: transport,
                                                       runtime: fixture.runtime, now: { 1_000 })
            let recordSpec = object(expect["record"])
            let parent = try await makeParent(fixture.runtime, sessionID: "gb-main", kind: .chat)

            if let expectedStatus = expect["status"] as? String {
                let taskID = recordSpec["task_id"] as? String ?? ""
                let sessionID = recordSpec["sessionId"] as? String ?? ""
                let record = try await remote.await(taskId: taskID, timeoutMs: 50,
                                                    parent: parent)
                XCTAssertEqual(record.status, expectedStatus, "\(name): restored status")
                let tokens = ["<taskId>": taskID, "<sessionId>": sessionID]
                XCTAssertEqual(record.jsonValue, try json(substitute(recordSpec, tokens)),
                               "\(name): restored record")
            } else if let code = expect["errorCode"] as? String {
                do {
                    _ = try await remote.await(
                        taskId: "task-legacy", timeoutMs: 50, parent: parent)
                    XCTFail("\(name): legacy record must not restore")
                } catch BotMCPError.invalidRequest(let message) {
                    XCTAssertEqual("invalid_arguments", code, "\(name): code")
                    XCTAssertEqual(message, expect["errorMessage"] as? String,
                                   "\(name): message")
                }
            }

            let delivered = await remote.deliverInterruptedTaskWakes()
            XCTAssertEqual(delivered, object(expect["wake"])["delivered"] as? Int ?? 0,
                           "\(name): wake count")
            let wake = object(expect["wake"])
            if let request = wake["requestId"] as? String {
                XCTAssertTrue(transport.promptRequestIds.contains { $0.requestId == request },
                              "\(name): wake request id")
                let prompt = transport.promptHistory.last { $0.sessionId == wake["sessionId"] as? String }
                for fragment in wake["promptContains"] as? [String] ?? [] {
                    XCTAssertTrue(prompt?.text.contains(fragment) == true,
                                  "\(name): prompt is missing \(fragment)")
                }
            }
            let second = await remote.deliverInterruptedTaskWakes()
            XCTAssertEqual(second, expect["secondWake"] as? Int ?? 0,
                           "\(name): second wake")
            let events = try await botEvents(fixture.store)
            if let suffix = expect["appendedEventSuffix"] as? String {
                XCTAssertTrue(events.contains { $0.eventId.hasSuffix(suffix) },
                              "\(name): missing persisted event \(suffix)")
            }
            if let suffix = expect["wakePersistedSuffix"] as? String {
                XCTAssertTrue(events.contains { $0.eventId.hasSuffix(suffix) },
                              "\(name): missing wake marker \(suffix)")
                let marked = events.last { $0.type == "task.updated"
                    && $0.eventId.hasSuffix(suffix) }
                XCTAssertEqual(marked?.data["persistedTask"]?["wakeDelivered"], .bool(true),
                               "\(name): wakeDelivered")
            }
        }
    }

    // MARK: - Request ids

    func testRequestIdCases() throws {
        for caseSpec in try cases("requestIdCases") {
            let name = caseSpec["name"] as? String ?? "?"
            let taskID = caseSpec["taskId"] as? String ?? ""
            let expected = caseSpec["expected"] as? String ?? ""
            let approval = caseSpec["approvalId"] as? String
            switch caseSpec["prefix"] as? String {
            case "task-turn:": 
                if approval == nil {
                    XCTAssertEqual(BotTurnOrigin.taskTurnRequestId(taskId: taskID),
                                   expected, "\(name): helper")
                }
            case "task-settled:":
                if approval == nil {
                    XCTAssertEqual(BotTurnOrigin.taskSettledRequestId(taskId: taskID),
                                   expected, "\(name): helper")
                }
            case "task-interrupted:":
                XCTAssertEqual(BotTurnOrigin.taskInterruptedRequestId(taskId: taskID),
                               expected, "\(name): helper")
            default:
                XCTFail("\(name): unknown prefix")
            }
            if let approval {
                XCTAssertTrue(expected.hasSuffix(":approval:\(approval)"), "\(name): suffix")
            }
            let origin = BotTurnOrigin(rpcId: expected)
            XCTAssertEqual(origin.kind.rawValue, caseSpec["origin"] as? String,
                           "\(name): origin")
            XCTAssertEqual(origin.hidden, caseSpec["hidden"] as? Bool, "\(name): hidden")
            XCTAssertEqual(origin.memorySource.rawValue,
                           caseSpec["memorySource"] as? String, "\(name): memory")
        }
    }
}
