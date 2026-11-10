// SPDX-License-Identifier: MIT

@testable import ProbeKit
import XCTest

@MainActor
final class ProbeScenePhaseForwardingTests: XCTestCase {
    func testDeliverInvokesChatAndMatrixOnce() async {
        let log = PhaseLog()
        await ProbeScenePhaseForwarding.deliver(
            "background",
            chat: { phase in log.add("chat:\(phase)") },
            backgroundMatrix: { phase in log.add("matrix:\(phase)") })
        XCTAssertEqual(log.snapshot.filter { $0.hasPrefix("chat:") }, ["chat:background"])
        XCTAssertEqual(log.snapshot.filter { $0.hasPrefix("matrix:") }, ["matrix:background"])
    }

    func testDeliverForwardsEachPhase() async {
        let log = PhaseLog()
        for phase in ["inactive", "background", "active"] {
            await ProbeScenePhaseForwarding.deliver(
                phase,
                chat: { log.add($0) },
                backgroundMatrix: { _ in })
        }
        XCTAssertEqual(log.snapshot, ["inactive", "background", "active"])
    }

    /// A repeated identical phase while the first delivery is still running
    /// (the lock/unlock notification storm) is dropped, not queued.
    func testDeliverDropsARepeatOfThePhaseInFlight() async {
        let log = PhaseLog()
        let gate = Gate()
        let first = Task { @MainActor in
            await ProbeScenePhaseForwarding.deliver(
                "background",
                chat: { phase in await gate.wait(); log.add("chat:\(phase)") },
                backgroundMatrix: { log.add("matrix:\($0)") })
        }
        await gate.started()
        await ProbeScenePhaseForwarding.deliver(
            "background",
            chat: { log.add("chat:again:\($0)") },
            backgroundMatrix: { log.add("matrix:again:\($0)") })
        await gate.open()
        await first.value
        XCTAssertEqual(log.snapshot.filter { $0.hasPrefix("chat:") }, ["chat:background"])
        XCTAssertEqual(log.snapshot.filter { $0.hasPrefix("matrix:") }, ["matrix:background"])
    }

    /// A newer phase that arrives during a long park must not start a second
    /// delivery of its own. Two parks overlapping is what the un-serialized
    /// onChange + Task per phase produced, and the second one re-parked a host
    /// the first had just resumed.
    func testDeliverNeverRunsTwoChatDeliveriesAtOnce() async {
        let log = PhaseLog()
        let inFlight = Counter()
        let peak = Counter()
        let gate = Gate()
        func chat(_ phase: String) async {
            let live = inFlight.incrementAndGet()
            peak.raise(to: live)
            if phase == "background" { await gate.wait() }
            log.add("chat:\(phase)")
            inFlight.decrement()
        }
        let parked = Task { @MainActor in
            await ProbeScenePhaseForwarding.deliver(
                "background", chat: chat, backgroundMatrix: { _ in })
        }
        await gate.started()
        let resumed = Task { @MainActor in
            await ProbeScenePhaseForwarding.deliver(
                "active", chat: chat, backgroundMatrix: { _ in })
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(peak.value, 1, "a second chat delivery started while a park was in flight")
        await gate.open()
        await parked.value
        await resumed.value
        XCTAssertEqual(peak.value, 1)
        XCTAssertEqual(log.snapshot, ["chat:background", "chat:active"])
    }
}

@MainActor
final class PhoneAudioSessionLeaseTests: XCTestCase {
    func testMicrophoneThenKeepAliveKeepsMixableProfileUntilZeroOwners() throws {
        let backend = LeaseBackend()
        let state = backend.state()
        let reclaims = Counter()

        let token = try state.acquireMicrophoneUser()
        XCTAssertEqual(backend.microphone.value, 1)
        state.beginKeepAlive {
            XCTAssertFalse(state.hasMicrophoneOwner)
            reclaims.increment()
        }
        try state.activateKeepAliveSession()
        XCTAssertEqual(backend.playback.value, 0, "playback was forced while the microphone was held")
        XCTAssertEqual(backend.activation.value, 1)

        state.releaseMicrophoneUser(token)
        XCTAssertEqual(backend.playback.value, 0, "releasing the microphone forced playback while the keep-alive remained")
        XCTAssertEqual(reclaims.value, 1)
        XCTAssertEqual(backend.deactivation.value, 0)
        XCTAssertFalse(state.hasMicrophoneOwner)
        XCTAssertTrue(state.isMicrophoneProfileSticky)

        state.endKeepAlive()
        XCTAssertEqual(backend.deactivation.value, 1)
        XCTAssertFalse(state.isKeepAliveHeld)
        XCTAssertFalse(state.isMicrophoneProfileSticky)
    }

