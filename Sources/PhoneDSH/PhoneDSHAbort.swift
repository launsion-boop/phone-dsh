// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — terminal DSH session record before teardown.
//
// G2-A08: a run that ended through a wall budget, a request budget, a user
// cancel or a background drain could tear the Worker down while the DSH session
// journal still had an open turn. The cancel RPC was fire-and-forget and the
// host drain only waited for in-flight `0x40` API exchanges, so the only record
// of the outcome was the runner's report: the session event stream could not be
// reconstructed (model-visible ⟺ logged was broken).
//
// This file supplies the pieces the host uses to make a session journal
// terminal *before* teardown:
//
//   * `PhoneDSHSessionLog` reads the materialized DSH session log
//     (`/dsh/home/sessions/<encoded-cwd>/<session-id>/session.v*.jsonl`) and
//     reports whether its last turn boundary is an open `turn/start` or a
//     closing `turn/end`. It never writes DSH events — the Worker owns the
//     journal.
//   * `PhoneDSHSessionTracker` remembers the session ids this host incarnation
//     handed to the Worker, so a stale journal from an earlier crash is never
//     mistaken for a live turn.
//   * `PhoneDSHTrackedTransport` is the transparent `DSHRemoteTransport` seam
//     that feeds that registry from the public `session/create` /
//     `session/prompt` envelopes.
//   * `phoneDSHResultWithinDeadline` bounds the awaited cancel RPC: a response
//     that never arrives cannot keep the App in its drain window forever.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHWire

// MARK: - Session journal state

/// The turn state of one DSH session journal.
///
/// DSH v4 appends one canonical JSON record per line. `turn/start` opens a
/// turn and `turn/end` closes it with a `reason.kind` (`completed`, `aborted`,
/// `interrupted`, `error`, `max-tokens`, …). A session with no open turn is
/// terminal: whatever ended the turn is durably in the same file the model's
/// history is replayed from.
public struct PhoneDSHSessionTurnState: Equatable, Sendable {
    /// The `id` recorded in the session header, or the directory name when the
    /// header was not readable.
    public var sessionID: String?
    /// `parentSession` from the session header. Present on a spawned child
    /// (and on a forked session); nil for a top-level root.
    public var parentSessionID: String?
    /// Coarse header classification: `subagent` marks a child session.
    public var origin: String?
    /// Durable delegation depth from the session header.
    public var delegationDepth: Int?
    /// Immutable session creation time (`createdAt`, epoch milliseconds).
    ///
    /// A child journal created before the current host incarnation started is
    /// a stale crash record: its Activation is no longer resident, so a live
    /// `drainDescendants` call cannot append its terminal `turn/end`.
    public var headerCreatedAtMillis: Int64?
    /// The turn opened by the most recent `turn/start` (nil when no turn is
    /// open at the tail).
    public var openTurn: Int?
    /// `type` of the last readable record.
    public var lastRecordType: String?
    /// `reason.kind` of the last `turn/end`.
    public var lastTurnEndReason: String?
    /// The `turn` number recorded by the last `turn/end`, when the journal
    /// carries it. This distinguishes "turn 2 was closed" from a truncated
    /// journal that fell back to turn 1's older terminal record.
    public var lastTurnEndTurn: Int?
    /// Every `turn` number closed by a `turn/end` that carried one. A drain
    /// can observe turn N open, then the Worker finishes N and consumes the
    /// pending inbox prompt into N+1 before escalation reads the journal. The
    /// tail then names N+1, but N's closer is still durable; this set proves
    /// that N was closed instead of accepting any terminal record.
    public var closedTurnNumbers: Set<Int>
    /// Timestamp (epoch milliseconds) of the last `turn/start` / `turn/end`.
    public var lastTurnBoundaryTimeMillis: Int64?
    /// Timestamp (epoch milliseconds) of the last `turn/end`.
    public var lastTurnEndTimeMillis: Int64?
    /// Timestamp (epoch milliseconds) of the last readable record.
    public var lastEventTimeMillis: Int64?
    /// Whether the journal contains at least one `turn/start`.
    public var sawTurnStart: Bool
    /// Whether the journal contains at least one `turn/end`.
    public var sawTurnEnd: Bool

