// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHShell: execution engine.
//
// One `pdsh_run` invocation bridges the Rust worker thread callbacks to an
// `AsyncThrowingStream<ExecEvent>`:
//
// - stdout/stderr are coalesced into at most one event per stream per 16 ms
//   window; the exit event is never coalesced and is always the last event;
// - `cancel(execID:)` forwards to `pdsh_cancel`; a cancelled run exits 130;
// - a request deadline becomes the Rust cancel-token deadline (the FFI
//   watchdog), so a timed-out command is reported as exit 124 and is never
//   reported as a normal quiescent exit; the thread is joined, never abandoned;
// - the `phone` / `ctx` commands call back into the injected
//   ``PhoneToolBridge`` synchronously from the Rust thread. That callback is
//   bounded by the same per-exec budget, wakes on `pdsh_cancel`, and cancels
//   its detached bridge task. A late bridge answer is discarded: it never
//   touches the C output buffer or emits a second exit.

#if PDSH_WITH_XZSHELL

import Foundation
import PhoneDSHAgentCore

internal final class PDSHShellEngine: @unchecked Sendable {
    private let limits: PDSHShellLimits
    private let mounts: [PDSHShellMount]
    private let acceleratorNames: Set<String>
    private let toolBridge: (any PhoneToolBridge)?

    private let lock = NSLock()
    private var jobs: [String: PDSHShellJob] = [:]
    /// Serial queue that owns every event emission and the exit ordering.
    private let eventQueue = DispatchQueue(label: "xl.pdsh-shell.events", qos: .userInitiated)
    /// `pdsh_join` waits for the Rust worker; it must never run on that worker.
    private let joinQueue = DispatchQueue(label: "xl.pdsh-shell.join", qos: .utility)
    init(limits: PDSHShellLimits,
         mounts: [PDSHShellMount],
         acceleratorNames: Set<String>,
         toolBridge: (any PhoneToolBridge)?) {
        self.limits = limits
        self.mounts = mounts
        self.acceleratorNames = acceleratorNames
        self.toolBridge = toolBridge
    }

    // MARK: - Lifecycle

