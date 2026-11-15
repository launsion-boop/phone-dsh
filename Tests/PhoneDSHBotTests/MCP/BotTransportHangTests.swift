// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHBot

/// Regressions for the production hang where a chat send waited forever after
/// a Worker rebind: the UI stayed on "等待响应", the Worker received no
/// `session/chat`, and no durable Bot event was written.
///
/// Two mechanisms are pinned here:
/// 1. Every handshake/idle await on the live transport is bounded. A transport
///    that accepted `attachTransport` (or `openMux`) but never answers must
///    fail retryably inside the deadline, mark itself dead, and tell the App
///    once per generation so it can rebind.
/// 2. A turn queued behind an attempt from a replaced transport generation is
///    released with a retryable result instead of awaiting a stream that can
///    never settle; a later send starts on the current transport.
@MainActor
final class BotTransportHangTests: XCTestCase {
    // MARK: - Bounded handshake

    /// `attachTransport` only records that a transport object exists. A socket
    /// that never answers `openMux` used to suspend the collector forever, so
    /// every later send queued behind it. The send must fail inside the
    /// configured deadline with the stable retryable message, report the unit
    /// as not live, and fire the App's failure hook exactly once.
    func testAHungOpenMuxFailsTheSendWithinTheDeadlineAndReportsTheDeadTransport() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotHangingTransport()
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        await remote.setTransportDeadlineMilliseconds(150)
        let failures = BotFailureCounter()
        await remote.setTransportFailureHandler { await failures.record() }

        let started = ContinuousClock.now
        do {
            _ = try await remote.sendUserMessage("hello")
            XCTFail("a transport that never answers openMux must not let the send hang")
        } catch let error as BotMCPError {
            XCTAssertEqual(error, .unavailable(BotTransportDeadline.unresponsiveMessage))
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .seconds(2),
                          "the send must fail inside the configured deadline, elapsed \(elapsed)")
        XCTAssertEqual(transport.openMuxAttempts, 1,
                       "the deadline must expire while openMux is the suspended request")

        let live = await remote.hasLiveTransport()
        XCTAssertFalse(live, "a transport that missed its deadline must not report live")
        let busy = await remote.isMainTurnBusy()
        XCTAssertFalse(busy, "the stalled attempt must be dropped, not left as the queue head")
        let failureCount = await failures.count
        XCTAssertEqual(failureCount, 1, "the App's rebind hook fires once for the failing generation")

        // A second send on the same dead generation still fails retryably
        // (rather than hanging); it must not fire the rebind hook again.
        let retryStarted = ContinuousClock.now
        do {
            _ = try await remote.sendUserMessage("again")
            XCTFail("the dead generation must keep failing retryably")
        } catch let error as BotMCPError {
            XCTAssertEqual(error, .unavailable(BotTransportDeadline.unresponsiveMessage))
        }
        XCTAssertLessThan(ContinuousClock.now - retryStarted, .seconds(2))
        let failureCountAfterRetry = await failures.count
        XCTAssertEqual(failureCountAfterRetry, 1,
                       "the failure handler is per generation, not per failed send")
        XCTAssertEqual(transport.openMuxAttempts, 2)

