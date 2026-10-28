// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: D10 persisted exec dedup.
//
// PLAN §2.4 (D10) and spec/v1/exec.md §2. The landed
// ``PhoneDSHLoopback/DefaultChannelHandling`` keeps its exec replay
// table in memory, which is correct for one connection but not across a
// process restart. ``PhoneDSHHost`` owns the controller's persisted
// ``PhoneDSHController/SideEffectLedger``; this decorator connects the
// two without widening the loopback module:
//
//   - the first `start` EXEC_EVT of an execution persists the intent entry
//     (argv/cwd/key) before the frame reaches the Worker;
//   - every later EXEC_EVT of a live execution is recorded before it is sent;
//   - a repeated `idem_key` replays the recorded stream instead of executing,
//     and a repeated key with a different argv/cwd is a conflict.
//
// Preflight errors the default handler emits before `start` (closed admission,
// unsupported accelerator, expired deadline) are not persisted, so a later
// retry with the same key can still execute — exactly the landed behaviour.
//
// Persistence failures are fail loud: the recorder keeps the frame moving to
// the Worker (the live execution must not stall) but remembers the error and
// calls its failure sink, which the host publishes on the ordered event stream
// and exposes through `PhoneDSHDiagnostics.ledgerPersistenceError`. Silently
// dropping the last EXEC_EVT would make a later replay incomplete.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHController
import PhoneDSHLoopback
import PhoneDSHWire

// MARK: - Recording outbound

