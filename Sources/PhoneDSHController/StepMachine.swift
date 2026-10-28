// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: per-step state machine.
//
// PLAN §2.4 (D13/D20) and spec/v1/exec.md §4. The App observes and
// persists one record per tool call. Worker-local `bash -c` steps record
// exactly `tool_dispatched -> wal_written -> journaled`; host-executed
// read-only accelerators record all seven progress states. `abandoned` is the
// terminal owner record when the host gives up an interrupted step. Transitions are monotonic:
// a repeated state is ignored and a forward gap is never guessed.
//
// Storage follows exec.md §4 (`steps/<session_id>.ndjson`, append + fsync). The
// snapshot is persisted under `steps/<session_id>/<step_key>.json` (D20: the
// journal idempotency key is the step identity; the decimal `step_id` is
// informational and may be absent on the wire), so boot reconcile can
// reconstruct a step without replaying the whole log. Both files are written
// only by the App, after D6 validation of every identifier used in a path.

import Foundation
import CoreFoundation
import PhoneDSHLog
import PhoneDSHWire

/// Errors of ``StepMachine``.
public enum StepMachineError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidStepID(String)
    case outOfOrder(from: StepState, to: StepState)
    case missingRecord(sessionID: String, stepID: String)
    case corruptRecord(String)
}

/// One persisted step record (D13). `history` is the recorded transition
/// sequence, in order, so tests and reconcile can verify the evidence path.
public struct StepRecord: Codable, Equatable, Sendable {
    public var version: Int
    public var sessionID: String
    /// The informational decimal D20 ordinal. It is absent from real
    /// tool-journal records (and therefore from key-only step records); the
    /// step is located by ``stepKey``.
    public var stepID: String?
    public var turnID: String?
    public var state: StepState
    public var updatedAtMilliseconds: Int64
    public var mseq: UInt64?
    public var jseq: UInt64?
    public var execID: String?
    public var idemKey: String?
    public var history: [StepState]
    /// Why the host abandoned this step (`state == .abandoned`). Optional so
    /// records written before the terminal state remain readable.
    public var settledReason: String?
    /// Per-EXEC_REQ evidence for accelerators spawned under one D20 tool key.
    /// Optional so existing snapshots and log lines remain readable.
    public var execEvidence: [String: StepExecEvidence]?
    public var checkpointJseq: UInt64?
    public var completionJseq: UInt64?

    /// The D20 step identity used by the journal, the exec dedup table and the
    /// snapshot path: `XL_IDEMPOTENCY_KEY` (`xl1-<32hex>`) when the journal
    /// supplied it, otherwise the informational decimal ordinal of a legacy
    /// record.
    public var stepKey: String {
        idemKey ?? stepID ?? ""
    }

    public init(version: Int = 1, sessionID: String, stepID: String? = nil,
                turnID: String? = nil,
                state: StepState, updatedAtMilliseconds: Int64,
                mseq: UInt64? = nil, jseq: UInt64? = nil, execID: String? = nil,
                idemKey: String? = nil, history: [StepState] = [],
                settledReason: String? = nil,
                execEvidence: [String: StepExecEvidence]? = nil,
                checkpointJseq: UInt64? = nil, completionJseq: UInt64? = nil) {
        self.version = version
        self.sessionID = sessionID
        self.stepID = stepID
        self.turnID = turnID
        self.state = state
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.mseq = mseq
        self.jseq = jseq
        self.execID = execID
        self.idemKey = idemKey
        self.history = history
        self.settledReason = settledReason
        self.execEvidence = execEvidence
        self.checkpointJseq = checkpointJseq
        self.completionJseq = completionJseq
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case sessionID = "session_id"
        case stepID = "step_id"
        case turnID = "turn_id"
        case state
        case updatedAtMilliseconds = "at_ms"
        case mseq
        case jseq
        case execID = "exec_id"
        case idemKey = "idem_key"
        case history
        case settledReason = "settled_reason"
        case execEvidence = "exec_evidence"
        case checkpointJseq = "checkpoint_jseq"
        case completionJseq = "completion_jseq"
    }
}

/// Durable evidence for one accelerator exec under a D20 tool call.
public struct StepExecEvidence: Codable, Equatable, Sendable {
    public var requiresMseq: UInt64
    public var started: Bool
    public var terminal: Bool
    public var walAcknowledged: Bool
    public var persistenceFailed: Bool

    public init(requiresMseq: UInt64, started: Bool = false,
                terminal: Bool = false, walAcknowledged: Bool = false,
                persistenceFailed: Bool = false) {
        self.requiresMseq = requiresMseq
        self.started = started
        self.terminal = terminal
        self.walAcknowledged = walAcknowledged
        self.persistenceFailed = persistenceFailed
    }

    enum CodingKeys: String, CodingKey {
        case requiresMseq = "requires_mseq"
        case started
        case terminal
        case walAcknowledged = "wal_acknowledged"
        case persistenceFailed = "persistence_failed"
    }
}

/// One line of `steps/<session_id>.ndjson` (exec.md §4).
struct StepLogLine: Codable, Equatable {
    var version: Int
    var stepID: String?
    var turnID: String?
    var state: StepState
    var updatedAtMilliseconds: Int64
    var mseq: UInt64?
    var jseq: UInt64?
    var execID: String?
    var idemKey: String?
    /// Optional `settled_reason` of a terminal `abandoned` record. Missing on
    /// every pre-existing line and on ordinary journaled steps.
    var settledReason: String?
    var execEvidence: [String: StepExecEvidence]?
    var checkpointJseq: UInt64?
    var completionJseq: UInt64?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case stepID = "step_id"
        case turnID = "turn_id"
        case state
        case updatedAtMilliseconds = "at_ms"
        case mseq
        case jseq
        case execID = "exec_id"
        case idemKey = "idem_key"
        case settledReason = "settled_reason"
        case execEvidence = "exec_evidence"
        case checkpointJseq = "checkpoint_jseq"
        case completionJseq = "completion_jseq"
    }
}

/// The three D20 tool-call transitions of a worker-local command.
public let workerLocalStepPath: [StepState] = [.toolDispatched, .walWritten, .journaled]