        // Adopting a live transport clears the dead flag for the next bind.
        await remote.attachTransport(BotScriptedRemoteTransport(scripts: [:]))
        let liveAfterRebind = await remote.hasLiveTransport()
        XCTAssertTrue(liveAfterRebind)
    }

    // MARK: - Generation-fenced queue

    /// The reported shape: a turn is collecting on a Worker, another turn is
    /// queued behind it, and the App rebinds because the transport stopped
    /// answering. The queued caller must be released retryably and the next
    /// send must start on the replacement transport instead of waiting behind
    /// the old generation's attempt, which never settles.
    func testARebindReleasesAQueuedTurnAndTheNextSendStartsOnTheNewTransport() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let old = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("partial"), .end()]],
        ])
        old.pause("gb-main")
        let remote = try await BotDSHRemoteRuntime(transport: old, runtime: fixture.runtime)
        // The handshake bound is irrelevant to this test; keep the stream idle
        // bound long so the predecessor really is "never settles".
        await remote.setTransportDeadlineMilliseconds(2_000)
        await remote.setCollectIdleDeadlineMilliseconds(10_000)

        let first = Task { try await remote.sendUserMessage("first") }
        try await waitUntil { old.promptHistory.count == 1 }
        let second = Task {
            try await remote.sendAgentMessage("second", requestId: "agent:queued")
        }
        try await waitUntil { await remote.queuedSessionIDs().contains("gb-main") }

        let replacementBase = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(2), .assistant("new answer"), .end(turn: 2)]],
        ])
        // The claim delay is intentional: it guarantees the third send reaches
        // the queue fence while `attachTransport` is still in its bounded 2 s
        // settle wait (the paused predecessor never settles on its own).
        let replacement = BotSlowClaimTransport(
            base: replacementBase, claimDelay: .milliseconds(300))
        let generationBefore = await remote.transportGenerationIdentifier()
        let attach = Task { await remote.attachTransport(replacement) }
        try await waitUntil {
            await remote.transportGenerationIdentifier() > generationBefore
        }

        let third = Task { try await remote.sendUserMessage("third") }
        let thirdResult = try await third.value
        XCTAssertEqual(thirdResult.status, "completed", thirdResult.error ?? "no error")
        XCTAssertEqual(thirdResult.text, "new answer",
                       "the send must run on the replacement transport")
        XCTAssertEqual(replacementBase.promptHistory.count, 1,
                       "exactly one prompt reaches the replacement Worker")
        XCTAssertEqual(replacementBase.promptHistory.first?.text, "third")

        let secondResult = try await second.value
        XCTAssertEqual(secondResult.status, "interrupted", secondResult.error ?? "no error")
        XCTAssertEqual(secondResult.error, "transport_replaced",
                       "a queued caller from the replaced generation gets a retryable result")

        await attach.value
        let queuedAfter = await remote.queuedSessionIDs()
        XCTAssertTrue(queuedAfter.isEmpty, "old-generation queued entries must be dropped")
        XCTAssertTrue(old.cancellations.isEmpty,
                      "adopting a replacement must never send session/cancel")

        old.closeMuxes()
        // The fenced predecessor settles as a cancellation; it must not hang
        // the test on its abandoned stream.
        do {
            let result = try await first.value
            XCTAssertEqual(result.status, "cancelled", result.error ?? "no error")
        } catch is CancellationError {
            // Cancelling the old attempt is the fence's documented behaviour.
        } catch {
            XCTFail("unexpected old-turn error: \(error)")
        }

        // PR #173's durable "被打断" marker is still written for the visible
        // in-flight turn that the rebind cut, even when a new send fences it
        // before the bounded adopt wait expires.
        let events = try await botEvents(fixture.store)
        let markers = events.filter {
            $0.type == "ui.notice" && $0.data["interrupted"] == .bool(true)
        }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.data["reason"]?.stringValue, "transport_replaced")
    }

    // MARK: - Pending action replay

    /// A committed card answer is replayed by submitting only its prompt: the
    /// caller must not wait for the turn or open a collector, and the Worker's
    /// `requestId` makes the replay idempotent.
    func testResumePendingPromptSubmitsWithoutOpeningACollector() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("the answer"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        await remote.setTransportDeadlineMilliseconds(500)

        try await remote.resumePendingPrompt(
            "answer: option A", requestId: "card-answer:nonce-1")
        XCTAssertEqual(transport.promptHistory.count, 1)
        XCTAssertEqual(transport.promptHistory.first?.mode, "queue")
        XCTAssertEqual(transport.promptRequestIds.first?.requestId, "card-answer:nonce-1")
        XCTAssertEqual(transport.openMuxCount, 0,
                       "a pending replay must not open a follow collector")
        XCTAssertTrue(transport.cancellations.isEmpty)

        // Replaying the same committed action submits the same idempotency key
        // so the Worker reuses the turn instead of opening a second one.
        try await remote.resumePendingPrompt(
            "answer: option A", requestId: "card-answer:nonce-1")
        XCTAssertEqual(transport.promptRequestIds.map(\.requestId),
                       ["card-answer:nonce-1", "card-answer:nonce-1"])
        XCTAssertTrue(transport.cancellations.isEmpty)
    }

    /// The replay uses the same bounded prompt request as a collected turn: a
    /// Worker that never answers it must fail retryably and report the dead
    /// transport to the App's rebind hook.
    func testAPendingPromptReplayFailsRetryablyWhenThePromptNeverAnswers() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotHangingTransport(hangCalls: ["session/prompt"])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        await remote.setTransportDeadlineMilliseconds(150)
        let failures = BotFailureCounter()
        await remote.setTransportFailureHandler { await failures.record() }

        let started = ContinuousClock.now
        do {
            try await remote.resumePendingPrompt("retry", requestId: "card-answer:hang")
            XCTFail("a prompt the transport never answers must not return")
        } catch let error as BotMCPError {
            XCTAssertEqual(error, .unavailable(BotTransportDeadline.unresponsiveMessage))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        let live = await remote.hasLiveTransport()
        XCTAssertFalse(live)
        let failureCount = await failures.count
        XCTAssertEqual(failureCount, 1)
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition did not become true", file: file, line: line)
    }
}