    func testKeepAliveThenMicrophoneDefersTeardownUntilLastOwnerGone() throws {
        let backend = LeaseBackend()
        let state = backend.state()
        let reclaims = Counter()

        state.beginKeepAlive {
            XCTAssertTrue(state.hasMicrophoneOwner)
            reclaims.increment()
        }
        try state.activateKeepAliveSession()
        XCTAssertEqual(backend.playback.value, 1)
        XCTAssertEqual(backend.microphone.value, 0)

        let token = try state.acquireMicrophoneUser()
        XCTAssertEqual(reclaims.value, 1, "the committed microphone profile did not recover rendering")
        state.endKeepAlive()
        XCTAssertEqual(backend.deactivation.value, 0)
        XCTAssertFalse(state.isKeepAliveHeld)

        state.releaseMicrophoneUser(token)
        XCTAssertEqual(backend.playback.value, 1, "the last release configured playback instead of deactivating")
        XCTAssertEqual(reclaims.value, 1)
        XCTAssertEqual(backend.deactivation.value, 1)
        XCTAssertFalse(state.hasMicrophoneOwner)
        XCTAssertFalse(state.isMicrophoneProfileSticky)
    }

    func testKeepAliveStopLeavesAnActiveMicrophoneSessionAlone() throws {
        let backend = LeaseBackend()
        let state = backend.state()
        let reclaims = Counter()

        let token = try state.acquireMicrophoneUser()
        state.beginKeepAlive { reclaims.increment() }
        try state.activateKeepAliveSession()
        state.endKeepAlive()
        XCTAssertEqual(backend.deactivation.value, 0)
        XCTAssertEqual(backend.playback.value, 0)
        XCTAssertTrue(state.hasMicrophoneOwner)

        state.releaseMicrophoneUser(token)
        XCTAssertEqual(backend.deactivation.value, 1)
    }

    func testIdleReleaseWithoutAnAcquiredTokenDoesNotDeactivate() {
        let backend = LeaseBackend()
        let state = backend.state()

        state.releaseMicrophoneUser(PhoneAudioSessionLease.MicrophoneToken())
        XCTAssertEqual(backend.deactivation.value, 0)
        XCTAssertEqual(backend.playback.value, 0)
        XCTAssertFalse(state.hasMicrophoneOwner)
    }

    func testRepeatedAndStaleMicrophoneReleasesAreIgnored() throws {
        let backend = LeaseBackend()
        let state = backend.state()

        let first = try state.acquireMicrophoneUser()
        state.releaseMicrophoneUser(first)
        XCTAssertEqual(backend.deactivation.value, 1)

        state.releaseMicrophoneUser(first)
        XCTAssertEqual(backend.deactivation.value, 1)

        let second = try state.acquireMicrophoneUser()
        state.releaseMicrophoneUser(first)
        XCTAssertEqual(backend.deactivation.value, 1)
        XCTAssertTrue(state.hasMicrophoneOwner)

        state.releaseMicrophoneUser(second)
        XCTAssertEqual(backend.deactivation.value, 2)
        XCTAssertFalse(state.hasMicrophoneOwner)
    }

    /// A re-acquisition while the retained mixable playAndRecord profile is
    /// active must commit a new token without re-running the category setter,
    /// and only the current token may tear the session down.
    func testReacquisitionOfRetainedProfileSkipsConfigureAndKeepsNewOwner() throws {
        let backend = LeaseBackend()
        let state = backend.state()
        let reclaims = Counter()

        state.beginKeepAlive { reclaims.increment() }
        let first = try state.acquireMicrophoneUser()
        XCTAssertEqual(backend.microphone.value, 1)
        state.releaseMicrophoneUser(first)
        XCTAssertEqual(backend.deactivation.value, 0)
        XCTAssertTrue(state.isMicrophoneProfileSticky)

        let second = try state.acquireMicrophoneUser()
        XCTAssertEqual(backend.microphone.value, 1, "re-acquisition reconfigured the retained microphone profile")
        XCTAssertEqual(backend.deactivation.value, 0)
        XCTAssertEqual(reclaims.value, 3)
        XCTAssertTrue(state.hasMicrophoneOwner)

        state.releaseMicrophoneUser(first)
        XCTAssertTrue(state.hasMicrophoneOwner, "a stale release closed the current microphone owner")
        XCTAssertEqual(backend.deactivation.value, 0)

        state.endKeepAlive()
        XCTAssertTrue(state.hasMicrophoneOwner)
        XCTAssertEqual(backend.deactivation.value, 0)
        XCTAssertTrue(state.isMicrophoneProfileSticky)

        state.releaseMicrophoneUser(second)
        XCTAssertFalse(state.hasMicrophoneOwner)
        XCTAssertEqual(backend.deactivation.value, 1)
        XCTAssertFalse(state.isMicrophoneProfileSticky)

        let third = try state.acquireMicrophoneUser()
        XCTAssertEqual(backend.microphone.value, 2, "a fresh acquisition after zero owners did not reconfigure")
        state.releaseMicrophoneUser(third)
        XCTAssertEqual(backend.deactivation.value, 2)
    }

