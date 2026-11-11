// SPDX-License-Identifier: MIT
//
// The frozen `mcp-egress.phone.json` identity and tools-call vectors drive the
// real HTTP identity route and the real `BotMCPHandler`/`BotMCPRuntime`/
// `BotTeamTools` code. The egress vectors are WPF1's; they are not duplicated
// here.

import Foundation
import XCTest
@testable import PhoneDSHBot

private final class VectorClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ value: Int64) { self.value = value }

    func now() -> Int64 { lock.withLock { value } }
    func advance(_ milliseconds: Int64) { lock.withLock { value += milliseconds } }
}

final class BotMCPEgressVectorTests: XCTestCase {
    private let bearer = "wpf2-vector-bot-bearer"

    private func makeRuntime(_ clock: VectorClock) throws
        -> (runtime: BotMCPRuntime, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { clock.now() })
        let gateway = BotGateway(now: { clock.now() })
        let runtime = BotMCPRuntime(store: store, gateway: gateway, now: { clock.now() })
        return (runtime, directory)
    }

    private func vector() throws -> [String: Any] {
        try BotGoldenFixture.rawObject("mcp-egress.phone")
    }

    private func issueRegistry(_ runtime: BotMCPRuntime, clock: VectorClock,
                               entries: [[String: Any]]) async throws -> [String: String] {
        var mapped: [String: String] = [:]
        for entry in entries {
            guard let fixtureToken = entry["token"] as? String,
                  let sessionId = entry["sessionId"] as? String else { continue }
            let kind: BotSessionKind
            if sessionId.hasPrefix("gb-task-") { kind = .task }
            else if sessionId.hasPrefix("gb-routine-") { kind = .routine }
            else { kind = .chat }
            let issued: BotIssuedToken
            if entry["expired"] as? Bool == true {
                issued = try await runtime.gateway.issueSessionToken(
                    botId: "main", sessionId: sessionId, kind: kind, ttlMilliseconds: 5)
                clock.advance(10)
            } else {
                issued = try await runtime.issueSessionToken(
                    botId: "main", sessionId: sessionId, kind: kind)
            }
            if entry["revoked"] as? Bool == true {
                _ = await runtime.gateway.tokens.revoke(issued.token)
            }
            mapped[fixtureToken] = issued.token
        }
        return mapped
    }

    func testIdentityVectorsDriveTheRealHTTPRegisterRoute() async throws {
        let fixture = try vector()
        let valid = fixture["valid"] as? [[String: Any]] ?? []
        let invalid = fixture["invalid"] as? [[String: Any]] ?? []
        var executed = 0
        for (accepted, cases) in [(true, valid), (false, invalid)] {
            for testCase in cases where testCase["suite"] as? String == "identity" {
                let name = testCase["name"] as? String ?? "?"
                let clock = VectorClock(1_000)
                let (runtime, directory) = try makeRuntime(clock)
                defer { try? FileManager.default.removeItem(at: directory) }
                let registry = testCase["registry"] as? [[String: Any]] ?? []
                let mapped = try await issueRegistry(runtime, clock: clock, entries: registry)
                let request = testCase["request"] as? [String: Any] ?? [:]
                let sessionId = request["sessionId"] as? String ?? ""
                let arguments = BotJSONValue.object([:])
                var body: [String: BotJSONValue] = [
                    "runtimeId": .string(BotMCPRuntime.defaultRuntimeID),
                    "sessionId": .string(sessionId),
                    "callId": .string("vector-\(name)"),
                    "name": .string("UpdateMemory"),
                    "arguments": arguments,
                    "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
                ]
                if let fixtureToken = request["sessionToken"] as? String {
                    body["sessionToken"] = .string(mapped[fixtureToken] ?? fixtureToken)
                }
                let server = BotMCPHTTPServer(
                    handler: BotMCPHandler(runtime: runtime), token: bearer)
                let url = try await server.start()
                let response = try await spikePost(
                    url.deletingLastPathComponent().appendingPathComponent("identity/register"),
                    token: bearer, body: .object(body))
                server.stop()
                executed += 1
                XCTAssertEqual(response.status, 200, "\(name): \(response.json)")
                XCTAssertEqual(response.json["ok"], .bool(accepted),
                               "\(name): expected accepted=\(accepted): \(response.json)")
                if accepted {
                    let id = response.json["id"]?.stringValue
                    XCTAssertNotNil(id, "\(name): accepted registration needs an id")
                } else {
                    XCTAssertEqual(response.json["error"], .string("unauthorized"),
                                   "\(name): \(response.json)")
                }
            }
        }
        XCTAssertEqual(executed, 13, "all identity vectors must run through the host route")
    }

    func testToolsCallVectorsDriveTheRealPerCallerCatalog() async throws {
        let fixture = try vector()
        let valid = fixture["valid"] as? [[String: Any]] ?? []
        let invalid = fixture["invalid"] as? [[String: Any]] ?? []
        let clock = VectorClock(1_000)
        let (runtime, directory) = try makeRuntime(clock)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FakeBotTeamHost(roster: botTeamRoster())
        await runtime.registerTeamTools(BotTeamTools(host: host))
        await runtime.registerFishActionTool()
        var tokens: [String: String] = [:]
        for botID in ["bot-a", "bot-b"] {
            let issued = try await runtime.issueSessionToken(
                botId: botID, sessionId: "gb-\(botID)", kind: .chat)
            tokens[botID] = issued.token
        }
        let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: runtime), token: bearer)
        let url = try await server.start()
        defer { server.stop() }

        var executed = 0
        for (accepted, cases) in [(true, valid), (false, invalid)] {
            for testCase in cases where testCase["suite"] as? String == "tools-call" {
                let name = testCase["name"] as? String ?? "?"
                let tool = testCase["tool"] as? String ?? ""
                let caller = testCase["callerBotId"] as? String ?? ""
                let token = try XCTUnwrap(tokens[caller], "\(name): no token for \(caller)")
                let bareTool = tool.hasPrefix("mcp__")
                    ? (tool.components(separatedBy: "__").last ?? tool) : tool
                let arguments = vectorArguments(tool: bareTool, caller: caller)
                let known = BotToolCatalog.isRegistered(bareTool)
                    || BotToolCatalog.teamToolNames.contains(bareTool)
                    || BotToolCatalog.fishActionNames.contains(bareTool)
                await beginUserTurn(runtime, sessionId: "gb-\(caller)", rpcId: "bot-vector-\(name)")
                if known {
                    let registration = try await runtime.registerIdentity(
                        runtimeId: BotMCPRuntime.defaultRuntimeID,
                        sessionId: "gb-\(caller)", callId: "vector-\(name)",
                        name: tool, arguments: arguments, sessionToken: token)
                    XCTAssertEqual(registration.sessionId, "gb-\(caller)")
                }
                let response = try await spikePost(
                    url, token: bearer,
                    body: .object([
                        "jsonrpc": .string("2.0"),
                        "id": .string("vector-\(name)"),
                        "method": .string("tools/call"),
                        "params": .object(["name": .string(tool), "arguments": arguments]),
                    ]),
                    headers: [BotMCPHandler.callerSessionHeader: "gb-\(caller)"])
                await runtime.endTurn(sessionId: "gb-\(caller)")
                executed += 1
                if accepted {
                    XCTAssertNotEqual(response.isError, true,
                                      "\(name): \(String(describing: response.json))")
                    XCTAssertNotNil(response.structured, "\(name): expected a tool result")
                } else {
                    XCTAssertEqual(response.isError, true,
                                   "\(name): \(String(describing: response.json))")
                    let code = response.structured?["error"]?["code"]?.stringValue
                    let expected = (testCase["expect"] as? [String: Any])?["error"] as? String
                    XCTAssertEqual(code, expected, "\(name): \(String(describing: response.json))")
                }
            }
        }
        XCTAssertEqual(executed, 9, "all tools-call vectors must run through the real handler")
        let created = await host.created
        XCTAssertEqual(created.map(\.name), ["Vector teammate"],
                       "only the accepted main-Bot CreateTeammate may run")
    }

    private func vectorArguments(tool: String, caller: String) -> BotJSONValue {
        switch tool {
        case BotToolCatalog.sendToAgentName:
            return .object([
                "agent_id": .string(caller == "bot-b" ? "bot-a" : "bot-b"),
                "message": .string("vector message"),
                "priority": .bool(true),
            ])
        case BotToolCatalog.createTeammateName:
            return .object(["name": .string("Vector teammate")])
        case "UpdateMemory":
            return .object([
                "action": .string("write"),
                "path": .string("agent/notes/vector.md"),
                "content": .string("vector fact"),
                "expected_version": .number(0),
            ])
        case BotToolCatalog.fishActionName:
            return .object(["action": .string(BotToolCatalog.fishActions[0])])
        default:
            return .object([:])
        }
    }
}
