// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: per-turn persistence accounting.
//
// `spec/v1/budgets.md` §7 collects `fsync_calls_per_turn` and
// `bytes_written_per_turn` for one user turn, at the `write()` /
// `fsync` / `F_FULLFSYNC` call. `PhoneDSHLog` already counts both in
// ``WorkspaceLogIOCounters`` (process-wide, every store that module owns);
// this file connects that counter window to the host's real turn lifecycle so
// the numbers are actually produced and recorded:
//
//   * turn start  — the `AgentHarness` command that asks for a turn
//                   (``HarnessCommand/prompt(text:attachments:requestID:)`` or
//                   ``HarnessCommand/steer(text:requestID:)``) calls
//                   ``WorkspaceLogIOCounters/reset()``; a prompt queued behind
//                   a running turn opens its own window at DSH's `.turnStarted`,
//                   the same boundary a fresh prompt uses;
//   * turn end    — the terminal `.turnEnded` (completed / cancelled / failed /
//                   budget exhausted), `.exited`, a failed prompt send, a
//                   closed session or the end of the event stream calls
//                   ``WorkspaceLogIOCounters/settle()`` and stores the sample;
//   * epoch close — D18's fsync pass. The tail it settles is credited to the
//                   open turn instead of being dropped, so a close in the
//                   middle of a turn never truncates that turn's window;
//   * teardown    — a park/stop force-closes whatever the abort drain could not
//                   observe, after the host's own sealing close.
//
// This is observation only. It adds no turn or epoch concept, changes no write
// order, sync point, CRC, file format or durability promise, and the recorded
// values never flow back into a decision: the only effects are the counter
// calls above plus one diagnostic line per settled turn.
//
// Scope: the counters cover the stores `PhoneDSHLog` owns (WAL segments,
// journal, materialized copy, blob store, overlay, manifest). Steps, the exec
// ledger and the response log live in other modules and are not counted; the
// budgets.md §7 row is filled by whatever the shipping build measures.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHLog

/// One settled per-turn persistence sample.
///
/// `counters` is the sum of every ``WorkspaceLogIOCounters`` window settled
/// since the turn started, including an epoch close that ran inside the turn.
/// A turn whose persistence work was observed but never settled (the process
/// died first) produces no sample; the next turn starts a fresh window.
public struct PhoneDSHTurnPersistenceIOSample: Equatable, Sendable {
    /// The DSH session whose turn settled.
    public var sessionID: String
    /// The turn id the harness reported (the prompt request id when no
    /// `.turnStarted`/`.turnEnded` id was available).
    public var turnID: String?
    /// Stable transport token for how the turn ended: `completed`, `cancelled`,
    /// `failed`, `budget-exhausted`, `exited`, `closed`, `send-failed`,
    /// `stream-ended`, `stream-failed`, `parked`, `interrupted`, `stopped`,
    /// `host-failed`.
    public var outcome: String
    /// Settled `fsync` / `F_FULLFSYNC` calls and bytes written.
    public var counters: WorkspaceLogIOCounters
    /// When the host settled the window.
    public var settledAt: Date

    public init(sessionID: String, turnID: String? = nil, outcome: String,
                counters: WorkspaceLogIOCounters, settledAt: Date = Date()) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.outcome = outcome
        self.counters = counters
        self.settledAt = settledAt
    }
}

/// Lock-protected owner of the host's per-turn counter window.
///
/// The type is an `@unchecked Sendable` final class rather than an actor so the
/// harness decorator can settle the window inside the same hop that delivers
/// the terminal event: a consumer that reacts to `.turnEnded` must be able to
/// read the finished number synchronously afterwards, and a settle that raced
/// behind the event would sometimes report the previous turn.
///
/// The window is process-wide like ``WorkspaceLogIOCounters`` itself. When two
/// sessions overlap, their writes share one window and the single sample is
/// attributed to the turn that closed last; `turn_end` for a session with no
/// open turn is a no-op, so a duplicate or late terminal cannot settle twice.
public final class PhoneDSHTurnPersistenceIOLedger: @unchecked Sendable {
    /// Receives one line per settled sample (the host appends it to its
    /// existing diagnostic log). Called outside the internal lock.
    public typealias Sink = @Sendable (PhoneDSHTurnPersistenceIOSample) -> Void

    private let lock = NSLock()
    /// Sessions whose turn is open, in the order they opened.
    private var openSessions: [String] = []
    /// Last turn id observed per open session.
    private var openTurnIDs: [String: String] = [:]
    /// Settled windows of the current turn window that have not been recorded
    /// yet (an epoch close inside the turn).
    private var accumulated = WorkspaceLogIOCounters()
    private var lastSampleStorage: PhoneDSHTurnPersistenceIOSample?
    private var settlementCountStorage: UInt64 = 0
    private let sink: Sink?