    func testSecondMicrophoneAcquisitionFailsBeforeTouchingTheSession() throws {
        let backend = LeaseBackend()
        let state = backend.state()

        let token = try state.acquireMicrophoneUser()
        XCTAssertEqual(backend.microphone.value, 1)
        XCTAssertThrowsError(try state.acquireMicrophoneUser()) { error in
            guard case let PhoneToolError.unavailable(capability, _) = error,
                  capability == .microphone else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(backend.microphone.value, 1)
        XCTAssertEqual(backend.deactivation.value, 0)
        XCTAssertTrue(state.hasMicrophoneOwner)

        state.releaseMicrophoneUser(token)
        XCTAssertEqual(backend.deactivation.value, 1)
    }

    func testFailedMicrophoneActivationKeepsTheKeepAliveOwner() throws {
        struct ActivationFailure: Error {}
        let backend = LeaseBackend()
        backend.microphoneError = ActivationFailure()
        let state = backend.state()
        let reclaims = Counter()

        state.beginKeepAlive { reclaims.increment() }
        try state.activateKeepAliveSession()
        XCTAssertEqual(backend.playback.value, 1)

        XCTAssertThrowsError(try state.acquireMicrophoneUser())
        XCTAssertFalse(state.hasMicrophoneOwner)
        XCTAssertTrue(state.isKeepAliveHeld)
        XCTAssertEqual(backend.playback.value, 2)
        XCTAssertEqual(reclaims.value, 1)
        XCTAssertEqual(backend.deactivation.value, 0)

        state.endKeepAlive()
        XCTAssertEqual(backend.deactivation.value, 1)
    }

    /// The mixable playAndRecord profile outlives the microphone token while the
    /// keep-alive remains, and only zero owners clear it. Releasing the mic and
    /// re-asserting the session must never fall back to playback; a fresh
    /// keep-alive after zero owners must arm playback again.
    func testStickyProfileSurvivesMicrophoneReleaseAndResetsAtZeroOwners() throws {
        let backend = LeaseBackend()
        let state = backend.state()
        let reclaims = Counter()

        let token = try state.acquireMicrophoneUser()
        XCTAssertEqual(backend.microphone.value, 1)
        state.beginKeepAlive { reclaims.increment() }

        state.releaseMicrophoneUser(token)
        XCTAssertEqual(backend.playback.value, 0, "releasing the microphone forced playback")
        XCTAssertEqual(backend.deactivation.value, 0)
        XCTAssertEqual(reclaims.value, 1)
        XCTAssertTrue(state.isMicrophoneProfileSticky)

        try state.activateKeepAliveSession()
        XCTAssertEqual(backend.playback.value, 0, "re-asserting a sticky keep-alive forced playback")
        XCTAssertEqual(backend.microphone.value, 2, "re-asserting did not reuse the sticky microphone profile")

        state.endKeepAlive()
        XCTAssertEqual(backend.deactivation.value, 1)
        XCTAssertFalse(state.isMicrophoneProfileSticky)

        state.beginKeepAlive { reclaims.increment() }
        try state.activateKeepAliveSession()
        XCTAssertEqual(backend.playback.value, 1, "a fresh keep-alive after zero owners did not arm playback")
        XCTAssertEqual(reclaims.value, 1)
        state.endKeepAlive()
        XCTAssertEqual(backend.deactivation.value, 2)
    }
}

@MainActor
final class SpeakerOutputLeaseTests: XCTestCase {
    func testAirPlayOutputIsForcedToTheSpeakerAndRestoredByTheLastOwner() throws {
        let backend = LeaseBackend()
        backend.airPlay = true
        let state = backend.state()
        let reclaims = Counter()
        state.beginKeepAlive { reclaims.increment() }
        try state.activateKeepAliveSession()
        XCTAssertEqual(backend.playback.value, 1)

        let token = try state.acquireSpeakerOutput()
        XCTAssertEqual(backend.microphone.value, 1, "speaker output uses the mixable playAndRecord profile")
        XCTAssertEqual(backend.overrides, [true], "AirPlay output is forced to the built-in speaker")
        XCTAssertTrue(state.isSpeakerOverridden)
        XCTAssertEqual(reclaims.value, 1, "the keep-alive resumes after the profile change")

        state.releaseSpeakerOutput(token)
        XCTAssertEqual(backend.overrides, [true, false])
        XCTAssertEqual(backend.deactivation.value, 0, "the keep-alive still owns the session")
        XCTAssertTrue(state.isMicrophoneProfileSticky, "the profile stays until the last owner leaves")
        state.endKeepAlive()
        XCTAssertEqual(backend.deactivation.value, 1)
        XCTAssertFalse(state.isMicrophoneProfileSticky)
    }

