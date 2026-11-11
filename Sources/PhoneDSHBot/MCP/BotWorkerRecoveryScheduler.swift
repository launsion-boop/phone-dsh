// SPDX-License-Identifier: MIT
// phone-dsh Bot runtime — App-side recovery after a Worker boot is replaced.
//
// The production composition owns one `BotWorkerRecoveryScheduler`. The host
// publishes `.webContentTerminated` before a replacement Worker boots, then
// `.restarted` (page boot-ready) and `.workerHello` (ordered channel HELLO).
// This scheduler turns those events into exactly one App-side rebind per new
// Worker boot: it never binds before the replacement boot is known, retries a
// newer boot seen during an in-flight rebind, and bounds every attempt so a
// transport that never answers cannot leave the Bot page at "正在重新同步…".

import Foundation

/// Serializes the App-side rebind of the production Bot composition.
@MainActor
public final class BotWorkerRecoveryScheduler {
    public enum Phase: Equatable, Sendable {
        case idle
        case recovering
        case ready
        case failed(String)
    }

    /// The production rebind: re-attach every Bot unit's transport, restart
    /// the main session and re-claim its credentials. The scheduler only
    /// decides when it runs; it never widens a credential check.
    public typealias Recovery = @MainActor (_ workerBootID: String?) async throws -> Void

    public private(set) var phase: Phase = .idle
    /// The Worker boot id whose rebind completed successfully.
    public private(set) var recoveredBootID: String?
    /// The newest Worker boot id observed from the host (HELLO or restart).
    public private(set) var latestBootID: String?
    /// The newest page boot-ready id reported by the engine. It is diagnostic
    /// only: `.restarted` is emitted by the engine/page, while only the Worker
    /// HELLO identifies the ordered channel this scheduler can bind.
    public private(set) var latestPageBootID: String?
    /// Host-monotonic HELLO sequence last consumed. A reconnect increments it
    /// too, so it is a duplicate filter, not a replacement signal.
    public private(set) var latestHelloCount: UInt64 = 0
    /// Fence generation last reported by a HELLO. The fence is the host's WAL
    /// authority; a WebContent kill does not advance it, so it is not a Worker
    /// process identity.
    public private(set) var latestFenceGeneration: UInt64 = 0
    /// For diagnostics/tests: whether a rebind is currently running.
    public private(set) var isRecovering = false
    /// For diagnostics/tests: the replacement boot is known from HELLO and the
    /// bind is waiting for its Worker `ready` signal.
    public var isAwaitingWorkerReady: Bool { awaitingReadyTarget != nil }

    /// Every attempt is bounded. A Worker replacement normally rebinds in a
    /// few seconds; the bound is only a safety net for a stalled transport.
    public let timeoutMilliseconds: Int
    /// Automatic retries after one event-driven failure (a new Worker HELLO,
    /// the visible retry, or a newer boot). An automatic retry that fails again
    /// consumes the same round; it never opens a fresh round. Without this
    /// bound a `.failed` phase change re-armed a new loop forever.
    public let maximumAutomaticRetries: Int
    /// Delay between two attempts of the same automatic round.
    public let retryDelayMilliseconds: Int
    /// Upper bound on waiting for a replacement Worker's `ready` signal before
    /// binding anyway. The production page/Worker forwards its reserved boot
    /// phase lines over the ordered channel; an older bundle that does not
    /// still recovers, just without the early-readiness guarantee.
    public let readyFallbackMilliseconds: Int
    public var onPhaseChange: ((Phase) -> Void)?

    private enum Target: Equatable {
        /// A specific replacement Worker, named by its HELLO boot id.
        case boot(String)
        /// No new boot is known (the visible retry button); the production
        /// bind records the host's current Worker id after it succeeds.
        case current

        var bootID: String? {
            if case .boot(let value) = self { return value }
            return nil
        }
    }

    private enum AttemptResult {
        case success
        case failure(String)
        case timedOut
        case cancelled
    }

