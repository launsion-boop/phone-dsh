// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLoopback: default channel handler.
//
// PLAN §2.2/§2.4 (D8, D10, D12), spec/v1/exec.md. Wires the ordered
// channel to a workspace log (VFS mutations), a journal log, and the read-only
// accelerators on an `ExecProvider` with the in-memory idempotency replay of
// this wave. Writing commands never reach this handler (§4.2 EXEC_REQ only);
// the executor inversion means the worker runs `bash -c` itself.
//
// This module may not depend on PhoneDSHLog (PLAN §2.1 fixes the
// dependency edge as Wire + AgentCore), so the log seams are the
// small ``LoopbackWorkspaceLog`` and ``LoopbackJournalLog`` protocols below;
// the W2 controller adapts `WorkspaceLogging` / `WorkspaceLogService` to them.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHWire

// MARK: - Log seams

/// One cumulative workspace acknowledgement.
public struct LoopbackWorkspaceAck: Equatable, Sendable {
    public var level: AckLevel
    public var uptoMseq: UInt64

    public init(level: AckLevel, uptoMseq: UInt64) {
        self.level = level
        self.uptoMseq = uptoMseq
    }
}

/// The workspace-log operations the ordered channel needs (wal.md §5).
///
/// `PhoneDSHLog.WorkspaceLogging` provides the same operations; W2
/// adapts it because PLAN §2.1 does not allow a Loopback → Log edge.
public protocol LoopbackWorkspaceLog: Sendable {
    /// Appends one structurally valid mutation and returns its host-allocated
    /// mseq. Returns only after the level-1 `write()` completed.
    func append(_ mutation: VfsMutationBody) async throws -> UInt64
    /// Cumulative acknowledgements; level 2 only at an epoch close.
    func acks() -> AsyncStream<LoopbackWorkspaceAck>
    /// Closes the current epoch and returns the level-2 ack. The default is
    /// nil for logs without a separate epoch trigger (W1 tests).
    func closeEpoch() async throws -> LoopbackWorkspaceAck?
    /// Paths whose `appended` mutation could not be materialized because the
    /// base did not match (channel.md §8, wal.md §5.1). The materializer
    /// detects the mismatch; its W2 adapter forwards each path here and the
    /// ordered channel turns it into one `0x13 VFS_RESYNC` at once. The default
    /// is an empty stream for logs without a materializer (W1 tests).
    func resyncs() -> AsyncStream<String>
}

extension LoopbackWorkspaceLog {
    public func closeEpoch() async throws -> LoopbackWorkspaceAck? { nil }
    public func resyncs() -> AsyncStream<String> { AsyncStream { $0.finish() } }
}

/// The journal append seam (tool-journal records, exec.md §4). The persistent
/// journal store arrives with the controller wave; this wave keeps an
/// in-memory implementation for the channel default handler.
public protocol LoopbackJournalLog: Sendable {
    /// Appends the record and returns the highest contiguous jseq for the
    /// session. A duplicate `(session_id, jseq)` is ignored; a forward gap is
    /// `BAD_PAYLOAD` (the channel checks it against ``lastJseq`` before
    /// calling this method).
    func appendJournal(sessionID: String, jseq: UInt64, record: Data) async throws -> UInt64
    /// The persisted per-session jseq high-water mark (`0` when nothing of the
    /// session is stored). `JOURNAL` deduplication and the forward-gap check
    /// use this value, never a per-connection counter: a reconnect re-sends
    /// every record above the highest jseq the host acknowledged (D2,
    /// channel.md §3.5, §9.3). The host HELLO cannot carry per-session journal
    /// marks (its wire schema is fixed), so the server derives them here.
    ///
    /// Durable implementations must override this with the persisted mark
    /// (`PhoneDSHLog.WorkspaceLogService.journalLastJseq(sessionID:)`);
    /// the default is for connection-scoped test doubles only.
    func lastJseq(sessionID: String) async -> UInt64
}

extension LoopbackJournalLog {
    public func lastJseq(sessionID: String) async -> UInt64 { 0 }
}