/// Persists the EXEC_EVT stream of live executions into ``SideEffectLedger``.
///
/// The ordered channel's EXEC_EVT payloads carry `exec_id` but not the
/// `idem_key`; the decorator binds the intent before it hands the request to
/// the default handler and this recorder writes `exec/<idem_key>.json` from the
/// first `start` event on.
///
/// Persistence errors do not stop the outbound stream: they are reported to
/// ``onPersistenceFailure`` and retained in ``lastPersistenceError`` so the App
/// can surface the degraded replay log instead of discovering it after a
/// restart.
actor PhoneDSHLedgerRecorder {
    private struct Intent: Sendable {
        var execID: String
        var idemKey: String
        var argv: [String]
        var cwd: String
        var toolKey: String?
        var requiresMseq: UInt64
    }

    private let ledger: SideEffectLedger
    private let stepMachine: StepMachine
    private let onPersistenceFailure: @Sendable (String) -> Void
    private var intents: [String: Intent] = [:]
    private var keyByExecID: [String: String] = [:]
    private var liveKeys: Set<String> = []
    private var startObserved: Set<String> = []
    /// Last ledger write failure, or `nil` while every write succeeded.
    private(set) var lastPersistenceError: String?

    init(ledger: SideEffectLedger, stepMachine: StepMachine,
         onPersistenceFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.ledger = ledger
        self.stepMachine = stepMachine
        self.onPersistenceFailure = onPersistenceFailure
    }

    /// Binds an EXEC_REQ's identity so its first EXEC_EVT can persist the
    /// intent entry. Called before the default handler sees the request.
    func bindIntent(execID: String, idemKey: String, argv: [String], cwd: String,
                    toolKey: String?, requiresMseq: UInt64) async {
        intents[execID] = Intent(execID: execID, idemKey: idemKey,
                                 argv: argv, cwd: cwd, toolKey: toolKey,
                                 requiresMseq: requiresMseq)
        keyByExecID[execID] = idemKey
        if let toolKey {
            do {
                _ = try await stepMachine.bindAccelerator(toolKey: toolKey, execID: execID,
                                                         requiresMseq: requiresMseq)
            }
            catch {
                do {
                    _ = try await stepMachine.markExecPersistenceFailure(
                        toolKey: toolKey, execID: execID,
                        requiresMseq: requiresMseq)
                } catch { report(error, operation: "markExecPersistenceFailure", execID: execID) }
                report(error, operation: "bindAccelerator", execID: execID)
            }
        }
    }

    /// Whether this connection has an execution with the key in flight.
    func isLive(idemKey: String) -> Bool {
        liveKeys.contains(idemKey)
    }

    /// Appends one already-emitted EXEC_EVT frame to the ledger entry that owns
    /// its `exec_id`. A persistence failure is retained in
    /// ``lastPersistenceError`` and reported to the failure sink; the frame
    /// still reaches the Worker so a live execution is never stalled.
    func record(_ payload: Data, ackedMseq: UInt64) async {
        guard let value = try? JSONValue.parse(payload),
              case .object(let members) = value,
              let execValue = members["exec_id"],
              case .string(let execID) = execValue,
              let typeValue = members["type"],
              case .string(let type) = typeValue else {
            return
        }
        if type == "start" {
            guard let intent = intents[execID] else { return }
            startObserved.insert(execID)
            let replay: ExecReplay
            do {
                replay = try await ledger.prepareExec(idemKey: intent.idemKey,
                                                     execID: intent.execID,
                                                     argv: intent.argv,
                                                     cwd: intent.cwd,
                                                     toolKey: intent.toolKey,
                                                     requiresMseq: intent.toolKey == nil ? nil : intent.requiresMseq)
            } catch {
                intents[execID] = intent
                if let toolKey = intent.toolKey {
                    do {
                        _ = try await stepMachine.markExecPersistenceFailure(
                            toolKey: toolKey, execID: execID,
                            requiresMseq: intent.requiresMseq)
                    } catch { report(error, operation: "markExecPersistenceFailure", execID: execID) }
                }
                report(error, operation: "prepareExec")
                return
            }
            switch replay {
            case .started:
                liveKeys.insert(intent.idemKey)
                await append(payload, idemKey: intent.idemKey, execID: intent.execID,
                             intent: intent, ackedMseq: ackedMseq)
            case .replay(let entry) where !entry.terminal:
                // Another connection persisted the same intent first; this is
                // still the live stream of one execution.
                liveKeys.insert(intent.idemKey)
                await append(payload, idemKey: intent.idemKey, execID: intent.execID,
                             intent: intent, ackedMseq: ackedMseq)
            case .replay, .conflict, .miss:
                break
            }
            return
        }
        if type == "error", intents[execID] != nil,
           !startObserved.contains(execID) {
            // Preflight error before `start` (closed admission, unsupported
            // accelerator, expired deadline): the request was never added to
            // the dedup table, so a later retry may still execute.
            if let intent = intents.removeValue(forKey: execID),
               let toolKey = intent.toolKey {
                do { _ = try await stepMachine.releaseAccelerator(toolKey: toolKey,
                                                                    execID: execID) }
                catch { report(error, operation: "releaseAccelerator", execID: execID) }
            }
            keyByExecID.removeValue(forKey: execID)
            startObserved.remove(execID)
            return
        }
        guard let idemKey = keyByExecID[execID], liveKeys.contains(idemKey) else {
            return
        }
        await append(payload, idemKey: idemKey, execID: execID,
                     intent: intents[execID], ackedMseq: ackedMseq)
        if type == "exit" || type == "error" {
            liveKeys.remove(idemKey)
            intents.removeValue(forKey: execID)
            startObserved.remove(execID)
            keyByExecID.removeValue(forKey: execID)
        }
    }

    private func append(_ payload: Data, idemKey: String, execID: String,
                        intent: Intent?, ackedMseq: UInt64) async {
        do {
            _ = try await ledger.appendExecEvent(idemKey: idemKey, event: payload)
            if let intent, let toolKey = intent.toolKey {
                _ = try await stepMachine.observeExecEvent(toolKey: toolKey,
                                                           execID: execID,
                                                           event: payload)
                _ = try await stepMachine.observeAcceleratorWAL(
                    toolKey: toolKey, execID: execID,
                    requiresMseq: intent.requiresMseq,
                    ackedMseq: ackedMseq)
            }
        } catch {
            if let intent, let toolKey = intent.toolKey {
                do {
                    _ = try await stepMachine.markExecPersistenceFailure(
                        toolKey: toolKey, execID: execID,
                        requiresMseq: intent.requiresMseq)
                } catch { report(error, operation: "markExecPersistenceFailure", execID: execID) }
            }
            report(error, operation: "appendExecEvent", execID: execID)
        }
    }

    /// Replays only persisted evidence. Used at boot and before replaying a
    /// prior exec stream; no event reaches StepMachine before ledger durability.
    func restoreStepEvidence(_ entry: SideEffectEntry, ackedMseq: UInt64) async {
        guard entry.kind == .exec, let toolKey = entry.toolKey,
              let execID = entry.execID else { return }
        do {
            _ = try await stepMachine.bindAccelerator(
                toolKey: toolKey, execID: execID,
                requiresMseq: entry.requiresMseq ?? 0)
            for text in entry.events {
                guard let event = text.data(using: .utf8) else { continue }
                _ = try await stepMachine.observeExecEvent(toolKey: toolKey,
                                                          execID: execID,
                                                          event: event)
            }
            if let required = entry.requiresMseq {
                _ = try await stepMachine.observeAcceleratorWAL(
                    toolKey: toolKey, execID: execID, requiresMseq: required,
                    ackedMseq: ackedMseq)
            }
        } catch {
            report(error, operation: "restoreStepEvidence", execID: execID)
        }
    }

    /// Keeps the last failure for diagnostics and publishes it through the
    /// sink. Later successes do not clear it: a replay log with a hole stays
    /// degraded until the App surfaces it.
    private func report(_ error: Error, operation: String, execID: String? = nil) {
        let subject = execID.map { " for exec \($0)" } ?? ""
        let message = "\(operation)\(subject) failed: \(error)"
        lastPersistenceError = message
        onPersistenceFailure(message)
    }
}