    private var recovery: Recovery?
    private var activeTarget: Target?
    private var pendingTarget: Target?
    /// The host's monotonic WebContent-termination count. A delayed duplicate
    /// of the event that was already consumed must not undo a completed boot.
    private var lastTerminationCount: UInt64 = 0
    /// Whether the next ordered-channel HELLO belongs to the replacement of a
    /// terminated Worker. The HELLO's boot id alone cannot answer this: the
    /// termination-recovery boot path reuses the host's engine configuration,
    /// so the replacement may present the id already bound. A same-Worker
    /// channel reconnect is the opposite case and must not rebind. The ordered
    /// termination event is the only reliable discriminator; the HELLO count
    /// only filters duplicate HELLOs.
    private var replacementHelloPending = false
    /// Whether a Worker `ready` boot phase was observed since the last
    /// termination. The Worker installs its ordered-channel API bridge just
    /// before that line, so a bind issued before it can send a request into a
    /// dropped window (the d-heal4 hang).
    private var workerReady = false
    /// The replacement boot whose HELLO is known but whose `ready` line has not
    /// arrived yet. The bind starts from here, never from the raw HELLO.
    private var awaitingReadyTarget: Target?
    private var readyFallbackTask: Task<Void, Never>?
    /// Invalidates a cancelled/superseded attempt. Its late completion must
    /// not publish `.ready` over a newer attempt or a visible failure.
    private var generation = 0
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var attemptContinuation: AsyncStream<AttemptResult>.Continuation?
    /// Attempts left in the current round. It is set only by an event-driven
    /// start and decremented by each scheduled automatic retry, so a failing
    /// automatic retry cannot reset it.
    private var automaticRetriesRemaining = 0

    public init(timeoutMilliseconds: Int = 20_000,
                maximumAutomaticRetries: Int = 5,
                retryDelayMilliseconds: Int = 2_000,
                readyFallbackMilliseconds: Int = 5_000) {
        self.timeoutMilliseconds = max(1, timeoutMilliseconds)
        self.maximumAutomaticRetries = max(0, maximumAutomaticRetries)
        self.retryDelayMilliseconds = max(0, retryDelayMilliseconds)
        self.readyFallbackMilliseconds = max(0, readyFallbackMilliseconds)
    }

    public func install(_ recovery: @escaping Recovery) {
        self.recovery = recovery
    }

    /// Records the Worker boot whose rebind succeeded during the initial
    /// composition bind. No recovery runs; the next new boot does.
    public func seed(recoveredBootID: String?) {
        cancelAutomaticRetry()
        cancelReadyFallback()
        awaitingReadyTarget = nil
        workerReady = false
        automaticRetriesRemaining = 0
        self.recoveredBootID = recoveredBootID
        self.latestBootID = recoveredBootID
        self.latestPageBootID = nil
        self.latestHelloCount = 0
        self.latestFenceGeneration = 0
        // A seed follows a host bind, which may have replaced the engine. The
        // WebEngine's termination count is per engine, so later counts restart
        // at 1; do not compare them with the previous engine's. Any HELLO still
        // queued from that bind is not a replacement.
        self.lastTerminationCount = 0
        self.replacementHelloPending = false
    }

    /// A WebContent termination is not a Worker boot: it only tells the page
    /// that the current channel is gone. Reporting `recovering` here without a
    /// bind is deliberate — the old Worker is dead and the replacement has not
    /// answered HELLO yet, so a transport opened now would wait on a channel
    /// that does not exist. Without an attempt deadline the queued HELLO
    /// events were only consumed after that stalled bind returned.
    public func noteTermination(count: UInt64) {
        guard count > lastTerminationCount else { return }
        lastTerminationCount = count
        // The replacement boot has not HELLOed yet; a retry queued for the dead
        // boot belongs to the previous round.
        cancelAutomaticRetry()
        cancelReadyFallback()
        awaitingReadyTarget = nil
        workerReady = false
        automaticRetriesRemaining = 0
        // Even if the engine reuses the Worker boot id, the next ordered
        // channel HELLO is a new Worker connection and owns a bind.
        replacementHelloPending = true
        setPhase(.recovering)
    }

    /// Records a Worker boot-phase `ready` line.
    ///
    /// The Worker installs its ordered-channel API bridge immediately before
    /// it announces `ready`, so this is the first moment an App bind can send
    /// `session/page` / `phone/botClaimSession` without the request being
    /// dropped from a channel that has HELLOed but cannot serve yet. A rebind
    /// armed by the replacement HELLO starts here.
    public func noteWorkerReady() {
        workerReady = true
        guard !isRecovering, let target = awaitingReadyTarget else { return }
        awaitingReadyTarget = nil
        cancelReadyFallback()
        startEventDriven(target)
    }

    /// Records the engine's page boot-ready report. It moves the page to
    /// recovering before the ordered channel is ready, but it is not a bind
    /// point: `.workerHello` owns the bind.
    ///
    /// The report id is the engine's page boot id. The production page forwards
    /// that id to the Worker, so it normally equals the following HELLO id,
    /// but an engine that reuses its configuration (the `bootWorker` fallback)
    /// or a Worker bundle that does not forward it can report a different id.
    /// It must therefore never become a bind target, and a late report must not
    /// undo a bind that already completed: the HELLO that would replace it has
    /// already been consumed, so the page would stay recovering forever.
    public func noteBootCandidate(_ pageBootID: String) {
        latestPageBootID = pageBootID
        guard pageBootID != recoveredBootID else { return }
        guard phase != .ready else { return }
        setPhase(.recovering)
    }