/// The seven transitions of a host-executed accelerator.
public let acceleratorStepPath: [StepState] = [
    .modelStreaming, .toolDispatched, .execRunning, .exitPersisted,
    .checkpointApplied, .walWritten, .journaled,
]

extension StepState {
    /// Position in the D13 order, 1-based. The terminal `abandoned` state is
    /// ordered after `journaled` so a snapshot cannot regress a step the host
    /// already gave up.
    public var order: Int {
        switch self {
        case .modelStreaming: return 1
        case .toolDispatched: return 2
        case .execRunning: return 3
        case .exitPersisted: return 4
        case .checkpointApplied: return 5
        case .walWritten: return 6
        case .journaled: return 7
        case .abandoned: return 8
        }
    }

    /// The next state of the accelerator path, `nil` for either terminal state.
    var next: StepState? {
        switch self {
        case .modelStreaming: return .toolDispatched
        case .toolDispatched: return .execRunning
        case .execRunning: return .exitPersisted
        case .exitPersisted: return .checkpointApplied
        case .checkpointApplied: return .walWritten
        case .walWritten: return .journaled
        case .journaled, .abandoned: return nil
        }
    }
}

/// The journal record fields the host needs (exec.md §4, tool-journal view).
///
/// The tool-journal writes its local record first (field `t`:
/// `start`/`executed`/`done`/`resolved`) and the 0x30 wire projection adds a
/// `type` field (`dispatched`/`executed`/`completed`/`resolved`), keeping `t`
/// (plugins/tool-journal/src/journal.ts, `wireRecord`). Real records carry
/// `key` = `XL_IDEMPOTENCY_KEY` and no `turn_id`/`step_id`; the decimal ordinal
/// is optional D20 information, accepted when a legacy fixture supplies it.
struct JournalSignal {
    enum Kind: Equatable {
        case header
        case dispatched
        case executed
        case completed
        case resolved
        case unknown
    }

    var kind: Kind
    /// The raw kind, kept for diagnostics so an unknown shape is reportable.
    var rawKind: String
    var turnID: String?
    var stepID: String?
    var execID: String?
    var toolKey: String?
    /// Only producer-shaped terminal records are allowed to checkpoint an
    /// accelerator step. A type/key pair alone is not a result receipt.
    var checkpointAuthority: Bool

    init(record: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: record),
              let dictionary = object as? [String: Any] else {
            throw StepMachineError.corruptRecord("journal record is not a JSON object")
        }
        let wireType = Self.string(dictionary["type"])
        let localType = Self.string(dictionary["t"])
        let rawType = wireType ?? localType ?? ""
        rawKind = rawType
        // `type` is the wire projection and wins when both fields are present;
        // `t` alone is accepted for records copied from the tool-journal source
        // tests (journal.test.ts).
        switch rawType {
        case "header": kind = .header
        case "dispatched", "start": kind = .dispatched
        case "executed": kind = .executed
        case "completed", "done": kind = .completed
        case "resolved": kind = .resolved
        default: kind = .unknown
        }
        turnID = Self.string(dictionary["turn_id"])
        stepID = Self.stepID(dictionary["step_id"])
        execID = Self.string(dictionary["exec_id"])
        toolKey = Self.string(dictionary["key"]) ?? Self.string(dictionary["XL_IDEMPOTENCY_KEY"])
        checkpointAuthority = Self.isCheckpointAuthority(
            dictionary: dictionary, localType: localType, wireType: wireType)
    }

    private static func isCheckpointAuthority(dictionary: [String: Any],
                                              localType: String?,
                                              wireType: String?) -> Bool {
        guard (dictionary["v"] as? Int) == 1,
              let callID = string(dictionary["call_id"]), !callID.isEmpty,
              callID.utf8.count <= 512, !callID.contains("\0"),
              isJSONNumber(dictionary["at"]) else { return false }
        switch localType {
        case "done":
            guard wireType == nil || wireType == "completed",
                  isJournaledResult(dictionary["result"]) else { return false }
            return true
        case "resolved":
            guard wireType == nil || wireType == "resolved",
                  let action = string(dictionary["action"]),
                  ["backfilled-done", "backfilled-executed", "rerun", "unknown"]
                    .contains(action) else { return false }
            if let detail = dictionary["detail"], !(detail is String) { return false }
            return true
        default:
            return false
        }
    }

    private static func isJournaledResult(_ value: Any?) -> Bool {
        guard let result = value as? [String: Any],
              result["content"] is [Any],
              let isError = result["isError"] as? NSNumber,
              CFGetTypeID(isError) == CFBooleanGetTypeID() else { return false }
        if let error = result["error"] {
            guard let details = error as? [String: Any],
                  let name = details["name"] as? String, !name.isEmpty,
                  let code = details["code"] as? String, !code.isEmpty else { return false }
            if let reason = details["reason"], !(reason is String) { return false }
        }
        return true
    }

    private static func isJSONNumber(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        return nil
    }

    private static func stepID(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            // JSON booleans decode as NSNumber too; only integer ordinals count.
            let doubleValue = number.doubleValue
            guard doubleValue.rounded() == doubleValue, doubleValue >= 1 else { return nil }
            return String(number.int64Value)
        }
        return nil
    }
}

/// One parsed exec-bridge v1 NDJSON event (exec.md §3).
struct ExecSignal {
    enum Kind: Equatable {
        case start
        case terminal
        case other
    }

    var kind: Kind
    var execID: String?

    init(event: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: event),
              let dictionary = object as? [String: Any] else {
            throw StepMachineError.corruptRecord("exec event is not a JSON object")
        }
        let type = (dictionary["type"] as? String) ?? ""
        switch type {
        case "start": kind = .start
        case "exit", "error": kind = .terminal
        default: kind = .other
        }
        execID = dictionary["exec_id"] as? String
    }
}

/// Severity of a controller log line.
public enum ControllerLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

/// Minimal logging seam of the controller. The facade can bridge this to
/// `PhoneDSHDiagnostics`; the controller does not depend on the facade.
public protocol ControllerLogging: Sendable {
    func log(_ level: ControllerLogLevel, _ message: String)
}