    func start(_ request: ExecRequest,
               continuation: AsyncThrowingStream<ExecEvent, Error>.Continuation) {
        // One request budget starts here, before validation, environment
        // sorting, C-string construction and the Rust request parse. The same
        // start instant is handed to the FFI so its cancel token is armed
        // before it parses anything; the bridge hard deadline is derived from
        // it instead of being restarted when `pdsh_run` returns.
        let requestStartNanos = PDSHShellC.monotonicNanos()
        let requestStart = DispatchTime.now()
        let requestStartedAt = Date()
        guard let cwd = guestPath(for: request.cwd) else {
            continuation.finish(throwing: PDSHShellError.invalidRequest("cwd is outside the mounts"))
            return
        }
        guard !request.argv.isEmpty else {
            continuation.finish(throwing: PDSHShellError.invalidRequest("argv must not be empty"))
            return
        }
        let name = request.argv[0]
        guard !name.isEmpty, !name.contains("\0") else {
            continuation.finish(throwing: PDSHShellError.invalidRequest("argv[0] is not a valid name"))
            return
        }
        // A provider without a usable mount cannot execute anything, so that
        // configuration error wins over the per-command advertised-name check.
        guard !mounts.isEmpty, mounts.allSatisfy({ Self.isDirectory($0.hostPath) }) else {
            continuation.finish(throwing: PDSHShellError.notConfigured)
            return
        }
        for mount in mounts where mount.hostPath.isEmpty || mount.guestPath.isEmpty {
            continuation.finish(throwing: PDSHShellError.notConfigured)
            return
        }
        guard acceleratorNames.contains(name) else {
            continuation.finish(throwing: PDSHShellError.unsupportedCommand(name))
            return
        }
        var environment: [(String, String)] = []
        for (key, value) in request.env {
            guard !key.isEmpty, !key.contains("="), !key.contains("\0"),
                  !value.contains("\0") else {
                continuation.finish(throwing: PDSHShellError.invalidRequest("invalid env entry"))
                return
            }
            environment.append((key, value))
        }
        environment.sort { $0.0 < $1.0 }

        // The remaining request budget is measured from the request start,
        // not from the moment this line runs. An already expired request
        // deadline is a terminal timeout (124), never `timeout_ms = 0`
        // ("no deadline" in the C ABI).
        guard let timeoutMilliseconds = timeoutMilliseconds(
            deadline: request.deadline, from: requestStartedAt) else {
            continuation.yield(.exit(code: 124, signal: nil, truncated: false))
            continuation.finish()
            return
        }

        let execID = request.execID
        let spec = PDSHShellRunSpec(argv: request.argv,
                                  cwd: cwd,
                                  env: environment,
                                  mounts: mounts.map { (guest: $0.guestPath, host: $0.hostPath) },
                                  timeoutMilliseconds: timeoutMilliseconds,
                                  requestStartNanos: requestStartNanos,
                                  maxOutputBytes: max(0, limits.maxOutputBytes),
                                  maxFiles: max(0, limits.maxFiles),
                                  maxFileBytes: limits.maxFileBytes)

        let job = PDSHShellJob(execID: execID,
                             maxOutputBytes: max(0, limits.maxOutputBytes),
                             bridgeDeadline: PDSHShellJob.makeBridgeDeadline(
                                timeoutMilliseconds: timeoutMilliseconds,
                                from: requestStart),
                             queue: eventQueue,
                             continuation: continuation)
        job.onTerminated = { [weak self, weak job] in
            guard let self, let job else { return }
            self.finish(job)
        }
        let bridge = toolBridge
        let sink = PDSHShellCallbackSink(
            stdout: { [weak job] data in job?.receive(.stdout, data) },
            stderr: { [weak job] data in job?.receive(.stderr, data) },
            exit: { [weak job] code in job?.receiveExit(code) },
            callTool: { [weak job] name, arguments, output, capacity in
                guard let bridge, let job else { return -1 }
                // A job that is already cancelled, finished or past its
                // deadline must not even create the detached bridge task:
                // `Task.detached` still runs its closure when it is cancelled
                // during `install`, so a host side effect could start after
                // the exec budget was spent. `beginBridgeCall` owns that
                // check under the job lock.
                guard let call = job.beginBridgeCall() else { return -1 }
                defer { job.endBridgeCall(call) }
                return PDSHShellToolBridgeForward.call(bridge,
                                                     name: name,
                                                     arguments: arguments,
                                                     output: output,
                                                     capacity: capacity,
                                                     call: call)
            })
        job.retain(sink: sink)

        // Register before `pdsh_run`: a very fast command can invoke its exit
        // callback before the handle is returned to us. The occupancy test and
        // the insert share one critical section so a duplicate exec_id cannot
        // start twice.
        lock.lock()
        guard jobs[execID] == nil else {
            lock.unlock()
            continuation.finish(
                throwing: PDSHShellError.invalidRequest("exec_id is already running"))
            return
        }
        jobs[execID] = job
        lock.unlock()

        let result = PDSHShellC.start(spec, sink: sink)
        job.attach(handle: result.handle, retained: result.retained)
    }

    func cancel(execID: String) {
        lock.lock()
        let job = jobs[execID]
        lock.unlock()
        job?.cancel()
    }

    // MARK: - Completion

    private func finish(_ job: PDSHShellJob) {
        switch job.claimJoin() {
        case .waitingForAttach:
            return
        case .noJoin:
            lock.lock()
            jobs.removeValue(forKey: job.execID)
            lock.unlock()
        case .joined(let handle):
            lock.lock()
            jobs.removeValue(forKey: job.execID)
            lock.unlock()
            // Keep the job (and therefore the request strings and the callback
            // sink) alive until pdsh_join returns, as xzshell.h requires.
            joinQueue.async {
                _ = PDSHShellC.join(handle)
                withExtendedLifetime(job) {}
            }
        }
    }

    // MARK: - Paths and time

    /// Maps a guest path (`/dsh/...`) or a host path below a mounted
    /// materialized directory to the guest path the Rust mount table needs.
    private func guestPath(for path: String) -> String? {
        if path.hasPrefix("/dsh/") {
            return path
        }
        for mount in mounts {
            if path == mount.hostPath {
                return mount.guestPath
            }
            let base = mount.hostPath.hasSuffix("/")
                ? String(mount.hostPath.dropLast())
                : mount.hostPath
            let prefix = base + "/"
            if path.hasPrefix(prefix) {
                return mount.guestPath + path.dropFirst(prefix.count - 1)
            }
        }
        return nil
    }

