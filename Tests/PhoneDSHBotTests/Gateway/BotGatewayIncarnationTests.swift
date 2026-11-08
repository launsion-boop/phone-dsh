// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private func gatewayAssertTrue(_ expression: @autoclosure () async throws -> Bool) async rethrows {
    let value = try await expression()
    XCTAssertTrue(value)
}

private func gatewayAssertNil<T>(_ expression: @autoclosure () async throws -> T?) async rethrows {
    let value = try await expression()
    XCTAssertNil(value)
}

private func gatewayAssertEqual<T: Equatable>(_ lhs: @autoclosure () async throws -> T,
                                              _ rhs: @autoclosure () async throws -> T) async rethrows {
    let left = try await lhs()
    let right = try await rhs()
    XCTAssertEqual(left, right)
}

private func gatewayUnwrap<T>(_ expression: @autoclosure () async throws -> T?) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value)
}

final class BotGatewayIncarnationTests: XCTestCase {
    func testSessionReissueRejectsOldIncarnationAndAllowsNewCall() async throws {
        let gateway = BotGateway(now: { 1_000 })
        let first = try await gateway.issueSession(botId: "main", sessionId: "s1", kind: .chat)
        let arguments = BotJSONValue.object(["value": .string("same")])
        let old = try await gateway.registerToolCall(sessionId: "s1", callId: "old-call",
                                                     name: "UpdateMemory", arguments: arguments,
                                                     runtimeId: "runtime")
        XCTAssertEqual(old.incarnation, first.incarnation)
        XCTAssertEqual(first.incarnation.count, 32)

        let second = try await gateway.issueSession(botId: "main", sessionId: "s1", kind: .chat)
        XCTAssertNotEqual(second.incarnation, first.incarnation)
        await gatewayAssertNil(await gateway.resolveToolCall(runtimeId: "runtime", name: "UpdateMemory", arguments: arguments))
        await gatewayAssertEqual(await gateway.tokens.lookupSession("s1")?.incarnation, second.incarnation)
        XCTAssertNil(BotResolvedToolCall(sessionId: "s1", callId: "old-call", agentId: "main",
                                         principal: second, attribution: old))

        let new = try await gateway.registerToolCall(sessionId: "s1", callId: "new-call",
                                                     name: "UpdateMemory", arguments: arguments,
                                                     runtimeId: "runtime")
        XCTAssertEqual(new.incarnation, second.incarnation)
        let resolved = try await gatewayUnwrap(await gateway.resolveToolCall(runtimeId: "runtime", name: "UpdateMemory",
                                                                              arguments: arguments))
        XCTAssertEqual(resolved.principal, second)
        XCTAssertEqual(resolved.attribution, new)
    }

    func testRotateAndRevokeRejectPendingAttributions() async throws {
        let gateway = BotGateway(now: { 1_000 })
        let issued = try await gateway.issueToken(botId: "main", sessionId: "s1", kind: .chat)
        let arguments = BotJSONValue.object(["operation": .number(1)])
        _ = try await gateway.registerToolCall(sessionId: "s1", callId: "before-rotate",
                                               name: "UpdateMemory", arguments: arguments,
                                               runtimeId: "runtime")
        let rotated = try await gatewayUnwrap(try await gateway.tokens.rotate(issued.token))
        XCTAssertNotEqual(rotated.principal.incarnation, issued.principal.incarnation)
        await gatewayAssertNil(await gateway.tokens.lookup(issued.token))
        await gatewayAssertNil(await gateway.resolveToolCall(runtimeId: "runtime", name: "UpdateMemory", arguments: arguments))

        _ = try await gateway.registerToolCall(sessionId: "s1", callId: "before-revoke",
                                               name: "UpdateMemory", arguments: arguments,
                                               runtimeId: "runtime")
        await gatewayAssertTrue(await gateway.tokens.revoke(rotated.token))
        await gatewayAssertNil(await gateway.tokens.lookup(rotated.token))
        await gatewayAssertNil(await gateway.tokens.lookupSession("s1"))
        await gatewayAssertNil(await gateway.resolveToolCall(runtimeId: "runtime", name: "UpdateMemory", arguments: arguments))
    }