    public init(sessionID: String? = nil,
                parentSessionID: String? = nil,
                origin: String? = nil,
                delegationDepth: Int? = nil,
                headerCreatedAtMillis: Int64? = nil,
                openTurn: Int? = nil,
                lastRecordType: String? = nil,
                lastTurnEndReason: String? = nil,
                lastTurnEndTurn: Int? = nil,
                closedTurnNumbers: Set<Int> = [],
                lastTurnBoundaryTimeMillis: Int64? = nil,
                lastTurnEndTimeMillis: Int64? = nil,
                lastEventTimeMillis: Int64? = nil,
                sawTurnStart: Bool = false,
                sawTurnEnd: Bool = false) {
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.origin = origin
        self.delegationDepth = delegationDepth
        self.headerCreatedAtMillis = headerCreatedAtMillis
        self.openTurn = openTurn
        self.lastRecordType = lastRecordType
        self.lastTurnEndReason = lastTurnEndReason
        self.lastTurnEndTurn = lastTurnEndTurn
        self.closedTurnNumbers = closedTurnNumbers
        self.lastTurnBoundaryTimeMillis = lastTurnBoundaryTimeMillis
        self.lastTurnEndTimeMillis = lastTurnEndTimeMillis
        self.lastEventTimeMillis = lastEventTimeMillis
        self.sawTurnStart = sawTurnStart
        self.sawTurnEnd = sawTurnEnd
    }

    /// A turn is open until its `turn/end` record is journaled.
    public var isTurnOpen: Bool { openTurn != nil }

    /// The journal ends on a terminal turn record (a `turn/end` and no later
    /// `turn/start`).
    public var hasTerminalTurn: Bool { sawTurnEnd && openTurn == nil }

    /// Whether the journal's terminal `turn/end` actually closes
    /// `expectedTurn`, not merely whichever earlier turn happened to survive a
    /// torn/regressed tail.
    ///
    /// The journaled `turn` numbers are authoritative when present. The drain
    /// may observe turn N open and the Worker may then finish N and consume a
    /// pending prompt into N+1 before the journal is read, so the tail names
    /// N+1. ``closedTurnNumbers`` proves N was closed in that case. A journal
    /// without turn numbers (older layout) falls back to the observed
    /// `turn/start` timestamp: the terminal boundary must not predate the turn
    /// the drain saw open.
    ///
    /// - Parameters:
    ///   - expectedTurn: the turn number observed open when escalation began.
    ///   - openedAtMillis: `lastTurnBoundaryTimeMillis` of that open turn.
    /// - Returns: `true` only when this state closes the expected turn.
    public func hasTerminalTurn(closing expectedTurn: Int,
                                openedAtMillis: Int64? = nil) -> Bool {
        guard hasTerminalTurn else { return false }
        if closedTurnNumbers.contains(expectedTurn) { return true }
        if let lastTurnEndTurn {
            // Turn numbers are monotonic. A terminal tail that already names a
            // later turn also proves the earlier observed turn closed. The
            // regressed-tail case (last end is an *older* turn) still fails.
            return lastTurnEndTurn >= expectedTurn
        }
        guard let openedAtMillis, let endedAt = lastTurnEndTimeMillis else {
            return false
        }
        return endedAt >= openedAtMillis
    }
}

/// The open turn an escalation observed before it terminated the Worker.
///
/// The drain stores this when it enters escalation and requires the
/// materialized journal to contain a `turn/end` for exactly this turn. A later
/// turn may also have closed (the Worker consumed a pending prompt before the
/// journal was read); the earlier closer is still durable evidence. Checking
/// only `hasTerminalTurn` would accept a journal truncated back to an older
/// completed turn, turning an interrupted turn into a silent "completed"
/// drain.
struct PhoneDSHExpectedTerminalTurn: Equatable, Sendable {
    /// The turn number that was open when the escalation began.
    let turn: Int
    /// Its `turn/start` timestamp, used when `turn/end` omits `turn`.
    let openedAtMillis: Int64?

    init(turn: Int, openedAtMillis: Int64? = nil) {
        self.turn = turn
        self.openedAtMillis = openedAtMillis
    }