/// Forwards every outbound frame unchanged and records EXEC_EVT before sending.
struct PhoneDSHLedgerOutbound: ChannelOutbound {
    let base: any ChannelOutbound
    let recorder: PhoneDSHLedgerRecorder

    func sendFrame(_ type: FrameType, payload: Data) async throws {
        if type == .execEvent {
            // Record before emitting so a replayed stream never omits a frame
            // the Worker already observed (exec.md §2).
            await recorder.record(payload, ackedMseq: await base.currentAckedMseq())
        }
        try await base.sendFrame(type, payload: payload)
    }

    func currentAckedMseq() async -> UInt64 {
        await base.currentAckedMseq()
    }

    func waitUntilAcked(_ mseq: UInt64, timeout: TimeInterval) async throws {
        try await base.waitUntilAcked(mseq, timeout: timeout)
    }

    func currentAdmission() async -> Admission {
        await base.currentAdmission()
    }

    func notifyVFSResync(path: String) async {
        await base.notifyVFSResync(path: path)
    }

    func sendLifecycle(_ payload: LifecyclePayload) async throws {
        try await base.sendLifecycle(payload)
    }

    func sendFence(_ payload: FencePayload) async throws {
        try await base.sendFence(payload)
    }
}

// MARK: - Handler decorator