/// In-memory journal log used by W1 and by tests.
public actor InMemoryJournalLog: LoopbackJournalLog {
    private var highest: [String: UInt64] = [:]
    private var records: [String: [UInt64: Data]] = [:]

    public init() {}

    public func appendJournal(sessionID: String, jseq: UInt64, record: Data) async throws -> UInt64 {
        guard jseq >= 1 else {
            throw PhoneWireError(code: .badPayload, message: "journal jseq starts at 1")
        }
        let current = highest[sessionID] ?? 0
        if jseq <= current { return current }
        guard jseq == current &+ 1 else {
            throw PhoneWireError(code: .badPayload, message: "journal jseq gap")
        }
        records[sessionID, default: [:]][jseq] = record
        highest[sessionID] = jseq
        return jseq
    }

    /// The stored record for one `(session_id, jseq)`; nil when absent.
    public func record(sessionID: String, jseq: UInt64) -> Data? {
        records[sessionID]?[jseq]
    }

    /// Highest contiguous jseq appended for the session.
    public func highestJseq(sessionID: String) -> UInt64 {
        highest[sessionID] ?? 0
    }

    /// Persisted high-water mark; the in-memory store survives reconnects for
    /// as long as the process does, which is the W1 test model of D2.
    public func lastJseq(sessionID: String) async -> UInt64 {
        highest[sessionID] ?? 0
    }
}

// MARK: - Default handler

