// SPDX-License-Identifier: MIT
//
// Regressions for PC-20261116 revision 2: a Bot unit startup that a `detach`
// or a newer start superseded may not resume to start the routine timer,
// subscribe the live observer or publish `started`.
//
// These hosted tests import the production PhoneDSHProbe app module.
// They build the real `BotRuntimeUnit` through its production `make` and drive
// its real `start`/`detach` flow. The only controlled step is the production
// `RoutineStore` seam: its first `mutate` suspends on a continuation and never
// observes cancellation, which is the non-cooperative call the unit fence must
// refuse to continue after the test resumes it.

import Foundation
import XCTest
@testable import PhoneDSHProbe
import PhoneDSHAgentCore
@testable import PhoneDSHBot

@MainActor
final class BotUnitStartFenceTests: XCTestCase {
    private let startSteps = [
        "unit.attach-transport",
        "unit.start-main-session",
        "unit.reclaim-sessions",
        "unit.environment-connect",
        "unit.scheduler-recover",
        "unit.approvals",
        "unit.interrupted-wakes",
        "unit.device-results",
        "unit.scheduler-start",
    ]

    // MARK: - Ordinary success

    func testOrdinaryStartRunsTheWholeChainAndPublishesStarted() async throws {
        let fixture = try await UnitFixture.make(blockFirstRecovery: false)
        addTeardownBlock { await fixture.stop() }
        let recorder = DiagnosticRecorder()
        let previousSink = PhoneDSHProbe.BotRebindDiagnostics.sink
        PhoneDSHProbe.BotRebindDiagnostics.sink = { recorder.append($0) }
        defer { PhoneDSHProbe.BotRebindDiagnostics.sink = previousSink }

        let slept = expectation(description: "the routine timer started")
        fixture.sleepProbe.onFirstCall = { slept.fulfill() }

        let lease = fixture.unit.beginStart()
        try await fixture.unit.start(
            transport: fixture.transport, attempt: 31,
            channelDetail: "test=ordinary",
            lease: lease,
            isOuterBindCurrent: { true })

        XCTAssertTrue(fixture.unit.started)
        let state = await fixture.unit.rebindState()
        XCTAssertTrue(state.isStarted)
        XCTAssertTrue(state.hasLiveTransport)
        let calls = fixture.transport.calls
        XCTAssertTrue(calls.contains("session/create"),
                      "the real unit startup must create the main session: \(calls)")
        XCTAssertTrue(calls.contains("phone/botClaimSession"),
                      "the real unit startup must claim the session: \(calls)")
        let lines = recorder.lines
        for step in startSteps {
            let prefix = "bot-rebind step=\(step) attempt=31"
            XCTAssertTrue(
                lines.contains {
                    $0.hasPrefix(prefix) && $0.contains("event=start")
                },
                "missing start diagnostic for \(step)")
            XCTAssertTrue(
                lines.contains {
                    $0.hasPrefix(prefix) && $0.contains("event=end") && $0.hasSuffix(" ok")
                },
                "\(step) must complete successfully")
        }

        await fulfillment(of: [slept], timeout: 2)
        XCTAssertGreaterThan(fixture.sleepProbe.callCount, 0,
                             "a successful start must start the routine timer")
    }

    // MARK: - Detach while start is suspended

    func testDetachInvalidatesAStartSuspendedInRoutineRecovery() async throws {
        let fixture = try await UnitFixture.make(blockFirstRecovery: true)
        addTeardownBlock { await fixture.stop() }
        let recorder = DiagnosticRecorder()
        let previousSink = PhoneDSHProbe.BotRebindDiagnostics.sink
        PhoneDSHProbe.BotRebindDiagnostics.sink = { recorder.append($0) }
        defer { PhoneDSHProbe.BotRebindDiagnostics.sink = previousSink }

        let blocked = expectation(description: "start is suspended inside scheduler.recover")
        fixture.routineStore.onBlocked = { blocked.fulfill() }
        let lease = fixture.unit.beginStart()
        let stale = Task { @MainActor in
            try await fixture.unit.start(
                transport: fixture.transport, attempt: 41,
                channelDetail: "test=detach",
                lease: lease,
                isOuterBindCurrent: { true })
        }
        await fulfillment(of: [blocked], timeout: 5)
        XCTAssertTrue(fixture.routineStore.isBlocked)

        // `detach` invalidates the suspended attempt before its own first
        // await, then finishes. It must not wait for the blocked start.
        let detached = await fixture.unit.detach()
        XCTAssertTrue(detached)
        let callsAfterDetach = fixture.transport.calls
        fixture.routineStore.release()

        do {
            try await stale.value
            XCTFail("a detached start must not resume successfully")
        } catch is CancellationError {
            // Expected: the unit fence rejects the stale attempt.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertFalse(fixture.unit.started,
                       "the detached start must not publish itself running")
        XCTAssertTrue(schedulerStartLines(in: recorder.lines, attempt: 41).isEmpty,
                      "the stale attempt must never reach scheduler-start")
        XCTAssertEqual(fixture.transport.calls, callsAfterDetach,
                       "the stale attempt must not issue another transport call after detach")
        let live = await fixture.unit.remote.hasLiveTransport()
        XCTAssertFalse(live, "detach must win over the suspended start")
        let state = await fixture.unit.rebindState()
        XCTAssertFalse(state.isStarted)
        XCTAssertFalse(state.hasLiveTransport)
    }

