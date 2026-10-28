// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: turn-level inactivity
// supervision.
//
// G2-FIX-12. The real-model batch exposed turns that stopped producing any
// session event while the Worker, the model delivery chain or a tool was
// hung: the runner only had its wall-clock budget, so the report could not
// tell "hung" from "still working" and the whole budget burned in silence.
//
// This supervisor wraps the `AgentHarness` the facade hands to the App. It
// timestamps every `HarnessEvent` of an open turn and owns a timer measured
// from the last event, not from the turn duration. When a turn stays silent
// for `PhoneDSHConfiguration.turnInactivityTimeout`, it:
//
//   1. fails the turn loud with a terminal `.turnEnded(..., reason: .failed)`
//      event that carries the last event kind and the measured silence;
//   2. emits a synthetic `.turnStarted` first when the harness never
//      announced the turn (so consumers that pair start with end still see a
//      complete terminal pair);
//   3. asks the underlying harness to cancel the in-flight turn;
//   4. records the stall in a ledger that ``PhoneDSHHost/diagnostics()``
//      surfaces through ``PhoneDSHDiagnostics``;
//   5. freezes that first terminal: a late terminal event the underlying
//      harness still produces for the aborted turn is not forwarded, so
//      recorders keyed on the latest reason keep the diagnosed failure;
//   6. disarms when the last `events()` subscriber goes away. A recovery
//      rebinds the harness (`PhoneDSHHost/harness()` returns a fresh
//      supervisor); the abandoned one must not later cancel the recovered
//      session or count a phantom stall in the ledger shared with the host.
//
// Any event (usage, streaming delta, tool call/result, progress, status)
// renews the timer, so a healthy long turn is never killed for its duration.
// The threshold is configuration, never a constant in this file.

import Foundation
import PhoneDSHAgentCore

/// Aggregate turn-inactivity diagnostics for one host incarnation.
public struct PhoneDSHTurnInactivityReport: Equatable, Sendable {
    /// The configured event-silence threshold in seconds.
    public var timeout: TimeInterval
    /// Number of turns aborted by the watchdog.
    public var stallCount: UInt64
    /// Human-readable diagnostic of the most recent stall, or `nil`.
    public var lastStallReason: String?
    /// When the most recent stall was detected, or `nil`.
    public var lastStallAt: Date?
    /// Kind of the last session event observed before the most recent stall.
    public var lastEventKind: String?
    /// Silence duration measured at the most recent stall.
    public var lastEventAge: TimeInterval?

    public init(timeout: TimeInterval, stallCount: UInt64 = 0,
                lastStallReason: String? = nil, lastStallAt: Date? = nil,
                lastEventKind: String? = nil, lastEventAge: TimeInterval? = nil) {
        self.timeout = timeout
        self.stallCount = stallCount
        self.lastStallReason = lastStallReason
        self.lastStallAt = lastStallAt
        self.lastEventKind = lastEventKind
        self.lastEventAge = lastEventAge
    }
}

/// Lock-protected stall ledger shared by the supervisors a host creates.
///
/// The facade may hand out more than one harness over its lifetime (a scenario
/// runner creates one per run); stalls are counted for the host, not for the
/// individual wrapper. The type is an `@unchecked Sendable` final class rather
/// than an actor so a supervisor can record a stall without another await
/// hop between closing the turn and publishing diagnostics.
public final class PhoneDSHTurnInactivityLedger: @unchecked Sendable {
    /// The configured event-silence threshold in seconds.
    public let timeout: TimeInterval

    private let lock = NSLock()
    private var stallCountStorage: UInt64 = 0
    private var lastReasonStorage: String?
    private var lastStallAtStorage: Date?
    private var lastEventKindStorage: String?
    private var lastEventAgeStorage: TimeInterval?

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// Records one watchdog abort.
    public func recordStall(reason: String, lastEventKind: String,
                            age: TimeInterval, at date: Date) {
        lock.lock()
        stallCountStorage &+= 1
        lastReasonStorage = reason
        lastStallAtStorage = date
        lastEventKindStorage = lastEventKind
        lastEventAgeStorage = age
        lock.unlock()
    }

    /// Immutable snapshot for diagnostics.
    public func report() -> PhoneDSHTurnInactivityReport {
        lock.lock()
        defer { lock.unlock() }
        return PhoneDSHTurnInactivityReport(
            timeout: timeout,
            stallCount: stallCountStorage,
            lastStallReason: lastReasonStorage,
            lastStallAt: lastStallAtStorage,
            lastEventKind: lastEventKindStorage,
            lastEventAge: lastEventAgeStorage)
    }
}

