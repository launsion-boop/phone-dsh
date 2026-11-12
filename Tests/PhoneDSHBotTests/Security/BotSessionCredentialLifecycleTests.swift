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

    /// The report's lost-Worker shape: the App still holds the current token,
    /// the Worker was rebuilt with an empty map. The first registration carries
    /// no token and fails; the App re-claims the exact token into the rebuilt
    /// Worker and the Worker's retry succeeds. A token for another session is
    /// never healed.
    func testUnauthorizedRegistrationReclaimsOnlyTheOwnedSession() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let firstTransport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("ok"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(
            transport: firstTransport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("hello")
        let current = try XCTUnwrap(firstTransport.claimedSessionTokens.last)
        XCTAssertEqual(current.sessionId, "gb-main")
        let token = try XCTUnwrap(current.sessionToken)

        // Foreground resume: a fresh Worker/transport with an empty token map.
        let rebuilt = BotScriptedRemoteTransport(scripts: [:])
        await remote.attachTransport(rebuilt)
        XCTAssertTrue(rebuilt.claimedSessionTokens.isEmpty)

        let recorder = ReclaimRecorder()
        await fixture.runtime.installSessionReclaimer { sessionId, suppliedToken in
            await recorder.record(sessionId, suppliedToken)
            return await remote.reclaimSessionForIdentity(
                sessionId, suppliedToken: suppliedToken)
        }

        do {
            _ = try await fixture.runtime.registerIdentity(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
                callId: "lost-worker", name: "ListRoutines", arguments: .object([:]),
                sessionToken: "")
            XCTFail("a Worker without a credential must start closed")
        } catch let error as BotMCPError {
            XCTAssertEqual(error, .unauthorized)
        }
        let calls = await recorder.snapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.sessionId, "gb-main")
        XCTAssertEqual(calls.first?.suppliedToken, "")
        XCTAssertEqual(rebuilt.claimedSessionTokens.last?.sessionToken, token,
                       "the App must re-claim the current token, not issue a new one")
        let diagnostic = await fixture.runtime.lastBridgeError()
        XCTAssertEqual(diagnostic?.code, "unauthorized")
        XCTAssertEqual(diagnostic?.sessionId, "gb-main")

        // The Worker retries with the re-claimed token and succeeds.
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "lost-worker-retry", name: "ListRoutines", arguments: .object([:]),
            sessionToken: token)
        let cleared = await fixture.runtime.lastBridgeError()
        XCTAssertNil(cleared)

        // A token minted for another session is an impersonation attempt, not
        // a lost Worker map: it must stay unauthorized and trigger no claim.
        let other = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-other", kind: .chat)
        do {
            _ = try await fixture.runtime.registerIdentity(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
                callId: "cross-session", name: "ListRoutines", arguments: .object([:]),
                sessionToken: other.token)
            XCTFail("another session's token must never register gb-main")
        } catch let error as BotMCPError {
            XCTAssertEqual(error, .unauthorized)
        }
        let callsAfterCrossSession = await recorder.snapshot()
        XCTAssertEqual(callsAfterCrossSession.count, 1,
                       "a cross-session token must not trigger a reclaim")
    }

    /// The Worker's lost-map request has no `sessionToken` at all, so the
    /// HTTP handler must run the same reclaim seam before it answers.
    func testHTTPIdentityHandlerReclaimsOnAMissingToken() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        let recorder = ReclaimRecorder()
        await fixture.runtime.installSessionReclaimer { sessionId, suppliedToken in
            await recorder.record(sessionId, suppliedToken)
            return true
        }
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let reply = await handler.registerIdentity(.object([
            "runtimeId": .string(BotMCPRuntime.defaultRuntimeID),
            "sessionId": .string("gb-main"),
            "callId": .string("missing-token-call"),
            "name": .string("ListRoutines"),
            "arguments": .object([:]),
        ]))
        XCTAssertEqual(reply["ok"], .bool(false))
        XCTAssertEqual(reply["error"], .string("unauthorized"))
        let calls = await recorder.snapshot()
        XCTAssertEqual(calls.count, 1, "a missing token must not skip the reclaim seam")
        XCTAssertEqual(calls.first?.sessionId, "gb-main")
        XCTAssertEqual(calls.first?.suppliedToken, "")
        let diagnostic = await fixture.runtime.lastBridgeError()
        XCTAssertEqual(diagnostic?.code, "unauthorized")
    }

    /// A token registry rebuild (or any re-sign the Worker did not observe)
    /// makes the stored token stale. Reclaim reissues with the same session
    /// kind/capabilities; it never extends the old TTL or reuses the old token.
    func testReclaimOwnedSessionsReissuesAStaleHostTokenAtTheNextBind() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("ok"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(
            transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("hello")
        let oldToken = try XCTUnwrap(transport.claimedSessionTokens.last?.sessionToken)

        // Re-sign behind the remote's back: the old token is revoked and the
        // Worker was not told. This is the rebuilt-token-registry shape.
        let unclaimed = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        XCTAssertNotEqual(unclaimed.token, oldToken)

        let reclaimed = await remote.reclaimOwnedSessions()
        XCTAssertEqual(reclaimed, 1)
        let newest = try XCTUnwrap(transport.claimedSessionTokens.last)
        XCTAssertEqual(newest.sessionId, "gb-main")
        let freshToken = try XCTUnwrap(newest.sessionToken)
        XCTAssertNotEqual(freshToken, oldToken)
        XCTAssertNotEqual(freshToken, unclaimed.token,
                          "reclaim issues for the session's current state, it does not guess")

        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "fresh-after-reclaim", name: "ListRoutines", arguments: .object([:]),
            sessionToken: freshToken)
        for stale in [oldToken, unclaimed.token] {
            do {
                _ = try await fixture.runtime.registerIdentity(
                    runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
                    callId: "stale-\(stale.prefix(6))", name: "ListRoutines",
                    arguments: .object([:]), sessionToken: stale)
                XCTFail("a stale token must stay invalid after reclaim")
            } catch let error as BotMCPError {
                XCTAssertEqual(error, .unauthorized)
            }
        }
    }
}

private actor ReclaimRecorder {
    private var entries: [(sessionId: String, suppliedToken: String)] = []
    func record(_ sessionId: String, _ suppliedToken: String) {
        entries.append((sessionId, suppliedToken))
    }
    func snapshot() -> [(sessionId: String, suppliedToken: String)] { entries }
}