    // MARK: - Newer start supersedes the suspended one

    func testNewerStartInvalidatesASuspendedStartAndKeepsTheNewOneRunning() async throws {
        let fixture = try await UnitFixture.make(blockFirstRecovery: true)
        addTeardownBlock { await fixture.stop() }
        let recorder = DiagnosticRecorder()
        let previousSink = PhoneDSHProbe.BotRebindDiagnostics.sink
        PhoneDSHProbe.BotRebindDiagnostics.sink = { recorder.append($0) }
        defer { PhoneDSHProbe.BotRebindDiagnostics.sink = previousSink }

        let blocked = expectation(description: "first start is suspended inside scheduler.recover")
        fixture.routineStore.onBlocked = { blocked.fulfill() }
        let firstLease = fixture.unit.beginStart()
        let first = Task { @MainActor in
            try await fixture.unit.start(
                transport: fixture.transport, attempt: 51,
                channelDetail: "test=newer-first",
                lease: firstLease,
                isOuterBindCurrent: { true })
        }
        await fulfillment(of: [blocked], timeout: 5)
        XCTAssertTrue(fixture.routineStore.isBlocked)

        // A newer start on the same unit invalidates the first attempt before
        // it awaits, and uses the same real detector/scheduler/remote flow.
        let secondTransport = StartTransport(sessionID: "gb-main-newer")
        let secondLease = fixture.unit.beginStart()
        try await fixture.unit.start(
            transport: secondTransport, attempt: 52,
            channelDetail: "test=newer-second",
            lease: secondLease,
            isOuterBindCurrent: { true })
        XCTAssertTrue(fixture.unit.started,
                      "the newer start must publish the unit")

        fixture.routineStore.release()
        do {
            try await first.value
            XCTFail("a superseded first start must not resume successfully")
        } catch is CancellationError {
            // Expected: the first attempt observes the new generation.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertTrue(fixture.unit.started,
                      "the stale attempt must not clear the newer start's flag")
        let state = await fixture.unit.rebindState()
        XCTAssertTrue(state.isStarted)
        XCTAssertTrue(state.hasLiveTransport)
        // The newer start has no live observer leak from the stale attempt:
        // the stale attempt never reached that step.
        let live = await fixture.unit.remote.hasLiveTransport()
        XCTAssertTrue(live)
        XCTAssertTrue(schedulerStartLines(in: recorder.lines, attempt: 51).isEmpty,
                      "the stale attempt must never reach scheduler-start")
        XCTAssertTrue(
            recorder.lines.contains {
                $0.hasPrefix("bot-rebind step=unit.scheduler-start attempt=52")
                    && $0.contains("event=end") && $0.hasSuffix(" ok")
            },
            "the newer start must reach and complete scheduler-start")
    }

    // MARK: - Outer bind validity