    func testNoOverrideWithoutAirPlayAndStaleReleaseIsIgnored() throws {
        let backend = LeaseBackend()
        let state = backend.state()
        let token = try state.acquireSpeakerOutput()
        XCTAssertEqual(backend.overrides, [], "headphones or the speaker are left as the user chose")
        state.releaseSpeakerOutput(token)
        state.releaseSpeakerOutput(token)
        XCTAssertEqual(backend.deactivation.value, 1, "a repeated release has no effect")
    }

    func testSpeakerAndMicrophoneShareTheProfileWithoutDeactivatingEachOther() throws {
        let backend = LeaseBackend()
        let state = backend.state()
        let speaker = try state.acquireSpeakerOutput()
        let microphone = try state.acquireMicrophoneUser()
        XCTAssertEqual(backend.microphone.value, 1, "the shared profile is not reconfigured")
        state.releaseMicrophoneUser(microphone)
        XCTAssertEqual(backend.deactivation.value, 0, "the speaker owner still holds the session")
        state.releaseSpeakerOutput(speaker)
        XCTAssertEqual(backend.deactivation.value, 1)
    }

    func testFailedSpeakerConfigurationRestoresTheKeepAlive() throws {
        let backend = LeaseBackend()
        backend.microphoneError = PhoneToolError.unavailable(.microphone, "x")
        let state = backend.state()
        let reclaims = Counter()
        state.beginKeepAlive { reclaims.increment() }
        try state.activateKeepAliveSession()
        XCTAssertThrowsError(try state.acquireSpeakerOutput())
        XCTAssertEqual(backend.playback.value, 2, "playback is restored for the keep-alive")
        XCTAssertEqual(reclaims.value, 1)
        XCTAssertFalse(state.hasSpeakerOwner)
    }
}

@MainActor
private final class LeaseBackend {
    let playback = Counter()
    let microphone = Counter()
    let activation = Counter()
    let deactivation = Counter()
    var microphoneError: Error?
    var airPlay = false
    var overrides: [Bool] = []

    func state() -> PhoneAudioSessionLease.State {
        PhoneAudioSessionLease.State(
            configurePlayback: { self.playback.increment() },
            configureMicrophone: {
                if let error = self.microphoneError { throw error }
                self.microphone.increment()
            },
            activate: { self.activation.increment() },
            deactivate: { self.deactivation.increment() },
            outputIsAirPlay: { self.airPlay },
            overrideToSpeaker: { self.overrides.append($0) })
    }
}

private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        stored -= 1
        lock.unlock()
    }

    /// Increments and returns the new value.
    func incrementAndGet() -> Int {
        lock.lock()
        let value = stored + 1
        stored = value
        lock.unlock()
        return value
    }

    func raise(to candidate: Int) {
        lock.lock()
        stored = max(stored, candidate)
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Lets a test hold one delivery open until another has been attempted.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    /// Resumes once `wait()` has been entered, so the caller cannot race the
    /// open below.
    func started() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
                return
            }
            startWaiters.append(continuation)
            lock.unlock()
        }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started = true
            let waiters = startWaiters
            startWaiters = []
            let alreadyOpen = isOpen
            if !alreadyOpen { openWaiters.append(continuation) }
            lock.unlock()
            waiters.forEach { $0.resume() }
            if alreadyOpen { continuation.resume() }
        }
    }

    func open() async {
        lock.lock()
        isOpen = true
        let waiters = openWaiters
        openWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
        // Give the resumed delivery a chance to run to completion.
        for _ in 0..<50 { await Task.yield() }
    }
}
