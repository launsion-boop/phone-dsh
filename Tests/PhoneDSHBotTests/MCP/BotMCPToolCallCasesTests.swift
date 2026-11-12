// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// D13 P0 tool contracts, driven from
/// `spec/bot/v1/golden/tool-call-cases.phone.json` through the real runtime,
/// the real card builder, the real memory/routine stores and the stub task
/// executor used by the existing MCP tests.
final class BotMCPToolCallCasesTests: XCTestCase {
    private var vector: [String: Any] = [:]

    override func setUpWithError() throws {
        vector = try BotContractFixture.object("tool-call-cases.phone")
    }

    func testMCPToolCallFixtureMetadata() throws {
        XCTAssertEqual(vector["vector"] as? String, "tool-call-cases.phone")
        XCTAssertEqual(vector["upstream"] as? [String], [])
        let tools = try XCTUnwrap(vector["tools"] as? [String])
        XCTAssertEqual(Set(tools), Set(BotToolCatalog.p0Names), "the fixture must cover the whole P0 catalog")
        let valid = try BotContractFixture.array(vector["valid"], "valid")
        let invalid = try BotContractFixture.array(vector["invalid"], "invalid")
        let denials = try BotContractFixture.array(vector["denials"], "denials")
        XCTAssertEqual(Set(valid.compactMap { $0["tool"] as? String }), Set(tools))
        XCTAssertEqual(Set(denials.compactMap { $0["tool"] as? String }), Set(tools))
        for tool in tools where tool != "ListRoutines" {
            XCTAssertTrue(invalid.contains { $0["tool"] as? String == tool },
                          "missing invalid-arguments case for \(tool)")
        }
        XCTAssertFalse(try BotContractFixture.array(vector["unknown"], "unknown").isEmpty)
    }

    func testMCPToolCallCases() async throws {
        for (index, object) in try BotContractFixture.array(vector["valid"], "valid").enumerated() {
            try await runCase(object, label: "valid[\(index)] \((object["name"] as? String) ?? "?")")
        }
        for (index, object) in try BotContractFixture.array(vector["invalid"], "invalid").enumerated() {
            try await runCase(object, label: "invalid[\(index)] \((object["name"] as? String) ?? "?")")
        }
        for (index, object) in try BotContractFixture.array(vector["denials"], "denials").enumerated() {
            try await runCase(object, label: "denials[\(index)] \((object["name"] as? String) ?? "?")")
        }
        for (index, object) in try BotContractFixture.array(vector["unknown"], "unknown").enumerated() {
            try await runCase(object, label: "unknown[\(index)] \((object["name"] as? String) ?? "?")")
        }
    }

    // MARK: - one case

