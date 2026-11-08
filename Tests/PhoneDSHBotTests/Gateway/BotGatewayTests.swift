// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private func assertTrue(_ expression: @autoclosure () async -> Bool) async {
    let value = await expression()
    XCTAssertTrue(value)
}

private func assertFalse(_ expression: @autoclosure () async -> Bool) async {
    let value = await expression()
    XCTAssertFalse(value)
}

private func assertNil<T>(_ expression: @autoclosure () async throws -> T?) async rethrows {
    let value = try await expression()
    XCTAssertNil(value)
}

private func assertNotNil<T>(_ expression: @autoclosure () async throws -> T?) async rethrows {
    let value = try await expression()
    XCTAssertNotNil(value)
}

private func assertEqual<T: Equatable>(_ lhs: @autoclosure () async -> T,
                                       _ rhs: @autoclosure () async -> T) async {
    let left = await lhs()
    let right = await rhs()
    XCTAssertEqual(left, right)
}

private func unwrap<T>(_ expression: @autoclosure () async throws -> T?) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value)
}

final class BotTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ value: Int64) {
        self.value = value
    }

    func now() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ milliseconds: Int64) {
        lock.lock()
        value += milliseconds
        lock.unlock()
    }
}

final class BotGatewayTests: XCTestCase {
    func testStableArgumentDigestMatchesPinnedSHA256() throws {
        let digest = try BotArgumentsDigest.string(for: .object(["secret": .string("not-recorded")]))
        XCTAssertEqual(digest, "9c58b105c0e3377b8052885445b4db03b3a2024b847396617dfd5152c05e9c06")
        let reordered = try BotArgumentsDigest.string(for: .object([
            "b": .array([.number(1), .bool(true), .null]),
            "a": .object(["nested": .string("值")]),
        ]))
        let same = try BotArgumentsDigest.string(for: .object([
            "a": .object(["nested": .string("值")]),
            "b": .array([.number(1), .bool(true), .null]),
        ]))
        XCTAssertEqual(reordered, same)
    }

    func testTokenLookupRotationRevocationAndExpiry() async throws {
        let clock = BotTestClock(1_000)
        let registry = BotTokenRegistry(now: { clock.now() }, defaultTTLMilliseconds: 1_000)
        let issued = try await registry.issue(botId: " main ", sessionId: " session ",
                                              kind: .chat, capabilities: ["memory", "memory", " cards "])
        XCTAssertEqual(issued.principal.botId, "main")
        XCTAssertEqual(issued.principal.sessionId, "session")
        XCTAssertEqual(issued.principal.capabilities, ["memory", "cards"])
        XCTAssertEqual(issued.principal.expiresAt, 2_000)
        XCTAssertTrue(issued.token.hasPrefix("dshg_"))
        let principal = await registry.lookup(issued.token)
        XCTAssertEqual(principal, issued.principal)
        await assertNil(await registry.lookup("dshg_forged"))
        await assertNotNil(await registry.lookupBearer("\tBearer  \(issued.token) \n"))
        await assertNil(await registry.lookupBearer("Basic \(issued.token)"))

        let rotated = try await unwrap(await registry.rotate(issued.token, ttlMilliseconds: 2_000))
        await assertNil(await registry.lookup(issued.token))
        await assertNotNil(await registry.lookup(rotated.token))
        await assertTrue(await registry.revoke(rotated.token))
        await assertFalse(await registry.revoke(rotated.token))

        let expiring = try await registry.issue(botId: "main", sessionId: "short", kind: .task)
        clock.advance(1_000)
        await assertNil(await registry.lookup(expiring.token))
        await assertEqual(await registry.count, 0)
    }

    func testSessionAndBotRevocation() async throws {
        let registry = BotTokenRegistry(now: { 1_000 })
        let chat = try await registry.issue(botId: "a", sessionId: "chat", kind: .chat)
        let task = try await registry.issue(botId: "a", sessionId: "task", kind: .task)
        let other = try await registry.issue(botId: "b", sessionId: "other", kind: .chat)
        await assertEqual(await registry.revokeSession("chat"), 1)
        await assertNil(await registry.lookup(chat.token))
        await assertNotNil(await registry.lookupSession("task"))
        await assertEqual(await registry.revokeBot("a"), 1)
        await assertNil(await registry.lookup(task.token))
        await assertNotNil(await registry.lookup(other.token))
    }

    func testGatewayRequiresActiveIdentityAndConsumesExactClaim() async throws {
        let clock = BotTestClock(10_000)
        let gateway = BotGateway(now: { clock.now() })
        _ = try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let arguments = BotJSONValue.object(["query": .string("简短"), "limit": .number(5)])
        let registration = try await gateway.registerToolCall(sessionId: "gb-main", callId: "call-1",
                                                              name: "mcp__dshbot__RecallMemory",
                                                              arguments: arguments, runtimeId: "runtime-1")
        let wrongDigest = try BotArgumentsDigest.string(for: .object(["query": .string("其他")]))
        await assertNil(await gateway.resolveToolCall(runtimeId: "runtime-1", name: "RecallMemory", argsDigest: wrongDigest))
        await assertNil(await gateway.resolveToolCall(runtimeId: "runtime-2", name: "RecallMemory", arguments: arguments))
        let resolved = try await unwrap(await gateway.resolveToolCall(runtimeId: "runtime-1", name: "RecallMemory", arguments: arguments))
        XCTAssertEqual(resolved.agentId, "main")
        XCTAssertEqual(resolved.callId, "call-1")
        XCTAssertEqual(resolved.attribution, registration)
        await assertNil(await gateway.resolveToolCall(runtimeId: "runtime-1", name: "RecallMemory", arguments: arguments))

        do {
            _ = try await gateway.registerToolCall(sessionId: "unknown", callId: "call-2",
                                                   name: "RecallMemory", runtimeId: "runtime-1")
            XCTFail("an unknown session must not register a call")
        } catch {
            XCTAssertEqual(error as? BotGatewayError, .unknownSession)
        }
    }