    /// Whether `state` carries the terminal record that closes this turn.
    func isClosed(by state: PhoneDSHSessionTurnState?) -> Bool {
        state?.hasTerminalTurn(closing: turn,
                               openedAtMillis: openedAtMillis) == true
    }
}

/// Read-only view of the materialized DSH session journals.
public enum PhoneDSHSessionLog {
    /// Whether `name` is a DSH session journal file name (`session.v4.jsonl`,
    /// and any later version DSH writes).
    public static func isSessionLogFile(_ name: String) -> Bool {
        name.hasPrefix("session.") && name.hasSuffix(".jsonl")
    }

    /// Parses one journal's turn boundaries. Malformed or torn lines are
    /// skipped: the caller only needs the last durably readable boundary.
    public static func state(of data: Data) -> PhoneDSHSessionTurnState {
        var remainder = data
        return advance(state: PhoneDSHSessionTurnState(), data: &remainder)
    }

    /// Applies every complete JSONL record in `data` to `state` and leaves the
    /// incomplete tail (bytes after the last newline) in `data`.
    ///
    /// DSH session journals are append-only. The abort drain uses this to parse
    /// only the bytes appended since the previous poll instead of re-reading a
    /// journal up to the 64 MiB `budgets.md` bound every 50 ms.
    static func advance(state: PhoneDSHSessionTurnState,
                        data: inout Data) -> PhoneDSHSessionTurnState {
        var state = state
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            apply(line: data[start..<newline], to: &state)
            start = data.index(after: newline)
        }
        if start > data.startIndex {
            data = Data(data[start...])
        }
        return state
    }

    /// Applies one JSONL line. A malformed or torn line is ignored: the caller
    /// only needs the last durably readable turn boundary.
    private static func apply(line: Data.SubSequence,
                              to state: inout PhoneDSHSessionTurnState) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
              let record = object as? [String: Any],
              let type = record["type"] as? String else {
            return
        }
        state.lastRecordType = type
        if let time = (record["time"] as? NSNumber)?.int64Value {
            state.lastEventTimeMillis = time
        }
        if type == "session" {
            state.sessionID = record["id"] as? String ?? state.sessionID
            // The physical JSONL header carries the durable lineage. A child
            // session is `origin: "subagent"` with the parent session id; the
            // teardown verifier follows that chain instead of assuming every
            // journal below `sessions/` belongs to this host incarnation.
            state.parentSessionID = record["parentSession"] as? String
            state.origin = record["origin"] as? String
            state.delegationDepth = (record["delegationDepth"] as? NSNumber)?.intValue
            state.headerCreatedAtMillis = (record["createdAt"] as? NSNumber)?.int64Value
            return
        }
        let body = record["data"] as? [String: Any]
        switch type {
        case "turn/start":
            let turn = (body?["turn"] as? NSNumber)?.intValue
                ?? max(1, state.openTurn ?? 1)
            state.openTurn = turn
            state.sawTurnStart = true
            if let time = (record["time"] as? NSNumber)?.int64Value {
                state.lastTurnBoundaryTimeMillis = time
            }
        case "turn/end":
            state.openTurn = nil
            state.sawTurnEnd = true
            state.lastTurnEndReason = (body?["reason"] as? [String: Any])?["kind"] as? String
            if let endedTurn = (body?["turn"] as? NSNumber)?.intValue {
                state.lastTurnEndTurn = endedTurn
                state.closedTurnNumbers.insert(endedTurn)
            } else {
                state.lastTurnEndTurn = nil
            }
            if let time = (record["time"] as? NSNumber)?.int64Value {
                state.lastTurnBoundaryTimeMillis = time
                state.lastTurnEndTimeMillis = time
            }
        default:
            break
        }
    }

    /// Reads every session journal below the materialized `home/sessions/`
    /// tree, keyed by session id.
    ///
    /// - Parameters:
    ///   - directory: the materialized `home/sessions` directory.
    ///   - sessionIDs: when present, only sessions this host incarnation
    ///     handed to the Worker are read. A journal left open by an earlier
    ///     crashed boot must not be treated as this host's live turn.
    ///   - cache: optional incremental state cache. The abort drain polls this
    ///     method every 50 ms; with the cache an unchanged journal is never
    ///     re-read, so a session log up to the 64 MiB `budgets.md` bound costs
    ///     one stat instead of a full read per poll.
    public static func states(inSessionsDirectory directory: URL,
                              including sessionIDs: Set<String>? = nil,
                              fileManager: FileManager = .default,
                              cache: PhoneDSHJournalStateCache? = nil) -> [String: PhoneDSHSessionTurnState] {
        guard let workspaces = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return [:]
        }
        var states: [String: PhoneDSHSessionTurnState] = [:]
        for workspace in workspaces {
            guard (try? workspace.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let sessionDirectories = try? fileManager.contentsOfDirectory(
                    at: workspace,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]) else {
                continue
            }
            for sessionDirectory in sessionDirectories {
                guard (try? sessionDirectory.resourceValues(
                    forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let files = try? fileManager.contentsOfDirectory(
                        at: sessionDirectory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]) else {
                    continue
                }
                // DSH names the session directory after the session id. Skip
                // an inactive directory before reading its (possibly large)
                // log; only ids this host handed to the Worker can be live.
                if let sessionIDs,
                   !sessionIDs.contains(sessionDirectory.lastPathComponent) {
                    continue
                }
                // A migrated workspace may carry several versions; the
                // highest version (last by name) is the journal DSH appends to.
                guard let journal = files
                    .filter({ isSessionLogFile($0.lastPathComponent) })
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                    .last else {
                    continue
                }
                let freshState: PhoneDSHSessionTurnState
                if let cache {
                    guard let cached = cache.state(forJournalAt: journal,
                                                   fileManager: fileManager) else { continue }
                    freshState = cached
                } else {
                    guard let data = try? Data(contentsOf: journal) else { continue }
                    freshState = state(of: data)
                }
                var state = freshState
                let id = state.sessionID ?? sessionDirectory.lastPathComponent
                if let sessionIDs, !sessionIDs.contains(id) { continue }
                state.sessionID = id
                states[id] = state
            }
        }
        return states
    }
}