    func testOuterBindInvalidationStopsAStartSuspendedInRoutineRecovery() async throws {
        let fixture = try await UnitFixture.make(blockFirstRecovery: true)
        addTeardownBlock { await fixture.stop() }
        let recorder = DiagnosticRecorder()
        let previousSink = PhoneDSHProbe.BotRebindDiagnostics.sink
        PhoneDSHProbe.BotRebindDiagnostics.sink = { recorder.append($0) }
        defer { PhoneDSHProbe.BotRebindDiagnostics.sink = previousSink }

        let blocked = expectation(description: "start is suspended inside scheduler.recover")
        fixture.routineStore.onBlocked = { blocked.fulfill() }
        let outer = OuterBindFlag(true)
        let lease = fixture.unit.beginStart()
        let stale = Task { @MainActor in
            try await fixture.unit.start(
                transport: fixture.transport, attempt: 61,
                channelDetail: "test=outer-bind",
                lease: lease,
                isOuterBindCurrent: { outer.value })
        }
        await fulfillment(of: [blocked], timeout: 5)
        XCTAssertTrue(fixture.routineStore.isBlocked)

        // This is the composition-side fence: the newer bind invalidated the
        // outer epoch without reaching the unit's detach yet.
        outer.value = false
        fixture.routineStore.release()

        do {
            try await stale.value
            XCTFail("a start whose outer bind was replaced must not resume successfully")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertFalse(fixture.unit.started)
        XCTAssertTrue(schedulerStartLines(in: recorder.lines, attempt: 61).isEmpty,
                      "a stale outer bind must never reach scheduler-start")
        let state = await fixture.unit.rebindState()
        XCTAssertFalse(state.isStarted)
    }

    // MARK: - Late cleanup

    func testLateDetachCannotTearDownANewerStart() async throws {
        let fixture = try await UnitFixture.make(blockFirstRecovery: true)
        addTeardownBlock { await fixture.stop() }
        let recorder = DiagnosticRecorder()
        let previousSink = PhoneDSHProbe.BotRebindDiagnostics.sink
        PhoneDSHProbe.BotRebindDiagnostics.sink = { recorder.append($0) }
        defer { PhoneDSHProbe.BotRebindDiagnostics.sink = previousSink }

        let blocked = expectation(description: "first start is suspended inside scheduler.recover")
        fixture.routineStore.onBlocked = { blocked.fulfill() }
        let firstLease = fixture.unit.beginStart()
        let first = Task { @MainActor in
            try await fixture.unit.start(
                transport: fixture.transport, attempt: 71,
                channelDetail: "test=late-first",
                lease: firstLease,
                isOuterBindCurrent: { true })
        }
        await fulfillment(of: [blocked], timeout: 5)
        XCTAssertTrue(fixture.routineStore.isBlocked)

        let secondTransport = StartTransport(sessionID: "gb-main-late")
        let secondLease = fixture.unit.beginStart()
        try await fixture.unit.start(
            transport: secondTransport, attempt: 72,
            channelDetail: "test=late-second",
            lease: secondLease,
            isOuterBindCurrent: { true })
        XCTAssertTrue(fixture.unit.started)

        // The old attempt's cleanup must be a no-op: a failed/superseded
        // start's catch path must not detach the newer unit state.
        let detached = await fixture.unit.detach(ifCurrent: firstLease)
        XCTAssertFalse(detached, "a stale lease must not own a teardown")
        XCTAssertTrue(fixture.unit.started)
        let live = await fixture.unit.remote.hasLiveTransport()
        XCTAssertTrue(live, "the newer start's transport must survive the stale cleanup")
        let state = await fixture.unit.rebindState()
        XCTAssertTrue(state.isStarted)

        fixture.routineStore.release()
        do {
            try await first.value
            XCTFail("the first start must still reject itself")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertTrue(fixture.unit.started,
                      "the stale attempt must not clear the newer start's flag")
        XCTAssertTrue(schedulerStartLines(in: recorder.lines, attempt: 71).isEmpty)
        XCTAssertTrue(
            recorder.lines.contains {
                $0.hasPrefix("bot-rebind step=unit.scheduler-start attempt=72")
                    && $0.contains("event=end") && $0.hasSuffix(" ok")
            })
    }

    // MARK: - Helpers

    private func schedulerStartLines(in lines: [String], attempt: Int) -> [String] {
        lines.filter {
            $0.hasPrefix("bot-rebind step=unit.scheduler-start attempt=\(attempt)")
        }
    }
}

// MARK: - Fixtures

@MainActor
private final class UnitFixture {
    let root: URL
    let domain: SQLiteDomainStore
    let routineStore: SuspendedRoutineStore
    let sleepProbe: SchedulerSleepProbe
    let transport: StartTransport
    let unit: BotRuntimeUnit

    private init(root: URL, domain: SQLiteDomainStore,
                 routineStore: SuspendedRoutineStore,
                 sleepProbe: SchedulerSleepProbe,
                 transport: StartTransport, unit: BotRuntimeUnit) {
        self.root = root
        self.domain = domain
        self.routineStore = routineStore
        self.sleepProbe = sleepProbe
        self.transport = transport
        self.unit = unit
    }

    static func make(blockFirstRecovery: Bool) async throws -> UnitFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-unit-start-fence-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"))
        do {
            let routineStore = SuspendedRoutineStore(blockFirstMutation: blockFirstRecovery)
            // `routineStore` is a production `BotMCPRuntime` seam (not a test
            // copy of the unit): the unit's real `scheduler.recover` calls
            // `RoutineMachine.recover` and therefore this store.
            let runtime = BotMCPRuntime(store: domain, routineStore: routineStore)
            let handler = BotMCPHandler(runtime: runtime)
            let sleepProbe = SchedulerSleepProbe()
            let unit = try await BotRuntimeUnit.make(
                runtime: runtime, handler: handler, store: domain,
                botID: "main", displayName: "Main",
                workspaceRoot: root,
                sleep: { milliseconds in await sleepProbe.sleep(milliseconds) })
            return UnitFixture(
                root: root, domain: domain, routineStore: routineStore,
                sleepProbe: sleepProbe,
                transport: StartTransport(sessionID: "gb-main"),
                unit: unit)
        } catch {
            try? await domain.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func stop() async {
        _ = await unit.detach()
        try? await domain.close()
        try? FileManager.default.removeItem(at: root)
    }
}

/// A production `RoutineStore` whose first mutation suspends without observing
/// task cancellation. The test resumes it explicitly, so the stale start is
/// deterministic instead of timing-based.
private final class SuspendedRoutineStore: RoutineStore, @unchecked Sendable {
    private let blockFirstMutation: Bool
    private let lock = NSLock()
    private var mutationCount = 0
    private var blocked = false
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?
    /// Test-only signal, called from the store task when the first mutation
    /// suspends. XCTestExpectation is safe to fulfil from any thread.
    var onBlocked: (() -> Void)?

    init(blockFirstMutation: Bool) {
        self.blockFirstMutation = blockFirstMutation
    }

    var isBlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    func release() {
        lock.lock()
        released = true
        let gate = self.gate
        self.gate = nil
        lock.unlock()
        gate?.resume()
    }

    func read(botId: String) async throws -> RoutineDocument {
        RoutineDocument()
    }

    func mutate<Value: Sendable>(
        botId: String,
        _ body: @escaping @Sendable (inout RoutineDocument) throws -> RoutineMutation<Value>
    ) async throws -> Value {
        lock.lock()
        mutationCount += 1
        let shouldBlock = blockFirstMutation && mutationCount == 1
        if shouldBlock {
            blocked = true
        }
        let notify = shouldBlock ? onBlocked : nil
        lock.unlock()
        notify?()

        if shouldBlock {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                gate = continuation
                lock.unlock()
            }
        }

        var document = RoutineDocument()
        let mutation = try body(&document)
        return mutation.value
    }
}

/// Records the timer's first sleep. The sleep parks cooperatively so a started
/// scheduler does not spin; `detach` cancels the timer while it waits.
private final class SchedulerSleepProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var onFirstCall: (() -> Void)?

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func sleep(_ milliseconds: Int64) async {
        lock.lock()
        calls += 1
        let notify = calls == 1 ? onFirstCall : nil
        lock.unlock()
        notify?()
        try? await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

/// One real startup transport. It answers only the recovery/claim calls the
/// unit start performs; it never opens a turn stream.
private final class StartTransport: DSHRemoteTransport, @unchecked Sendable {
    private let sessionID: String
    private let lock = NSLock()
    private var recorded: [String] = []

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        lock.lock()
        recorded.append(endpoint)
        lock.unlock()
        switch endpoint {
        case "session/create":
            return .object([
                "sessionId": .string(sessionID),
                "agentPreset": .string(BotDSHRemoteRuntime.phoneBotAgentPreset),
            ])
        case "phone/botClaimSession":
            return .object(["ok": .bool(true)])
        default:
            return .object([:])
        }
    }

    func openMux() async throws -> any DSHMuxConnection {
        throw StartTransportError.noTurnStream
    }
}

private enum StartTransportError: Error {
    case noTurnStream
}

/// Records the bind diagnostics. `PhoneDSHProbe.BotRebindDiagnostics.sink` is the existing
/// production diagnostic seam; the test only observes which unit steps ran.
private final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
private final class OuterBindFlag {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}