    func testRevokedPrincipalCannotResolvePendingClaim() async throws {
        let gateway = BotGateway(now: { 1_000 })
        let issued = try await gateway.issueToken(botId: "main", sessionId: "gb-main", kind: .chat)
        let registration = try await gateway.registerToolCall(sessionId: "gb-main", callId: "call-1",
                                                              name: "UpdateMemory", runtimeId: "runtime")
        await assertTrue(await gateway.tokens.revoke(issued.token))
        let digest = registration.argsDigest
        await assertNil(await gateway.resolveToolCall(runtimeId: "runtime", name: "UpdateMemory", argsDigest: digest))
        await assertNil(await gateway.resolveToolCall(runtimeId: "runtime", name: "UpdateMemory", argsDigest: digest))
    }

    func testClaimIsBoundToToolNameAndCannotStealAnotherRegistration() async throws {
        let gateway = BotGateway(now: { 1_000 })
        _ = try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let arguments = BotJSONValue.object(["value": .string("same")])
        let bash = try await gateway.registerToolCall(
            sessionId: "gb-main", callId: "bash-call", name: "mcp__phone__bash",
            arguments: arguments, runtimeId: "runtime")
        let write = try await gateway.registerToolCall(
            sessionId: "gb-main", callId: "write-call", name: "mcp__phone__write",
            arguments: arguments, runtimeId: "runtime")
        XCTAssertEqual(bash.name, "bash")
        XCTAssertEqual(write.name, "write")

        let claimedWrite = try await unwrap(await gateway.resolveToolCall(
            runtimeId: "runtime", name: "write", arguments: arguments))
        XCTAssertEqual(claimedWrite.callId, "write-call")
        await assertNil(await gateway.resolveToolCall(runtimeId: "runtime", name: "write", arguments: arguments))
        let claimedBash = try await unwrap(await gateway.resolveToolCall(
            runtimeId: "runtime", name: "bash", arguments: arguments))
        XCTAssertEqual(claimedBash.callId, "bash-call")
        await assertNil(await gateway.resolveToolCall(runtimeId: "runtime", name: "edit", arguments: arguments))
    }

    func testAttributionDuplicateExpiryAmbiguityAndRuntimeScope() async throws {
        let clock = BotTestClock(1_000)
        let registry = BotAttributionRegistry(now: { clock.now() })
        let arguments = BotJSONValue.object(["same": .bool(true)])
        _ = try await registry.register(sessionId: "s1", incarnation: "i1", callId: "c1", name: "A",
                                        arguments: arguments, runtimeId: "r1")
        do {
            _ = try await registry.register(sessionId: "s1", incarnation: "i1", callId: "c2", name: "A",
                                            arguments: arguments, runtimeId: "r1")
            XCTFail("duplicate live registration must fail")
        } catch {
            XCTAssertEqual(error as? BotAttributionError, .duplicate)
        }
        _ = try await registry.register(sessionId: "s2", incarnation: "i2", callId: "c2", name: "B",
                                        arguments: arguments, runtimeId: "r1")
        try await assertNil(try await registry.claimByDigest(arguments: arguments, runtimeId: "r1"))
        await assertEqual(await registry.pendingCount(runtimeId: "r1"), 2)
        let first = try await unwrap(await registry.claim(sessionId: "s1", name: "A",
                                                          arguments: arguments, runtimeId: "r1"))
        XCTAssertEqual(first.callId, "c1")
        XCTAssertEqual(first.incarnation, "i1")
        try await assertNotNil(try await registry.claimByDigest(arguments: arguments, runtimeId: "r1"))

        _ = try await registry.register(sessionId: "s3", incarnation: "i3", callId: "c3", name: "A",
                                        arguments: arguments, runtimeId: "r2")
        _ = try await registry.register(sessionId: "s4", incarnation: "i4", callId: "c4", name: "A",
                                        arguments: arguments, runtimeId: "r3")
        try await assertNotNil(try await registry.claimByDigest(arguments: arguments, runtimeId: "r2"))
        try await assertNotNil(try await registry.claimByDigest(arguments: arguments, runtimeId: "r3"))

        let expiring = try await registry.register(sessionId: "s5", incarnation: "i5", callId: "c5", name: "A",
                                                   arguments: .object(["expiry": .bool(true)]), runtimeId: "r4")
        // The runtime TTL covers the 300 s approval window; one registration
        // must survive that wait and then expire.
        clock.advance(BotAttributionRegistry.defaultTTLMilliseconds + 1)
        try await assertNil(try await registry.claimByDigest(argsDigest: expiring.argsDigest, runtimeId: "r4"))
        await assertEqual(await registry.count, 0)
    }
}
