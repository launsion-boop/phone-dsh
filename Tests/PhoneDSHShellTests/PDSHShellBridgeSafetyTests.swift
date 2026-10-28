// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — linked native bridge cancellation/deadline safety.
//
// These tests drive the real Rust pdsh-shell C ABI through `PDSHShellProvider`.
// They cover the synchronous `call_tool` callback: a bridge that is still
// suspended must not keep `cancel`/`join` blocked for the old fixed 30 s, a
// request deadline must end the callback inside the request budget and report
// exit 124, a late answer must not emit or touch a released C context, and
// cancellation must stay scoped to the one exec.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHShell

#if PDSH_WITH_XZSHELL

private struct BridgeSafetyResult: Sendable {
    var stdout = Data()
    var stderr = Data()
    var exitCode: Int32?
    var signal: Int32?
    var exitCount = 0
    var lastEventWasExit = false

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

private func collectBridge(_ stream: AsyncThrowingStream<ExecEvent, Error>) async throws
    -> BridgeSafetyResult {
    var result = BridgeSafetyResult()
    for try await event in stream {
        result.lastEventWasExit = false
        switch event {
        case .stdout(_, let data):
            result.stdout.append(data)
        case .stderr(_, let data):
            result.stderr.append(data)
        case .exit(let code, let signal, _):
            result.exitCode = code
            result.signal = signal
            result.exitCount += 1
            result.lastEventWasExit = true
        }
    }
    return result
}

private struct BridgeSafetyTimeout: Error, CustomStringConvertible {
    var description: String
}

private final class BridgeSafetyResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<BridgeSafetyResult, Error>?

    func store(_ result: Result<BridgeSafetyResult, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func value() throws -> BridgeSafetyResult {
        lock.lock()
        defer { lock.unlock() }
        guard let stored else {
            throw BridgeSafetyTimeout(description: "the exec stream did not finish")
        }
        return try stored.get()
    }
}

private extension XCTestCase {
    /// Starts draining one stream on a separate task. Await `bridgeResult`
    /// afterwards; a timed-out expectation fails the test instead of hanging
    /// the process if the bridge callback never converges.
    func startBridgeCollection(
        _ stream: AsyncThrowingStream<ExecEvent, Error>
    ) -> (XCTestExpectation, BridgeSafetyResultBox) {
        let expectation = expectation(description: "bridge exec stream finished")
        let box = BridgeSafetyResultBox()
        Task {
            do {
                box.store(.success(try await collectBridge(stream)))
            } catch {
                box.store(.failure(error))
            }
            expectation.fulfill()
        }
        return (expectation, box)
    }

    func bridgeResult(_ expectation: XCTestExpectation,
                      _ box: BridgeSafetyResultBox,
                      timeout: TimeInterval) async throws -> BridgeSafetyResult {
        await fulfillment(of: [expectation], timeout: timeout)
        return try box.value()
    }

    func collectBridgeExpecting(
        _ stream: AsyncThrowingStream<ExecEvent, Error>,
        timeout: TimeInterval = 2
    ) async throws -> BridgeSafetyResult {
        let (expectation, box) = startBridgeCollection(stream)
        return try await bridgeResult(expectation, box, timeout: timeout)
    }
}

private final class BridgeSafetyTree {
    let root: URL
    let workspace: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-bridge-safety-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("materialized/workspace", isDirectory: true)
        home = root.appendingPathComponent("materialized/home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func provider(bridge: any PhoneToolBridge,
                  limits: PDSHShellLimits = .default) -> PDSHShellProvider {
        PDSHShellProvider(workspaceRoot: root, limits: limits, toolBridge: bridge)
    }
}

/// Thread-safe gate shared by the test and the suspended host bridge. A bridge
/// task may be cancelled while parked in `waitForRelease`; the continuation is
/// resumed explicitly so the test can observe `Task.isCancelled` afterwards.
private final class BridgeSafetyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var enterCount = 0
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var observedTaskCancellation = false

    var hasEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return enterCount
    }

    func markEntered() {
        lock.lock()
        entered = true
        enterCount += 1
        lock.unlock()
    }

    func waitForRelease() async {
        lock.lock()
        if released {
            lock.unlock()
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func recordTaskCancellation(_ observed: Bool) {
        lock.lock()
        observedTaskCancellation = observed
        lock.unlock()
    }

    var taskSawCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedTaskCancellation
    }
}

private enum BridgeLateBehavior: Sendable {
    case success
    case failure
}