    /// The authoritative point to rebind: the replacement Worker completed its
    /// ordered-channel HELLO. If another attempt is still running, remember
    /// the newest boot and redo it when that attempt ends.
    ///
    /// - Parameters:
    ///   - bootID: Worker process identity from the HELLO.
    ///   - helloCount: Host-monotonic HELLO sequence (0 when unknown). It
    ///     increments for every channel HELLO, including a same-Worker
    ///     reconnect, so it can discard a duplicate but cannot by itself tell
    ///     a replacement from a reconnect.
    ///   - fenceGeneration: Fence generation the Worker presented. This is the
    ///     host's WAL authority, not a process identity: a WebContent kill does
    ///     not advance it. It is recorded for diagnostics only.
    public func noteWorkerBoot(_ bootID: String, helloCount: UInt64 = 0,
                               fenceGeneration: UInt64 = 0) {
        if helloCount > 0 {
            guard helloCount > latestHelloCount else { return }
            latestHelloCount = helloCount
        }
        latestBootID = bootID
        latestFenceGeneration = fenceGeneration
        // The engine restart / resume behind this HELLO can have a fresh
        // per-engine termination counter (a parked host gets a new engine).
        lastTerminationCount = 0
        let isReplacement = replacementHelloPending
        replacementHelloPending = false
        let isNewBoot = isReplacement || bootID != recoveredBootID
        if isRecovering {
            if isNewBoot {
                pendingTarget = .boot(bootID)
                // Any ready signal seen so far belongs to the boot whose bind
                // is still running, not to this newer replacement.
                workerReady = false
            }
            setPhase(.recovering)
            return
        }
        guard isNewBoot else { return }
        // HELLO is the Worker's identity, not its API readiness: the Worker
        // sends it when the socket opens, then spends most of its boot before
        // `serveApiRequests` is installed. Binding on HELLO sent the first
        // `session/page` into that drop window; wait for the `ready` phase
        // (with a bounded fallback for bundles that do not forward it).
        workerReady = false
        armReadyGate(.boot(bootID))
    }

    private func armReadyGate(_ target: Target) {
        awaitingReadyTarget = target
        setPhase(.recovering)
        scheduleReadyFallback(for: target)
    }