/// Adds the persisted D10 exec replay of ``SideEffectLedger`` in front of the
/// loopback module's in-memory default handler.
actor PhoneDSHLedgerChannelHandling: ChannelHandling {
    private let delegate: any ChannelHandling
    private let ledger: SideEffectLedger
    private let outbound: any ChannelOutbound
    private let recorder: PhoneDSHLedgerRecorder

    init(delegate: any ChannelHandling,
         ledger: SideEffectLedger,
         outbound: any ChannelOutbound,
         recorder: PhoneDSHLedgerRecorder) {
        self.delegate = delegate
        self.ledger = ledger
        self.outbound = outbound
        self.recorder = recorder
    }

    // MARK: Pass-through

    func handleHello(_ payload: HelloPayload) async throws {
        try await delegate.handleHello(payload)
    }

    func handleVFSMutation(_ body: VfsMutationBody, seq: UInt64) async throws {
        try await delegate.handleVFSMutation(body, seq: seq)
    }

    func handleVFSMutation(_ body: VfsMutationBody, mseq: UInt64,
                           seq: UInt64) async throws {
        try await delegate.handleVFSMutation(body, mseq: mseq, seq: seq)
    }

    func handleVFSBarrier(_ body: VfsBarrierBody) async throws {
        try await delegate.handleVFSBarrier(body)
    }

    func handleExecControl(_ payload: ExecControlPayload) async throws {
        try await delegate.handleExecControl(payload)
    }

    func handleJournal(_ body: JournalBody) async throws {
        try await delegate.handleJournal(body)
    }

    func handleAPIResponse(_ frame: ApiResponseFrame) async throws {
        try await delegate.handleAPIResponse(frame)
    }

    func handleAPIEnd(_ frame: ApiEndFrame) async throws {
        try await delegate.handleAPIEnd(frame)
    }

    func handleAPIAbort(_ frame: ApiAbortFrame) async throws {
        try await delegate.handleAPIAbort(frame)
    }

    func handleConsole(_ payload: ConsolePayload) async throws {
        try await delegate.handleConsole(payload)
    }

    func handleError(_ payload: ErrorPayload) async throws {
        try await delegate.handleError(payload)
    }

    // MARK: Exec dedup

    func handleExecRequest(_ payload: ExecRequestPayload) async throws {
        guard let body = Self.validatedBody(payload) else {
            // Let the landed handler own the exact wire error for an invalid
            // request; no ledger entry must exist for it.
            try await delegate.handleExecRequest(payload)
            return
        }
        if await recorder.isLive(idemKey: payload.idemKey) {
            // The stream is still live on this connection: replay the recorded
            // prefix and let the provider's remaining events follow. A second
            // process is never started (exec.md §2).
            if let entry = await ledger.entry(forKey: payload.idemKey) {
                await recorder.restoreStepEvidence(entry,
                                                   ackedMseq: await outbound.currentAckedMseq())
                await replayEvents(entry)
            }
            return
        }
        let replay: ExecReplay
        do {
            replay = try await ledger.replayExec(idemKey: payload.idemKey,
                                                argv: body.argv,
                                                cwd: body.cwd)
        } catch {
            throw error
        }
        switch replay {
        case .miss, .started:
            // `.started` cannot come from replayExec; handling it like a miss
            // keeps the switch total without inventing a second code path.
            await recorder.bindIntent(execID: body.execID,
                                      idemKey: payload.idemKey,
                                      argv: body.argv,
                                      cwd: body.cwd,
                                      toolKey: body.toolKey,
                                      requiresMseq: payload.requiresMseq)
            try await delegate.handleExecRequest(payload)
        case .replay(let entry):
            // replayExec terminalizes a stale in-flight entry with the
            // `interrupted` error before returning it.
            await recorder.restoreStepEvidence(entry,
                                               ackedMseq: await outbound.currentAckedMseq())
            await replayEvents(entry)
        case .conflict:
            await emitError(execID: body.execID, code: "exec_id_conflict",
                            message: "idem_key was reused with a different argv or cwd")
        }
    }

    // MARK: Helpers

    /// The decoded fields D10 compares plus the checks the default handler
    /// performs before it allocates a record. A nil result keeps the landed
    /// error path (and therefore the wire error text) for invalid requests.
    private struct ValidatedBody {
        var execID: String
        var argv: [String]
        var cwd: String
        var toolKey: String?
    }

    private struct ExecBody: Decodable {
        struct Confine: Decodable {
            var mode: String?
        }

        var execID: String
        var argv: [String]
        var cwd: String
        var graceMS: Int?
        var confine: Confine?
        var tier: String?
        var env: [String: String?]?

        enum CodingKeys: String, CodingKey {
            case argv, cwd, tier, confine, env
            case execID = "exec_id"
            case graceMS = "grace_ms"
        }
    }

    private static func validatedBody(_ payload: ExecRequestPayload) -> ValidatedBody? {
        guard let body = try? JSONDecoder().decode(ExecBody.self, from: payload.body) else {
            return nil
        }
        guard WireValidation.isValidIdentifier(body.execID),
              !body.argv.isEmpty,
              body.argv.allSatisfy({ !$0.contains("\0") }),
              body.cwd.hasPrefix("/") else {
            return nil
        }
        if let grace = body.graceMS, !(1...60000).contains(grace) { return nil }
        if let confine = body.confine?.mode,
           confine != "read-only" && confine != "workspace-write" { return nil }
        if let tier = body.tier,
           !["interactive", "session", "batch"].contains(tier) { return nil }
        let toolKey = body.env?["XL_IDEMPOTENCY_KEY"] ?? nil
        return ValidatedBody(execID: body.execID, argv: body.argv, cwd: body.cwd,
                             toolKey: toolKey)
    }

    /// Re-emits the recorded `0x21 EXEC_EVT` frames in emit order, marking the
    /// `start` frame as a replay exactly like the in-memory handler does.
    private func replayEvents(_ entry: SideEffectEntry) async {
        for text in entry.events {
            guard var data = text.data(using: .utf8) else { continue }
            if let value = try? JSONValue.parse(data),
               case .object(var members) = value,
               members["type"] == .string("start") {
                members["replayed"] = .bool(true)
                data = (try? JSONValue.object(members).encoded()) ?? data
            }
            try? await outbound.sendFrame(.execEvent, payload: data)
        }
    }

    private func emitError(execID: String, code: String, message: String) async {
        let event = JSONValue.object([
            "code": .string(code),
            "exec_id": .string(execID),
            "message": .string(message),
            "seq": .number(0),
            "type": .string("error"),
        ])
        guard let data = try? event.encoded() else { return }
        try? await outbound.sendFrame(.execEvent, payload: data)
    }
}
