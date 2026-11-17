// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Identity → structural-approval attribution (P26). Regression for the eval
/// harness failure where every `bash` call after a Worker boot was reported as
/// `[structural approval gate] … 身份登记已失效`: the runtime compared the
/// gateway's wall-clock `expiresAt` with its own injected clock (the harness
/// starts every scenario at local noon), so fresh registrations were already
/// "expired" at the moment the card was requested.
final class BotMCPIdentityApprovalTests: XCTestCase {
    private var directory: URL!
    private var store: SQLiteDomainStore!

    private let wallClock: Int64 = 1_760_000_000_000
    private let skewMilliseconds: Int64 = 8 * 60 * 60 * 1_000
    private let timeoutMs = 60_000
    private let expiryMs = 60_000

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-identity-approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { self.wallClock })
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Positive: attribution survives clock domains and Worker restarts

    func testBashApprovalStaysAttributedWhenRuntimeClockRunsAhead() async throws {
        let gateway = BotGateway(now: { self.wallClock })
        let runtime = makeRuntime(gateway: gateway, now: wallClock + skewMilliseconds)
        try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let digest = try await register(runtime, session: "gb-main", callId: "call-bash",
                                        command: "printf SELFTEST_TOOL > tool.txt")

        // The exact pre-card gate the structural approval uses.
        let identity = await runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main", callId: "call-bash")
        XCTAssertNotNil(identity, "a fresh registration must stay attributable")

        let outcome = await approve(runtime, session: "gb-main", callId: "call-bash",
                                    command: "printf SELFTEST_TOOL > tool.txt", digest: digest)
        XCTAssertTrue(outcome.ok, "\(outcome.message ?? "")")
        XCTAssertNotEqual(outcome.message, "unattributed")
        if outcome.pending {
            let resolved = await runtime.approvals.resolve(
                approvalId: outcome.approvalId ?? "", decision: .allowOnce, digest: digest)
            XCTAssertEqual(resolved, .resolved)
        } else {
            XCTAssertTrue(outcome.allowed || outcome.ok)
        }
    }

    func testApprovalAfterWorkerRestartWithFreshRegistrationIsAttributed() async throws {
        let gateway = BotGateway(now: { self.wallClock })
        let runtime = makeRuntime(gateway: gateway, now: wallClock + skewMilliseconds)
        try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        _ = try await register(runtime, session: "gb-main", callId: "call-before",
                               command: "printf before > before.txt")
        _ = await runtime.workerRestarted()

        // The Worker registers again under the new generation.
        let digest = try await register(runtime, session: "gb-main", callId: "call-after",
                                        command: "printf after > after.txt")
        let outcome = await approve(runtime, session: "gb-main", callId: "call-after",
                                    command: "printf after > after.txt", digest: digest)
        XCTAssertTrue(outcome.ok, "\(outcome.message ?? "")")
        XCTAssertNotEqual(outcome.message, "unattributed")
        let identity = await runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main", callId: "call-after")
        XCTAssertNotNil(identity, "the new generation's registration must be attributable")
    }

    // MARK: - Negative: the gate must still fail closed

    func testUnregisteredCallIsUnattributed() async throws {
        let gateway = BotGateway(now: { self.wallClock })
        let runtime = makeRuntime(gateway: gateway, now: wallClock + skewMilliseconds)
        try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let outcome = await approve(runtime, session: "gb-main", callId: "never-registered",
                                    command: "printf nope > nope.txt",
                                    digest: try BotArgumentsDigest.string(for: bashArguments("printf nope > nope.txt")))
        XCTAssertEqual(outcome.message, "unattributed")
        XCTAssertFalse(outcome.allowed)
    }

    func testApprovalForAnotherSessionIsUnattributed() async throws {
        let gateway = BotGateway(now: { self.wallClock })
        let runtime = makeRuntime(gateway: gateway, now: wallClock + skewMilliseconds)
        try await gateway.issueSession(botId: "main", sessionId: "gb-a", kind: .chat)
        try await gateway.issueSession(botId: "main", sessionId: "gb-b", kind: .chat)
        let command = "printf cross > cross.txt"
        let digest = try await register(runtime, session: "gb-a", callId: "call-cross", command: command)
        let outcome = await approve(runtime, session: "gb-b", callId: "call-cross",
                                    command: command, digest: digest)
        XCTAssertEqual(outcome.message, "unattributed",
                       "a registration for gb-a must not authorize gb-b")
    }

    func testApprovalFromBeforeWorkerRestartIsUnattributed() async throws {
        let gateway = BotGateway(now: { self.wallClock })
        let runtime = makeRuntime(gateway: gateway, now: wallClock + skewMilliseconds)
        try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let command = "printf stale > stale.txt"
        let digest = try await register(runtime, session: "gb-main", callId: "call-stale",
                                        command: command)
        _ = await runtime.workerRestarted()
        let outcome = await approve(runtime, session: "gb-main", callId: "call-stale",
                                    command: command, digest: digest)
        XCTAssertEqual(outcome.message, "unattributed",
                       "a replaced Worker's registration must never be claimable")
    }

    func testRuntimeDeadlineStillExpiresARegistration() async throws {
        let gateway = BotGateway(now: { self.wallClock })
        let command = "printf late > late.txt"
        let clock = ClockBox(wallClock)
        let runtime = makeRuntime(gateway: gateway, now: { clock.now })
        try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let digest = try await register(runtime, session: "gb-main", callId: "call-late",
                                        command: command)
        // Move past the runtime-clock bound without touching the gateway clock:
        // the local deadline must still fail closed.
        clock.now = wallClock + BotAttributionRegistry.defaultTTLMilliseconds + 1_000
        let expired = await runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main", callId: "call-late")
        XCTAssertNil(expired)
        let outcome = await approve(runtime, session: "gb-main", callId: "call-late",
                                    command: command, digest: digest)
        XCTAssertEqual(outcome.message, "unattributed")
    }

    func testRegistryExpiryStillGovernsApproval() async throws {
        // A gateway with a one-second attribution TTL keeps the registry as the
        // expiry authority: the runtime's longer local bound must not revive it.
        let clock = ClockBox(wallClock)
        let gateway = BotGateway(now: { clock.now }, attributionTTLMilliseconds: 1_000)
        let runtime = makeRuntime(gateway: gateway, now: { clock.now })
        try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let command = "printf expired > expired.txt"
        let digest = try await register(runtime, session: "gb-main", callId: "call-expired",
                                        command: command)
        clock.now = wallClock + 2_000
        let outcome = await approve(runtime, session: "gb-main", callId: "call-expired",
                                    command: command, digest: digest)
        XCTAssertEqual(outcome.message, "unattributed",
                       "the registry, not the runtime's local bound, owns expiry")
    }

    // MARK: - Helpers

    private final class ClockBox: @unchecked Sendable {
        var now: Int64
        init(_ now: Int64) { self.now = now }
    }

    private func makeRuntime(gateway: BotGateway, now: @escaping @Sendable () -> Int64)
        -> BotMCPRuntime {
        BotMCPRuntime(
            store: store, gateway: gateway, now: now,
            approvalTimeoutMs: Int64(timeoutMs), approvalExpiryMs: Int64(expiryMs))
    }

    private func makeRuntime(gateway: BotGateway, now: Int64) -> BotMCPRuntime {
        makeRuntime(gateway: gateway, now: { now })
    }

    private func bashArguments(_ command: String) -> BotJSONValue {
        .object(["command": .string(command), "description": .string("identity regression")])
    }

    @discardableResult
    private func register(_ runtime: BotMCPRuntime, session: String, callId: String,
                          command: String) async throws -> String {
        let arguments = bashArguments(command)
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: session,
            callId: callId, name: "bash", arguments: arguments)
        return try BotArgumentsDigest.string(for: arguments)
    }

    private func approve(_ runtime: BotMCPRuntime, session: String, callId: String,
                         command: String, digest: String) async -> BotApprovalOutcome {
        await runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: session,
            callId: callId, name: "bash", action: "run-command",
            detail: "identity regression", command: command,
            argsDigest: digest, alwaysScope: "until", askAction: "run-command")
    }
}
