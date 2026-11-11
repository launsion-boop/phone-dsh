// SPDX-License-Identifier: MIT
// Regression for the App-side Worker recovery scheduling (d-heal).
//
// The host emits `.webContentTerminated` before the replacement Worker boots.
// Binding at that point opens a transport into a channel that does not exist
// yet; the old composition could then drop the later HELLO of the new boot and
// leave the Bot page at "正在重新同步…" forever. These tests drive the
// scheduler's real state machine with a fake bind (the composition's bind is
// the only production caller) and assert the final boot is claimed once.

import XCTest
@testable import PhoneDSHBot

@MainActor
final class BotWorkerRecoverySchedulerTests: XCTestCase {
    func testNewBootDuringAnInFlightRecoveryIsRecoveredAfterTheFirstAttempt() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        defer { scheduler.stop() }
        var attempts: [String?] = []
        // Production's recovery closure is `bind`, which calls
        // `BotRuntimeUnit.start` -> `remote.reclaimOwnedSessions()`.
        var reclaimCalls = 0
        scheduler.install { bootID in
            attempts.append(bootID)
            if bootID == "boot-one" {
                // Simulate the old composition's bind: it opened a transport
                // before the replacement Worker answered HELLO and waited.
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            reclaimCalls += 1
        }

        scheduler.noteWorkerBoot("boot-one")
        let started = await waitUntil { attempts == ["boot-one"] }
        XCTAssertTrue(started, "the first boot must start one bind; attempts=\(attempts)")
        scheduler.noteWorkerBoot("boot-two")

        let ready = await waitUntil(timeout: 2) {
            scheduler.phase == .ready && scheduler.recoveredBootID == "boot-two"
        }
        XCTAssertTrue(ready,
                      "a newer Worker boot must be rebound after the first attempt ends; "
                          + "phase=\(scheduler.phase) attempts=\(attempts)")
        XCTAssertEqual(attempts, ["boot-one", "boot-two"])
        XCTAssertEqual(reclaimCalls, 1, "the latest boot is claimed exactly once")
    }

    func testTerminationAloneDoesNotBindBeforeAReplacementBootIsKnown() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        defer { scheduler.stop() }
        var attempts: [String?] = []
        scheduler.install { bootID in attempts.append(bootID) }

        scheduler.noteTermination(count: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(scheduler.phase, .recovering)
        XCTAssertTrue(attempts.isEmpty,
                      "the old Worker is dead and no replacement has HELLOed yet; "
                          + "opening a transport here is what stalled the d scenario: \(attempts)")

        scheduler.noteWorkerBoot("boot-new")
        let ready = await waitUntil { scheduler.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(attempts, ["boot-new"])
    }

    func testRestartCandidateShowsRecoveringButWaitsForHello() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        defer { scheduler.stop() }
        var attempts: [String?] = []
        scheduler.install { bootID in attempts.append(bootID) }

        scheduler.noteBootCandidate("boot-page")
        XCTAssertEqual(scheduler.phase, .recovering)
        XCTAssertTrue(attempts.isEmpty,
                      "page boot-ready is not yet a channel; the HELLO owns the bind")
        scheduler.noteWorkerBoot("boot-page")
        let ready = await waitUntil { scheduler.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(attempts, ["boot-page"])
    }

    func testAHungBindTimesOutIntoAFailedState() async throws {
        // Retry budget 0: this test is about the per-attempt deadline alone;
        // the bounded round is covered by the tests below.
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 40, maximumAutomaticRetries: 0)
        defer { scheduler.stop() }
        let attempts = AttemptCounter()
        scheduler.install { _ in
            attempts.record()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        scheduler.noteWorkerBoot("boot-hung")
        let failed = await waitUntil(timeout: 2) {
            if case .failed = scheduler.phase { return true }
            return false
        }
        XCTAssertTrue(failed,
                      "a bind that never returns must not leave phase at recovering: \(scheduler.phase)")
        XCTAssertTrue(scheduler.phase.isFailure)
        XCTAssertEqual(attempts.value, 1, "an exhausted zero retry budget must not re-arm")
    }

    /// The bug this replaces: every `.failed` phase re-ran a 5-attempt loop, so
    /// a permanently failing Worker was retried forever. One event-driven
    /// attempt plus the configured retries is the whole budget; failures caused
    /// by those retries must not reset it.
    func testContinuousFailureIsBoundedToOneAutomaticRetryRound() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 200, maximumAutomaticRetries: 3,
            retryDelayMilliseconds: 10)
        defer { scheduler.stop() }
        let attempts = AttemptCounter()
        scheduler.install { _ in
            attempts.record()
            throw RecoveryFailure()
        }