/// Incremental parse cache for the materialized DSH session journals.
///
/// The abort drain polls `PhoneDSHSessionLog.states` every 50 ms while it waits
/// for a terminal `turn/end`; DSH only appends to these files, so a journal
/// whose size and mtime are unchanged cannot have changed its turn state, and a
/// journal that only grew can be advanced by parsing its tail. The cache keeps
/// the last parsed state, the number of bytes already read and the incomplete
/// trailing line per journal, so a 64 MiB journal costs one stat per poll and
/// only the appended bytes are read when it grows. Truncation, replacement or a
/// same-size rewrite falls back to a full read.
///
/// It never writes a journal (Swift must not fabricate DSH session records); it
/// is only a read optimization. The type is safe to share: an `NSLock` guards
/// the entry table; the incremental read and parse happen under the lock so two
/// concurrent polls cannot interleave a stale prefix into the cache.
public final class PhoneDSHJournalStateCache: @unchecked Sendable {
    private struct Entry {
        /// The size/mtime the last read observed (the poll's stat snapshot).
        var fileSize: Int
        var modified: Date?
        /// Bytes read from the journal so far, including `pendingTail`.
        var readBytes: Int
        /// The incomplete line after the last newline, kept for the next append.
        var pendingTail: Data
        var state: PhoneDSHSessionTurnState
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Creates an empty cache.
    public init() {}

