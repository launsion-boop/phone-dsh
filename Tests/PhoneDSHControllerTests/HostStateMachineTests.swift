// SPDX-License-Identifier: MIT
// PhoneDSHController: D14 host state machine tests.

import Foundation
import XCTest
@testable import PhoneDSHController
import PhoneDSHWire

private struct InjectedFailure: Error, Sendable {}

/// Counts lease-check invocations from the injected closure.
private final class LeaseCheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var count: Int { lock.withLock { stored } }

    func increment() {
        lock.withLock { stored += 1 }
    }
}

final class HostStateMachineTests: XCTestCase {
    private func persistedState(_ root: URL) throws -> String? {
        let json = try ControllerTestSupport.readJSON(
            root.appendingPathComponent("host-state.json"))
        return json["state"] as? String
    }

    // MARK: - Boot mapping

    func testBootWithoutPersistedStateStartsRecoveringAndPersists() async throws {
        let clock = ManualHostClock()
        let machine = try ControllerTestSupport.makeHost(for: self, clock: clock)
        let state = await machine.state
        XCTAssertEqual(state, .recovering)
        let disposition = await machine.bootDisposition
        XCTAssertEqual(disposition, .coldStart)
        let bootReason = await machine.bootReason
        XCTAssertEqual(bootReason, HostStateMachine.coldStartReason)
        XCTAssertEqual(machine.admission.current, .closed)
        let json = try ControllerTestSupport.readJSON(
            machine.root.appendingPathComponent("host-state.json"))
        XCTAssertEqual(json["state"] as? String, "recovering")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["boot_disposition"] as? String, "cold_start")
        XCTAssertEqual(json["boot_reason"] as? String, "empty_workspace")
    }

    func testNoHostStateButWorkspaceHistoryIsCrashRecovery() async throws {
        let root = ControllerTestSupport.root(for: self)
        let machine = try ControllerTestSupport.makeHost(for: self, root: root,
                                                         clock: ManualHostClock(),
                                                         workspaceHasState: true)
        let state = await machine.state
        XCTAssertEqual(state, .recovering, "the D14 mapping is unchanged")
        let disposition = await machine.bootDisposition
        XCTAssertEqual(disposition, .crashRecovery)
        let reason = await machine.bootReason
        XCTAssertEqual(reason, "workspace_without_host_state")
        let json = try ControllerTestSupport.readJSON(
            root.appendingPathComponent("host-state.json"))
        XCTAssertEqual(json["boot_disposition"] as? String, "crash_recovery")
    }

    func testBootMapsPersistedRunningToRecovering() async throws {
        let root = ControllerTestSupport.root(for: self)
        let first = try ControllerTestSupport.makeHost(for: self, root: root,
                                                       clock: ManualHostClock())
        _ = try await first.verifyLease()
        let firstState = await first.state
        XCTAssertEqual(firstState, .running)
        await first.shutdown()

        let second = try ControllerTestSupport.makeHost(for: self, root: root,
                                                        clock: ManualHostClock())
        let secondState = await second.state
        XCTAssertEqual(secondState, .recovering)
        XCTAssertEqual(second.admission.current, .closed)
        let disposition = await second.bootDisposition
        XCTAssertEqual(disposition, .crashRecovery)
        let reason = await second.bootReason
        XCTAssertEqual(reason, "persisted_running")
        let json = try ControllerTestSupport.readJSON(
            root.appendingPathComponent("host-state.json"))
        XCTAssertEqual(json["boot_disposition"] as? String, "crash_recovery")
        XCTAssertEqual(json["boot_reason"] as? String, "persisted_running")
    }

    func testBootMapsPersistedDrainingToRecovering() async throws {
        let root = ControllerTestSupport.root(for: self)
        let first = try ControllerTestSupport.makeHost(for: self, root: root,
                                                       clock: ManualHostClock())
        _ = try await first.verifyLease()
        _ = try await first.handle(.scenePhase(.background))
        let draining = await first.state
        XCTAssertEqual(draining, .draining)
        await first.shutdown()

        let second = try ControllerTestSupport.makeHost(for: self, root: root,
                                                        clock: ManualHostClock())
        let secondState = await second.state
        XCTAssertEqual(secondState, .recovering)
        XCTAssertEqual(second.admission.current, .closed)
    }

    func testBootMapsPersistedRecoveringToRecovering() async throws {
        let root = ControllerTestSupport.root(for: self)
        // Persisted Recovering is an input of the boot mapping in its own
        // right; construct it directly instead of deriving it from a signal.
        let persisted: [String: Any] = [
            "version": 1,
            "state": "recovering",
            "updated_at_ms": 1_700_000_000_000,
        ]
        try ControllerTestSupport.canonicalJSON(persisted).write(
            to: root.appendingPathComponent("host-state.json"), options: .atomic)

        let machine = try ControllerTestSupport.makeHost(for: self, root: root,
                                                         clock: ManualHostClock())
        let state = await machine.state
        XCTAssertEqual(state, .recovering)
        XCTAssertEqual(machine.admission.current, .closed)
        XCTAssertEqual(try persistedState(root), "recovering")
    }

    func testBootKeepsPersistedFailed() async throws {
        let root = ControllerTestSupport.root(for: self)
        let first = try ControllerTestSupport.makeHost(for: self, root: root,
                                                       clock: ManualHostClock())
        _ = try await first.handle(.failure(reason: "wal corrupt"))
        let firstState = await first.state
        XCTAssertEqual(firstState, .failed)
        await first.shutdown()

        let second = try ControllerTestSupport.makeHost(for: self, root: root,
                                                        clock: ManualHostClock())
        let secondState = await second.state
        XCTAssertEqual(secondState, .failed)
        let reason = await second.lastError
        XCTAssertEqual(reason, "wal corrupt")
        XCTAssertEqual(second.admission.current, .closed)
    }

    func testBootKeepsPersistedRemoteClosed() async throws {
        let root = ControllerTestSupport.root(for: self)
        let first = try ControllerTestSupport.makeHost(for: self, root: root,
                                                       clock: ManualHostClock())
        _ = try await first.verifyLease()
        _ = try await first.handle(.handoffRequested)
        _ = try await first.handle(.handoffFenceInstalled)
        _ = try await first.handle(.handoffCompleted(remoteAdmission: .open))
        let remote = await first.state
        XCTAssertEqual(remote, .remote)
        await first.shutdown()

        let second = try ControllerTestSupport.makeHost(for: self, root: root,
                                                        clock: ManualHostClock())
        let secondState = await second.state
        XCTAssertEqual(secondState, .remote)
        XCTAssertEqual(second.admission.current, .closed)
    }

    // MARK: - Draining

    func testRunningToDrainingOnBackgroundClosesAdmission() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        XCTAssertEqual(machine.admission.current, .open)
        let state = try await machine.handle(.scenePhase(.background))
        XCTAssertEqual(state, .draining)
        XCTAssertEqual(machine.admission.current, .closed)
        let deadline = await machine.drainDeadline
        XCTAssertNotNil(deadline)
        let target = await machine.drainTarget
        XCTAssertEqual(target, .parked)
    }

    func testDrainingToParkedOnDrainComplete() async throws {
        let closer = RecordingEpochCloser()
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock(),
                                                         closer: closer)
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        XCTAssertEqual(closer.count, 0,
                       "the epoch closes on leaving Draining, not on entry")
        let state = try await machine.handle(.backgroundDrainCompleted)
        XCTAssertEqual(state, .parked)
        XCTAssertEqual(closer.count, 1)
        XCTAssertFalse(machine.drainCancellation.isCancelled)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testDrainDeadlineCancelsInFlightAndFlushesEpoch() async throws {
        let clock = ManualHostClock()
        let closer = RecordingEpochCloser()
        let machine = try ControllerTestSupport.makeHost(for: self, clock: clock,
                                                         closer: closer)
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        clock.advance(by: 20)
        // Give the injected-clock timer the deadline signal; an explicit
        // deadline signal may race it, so both paths are accepted.
        _ = try? await machine.handle(.drainDeadlineElapsed)
        let state = await ControllerTestSupport.waitForState(machine, .parked)
        XCTAssertEqual(state, .parked)
        XCTAssertTrue(machine.drainCancellation.isCancelled)
        XCTAssertEqual(closer.count, 1)
    }

    func testDrainDeadlineRejectedBeforeClockReachesTheDeadline() async throws {
        let clock = ManualHostClock()
        let machine = try ControllerTestSupport.makeHost(for: self, clock: clock)
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        clock.advance(by: 19.5)
        do {
            _ = try await machine.handle(.drainDeadlineElapsed)
            XCTFail("a deadline signal before 20 s must be rejected")
        } catch {
            XCTAssertEqual(error as? HostStateError, .deadlineNotReached)
            let state = await machine.state
            XCTAssertEqual(state, .draining)
        }
    }

    func testBackgroundTaskExpiryForcesTheDrainDeadline() async throws {
        let closer = RecordingEpochCloser()
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock(),
                                                         closer: closer)
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        let state = try await machine.handle(.backgroundTaskExpired)
        XCTAssertEqual(state, .parked)
        XCTAssertTrue(machine.drainCancellation.isCancelled)
        XCTAssertEqual(closer.count, 1)
    }

    func testDrainingToRecoveringOnPlannedRestart() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        let state = try await machine.handle(.plannedRestart)
        XCTAssertEqual(state, .recovering)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testDrainingToRecoveringOnWebContentTermination() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        let termination = WebContentTermination(wasForeground: false, terminationCount: 1)
        let state = try await machine.handle(.webContentTerminated(termination))
        XCTAssertEqual(state, .recovering)
    }

    // MARK: - Restart / parked / recovering

    func testRunningToRecoveringOnPlannedRestartClosesEpoch() async throws {
        let closer = RecordingEpochCloser()
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock(),
                                                         closer: closer)
        _ = try await machine.verifyLease()
        let state = try await machine.handle(.plannedRestart)
        XCTAssertEqual(state, .recovering)
        XCTAssertEqual(closer.count, 1)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testRunningToRecoveringOnForegroundWebContentTermination() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        let termination = WebContentTermination(wasForeground: true, terminationCount: 2)
        let state = try await machine.handle(.webContentTerminated(termination))
        XCTAssertEqual(state, .recovering)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testBackgroundWebContentTerminationIsRejected() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        let termination = WebContentTermination(wasForeground: false, terminationCount: 3)
        do {
            _ = try await machine.handle(.webContentTerminated(termination))
            XCTFail("a background termination is not a Running -> Recovering edge")
        } catch {
            XCTAssertEqual(error as? HostStateError,
                           .illegalTransition(from: .running,
                                              signal: "webContentTerminated"))
            let state = await machine.state
            XCTAssertEqual(state, .running)
        }
    }

    func testParkedToRecoveringOnActive() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        _ = try await machine.handle(.backgroundDrainCompleted)
        let parked = await machine.state
        XCTAssertEqual(parked, .parked)
        let state = try await machine.handle(.scenePhase(.active))
        XCTAssertEqual(state, .recovering)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testParkedBootTransitionCarriesBootReason() async throws {
        let root = ControllerTestSupport.root(for: self)
        let first = try ControllerTestSupport.makeHost(for: self, root: root,
                                                       clock: ManualHostClock())
        _ = try await first.verifyLease()
        _ = try await first.handle(.scenePhase(.background))
        _ = try await first.handle(.backgroundDrainCompleted)
        await first.shutdown()

        let second = try ControllerTestSupport.makeHost(for: self, root: root,
                                                        clock: ManualHostClock())
        let disposition = await second.bootDisposition
        XCTAssertEqual(disposition, .parkedResume)
        let stream = second.transitions()
        let collector = Task { await collect(1, from: stream) }
        let state = try await second.handle(.scenePhase(.active))
        XCTAssertEqual(state, .recovering)
        let records = await collector.value ?? []
        XCTAssertEqual(records.first?.reason, "parked_resume")
        XCTAssertEqual(records.first?.signal, "scenePhase(active)")
    }

    func testInProcessParkResumeKeepsColdStartDisposition() async throws {
        let root = ControllerTestSupport.root(for: self)
        let machine = try ControllerTestSupport.makeHost(for: self, root: root,
                                                         clock: ManualHostClock())
        let initial = await machine.bootDisposition
        XCTAssertEqual(initial, .coldStart)
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        _ = try await machine.handle(.backgroundDrainCompleted)
        let parked = await machine.state
        XCTAssertEqual(parked, .parked)

        let state = try await machine.handle(.scenePhase(.active))
        XCTAssertEqual(state, .recovering)
        // A late subscriber receives the most recent accepted transition.
        let records = await collect(1, from: machine.transitions()) ?? []
        XCTAssertEqual(records.last?.reason, "parked_resume")

        // Park/resume inside the process is not a new boot: the original
        // cold-start disposition must survive both in memory and on disk.
        let disposition = await machine.bootDisposition
        XCTAssertEqual(disposition, .coldStart)
        let reason = await machine.bootReason
        XCTAssertEqual(reason, HostStateMachine.coldStartReason)
        let json = try ControllerTestSupport.readJSON(
            root.appendingPathComponent("host-state.json"))
        XCTAssertEqual(json["boot_disposition"] as? String, "cold_start")
        XCTAssertEqual(json["boot_reason"] as? String, "empty_workspace")
    }

    func testInProcessParkResumeKeepsCrashRecoveryDisposition() async throws {
        let root = ControllerTestSupport.root(for: self)
        let first = try ControllerTestSupport.makeHost(for: self, root: root,
                                                       clock: ManualHostClock())
        _ = try await first.verifyLease()
        await first.shutdown()

        let second = try ControllerTestSupport.makeHost(for: self, root: root,
                                                        clock: ManualHostClock())
        let recovered = await second.bootDisposition
        XCTAssertEqual(recovered, .crashRecovery)
        _ = try await second.verifyLease()
        _ = try await second.handle(.scenePhase(.background))
        _ = try await second.handle(.backgroundDrainCompleted)
        let parked = await second.state
        XCTAssertEqual(parked, .parked)

        let state = try await second.handle(.scenePhase(.active))
        XCTAssertEqual(state, .recovering)
        // A late subscriber receives the most recent accepted transition.
        let records = await collect(1, from: second.transitions()) ?? []
        XCTAssertEqual(records.last?.reason, "parked_resume")

        let disposition = await second.bootDisposition
        XCTAssertEqual(disposition, .crashRecovery)
        let reason = await second.bootReason
        XCTAssertEqual(reason, "persisted_running")
        let json = try ControllerTestSupport.readJSON(
            root.appendingPathComponent("host-state.json"))
        XCTAssertEqual(json["boot_disposition"] as? String, "crash_recovery")
        XCTAssertEqual(json["boot_reason"] as? String, "persisted_running")
    }

    func testUserResetTransitionCarriesBootReason() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.handle(.failure(reason: "quota"))
        _ = try await machine.handle(.userReset)
        // A late subscriber receives the most recent accepted transition.
        let records = await collect(1, from: machine.transitions()) ?? []
        XCTAssertEqual(records.last?.reason, "user_reset")
        XCTAssertEqual(records.last?.signal, "userReset")
        let disposition = await machine.bootDisposition
        XCTAssertEqual(disposition, .userReset)
        let reason = await machine.bootReason
        XCTAssertEqual(reason, "explicit_user_reset")
    }

    func testRecoveringToRunningOnlyViaVerifyLease() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        XCTAssertEqual(machine.admission.current, .closed)
        let state = try await machine.verifyLease()
        XCTAssertEqual(state, .running)
        XCTAssertEqual(machine.admission.current, .open)
    }

    func testVerifyLeaseRejectedOutsideRecovering() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        do {
            _ = try await machine.verifyLease()
            XCTFail("verifyLease only exists on the Recovering -> Running edge")
        } catch {
            XCTAssertEqual(error as? HostStateError,
                           .illegalTransition(from: .running, signal: "verifyLease"))
        }
    }

    // MARK: - Backoff

    func testRunningToBackoffOnUnsatisfiedNetworkPath() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        let state = try await machine.handle(.networkPath(.unsatisfied))
        XCTAssertEqual(state, .backoff)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testRunningToBackoffOn429() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        let state = try await machine.handle(.upstreamUnavailable(status: 429))
        XCTAssertEqual(state, .backoff)
    }

    func testRunningToBackoffOn5xx() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        let state = try await machine.handle(.upstreamUnavailable(status: 503))
        XCTAssertEqual(state, .backoff)
    }

    func testNonRetryableUpstreamStatusIsRejected() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        do {
            _ = try await machine.handle(.upstreamUnavailable(status: 400))
            XCTFail("only 429/5xx drives Running -> Backoff")
        } catch {
            let state = await machine.state
            XCTAssertEqual(state, .running)
        }
    }

    func testBackoffToRunningRequiresSatisfiedPathAndSuccessfulProbe() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.networkPath(.unsatisfied))
        do {
            _ = try await machine.handle(.retryProbeSucceeded)
            XCTFail("a probe without a satisfied path must not reopen admission")
        } catch {
            guard case .guardFailed = error as? HostStateError else {
                return XCTFail("expected guardFailed, got \(error)")
            }
        }
        XCTAssertEqual(machine.admission.current, .closed)

        _ = try await machine.handle(.networkPath(.satisfied))
        let stillBackoff = await machine.state
        XCTAssertEqual(stillBackoff, .backoff,
                       "path satisfied alone does not end Backoff")
        let state = try await machine.handle(.retryProbeSucceeded)
        XCTAssertEqual(state, .running)
        XCTAssertEqual(machine.admission.current, .open)
    }

    func testBackoffToRunningRunsTheLeaseCheckBeforeOpeningAdmission() async throws {
        let counter = LeaseCheckCounter()
        let machine = try ControllerTestSupport.makeHost(
            for: self, clock: ManualHostClock(),
            leaseVerifier: {
                counter.increment()
                return true
            })
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.upstreamUnavailable(status: 429))
        _ = try await machine.handle(.networkPath(.satisfied))
        XCTAssertEqual(counter.count, 0, "the lease is checked at the edge, not on entry")

        let state = try await machine.handle(.retryProbeSucceeded)
        XCTAssertEqual(state, .running)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(machine.admission.current, .open)
    }

    func testFailedLeaseCheckKeepsBackoffClosed() async throws {
        let machine = try ControllerTestSupport.makeHost(
            for: self, clock: ManualHostClock(), leaseVerifier: { false })
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.upstreamUnavailable(status: 503))
        _ = try await machine.handle(.networkPath(.satisfied))
        do {
            _ = try await machine.handle(.retryProbeSucceeded)
            XCTFail("a failed lease check must not reopen admission")
        } catch {
            guard case .guardFailed(let signal, let reason) = error as? HostStateError else {
                return XCTFail("expected guardFailed, got \(error)")
            }
            XCTAssertEqual(signal, "retryProbeSucceeded")
            XCTAssertTrue(reason.contains("lease check failed"))
        }
        let state = await machine.state
        XCTAssertEqual(state, .backoff)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testStaleFenceLeaseCheckKeepsBackoffClosed() async throws {
        let root = ControllerTestSupport.root(for: self)
        let authority = try FenceAuthority(root: root, owner: "phone",
                                           generation: 1, walSeq: 4)
        let stale = Fence(owner: "phone", generation: 0, walSeq: 4)
        let verifier = await authority.backoffLeaseVerifier(presented: { stale })
        let machine = try ControllerTestSupport.makeHost(
            for: self, root: root, clock: ManualHostClock(),
            leaseVerifier: verifier)
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.networkPath(.unsatisfied))
        _ = try await machine.handle(.networkPath(.satisfied))
        do {
            _ = try await machine.handle(.retryProbeSucceeded)
            XCTFail("the stale fence must fail FenceAuthority.validate()")
        } catch {
            guard case .guardFailed = error as? HostStateError else {
                return XCTFail("expected guardFailed, got \(error)")
            }
        }
        let state = await machine.state
        XCTAssertEqual(state, .backoff)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testPersistedBackoffResumesOnlyAfterItsRetryDeadline() async throws {
        let root = ControllerTestSupport.root(for: self)
        let clock = ManualHostClock()
        let first = try ControllerTestSupport.makeHost(for: self, root: root, clock: clock)
        _ = try await first.verifyLease()
        _ = try await first.handle(.upstreamUnavailable(status: 429))
        let recordedDeadline = await first.backoffDeadline()
        let deadline = try XCTUnwrap(recordedDeadline)
        XCTAssertEqual(
            deadline.timeIntervalSince1970,
            clock.now.addingTimeInterval(HostStateMachine.defaultBackoffIntervalSeconds)
                .timeIntervalSince1970,
            accuracy: 0.001)
        let json = try ControllerTestSupport.readJSON(
            root.appendingPathComponent("host-state.json"))
        XCTAssertNotNil(json["backoff_until_ms"])
        await first.shutdown()

        let earlyClock = ManualHostClock(now: deadline.addingTimeInterval(-1))
        let early = try ControllerTestSupport.makeHost(for: self, root: root,
                                                       clock: earlyClock)
        do {
            _ = try await early.resumeFromPersistedBackoff()
            XCTFail("D24: Backoff must not be resumed before its deadline")
        } catch let error as HostStateError {
            guard case .backoffDeadlineNotReached(let reported) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reported.timeIntervalSince1970,
                           deadline.timeIntervalSince1970, accuracy: 0.001)
        }
        let stillBackoff = await early.state
        XCTAssertEqual(stillBackoff, .backoff)
        XCTAssertEqual(early.admission.current, .closed)
        await early.shutdown()

        let lateClock = ManualHostClock(now: deadline.addingTimeInterval(1))
        let late = try ControllerTestSupport.makeHost(for: self, root: root,
                                                      clock: lateClock)
        let state = try await late.resumeFromPersistedBackoff()
        XCTAssertEqual(state, .recovering)
        XCTAssertEqual(late.admission.current, .closed,
                       "the lease is verified only after the Worker boots")
        do {
            _ = try await late.resumeFromPersistedBackoff()
            XCTFail("the boot-side Backoff bridge only exists once")
        } catch let error as HostStateError {
            guard case .illegalTransition = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - Handoff / reclaim

    func testRunningToHandingOffClosesAdmissionAndEpoch() async throws {
        let closer = RecordingEpochCloser()
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock(),
                                                         closer: closer)
        _ = try await machine.verifyLease()
        let state = try await machine.handle(.handoffRequested)
        XCTAssertEqual(state, .handingOff)
        XCTAssertEqual(closer.count, 1)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testDrainingToHandingOff() async throws {
        let closer = RecordingEpochCloser()
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock(),
                                                         closer: closer)
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        XCTAssertEqual(closer.count, 0)
        let state = try await machine.handle(.handoffRequested)
        XCTAssertEqual(state, .handingOff)
        XCTAssertEqual(closer.count, 1)
    }

    func testHandingOffToRemoteRequiresOpenRemoteAdmission() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.handoffRequested)
        do {
            _ = try await machine.handle(.handoffCompleted(remoteAdmission: .closed))
            XCTFail("the remote must open admission before HandingOff -> Remote")
        } catch {
            let state = await machine.state
            XCTAssertEqual(state, .handingOff)
        }
        let state = try await machine.handle(.handoffCompleted(remoteAdmission: .open))
        XCTAssertEqual(state, .remote)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testHandoffFailureBeforeFenceIsRejected() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.handoffRequested)
        do {
            _ = try await machine.handle(.handoffFailed)
            XCTFail("without a fence there is no reclaim path")
        } catch {
            let state = await machine.state
            XCTAssertEqual(state, .handingOff)
        }
    }

    func testHandoffFailureAfterFenceEntersReclaiming() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.handoffRequested)
        _ = try await machine.handle(.handoffFenceInstalled)
        let state = try await machine.handle(.handoffFailed)
        XCTAssertEqual(state, .reclaiming)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testRemoteToReclaimingOnRequest() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.handoffRequested)
        _ = try await machine.handle(.handoffFenceInstalled)
        _ = try await machine.handle(.handoffCompleted(remoteAdmission: .open))
        let state = try await machine.handle(.reclaimRequested)
        XCTAssertEqual(state, .reclaiming)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    func testReclaimingToRecoveringRequiresAppliedFenceAndEpoch() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.handoffRequested)
        _ = try await machine.handle(.handoffFenceInstalled)
        _ = try await machine.handle(.handoffCompleted(remoteAdmission: .open))
        _ = try await machine.handle(.reclaimRequested)

        do {
            _ = try await machine.handle(.reclaimCompleted(fencePersisted: true,
                                                           epochClosed: true))
            XCTFail("the reclaim response must be applied first")
        } catch {
            guard case .guardFailed = error as? HostStateError else {
                return XCTFail("expected guardFailed, got \(error)")
            }
        }
        _ = try await machine.handle(.reclaimResponseApplied)
        do {
            _ = try await machine.handle(.reclaimCompleted(fencePersisted: false,
                                                           epochClosed: true))
            XCTFail("the new fence must be persisted")
        } catch {
            let state = await machine.state
            XCTAssertEqual(state, .reclaiming)
        }
        let state = try await machine.handle(.reclaimCompleted(fencePersisted: true,
                                                               epochClosed: true))
        XCTAssertEqual(state, .recovering)
        XCTAssertEqual(machine.admission.current, .closed)
    }

    // MARK: - Failed

    func testAnyStateToFailedKeepsAdmissionClosedAndPersistsReason() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.verifyLease()
        XCTAssertEqual(machine.admission.current, .open)
        let state = try await machine.handle(.failure(reason: "materialization I/O failure"))
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(machine.admission.current, .closed)
        let reason = await machine.lastError
        XCTAssertEqual(reason, "materialization I/O failure")
        let json = try ControllerTestSupport.readJSON(
            machine.root.appendingPathComponent("host-state.json"))
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["reason"] as? String, "materialization I/O failure")
    }

    func testFailedToRecoveringOnlyByExplicitUserReset() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        _ = try await machine.handle(.failure(reason: "quota"))
        do {
            _ = try await machine.verifyLease()
            XCTFail("Failed never opens admission through verifyLease")
        } catch {
            let state = await machine.state
            XCTAssertEqual(state, .failed)
        }
        let state = try await machine.handle(.userReset)
        XCTAssertEqual(state, .recovering)
        XCTAssertEqual(machine.admission.current, .closed)
        let reason = await machine.lastError
        XCTAssertNil(reason)
    }

    // MARK: - Illegal edges

    func testIllegalTransitionsAreRejected() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        do {
            _ = try await machine.handle(.backgroundDrainCompleted)
            XCTFail("Draining -> Parked does not exist from Recovering")
        } catch {}
        _ = try await machine.verifyLease()
        do {
            _ = try await machine.handle(.backgroundDrainCompleted)
            XCTFail("Draining -> Parked does not exist from Running")
        } catch {}
        do {
            _ = try await machine.handle(.retryProbeSucceeded)
            XCTFail("Retry probe only exists from Backoff")
        } catch {}
        do {
            _ = try await machine.handle(.reclaimRequested)
            XCTFail("Reclaim only exists from Remote")
        } catch {
            let state = await machine.state
            XCTAssertEqual(state, .running)
        }
        do {
            _ = try await machine.handle(.scenePhase(.inactive))
            XCTFail("inactive is not a D14 driving signal")
        } catch {}
    }

    // MARK: - Observability and persistence

    func testTransitionsStreamPublishesEachAcceptedEdge() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        let stream = machine.transitions()
        let collector = Task { await collect(4, from: stream) }
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        _ = try await machine.handle(.backgroundDrainCompleted)
        _ = try await machine.handle(.scenePhase(.active))
        let records = await collector.value ?? []
        XCTAssertEqual(records.map(\.to), [.running, .draining, .parked, .recovering])
        XCTAssertEqual(records.first?.signal, "verifyLease")
        XCTAssertEqual(records.map(\.admission), [.open, .closed, .closed, .closed])
    }

    func testHostStateIsPersistedAtomicallyAfterEveryTransition() async throws {
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock())
        let root = machine.root

        _ = try await machine.verifyLease()
        XCTAssertEqual(try persistedState(root), "running")

        _ = try await machine.handle(.scenePhase(.background))
        XCTAssertEqual(try persistedState(root), "draining")

        _ = try await machine.handle(.backgroundDrainCompleted)
        XCTAssertEqual(try persistedState(root), "parked")

        _ = try await machine.handle(.scenePhase(.active))
        XCTAssertEqual(try persistedState(root), "recovering")

        _ = try await machine.verifyLease()
        XCTAssertEqual(try persistedState(root), "running")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("host-state.json.tmp").path))
    }

    func testEpochCloseFailureFailsLoud() async throws {
        let closer = RecordingEpochCloser()
        closer.fail(with: InjectedFailure())
        let machine = try ControllerTestSupport.makeHost(for: self, clock: ManualHostClock(),
                                                         closer: closer)
        _ = try await machine.verifyLease()
        do {
            _ = try await machine.handle(.plannedRestart)
            XCTFail("an epoch close failure is fail loud")
        } catch {
            guard case .epochCloseFailed = error as? HostStateError else {
                return XCTFail("expected epochCloseFailed, got \(error)")
            }
            let state = await machine.state
            XCTAssertEqual(state, .failed)
            XCTAssertEqual(machine.admission.current, .closed)
        }
    }

    func testDrainTimerFiresFromInjectedClock() async throws {
        let clock = ManualHostClock()
        let closer = RecordingEpochCloser()
        let machine = try ControllerTestSupport.makeHost(for: self, clock: clock,
                                                         closer: closer)
        let stream = machine.transitions()
        let collector = Task { await collect(3, from: stream) }
        _ = try await machine.verifyLease()
        _ = try await machine.handle(.scenePhase(.background))
        clock.advance(by: 20)
        let records = await collector.value ?? []
        XCTAssertEqual(records.last?.to, .parked)
        XCTAssertEqual(closer.count, 1)
        XCTAssertTrue(machine.drainCancellation.isCancelled)
    }
}
