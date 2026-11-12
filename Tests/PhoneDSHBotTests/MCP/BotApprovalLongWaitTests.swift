// SPDX-License-Identifier: MIT
// spec/bot/v1/mcp-endpoint.md §2 "Long approvals" and §3 cancel cascade.
// The shared `approval` golden block judges the real decision table and the
// Worker-side stream parser (plugins/tests/bot-approval-long-wait.test.ts);
// these real-HTTP cases judge the listener framing, the old-Worker JSON
// compatibility path, and the `/identity/cancel` card cascade.

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotApprovalLongWaitTests: XCTestCase {
    private let serverToken = "approval-long-token-0123456789"
    private let sessionID = "gb-main"

    private func cases() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("spec/v1/golden/mcp-long-call/cases.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func approvalCases() throws -> [String: Any] {
        try XCTUnwrap(try cases()["approval"] as? [String: Any])
    }

    // MARK: - Shared golden decision table

    func testApprovalDecisionTable() throws {
        let decisions = try XCTUnwrap(try approvalCases()["decisions"] as? [[String: Any]])
        for item in decisions {
            let streams = BotMCPHTTPServer.streamsLongApproval(accept: item["accept"] as? String)
            // A fast outcome never reaches the stream branch's deadline, so it
            // stays JSON either way — exactly like the tools/call table.
            let expected = (item["slow"] as! Bool) && streams ? "stream" : "json"
            XCTAssertEqual(expected, item["expect"] as? String, item["name"] as? String ?? "")
        }
    }

    // MARK: - Real HTTP

    private struct ApprovalServer {
        let fixture: BotMCPTestFixture
        let server: BotMCPHTTPServer
        let url: URL
        let sessionToken: String

        var base: URL { url.deletingLastPathComponent() }
        var token: String { server.token }

        func stop() {
            server.stop()
            fixture.cleanup()
        }
    }

    private func start(approvalTimeoutMs: Int64 = BotApprovalCoordinator.defaultTimeoutMilliseconds)
        async throws -> ApprovalServer {
        let fixture = try makeBotMCPFixture(approvalTimeoutMs: approvalTimeoutMs)
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: sessionID, kind: .chat)
        let server = BotMCPHTTPServer(
            handler: BotMCPHandler(runtime: fixture.runtime), token: serverToken,
            longCallTiming: .init(streamAfter: .milliseconds(200),
                                  keepaliveInterval: .milliseconds(150)))
        return ApprovalServer(fixture: fixture, server: server, url: try await server.start(),
                              sessionToken: issued.token)
    }

    private func post(_ target: URL, body: BotJSONValue, token: String,
                      accept: String? = nil) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        request.httpBody = try body.encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }

    private func json(_ response: (HTTPURLResponse, Data)) throws -> BotJSONValue {
        XCTAssertEqual(response.0.statusCode, 200)
        return try BotJSONValue.parse(response.1)
    }

    private func register(_ server: ApprovalServer, name: String, arguments: BotJSONValue,
                          callId: String) async throws -> String {
        let reply = try await json(try await post(
            server.base.appendingPathComponent("identity/register"),
            body: .object([
                "runtimeId": .string(BotMCPRuntime.defaultRuntimeID),
                "sessionId": .string(sessionID), "callId": .string(callId),
                "name": .string(name),
                "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
                "arguments": arguments,
                "sessionToken": .string(server.sessionToken),
            ]), token: server.token))
        XCTAssertEqual(reply["ok"], .bool(true))
        return try XCTUnwrap(reply["id"]?.stringValue)
    }

    private func memoryArguments(_ fact: String) -> BotJSONValue {
        .object([
            "action": .string("forget"), "scope": .string("user"), "fact": .string(fact),
        ])
    }

    private func approvalBody(arguments: BotJSONValue, callId: String) throws -> BotJSONValue {
        .object([
            "sessionId": .string(sessionID), "callId": .string(callId),
            "tool": .string("UpdateMemory"),
            "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
            "alwaysScope": .string("until"), "askAction": .string("tool-call"),
            "action": .string("Forget"), "detail": .string("test"), "command": .string(""),
        ])
    }

    private func waitForPending(_ coordinator: BotApprovalCoordinator,
                                _ expected: Int) async throws -> [String] {
        for _ in 0..<400 {
            let ids = await coordinator.pendingIDs
            if ids.count == expected { return ids }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return await coordinator.pendingIDs
    }

    /// Splits the SSE body and returns its single message outcome.
    private func streamOutcome(_ data: Data) throws -> BotJSONValue {
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: "event: message\ndata: ")
        XCTAssertEqual(parts.count, 2, "exactly one message event: \(text)")
        XCTAssertTrue(parts[0].replacingOccurrences(of: ": keepalive\n\n", with: "").isEmpty,
                      "only keepalives before the message: \(text)")
        XCTAssertTrue(parts[1].hasSuffix("\n\n"), "the event ends with a blank line")
        let line = String(parts[1].dropLast(2))
        XCTAssertFalse(line.contains("\n"), "the outcome is one data line: \(line)")
        return try BotJSONValue.parse(Data(line.utf8))
    }

    func testSlowApprovalIsStreamedWithoutSessionHeaderAndEndsWithOneMessage() async throws {
        let server = try await start()
        defer { server.stop() }
        let arguments = memoryArguments("stream-allow")
        let callId = "approval-stream"
        _ = try await register(server, name: "UpdateMemory", arguments: arguments, callId: callId)
        let request = Task {
            try await post(server.base.appendingPathComponent("approval"),
                           body: try approvalBody(arguments: arguments, callId: callId),
                           token: server.token, accept: "application/json, text/event-stream")
        }
        let pending = try await waitForPending(server.fixture.runtime.approvals, 1)
        try await Task.sleep(nanoseconds: 650_000_000)
        let resolved = await server.fixture.runtime.approvals.resolve(
            approvalId: pending[0], decision: .allowOnce,
            digest: try BotArgumentsDigest.string(for: arguments))
        XCTAssertEqual(resolved, .resolved)

        let (response, data) = try await request.value
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        XCTAssertNil(response.value(forHTTPHeaderField: "Content-Length"))
        XCTAssertNil(response.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertGreaterThanOrEqual(
            text.components(separatedBy: ": keepalive\n\n").count - 1, 1, text)
        let outcome = try streamOutcome(data)
        XCTAssertEqual(outcome["ok"], .bool(true))
        XCTAssertEqual(outcome["allowed"], .bool(true))
        XCTAssertEqual(outcome["approvalId"], .string(pending[0]))
    }

    func testSlowApprovalWithoutSSEAcceptKeepsTheOldJSONAnswer() async throws {
        let server = try await start()
        defer { server.stop() }
        let arguments = memoryArguments("stream-json-compat")
        let callId = "approval-json"
        _ = try await register(server, name: "UpdateMemory", arguments: arguments, callId: callId)
        let request = Task {
            try await post(server.base.appendingPathComponent("approval"),
                           body: try approvalBody(arguments: arguments, callId: callId),
                           token: server.token, accept: "application/json")
        }
        let pending = try await waitForPending(server.fixture.runtime.approvals, 1)
        try await Task.sleep(nanoseconds: 650_000_000)
        _ = await server.fixture.runtime.approvals.resolve(
            approvalId: pending[0], decision: .allowOnce,
            digest: try BotArgumentsDigest.string(for: arguments))

        let (response, data) = try await request.value
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(response.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let outcome = try BotJSONValue.parse(data)
        XCTAssertEqual(outcome["ok"], .bool(true))
        XCTAssertEqual(outcome["allowed"], .bool(true))
    }

    func testFastStandingGrantWithSSEAcceptStaysJSON() async throws {
        let server = try await start()
        defer { server.stop() }
        let arguments = memoryArguments("stream-fast-grant")
        let callId = "approval-fast"
        let effect = BotToolEffectClassifier.effect(for: "UpdateMemory", arguments: arguments)
        _ = try await server.fixture.runtime.grants.add(BotGrant(
            botId: "main", tool: effect.tool, operation: effect.operation,
            resource: effect.resource, scope: .until, sessionId: sessionID,
            createdAt: 1_000, source: "test", decision: .allow))
        _ = try await register(server, name: "UpdateMemory", arguments: arguments, callId: callId)
        let response = try await post(
            server.base.appendingPathComponent("approval"),
            body: try approvalBody(arguments: arguments, callId: callId),
            token: server.token, accept: "application/json, text/event-stream")
        XCTAssertEqual(response.0.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let outcome = try BotJSONValue.parse(response.1)
        XCTAssertEqual(outcome["ok"], .bool(true))
        XCTAssertEqual(outcome["allowed"], .bool(true))
    }

    func testCancelledRegistrationEndsThePendingApprovalAndWritesOneDecided() async throws {
        // The scaled timeout stands in for the 300 s approval window; the
        // cascade must cancel the expiry task so it can never write a second
        // `approval.decided`.
        let server = try await start(approvalTimeoutMs: 1_000)
        defer { server.stop() }
        let arguments = memoryArguments("stream-cancel")
        let callId = "approval-cancel"
        let registrationID = try await register(
            server, name: "UpdateMemory", arguments: arguments, callId: callId)
        let request = Task {
            try await post(server.base.appendingPathComponent("approval"),
                           body: try approvalBody(arguments: arguments, callId: callId),
                           token: server.token, accept: "application/json, text/event-stream")
        }
        let pending = try await waitForPending(server.fixture.runtime.approvals, 1)
        try await Task.sleep(nanoseconds: 300_000_000)

        let cancelled = try await json(try await post(
            server.base.appendingPathComponent("identity/cancel"),
            body: .object(["id": .string(registrationID)]), token: server.token))
        XCTAssertEqual(cancelled["ok"], .bool(true))

        let (response, data) = try await request.value
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        let outcome = try streamOutcome(data)
        XCTAssertEqual(outcome["ok"], .bool(false))
        XCTAssertEqual(outcome["allowed"], .bool(false))
        XCTAssertEqual(outcome["message"], .string("approval cancelled"))

        let events = try await botEvents(server.fixture.store)
        let decisions = events.filter {
            $0.type == "approval.decided" && $0.data["approvalID"] == .string(pending[0])
        }
        XCTAssertEqual(decisions.count, 1, "exactly one decided row for \(pending[0])")
        XCTAssertEqual(decisions.first?.data["decision"], .string("deny"))
        XCTAssertEqual(decisions.first?.data["status"], .string("cancelled"))
        XCTAssertEqual(decisions.first?.data["reason"], .string("consumer_cancelled"))
        let remaining = await server.fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(remaining.isEmpty, "the session has no pending approval: \(remaining)")

        // Past the scaled 300 s deadline: the cancelled expiry task must not
        // append a second `approval.decided` (for example a timed-out deny).
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let after = try await botEvents(server.fixture.store)
        XCTAssertEqual(after.filter {
            $0.type == "approval.decided" && $0.data["approvalID"] == .string(pending[0])
        }.count, 1)
    }

    func testCancelDoesNotEndTheCallsDurableApproval() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let session = "gb-task"
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: session, kind: .task)
        let arguments = memoryArguments("durable-kept")
        let callId = "durable-call"
        let registration = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: session,
            callId: callId, name: "UpdateMemory", arguments: arguments,
            sessionToken: issued.token)
        let outcome = await fixture.runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: session, callId: callId,
            name: "UpdateMemory", action: "Forget", detail: "test", command: "",
            argsDigest: try BotArgumentsDigest.string(for: arguments),
            alwaysScope: "until", askAction: "tool-call")
        XCTAssertTrue(outcome.pending)
        let pendingBefore = await fixture.runtime.approvals.pendingIDs
        XCTAssertEqual(pendingBefore.count, 1)

        let cancelledRegistration = await fixture.runtime.cancelIdentity(id: registration.id)
        XCTAssertTrue(cancelledRegistration)

        let pendingAfter = await fixture.runtime.approvals.pendingIDs
        XCTAssertEqual(pendingAfter, pendingBefore, "a durable todo survives the registration cancel")
        let durable = await fixture.runtime.approvals.pendingApproval(sessionId: session)
        XCTAssertEqual(durable?.approvalID, pendingBefore[0])
        XCTAssertEqual(durable?.status, .pending)
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.filter {
            $0.type == "approval.decided"
                && $0.data["approvalID"] == .string(pendingBefore[0])
        }.isEmpty, "cancelling the registration must write no decision for the durable todo")
    }

    func testCancelEndsOnlyTheCancelledCallsInteractiveApproval() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: sessionID, kind: .chat)
        let cancelledArguments = memoryArguments("other-call-cancelled")
        let keptArguments = memoryArguments("other-call-kept")
        let cancelledCall = "call-cancelled"
        let keptCall = "call-kept"
        let registration = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionID,
            callId: cancelledCall, name: "UpdateMemory", arguments: cancelledArguments,
            sessionToken: issued.token)
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionID,
            callId: keptCall, name: "UpdateMemory", arguments: keptArguments,
            sessionToken: issued.token)

        let cancelling = Task {
            await fixture.runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionID,
                callId: cancelledCall, name: "UpdateMemory", action: "Forget",
                detail: "test", command: "",
                argsDigest: try BotArgumentsDigest.string(for: cancelledArguments),
                alwaysScope: "until", askAction: "tool-call")
        }
        let keeping = Task {
            await fixture.runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionID,
                callId: keptCall, name: "UpdateMemory", action: "Forget",
                detail: "test", command: "",
                argsDigest: try BotArgumentsDigest.string(for: keptArguments),
                alwaysScope: "until", askAction: "tool-call")
        }
        try await waitForPending(fixture.runtime.approvals, 2)

        let cancelledRegistration = await fixture.runtime.cancelIdentity(id: registration.id)
        XCTAssertTrue(cancelledRegistration)
        let cancelledOutcome = try await cancelling.value
        XCTAssertEqual(cancelledOutcome.message, "approval cancelled")
        let remaining = await fixture.runtime.approvals.pendingIDs
        XCTAssertEqual(remaining.count, 1, "the other call's approval stays pending: \(remaining)")

        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: remaining[0], decision: .allowOnce,
            digest: try BotArgumentsDigest.string(for: keptArguments))
        XCTAssertEqual(resolved, .resolved)
        let keptOutcome = try await keeping.value
        XCTAssertTrue(keptOutcome.allowed)
        XCTAssertEqual(keptOutcome.message, "allowed")
    }
}
