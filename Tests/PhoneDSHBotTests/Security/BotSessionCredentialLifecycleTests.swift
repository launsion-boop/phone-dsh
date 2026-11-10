// SPDX-License-Identifier: MIT
//
// B-layer lifecycle regressions: re-sign, rotate, revoke, expiry and Bot
// deletion all invalidate the session credential; the current incarnation is
// the only one that can register an identity.

import XCTest
@testable import PhoneDSHBot

private final class CredentialClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ value: Int64) { self.value = value }

    func now() -> Int64 { lock.withLock { value } }
    func advance(_ milliseconds: Int64) { lock.withLock { value += milliseconds } }
}

final class BotSessionCredentialLifecycleTests: XCTestCase {
    private func expectUnauthorized(_ runtime: BotMCPRuntime, sessionId: String,
                                    token: String, callId: String) async {
        do {
            _ = try await runtime.registerIdentity(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
                callId: callId, name: "ListRoutines", arguments: .object([:]),
                sessionToken: token)
            XCTFail("\(callId): an invalid credential must not register")
        } catch let error as BotMCPError {
            XCTAssertEqual(error, .unauthorized, "\(callId): \(error)")
        } catch {
            XCTFail("\(callId): unexpected error \(error)")
        }
    }

    private func register(_ runtime: BotMCPRuntime, sessionId: String,
                          token: String, callId: String) async throws -> BotAttribution {
        try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
            callId: callId, name: "ListRoutines", arguments: .object([:]),
            sessionToken: token)
    }

    func testReissueRevokesTheOldCredentialAndAcceptsTheCurrentOne() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        let second = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await expectUnauthorized(fixture.runtime, sessionId: "gb-main",
                                 token: first.token, callId: "reissue-old")
        _ = try await register(fixture.runtime, sessionId: "gb-main",
                               token: second.token, callId: "reissue-new")
    }

    func testRotateAndRevokeInvalidateTheOldCredential() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        let rotated = try await fixture.runtime.gateway.tokens.rotate(issued.token)
        let replacement = try XCTUnwrap(rotated)
        await expectUnauthorized(fixture.runtime, sessionId: "gb-main",
                                 token: issued.token, callId: "rotate-old")
        _ = try await register(fixture.runtime, sessionId: "gb-main",
                               token: replacement.token, callId: "rotate-new")
        _ = await fixture.runtime.gateway.tokens.revoke(replacement.token)
        await expectUnauthorized(fixture.runtime, sessionId: "gb-main",
                                 token: replacement.token, callId: "revoked")
    }

    func testExpiryRevokesTheCredential() async throws {
        let clock = CredentialClock(1_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { clock.now() })
        let runtime = BotMCPRuntime(
            store: store, gateway: BotGateway(now: { clock.now() }), now: { clock.now() })
        let issued = try await runtime.gateway.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat, ttlMilliseconds: 5)
        clock.advance(10)
        await expectUnauthorized(runtime, sessionId: "gb-main",
                                 token: issued.token, callId: "expired")
    }

    func testBotDeletionRevokesEverySessionCredentialForThatBot() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let botA = try await fixture.runtime.issueSessionToken(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        let other = try await fixture.runtime.issueSessionToken(
            botId: "bot-b", sessionId: "gb-bot-b", kind: .chat)
        _ = await fixture.runtime.gateway.tokens.revokeBot("bot-a")
        await expectUnauthorized(fixture.runtime, sessionId: "gb-bot-a",
                                 token: botA.token, callId: "deleted-bot")
        _ = try await register(fixture.runtime, sessionId: "gb-bot-b",
                               token: other.token, callId: "surviving-bot")
    }
}