        scheduler.noteWorkerBoot("boot-failing")
        let failed = await waitUntil(timeout: 2) {
            if case .failed = scheduler.phase { return true }
            return false
        }
        XCTAssertTrue(failed, "phase=\(scheduler.phase) attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 4, "one event-driven bind + three automatic retries")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(attempts.value, 4,
                       "a failed automatic retry must not open a fresh round")
    }

    /// The page's 重试 button is an event: after the previous round is
    /// exhausted it must be able to open another bounded round.
    func testVisibleRetryStartsANewRoundAfterThePreviousOneWasExhausted() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 200, maximumAutomaticRetries: 2,
            retryDelayMilliseconds: 10)
        defer { scheduler.stop() }
        let attempts = AttemptCounter()
        scheduler.install { _ in
            attempts.record()
            throw RecoveryFailure()
        }

        scheduler.noteWorkerBoot("boot-failing")
        let firstRound = await waitUntil(timeout: 2) {
            if case .failed = scheduler.phase { return true }
            return false
        }
        XCTAssertTrue(firstRound, "phase=\(scheduler.phase) attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 3)

        scheduler.forceRetry()
        let secondRound = await waitUntil(timeout: 2) {
            attempts.value == 6 && scheduler.phase.isFailure
        }
        XCTAssertTrue(secondRound,
                      "the visible retry must open a new round; phase=\(scheduler.phase) "
                          + "attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 6)
    }

    /// A replacement Worker boot is an event too: after an exhausted round the
    /// next HELLO must be able to recover instead of inheriting the old budget.
    func testANewWorkerBootStartsANewRoundAfterThePreviousOneWasExhausted() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 200, maximumAutomaticRetries: 1,
            retryDelayMilliseconds: 10)
        defer { scheduler.stop() }
        let attempts = AttemptCounter()
        scheduler.install { _ in
            attempts.record()
            throw RecoveryFailure()
        }

        scheduler.noteWorkerBoot("boot-one")
        let firstRound = await waitUntil(timeout: 2) {
            if case .failed = scheduler.phase { return true }
            return false
        }
        XCTAssertTrue(firstRound, "phase=\(scheduler.phase) attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 2, "one bind + one automatic retry")

        scheduler.noteWorkerBoot("boot-two")
        let secondRound = await waitUntil(timeout: 2) {
            attempts.value == 4 && scheduler.phase.isFailure
        }
        XCTAssertTrue(secondRound,
                      "a new Worker boot must open a new round; phase=\(scheduler.phase) "
                          + "attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 4, "the new event restarts the same bounded budget")
    }

    func testASuccessfulAutomaticRetryEndsTheRound() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 200, maximumAutomaticRetries: 3,
            retryDelayMilliseconds: 10)
        defer { scheduler.stop() }
        let attempts = AttemptCounter()
        scheduler.install { _ in
            attempts.record()
            if attempts.value == 1 { throw RecoveryFailure() }
        }

        scheduler.noteWorkerBoot("boot-retried")
        let ready = await waitUntil(timeout: 2) { scheduler.phase == .ready }
        XCTAssertTrue(ready, "phase=\(scheduler.phase) attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 2)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(attempts.value, 2, "a successful retry must cancel the rest of the round")
        XCTAssertEqual(scheduler.recoveredBootID, "boot-retried")
    }

    /// The visible 重试 button must issue a real rebind even while the previous
    /// attempt is still in flight; otherwise it looks enabled but does nothing.
    func testForceRetryStartsANewBindWhileAnotherAttemptIsInFlight() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 5_000)
        defer { scheduler.stop() }
        var attempts: [String?] = []
        var reclaimCalls = 0
        scheduler.install { bootID in
            attempts.append(bootID)
            if attempts.count == 1 {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            reclaimCalls += 1
        }

        scheduler.noteWorkerBoot("boot-one")
        let started = await waitUntil { attempts == ["boot-one"] }
        XCTAssertTrue(started)
        scheduler.forceRetry()
        let ready = await waitUntil(timeout: 2) { scheduler.phase == .ready }
        XCTAssertTrue(ready, "retry must rebind; phase=\(scheduler.phase) attempts=\(attempts)")
        XCTAssertEqual(attempts, ["boot-one", "boot-one"])
        XCTAssertEqual(reclaimCalls, 1)
    }

    func testADuplicateTerminationEventDoesNotAddASecondRecovery() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        defer { scheduler.stop() }
        var attempts: [String?] = []
        scheduler.install { bootID in attempts.append(bootID) }

        scheduler.noteTermination(count: 1)
        scheduler.noteTermination(count: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(scheduler.phase, .recovering)
        XCTAssertTrue(attempts.isEmpty)
        scheduler.noteWorkerBoot("boot-new")
        let ready = await waitUntil { scheduler.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(attempts, ["boot-new"])
    }

    /// A parked host gets a new WebEngine, so its termination counter restarts
    /// at 1. The next kill after a resume must still enter recovering.
    func testASecondKillWithARestartedEngineCounterIsAccepted() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        defer { scheduler.stop() }
        var attempts: [String?] = []
        scheduler.install { bootID in attempts.append(bootID) }

        scheduler.noteTermination(count: 1)
        scheduler.noteWorkerBoot("boot-one")
        let first = await waitUntil { scheduler.phase == .ready }
        XCTAssertTrue(first)
        scheduler.noteTermination(count: 1)
        XCTAssertEqual(scheduler.phase, .recovering)
        scheduler.noteWorkerBoot("boot-two")
        let second = await waitUntil { scheduler.phase == .ready }
        XCTAssertTrue(second)
        XCTAssertEqual(attempts, ["boot-one", "boot-two"])
    }

    func testANewTerminationAfterRecoveryShowsRecoveringAgain() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        defer { scheduler.stop() }
        var attempts: [String?] = []
        scheduler.install { bootID in attempts.append(bootID) }

        scheduler.noteTermination(count: 1)
        scheduler.noteWorkerBoot("boot-one")
        let first = await waitUntil { scheduler.phase == .ready }
        XCTAssertTrue(first)
        scheduler.noteTermination(count: 2)
        XCTAssertEqual(scheduler.phase, .recovering)
        XCTAssertEqual(attempts, ["boot-one"],
                       "a termination reports recovering but must wait for the next HELLO")
        scheduler.noteWorkerBoot("boot-two")
        let second = await waitUntil { scheduler.phase == .ready }
        XCTAssertTrue(second)
        XCTAssertEqual(attempts, ["boot-one", "boot-two"])
    }

    private func waitUntil(timeout: TimeInterval = 1,
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private extension BotWorkerRecoveryScheduler.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct RecoveryFailure: Error {}

/// Mutable counters live on the main actor with the scheduler; a local `var`
/// captured by two escaping `@MainActor` closures is rejected by Swift 6.
@MainActor
private final class AttemptCounter {
    private(set) var value = 0

    func record() { value += 1 }
}