    /// The cached turn state of `journal`, updated from the appended bytes only
    /// when the file grew since the previous poll. Returns `nil` when the
    /// journal cannot be stat-ed or read.
    public func state(forJournalAt journal: URL,
                      fileManager: FileManager = .default) -> PhoneDSHSessionTurnState? {
        guard let values = try? journal.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize else {
            return nil
        }
        let modified = values.contentModificationDate
        lock.lock()
        defer { lock.unlock() }
        let previous = entries[journal.path]
        if let previous,
           previous.fileSize == fileSize,
           previous.modified == modified {
            return previous.state
        }
        // Append-only fast path. Requiring growth past the previously observed
        // size (not just past the bytes read) also catches a truncate+rewrite
        // whose result happens to be larger than the read cursor.
        if let previous,
           fileSize > previous.fileSize,
           fileSize > previous.readBytes,
           let handle = try? FileHandle(forReadingFrom: journal) {
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(previous.readBytes))
                let expected = fileSize - previous.readBytes
                let appended = try handle.read(upToCount: expected) ?? Data()
                var data = previous.pendingTail
                data.append(appended)
                let state = PhoneDSHSessionLog.advance(state: previous.state, data: &data)
                entries[journal.path] = Entry(
                    fileSize: fileSize,
                    modified: modified,
                    readBytes: previous.readBytes + appended.count,
                    pendingTail: data,
                    state: state)
                return state
            } catch {
                // The append could not be read; fall back to a full read.
            }
        }
        guard let data = try? Data(contentsOf: journal) else { return nil }
        var remainder = data
        let state = PhoneDSHSessionLog.advance(state: PhoneDSHSessionTurnState(),
                                               data: &remainder)
        entries[journal.path] = Entry(
            fileSize: fileSize,
            modified: modified,
            readBytes: data.count,
            pendingTail: remainder,
            state: state)
        return state
    }

    /// Drops every cached state (for tests and for a boot-id change).
    public func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

// MARK: - Live session registry

/// The session ids this host incarnation handed to the Worker.
///
/// Prompt times let the drain tell "a turn is open" from "an accepted prompt
/// has not opened its turn yet" without guessing from the journal alone.
actor PhoneDSHSessionTracker {
    private var sessions: [String: Date] = [:]

    /// Records a session the Worker acknowledged (a `session/create` result or
    /// an explicit resume id). It is not yet prompted.
    func noteSession(_ sessionID: String) {
        if sessions[sessionID] == nil { sessions[sessionID] = .distantPast }
    }

    /// Records the time of the last `session/prompt` the Worker accepted.
    func notePrompt(sessionID: String, at date: Date) {
        sessions[sessionID] = date
    }

    struct Snapshot: Sendable {
        var sessionIDs: Set<String>
        var promptTimes: [String: Date]
    }

    func snapshot() -> Snapshot {
        Snapshot(sessionIDs: Set(sessions.keys), promptTimes: sessions)
    }
}

/// The transparent transport wrapper that records session ids for the drain.
///
/// It forwards every call, mux and authentication operation to the landed
/// `ChannelDSHTransport`; it only observes the public remote envelopes that
/// carry a session id (`session/create`, `session/prompt`).
actor PhoneDSHTrackedTransport: DSHRemoteTransport {
    private let base: any DSHRemoteTransport
    private let tracker: PhoneDSHSessionTracker

    init(base: any DSHRemoteTransport, tracker: PhoneDSHSessionTracker) {
        self.base = base
        self.tracker = tracker
    }

    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        let request = args["request"]
        // The prompt time is taken before the call: an accepted prompt opens
        // its turn after this instant, so a `turn/end` timestamp later than it
        // proves the turn completed rather than being still queued.
        let promptStartedAt = endpoint == "session/prompt" ? Date() : nil
        let value = try await base.call(endpoint, args: args)
        switch endpoint {
        case "session/create":
            if let id = value["sessionId"]?.stringValue {
                await tracker.noteSession(id)
            }
            if let id = request?["sessionId"]?.stringValue {
                await tracker.noteSession(id)
            }
        case "session/page":
            // Reopening a persisted session validates its address without
            // creating a new one. Keep it visible to lifecycle reconciliation.
            if request?["address"]?["kind"]?.stringValue == "session",
               let id = request?["address"]?["sessionId"]?.stringValue {
                await tracker.noteSession(id)
            }
        case "session/prompt":
            if let id = request?["sessionId"]?.stringValue {
                await tracker.notePrompt(sessionID: id, at: promptStartedAt ?? Date())
            }
        default:
            break
        }
        return value
    }

    func openMux() async throws -> any DSHMuxConnection {
        try await base.openMux()
    }

    func authenticationFailed() async {
        await base.authenticationFailed()
    }
}