/// Default ``ChannelHandling``: persists VFS mutations through a workspace log,
/// journals records, and runs the read-only accelerators on an ExecProvider.
public actor DefaultChannelHandling: ChannelHandling {
    private let outbound: any ChannelOutbound
    private let workspaceLog: (any LoopbackWorkspaceLog)?
    private let journalLog: (any LoopbackJournalLog)?
    private let execProvider: (any ExecProvider)?
    private let accelerators: Set<String>
    private let admissionProvider: @Sendable () async -> Admission

    // Wave W1 keeps the D10 dedup/replay table in memory; the persisted
    // side-effect ledger is W2-CONTROLLER's SideEffectLedger (exec.md §2).
    private var executions: [String: ExecRecord] = [:]
    private var executionsByID: [String: ExecRecord] = [:]

    public init(outbound: any ChannelOutbound,
                workspaceLog: (any LoopbackWorkspaceLog)? = nil,
                journalLog: (any LoopbackJournalLog)? = nil,
                execProvider: (any ExecProvider)? = nil,
                accelerators: [String] = [],
                admission: @escaping @Sendable () async -> Admission = { .open }) {
        self.outbound = outbound
        self.workspaceLog = workspaceLog
        self.journalLog = journalLog
        self.execProvider = execProvider
        self.accelerators = Set(accelerators)
        self.admissionProvider = admission
    }

    // MARK: ChannelHandling

    public func handleHello(_ payload: HelloPayload) async throws {}

    public func handleVFSMutation(_ body: VfsMutationBody, seq: UInt64) async throws {
        try await handleVFSMutation(body, mseq: 0, seq: seq)
    }

    public func handleVFSMutation(_ body: VfsMutationBody, mseq: UInt64,
                                  seq: UInt64) async throws {
        // Acknowledging a mutation without a log would claim a durability the
        // host cannot provide; fail loud instead (channel.md §8 D8).
        guard let workspaceLog else { throw LoopbackError.channelUnavailable }
        let allocated = try await workspaceLog.append(body)
        if mseq != 0, allocated != mseq {
            throw PhoneWireError(code: .badMseq,
                                 message: "the workspace log allocated mseq \(allocated), expected \(mseq)",
                                 refSeq: seq)
        }
    }

    /// Barriers are answered by the channel server from the observed ack
    /// levels; the handler only sees them for bookkeeping.
    public func handleVFSBarrier(_ body: VfsBarrierBody) async throws {}

    public func handleJournal(_ body: JournalBody) async throws {
        guard let journalLog else { return }
        _ = try await journalLog.appendJournal(sessionID: body.sessionID,
                                               jseq: body.jseq,
                                               record: body.record)
    }

    public func handleAPIResponse(_ frame: ApiResponseFrame) async throws {}
    public func handleAPIEnd(_ frame: ApiEndFrame) async throws {}
    public func handleAPIAbort(_ frame: ApiAbortFrame) async throws {}
    public func handleConsole(_ payload: ConsolePayload) async throws {}
    public func handleError(_ payload: ErrorPayload) async throws {}

    // MARK: Exec

    public func handleExecRequest(_ payload: ExecRequestPayload) async throws {
        let body: ExecRequestBody
        do {
            body = try JSONDecoder().decode(ExecRequestBody.self, from: payload.body)
        } catch {
            throw PhoneWireError(code: .badPayload, message: "malformed EXEC_REQ body")
        }
        guard WireValidation.isValidIdentifier(body.execID) else {
            throw PhoneWireError(code: .badPayload, message: "invalid exec_id")
        }
        guard !body.argv.isEmpty, body.argv.allSatisfy({ !$0.contains("\0") }) else {
            throw PhoneWireError(code: .badPayload, message: "argv must be non-empty and NUL-free")
        }
        guard body.cwd.hasPrefix("/") else {
            throw PhoneWireError(code: .badPayload, message: "cwd must be absolute")
        }
        if let grace = body.graceMS, !(1...60000).contains(grace) {
            throw PhoneWireError(code: .badPayload, message: "grace_ms must be 1-60000")
        }
        if let confine = body.confine?.mode, confine != "read-only" && confine != "workspace-write" {
            throw PhoneWireError(code: .badPayload, message: "invalid confine mode")
        }
        if let tier = body.tier, !["interactive", "session", "batch"].contains(tier) {
            throw PhoneWireError(code: .badPayload, message: "invalid tier")
        }

        if await admissionProvider() == .closed {
            await emitTerminalError(execID: body.execID, code: "admission_closed",
                                    message: "admission is closed")
            return
        }
        guard let execProvider else {
            await emitTerminalError(execID: body.execID, code: "unsupported",
                                    message: "the host has no exec provider")
            return
        }
        guard accelerators.contains(body.argv[0]) else {
            // Executor inversion (D12): only an advertised accelerator may
            // travel as EXEC_REQ; everything else belongs to the worker.
            await emitTerminalError(execID: body.execID, code: "unsupported",
                                    message: "\(body.argv[0]) is not an advertised accelerator")
            return
        }

        if let existing = executions[payload.idemKey] {
            guard existing.argv == body.argv, existing.cwd == body.cwd else {
                await emitTerminalError(execID: body.execID, code: "exec_id_conflict",
                                        message: "idem_key was reused with a different argv or cwd")
                return
            }
            await replay(existing)
            return
        }
        if let existing = executionsByID[body.execID],
           existing.idemKey != payload.idemKey {
            // exec.md §2: an exec_id may not be reused for a different idem_key.
            await emitTerminalError(execID: body.execID, code: "exec_id_conflict",
                                    message: "exec_id was reused for a different idem_key")
            return
        }

        if payload.requiresMseq > 0 {
            let waitDeadline = min(Date().addingTimeInterval(300),
                                   body.deadline.map {
                                       Date(timeIntervalSince1970: Double($0) / 1000)
                                   } ?? Date().addingTimeInterval(300))
            while await outbound.currentAckedMseq() < payload.requiresMseq {
                if await admissionProvider() == .closed {
                    await emitTerminalError(execID: body.execID, code: "admission_closed",
                                            message: "admission closed while waiting for requires_mseq")
                    return
                }
                if Date() >= waitDeadline {
                    await emitTerminalError(execID: body.execID, code: "deadline_exceeded",
                                            message: "requires_mseq was not reached in time")
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        if let deadline = body.deadline, deadline <= nowMilliseconds {
            await emitTerminalError(execID: body.execID, code: "deadline_exceeded",
                                    message: "the deadline has already passed")
            return
        }

        let record = ExecRecord(idemKey: payload.idemKey, execID: body.execID,
                                argv: body.argv, cwd: body.cwd)
        executions[payload.idemKey] = record
        executionsByID[body.execID] = record
        await appendEvent(record, StartEvent(execID: body.execID, seq: 0, replayed: false))

        let request = ExecRequest(execID: body.execID,
                                  argv: body.argv,
                                  cwd: body.cwd,
                                  env: body.env?.compactMapValues { $0 } ?? [:],
                                  deadline: body.deadline.map {
                                      Date(timeIntervalSince1970: Double($0) / 1000)
                                  },
                                  tier: body.tierDate)
        Task { [weak self] in
            await self?.drive(record: record, request: request, provider: execProvider)
        }
    }

    public func handleExecControl(_ payload: ExecControlPayload) async throws {
        switch payload.op {
        case .cancel:
            guard let record = executionsByID[payload.execID], !record.terminal else { return }
            record.cancelled = true
            await execProvider?.cancel(execID: payload.execID)
        case .stdin:
            // `ExecProvider` has no stdin channel; exec-bridge v1 answers 501.
            // On the channel an error event is the closest representation.
            guard let record = executionsByID[payload.execID], !record.terminal else {
                await emitTerminalError(execID: payload.execID, code: "unsupported",
                                        message: "stdin is not supported: the provider has no stdin")
                return
            }
            await appendEvent(record, ErrorEvent(execID: payload.execID,
                                                 seq: record.nextSeq(),
                                                 code: "unsupported",
                                                 message: "stdin is not supported: the provider has no stdin"))
        }
    }

    // MARK: Exec driving

    private func drive(record: ExecRecord, request: ExecRequest,
                       provider: any ExecProvider) async {
        var sawExit = false
        do {
            for try await event in provider.run(request) {
                switch event {
                case .stdout(_, let data):
                    record.stdoutBytes += data.count
                    await appendEvent(record, OutputEvent(execID: record.execID,
                                                          seq: record.nextSeq(),
                                                          stream: "stdout", data: data))
                case .stderr(_, let data):
                    record.stderrBytes += data.count
                    await appendEvent(record, OutputEvent(execID: record.execID,
                                                          seq: record.nextSeq(),
                                                          stream: "stderr", data: data))
                case .exit(let code, let signal, let truncated):
                    sawExit = true
                    let status: String
                    if record.cancelled {
                        status = "cancelled"
                    } else if signal != nil {
                        status = "signaled"
                    } else if code != nil {
                        status = "exited"
                    } else {
                        status = "failed"
                    }
                    await appendEvent(record, ExitEvent(execID: record.execID,
                                                        seq: record.nextSeq(),
                                                        code: code,
                                                        signal: Self.signalName(signal),
                                                        status: status,
                                                        truncated: truncated,
                                                        stdoutBytes: record.stdoutBytes,
                                                        stderrBytes: record.stderrBytes))
                    await finish(record)
                    return
                }
            }
            if !sawExit {
                await appendEvent(record, ErrorEvent(execID: record.execID,
                                                     seq: record.nextSeq(),
                                                     code: "internal",
                                                     message: "the provider stream ended without an exit event"))
                await finish(record)
            }
        } catch {
            guard !record.terminal else { return }
            if let failure = error as? ExecProviderFailure {
                await appendEvent(record, ErrorEvent(execID: record.execID,
                                                     seq: record.nextSeq(),
                                                     code: failure.code,
                                                     message: failure.message))
            } else {
                let cancelled = error is CancellationError
                await appendEvent(record, ErrorEvent(
                    execID: record.execID,
                    seq: record.nextSeq(),
                    code: cancelled ? "cancelled" : "provider_unavailable",
                    message: cancelled
                        ? "the provider call was cancelled"
                        : "the exec provider failed without a typed error"))
            }
            await finish(record)
        }
    }

    private func finish(_ record: ExecRecord) async {
        record.terminal = true
    }

    /// Replays a recorded event stream; the `start` event says `replayed`.
    private func replay(_ record: ExecRecord) async {
        for event in record.events {
            var value = event.value
            if event.type == "start", case .object(var members) = value {
                members["replayed"] = .boolean(true)
                value = .object(members)
            }
            try? await outbound.sendFrame(.execEvent, payload: value.encoded())
        }
    }

    private func appendEvent(_ record: ExecRecord, _ event: any ExecEventValue) async {
        let value = event.value
        record.events.append(RecordedEvent(type: event.type, value: value))
        try? await outbound.sendFrame(.execEvent, payload: value.encoded())
    }

    private func emitTerminalError(execID: String, code: String, message: String) async {
        let value = ErrorEvent(execID: execID, seq: 0, code: code, message: message).value
        try? await outbound.sendFrame(.execEvent, payload: value.encoded())
    }

    private static func signalName(_ signal: Int32?) -> String? {
        switch signal {
        case 1: return "SIGHUP"
        case 2: return "SIGINT"
        case 3: return "SIGQUIT"
        case 6: return "SIGABRT"
        case 9: return "SIGKILL"
        case 13: return "SIGPIPE"
        case 14: return "SIGALRM"
        case 15: return "SIGTERM"
        default: return nil
        }
    }
}

// MARK: - Exec wire body

struct ExecRequestBody: Decodable {
    struct Stdin: Decodable {
        var mode: String
        var data: String?
    }

    struct Confine: Decodable {
        var mode: String
        var workspaceRoot: String?

        enum CodingKeys: String, CodingKey {
            case mode
            case workspaceRoot = "workspace_root"
        }
    }

    var execID: String
    var argv: [String]
    var cwd: String
    var env: [String: String?]?
    var deadline: Int64?
    var graceMS: Int?
    var stdin: Stdin?
    var tier: String?
    var confine: Confine?

    enum CodingKeys: String, CodingKey {
        case argv, cwd, env, deadline, stdin, tier, confine
        case execID = "exec_id"
        case graceMS = "grace_ms"
    }

    var tierDate: ExecRequest.Tier {
        switch tier {
        case "interactive", nil: return .interactive
        case "session": return .session
        case "batch": return .batch
        default: return .interactive
        }
    }
}

// MARK: - Recorded exec state

/// One execution record; confined to the ``DefaultChannelHandling`` actor.
private final class ExecRecord: @unchecked Sendable {
    let idemKey: String
    let execID: String
    let argv: [String]
    let cwd: String
    var events: [RecordedEvent] = []
    var terminal = false
    var cancelled = false
    var stdoutBytes = 0
    var stderrBytes = 0

    init(idemKey: String, execID: String, argv: [String], cwd: String) {
        self.idemKey = idemKey
        self.execID = execID
        self.argv = argv
        self.cwd = cwd
    }

    func nextSeq() -> UInt64 { UInt64(events.count) }
}

private struct RecordedEvent: Sendable {
    var type: String
    var value: CanonicalJSONValue
}

// MARK: - Canonical event shapes (channel.md §4.3, exec-bridge v1 §4.1)

private protocol ExecEventValue {
    var type: String { get }
    var value: CanonicalJSONValue { get }
}

private struct StartEvent: ExecEventValue {
    var execID: String
    var seq: UInt64
    var replayed: Bool
    var type: String { "start" }
    var value: CanonicalJSONValue {
        .object([
            "exec_id": .string(execID),
            "replayed": .boolean(replayed),
            "seq": .integer(seq),
            "type": .string(type),
        ])
    }
}

private struct OutputEvent: ExecEventValue {
    var execID: String
    var seq: UInt64
    var stream: String
    var data: Data
    var type: String { "output" }
    var value: CanonicalJSONValue {
        .object([
            "data": .string(data.base64EncodedString()),
            "exec_id": .string(execID),
            "seq": .integer(seq),
            "stream": .string(stream),
            "type": .string(type),
        ])
    }
}

private struct ExitEvent: ExecEventValue {
    var execID: String
    var seq: UInt64
    var code: Int32?
    var signal: String?
    var status: String
    var truncated: Bool
    var stdoutBytes: Int
    var stderrBytes: Int
    var type: String { "exit" }
    var value: CanonicalJSONValue {
        var members: [String: CanonicalJSONValue] = [
            "code": code.map { .signed(Int64($0)) } ?? .null,
            "exec_id": .string(execID),
            "quiescent": .boolean(true),
            "seq": .integer(seq),
            "signal": signal.map { .string($0) } ?? .null,
            "status": .string(status),
            "stderr_bytes": .integer(UInt64(max(0, stderrBytes))),
            "stdout_bytes": .integer(UInt64(max(0, stdoutBytes))),
            "type": .string(type),
        ]
        if truncated {
            members["stderr_truncated"] = .boolean(true)
            members["stdout_truncated"] = .boolean(true)
        }
        return .object(members)
    }
}

private struct ErrorEvent: ExecEventValue {
    var execID: String
    var seq: UInt64
    var code: String
    var message: String
    var type: String { "error" }
    var value: CanonicalJSONValue {
        .object([
            "code": .string(code),
            "exec_id": .string(execID),
            "message": .string(message),
            "seq": .integer(seq),
            "type": .string(type),
        ])
    }
}