/// Writes controller log lines to standard error. Deterministic tests inject
/// their own ``ControllerLogging`` implementation.
public struct StderrControllerLogger: ControllerLogging {
    public init() {}

    public func log(_ level: ControllerLogLevel, _ message: String) {
        FileHandle.standardError.write(Data(
            "[PhoneDSHController] \(level.rawValue): \(message)\n".utf8))
    }
}

/// Observable counters of what ``StepMachine`` did with the journal and exec
/// evidence. They follow the shape of the facade's `PhoneDSHDiagnostics`:
/// every observed record is accounted for, and a shape the controller does not
/// understand is visible here instead of silently disappearing.
public struct StepMachineMetrics: Equatable, Sendable {
    /// JOURNAL records observed through ``StepMachine/observeJournal``.
    public var journalRecords = 0
    /// Observations that advanced or refreshed a step record.
    public var journalRecordsApplied = 0
    /// Known non-step records, such as the tool-journal header.
    public var journalRecordsIgnored = 0
    /// Records whose shape or identity the controller could not map to a step.
    public var unknownJournalRecords = 0
    /// Records that were not a JSON object at all.
    public var malformedJournalRecords = 0
    /// EXEC_EVT observations.
    public var execEvents = 0
    /// VFS acknowledgement / checkpoint observations.
    public var walObservations = 0

    public init() {}
}

