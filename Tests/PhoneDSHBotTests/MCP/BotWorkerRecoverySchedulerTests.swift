// SPDX-License-Identifier: MIT
// Regression for the App-side Worker recovery scheduling (d-heal).
//
// The host emits `.webContentTerminated` before the replacement Worker boots.
// Binding at that point opens a transport into a channel that does not exist
// yet; the old composition could then drop the later HELLO of the new boot and
// leave the Bot page at "正在重新同步…" forever. These tests drive the
// scheduler's real actor state machine with a fake bind (the composition's
// bind is the only production caller) and assert the final boot is claimed
// once. Every scheduler command and snapshot read is awaited; the fake bind and
// the phase consumer are `Sendable`, exactly like the production callbacks.

import XCTest
@testable import PhoneDSHBot

@MainActor
final class BotWorkerRecoverySchedulerTests: XCTestCase {
    func testNewBootDuringAnInFlightRecoveryIsRecoveredAfterTheFirstAttempt() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        // Production's recovery closure is `bind`, which calls
        // `BotRuntimeUnit.start` -> `remote.reclaimOwnedSessions()`.
        let reclaims = AttemptCounter()
        await scheduler.install { bootID in
            attempts.record(bootID)
            if bootID == "boot-one" {
                // Simulate the old composition's bind: it opened a transport
                // before the replacement Worker answered HELLO and waited.
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            reclaims.record()
        }

        await scheduler.noteWorkerBoot("boot-one")
        await scheduler.noteWorkerReady()
        let started = await waitUntil { attempts.values == ["boot-one"] }
        XCTAssertTrue(started, "the first boot must start one bind; attempts=\(attempts.values)")
        await scheduler.noteWorkerBoot("boot-two")
        await scheduler.noteWorkerReady()

        let ready = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            let recovered = await scheduler.recoveredBootID
            return phase == .ready && recovered == "boot-two"
        }
        let finalPhase = await scheduler.phase
        XCTAssertTrue(ready,
                      "a newer Worker boot must be rebound after the first attempt ends; "
                          + "phase=\(finalPhase) attempts=\(attempts.values)")
        XCTAssertEqual(attempts.values, ["boot-one", "boot-two"])
        XCTAssertEqual(reclaims.value, 1, "the latest boot is claimed exactly once")
    }

    func testTerminationAloneDoesNotBindBeforeAReplacementBootIsKnown() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.noteTermination(count: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let recoveringPhase = await scheduler.phase
        XCTAssertEqual(recoveringPhase, .recovering)
        XCTAssertTrue(attempts.values.isEmpty,
                      "the old Worker is dead and no replacement has HELLOed yet; "
                          + "opening a transport here is what stalled the d scenario: "
                          + "\(attempts.values)")

        await scheduler.noteWorkerBoot("boot-new")
        await scheduler.noteWorkerReady()
        let ready = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(attempts.values, ["boot-new"])
    }

    /// The real termination path (`bootReplacementWorker` / the
    /// `bootWorker` fallback for an engine without the restart lever) reuses
    /// the host's engine configuration, so the replacement Worker can present
    /// the *same* boot id as the one already bound. The ordered-channel HELLO
    /// that follows a termination is nevertheless a new Worker connection and
    /// must rebind; comparing only `bootID` would leave the page at
    /// recovering forever, which is the d-heal regression.
    func testSameBootIDReplacementHelloAfterTerminationRebinds() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 500)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        // The initial composition bind attached this Worker and seeded its id.
        await scheduler.seed(recoveredBootID: "boot-same")
        await scheduler.noteWorkerBoot("boot-same", helloCount: 1, fenceGeneration: 7)
        await scheduler.noteWorkerReady()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(attempts.values.isEmpty,
                      "the HELLO of the already-seeded Worker must not rebind: \(attempts.values)")

        await scheduler.noteTermination(count: 1)
        let recoveringPhase = await scheduler.phase
        XCTAssertEqual(recoveringPhase, .recovering)
        // Replacement Worker, same process id, next host-monotonic HELLO. The
        // fence generation is unchanged because a WebContent kill does not
        // advance the host's WAL authority.
        await scheduler.noteWorkerBoot("boot-same", helloCount: 2, fenceGeneration: 7)
        await scheduler.noteWorkerReady()
        let ready = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        let phase = await scheduler.phase
        XCTAssertTrue(ready,
                      "a HELLO after a termination must rebind even when the boot id "
                          + "is unchanged; phase=\(phase) attempts=\(attempts.values)")
        XCTAssertEqual(attempts.values, ["boot-same"],
                       "the replacement connection is claimed exactly once")
        let recovered = await scheduler.recoveredBootID
        XCTAssertEqual(recovered, "boot-same")
    }

    /// A channel reconnect of the already-bound Worker increments the host
    /// HELLO count but is not a new Worker. It must not start a redundant
    /// bind.
    func testSameWorkerChannelReconnectAfterRecoveryDoesNotRebind() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 500)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.noteWorkerBoot("boot-one", helloCount: 1, fenceGeneration: 2)
        await scheduler.noteWorkerReady()
        let ready = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(attempts.values, ["boot-one"])

        await scheduler.noteWorkerBoot("boot-one", helloCount: 2, fenceGeneration: 2)
        await scheduler.noteWorkerReady()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(attempts.values, ["boot-one"],
                       "a same-Worker channel reconnect must not trigger a second bind")
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .ready)
    }

    /// `.restarted` is page boot-ready, not a bind point. It normally carries
    /// the same boot id the following HELLO uses, but an engine (or a Worker
    /// bundle that does not forward the page boot id) can report an id that is
    /// not the Worker's. A late page report must not undo a completed bind and
    /// leave the page at recovering with no further HELLO to consume.
    func testALatePageReadyDoesNotUndoACompletedRecovery() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 500)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.noteWorkerBoot("boot-worker", helloCount: 1, fenceGeneration: 2)
        await scheduler.noteWorkerReady()
        let ready = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(attempts.values, ["boot-worker"])

        await scheduler.noteBootCandidate("page-boot-id")
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .ready,
                       "a late page boot-ready must not move a bound page back to recovering")
        let latestBoot = await scheduler.latestBootID
        XCTAssertEqual(latestBoot, "boot-worker",
                       "the page boot id is not a Worker bind target")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(attempts.values, ["boot-worker"])
    }

    func testRestartCandidateShowsRecoveringButWaitsForHello() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.noteBootCandidate("boot-page")
        let recoveringPhase = await scheduler.phase
        XCTAssertEqual(recoveringPhase, .recovering)
        XCTAssertTrue(attempts.values.isEmpty,
                      "page boot-ready is not yet a channel; the HELLO owns the bind")
        await scheduler.noteWorkerBoot("boot-page")
        await scheduler.noteWorkerReady()
        let ready = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(attempts.values, ["boot-page"])
    }

    func testAHungBindTimesOutIntoAFailedState() async throws {
        // Retry budget 0: this test is about the per-attempt deadline alone;
        // the bounded round is covered by the tests below.
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 40, maximumAutomaticRetries: 0)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptCounter()
        await scheduler.install { _ in
            attempts.record()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        await scheduler.noteWorkerBoot("boot-hung")
        await scheduler.noteWorkerReady()
        let failed = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            if case .failed = phase { return true }
            return false
        }
        let phase = await scheduler.phase
        XCTAssertTrue(failed,
                      "a bind that never returns must not leave phase at recovering: \(phase)")
        XCTAssertTrue(phase.isFailure)
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
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptCounter()
        await scheduler.install { _ in
            attempts.record()
            throw RecoveryFailure()
        }

        await scheduler.noteWorkerBoot("boot-failing")
        await scheduler.noteWorkerReady()
        let failed = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            if case .failed = phase { return true }
            return false
        }
        let phase = await scheduler.phase
        XCTAssertTrue(failed, "phase=\(phase) attempts=\(attempts.value)")
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
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptCounter()
        await scheduler.install { _ in
            attempts.record()
            throw RecoveryFailure()
        }

        await scheduler.noteWorkerBoot("boot-failing")
        await scheduler.noteWorkerReady()
        let firstRound = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            if case .failed = phase { return true }
            return false
        }
        let phase = await scheduler.phase
        XCTAssertTrue(firstRound, "phase=\(phase) attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 3)

        await scheduler.forceRetry()
        let secondRound = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            return attempts.value == 6 && phase.isFailure
        }
        let finalPhase = await scheduler.phase
        XCTAssertTrue(secondRound,
                      "the visible retry must open a new round; phase=\(finalPhase) "
                          + "attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 6)
    }

    /// A replacement Worker boot is an event too: after an exhausted round the
    /// next HELLO must be able to recover instead of inheriting the old budget.
    func testANewWorkerBootStartsANewRoundAfterThePreviousOneWasExhausted() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 200, maximumAutomaticRetries: 1,
            retryDelayMilliseconds: 10)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptCounter()
        await scheduler.install { _ in
            attempts.record()
            throw RecoveryFailure()
        }

        await scheduler.noteWorkerBoot("boot-one")
        await scheduler.noteWorkerReady()
        let firstRound = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            if case .failed = phase { return true }
            return false
        }
        let phase = await scheduler.phase
        XCTAssertTrue(firstRound, "phase=\(phase) attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 2, "one bind + one automatic retry")

        await scheduler.noteWorkerBoot("boot-two")
        await scheduler.noteWorkerReady()
        let secondRound = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            return attempts.value == 4 && phase.isFailure
        }
        let finalPhase = await scheduler.phase
        XCTAssertTrue(secondRound,
                      "a new Worker boot must open a new round; phase=\(finalPhase) "
                          + "attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 4, "the new event restarts the same bounded budget")
    }

    func testASuccessfulAutomaticRetryEndsTheRound() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 200, maximumAutomaticRetries: 3,
            retryDelayMilliseconds: 10)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptCounter()
        await scheduler.install { _ in
            attempts.record()
            if attempts.value == 1 { throw RecoveryFailure() }
        }

        await scheduler.noteWorkerBoot("boot-retried")
        await scheduler.noteWorkerReady()
        let ready = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            return phase == .ready
        }
        let phase = await scheduler.phase
        XCTAssertTrue(ready, "phase=\(phase) attempts=\(attempts.value)")
        XCTAssertEqual(attempts.value, 2)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(attempts.value, 2, "a successful retry must cancel the rest of the round")
        let recovered = await scheduler.recoveredBootID
        XCTAssertEqual(recovered, "boot-retried")
    }

    /// The visible 重试 button must issue a real rebind even while the previous
    /// attempt is still in flight; otherwise it looks enabled but does nothing.
    func testForceRetryStartsANewBindWhileAnotherAttemptIsInFlight() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 5_000)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        let reclaims = AttemptCounter()
        await scheduler.install { bootID in
            attempts.record(bootID)
            if attempts.values.count == 1 {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            reclaims.record()
        }

        await scheduler.noteWorkerBoot("boot-one")
        await scheduler.noteWorkerReady()
        let started = await waitUntil { attempts.values == ["boot-one"] }
        XCTAssertTrue(started)
        await scheduler.forceRetry()
        let ready = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            return phase == .ready
        }
        let phase = await scheduler.phase
        XCTAssertTrue(ready, "retry must rebind; phase=\(phase) attempts=\(attempts.values)")
        XCTAssertEqual(attempts.values, ["boot-one", "boot-one"])
        XCTAssertEqual(reclaims.value, 1)
    }

    func testADuplicateTerminationEventDoesNotAddASecondRecovery() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.noteTermination(count: 1)
        await scheduler.noteTermination(count: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .recovering)
        XCTAssertTrue(attempts.values.isEmpty)
        await scheduler.noteWorkerBoot("boot-new")
        await scheduler.noteWorkerReady()
        let ready = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(attempts.values, ["boot-new"])
    }

    /// A parked host gets a new WebEngine, so its termination counter restarts
    /// at 1. The next kill after a resume must still enter recovering.
    func testASecondKillWithARestartedEngineCounterIsAccepted() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.noteTermination(count: 1)
        await scheduler.noteWorkerBoot("boot-one")
        await scheduler.noteWorkerReady()
        let first = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        XCTAssertTrue(first)
        await scheduler.noteTermination(count: 1)
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .recovering)
        await scheduler.noteWorkerBoot("boot-two")
        await scheduler.noteWorkerReady()
        let second = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        XCTAssertTrue(second)
        XCTAssertEqual(attempts.values, ["boot-one", "boot-two"])
    }

    /// A deliberate manual park/start (the S6 memory eraser) suppresses the
    /// automatic `.workerHello` rebind. The page still sees `.restarted` /
    /// HELLO boot candidates during that window, so the scheduler enters
    /// recovering. Once the manual path reattaches the replacement Worker, its
    /// recorded boot must publish `.ready` — otherwise the banner stays until
    /// the user taps 重试 even though the new session already started.
    func testManualRebindAfterSuppressedParkStartReturnsToReady() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 500)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.seed(recoveredBootID: "boot-old")
        // `.restarted` and the suppressed HELLO both arrive as page candidates.
        await scheduler.noteBootCandidate("boot-new")
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .recovering)

        await scheduler.beginManualRebind()
        await scheduler.completeManualRebind(recoveredBootID: "boot-new")
        let readyPhase = await scheduler.phase
        XCTAssertEqual(readyPhase, .ready)
        let recovered = await scheduler.recoveredBootID
        XCTAssertEqual(recovered, "boot-new")
        let awaiting = await scheduler.isAwaitingWorkerReady
        XCTAssertFalse(awaiting)
        XCTAssertTrue(attempts.values.isEmpty,
                      "the manual path owns the reattach; no automatic bind may run: "
                          + "\(attempts.values)")
    }

    /// The ready gate armed by a replacement HELLO must be released when the
    /// caller takes over the park/start. Otherwise the fallback timer or a
    /// later ready line starts a second, racing bind.
    func testManualRebindReleasesAnArmedReadyGate() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 500)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.seed(recoveredBootID: "boot-old")
        await scheduler.noteTermination(count: 1)
        await scheduler.noteWorkerBoot("boot-new", helloCount: 1)
        let awaiting = await scheduler.isAwaitingWorkerReady
        XCTAssertTrue(awaiting)

        await scheduler.beginManualRebind()
        let released = await scheduler.isAwaitingWorkerReady
        XCTAssertFalse(released)
        await scheduler.completeManualRebind(recoveredBootID: "boot-new")
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .ready)
        XCTAssertTrue(attempts.values.isEmpty,
                      "the released gate must not bind after the manual path: \(attempts.values)")
    }

    func testFailedManualRebindPublishesARetryableFailure() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 500)
        addTeardownBlock { await scheduler.stop() }
        await scheduler.seed(recoveredBootID: "boot-old")
        await scheduler.beginManualRebind()
        await scheduler.failManualRebind("Bot 连接没有恢复，请重试。")
        let phase = await scheduler.phase
        XCTAssertTrue(phase.isFailure)
        if case let .failed(message) = phase {
            XCTAssertEqual(message, "Bot 连接没有恢复，请重试。")
        }
        let awaiting = await scheduler.isAwaitingWorkerReady
        XCTAssertFalse(awaiting)
    }

    func testANewTerminationAfterRecoveryShowsRecoveringAgain() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.noteTermination(count: 1)
        await scheduler.noteWorkerBoot("boot-one")
        await scheduler.noteWorkerReady()
        let first = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        XCTAssertTrue(first)
        await scheduler.noteTermination(count: 2)
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .recovering)
        XCTAssertEqual(attempts.values, ["boot-one"],
                       "a termination reports recovering but must wait for the next HELLO")
        await scheduler.noteWorkerBoot("boot-two")
        await scheduler.noteWorkerReady()
        let second = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        XCTAssertTrue(second)
        XCTAssertEqual(attempts.values, ["boot-one", "boot-two"])
    }

    /// The replacement Worker sends HELLO when its socket opens, then spends
    /// most of its boot before the ordered-channel API bridge exists. A bind
    /// issued on the raw HELLO sends its first `session/page` into that
    /// dropped-request window; the request never answers and the 20 s attempt
    /// deadline expires. The bind must wait for the Worker `ready` phase.
    func testAReplacementHelloWaitsForWorkerReadyBeforeBinding() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 500)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.noteTermination(count: 1)
        await scheduler.noteWorkerBoot("boot-replacement", helloCount: 1)
        try await Task.sleep(nanoseconds: 80_000_000)
        let phase = await scheduler.phase
        let awaiting = await scheduler.isAwaitingWorkerReady
        XCTAssertEqual(phase, .recovering)
        XCTAssertTrue(awaiting)
        XCTAssertTrue(attempts.values.isEmpty,
                      "HELLO announces the Worker identity, not its API bridge: "
                          + "\(attempts.values)")

        await scheduler.noteWorkerReady()
        let ready = await waitUntil {
            let phase = await scheduler.phase
            return phase == .ready
        }
        let finalPhase = await scheduler.phase
        let stillAwaiting = await scheduler.isAwaitingWorkerReady
        XCTAssertTrue(ready,
                      "the ready phase must release the armed bind; "
                          + "phase=\(finalPhase) attempts=\(attempts.values)")
        XCTAssertEqual(attempts.values, ["boot-replacement"])
        XCTAssertFalse(stillAwaiting)
    }

    /// A Worker bundle that does not forward the reserved boot phase still has
    /// to recover; the ready gate is a head start, not a new permanent stall.
    func testReadyFallbackBindsAWorkerThatNeverAnnouncesReady() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 500, readyFallbackMilliseconds: 120)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.noteTermination(count: 1)
        await scheduler.noteWorkerBoot("boot-silent", helloCount: 1)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(attempts.values.isEmpty)
        let ready = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            return phase == .ready
        }
        let phase = await scheduler.phase
        XCTAssertTrue(ready,
                      "the bounded ready fallback must still bind; "
                          + "phase=\(phase) attempts=\(attempts.values)")
        XCTAssertEqual(attempts.values, ["boot-silent"])
    }

    // MARK: - Phase ordering and generation races

    /// Phase notifications are one ordered, non-dropping stream: transitions
    /// published before the application starts its consumer are retained, in
    /// scheduler order, and `stop()` publishes its idle transition on the same
    /// stream.
    func testPhaseStreamRetainsEveryTransitionInOrderBeforeAConsumerStarts() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        addTeardownBlock { await scheduler.stop() }
        await scheduler.beginManualRebind()
        await scheduler.failManualRebind("first")
        await scheduler.beginManualRebind()
        await scheduler.failManualRebind("second")

        var iterator = scheduler.phases.makeAsyncIterator()
        let first = (await iterator.next())?.phase
        let second = (await iterator.next())?.phase
        let third = (await iterator.next())?.phase
        let fourth = (await iterator.next())?.phase
        XCTAssertEqual(first, .recovering)
        XCTAssertEqual(second, .failed("first"))
        XCTAssertEqual(third, .recovering)
        XCTAssertEqual(fourth, .failed("second"))

        await scheduler.stop()
        let fifth = (await iterator.next())?.phase
        XCTAssertEqual(fifth, .idle,
                       "stop publishes its transition on the same non-dropping stream")
    }

    /// The application starts its single consumer before host events. Every
    /// transition must arrive on that consumer in scheduler order.
    func testPhaseConsumerStartedBeforeEventsObservesEveryPhaseInOrder() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        addTeardownBlock { await scheduler.stop() }
        let observed = PhaseLog()
        let consumer = Task { [phases = scheduler.phases] in
            for await event in phases {
                observed.record(event.phase)
            }
        }
        addTeardownBlock { consumer.cancel() }

        await scheduler.beginManualRebind()
        await scheduler.failManualRebind("first")
        await scheduler.beginManualRebind()
        await scheduler.completeManualRebind(recoveredBootID: "boot-manual")
        await scheduler.stop()

        let seen = await waitUntil(timeout: 2) { observed.values.count == 5 }
        XCTAssertTrue(seen, "consumer saw \(observed.values)")
        XCTAssertEqual(observed.values,
                       [.recovering, .failed("first"), .recovering, .ready, .idle])
    }

    /// `stop()` resets the generation and finishes the in-flight attempt. A
    /// transport that ignores cancellation and completes later must not
    /// publish `.ready` or claim its boot over the reset state.
    func testStopFencesALateCompletionFromOverwritingTheResetState() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 5_000)
        addTeardownBlock { await scheduler.stop() }
        let gate = RecoveryGate()
        let attempts = AttemptLog()
        await scheduler.install { bootID in
            attempts.record(bootID)
            await gate.wait()
        }

        await scheduler.noteWorkerBoot("boot-one")
        await scheduler.noteWorkerReady()
        let started = await waitUntil { attempts.values == ["boot-one"] }
        XCTAssertTrue(started)

        await scheduler.stop()
        let stoppedPhase = await scheduler.phase
        let stoppedBoot = await scheduler.recoveredBootID
        XCTAssertEqual(stoppedPhase, .idle)
        XCTAssertNil(stoppedBoot)

        // The non-cooperative recovery ignores the cancellation and succeeds.
        gate.open()
        try await Task.sleep(nanoseconds: 150_000_000)
        let phase = await scheduler.phase
        let recovered = await scheduler.recoveredBootID
        XCTAssertEqual(phase, .idle,
                       "a stale completion must not publish ready after stop")
        XCTAssertNil(recovered, "a stale completion must not claim a Worker boot")
    }

    /// `stop()` must disarm a ready gate and its fallback deadline. The gate is
    /// a pending bind, so leaving it armed would let a detached composition
    /// bind a Worker after the stop already finished.
    func testStopDisarmsTheReadyGateBeforeItsFallbackCanBind() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 500, readyFallbackMilliseconds: 60)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptLog()
        await scheduler.install { bootID in attempts.record(bootID) }

        await scheduler.noteTermination(count: 1)
        await scheduler.noteWorkerBoot("boot-silent", helloCount: 1)
        let armed = await scheduler.isAwaitingWorkerReady
        XCTAssertTrue(armed)

        await scheduler.stop()
        let released = await scheduler.isAwaitingWorkerReady
        XCTAssertFalse(released)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(attempts.values.isEmpty,
                      "the stopped scheduler must not bind from the old ready gate: "
                          + "\(attempts.values)")
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .idle)
    }

    /// `stop()` cancels the pending automatic-retry delay too: a round that was
    /// already scheduled must not fire an attempt after the stop finished.
    func testStopCancelsAPendingAutomaticRetry() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 200, maximumAutomaticRetries: 3,
            retryDelayMilliseconds: 150)
        addTeardownBlock { await scheduler.stop() }
        let attempts = AttemptCounter()
        await scheduler.install { _ in
            attempts.record()
            throw RecoveryFailure()
        }

        await scheduler.noteWorkerBoot("boot-failing")
        await scheduler.noteWorkerReady()
        let firstAttempt = await waitUntil { attempts.value == 1 }
        XCTAssertTrue(firstAttempt)
        await scheduler.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(attempts.value, 1,
                       "a retry delay scheduled before stop must be cancelled")
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .idle)
    }

    /// A new event after `stop()` gets a clean generation. The abandoned
    /// non-cooperative attempt from before the stop must not overwrite the new
    /// boot's successful rebind when it finally completes.
    func testANewRebindAfterStopIsNotOverwrittenByTheAbandonedAttempt() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 5_000)
        addTeardownBlock { await scheduler.stop() }
        let gate = RecoveryGate()
        let attempts = AttemptLog()
        await scheduler.install { bootID in
            attempts.record(bootID)
            if bootID == "boot-one" {
                await gate.wait()
            }
        }

        await scheduler.noteWorkerBoot("boot-one")
        await scheduler.noteWorkerReady()
        let started = await waitUntil { attempts.values == ["boot-one"] }
        XCTAssertTrue(started)
        await scheduler.stop()

        await scheduler.noteWorkerBoot("boot-two")
        await scheduler.noteWorkerReady()
        let ready = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            let recovered = await scheduler.recoveredBootID
            return phase == .ready && recovered == "boot-two"
        }
        XCTAssertTrue(ready, "attempts=\(attempts.values)")
        XCTAssertEqual(attempts.values, ["boot-one", "boot-two"])

        gate.open()
        try await Task.sleep(nanoseconds: 150_000_000)
        let phase = await scheduler.phase
        let recovered = await scheduler.recoveredBootID
        XCTAssertEqual(phase, .ready)
        XCTAssertEqual(recovered, "boot-two",
                       "the abandoned attempt must not overwrite the new generation")
    }

    /// The predecessor of this test found that a superseded attempt could
    /// still install its result continuation after the newer attempt had
    /// installed its own: the stale attempt then owned the stream that `stop()`
    /// or `beginManualRebind()` finished, so the live bind was never released.
    ///
    /// The hook holds attempt A after its task starts but before `runAttempt`
    /// may install anything. Attempt B supersedes it with a new generation.
    /// When A resumes it must not start its recovery work or overwrite B's
    /// continuation.
    func testASupersededAttemptCannotInstallItsContinuationOverTheLiveAttempt() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 5_000)
        addTeardownBlock {
            await scheduler.setAttemptEntryHook(nil)
            await scheduler.stop()
        }
        let attempts = AttemptLog()
        let workGate = RecoveryGate()
        let entryGate = NonCooperativeSuspension()
        let entries = AttemptCounter()
        await scheduler.setAttemptEntryHook {
            if entries.record() == 1 { await entryGate.wait() }
        }
        await scheduler.install { bootID in
            attempts.record(bootID)
            await workGate.wait()
        }

        await scheduler.noteWorkerBoot("boot-one")
        await scheduler.noteWorkerReady()
        let firstEntry = await waitUntil { entries.value == 1 }
        XCTAssertTrue(firstEntry, "attempt A must reach the entry hook")

        // Supersede A before it reaches the continuation install. B starts and
        // owns the attempt now.
        await scheduler.forceRetry()
        let secondEntry = await waitUntil { entries.value == 2 }
        XCTAssertTrue(secondEntry, "the retry must start a second attempt")
        let liveAttempts = await waitUntil { attempts.values == ["boot-one"] }
        XCTAssertTrue(liveAttempts, "attempts=\(attempts.values)")

        // Release A. The generation check must reject it before it can start
        // `recovery` or install its continuation.
        entryGate.open()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(attempts.values, ["boot-one"],
                       "a superseded attempt must not start a second recovery work item: "
                           + "\(attempts.values)")

        // If A had overwritten the live continuation, this stop could not
        // release B: B's stream would only finish at the attempt timeout. The
        // live attempt was waiting on `workGate`, so observe the fence by
        // checking that the scheduler accepts the next event immediately and
        // that B is cancelled rather than kept alive.
        await scheduler.stop()
        workGate.open()
        let idle = await waitUntil(timeout: 2) {
            (await scheduler.isRecovering) == false
        }
        XCTAssertTrue(idle)
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .idle)
    }

    /// `failManualRebind` publishes the visible failure that offers 重试. An
    /// automatic attempt started during the manual window (the composition's
    /// transport-failure/visible-retry entries were not fenced by the manual
    /// flag) must be invalidated by that failure: its late success must not
    /// publish ready over the visible failure.
    func testFailedManualRebindFencesAnAttemptStartedDuringTheManualWindow() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 5_000, maximumAutomaticRetries: 3,
            retryDelayMilliseconds: 10)
        addTeardownBlock { await scheduler.stop() }
        let gate = RecoveryGate()
        let attempts = AttemptLog()
        await scheduler.install { bootID in
            attempts.record(bootID)
            await gate.wait()
        }

        await scheduler.seed(recoveredBootID: "boot-old")
        await scheduler.beginManualRebind()
        // The composition's transport-failure path (and its retry guard while
        // state == .recovering) can start an attempt in this window.
        await scheduler.forceRetry()
        let started = await waitUntil { attempts.values == ["boot-old"] }
        XCTAssertTrue(started, "the manual-window attempt must start; attempts=\(attempts.values)")

        await scheduler.failManualRebind("Bot 连接没有恢复，请重试。")
        // The non-cooperative closure ignores cancellation and succeeds late.
        gate.open()
        try await Task.sleep(nanoseconds: 200_000_000)
        let phase = await scheduler.phase
        let recovered = await scheduler.recoveredBootID
        XCTAssertEqual(phase, .failed("Bot 连接没有恢复，请重试。"),
                       "a late success must not overwrite the visible manual failure")
        XCTAssertEqual(recovered, "boot-old",
                       "the late success must not claim the replacement boot")
    }
    // MARK: - Phase epoch fences

    /// A queued phase from the binding that `stop()` replaced carries an older
    /// lifecycle epoch. The composition compares the notification epoch with
    /// the scheduler's current one, so a `.failed` read after the stop cannot
    /// make a stopped composition report a failure.
    func testStopAdvanceThePhaseFenceSoQueuedOlderPhasesAreStale() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 80)
        addTeardownBlock { await scheduler.stop() }
        await scheduler.noteTermination(count: 1)
        let recoveringEpoch = await scheduler.phaseEpoch
        await scheduler.stop()
        let currentEpoch = await scheduler.phaseEpoch

        var iterator = scheduler.phases.makeAsyncIterator()
        let recovering = await iterator.next()
        let idle = await iterator.next()
        XCTAssertEqual(recovering?.phase, .recovering)
        XCTAssertEqual(idle?.phase, .idle)
        XCTAssertLessThan(recovering?.epoch ?? .max, currentEpoch,
                          "the queued recovering phase belongs to the stopped binding")
        XCTAssertEqual(idle?.epoch, currentEpoch)
    }

    /// Every fence republishes the current phase at its new epoch, even when
    /// the phase value is unchanged. A consumer that rejects stale epochs must
    /// still observe the state that is current — otherwise a retry during a
    /// recovering bind would drop the only recovering notification and leave
    /// the page on the previous (failed) state.
    func testFencedRoundStartRepublishesTheCurrentPhaseAtTheNewEpoch() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 5_000)
        addTeardownBlock { await scheduler.stop() }
        let gate = RecoveryGate()
        await scheduler.install { _ in await gate.wait() }

        await scheduler.beginManualRebind()
        let manualEpoch = await scheduler.phaseEpoch
        await scheduler.forceRetry()
        let currentEpoch = await scheduler.phaseEpoch
        XCTAssertGreaterThan(currentEpoch, manualEpoch)

        var iterator = scheduler.phases.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first?.phase, .recovering)
        XCTAssertEqual(first?.epoch, manualEpoch)
        XCTAssertEqual(second?.phase, .recovering,
                       "the unrepeated recovering value is still current at the new epoch")
        XCTAssertEqual(second?.epoch, currentEpoch)

        gate.open()
        let ready = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            return phase == .ready
        }
        XCTAssertTrue(ready)
    }

    /// A Worker boot that arrives after an exhausted round starts a new bind.
    /// Its recovering phase must be published at a newer epoch so a queued
    /// `.failed` from the old round is rejected instead of parking the page on
    /// the failure while the new boot is binding.
    func testANewWorkerBootAfterAnExhaustedRoundFencesTheFailedPhase() async throws {
        let scheduler = BotWorkerRecoveryScheduler(
            timeoutMilliseconds: 200, maximumAutomaticRetries: 0)
        addTeardownBlock { await scheduler.stop() }
        await scheduler.install { _ in throw RecoveryFailure() }

        await scheduler.noteWorkerBoot("boot-one")
        await scheduler.noteWorkerReady()
        let failed = await waitUntil(timeout: 2) {
            let phase = await scheduler.phase
            if case .failed = phase { return true }
            return false
        }
        XCTAssertTrue(failed)
        let failedEpoch = await scheduler.phaseEpoch

        await scheduler.noteWorkerBoot("boot-two")
        let currentEpoch = await scheduler.phaseEpoch
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .recovering)
        XCTAssertGreaterThan(currentEpoch, failedEpoch,
                             "the replacement boot must fence the old round's failure")

        var iterator = scheduler.phases.makeAsyncIterator()
        var seenFailureOlderThanCurrent = false
        var foundCurrentRecovering = false
        for _ in 0..<8 {
            guard let event = await iterator.next() else { break }
            if case .failed = event.phase, event.epoch < currentEpoch {
                seenFailureOlderThanCurrent = true
            }
            if event.phase == .recovering, event.epoch == currentEpoch {
                foundCurrentRecovering = true
            }
            if foundCurrentRecovering { break }
        }
        XCTAssertTrue(seenFailureOlderThanCurrent,
                      "the exhausted round must have published a fenced failure")
        XCTAssertTrue(foundCurrentRecovering,
                      "the current recovering phase must survive the epoch comparison")
    }

    /// A page boot report is not a bind event. After a failed manual rebind it
    /// must not move the page back to recovering with no attempt or timer
    /// armed; the visible 重试/HELLO owns the next bind.
    func testALatePageBootCandidateDoesNotReviveAFailedManualRebind() async throws {
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 500)
        addTeardownBlock { await scheduler.stop() }
        await scheduler.seed(recoveredBootID: "boot-old")
        await scheduler.beginManualRebind()
        await scheduler.failManualRebind("Bot 连接没有恢复，请重试。")
        await scheduler.noteBootCandidate("late-page-boot")
        let phase = await scheduler.phase
        XCTAssertEqual(phase, .failed("Bot 连接没有恢复，请重试。"),
                       "a late page report cannot revive a terminal manual failure")
        let awaiting = await scheduler.isAwaitingWorkerReady
        XCTAssertFalse(awaiting)
    }

    private func waitUntil(timeout: TimeInterval = 1,
                           _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private extension BotWorkerRecoveryScheduler.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct RecoveryFailure: Error, Sendable {}

/// Lock-protected attempt log shared by the `Sendable` recovery closure and the
/// main-actor test body. The closure no longer runs on the main actor, so the
/// old `@MainActor var` capture is not valid.
private final class AttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    var values: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ bootID: String?) {
        lock.lock()
        storage.append(bootID)
        lock.unlock()
    }
}

