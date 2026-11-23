// SPDX-License-Identifier: MIT
//
// A standing "always" for a destructive shell family must cover the queued
// cards of the same class, not only the card the person tapped. The first
// approval persists an `exec:delete` grant; a second `rm` of another target
// that was already waiting is answered without another card.

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotApprovalClassContinuationTests: XCTestCase {
    private let serverToken = "approval-class-token-0123456789"
    private let sessionID = "gb-main"

    private struct Server {
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

    private func start() async throws -> Server {
        let fixture = try makeBotMCPFixture()
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: sessionID, kind: .chat)
        let server = BotMCPHTTPServer(
            handler: BotMCPHandler(runtime: fixture.runtime), token: serverToken)
        return Server(fixture: fixture, server: server, url: try await server.start(),
                      sessionToken: issued.token)
    }

    private func post(_ target: URL, body: BotJSONValue, token: String)
        async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }

    private func register(_ server: Server, command: String, callId: String) async throws {
        let arguments: BotJSONValue = .object(["command": .string(command)])
        let reply = try BotJSONValue.parse(try await post(
            server.base.appendingPathComponent("identity/register"),
            body: .object([
                "runtimeId": .string(BotMCPRuntime.defaultRuntimeID),
                "sessionId": .string(sessionID), "callId": .string(callId),
                "name": .string("bash"),
                "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
                "arguments": arguments,
                "sessionToken": .string(server.sessionToken),
            ]), token: server.token).1)
        XCTAssertEqual(reply["ok"], .bool(true))
    }

    private func approvalBody(command: String, callId: String) throws -> BotJSONValue {
        let arguments: BotJSONValue = .object(["command": .string(command)])
        return .object([
            "sessionId": .string(sessionID), "callId": .string(callId),
            "tool": .string("bash"),
            "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
            "alwaysScope": .string("until"), "askAction": .string("run-command"),
            "action": .string("Delete files or directories (rm)"),
            "detail": .string("This command deletes files or directories: \(command)"),
            "command": .string(command),
        ])
    }

    private func waitForPending(_ coordinator: BotApprovalCoordinator,
                                _ expected: Int) async throws -> [String] {
        for _ in 0..<600 {
            let ids = await coordinator.pendingIDs
            if ids.count == expected { return ids }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return await coordinator.pendingIDs
    }

    func testAlwaysForDeleteAnswersAQueuedDeleteOfAnotherTarget() async throws {
        let server = try await start()
        defer { server.stop() }
        let firstCommand = "rm -rf build"
        let secondCommand = "rm -rf dist"
        try await register(server, command: firstCommand, callId: "class-rm-1")
        try await register(server, command: secondCommand, callId: "class-rm-2")

        let first = Task {
            try await post(server.base.appendingPathComponent("approval"),
                           body: try approvalBody(command: firstCommand, callId: "class-rm-1"),
                           token: server.token)
        }
        let pending = try await waitForPending(server.fixture.runtime.approvals, 1)
        let second = Task {
            try await post(server.base.appendingPathComponent("approval"),
                           body: try approvalBody(command: secondCommand, callId: "class-rm-2"),
                           token: server.token)
        }
        _ = try await waitForPending(server.fixture.runtime.approvals, 2)

        let firstId = try XCTUnwrap(pending.first)
        let resolved = await server.fixture.runtime.approvals.resolve(
            approvalId: firstId, decision: .always,
            digest: try BotArgumentsDigest.string(
                for: .object(["command": .string(firstCommand)])))
        XCTAssertEqual(resolved, .resolved)

        let firstOutcome = try BotJSONValue.parse(try await first.value.1)
        XCTAssertEqual(firstOutcome["allowed"], .bool(true))
        let secondOutcome = try BotJSONValue.parse(try await second.value.1)
        XCTAssertEqual(secondOutcome["allowed"], .bool(true),
                       "a queued delete of the same class must be answered, not left waiting")
        let remaining = await server.fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(remaining.isEmpty)

        // One standing class grant, stored by class and wildcard resource.
        let grants = await server.fixture.runtime.grants.list(botId: "main")
        let classGrants = grants.filter { $0.operation == BotActionClass.execDelete.rawValue }
        XCTAssertEqual(classGrants.count, 1)
        XCTAssertEqual(classGrants.first?.resource, "*")
        XCTAssertEqual(classGrants.first?.scope, .until)
    }

    func testAlwaysForDeleteDoesNotAnswerADifferentClass() async throws {
        let server = try await start()
        defer { server.stop() }
        let deleteCommand = "rm -rf build"
        let resetCommand = "git reset --hard HEAD"
        try await register(server, command: deleteCommand, callId: "class-only-rm")
        try await register(server, command: resetCommand, callId: "class-only-reset")

        let deleteRequest = Task {
            try await post(server.base.appendingPathComponent("approval"),
                           body: try approvalBody(command: deleteCommand, callId: "class-only-rm"),
                           token: server.token)
        }
        let pending = try await waitForPending(server.fixture.runtime.approvals, 1)
        let resetRequest = Task {
            try await post(server.base.appendingPathComponent("approval"),
                           body: try approvalBody(command: resetCommand, callId: "class-only-reset"),
                           token: server.token)
        }
        _ = try await waitForPending(server.fixture.runtime.approvals, 2)
        _ = await server.fixture.runtime.approvals.resolve(
            approvalId: try XCTUnwrap(pending.first), decision: .always,
            digest: try BotArgumentsDigest.string(
                for: .object(["command": .string(deleteCommand)])))
        _ = try await deleteRequest.value
        // The git-reset card stays open: a delete grant is not a generic shell
        // grant, so its owner still has to decide.
        let stillPending = try await waitForPending(server.fixture.runtime.approvals, 1)
        XCTAssertEqual(stillPending.count, 1)
        for id in stillPending {
            _ = await server.fixture.runtime.approvals.resolve(
                approvalId: id, decision: .deny,
                digest: try BotArgumentsDigest.string(
                    for: .object(["command": .string(resetCommand)])))
        }
        _ = try await resetRequest.value
    }
}