    /// The request budget in milliseconds, measured from `start`. `nil` means
    /// the request deadline had already passed when the request was accepted;
    /// that is a terminal 124 and must not turn into the C ABI's
    /// `timeout_ms = 0` ("no deadline").
    private func timeoutMilliseconds(deadline: Date?, from start: Date) -> UInt64? {
        guard let deadline else { return limits.timeoutMilliseconds }
        let remaining = deadline.timeIntervalSince(start)
        guard remaining > 0 else { return nil }
        let milliseconds = (remaining * 1000).rounded(.up)
        return UInt64(min(max(milliseconds, 1), Double(UInt64.max / 2)))
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

// MARK: - One execution

internal enum PDSHShellOutput: Equatable {
    case stdout
    case stderr
}

/// The two monotonic bounds of one bridge callback.
///
/// `hard` is aligned with the Rust cancel token: a result completed at or
/// after it is past the request budget and must be discarded even if it
/// arrives during the short wait grace. `wait` is `hard` plus the grace used
/// only to give the Rust watchdog time to observe its own deadline; waiting
/// past `hard` never accepts a result.
internal struct PDSHShellBridgeDeadline {
    let hard: DispatchTime
    let wait: DispatchTime
}

internal final class PDSHShellJob: @unchecked Sendable {
    let execID: String
    var onTerminated: (() -> Void)?

    private let maxOutputBytes: Int
    /// Starts at the request start and is never reset after `pdsh_run`
    /// returns. The Rust token is armed from the same start instant before it
    /// parses the request, so request parsing and C-string construction spend
    /// the original budget instead of granting the bridge a fresh one.
    private let bridgeDeadline: PDSHShellBridgeDeadline?
    private let queue: DispatchQueue
    private let continuation: AsyncThrowingStream<ExecEvent, Error>.Continuation
    /// Protects all job state. It is a condition so a tool callback that
    /// starts before `pdsh_run` returns can wait until the handle (and hence
    /// the Rust token) exists, instead of racing cancellation delivery.
    private let lock = NSCondition()

    private var sink: PDSHShellCallbackSink?
    private var retained: AnyObject?
    private var handle: Int32 = 0
    private var handleKnown = false
    private var startFailed = false
    private var cancelled = false
    private var cancelDelivered = false
    private var finished = false
    private var joinScheduled = false
    private var bridgeCalls: [PDSHShellBridgeCall] = []
    private var pendingExitCode: Int32?
    private var pending: [(stream: PDSHShellOutput, data: Data)] = []
    private var flushScheduled = false
    private var seq: UInt64 = 0
    private var stdoutBytes = 0
    private var stderrBytes = 0
    private var sawTruncationMarker = false

    private static let truncationMarker = Data("[pdsh-shell truncated ".utf8)
    /// Small allowance over the Rust watchdog deadline for a blocked host
    /// tool callback. The hard deadline is monotonic and starts at the same
    /// request instant as the Rust token, so this grace only bounds how long
    /// `wait()` keeps the Rust worker parked after that hard deadline; a
    /// bridge result completed inside the grace is still late and discarded.
    private static let bridgeDeadlineGraceMilliseconds: UInt64 = 25

    /// Arms the monotonic bridge bounds from the request start. Called before
    /// `pdsh_run`, not from `attach`.
    static func makeBridgeDeadline(timeoutMilliseconds: UInt64,
                                   from start: DispatchTime) -> PDSHShellBridgeDeadline? {
        guard timeoutMilliseconds > 0 else { return nil }
        let now = start.uptimeNanoseconds
        let availableMilliseconds = (UInt64.max - now) / 1_000_000
        let budget = min(timeoutMilliseconds, availableMilliseconds)
        let grace = min(bridgeDeadlineGraceMilliseconds, availableMilliseconds - budget)
        return PDSHShellBridgeDeadline(
            hard: DispatchTime(uptimeNanoseconds: now + budget * 1_000_000),
            wait: DispatchTime(uptimeNanoseconds: now + (budget + grace) * 1_000_000))
    }

    init(execID: String,
         maxOutputBytes: Int,
         bridgeDeadline: PDSHShellBridgeDeadline?,
         queue: DispatchQueue,
         continuation: AsyncThrowingStream<ExecEvent, Error>.Continuation) {
        self.execID = execID
        self.maxOutputBytes = maxOutputBytes
        self.bridgeDeadline = bridgeDeadline
        self.queue = queue
        self.continuation = continuation
    }

    func retain(sink: PDSHShellCallbackSink) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    /// Called with the handle returned by `pdsh_run` (or a negative value when
    /// the request could not be started).
    func attach(handle: Int32, retained: AnyObject?) {
        lock.lock()
        self.retained = retained
        if handle <= 0 {
            startFailed = true
            finished = true
            cancelDelivered = true
            let calls = bridgeCalls
            bridgeCalls.removeAll()
            lock.broadcast()
            lock.unlock()
            for call in calls {
                call.cancel()
            }
            continuation.finish(
                throwing: PDSHShellError.invalidRequest("pdsh-shell could not start the command"))
            onTerminated?()
            return
        }
        self.handle = handle
        handleKnown = true
        let cancelNow = cancelled
        let alreadyFinished = finished
        if !cancelNow {
            lock.broadcast()
            lock.unlock()
        } else {
            lock.unlock()
            // Forward the cancel to the Rust token before releasing a tool
            // callback that is waiting for the handle. Otherwise the callback
            // could answer first and turn the cancellation into a bridge
            // failure instead of exit 130.
            _ = PDSHShellC.cancel(handle)
            lock.lock()
            cancelDelivered = true
            let calls = bridgeCalls
            bridgeCalls.removeAll()
            lock.broadcast()
            lock.unlock()
            for call in calls {
                call.cancel()
            }
        }
        if alreadyFinished {
            // The exit callback won the race with `pdsh_run` returning.
            onTerminated?()
        }
    }

    /// Registers one synchronous `call_tool` callback before it blocks. A
    /// callback that starts before `pdsh_run` returns waits for the handle
    /// (and, when already cancelled, for `pdsh_cancel`) so it cannot race
    /// cancellation delivery. Its deadline was already armed at the request
    /// start, so a slow request parse is charged to the original budget.
    /// Returns `nil` when the job is already cancelled, finished or past that
    /// hard deadline (including a cancel that arrived while the callback was
    /// waiting for the handle): the host bridge must then not be entered at
    /// all, not even by a task that would be cancelled immediately after
    /// creation. On return the call remains in `bridgeCalls` until
    /// `endBridgeCall`; cancellation can therefore wake a callback that is
    /// already waiting.
    func beginBridgeCall() -> PDSHShellBridgeCall? {
        lock.lock()
        let call = PDSHShellBridgeCall(deadline: bridgeDeadline)
        if finished || startFailed {
            call.cancel()
            lock.unlock()
            return nil
        }
        bridgeCalls.append(call)
        // The Rust worker may reach the callback just before `pdsh_run`
        // returns its handle. Wait for that handle so a cancellation that
        // arrives during a slow request parse is delivered to the token before
        // the callback can start the host task.
        while !finished && !startFailed && !handleKnown && !cancelled {
            lock.wait()
        }
        while cancelled && !cancelDelivered && !finished && !startFailed {
            lock.wait()
        }
        let abandon = cancelled || finished || startFailed
        if abandon {
            bridgeCalls.removeAll { $0 === call }
            call.cancel()
            lock.unlock()
            return nil
        }
        lock.unlock()
        // The hard deadline can pass while the callback waited for the handle
        // (a very short request budget or a slow FFI parse). Do not create a
        // bridge task in that case: the Rust token was armed from the same
        // request start and has expired, so `-1` produces the deadline exit
        // and diagnostic instead of a new host side effect.
        guard call.canStartBridge() else {
            lock.lock()
            bridgeCalls.removeAll { $0 === call }
            lock.unlock()
            return nil
        }
        return call
    }

    func endBridgeCall(_ call: PDSHShellBridgeCall) {
        lock.lock()
        bridgeCalls.removeAll { $0 === call }
        lock.unlock()
    }

    /// Called on the Rust worker thread for every retained output chunk.
    func receive(_ stream: PDSHShellOutput, _ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if stream == .stdout {
            stdoutBytes += data.count
        } else {
            stderrBytes += data.count
        }
        if data.range(of: Self.truncationMarker) != nil {
            sawTruncationMarker = true
        }
        if let last = pending.last, last.stream == stream {
            pending[pending.count - 1].data.append(data)
        } else {
            pending.append((stream: stream, data: data))
        }
        let schedule = !flushScheduled
        if schedule {
            flushScheduled = true
        }
        lock.unlock()
        if schedule {
            // 16 ms coalescing window (PLAN W4-SWIFT); the exit event is sent
            // by `finishOnQueue` and is never delayed by this timer.
            queue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                self?.flushOnQueue()
            }
        }
    }

    /// Called on the Rust worker thread immediately before the worker returns.
    func receiveExit(_ code: Int32) {
        lock.lock()
        if pendingExitCode == nil {
            pendingExitCode = code
        }
        lock.unlock()
        queue.async { [weak self] in
            self?.finishOnQueue()
        }
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        cancelled = true
        let liveHandle = handleKnown ? handle : 0
        let needsDelivery = liveHandle > 0 && !cancelDelivered
        if !needsDelivery {
            // Wake an early callback so it observes `cancelled`. It still
            // waits for cancel delivery (or for `attach` to report a failed
            // start) before returning to the Rust worker.
            lock.broadcast()
            lock.unlock()
            return
        }
        lock.unlock()
        // The Rust token must observe the cancellation before a blocked host
        // callback is released; the callback then reports the cancel reason
        // and the command exits 130 rather than 69.
        _ = PDSHShellC.cancel(liveHandle)
        lock.lock()
        cancelDelivered = true
        let calls = bridgeCalls
        bridgeCalls.removeAll()
        lock.broadcast()
        lock.unlock()
        for call in calls {
            call.cancel()
        }
    }

    /// Claims the one `pdsh_join` of this handle. Called from `finish`.
    func claimJoin() -> JoinClaim {
        lock.lock()
        defer { lock.unlock() }
        if startFailed {
            return .noJoin
        }
        guard handleKnown else {
            return .waitingForAttach
        }
        guard !joinScheduled else {
            return .waitingForAttach
        }
        joinScheduled = true
        return .joined(handle)
    }

    enum JoinClaim {
        case joined(Int32)
        case waitingForAttach
        case noJoin
    }

    // MARK: Serialized event emission (eventQueue only)

    private func flushOnQueue() {
        lock.lock()
        flushScheduled = false
        let events = drainLocked()
        lock.unlock()
        emit(events)
    }

    private func finishOnQueue() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        flushScheduled = false
        let events = drainLocked()
        let exitCode = pendingExitCode
        let truncated = stdoutBytes > maxOutputBytes || stderrBytes > maxOutputBytes
            || sawTruncationMarker
        let calls = bridgeCalls
        bridgeCalls.removeAll()
        lock.broadcast()
        lock.unlock()
        for call in calls {
            call.cancel()
        }

        emit(events)
        let reported: Int32?
        if exitCode == 130 {
            // pdsh_cancel -> pdsh-ffi returns 130 (EXIT_CANCELLED in pdsh-core).
            reported = 130
        } else if exitCode == 124 {
            // The FFI watchdog cancelled the token at the requested deadline;
            // a timed-out command is always reported as 124, never as a
            // normal successful/quiescent exit.
            reported = 124
        } else {
            // A cancel that lost the race with a normal exit keeps the real
            // exit code; only the Rust side decides whether it cancelled.
            reported = exitCode
        }
        continuation.yield(.exit(code: reported, signal: nil, truncated: truncated))
        continuation.finish()
        onTerminated?()
    }