/// Lock-protected attempt counter, also usable inside the `Sendable` recovery
/// closure from an arbitrary executor.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func record() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }
}

/// A one-shot recovery suspension point. `open()` finishes the wait; the
/// scheduler has no way to cancel it, which models a transport that ignores
/// cancellation and completes late.
private final class RecoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<Void>
    private var continuation: AsyncStream<Void>.Continuation?

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func wait() async {
        for await _ in stream { return }
    }

    func open() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.yield(())
        continuation?.finish()
    }
}

/// A one-shot recovery suspension point that ignores task cancellation.
///
/// `RecoveryGate` is built on `AsyncStream`, whose iterator ends when the
/// awaiting task is cancelled. That is the right model for the scheduler's
/// cancellable timer, but the stale-attempt test must keep a *cancelled* task
/// suspended exactly like a transport that is already inside a syscall. A
/// checked continuation resumed only by the test does that.
private final class NonCooperativeSuspension: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

/// Ordered phase sink for the stream consumer; lock-protected for the same
/// reason as the attempt helpers.
private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BotWorkerRecoveryScheduler.Phase] = []

    var values: [BotWorkerRecoveryScheduler.Phase] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ phase: BotWorkerRecoveryScheduler.Phase) {
        lock.lock()
        storage.append(phase)
        lock.unlock()
    }
}
