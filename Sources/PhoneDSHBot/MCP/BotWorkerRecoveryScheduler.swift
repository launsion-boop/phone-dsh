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
    /// For diagnostics/tests: whether a rebind is currently running.
    public private(set) var isRecovering = false

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
                retryDelayMilliseconds: Int = 2_000) {
        self.timeoutMilliseconds = max(1, timeoutMilliseconds)
        self.maximumAutomaticRetries = max(0, maximumAutomaticRetries)
        self.retryDelayMilliseconds = max(0, retryDelayMilliseconds)
    }

    public func install(_ recovery: @escaping Recovery) {
        self.recovery = recovery
    }

    /// Records the Worker boot whose rebind succeeded during the initial
    /// composition bind. No recovery runs; the next new boot does.
    public func seed(recoveredBootID: String?) {
        cancelAutomaticRetry()
        automaticRetriesRemaining = 0
        self.recoveredBootID = recoveredBootID
        self.latestBootID = recoveredBootID
        // A seed follows a host bind, which may have replaced the engine. The
        // WebEngine's termination count is per engine, so later counts restart
        // at 1; do not compare them with the previous engine's.
        self.lastTerminationCount = 0
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
        automaticRetriesRemaining = 0
        setPhase(.recovering)
    }

    /// Records a boot id the host announced before the ordered channel is
    /// ready (the engine's `.restarted` page boot-ready report). It moves the
    /// page to recovering immediately but only becomes a bind target when the
    /// matching `.workerHello` confirms the channel.
    public func noteBootCandidate(_ bootID: String) {
        latestBootID = bootID
        guard bootID != recoveredBootID else { return }
        setPhase(.recovering)
    }

    /// The authoritative point to rebind: the replacement Worker completed its
    /// ordered-channel HELLO. If another attempt is still running, remember
    /// the newest boot and redo it when that attempt ends.
    public func noteWorkerBoot(_ bootID: String) {
        latestBootID = bootID
        // The engine restart / resume behind this HELLO can have a fresh
        // per-engine termination counter (a parked host gets a new engine).
        lastTerminationCount = 0
        if isRecovering {
            if bootID != activeTarget?.bootID, bootID != recoveredBootID {
                pendingTarget = .boot(bootID)
            }
            setPhase(.recovering)
            return
        }
        guard bootID != recoveredBootID else { return }
        startEventDriven(.boot(bootID))
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
        while (isRecovering || task != nil || retryTask != nil) && !Task.isCancelled {
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
        isRecovering = false
        activeTarget = nil
        pendingTarget = nil
        recoveredBootID = nil
        latestBootID = nil
        lastTerminationCount = 0
        automaticRetriesRemaining = 0
        setPhase(.idle)
    }

    /// Starts a round for a new event: a new Worker boot, the visible retry, or
    /// a newer boot seen while an attempt was in flight.
    private func startEventDriven(_ target: Target) {
        cancelAutomaticRetry()
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
                startEventDriven(pending)
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
        startEventDriven(pending)
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