    private func scheduleReadyFallback(for target: Target) {
        cancelReadyFallback()
        guard readyFallbackMilliseconds > 0 else {
            awaitingReadyTarget = nil
            startEventDriven(target)
            return
        }
        let delay = readyFallbackMilliseconds
        readyFallbackTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.awaitingReadyTarget == target else { return }
            self.readyFallbackTask = nil
            self.awaitingReadyTarget = nil
            self.startEventDriven(target)
        }
    }

    private func cancelReadyFallback() {
        readyFallbackTask?.cancel()
        readyFallbackTask = nil
    }

    /// The page's 重试 button. It is never masked by an in-flight flag: a hung
    /// attempt must not make the visible button a no-op. The old attempt is
    /// superseded (its late result is ignored) and the current boot is retried.
    /// A user action is a new event, so it opens a fresh automatic-retry round.
    public func forceRetry() {
        let target = latestBootID.map(Target.boot) ?? .current
        if isRecovering {
            generation &+= 1
            task?.cancel()
            attemptContinuation?.finish()
            attemptContinuation = nil
            task = nil
            isRecovering = false
            activeTarget = nil
            pendingTarget = nil
        }
        startEventDriven(target)
    }

    /// Waits until the current rebind (and any queued newer boot) finished.
    /// The composition's visible 重试 action uses this so its caller observes
    /// the same completed state it did when retry awaited `bind` directly.
    public func waitUntilIdle() async {
        while (isRecovering || task != nil || retryTask != nil
                || awaitingReadyTarget != nil) && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Cancels the in-flight attempt (best effort) and drops pending work.
    /// Called when the composition detaches or switches hosts.
    public func stop() {
        generation &+= 1
        task?.cancel()
        attemptContinuation?.finish()
        attemptContinuation = nil
        task = nil
        cancelAutomaticRetry()
        cancelReadyFallback()
        awaitingReadyTarget = nil
        workerReady = false
        isRecovering = false
        activeTarget = nil
        pendingTarget = nil
        recoveredBootID = nil
        latestBootID = nil
        latestPageBootID = nil
        latestHelloCount = 0
        latestFenceGeneration = 0
        lastTerminationCount = 0
        replacementHelloPending = false
        automaticRetriesRemaining = 0
        setPhase(.idle)
    }

    /// Starts a round for a new event: a new Worker boot, the visible retry, or
    /// a newer boot seen while an attempt was in flight.
    private func startEventDriven(_ target: Target) {
        cancelAutomaticRetry()
        cancelReadyFallback()
        awaitingReadyTarget = nil
        automaticRetriesRemaining = maximumAutomaticRetries
        start(target)
    }

    private func start(_ target: Target) {
        guard let recovery else { return }
        generation &+= 1
        let attemptGeneration = generation
        isRecovering = true
        activeTarget = target
        setPhase(.recovering)
        task = Task { [weak self] in
            guard let self else { return }
            let result = await self.runAttempt(target, recovery: recovery)
            guard !Task.isCancelled, attemptGeneration == self.generation else { return }
            self.finish(target: target, result: result)
        }
    }

    private func finish(target: Target, result: AttemptResult) {
        isRecovering = false
        task = nil
        attemptContinuation = nil
        activeTarget = nil
        switch result {
        case .success:
            cancelAutomaticRetry()
            automaticRetriesRemaining = 0
            recoveredBootID = target.bootID ?? latestBootID ?? recoveredBootID
            if let pending = pendingTarget, pending != target,
               pending.bootID != recoveredBootID {
                pendingTarget = nil
                if workerReady {
                    workerReady = false
                    startEventDriven(pending)
                } else {
                    armReadyGate(pending)
                }
                return
            }
            pendingTarget = nil
            setPhase(.ready)
        case .failure(let message):
            if retryNewerBootIfPending(after: target) { return }
            if scheduleAutomaticRetry(after: target) { return }
            automaticRetriesRemaining = 0
            setPhase(.failed(message))
        case .timedOut:
            if retryNewerBootIfPending(after: target) { return }
            if scheduleAutomaticRetry(after: target) { return }
            automaticRetriesRemaining = 0
            setPhase(.failed("Bot 连接恢复超时"))
        case .cancelled:
            // `stop()`/a superseded retry owns the next state.
            break
        }
    }

    /// A newer Worker boot that arrived while an attempt was in flight is the
    /// boot that matters: try it before surfacing a failure, so event order
    /// cannot strand the page. It is a new event, so it starts a fresh round.
    private func retryNewerBootIfPending(after target: Target) -> Bool {
        guard let pending = pendingTarget, pending != target,
              pending.bootID != recoveredBootID else {
            pendingTarget = nil
            return false
        }
        pendingTarget = nil
        // A newer boot may itself still be before its `ready` line; use the
        // same gate instead of re-entering the dropped-request window.
        if workerReady {
            workerReady = false
            startEventDriven(pending)
        } else {
            armReadyGate(pending)
        }
        return true
    }

    /// Continues the current round if it has retries left. The budget is
    /// consumed here, so failures caused by these attempts can only schedule
    /// the next retry of the same round — never reset it. Once it reaches zero
    /// the phase stays `.failed` until a new event (`noteWorkerBoot`,
    /// `forceRetry`) starts another round.
    private func scheduleAutomaticRetry(after target: Target) -> Bool {
        guard automaticRetriesRemaining > 0 else { return false }
        automaticRetriesRemaining -= 1
        generation &+= 1
        let attemptGeneration = generation
        let delay = retryDelayMilliseconds
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  attemptGeneration == self.generation else { return }
            self.retryTask = nil
            self.start(target)
        }
        return true
    }

    private func cancelAutomaticRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// Runs one rebind with a hard deadline. The timeout is deliberately an
    /// unstructured race: a transport that ignores cancellation cannot make
    /// `withTaskGroup` wait forever on the scope exit.
    private func runAttempt(_ target: Target, recovery: @escaping Recovery) async
        -> AttemptResult {
        let (stream, continuation) = AsyncStream<AttemptResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        attemptContinuation = continuation
        let work = Task { @MainActor in
            do {
                try await recovery(target.bootID)
                continuation.yield(.success)
            } catch {
                continuation.yield(.failure(
                    "Bot 连接恢复失败：\(error.localizedDescription)"))
            }
            continuation.finish()
        }
        let timeout = timeoutMilliseconds
        let timer = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
            } catch {
                return
            }
            continuation.yield(.timedOut)
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next() ?? .cancelled
        work.cancel()
        timer.cancel()
        if case .timedOut = result {
            // The non-cooperative work may still be suspended; its late yield
            // lands in the finished stream and is ignored.
            attemptContinuation = nil
        }
        return result
    }

    private func setPhase(_ next: Phase) {
        guard phase != next else { return }
        phase = next
        onPhaseChange?(next)
    }
}