    public init(sink: Sink? = nil) {
        self.sink = sink
    }

    // MARK: - Reads

    /// The most recently settled turn sample, or `nil` before the first turn.
    public func lastSample() -> PhoneDSHTurnPersistenceIOSample? {
        lock.lock()
        defer { lock.unlock() }
        return lastSampleStorage
    }

    /// The most recently settled turn's counters (budgets.md §7).
    public func lastCounters() -> WorkspaceLogIOCounters? {
        lastSample()?.counters
    }

    /// Number of settled turn windows this host recorded.
    public func settlementCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return settlementCountStorage
    }

    /// Sessions with an open turn right now (diagnostics/tests).
    public func openSessionIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return openSessions
    }

    // MARK: - Window transitions (called by the harness decorator and the host)

    /// Starts the window for a turn that just opened (a prompt/steer command,
    /// or DSH's `.turnStarted` for a queued turn).
    ///
    /// The first open turn of the process resets the counters so no write that
    /// preceded the turn is reported as its persistence work. A prompt/steer
    /// that queues into an already-open turn keeps the running window.
    func beginTurn(sessionID: String, turnID: String?) {
        lock.lock()
        let firstOpen = openSessions.isEmpty
        if !openSessions.contains(sessionID) {
            openSessions.append(sessionID)
            if let turnID { openTurnIDs[sessionID] = turnID }
        }
        // A queued prompt that arrives while its session already has an open
        // turn does not replace that turn's id: the running turn is still the
        // one that will settle (and it reports its own terminal id anyway).
        if firstOpen {
            // Reset while the ledger is locked so an epoch close or a terminal
            // from another session cannot interleave between the check and the
            // reset and hand this turn the previous window's tail.
            WorkspaceLogIOCounters.reset()
            accumulated = WorkspaceLogIOCounters()
        }
        lock.unlock()
    }

    /// Settles the window of a turn that ended.
    ///
    /// When no other session still has an open turn, the accumulated window is
    /// stored as the sample and reported to the sink. A no-op for a session
    /// whose turn already settled (a late or duplicate terminal).
    func endTurn(sessionID: String, turnID: String?, outcome: String) {
        var sample: PhoneDSHTurnPersistenceIOSample?
        lock.lock()
        guard let index = openSessions.firstIndex(of: sessionID) else {
            lock.unlock()
            return
        }
        openSessions.remove(at: index)
        let recordedTurnID = openTurnIDs.removeValue(forKey: sessionID)
        accumulated = combined(accumulated, with: WorkspaceLogIOCounters.settle())
        if openSessions.isEmpty {
            let settled = PhoneDSHTurnPersistenceIOSample(
                sessionID: sessionID,
                turnID: turnID ?? recordedTurnID,
                outcome: outcome,
                counters: accumulated,
                settledAt: Date())
            accumulated = WorkspaceLogIOCounters()
            lastSampleStorage = settled
            settlementCountStorage &+= 1
            sample = settled
        }
        lock.unlock()
        if let sample { sink?(sample) }
    }

    /// Settles one epoch close (D18's fsync pass).
    ///
    /// A close inside an open turn is credited to that turn, because the fsyncs
    /// belong to the work the turn just made durable. A close with no open turn
    /// is the between-turns tail: it is discarded here, and the next turn's
    /// ``beginTurn(sessionID:turnID:)`` would discard it anyway.
    func settleEpochClose() {
        lock.lock()
        let settled = WorkspaceLogIOCounters.settle()
        if !openSessions.isEmpty {
            accumulated = combined(accumulated, with: settled)
        }
        lock.unlock()
    }

    /// Settles and closes every open turn after the host has sealed the
    /// workspace (park/stop). Samples an open window with `outcome`; a window
    /// with no open turn only drops the teardown tail.
    @discardableResult
    func closeOpenTurnsAfterSeal(outcome: String) -> PhoneDSHTurnPersistenceIOSample? {
        var sample: PhoneDSHTurnPersistenceIOSample?
        lock.lock()
        accumulated = combined(accumulated, with: WorkspaceLogIOCounters.settle())
        guard let sessionID = openSessions.last else {
            accumulated = WorkspaceLogIOCounters()
            lock.unlock()
            return nil
        }
        let turnID = openTurnIDs[sessionID]
        openSessions.removeAll()
        openTurnIDs.removeAll()
        let settled = PhoneDSHTurnPersistenceIOSample(
            sessionID: sessionID, turnID: turnID, outcome: outcome,
            counters: accumulated, settledAt: Date())
        accumulated = WorkspaceLogIOCounters()
        lastSampleStorage = settled
        settlementCountStorage &+= 1
        sample = settled
        lock.unlock()
        if let sample { sink?(sample) }
        return sample
    }

    // MARK: - Helpers

    private func combined(_ lhs: WorkspaceLogIOCounters,
                          with rhs: WorkspaceLogIOCounters) -> WorkspaceLogIOCounters {
        WorkspaceLogIOCounters(
            fsyncCalls: lhs.fsyncCalls + rhs.fsyncCalls,
            bytesWritten: lhs.bytesWritten + rhs.bytesWritten)
    }

    /// One bounded `boot-timings.log` diagnostic line for a settled turn.
    ///
    /// The format is console/log text only: no channel frame, event field or
    /// spec value is added by it.
    static func diagnosticLine(for sample: PhoneDSHTurnPersistenceIOSample,
                               bootID: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: sample.settledAt)
        let session = token(sample.sessionID)
        let turn = token(sample.turnID ?? "unknown")
        let outcome = token(sample.outcome)
        return "turn-io \(timestamp) boot=\(bootID) session=\(session) "
            + "turn=\(turn) outcome=\(outcome) "
            + "fsync_calls=\(sample.counters.fsyncCalls) "
            + "bytes_written=\(sample.counters.bytesWritten)"
    }

    /// A single bounded token: no whitespace or control characters, at most 64
    /// characters, so one record stays one parseable keyword=value line.
    private static func token(_ raw: String) -> String {
        let cleaned = raw.map { character -> Character in
            if character.isWhitespace || character.isNewline { return "_" }
            if let scalar = character.unicodeScalars.first,
               CharacterSet.controlCharacters.contains(scalar) { return "_" }
            return character
        }
        let bounded = String(cleaned.prefix(64))
        return bounded.isEmpty ? "unknown" : bounded
    }
}