// MARK: - Doubles

private actor BotFailureCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

/// Accepts every unary call but never opens a mux. Cancellation is ignored on
/// purpose: a real dead socket does not resume because the client cancelled.
private final class BotHangingTransport: DSHRemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var muxAttempts = 0
    private let hangCalls: Set<String>

    init(hangCalls: Set<String> = []) {
        self.hangCalls = hangCalls
    }

    var openMuxAttempts: Int { lock.withLock { muxAttempts } }

    func call(_ endpoint: String, args: BotJSONValue) async throws -> BotJSONValue {
        if hangCalls.contains(endpoint) {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            throw BotMCPError.unavailable("unreachable")
        }
        switch endpoint {
        case "session/create":
            let sessionId = args["request"]?["sessionId"]?.stringValue ?? "gb-main"
            let preset = args["request"]?["agentPreset"]?.stringValue ?? "phone-bot"
            return .object([
                "sessionId": .string(sessionId), "agentPreset": .string(preset),
            ])
        case "session/page":
            let sessionId = args["request"]?["address"]?["sessionId"]?.stringValue ?? ""
            return .object(["sessionId": .string(sessionId)])
        case "phone/botClaimSession":
            return .object([
                "ok": .bool(true),
                "sessionId": .string(args["request"]?["sessionId"]?.stringValue ?? ""),
            ])
        default:
            return .object([:])
        }
    }

    func openMux() async throws -> any DSHMuxConnection {
        lock.withLock { muxAttempts += 1 }
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        throw BotMCPError.unavailable("unreachable")
    }
}

/// Delegates to the scripted transport, but delays the session claim so a
/// concurrent send reliably reaches the generation fence while
/// `attachTransport` is still settling the replaced attempt.
private final class BotSlowClaimTransport: DSHRemoteTransport, @unchecked Sendable {
    let base: BotScriptedRemoteTransport
    let claimDelay: Duration

    init(base: BotScriptedRemoteTransport, claimDelay: Duration) {
        self.base = base
        self.claimDelay = claimDelay
    }

    func call(_ endpoint: String, args: BotJSONValue) async throws -> BotJSONValue {
        if endpoint == "phone/botClaimSession" {
            try? await Task.sleep(for: claimDelay)
        }
        return try await base.call(endpoint, args: args)
    }

    func openMux() async throws -> any DSHMuxConnection {
        try await base.openMux()
    }

    func authenticationFailed() async {
        await base.authenticationFailed()
    }
}