extension PhoneDSHTrackedTransport: PhoneDSHWorkerCommandCalling {
    /// Forward one Worker command acceptance request to the channel transport.
    /// The wrapper observes session envelopes only; the command route is not a
    /// session call, so it is passed through unchanged.
    func executeWorkerCommand(_ request: PhoneDSHWorkerCommandRequest) async throws
        -> PhoneDSHWorkerCommandReceipt {
        guard let worker = base as? any PhoneDSHWorkerCommandCalling else {
            throw PhoneDSHError.invalidState(
                "the active transport has no Worker command acceptance path")
        }
        return try await worker.executeWorkerCommand(request)
    }
}

extension PhoneDSHTrackedTransport: PhoneDSHDescendantDrainCalling {
    /// The tracked wrapper always conforms; the capability belongs to the
    /// channel it wraps. This lets the host always offer the scoped call for a
    /// real channel while still tolerating a scripted/legacy base.
    func supportsDescendantDrain() async -> Bool {
        guard let worker = base as? any PhoneDSHDescendantDrainCalling else {
            return false
        }
        return await worker.supportsDescendantDrain()
    }

    /// Forward the scoped descendant drain to the active channel transport.
    /// The wrapper observes session envelopes only; this route is not a
    /// session call, so it is passed through unchanged.
    func drainDescendantSessions(_ request: PhoneDSHDescendantDrainRequest) async throws
        -> PhoneDSHDescendantDrainReceipt {
        guard let worker = base as? any PhoneDSHDescendantDrainCalling else {
            throw PhoneDSHError.invalidState(
                "the active transport has no scoped descendant-drain path")
        }
        return try await worker.drainDescendantSessions(request)
    }
}

extension PhoneDSHTrackedTransport: PhoneDSHRecoveryCalling {
    func reconcileSessionForRecovery(_ sessionID: String) async throws {
        guard let recovery = base as? any PhoneDSHRecoveryCalling else {
            throw PhoneDSHError.invalidState(
                "the active transport has no recovery write-open path")
        }
        try await recovery.reconcileSessionForRecovery(sessionID)
    }

    func reconcileSessionForRecovery(_ sessionID: String,
                                     budget: PhoneDSHRecoveryBudget) async throws {
        guard let recovery = base as? any PhoneDSHRecoveryCalling else {
            throw PhoneDSHError.invalidState(
                "the active transport has no recovery write-open path")
        }
        try await recovery.reconcileSessionForRecovery(sessionID, budget: budget)
    }

    func resumeSessionForRecovery(_ sessionID: String,
                                  budget: PhoneDSHRecoveryBudget) async throws {
        guard let recovery = base as? any PhoneDSHRecoveryCalling else {
            throw PhoneDSHError.invalidState(
                "the active transport has no DSH resume/repair path")
        }
        try await recovery.resumeSessionForRecovery(sessionID, budget: budget)
    }
}

// MARK: - Bounded await

/// One-shot completion claim shared by the operation and its deadline.
private final class PhoneDSHDeadlineClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// The operation task of ``phoneDSHResultWithinDeadline``, installed after the
/// task starts. Cancelling the caller before installation is remembered and
/// applied as soon as the task exists.
private final class PhoneDSHDeadlineOperationTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Awaits `operation` for at most `seconds`.
///
/// - Returns: the operation's result, `nil` when the deadline expired first.
///
/// The operation is cancelled at the deadline and when the caller is cancelled;
/// the caller's cancellation also cancels the operation task so a stop hook can
/// unwind instead of running on after the handoff was abandoned. A transport
/// call stuck in a pending response stream drains when the channel is torn down;
/// it is never awaited again, so it cannot hold the drain open past its window.
/// The bounded window still applies if the operation ignores cancellation.
func phoneDSHResultWithinDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async -> Result<T, Error>? {
    guard seconds > 0 else { return nil }
    let claim = PhoneDSHDeadlineClaim()
    let operationTask = PhoneDSHDeadlineOperationTask()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>?, Never>) in
            let started = Task {
                let result: Result<T, Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                if claim.claim() { continuation.resume(returning: result) }
            }
            operationTask.install(started)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                started.cancel()
                if claim.claim() { continuation.resume(returning: nil) }
            }
        }
    } onCancel: {
        operationTask.cancel()
    }
}