/// A host bridge that ignores `Task.cancel()` and only answers at `release()`.
private struct BridgeLateBridge: PhoneToolBridge {
    let gate: BridgeSafetyGate
    let behavior: BridgeLateBehavior

    func callTool(name: String, arguments: String) async throws -> String {
        gate.markEntered()
        await gate.waitForRelease()
        gate.recordTaskCancellation(Task.isCancelled)
        switch behavior {
        case .success:
            return "{\"late\":true,\"name\":\"\(name)\"}"
        case .failure:
            throw BridgeSafetyTimeout(description: "late bridge failure for \(name)")
        }
    }
}

/// A bridge that answers successfully only after the request deadline. The
/// payload is larger than the FFI's first buffer, so a late success accepted
/// by the engine would trigger the negative-retry-size protocol and enter the
/// bridge a second time.
private struct BridgeDeadlineLateSuccessBridge: PhoneToolBridge {
    let gate: BridgeSafetyGate
    let payload: String
    let delayNanoseconds: UInt64

    func callTool(name: String, arguments: String) async throws -> String {
        gate.markEntered()
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        gate.recordTaskCancellation(Task.isCancelled)
        return payload
    }
}

/// Minimal thread-safe flag for coordinating a run whose request parse is
/// still in progress.
private final class BridgeSafetyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Routes the `slow` exec to the gate while letting independent execs finish.
private struct BridgeRoutingBridge: PhoneToolBridge {
    let gate: BridgeSafetyGate

    func callTool(name: String, arguments: String) async throws -> String {
        if name.hasSuffix("slow.tool") {
            gate.markEntered()
            await gate.waitForRelease()
            gate.recordTaskCancellation(Task.isCancelled)
            return "{\"late\":true}"
        }
        if name.hasSuffix("fast.tool") {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "{\"ok\":true,\"fast\":true}"
        }
        return "{\"ok\":true}"
    }
}