    private func drainLocked() -> [(stream: PDSHShellOutput, seq: UInt64, data: Data)] {
        var events: [(stream: PDSHShellOutput, seq: UInt64, data: Data)] = []
        events.reserveCapacity(pending.count)
        for chunk in pending {
            events.append((stream: chunk.stream, seq: seq, data: chunk.data))
            seq += 1
        }
        pending.removeAll(keepingCapacity: false)
        return events
    }

    private func emit(_ events: [(stream: PDSHShellOutput, seq: UInt64, data: Data)]) {
        for event in events {
            switch event.stream {
            case .stdout:
                continuation.yield(.stdout(seq: event.seq, data: event.data))
            case .stderr:
                continuation.yield(.stderr(seq: event.seq, data: event.data))
            }
        }
    }
}

// MARK: - Host tool bridge

/// Bridges the synchronous Rust `call_tool` callback to the async
/// ``PhoneToolBridge``.
///
/// The Rust worker thread is blocked only until the injected bridge answers,
/// the per-exec deadline expires, or `pdsh_cancel` wakes the call. On the
/// latter two the detached bridge task is cancelled and the callback returns
/// `-1`; the Rust side converts that into the request's deadline/cancel exit
/// code and diagnostic. A bridge that ignores `Task.cancel()` may keep running,
/// but its answer is dropped: it cannot write the C output buffer, emit a
/// second event or retain the Rust worker.
internal enum PDSHShellToolBridgeForward {
    static func call(_ bridge: any PhoneToolBridge,
                     name: String,
                     arguments: String,
                     output: UnsafeMutablePointer<UInt8>?,
                     capacity: Int,
                     call: PDSHShellBridgeCall) -> Int {
        // Check before creating the detached task. `Task.detached` executes
        // its closure even when it is cancelled during `install`, so creating
        // it for an already cancelled/expired call would still enter the host
        // bridge. The task repeats the check before it actually awaits the
        // bridge, which closes the window between this check and scheduling.
        guard call.canStartBridge() else { return -1 }
        let task = Task.detached(priority: .userInitiated) {
            guard call.canStartBridge() else { return }
            do {
                let text = try await bridge.callTool(name: name, arguments: arguments)
                call.complete(.success(text))
            } catch {
                call.complete(.failure(error))
            }
        }
        call.install(task: task)

        switch call.wait() {
        case .success(let text):
            let bytes = Array(text.utf8)
            if bytes.count > capacity {
                // xzshell.h: negative means "retry with a buffer of this size".
                return -bytes.count
            }
            if let output, !bytes.isEmpty {
                output.update(from: bytes, count: bytes.count)
            }
            return bytes.count
        case .failure(_), .cancelled, .timedOut:
            return -1
        }
    }
}