/// `AgentHarness` decorator that aborts a turn when its event stream goes
/// silent for the configured threshold (G2-FIX-12).
///
/// It forwards every command and event to the wrapped harness unchanged; the
/// only added behaviour is the inactivity timer and the terminal event it
/// publishes when that timer expires. It does not poll: the timer is an
/// event-driven `Task.sleep` that every observed event reschedules.
public actor PhoneDSHTurnInactivitySupervisor: AgentHarness {
    /// Forwarded from the wrapped harness.
    public nonisolated let capabilities: HarnessCapabilities

    private struct SessionState {
        var turnOpen = false
        var aborting = false
        var turnID: String?
        var turnStartObserved = false
        var openedAt: Date?
        var lastEventAt: Date?
        var lastEventKind = "none"
        /// Turn IDs whose terminal event the watchdog already published. A
        /// late terminal from the underlying harness for one of these turns
        /// is dropped so consumers that key on the latest terminal keep the
        /// first (diagnosed) one.
        var sealedTerminalTurnIDs: Set<String> = []
        /// Set when the watchdog aborted a turn that never announced its ID;
        /// the first terminal that arrives afterwards belongs to it.
        var suppressNextTerminal = false
        /// Bumped by every event and by every new turn; a timer that wakes
        /// with a stale value does nothing.
        var generation: UInt64 = 0
    }

    private nonisolated let harness: any AgentHarness
    private nonisolated let timeout: TimeInterval
    private nonisolated let ledger: PhoneDSHTurnInactivityLedger
    private var sessions: [String: SessionState] = [:]
    private var subscribers: [String: [UUID: AsyncThrowingStream<HarnessEvent, Error>.Continuation]] = [:]
    private var timerTasks: [String: Task<Void, Never>] = [:]

    /// Creates a supervisor.
    ///
    /// - Parameters:
    ///   - harness: The session stream to supervise.
    ///   - timeout: Event-silence threshold in seconds. The host passes
    ///     ``PhoneDSHConfiguration/turnInactivityTimeout``; this type never
    ///     hardcodes a value.
    ///   - ledger: Shared diagnostics ledger; a private one is created when
    ///     omitted.
    public init(harness: any AgentHarness, timeout: TimeInterval,
                ledger: PhoneDSHTurnInactivityLedger? = nil) {
        self.harness = harness
        self.timeout = timeout
        self.capabilities = harness.capabilities
        self.ledger = ledger ?? PhoneDSHTurnInactivityLedger(timeout: timeout)
    }

    /// The stall counter and last reason recorded by this supervisor's ledger.
    public func inactivityReport() -> PhoneDSHTurnInactivityReport {
        ledger.report()
    }

    // MARK: - AgentHarness

    public func openSession(_ request: HarnessSessionRequest) async throws -> HarnessSession {
        try await harness.openSession(request)
    }

    public func send(_ command: HarnessCommand, to sessionID: String) async throws {
        let opensTurn: Bool
        switch command {
        case .prompt(_, _, let requestID):
            beginTurn(sessionID, turnID: requestID)
            opensTurn = true
        case .steer(_, let requestID):
            beginTurn(sessionID, turnID: requestID)
            opensTurn = true
        case .permissionResponse, .questionResponse:
            // Answering an approval/question is host progress: it renews the
            // timer but does not open a new turn (the turn is already open).
            touchForHostCommand(sessionID)
            opensTurn = false
        case .cancel, .cancelWithCause, .shutdown:
            opensTurn = false
        }
        do {
            try await harness.send(command, to: sessionID)
            switch command {
            case .cancel, .cancelWithCause, .shutdown:
                closeTurn(sessionID)
            default:
                break
            }
        } catch {
            // A prompt that never reached the harness cannot open a turn; the
            // error already reaches the caller.
            if opensTurn { closeTurn(sessionID) }
            throw error
        }
    }

    public nonisolated func events(sessionID: String, after seq: UInt64?)
        -> AsyncThrowingStream<HarnessEvent, Error> {
        let harness = self.harness
        let subscriberID = UUID()
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.addSubscriber(subscriberID, sessionID: sessionID,
                                         continuation: continuation)
                do {
                    for try await event in harness.events(sessionID: sessionID, after: seq) {
                        await self.deliver(event, sessionID: sessionID,
                                           subscriberID: subscriberID)
                    }
                    await self.removeSubscriber(subscriberID, sessionID: sessionID)
                    continuation.finish()
                } catch {
                    await self.removeSubscriber(subscriberID, sessionID: sessionID)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func closeSession(_ sessionID: String) async {
        await harness.closeSession(sessionID)
        sessions[sessionID] = nil
        timerTasks[sessionID]?.cancel()
        timerTasks[sessionID] = nil
        if let continuations = subscribers.removeValue(forKey: sessionID) {
            for continuation in continuations.values { continuation.finish() }
        }
    }

    // MARK: - Turn state

    private func addSubscriber(
        _ id: UUID, sessionID: String,
        continuation: AsyncThrowingStream<HarnessEvent, Error>.Continuation) {
        subscribers[sessionID, default: [:]][id] = continuation
    }

    private func removeSubscriber(_ id: UUID, sessionID: String) {
        subscribers[sessionID]?[id] = nil
        if subscribers[sessionID]?.isEmpty == true {
            subscribers[sessionID] = nil
            // No consumer observes this session any more (the scenario runner
            // cancels its pump when it rebinds the harness after a recovery).
            // Disarm the watchdog: an abandoned supervisor with an open turn
            // would later emit into a dead stream and, worse, cancel the
            // recovered session and count a phantom stall in the shared
            // ledger.
            disarmTurn(sessionID)
        }
    }

    /// Stops supervising the current turn because its observer went away.
    private func disarmTurn(_ sessionID: String) {
        guard var state = sessions[sessionID] else { return }
        state.turnOpen = false
        state.aborting = false
        state.generation &+= 1
        sessions[sessionID] = state
        timerTasks[sessionID]?.cancel()
        timerTasks[sessionID] = nil
    }

    private func deliver(_ event: HarnessEvent, sessionID: String,
                         subscriberID: UUID) {
        if var state = sessions[sessionID] {
            if case .turnEnded(let turnID, _) = event.kind {
                if state.sealedTerminalTurnIDs.contains(turnID) {
                    // The watchdog already published the one terminal event
                    // of this turn; a late terminal from the underlying
                    // harness (DSH reports the cancelled turn after our
                    // abort) must not overwrite the recorded diagnosis.
                    return
                }
                if state.suppressNextTerminal {
                    state.suppressNextTerminal = false
                    sessions[sessionID] = state
                    return
                }
            }
        }
        observe(event, sessionID: sessionID)
        subscribers[sessionID]?[subscriberID]?.yield(event)
    }

    /// Opens (or renews) the supervised turn for one prompt/steer.
    private func beginTurn(_ sessionID: String, turnID: String?) {
        var state = sessions[sessionID] ?? SessionState()
        let now = Date()
        if !state.turnOpen {
            state.turnOpen = true
            state.aborting = false
            state.turnID = turnID ?? state.turnID
            state.turnStartObserved = false
            state.openedAt = now
            state.lastEventAt = now
            state.lastEventKind = "none"
        } else {
            // A queued prompt renews the silence timer of the running turn.
            state.lastEventAt = now
            state.lastEventKind = "host-command"
        }
        // A prompt/steer opens (or queues into) a supervised turn; a terminal
        // suppressed for a previously aborted turn must not swallow this one.
        state.suppressNextTerminal = false
        state.generation &+= 1
        sessions[sessionID] = state
        scheduleCheck(sessionID)
    }

    private func closeTurn(_ sessionID: String) {
        guard var state = sessions[sessionID] else { return }
        state.turnOpen = false
        state.aborting = false
        state.generation &+= 1
        sessions[sessionID] = state
        timerTasks[sessionID]?.cancel()
        timerTasks[sessionID] = nil
    }

    private func touchForHostCommand(_ sessionID: String) {
        guard var state = sessions[sessionID], state.turnOpen else { return }
        state.lastEventAt = Date()
        state.lastEventKind = "host-command"
        state.generation &+= 1
        sessions[sessionID] = state
        scheduleCheck(sessionID)
    }

    private func observe(_ event: HarnessEvent, sessionID: String) {
        guard var state = sessions[sessionID], state.turnOpen else { return }
        let now = Date()
        state.lastEventAt = now
        state.lastEventKind = Self.describe(event.kind)
        state.generation &+= 1
        switch event.kind {
        case .turnStarted(let turnID):
            state.turnID = turnID
            state.turnStartObserved = true
            sessions[sessionID] = state
            scheduleCheck(sessionID)
        case .turnEnded(let endedTurnID, _):
            // A late terminal event of an already-aborted turn must not close
            // the retried turn that replaced it. When IDs are unknown (no
            // turnStarted ever arrived) the terminal event still closes.
            if let current = state.turnID, current != endedTurnID {
                sessions[sessionID] = state
                scheduleCheck(sessionID)
                return
            }
            state.turnOpen = false
            state.aborting = false
            sessions[sessionID] = state
            timerTasks[sessionID]?.cancel()
            timerTasks[sessionID] = nil
        case .exited:
            state.turnOpen = false
            state.aborting = false
            sessions[sessionID] = state
            timerTasks[sessionID]?.cancel()
            timerTasks[sessionID] = nil
        default:
            sessions[sessionID] = state
            scheduleCheck(sessionID)
        }
    }

    // MARK: - Watchdog

    /// (Re)arms the silence timer for the current turn generation.
    private func scheduleCheck(_ sessionID: String) {
        timerTasks[sessionID]?.cancel()
        guard let state = sessions[sessionID], state.turnOpen else { return }
        let generation = state.generation
        let timeout = self.timeout
        timerTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
            } catch {
                return
            }
            await self?.checkStall(sessionID: sessionID, generation: generation)
        }
    }

    private func checkStall(sessionID: String, generation: UInt64) async {
        guard var state = sessions[sessionID], state.turnOpen,
              !state.aborting, state.generation == generation else { return }
        // The watchdog only exists for an observed turn. If the last
        // subscriber disappeared between arming the timer and this hop, it is
        // an abandoned supervisor: disarm instead of failing a turn nobody is
        // watching, sending a cancel into the recovered session and counting a
        // phantom stall in the shared ledger.
        guard subscribers[sessionID]?.isEmpty == false else {
            disarmTurn(sessionID)
            return
        }
        let now = Date()
        let lastEventAt = state.lastEventAt ?? state.openedAt ?? now
        let age = max(0, now.timeIntervalSince(lastEventAt))
        let kind = state.lastEventKind
        let turnID = state.turnID ?? "unknown"
        let ageText = Self.seconds(age)
        let timeoutText = Self.seconds(timeout)
        let reason = "turn \(turnID) in session \(sessionID) stalled: "
            + "no session event for \(ageText) s "
            + "(timeout \(timeoutText) s, last event: \(kind), "
            + "last event age \(ageText) s)"
        state.aborting = true
        state.turnOpen = false
        state.sealedTerminalTurnIDs.insert(turnID)
        // When the harness never announced the turn we can only know its
        // provisional request id, while its late terminal carries the DSH
        // turn number. Suppress the first underlying terminal that arrives
        // afterwards; a new prompt clears the suppression.
        if !state.turnStartObserved { state.suppressNextTerminal = true }
        sessions[sessionID] = state
        timerTasks[sessionID] = nil
        ledger.recordStall(reason: reason, lastEventKind: kind, age: age, at: now)
        let terminal = HarnessEvent(
            seq: nil, time: now,
            kind: .turnEnded(turnID: turnID, reason: .failed(reason)))
        let syntheticStart: HarnessEvent? = state.turnStartObserved ? nil : HarnessEvent(
            seq: nil, time: now, kind: .turnStarted(turnID: turnID))
        if let continuations = subscribers[sessionID] {
            for continuation in continuations.values {
                if let syntheticStart { continuation.yield(syntheticStart) }
                continuation.yield(terminal)
            }
        }
        // Abort the in-flight turn on the harness side as well; the synthetic
        // terminal event already released the consumer.
        let harness = self.harness
        Task { try? await harness.send(.cancel, to: sessionID) }
    }

    private static func describe(_ kind: HarnessEvent.Kind) -> String {
        switch kind {
        case .assistantDelta: return "assistantDelta"
        case .assistantMessage: return "assistantMessage"
        case .userMessage: return "userMessage"
        case .inboxSpliced: return "inboxSpliced"
        case .toolCall: return "toolCall"
        case .toolResult: return "toolResult"
        case .permissionRequested: return "permissionRequested"
        case .questionRequested: return "questionRequested"
        case .turnStarted: return "turnStarted"
        case .turnEnded: return "turnEnded"
        case .progress: return "progress"
        case .sessionStatus: return "sessionStatus"
        case .usage: return "usage"
        case .exited: return "exited"
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }
}