private func waitForBridgeEntry(_ gate: BridgeSafetyGate,
                                timeout: TimeInterval = 1) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !gate.hasEntered {
        guard Date() < deadline else {
            throw BridgeSafetyTimeout(description: "the host bridge was never entered")
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Holds a weak engine reference so a bridge cancellation handler can re-enter
/// the same per-exec cancel path synchronously, exactly like
/// `PDSHShellProvider.cancel(execID:)` does through the engine.
private final class ReentrantCancelTarget: @unchecked Sendable {
    private let lock = NSLock()
    private weak var engine: PDSHShellEngine?

    func set(_ engine: PDSHShellEngine) {
        lock.lock()
        self.engine = engine
        lock.unlock()
    }

    func cancel(execID: String) {
        lock.lock()
        let engine = self.engine
        lock.unlock()
        engine?.cancel(execID: execID)
    }
}

/// A parked bridge whose task cancellation handler synchronously re-enters the
/// per-exec cancel path. The old `wait()` called `Task.cancel()` under the
/// bridge call lock, so this handler deadlocked the Rust worker.
private struct ReentrantCancelBridge: PhoneToolBridge {
    let gate: BridgeSafetyGate
    let target: ReentrantCancelTarget
    let execID: String

    func callTool(name: String, arguments: String) async throws -> String {
        gate.markEntered()
        return await withTaskCancellationHandler {
            await gate.waitForRelease()
            gate.recordTaskCancellation(Task.isCancelled)
            return "{\"late\":true}"
        } onCancel: {
            target.cancel(execID: execID)
        }
    }
}

final class PDSHShellBridgeSafetyTests: XCTestCase {
    func testCancelWakesBlockedBridgePromptlyAndReports130() async throws {
        let tree = try BridgeSafetyTree()
        let gate = BridgeSafetyGate()
        defer { gate.release() }
        let provider = tree.provider(bridge: BridgeLateBridge(gate: gate, behavior: .success))

        let stream = provider.run(ExecRequest(
            execID: "bridge-cancel",
            argv: ["phone", "slow.tool", "{}"],
            cwd: "/dsh/workspace"))
        let (expectation, box) = startBridgeCollection(stream)
        try await waitForBridgeEntry(gate)

        let started = Date()
        await provider.cancel(execID: "bridge-cancel")
        let result = try await bridgeResult(expectation, box, timeout: 1)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.exitCount, 1)
        XCTAssertTrue(result.lastEventWasExit)
        XCTAssertEqual(result.exitCode, 130, "stderr: \(result.stderrText)")
        XCTAssertNil(result.signal)
        XCTAssertEqual(result.stdout, Data(), "a cancelled bridge must not emit its late answer")
        XCTAssertTrue(result.stderrText.contains("cancelled"),
                      "the diagnostic must name cancellation: \(result.stderrText)")
        XCTAssertLessThan(elapsed, 1.0,
                          "cancel must not wait for the old fixed 30 s bridge timeout")

        gate.release()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(gate.taskSawCancellation,
                      "the engine must request Task.cancel on the cancelled bridge task")
    }

    func testShortRequestDeadlineReturns124AndCancelsTheBridgeTask() async throws {
        let tree = try BridgeSafetyTree()
        let gate = BridgeSafetyGate()
        defer { gate.release() }
        let provider = tree.provider(bridge: BridgeLateBridge(gate: gate, behavior: .success))

        let started = Date()
        let stream = provider.run(ExecRequest(
            execID: "bridge-deadline",
            argv: ["phone", "slow.tool", "{}"],
            cwd: "/dsh/workspace",
            deadline: Date().addingTimeInterval(0.15)))
        let (expectation, box) = startBridgeCollection(stream)
        try await waitForBridgeEntry(gate)
        let result = try await bridgeResult(expectation, box, timeout: 2)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.exitCount, 1)
        XCTAssertTrue(result.lastEventWasExit)
        XCTAssertEqual(result.exitCode, 124, "the FFI deadline exit is 124; stderr: \(result.stderrText)")
        XCTAssertNil(result.signal)
        XCTAssertEqual(result.stdout, Data())
        XCTAssertTrue(result.stderrText.contains("deadline"),
                      "the diagnostic must name the deadline: \(result.stderrText)")
        XCTAssertLessThan(elapsed, 1.5, "a 150 ms deadline must not wait for a 30 s bridge")

        gate.release()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(gate.taskSawCancellation,
                      "the engine must request Task.cancel on the abandoned bridge task")
    }

    func testShortDeadlineStays124WhenRequestParsingOutlivesTheOldGrace() async throws {
        let tree = try BridgeSafetyTree()
        let gate = BridgeSafetyGate()
        defer { gate.release() }
        let provider = tree.provider(bridge: BridgeLateBridge(gate: gate, behavior: .success))

        // The bridge deadline used to be armed before `pdsh_run` with a fixed
        // 25 ms grace. If the FFI request parse (argv/env/mount validation)
        // outlived that grace, the callback woke before the Rust token expired
        // and the exec reported a bridge failure (69) instead of 124. A large
        // environment makes the parse window real while still going through
        // the actual C ABI/XCFramework.
        // Long unique keys keep the C-storage and FFI parse window well above
        // 25 ms even on a fast machine without needing a huge value payload.
        // 100k entries stay well above that grace while leaving room for a
        // slower host to build the C strings and apply the environment before
        // the request budget expires.
        let padding = String(repeating: "p", count: 96)
        var environment: [String: String] = [:]
        environment.reserveCapacity(100_000)
        for index in 0..<100_000 {
            environment["PDSH_BRIDGE_PARSE_\(padding)_\(index)"] = "v\(index)"
        }
        var request = ExecRequest(
            execID: "bridge-parse-delay",
            argv: ["phone", "slow.tool", "{}"],
            cwd: "/dsh/workspace",
            env: environment)
        // The budget must still leave room for the host to build the C
        // strings and for the worker to apply the environment after the
        // parse. The old 25 ms grace is what this test must outlive, not a
        // whole second of slow-host scheduling.
        request.deadline = Date().addingTimeInterval(2.0)

        let started = Date()
        let stream = provider.run(request)
        let (expectation, box) = startBridgeCollection(stream)
        try await waitForBridgeEntry(gate, timeout: 3)
        let result = try await bridgeResult(expectation, box, timeout: 4)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.exitCount, 1)
        XCTAssertTrue(result.lastEventWasExit)
        XCTAssertEqual(result.exitCode, 124,
                       "a slow request parse must not turn the deadline into a bridge failure; stderr: \(result.stderrText)")
        XCTAssertNil(result.signal)
        XCTAssertEqual(result.stdout, Data())
        XCTAssertTrue(result.stderrText.contains("deadline"),
                      "the diagnostic must name the deadline: \(result.stderrText)")
        XCTAssertLessThan(elapsed, 6.0)

        gate.release()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(gate.taskSawCancellation)
    }

    func testLateBridgeFailureAfterDeadlineIsIsolated() async throws {
        let tree = try BridgeSafetyTree()
        let gate = BridgeSafetyGate()
        defer { gate.release() }
        let provider = tree.provider(bridge: BridgeLateBridge(gate: gate, behavior: .failure))

        let stream = provider.run(ExecRequest(
            execID: "bridge-late-failure",
            argv: ["phone", "slow.tool", "{}"],
            cwd: "/dsh/workspace",
            deadline: Date().addingTimeInterval(0.15)))
        let (expectation, box) = startBridgeCollection(stream)
        try await waitForBridgeEntry(gate)
        let result = try await bridgeResult(expectation, box, timeout: 2)

        XCTAssertEqual(result.exitCount, 1)
        XCTAssertTrue(result.lastEventWasExit)
        XCTAssertEqual(result.exitCode, 124, "stderr: \(result.stderrText)")
        XCTAssertEqual(result.stdout, Data())

        // Let the abandoned task throw after the callback/C context is gone.
        // The engine must not turn that into a second output or exit event.
        gate.release()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(result.stderrText.contains("late bridge failure"),
                       "a late host failure must not be projected into the finished exec")
        XCTAssertTrue(gate.taskSawCancellation)
    }

    func testLateBridgeSuccessAfterDeadlineIsDiscardedWithoutRetry() async throws {
        let tree = try BridgeSafetyTree()
        let gate = BridgeSafetyGate()
        defer { gate.release() }
        // Bigger than the FFI's initial tool buffer: an accepted late success
        // would be returned as a negative retry size and enter the bridge a
        // second time.
        let payload = "{\"late\":\"" + String(repeating: "x", count: 8192) + "\"}"
        // Sleeping past the grace window makes `Task.cancel` observable in
        // the bridge itself; the completion-time check inside the grace is
        // covered by the direct `PDSHShellBridgeCall` test below.
        let provider = tree.provider(bridge: BridgeDeadlineLateSuccessBridge(
            gate: gate,
            payload: payload,
            delayNanoseconds: 240_000_000))
        let started = Date()
        let stream = provider.run(ExecRequest(
            execID: "bridge-late-success",
            argv: ["phone", "slow.tool", "{}"],
            cwd: "/dsh/workspace",
            deadline: Date().addingTimeInterval(0.2)))
        let (expectation, box) = startBridgeCollection(stream)
        try await waitForBridgeEntry(gate)
        let result = try await bridgeResult(expectation, box, timeout: 2)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.exitCount, 1)
        XCTAssertTrue(result.lastEventWasExit)
        XCTAssertEqual(result.exitCode, 124,
                       "a success completed after the hard deadline is a timeout; stderr: \(result.stderrText)")
        XCTAssertNil(result.signal)
        XCTAssertEqual(result.stdout, Data(),
                       "the late answer must not reach the C buffer or the event stream")
        XCTAssertTrue(result.stderrText.contains("deadline"),
                      "the diagnostic must name the deadline: \(result.stderrText)")
        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertEqual(gate.invocationCount, 1,
                       "a late success must not trigger a negative-size retry that re-enters the bridge")

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(gate.taskSawCancellation,
                      "the late bridge task must be cancelled at the hard deadline")
    }

    func testCancelDuringRequestParsingNeverEntersTheBridge() async throws {
        let tree = try BridgeSafetyTree()
        let gate = BridgeSafetyGate()
        defer { gate.release() }
        let provider = tree.provider(bridge: BridgeLateBridge(gate: gate, behavior: .success))

        // Keep the real FFI request parse busy while `cancel` runs. The job is
        // registered before `pdsh_run`, so cancellation must be parked until
        // the handle (and Rust token) exist and then prevent the bridge task
        // from ever being created.
        let padding = String(repeating: "p", count: 96)
        var environment: [String: String] = [:]
        environment.reserveCapacity(200_000)
        for index in 0..<200_000 {
            environment["PDSH_BRIDGE_CANCEL_PARSE_\(padding)_\(index)"] = "v\(index)"
        }
        let request = ExecRequest(
            execID: "bridge-cancel-parse",
            argv: ["phone", "slow.tool", "{}"],
            cwd: "/dsh/workspace",
            env: environment)
        let started = BridgeSafetyFlag()
        let returned = BridgeSafetyFlag()
        let runTask = Task { () -> AsyncThrowingStream<ExecEvent, Error> in
            started.set()
            let stream = provider.run(request)
            returned.set()
            return stream
        }
        while !started.isSet {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let cancelUntil = Date().addingTimeInterval(2)
        while !returned.isSet && Date() < cancelUntil {
            await provider.cancel(execID: "bridge-cancel-parse")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let stream = await runTask.value
        // Cover the case where the parse finished before the last iteration.
        await provider.cancel(execID: "bridge-cancel-parse")
        let result = try await collectBridgeExpecting(stream, timeout: 3)

        XCTAssertEqual(result.exitCount, 1)
        XCTAssertEqual(result.exitCode, 130, "stderr: \(result.stderrText)")
        XCTAssertEqual(result.stdout, Data())
        // The bridge is never entered, so there is no bridge terminal-error
        // diagnostic: the Rust command observes the cancelled token before
        // the callback. The exit code, not a host-callback stderr line, is the
        // contract here.
        XCTAssertEqual(gate.invocationCount, 0,
                       "a cancellation during pdsh_run/parse must not enter the host bridge")
    }

    func testLateResultInsideGraceIsRejectedByCompletionTime() async throws {
        let now = DispatchTime.now()
        let call = PDSHShellBridgeCall(deadline: PDSHShellBridgeDeadline(
            hard: DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 20_000_000),
            wait: DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 300_000_000)))
        let waiter = Task.detached { call.wait() }
        // The answer arrives after the hard deadline but well inside the grace
        // window. The old wait consumed any result before looking at the
        // deadline and would have reported this success.
        try await Task.sleep(nanoseconds: 50_000_000)
        call.complete(.success("late success inside grace"))
        let outcome = await waiter.value
        guard case .timedOut = outcome else {
            return XCTFail("a result that completed after the hard deadline must be timed out")
        }
    }

    func testPreCancelledAndExpiredCallsNeverStartTheBridgeTask() async throws {
        let gate = BridgeSafetyGate()
        let bridge = BridgeLateBridge(gate: gate, behavior: .success)

        let cancelled = PDSHShellBridgeCall(deadline: nil)
        cancelled.cancel()
        XCTAssertEqual(PDSHShellToolBridgeForward.call(
            bridge,
            name: "phone.cancelled",
            arguments: "{}",
            output: nil,
            capacity: 4096,
            call: cancelled), -1)

        let now = DispatchTime.now()
        let expired = PDSHShellBridgeCall(deadline: PDSHShellBridgeDeadline(
            hard: now,
            wait: DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 25_000_000)))
        XCTAssertEqual(PDSHShellToolBridgeForward.call(
            bridge,
            name: "phone.expired",
            arguments: "{}",
            output: nil,
            capacity: 4096,
            call: expired), -1)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gate.invocationCount, 0,
                       "a cancelled or expired callback must not create a bridge task")
    }

    func testCancelIsPerExecAndIndependentExecsStillSucceed() async throws {
        let tree = try BridgeSafetyTree()
        let gate = BridgeSafetyGate()
        defer { gate.release() }
        let provider = tree.provider(bridge: BridgeRoutingBridge(gate: gate))

        let slowStream = provider.run(ExecRequest(
            execID: "bridge-per-exec-slow",
            argv: ["phone", "slow.tool", "{}"],
            cwd: "/dsh/workspace"))
        let (slowExpectation, slowBox) = startBridgeCollection(slowStream)
        try await waitForBridgeEntry(gate)

        // A second exec must complete while the first bridge is still parked.
        let fast = try await collectBridgeExpecting(provider.run(ExecRequest(
            execID: "bridge-per-exec-fast",
            argv: ["phone", "fast.tool", "{}"],
            cwd: "/dsh/workspace")))
        XCTAssertEqual(fast.exitCount, 1, "stderr: \(fast.stderrText)")
        XCTAssertEqual(fast.exitCode, 0, "stderr: \(fast.stderrText)")
        XCTAssertTrue(fast.stdoutText.contains("\"fast\":true"))

        await provider.cancel(execID: "bridge-per-exec-slow")
        let slow = try await bridgeResult(slowExpectation, slowBox, timeout: 1)
        XCTAssertEqual(slow.exitCode, 130, "stderr: \(slow.stderrText)")

        // A later independent exec still runs after the cancellation cleanup.
        let after = try await collectBridgeExpecting(provider.run(ExecRequest(
            execID: "bridge-after-cancel",
            argv: ["phone", "after.tool", "{}"],
            cwd: "/dsh/workspace")))
        XCTAssertEqual(after.exitCount, 1, "stderr: \(after.stderrText)")
        XCTAssertEqual(after.exitCode, 0, "stderr: \(after.stderrText)")
        XCTAssertTrue(after.stdoutText.contains("\"ok\":true"))
    }

    func testShortDeadlineWithSlowRequestPreparationNeverEntersTheBridge() async throws {
        let tree = try BridgeSafetyTree()
        let gate = BridgeSafetyGate()
        defer { gate.release() }
        let provider = tree.provider(bridge: BridgeLateBridge(gate: gate, behavior: .success))

        // The request start is sampled before environment validation/sorting,
        // C-string construction and the Rust parse. A 50 ms budget with enough
        // environment data to outlive it must end as 124 before the host
        // bridge is entered; the old deadline was restarted after `pdsh_run`
        // returned (or became `timeout_ms = 0`, i.e. unbounded, when the
        // remaining time was already negative), so it entered the bridge with
        // a fresh budget.
        let padding = String(repeating: "p", count: 96)
        var environment: [String: String] = [:]
        environment.reserveCapacity(200_000)
        for index in 0..<200_000 {
            environment["PDSH_BRIDGE_SHORT_PARSE_\(padding)_\(index)"] = "v\(index)"
        }
        var request = ExecRequest(
            execID: "bridge-short-parse-budget",
            argv: ["phone", "slow.tool", "{}"],
            cwd: "/dsh/workspace",
            env: environment)
        request.deadline = Date().addingTimeInterval(0.05)

        let started = Date()
        let stream = provider.run(request)
        let (expectation, box) = startBridgeCollection(stream)
        let result = try await bridgeResult(expectation, box, timeout: 5)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.exitCount, 1)
        XCTAssertTrue(result.lastEventWasExit)
        XCTAssertEqual(result.exitCode, 124,
                       "an expired original budget must be 124, not a bridge failure; stderr: \(result.stderrText)")
        XCTAssertEqual(result.stdout, Data())
        XCTAssertEqual(gate.invocationCount, 0,
                       "a bridge must not be entered after the original request budget expired during preparation")
        XCTAssertLessThan(elapsed, 4.0,
                          "the callback must not add a fresh budget after slow request preparation")
    }

    func testBridgeCancellationHandlerCanReenterExecCancelWithoutDeadlock() async throws {
        let tree = try BridgeSafetyTree()
        let gate = BridgeSafetyGate()
        defer { gate.release() }
        let target = ReentrantCancelTarget()
        let execID = "bridge-reentrant-cancel"
        let bridge = ReentrantCancelBridge(gate: gate, target: target, execID: execID)
        let mounts = [
            PDSHShellMount(hostPath: tree.workspace.path,
                           guestPath: "/dsh/workspace",
                           readOnly: true),
            PDSHShellMount(hostPath: tree.home.path,
                           guestPath: "/dsh/home",
                           readOnly: true),
        ]
        let engine = PDSHShellEngine(limits: .default,
                                   mounts: mounts,
                                   acceleratorNames: ["phone"],
                                   toolBridge: bridge)
        target.set(engine)

        let started = Date()
        let stream = AsyncThrowingStream<ExecEvent, Error> { continuation in
            engine.start(ExecRequest(
                execID: execID,
                argv: ["phone", "slow.tool", "{}"],
                cwd: "/dsh/workspace",
                deadline: Date().addingTimeInterval(0.15)), continuation: continuation)
        }
        let (expectation, box) = startBridgeCollection(stream)
        try await waitForBridgeEntry(gate)
        let result = try await bridgeResult(expectation, box, timeout: 2)
        let elapsed = Date().timeIntervalSince(started)

        // The handler cancels the Rust token while `wait()` cancels the task.
        // Both the deadline and the explicit cancel are expired, so either
        // 124 (deadline wins in the FFI) or 130 is a correct bounded exit; the
        // regression is that this must not deadlock while holding the call
        // lock.
        XCTAssertEqual(result.exitCount, 1, "stderr: \(result.stderrText)")
        XCTAssertTrue(result.lastEventWasExit)
        XCTAssertTrue([124, 130].contains(result.exitCode ?? -1),
                      "stderr: \(result.stderrText)")
        XCTAssertLessThan(elapsed, 1.5,
                          "re-entering provider/engine cancel from the handler must not hold the callback lock")
        gate.release()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(gate.taskSawCancellation)
    }
}

#endif