/// One synchronous bridge callback. The C callback and the detached Swift
/// task meet here; `wait()` is the only place that consumes the answer, so a
/// late completion after cancellation/deadline is isolated from the C output
/// buffer and from the execution's event stream.
///
/// The deadline is a `DispatchTime` (monotonic uptime), not a wall-clock
/// `Date`: a clock adjustment cannot stretch the callback's budget. It starts
/// at the request start (before C-string construction and the Rust parse), not
/// when `pdsh_run` returns the handle.
internal final class PDSHShellBridgeCall: @unchecked Sendable {
    enum Outcome {
        case success(String)
        case failure(Error)
        case cancelled
        case timedOut
    }

    private let lock = NSLock()
    /// Wakes `wait()` for a result, cancellation, or a late-armed deadline.
    private let signal = DispatchSemaphore(value: 0)
    private var deadline: PDSHShellBridgeDeadline?
    private var result: Result<String, Error>?
    /// When the detached task produced `result`. Required to reject a result
    /// that was produced after the token-aligned hard deadline but is only
    /// observed by a delayed `wait()` during the grace window.
    private var completedAt: DispatchTime?
    private var cancelled = false
    private var timedOut = false
    private var abandoned = false
    private var task: Task<Void, Never>?
    /// The hard deadline passed while the detached task was still running.
    /// The task is cancelled once, but `wait()` keeps the worker parked for
    /// the grace window so a late answer can be observed and discarded.
    private var taskCancelledAtHardDeadline = false