/// `AgentHarness` decorator that ties ``WorkspaceLogIOCounters`` to the real
/// turn boundary of the session stream.
///
/// It forwards every command, event and session call unchanged. The only added
/// behaviour is the counter window: reset when a turn opens (the prompt/steer
/// command that asks for it, or DSH's own `.turnStarted` when a queued prompt
/// begins a turn the command already preceded), settle when the turn's terminal
/// event is observed — before that event is yielded, so a consumer reading the
/// host API on `.turnEnded` sees the finished number — and settle what is left
/// when the last event subscriber goes away or the session is closed. A cancel
/// settles on DSH's own terminal record, not on the cancel RPC's return, so the
/// bytes DSH journals for the abort are counted with the turn.
///
/// A `.turnStarted` for the turn this decorator already settled is a replayed
/// snapshot (the follow stream replays the latest turn when a consumer
/// subscribes from scratch), not a new turn: it does not re-open a window.
/// Likewise a terminal whose id does not match the `.turnStarted` id of the open
/// turn belongs to an older turn and does not settle the current one.
public actor PhoneDSHTurnPersistenceIOSupervisor: AgentHarness {
    /// Forwarded from the wrapped harness.
    public nonisolated let capabilities: HarnessCapabilities

    private nonisolated let harness: any AgentHarness
    private nonisolated let ledger: PhoneDSHTurnPersistenceIOLedger
    /// Sessions with at least one live `events()` subscriber.
    private var subscriberCounts: [String: Int] = [:]
    /// Sessions whose turn this decorator opened and still owns.
    private var openSessions: Set<String> = []
    /// The prompt/steer request id that preceded the open turn, when any. It is
    /// the sample's fallback id; DSH's durable turn id wins when it arrives.
    private var requestIDs: [String: String] = [:]
    /// DSH turn id announced by `.turnStarted` for the open turn.
    private var startedTurnIDs: [String: String] = [:]
    /// The last turn id this decorator settled per session. A replayed
    /// `.turnStarted` naming it is not a new turn.
    private var settledTurnIDs: [String: String] = [:]

    public init(harness: any AgentHarness,
                ledger: PhoneDSHTurnPersistenceIOLedger) {
        self.harness = harness
        self.capabilities = harness.capabilities
        self.ledger = ledger
    }

    // MARK: - AgentHarness

    public func openSession(_ request: HarnessSessionRequest) async throws
        -> HarnessSession {
        try await harness.openSession(request)
    }

    public func send(_ command: HarnessCommand, to sessionID: String) async throws {
        let opensTurn: Bool
        let turnID: String?
        switch command {
        case .prompt(_, _, let requestID):
            opensTurn = true
            turnID = requestID
        case .steer(_, let requestID):
            opensTurn = true
            turnID = requestID
        case .cancel, .cancelWithCause, .permissionResponse, .questionResponse,
             .shutdown:
            // A cancel ends the turn when the terminal record arrives: DSH
            // journals `turn/end` after the cancel is processed, and settling
            // on the RPC return would drop those bytes. The abort/teardown
            // paths close a turn whose terminal never arrives.
            opensTurn = false
            turnID = nil
        }
        if opensTurn {
            if openSessions.insert(sessionID).inserted {
                requestIDs[sessionID] = turnID
                startedTurnIDs[sessionID] = nil
            }
            ledger.beginTurn(sessionID: sessionID, turnID: turnID)
        }
        do {
            try await harness.send(command, to: sessionID)
        } catch {
            // A prompt that never reached the harness cannot open a turn.
            if opensTurn, openSessions.remove(sessionID) != nil {
                requestIDs[sessionID] = nil
                startedTurnIDs[sessionID] = nil
                ledger.endTurn(sessionID: sessionID, turnID: turnID,
                               outcome: "send-failed")
            }
            throw error
        }
    }

    public nonisolated func events(sessionID: String, after seq: UInt64?)
        -> AsyncThrowingStream<HarnessEvent, Error> {
        let harness = self.harness
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.subscribe(sessionID)
                do {
                    for try await event in harness.events(sessionID: sessionID,
                                                          after: seq) {
                        await self.observe(event, sessionID: sessionID)
                        continuation.yield(event)
                    }
                    await self.unsubscribe(sessionID, outcome: "stream-ended")
                    continuation.finish()
                } catch {
                    await self.unsubscribe(sessionID, outcome: "stream-failed")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func closeSession(_ sessionID: String) async {
        await harness.closeSession(sessionID)
        subscriberCounts[sessionID] = nil
        if openSessions.contains(sessionID) {
            finish(sessionID, turnID: nil, outcome: "closed")
        }
    }

    // MARK: - Turn state

    private func subscribe(_ sessionID: String) {
        subscriberCounts[sessionID, default: 0] += 1
    }

    /// The last subscriber of a session went away: no consumer can observe this
    /// session's terminal record any more, so an open turn must not keep the
    /// process-wide window (and every later turn) merged into one.
    private func unsubscribe(_ sessionID: String, outcome: String) {
        let remaining = (subscriberCounts[sessionID] ?? 1) - 1
        if remaining > 0 {
            subscriberCounts[sessionID] = remaining
            return
        }
        subscriberCounts[sessionID] = nil
        guard openSessions.contains(sessionID) else { return }
        finish(sessionID, turnID: nil, outcome: outcome)
    }

    /// Settles the turn *before* the terminal event is yielded: a consumer that
    /// reacts to `.turnEnded` by reading the host API must see this turn's
    /// numbers, not the previous turn's.
    private func observe(_ event: HarnessEvent, sessionID: String) {
        switch event.kind {
        case .turnStarted(let turnID):
            guard settledTurnIDs[sessionID] != turnID else { return }
            if !openSessions.contains(sessionID) {
                // A queued prompt begins its turn after the previous turn's
                // terminal; the command that queued it opened no window here.
                // DSH's own turn start is the same boundary the watchdog and
                // the abort drain use, so the window starts here.
                openSessions.insert(sessionID)
                requestIDs[sessionID] = nil
                ledger.beginTurn(sessionID: sessionID, turnID: turnID)
            }
            startedTurnIDs[sessionID] = turnID
        case .turnEnded(let turnID, let reason):
            guard openSessions.contains(sessionID) else { return }
            // A terminal of an older turn (a replayed snapshot, a late
            // duplicate) must not settle the turn that replaced it.
            if let started = startedTurnIDs[sessionID], started != turnID {
                return
            }
            finish(sessionID, turnID: turnID, outcome: Self.outcome(of: reason))
        case .exited:
            guard openSessions.contains(sessionID) else { return }
            finish(sessionID, turnID: nil, outcome: "exited")
        default:
            break
        }
    }

    /// Closes and settles the open turn of one session.
    private func finish(_ sessionID: String, turnID: String?, outcome: String) {
        openSessions.remove(sessionID)
        let provisional = requestIDs[sessionID]
        requestIDs[sessionID] = nil
        let started = startedTurnIDs[sessionID]
        startedTurnIDs[sessionID] = nil
        let reported = turnID ?? started ?? provisional
        if let reported { settledTurnIDs[sessionID] = reported }
        ledger.endTurn(sessionID: sessionID, turnID: reported, outcome: outcome)
    }

    private static func outcome(of reason: HarnessTurnEnd) -> String {
        switch reason {
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .budgetExhausted: return "budget-exhausted"
        }
    }
}