/// Per-tool-call persistence and evidence engine of D13.
public actor StepMachine {
    /// Workspace root, `Library/xl/<workspace_id>/`.
    public nonisolated let root: URL
    private let clock: any HostClock
    private let logger: any ControllerLogging
    private let stepsDirectory: URL
    private var records: [StepKey: StepRecord] = [:]
    private var order: [StepKey] = []
    private var streamingTurns: Set<TurnKey> = []
    private var storedMetrics = StepMachineMetrics()

    struct StepKey: Hashable, Sendable {
        var sessionID: String
        /// The D20 identity: the journal `key` when present, otherwise a
        /// legacy decimal `step_id`.
        var identity: String
    }

    struct TurnKey: Hashable, Sendable {
        var sessionID: String
        var turnID: String
    }

    /// Opens the step store and loads every complete record for reconcile.
    /// A torn final NDJSON line is ignored (exec.md §4).
    public init(root: URL, clock: any HostClock = SystemHostClock(),
                logger: any ControllerLogging = StderrControllerLogger()) throws {
        self.root = root
        self.clock = clock
        self.logger = logger
        self.stepsDirectory = root.appendingPathComponent("steps", isDirectory: true)
        try ControllerFileStore.ensureDirectory(stepsDirectory)
        let loaded = try Self.loadFromDisk(stepsDirectory: stepsDirectory)
        self.records = loaded.records
        self.order = loaded.order
    }

    /// The accounting counters of this boot.
    public func metrics() -> StepMachineMetrics { storedMetrics }

    /// Alias of ``metrics()`` matching the facade diagnostics vocabulary:
    /// every observed journal record is accounted for, including shapes the
    /// controller could not map.
    public func diagnostics() -> StepMachineMetrics { storedMetrics }

    // MARK: - Journal evidence

    /// Applies one JOURNAL frame body (0x30). The session id comes from the
    /// frame body (``JournalBody/sessionID``); the step is located by the
    /// record's D20 `key` (`xl1-<32hex>`), not by a turn/step ordinal.
    @discardableResult
    public func observeJournal(_ body: JournalBody) async throws -> StepRecord? {
        try await observeJournal(sessionID: body.sessionID, jseq: body.jseq,
                                 record: body.record)
    }

    /// Applies one JOURNAL record (0x30).
    ///
    /// Real tool-journal records carry `key` = `XL_IDEMPOTENCY_KEY` and no
    /// `turn_id`/`step_id` (PLAN D20 amended): the key is the step identity and
    /// the snapshot is written to `steps/<session_id>/<step_key>.json`. Records
    /// copied from the journal source tests that only carry `t` are accepted as
    /// the same wire projection. A record that cannot be mapped to a step is
    /// counted in ``metrics()`` and logged; it is never silently dropped.
    @discardableResult
    public func observeJournal(sessionID: String, jseq: UInt64,
                               record: Data) async throws -> StepRecord? {
        storedMetrics.journalRecords += 1
        let signal: JournalSignal
        do {
            signal = try JournalSignal(record: record)
        } catch {
            storedMetrics.malformedJournalRecords += 1
            logger.log(.warning,
                       "JOURNAL session \(sessionID) jseq \(jseq) is not a JSON object")
            throw error
        }

        if signal.kind == .header {
            storedMetrics.journalRecordsIgnored += 1
            logger.log(.debug,
                       "JOURNAL header session \(sessionID) jseq \(jseq) is not step evidence")
            return nil
        }

        // D20 identity: the journal key when present. The decimal
        // (turn_id, step_id) pair is accepted only as legacy information from
        // fixtures copied from the tool-journal tests.
        let identity: String
        if let stepKey = signal.toolKey {
            try validate(sessionID: sessionID)
            try validateStepKey(stepKey)
            identity = stepKey
        } else if let turnID = signal.turnID, let stepID = signal.stepID {
            try validate(sessionID: sessionID, turnID: turnID, stepID: stepID)
            identity = stepID
        } else {
            storedMetrics.unknownJournalRecords += 1
            logger.log(.warning,
                       "unknown JOURNAL shape session \(sessionID) jseq \(jseq): " +
                       "kind '\(signal.rawKind)' has no D20 key")
            return nil
        }

        let key = StepKey(sessionID: sessionID, identity: identity)
        if let terminal = records[key], terminal.state.isTerminal {
            // A terminal step is immutable: late or replayed journal evidence
            // must never turn an abandoned step back into a journaled one.
            storedMetrics.journalRecordsApplied += 1
            return terminal
        }
        if signal.kind == .unknown {
            storedMetrics.unknownJournalRecords += 1
            logger.log(.warning,
                       "unrecognized JOURNAL record kind '\(signal.rawKind)' " +
                       "session \(sessionID) jseq \(jseq) key \(identity)")
            return records[key]
        }

        let turnID = signal.turnID
        switch signal.kind {
        case .header, .unknown:
            return records[key]

        case .dispatched:
            var record = try recordOrCreate(key: key, turnID: turnID,
                                            stepID: signal.stepID,
                                            execID: signal.execID,
                                            idemKey: signal.toolKey)
            if let turnID,
               streamingTurns.contains(TurnKey(sessionID: sessionID, turnID: turnID)),
               record.history.isEmpty {
                // Turn-level model streaming evidence is attached when the
                // dispatched record resolves the step identity (D20).
                record.history.append(.modelStreaming)
            }
            if record.state.order < StepState.toolDispatched.order {
                try advance(&record, to: .toolDispatched)
            }
            record.jseq = max(record.jseq ?? 0, jseq)
            record.execID = record.execID ?? signal.execID
            record.idemKey = record.idemKey ?? signal.toolKey
            try persist(record)
            storedMetrics.journalRecordsApplied += 1
            return record

        case .executed:
            // Tool-journal's executed record is the checkpoint evidence for a
            // host-executed accelerator; worker-local steps never cross the
            // exec/checkpoint states (D13/D20).
            guard var record = records[key], record.execID != nil else {
                storedMetrics.journalRecordsApplied += 1
                return records[key]
            }
            record.checkpointJseq = max(record.checkpointJseq ?? 0, jseq)
            if record.execEvidence?.isEmpty == false {
                try recomputeAcceleratorProgress(&record)
            } else {
                if record.state == .exitPersisted {
                    try advance(&record, to: .checkpointApplied)
                }
                try advanceWalIfReady(&record)
            }
            record.jseq = max(record.jseq ?? 0, jseq)
            try persist(record)
            storedMetrics.journalRecordsApplied += 1
            return record

        case .completed, .resolved:
            // Both the wire `completed` projection (`t: "done"`) and a
            // `resolved` record are durable evidence that the step's journal
            // entry is complete (exec.md §4).
            var record = try recordOrCreate(key: key, turnID: turnID,
                                            stepID: signal.stepID,
                                            execID: signal.execID,
                                            idemKey: signal.toolKey)
            record.execID = record.execID ?? signal.execID
            record.idemKey = record.idemKey ?? signal.toolKey
            if signal.kind == .resolved && signal.checkpointAuthority {
                record.checkpointJseq = max(record.checkpointJseq ?? 0, jseq)
                record.completionJseq = max(record.completionJseq ?? 0, jseq)
            }
            if record.execEvidence?.isEmpty == false {
                if signal.kind == .completed {
                    if signal.checkpointAuthority {
                        record.checkpointJseq = max(record.checkpointJseq ?? 0, jseq)
                    }
                    if signal.checkpointAuthority || record.checkpointJseq != nil {
                        record.completionJseq = max(record.completionJseq ?? 0, jseq)
                        try recomputeAcceleratorProgress(&record)
                    }
                } else if signal.checkpointAuthority {
                    try recomputeAcceleratorProgress(&record)
                }
            } else if signal.kind == .resolved && !signal.checkpointAuthority {
                storedMetrics.unknownJournalRecords += 1
                return records[key]
            } else if record.execID == nil {
                // Exactly the D20 worker-local path: the completed journal
                // record is the evidence for the intermediate WAL state.
                if record.state.order < StepState.toolDispatched.order {
                    try advance(&record, to: .toolDispatched)
                }
                if record.state.order < StepState.walWritten.order {
                    try advance(&record, to: .walWritten)
                }
                if record.state.order < StepState.journaled.order {
                    try advance(&record, to: .journaled)
                }
            } else if record.state.order >= StepState.walWritten.order {
                try advance(&record, to: .journaled)
            }
            // An accelerator completed record before its WAL ack is not a
            // guessable forward gap; reconcile at boot reconstructs it.
            record.jseq = max(record.jseq ?? 0, jseq)
            try persist(record)
            storedMetrics.journalRecordsApplied += 1
            return record
        }
    }

    /// Records the turn-level model streaming evidence (D20). It is attached
    /// to the step when the dispatched journal record resolves its identity.
    @discardableResult
    public func recordModelStreaming(sessionID: String,
                                     turnID: String) async throws -> StepRecord? {
        try validate(sessionID: sessionID, turnID: turnID)
        streamingTurns.insert(TurnKey(sessionID: sessionID, turnID: turnID))
        // Attach to steps of this turn that already exist.
        var last: StepRecord?
        for key in order where key.sessionID == sessionID {
            guard var record = records[key], record.turnID == turnID else { continue }
            if record.state == .modelStreaming, record.history.isEmpty {
                record.history.append(.modelStreaming)
                try persist(record)
            }
            last = record
        }
        return last
    }

    // MARK: - Exec evidence

    /// Applies one EXEC_EVT (0x21) of an accelerator step. The caller invokes
    /// this only after the event is durable in the side-effect ledger, which is
    /// the D13 evidence for `exit_persisted`.
    @discardableResult
    public func observeExecEvent(sessionID: String, turnID: String, stepID: String,
                                 execID: String, event: Data,
                                 idemKey: String? = nil) async throws -> StepRecord {
        try validate(sessionID: sessionID, turnID: turnID, stepID: stepID,
                     execID: execID)
        storedMetrics.execEvents += 1
        let signal = try ExecSignal(event: event)
        let key = try resolveStepKey(sessionID: sessionID, turnID: turnID,
                                     stepID: stepID, idemKey: idemKey)
        var record = try recordOrCreate(key: key, turnID: turnID,
                                        stepID: stepID,
                                        execID: execID, idemKey: idemKey)
        record.execID = execID
        record.idemKey = record.idemKey ?? idemKey
        switch signal.kind {
        case .start:
            if record.state.order < StepState.toolDispatched.order {
                try advance(&record, to: .toolDispatched)
            }
            if record.state.order == StepState.toolDispatched.order {
                try advance(&record, to: .execRunning)
            }
        case .terminal:
            guard record.state.order >= StepState.execRunning.order else {
                throw StepMachineError.outOfOrder(from: record.state, to: .exitPersisted)
            }
            if record.state.order == StepState.execRunning.order {
                try advance(&record, to: .exitPersisted)
            }
        case .other:
            break
        }
        try persist(record)
        return record
    }

    /// Associates the durable SideEffectLedger D20 key with its exact
    /// dispatched journal record. This does not advance execution state; it
    /// prevents later `completed` from being mistaken for worker-local proof.
    @discardableResult
    public func bindAccelerator(toolKey: String, execID: String,
                                requiresMseq: UInt64 = 0) throws -> StepRecord? {
        try validateStepKey(toolKey)
        guard let key = uniqueKey(toolKey: toolKey), var record = records[key],
              !record.state.isTerminal else { return nil }
        var evidence = record.execEvidence ?? [:]
        if let existing = evidence[execID] {
            guard existing.requiresMseq == requiresMseq else {
                throw StepMachineError.corruptRecord(
                    "requires_mseq changed for persisted exec_id \(execID)")
            }
        } else {
            evidence[execID] = StepExecEvidence(requiresMseq: requiresMseq)
        }
        record.execEvidence = evidence
        record.execID = execID
        record.idemKey = record.idemKey ?? toolKey
        try persist(record)
        return record
    }

    /// Clears a request reservation only when the provider rejected it before
    /// emitting a start event. This lets the subsequent worker-local done
    /// record close the step without leaving a false accelerator identity.
    @discardableResult
    public func releaseAccelerator(toolKey: String, execID: String) throws -> StepRecord? {
        try validateStepKey(toolKey)
        guard let key = uniqueKey(toolKey: toolKey), var record = records[key],
              !record.state.isTerminal,
              var evidence = record.execEvidence,
              let entry = evidence[execID], !entry.started,
              !entry.persistenceFailed else { return recordIfUnique(toolKey: toolKey) }
        evidence.removeValue(forKey: execID)
        record.execEvidence = evidence.isEmpty ? nil : evidence
        record.execID = evidence.keys.sorted().last
        try recomputeAcceleratorProgress(&record)
        try persist(record)
        return record
    }

    /// Retains a sticky failure for one exact exec identity. A later successful
    /// sibling exec cannot erase a ledger persistence hole from this tool call.
    @discardableResult
    public func markExecPersistenceFailure(toolKey: String, execID: String,
                                           requiresMseq: UInt64 = 0) throws -> StepRecord? {
        try validateStepKey(toolKey)
        guard let key = uniqueKey(toolKey: toolKey), var record = records[key],
              !record.state.isTerminal else { return recordIfUnique(toolKey: toolKey) }
        var evidence = record.execEvidence ?? [:]
        var entry = evidence[execID] ?? StepExecEvidence(requiresMseq: requiresMseq)
        entry.persistenceFailed = true
        evidence[execID] = entry
        record.execEvidence = evidence
        record.execID = execID
        record.idemKey = record.idemKey ?? toolKey
        try persist(record)
        return record
    }

    /// Applies an EXEC_EVT only to the exact D20 journal key. Caller must have
    /// durably appended the event to SideEffectLedger first.
    @discardableResult
    public func observeExecEvent(toolKey: String, execID: String,
                                 event: Data) throws -> StepRecord? {
        try validateStepKey(toolKey)
        guard let key = uniqueKey(toolKey: toolKey), var record = records[key],
              !record.state.isTerminal else { return recordIfUnique(toolKey: toolKey) }
        let signal = try ExecSignal(event: event)
        guard signal.execID == nil || signal.execID == execID else {
            throw StepMachineError.corruptRecord("exec_id does not match persisted intent")
        }
        storedMetrics.execEvents += 1
        var evidence = record.execEvidence ?? [:]
        var execEvidence = evidence[execID] ?? StepExecEvidence(requiresMseq: 0)
        guard !execEvidence.persistenceFailed else { return record }
        record.idemKey = record.idemKey ?? toolKey
        switch signal.kind {
        case .start:
            execEvidence.started = true
            if record.state.order < StepState.toolDispatched.order {
                try advance(&record, to: .toolDispatched)
            }
            if record.state == .toolDispatched {
                try advance(&record, to: .execRunning)
            }
        case .terminal:
            guard execEvidence.started else {
                throw StepMachineError.outOfOrder(from: record.state, to: .exitPersisted)
            }
            execEvidence.terminal = true
        case .other:
            break
        }
        evidence[execID] = execEvidence
        record.execEvidence = evidence
        record.execID = execID
        if execEvidence.terminal && execEvidence.walAcknowledged {
            try recomputeAcceleratorProgress(&record)
        }
        try persist(record)
        return record
    }

    /// Applies the read-only accelerator WAL proof to one exact exec. A zero
    /// requires_mseq is a valid no-dependency proof when ackedMseq is zero.
    @discardableResult
    public func observeAcceleratorWAL(toolKey: String, execID: String? = nil,
                                      requiresMseq: UInt64,
                                      ackedMseq: UInt64) throws -> StepRecord? {
        try validateStepKey(toolKey)
        guard ackedMseq >= requiresMseq,
              let key = uniqueKey(toolKey: toolKey), var record = records[key],
              !record.state.isTerminal else { return recordIfUnique(toolKey: toolKey) }
        var evidence = record.execEvidence ?? [:]
        let targetExecID: String
        if let execID {
            targetExecID = execID
        } else if evidence.count == 1, let only = evidence.keys.first {
            targetExecID = only
        } else {
            return record
        }
        guard var entry = evidence[targetExecID], !entry.persistenceFailed else {
            return record
        }
        guard entry.requiresMseq == requiresMseq else {
            throw StepMachineError.corruptRecord(
                "WAL requirement does not match persisted exec_id \(targetExecID)")
        }
        storedMetrics.walObservations += 1
        entry.walAcknowledged = true
        evidence[targetExecID] = entry
        record.execEvidence = evidence
        record.mseq = max(record.mseq ?? 0, requiresMseq)
        try recomputeAcceleratorProgress(&record)
        try persist(record)
        return record
    }

    private func allStartedExecsTerminal(_ evidence: [String: StepExecEvidence]) -> Bool {
        !evidence.isEmpty && evidence.values.allSatisfy {
            $0.started && $0.terminal && !$0.persistenceFailed
        }
    }

    private func recomputeAcceleratorProgress(_ record: inout StepRecord) throws {
        guard let evidence = record.execEvidence, !evidence.isEmpty,
              evidence.values.allSatisfy({ $0.started && !$0.persistenceFailed }),
              allStartedExecsTerminal(evidence),
              evidence.values.allSatisfy(\.walAcknowledged),
              let checkpointJseq = record.checkpointJseq else { return }
        if record.state == .execRunning {
            try advance(&record, to: .exitPersisted)
        }
        guard record.state.order >= StepState.exitPersisted.order else { return }
        if record.state == .exitPersisted {
            try advance(&record, to: .checkpointApplied)
        }
        try advanceWalIfReady(&record)
        if record.state == .walWritten, record.completionJseq != nil {
            try advance(&record, to: .journaled)
        }
        record.jseq = max(record.jseq ?? 0, checkpointJseq,
                          record.completionJseq ?? 0)
    }

    private func uniqueKey(toolKey: String) -> StepKey? {
        let matches = order.filter { records[$0]?.stepKey == toolKey }
        return matches.count == 1 ? matches[0] : nil
    }

    private func recordIfUnique(toolKey: String) -> StepRecord? {
        guard let key = uniqueKey(toolKey: toolKey) else { return nil }
        return records[key]
    }

    /// Records the tool-call checkpoint evidence of an accelerator step.
    @discardableResult
    public func observeCheckpoint(sessionID: String, turnID: String,
                                  stepID: String, idemKey: String? = nil) async throws -> StepRecord {
        try validate(sessionID: sessionID, turnID: turnID, stepID: stepID)
        storedMetrics.walObservations += 1
        let key = try resolveStepKey(sessionID: sessionID, turnID: turnID,
                                     stepID: stepID, idemKey: idemKey)
        guard var record = records[key] else {
            throw StepMachineError.missingRecord(sessionID: sessionID, stepID: stepID)
        }
        guard record.state.order >= StepState.exitPersisted.order else {
            throw StepMachineError.outOfOrder(from: record.state, to: .checkpointApplied)
        }
        if record.state == .exitPersisted {
            try advance(&record, to: .checkpointApplied)
        }
        try advanceWalIfReady(&record)
        try persist(record)
        return record
    }

    /// Records the WAL acknowledgement evidence (`VFS_ACK` covers `mseq`).
    @discardableResult
    public func observeWalWritten(sessionID: String, turnID: String, stepID: String,
                                  mseq: UInt64,
                                  idemKey: String? = nil) async throws -> StepRecord {
        try validate(sessionID: sessionID, turnID: turnID, stepID: stepID)
        storedMetrics.walObservations += 1
        let key = try resolveStepKey(sessionID: sessionID, turnID: turnID,
                                     stepID: stepID, idemKey: idemKey)
        guard var record = records[key] else {
            throw StepMachineError.missingRecord(sessionID: sessionID, stepID: stepID)
        }
        if record.state.order < StepState.walWritten.order {
            if record.execID != nil, record.state.order < StepState.checkpointApplied.order {
                // The D13 order requires exit_persisted and checkpoint_applied
                // first. Keep the acknowledgement as evidence and apply it
                // when the checkpoint arrives instead of guessing a gap.
                record.mseq = max(record.mseq ?? 0, mseq)
                try persist(record)
                return record
            }
            guard record.state == .toolDispatched ||
                    record.state == .checkpointApplied else {
                throw StepMachineError.outOfOrder(from: record.state, to: .walWritten)
            }
            try advance(&record, to: .walWritten)
        }
        record.mseq = max(record.mseq ?? 0, mseq)
        try persist(record)
        return record
    }

    /// Applies a WAL acknowledgement retained while the D13 order waited for
    /// the checkpoint evidence.
    private func advanceWalIfReady(_ record: inout StepRecord) throws {
        if record.state == .checkpointApplied, record.mseq != nil {
            try advance(&record, to: .walWritten)
        }
    }

    // MARK: - Queries

    /// The recorded state of one step located by the informational decimal
    /// ordinal. Records driven by the real journal key are found by scanning,
    /// because their dictionary key is the D20 key.
    public func record(sessionID: String, stepID: String) -> StepRecord? {
        if let direct = records[StepKey(sessionID: sessionID, identity: stepID)] {
            return direct
        }
        return allRecords().first {
            $0.sessionID == sessionID && $0.stepID == stepID
        }
    }

    /// Locates a step by its D20 identity key within a session.
    ///
    /// The key is `XL_IDEMPOTENCY_KEY` (`xl1-<32hex>`) when the journal
    /// supplied it; a step known only by its decimal ordinal falls back to
    /// that ordinal. The decimal `step_id` remains informational.
    public func record(sessionID: String, stepKey: String) -> StepRecord? {
        guard WireValidation.isValidIdentifier(stepKey) else { return nil }
        if let direct = records[StepKey(sessionID: sessionID, identity: stepKey)] {
            return direct
        }
        return allRecords().first {
            $0.sessionID == sessionID && $0.stepKey == stepKey
        }
    }

    /// Every loaded record, order of first observation.
    public func allRecords() -> [StepRecord] {
        order.compactMap { records[$0] }
    }

    /// Steps left incomplete at boot (D13 reconcile). A record is complete
    /// when it reached either terminal state.
    public func reconcile() -> [StepRecord] {
        allRecords().filter { !$0.state.isTerminal }
    }

    /// Gives every non-terminal step a terminal owner after the host has
    /// stopped waiting for a replacement Worker to reconcile it.
    ///
    /// The step becomes `abandoned`, its `history` records that terminal
    /// transition, and both the append-only `steps/<session>.ndjson` line and
    /// the per-step snapshot are rewritten. This is deliberately not a tool
    /// result: no `journaled` transition and no completed evidence is
    /// fabricated. A later journal record cannot revive the step.
    ///
    /// - Parameter reason: machine-readable cause stored as `settled_reason`
    ///   (for example `worker-terminated` or `drain-timeout`).
    /// - Returns: the records that this call transitioned. A second call
    ///   returns an empty array.
    @discardableResult
    public func settleOrphans(reason: String) async throws -> [StepRecord] {
        let now = clock.now.millisecondsSinceEpoch
        var settled: [StepRecord] = []
        var settledIdentities: Set<StepKey> = []
        for key in order {
            guard !settledIdentities.contains(key),
                  var record = records[key],
                  !record.state.isTerminal else { continue }
            let identity = StepKey(sessionID: record.sessionID,
                                   identity: record.stepKey)
            guard !settledIdentities.contains(identity) else { continue }
            record.state = .abandoned
            record.updatedAtMilliseconds = now
            record.settledReason = reason
            record.history.append(.abandoned)
            try persist(record)
            // A legacy record can be reachable through more than one storage
            // key; keep every in-memory alias on the same terminal record so
            // reconcile cannot report a stale alias after persistence.
            for alias in order where alias != identity
                && records[alias]?.sessionID == record.sessionID
                && records[alias]?.stepKey == record.stepKey {
                records[alias] = record
            }
            settledIdentities.insert(identity)
            settled.append(record)
        }
        return settled
    }

    /// `true` when no step is in the `exec_running` state; a planned restart
    /// or handoff may start only here (budgets.md §4).
    public var isIdle: Bool {
        !records.values.contains { $0.state == .execRunning }
    }

    // MARK: - Transition internals

    /// Resolves the dictionary key of an exec/checkpoint/WAL observation.
    /// `idemKey` (D20) wins; otherwise the record dispatched by key earlier in
    /// this session is found through its informational decimal ordinal.
    private func resolveStepKey(sessionID: String, turnID: String, stepID: String,
                                idemKey: String?) throws -> StepKey {
        if let idemKey {
            try validateStepKey(idemKey)
            return StepKey(sessionID: sessionID, identity: idemKey)
        }
        let legacy = StepKey(sessionID: sessionID, identity: stepID)
        if records[legacy] != nil { return legacy }
        if let match = order.first(where: { key in
            guard key.sessionID == sessionID, let record = records[key] else { return false }
            return record.stepID == stepID && record.turnID == turnID
        }) {
            return match
        }
        return legacy
    }

    private func recordOrCreate(key: StepKey, turnID: String?,
                                stepID: String? = nil,
                                execID: String?,
                                idemKey: String?) throws -> StepRecord {
        if let existing = records[key] { return existing }
        let record = StepRecord(sessionID: key.sessionID, stepID: stepID,
                                turnID: turnID,
                                state: .modelStreaming,
                                updatedAtMilliseconds: clock.now.millisecondsSinceEpoch,
                                execID: execID, idemKey: idemKey,
                                history: [])
        records[key] = record
        order.append(key)
        return record
    }

    /// Advances along the D13 order. Replaying an earlier or equal state is
    /// ignored; only the next state (or the documented worker-local
    /// `tool_dispatched -> wal_written -> journaled` path) is accepted.
    private func advance(_ record: inout StepRecord, to target: StepState) throws {
        guard !record.state.isTerminal else {
            throw StepMachineError.outOfOrder(from: record.state, to: target)
        }
        guard target.order > record.state.order else { return }
        let allowedNext = record.state.next
        // tool_dispatched has two valid successors: exec_running for a
        // host-executed accelerator and wal_written for a worker-local command
        // (or for an accelerator whose VFS acknowledgement arrives first).
        let walFromDispatch = record.state == .toolDispatched && target == .walWritten
        let workerLocalJoin = record.execID == nil &&
            record.state == .toolDispatched && target == .journaled
        guard target == allowedNext || walFromDispatch || workerLocalJoin else {
            throw StepMachineError.outOfOrder(from: record.state, to: target)
        }
        if workerLocalJoin, record.state.order < StepState.walWritten.order {
            record.state = .walWritten
            record.updatedAtMilliseconds = clock.now.millisecondsSinceEpoch
            record.history.append(.walWritten)
        }
        record.state = target
        record.updatedAtMilliseconds = clock.now.millisecondsSinceEpoch
        record.history.append(target)
    }

    private func persist(_ record: StepRecord) throws {
        let stepKey = record.stepKey
        guard WireValidation.isValidIdentifier(stepKey) else {
            throw StepMachineError.invalidIdentifier(stepKey)
        }
        try validate(sessionID: record.sessionID)
        records[StepKey(sessionID: record.sessionID, identity: stepKey)] = record
        let line = StepLogLine(version: 1, stepID: record.stepID, turnID: record.turnID,
                               state: record.state,
                               updatedAtMilliseconds: record.updatedAtMilliseconds,
                               mseq: record.mseq, jseq: record.jseq,
                               execID: record.execID, idemKey: record.idemKey,
                               settledReason: record.settledReason,
                               execEvidence: record.execEvidence,
                               checkpointJseq: record.checkpointJseq,
                               completionJseq: record.completionJseq)
        var data = try ControllerFileStore.encode(line)
        data.append(0x0A)
        try ControllerFileStore.append(data, to: sessionLogURL(sessionID: record.sessionID))
        let encoded = try ControllerFileStore.encode(record)
        // D20 canonical snapshot: the step identity is the journal key.
        try ControllerFileStore.writeAtomic(
            encoded, to: snapshotURL(sessionID: record.sessionID, stepKey: stepKey))
        // The W0/W2 snapshot form keyed by the informational decimal ordinal is
        // still written when the record carries one, so a reader that only
        // knows the original form keeps working. The key snapshot is canonical.
        if let stepID = record.stepID, stepID != stepKey {
            try ControllerFileStore.writeAtomic(
                encoded, to: snapshotURL(sessionID: record.sessionID, stepKey: stepID))
        }
    }

    private func sessionLogURL(sessionID: String) -> URL {
        stepsDirectory.appendingPathComponent(sessionID + ".ndjson")
    }

    private func snapshotURL(sessionID: String, stepKey: String) -> URL {
        stepsDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(stepKey + ".json")
    }

    // MARK: - Identifier validation

    private func validate(sessionID: String) throws {
        guard WireValidation.isValidIdentifier(sessionID) else {
            throw StepMachineError.invalidIdentifier(sessionID)
        }
    }

    private func validate(sessionID: String, turnID: String) throws {
        try validate(sessionID: sessionID)
        guard WireValidation.isValidIdentifier(turnID) else {
            throw StepMachineError.invalidIdentifier(turnID)
        }
    }

    private func validate(sessionID: String, turnID: String, stepID: String) throws {
        try validate(sessionID: sessionID, turnID: turnID)
        try validateStepID(stepID)
    }

    private func validate(sessionID: String, turnID: String, stepID: String,
                          execID: String) throws {
        try validate(sessionID: sessionID, turnID: turnID, stepID: stepID)
        guard WireValidation.isValidIdentifier(execID) else {
            throw StepMachineError.invalidIdentifier(execID)
        }
    }

    private func validateStepKey(_ stepKey: String) throws {
        // D6 is the only grammar for the D20 step identity; `xl1-<32hex>`
        // passes it and must never be rejected for not being decimal.
        guard WireValidation.isValidIdentifier(stepKey) else {
            throw StepMachineError.invalidIdentifier(stepKey)
        }
    }

    private func validateStepID(_ stepID: String) throws {
        guard WireValidation.isValidIdentifier(stepID) else {
            throw StepMachineError.invalidIdentifier(stepID)
        }
        // D20: unsigned decimal ASCII without leading zeros, first ordinal 1.
        let bytes = Array(stepID.utf8)
        guard let first = bytes.first, first >= 49, first <= 57,
              bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw StepMachineError.invalidStepID(stepID)
        }
    }

    // MARK: - Boot loading

    private static func loadFromDisk(stepsDirectory: URL) throws
        -> (records: [StepKey: StepRecord], order: [StepKey]) {
        var records: [StepKey: StepRecord] = [:]
        for name in ControllerFileStore.fileNames(in: stepsDirectory)
        where name.hasSuffix(".ndjson") {
            records = try loadSessionLog(name: name, stepsDirectory: stepsDirectory,
                                         into: records)
        }
        for name in ControllerFileStore.fileNames(in: stepsDirectory) {
            let url = stepsDirectory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            records = try loadSnapshots(sessionID: name, directory: url, into: records)
        }
        let order = records.keys.sorted {
            $0.sessionID == $1.sessionID ? $0.identity < $1.identity
                                        : $0.sessionID < $1.sessionID
        }
        return (records, order)
    }

    private static func loadSessionLog(name: String, stepsDirectory: URL,
                                       into records: [StepKey: StepRecord])
        throws -> [StepKey: StepRecord] {
        var records = records
        let sessionID = String(name.dropLast(".ndjson".count))
        guard WireValidation.isValidIdentifier(sessionID) else { return records }
        let url = stepsDirectory.appendingPathComponent(name)
        let data = try ControllerFileStore.read(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StepMachineError.corruptRecord("step log is not UTF-8")
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let decoded = try? ControllerFileStore.makeDecoder()
                .decode(StepLogLine.self, from: lineData) else {
                // A torn final line from a crash mid-append.
                continue
            }
            guard let identity = decoded.idemKey ?? decoded.stepID,
                  WireValidation.isValidIdentifier(identity) else {
                // A log line without a usable identity cannot locate a step;
                // it is not a step record the controller can reconstruct.
                continue
            }
            let key = StepKey(sessionID: sessionID, identity: identity)
            guard var record = records[key] else {
                records[key] = StepRecord(
                    sessionID: sessionID, stepID: decoded.stepID,
                    turnID: decoded.turnID, state: decoded.state,
                    updatedAtMilliseconds: decoded.updatedAtMilliseconds,
                    mseq: decoded.mseq, jseq: decoded.jseq, execID: decoded.execID,
                    idemKey: decoded.idemKey, history: [],
                    settledReason: decoded.settledReason,
                    execEvidence: decoded.execEvidence,
                    checkpointJseq: decoded.checkpointJseq,
                    completionJseq: decoded.completionJseq)
                continue
            }
            if let currentTurn = record.turnID, let nextTurn = decoded.turnID,
               currentTurn != nextTurn {
                continue
            }
            if record.state.isTerminal, !decoded.state.isTerminal {
                // The append-only log may still hold the pre-settlement tail
                // length; a terminal record never regresses.
                continue
            }
            record.state = decoded.state
            record.updatedAtMilliseconds = decoded.updatedAtMilliseconds
            record.mseq = decoded.mseq ?? record.mseq
            record.jseq = decoded.jseq ?? record.jseq
            record.execID = decoded.execID ?? record.execID
            record.idemKey = decoded.idemKey ?? record.idemKey
            record.settledReason = decoded.settledReason ?? record.settledReason
            record.execEvidence = decoded.execEvidence ?? record.execEvidence
            record.checkpointJseq = decoded.checkpointJseq ?? record.checkpointJseq
            record.completionJseq = decoded.completionJseq ?? record.completionJseq
            records[key] = record
        }
        return records
    }

    private static func loadSnapshots(sessionID: String, directory: URL,
                                      into records: [StepKey: StepRecord])
        throws -> [StepKey: StepRecord] {
        var records = records
        guard WireValidation.isValidIdentifier(sessionID) else { return records }
        for name in ControllerFileStore.fileNames(in: directory) where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let record = try ControllerFileStore.readJSON(StepRecord.self,
                                                                from: url) else {
                continue
            }
            guard record.sessionID == sessionID,
                  WireValidation.isValidIdentifier(record.stepKey) else { continue }
            let key = StepKey(sessionID: sessionID, identity: record.stepKey)
            if let existing = records[key] {
                if existing.state.isTerminal, !record.state.isTerminal { continue }
                if existing.state.order > record.state.order { continue }
            }
            records[key] = record
        }
        return records
    }
}

extension StepMachine: ToolCallBoundaryProviding {
    /// The step-level component of the budgets.md §4 tool-call boundary: no
    /// `exec_running` step exists. The frame-in-flight and closed-epoch
    /// conditions are enforced by ``ToolCallBoundary``, which ANDs this result
    /// with the loopback frame counter and the WAL epoch predicate. The
    /// scheduler is always given the composed provider, not this alone.
    public func atToolCallBoundary() async -> Bool { isIdle }
}