    init(deadline: PDSHShellBridgeDeadline?) {
        self.deadline = deadline
    }

    /// Whether the host bridge may be entered now. Called once before the
    /// detached task is created and again by the task before it awaits the
    /// injected bridge. A cancelled call or an expired hard deadline returns
    /// `false` and abandons the call, so an uncooperative bridge is never
    /// entered for a budget that is already over.
    func canStartBridge() -> Bool {
        lock.lock()
        guard !cancelled, !timedOut, !abandoned else {
            lock.unlock()
            return false
        }
        if let deadline, DispatchTime.now() >= deadline.hard {
            timedOut = true
            abandoned = true
            let task = self.task
            self.task = nil
            lock.unlock()
            task?.cancel()
            signal.signal()
            return false
        }
        lock.unlock()
        return true
    }

    /// Installs the detached bridge task. If the call was already cancelled or
    /// timed out before the task was installed, cancel it immediately; the
    /// task's own `canStartBridge` check then keeps the host bridge untouched.
    func install(task: Task<Void, Never>) {
        lock.lock()
        if cancelled || timedOut || abandoned {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    /// Called by the detached task exactly once. The completion time, not the
    /// time `wait()` happens to observe it, decides whether it is late.
    func complete(_ result: Result<String, Error>) {
        lock.lock()
        if !abandoned && !cancelled && !timedOut && self.result == nil {
            self.result = result
            self.completedAt = DispatchTime.now()
        }
        lock.unlock()
        signal.signal()
    }

    /// Called by the owning job on `pdsh_cancel` (or when the job ends).
    func cancel() {
        lock.lock()
        guard !abandoned else {
            lock.unlock()
            return
        }
        cancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
        signal.signal()
    }

    /// Blocks the Rust worker until the bridge answers or the per-exec budget
    /// is spent. Cancellation and timeout both return without consuming a
    /// result that may arrive later.
    ///
    /// A result is accepted only when it completed before `deadline.hard`.
    /// Results that completed in the grace window (after the Rust token
    /// deadline) are marked `timedOut`, dropped and their task is cancelled,
    /// so they never reach the C output buffer and cannot trigger a retry that
    /// would enter the host bridge again.
    func wait() -> Outcome {
        while true {
            lock.lock()
            if cancelled {
                abandoned = true
                result = nil
                completedAt = nil
                let task = self.task
                self.task = nil
                lock.unlock()
                task?.cancel()
                return .cancelled
            }
            if let result {
                let completion = completedAt ?? DispatchTime.now()
                if let deadline, completion >= deadline.hard {
                    self.result = nil
                    completedAt = nil
                    timedOut = true
                    abandoned = true
                    let task = self.task
                    self.task = nil
                    lock.unlock()
                    task?.cancel()
                    return .timedOut
                }
                self.result = nil
                completedAt = nil
                lock.unlock()
                switch result {
                case .success(let text):
                    return .success(text)
                case .failure(let error):
                    return .failure(error)
                }
            }
            if timedOut {
                abandoned = true
                let task = self.task
                self.task = nil
                lock.unlock()
                task?.cancel()
                return .timedOut
            }
            let now = DispatchTime.now()
            let waitUntil: DispatchTime
            var taskToCancel: Task<Void, Never>?
            if let deadline {
                if now >= deadline.hard, !taskCancelledAtHardDeadline {
                    // The budget is spent: stop the host task immediately,
                    // even though the worker is kept for the grace window so
                    // a late answer is seen and dropped rather than racing
                    // the Rust watchdog. `Task.cancel()` synchronously runs
                    // user cancellation handlers, so it must happen after
                    // this call's lock is released: a handler that re-enters
                    // the per-exec cancel path (`call.cancel()`) would
                    // otherwise deadlock the Rust worker on this same lock.
                    taskCancelledAtHardDeadline = true
                    taskToCancel = task
                    self.task = nil
                }
                if now >= deadline.wait {
                    timedOut = true
                    abandoned = true
                    let task = self.task
                    self.task = nil
                    lock.unlock()
                    taskToCancel?.cancel()
                    task?.cancel()
                    return .timedOut
                }
                // Wake at the hard deadline first so the host task is
                // cancelled on time; only then wait out the grace window.
                waitUntil = taskCancelledAtHardDeadline ? deadline.wait : deadline.hard
            } else {
                waitUntil = .distantFuture
            }
            lock.unlock()
            taskToCancel?.cancel()
            _ = signal.wait(timeout: waitUntil)
        }
    }
}

#else

import Foundation
import PhoneDSHAgentCore

/// Stub engine of a build without the Rust library: every run fails with
/// ``PDSHShellError/notLinked`` and nothing is executed.
internal final class PDSHShellEngine: @unchecked Sendable {
    init(limits: PDSHShellLimits,
         mounts: [PDSHShellMount],
         acceleratorNames: Set<String>,
         toolBridge: (any PhoneToolBridge)?) {}

    func start(_ request: ExecRequest,
               continuation: AsyncThrowingStream<ExecEvent, Error>.Continuation) {
        continuation.finish(throwing: PDSHShellError.notLinked)
    }

    func cancel(execID: String) {}
}

#endif