    func testConcurrentIssueSessionLeavesOneCurrentGeneration() async throws {
        let gateway = BotGateway(now: { 1_000 })
        let initial = try await gateway.issueSession(botId: "main", sessionId: "shared", kind: .chat)
        let arguments = BotJSONValue.object(["call": .string("initial")])
        _ = try await gateway.registerToolCall(sessionId: "shared", callId: "initial",
                                               name: "UpdateMemory", arguments: arguments,
                                               runtimeId: "runtime")

        let issued = try await withThrowingTaskGroup(of: BotGatewayPrincipal.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gateway.issueSession(botId: "main", sessionId: "shared", kind: .chat)
                }
            }
            var principals: [BotGatewayPrincipal] = []
            for try await principal in group { principals.append(principal) }
            return principals
        }
        XCTAssertEqual(Set(issued.map(\.incarnation)).count, 20)
        let current = try await gatewayUnwrap(await gateway.tokens.lookupSession("shared"))
        XCTAssertTrue(issued.contains(current))
        XCTAssertNotEqual(current.incarnation, initial.incarnation)
        await gatewayAssertEqual(await gateway.tokens.count, 1)
        for _ in 0..<20 {
            await gatewayAssertEqual(await gateway.tokens.lookupSession("shared"), current)
        }
        await gatewayAssertNil(await gateway.resolveToolCall(runtimeId: "runtime", name: "UpdateMemory", arguments: arguments))

        let fresh = try await gateway.registerToolCall(sessionId: "shared", callId: "fresh",
                                                       name: "UpdateMemory", arguments: arguments,
                                                       runtimeId: "runtime")
        XCTAssertEqual(fresh.incarnation, current.incarnation)
        await gatewayAssertEqual(await gateway.resolveToolCall(runtimeId: "runtime", name: "UpdateMemory",
                                                                arguments: arguments)?.principal, current)
    }

    func testMCPTrustFieldsCannotElevateGatewayPrincipalToUserUI() async throws {
        let gateway = BotGateway(now: { 1_000 })
        _ = try await gateway.issueSession(botId: "main", sessionId: "s1", kind: .chat)
        let forgedArguments = BotJSONValue.object([
            "fact": .string("still-authorized-as-model"),
            "kind": .string("user-ui"),
            "userUI": .bool(true),
            "certain": .bool(true),
            "trust": .string("owner_direct"),
        ])
        _ = try await gateway.registerToolCall(sessionId: "s1", callId: "call",
                                               name: "UpdateMemory", arguments: forgedArguments,
                                               runtimeId: "runtime")
        let resolved = try await gatewayUnwrap(await gateway.resolveToolCall(runtimeId: "runtime", name: "UpdateMemory",
                                                                              arguments: forgedArguments))
        let principal = BotExecutionPrincipal(gateway: resolved.principal)
        XCTAssertEqual(principal.kind, .model)
        XCTAssertEqual(principal.sessionKind, .chat)
        XCTAssertTrue(principal.certain)
        XCTAssertFalse(BotExecutionPrincipal.self is Decodable.Type)
        XCTAssertFalse(BotExecutionPrincipal.self is Encodable.Type)

        let effect = BotToolEffect(tool: "memory", operation: "memory.write",
                                   resource: "memory:user&fact=still-authorized-as-model",
                                   mutability: .write, policy: .ask)
        let decision = await BotExecutionAuthorizer(grants: BotGrantStore(now: { 1_000 }))
            .authorizeExecution(principal: principal, effects: [effect])
        XCTAssertFalse(decision.allowed)
        XCTAssertFalse(decision.userUI)
        XCTAssertEqual(decision.reason, "missing-grant")
    }
}