    private func runCase(_ object: [String: Any], label: String) async throws {
        let tool = try BotContractFixture.string(object["tool"], "\(label).tool")
        let setup = try BotContractFixture.object(object["setup"], "\(label).setup")
        let fixture = try makeBotMCPFixture(taskExecutor: StubBotTaskExecutor())
        defer { fixture.cleanup() }
        let runtime = fixture.runtime
        let sessionId = try BotContractFixture.string(setup["sessionId"], "\(label).setup.sessionId")
        let botId = try BotContractFixture.string(setup["botId"], "\(label).setup.botId")
        let kindRaw = try BotContractFixture.string(setup["kind"], "\(label).setup.kind")
        let kind = BotSessionKind(rawValue: kindRaw) ?? .chat
        let capabilities = (setup["capabilities"] as? [String]) ?? []
        _ = try await runtime.issueSessionToken(
            botId: botId, sessionId: sessionId, kind: kind, capabilities: capabilities)

        // Grant recovery scans the event log and requires its snapshot before
        // any later event exists; force the empty snapshot before seeding, the
        // same ordering the production composition has before the first turn.
        try await runtime.grants.recover()
        for doc in (setup["seedMemory"] as? [[String: Any]]) ?? [] {
            _ = try await runtime.memory(for: botId).write(
                BotMemoryWriteRequest(
                    action: .write,
                    path: try BotContractFixture.string(doc["path"], "\(label).seedMemory.path"),
                    content: try BotContractFixture.string(doc["content"], "\(label).seedMemory.content"),
                    expectedVersion: 0),
                context: BotMemoryWriteContext(
                    botID: botId, sessionID: sessionId, authorKind: .chat,
                    source: BotMemorySource(kind: .userTurn, sessionID: sessionId),
                    trust: .user))
        }
        for routine in (setup["seedRoutines"] as? [[String: Any]]) ?? [] {
            _ = try await runtime.routineMachine.create(
                botId: botId,
                title: try BotContractFixture.string(routine["title"], "\(label).seedRoutines.title"),
                prompt: try BotContractFixture.string(routine["prompt"], "\(label).seedRoutines.prompt"),
                schedule: .interval(everyMinutes: 60), now: 1_000)
        }
        switch setup["turn"] as? String {
        case "user":
            await runtime.beginTurn(sessionId: sessionId, hidden: false,
                                    origin: BotTurnOrigin(rpcId: "bot-contract-\(label)"))
        case "hidden":
            await runtime.beginTurn(sessionId: sessionId, hidden: true,
                                    origin: BotTurnOrigin(rpcId: "held:contract"))
        default:
            break
        }

        var arguments = try BotContractFixture.json(object["arguments"] ?? [:])
        if object["createTask"] as? Bool == true {
            let seed = try await registerAndExecute(
                runtime, name: "Task",
                arguments: .object([
                    "task_title": .string("Seed"),
                    "task_description": .string("seed task"),
                    "async": .bool(true),
                ]), sessionId: sessionId)
            let taskId = try XCTUnwrap(seed.structuredContent?["task_id"]?.stringValue,
                                       "\(label): seed Task produced no task_id")
            arguments = substitutingTaskID(arguments, taskId: taskId)
        }

        if object["skipRegistration"] as? Bool != true {
            if object["deny"] as? Bool == true {
                await runtime.setToolCatalogProvider { caller in
                    var definitions = BotToolCatalog.allDefinitions
                    if caller == "restricted" {
                        definitions.removeAll { $0.name == tool }
                    }
                    return definitions
                }
            } else {
                await runtime.setToolCatalogProvider(nil)
            }
            let callId = "case-\(object["name"] as? String ?? UUID().uuidString)"
            _ = try await runtime.registerIdentity(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
                callId: callId, name: tool, arguments: arguments)
            if object["layer"] as? String == "rpc" {
                let handler = BotMCPHandler(runtime: runtime)
                let reply = await handler.rpc(
                    method: "tools/call",
                    params: .object(["name": .string(tool), "arguments": arguments]),
                    id: .string(callId))
                let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
                BotContractFixture.assertError(
                    reply, try BotContractFixture.json(["code": expect["rpcError"] ?? -32602]),
                    label)
                XCTAssertEqual(reply["error"]?["message"]?.stringValue,
                               expect["message"] as? String, label)
                return
            }
            let result = await execute(runtime, tool: tool, arguments: arguments,
                                       callId: callId, object: object, label: label)
            try assertResult(result, object: object, label: label)
        } else {
            let result = await runtime.execute(
                name: tool, arguments: arguments,
                context: BotMCPRequestContext(callId: "unknown-\(label)"))
            try assertResult(result, object: object, label: label)
        }
    }

    private func execute(_ runtime: BotMCPRuntime, tool: String, arguments: BotJSONValue,
                         callId: String, object: [String: Any], label: String) async -> BotMCPCallResult {
        guard object["approvalDecision"] as? String != nil else {
            return await runtime.execute(
                name: tool, arguments: arguments,
                context: BotMCPRequestContext(callId: callId))
        }
        let task = Task {
            await runtime.execute(name: tool, arguments: arguments,
                                  context: BotMCPRequestContext(callId: callId))
        }
        let digest = (try? BotArgumentsDigest.string(for: arguments)) ?? ""
        for _ in 0..<400 {
            if let id = await runtime.approvals.pendingIDs.first {
                _ = await runtime.approvals.resolve(
                    approvalId: id, decision: .allowOnce, digest: digest)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await task.value
    }

    private func assertResult(_ result: BotMCPCallResult, object: [String: Any],
                              label: String) throws {
        let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
        if expect["isError"] as? Bool == true {
            XCTAssertEqual(result.isError, true, "\(label): expected isError true")
            guard let code = expect["errorCode"] as? String else {
                XCTFail("\(label): missing errorCode")
                return
            }
            XCTAssertEqual(result.structuredContent?["error"]?["code"]?.stringValue, code, label)
            if let contains = expect["messageContains"] as? String,
               let message = result.structuredContent?["error"]?["message"]?.stringValue {
                XCTAssertTrue(message.contains(contains),
                              "\(label): message \(message) does not contain \(contains)")
            }
        } else {
            XCTAssertNil(result.isError, "\(label): success must omit isError; result=\(String(describing: result.structuredContent))")
        }
        if let structured = expect["structured"] {
            BotContractFixture.assertSubset(result.structuredContent ?? .null,
                                            try BotContractFixture.json(structured), label)
        }
    }

    private func substitutingTaskID(_ value: BotJSONValue, taskId: String) -> BotJSONValue {
        switch value {
        case .string("$taskId"): return .string(taskId)
        case .array(let values): return .array(values.map { substitutingTaskID($0, taskId: taskId) })
        case .object(let fields):
            return .object(fields.mapValues { substitutingTaskID($0, taskId: taskId) })
        default:
            return value
        }
    }
}
