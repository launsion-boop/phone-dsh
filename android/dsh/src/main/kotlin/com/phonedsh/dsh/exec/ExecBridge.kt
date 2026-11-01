// phone-dsh — :dsh / com.phonedsh.dsh.exec: the EXEC_REQ → EXEC_EVT bridge.
// SPDX-License-Identifier: MIT
//
// This is the `exec/1` capability (channel.md §4.1): one `0x20` in, an ordered
// stream of `0x21` events out, plus one `0x22` control entry point. The host
// wiring is three calls on the connection:
//
//     val request = ExecRequest.parse(payload)      // BAD_PAYLOAD on refusal
//     bridge.onRequest(request).collect { event -> send(event.encode(nextSeq())) }
//     val control = ExecControl.parse(payload)      // EXEC_CTL, 0x22
//     bridge.onControl(control)                     // Applied/Ignored/Refused/Emit
//
// and the capability that must be in the HELLO is
// `execCapability.helloCaps(baseCaps)` — never a hand-written "exec/1".
//
// ---- the rules this file exists to enforce ---------------------------------
// 1. Admission closed: no execution, one terminal `error` (exec.md §2, §2.1).
// 2. `requires_mseq > 0`: the request waits until the materialized view covers
//    that mseq. It is never dispatched early; a closed admission or an expired
//    deadline ends the wait with a terminal error and no execution (§2.1).
// 3. A repeated `idem_key` joins the *same* execution: the live log replays the
//    recorded prefix and then follows the provider (exec.md §2). It is not a
//    second run and not a terminal refusal. A completed key replays from the
//    durable ledger (or the retained live log) with `start.replayed = true`.
// 4. `exit` is one event of its own. There is no batching layer in this file:
//    every event is a separate Flow emission and a separate frame (§4.3).
// 5. Unknown command, a `stdin.mode = pipe` request, or a tool's protocol-level
//    refusal (a `stdin.data` payload, a `jaq` that would read the process
//    stdin): one terminal `error` with the stable code `unsupported`
//    (exec.md §3). An in-process accelerator has no stdin pipe, so the request
//    is refused, never silently ignored. A tool that *ran* and failed keeps the
//    distinct `tool_failed` code.
// 6. `EXEC_CTL cancel` ends the execution with a terminal `cancelled` exit and
//    drops every later event; `stdin` is refused explicitly ([onControl]).
//    `argv` is never copied into a code, a message or a log line.
//
// The execution is driven on [executionScope], not on a collector's coroutine:
// the Worker may drop the connection while the accelerator keeps running, and a
// join from another request (or after a reconnect) must still see the same
// execution. A collector only subscribes to the live log, so cancelling it does
// not cancel the run (exec.md §3).

package com.phonedsh.dsh.exec

import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.tools.InMemoryRequestLedger
import com.phonedsh.dsh.tools.PhoneTool
import com.phonedsh.dsh.tools.PhoneToolBridge
import com.phonedsh.dsh.tools.RequestLedger
import com.phonedsh.dsh.tools.ToolAnswer
import com.phonedsh.dsh.tools.ToolInvocation
import com.phonedsh.dsh.tools.ToolOutcome
import com.phonedsh.platform.Clock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch

/**
 * The host-side exec bridge for the advertised [capability].
 *
 * @param capability exactly the tools this bridge can dispatch; non-empty by type
 * @param admission the host's admission state; this lane never changes it
 * @param workspace the applied VFS watermark (`exec.md §2.1`)
 * @param clock wall time for `deadline`, monotonic time for the readiness bound
 * @param logger host log; never receives `argv`, `cwd` or a tool result body
 * @param readinessPollMs how often a waiting request re-reads the watermark
 * @param readinessWaitLimitMs fail-loud bound while the watermark never arrives;
 *   the spec's own bound is the request `deadline`, which may be absent
 * @param ledger the one idempotency ledger, shared with every other tool surface;
 *   [FileRequestLedger] is the durable backend of exec.md §2
 * @param executionScope owns the running executions; the default keeps the
 *   previous dispatch behaviour (the tool starts on the caller's thread and then
 *   suspends on its own), while making a run independent of any one collector
 */
class ExecBridge(
    val capability: ExecCapability.Available,
    private val admission: AdmissionGate,
    private val workspace: ExecWorkspace,
    private val clock: Clock,
    private val logger: HostLog = HostLog.None,
    private val readinessPollMs: Long = DEFAULT_READINESS_POLL_MS,
    private val readinessWaitLimitMs: Long = DEFAULT_READINESS_WAIT_LIMIT_MS,
    ledger: RequestLedger = InMemoryRequestLedger(),
    private val executionScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
) {
    init {
        require(capability.names.isNotEmpty()) {
            "ExecBridge needs at least one executable accelerator; exec/1 would be a lie"
        }
        require(readinessPollMs >= 1L) { "readinessPollMs must be positive, was $readinessPollMs" }
        require(readinessWaitLimitMs >= 1L) {
            "readinessWaitLimitMs must be positive, was $readinessWaitLimitMs"
        }
    }

    private val live: LiveExecutions = LiveExecutions()

    private val registry: PhoneToolBridge = PhoneToolBridge(ledger = ledger, logger = logger)

    private val execIdLock = Any()
    private val execIdOwners = LinkedHashMap<String, String>()

    init {
        // The capability's tools are the only dispatchers. Registering them here
        // keeps "advertised" and "executable" the same list by construction.
        for (registered in capability.tools.all) {
            registry.registerTool(registered.name, RecordingTool(registered.tool, logger, live))
        }
    }

    /**
     * The retained live executions, exposed to the module's tests for the
     * replay-prefix assertions. Production code observes them only through
     * [onRequest] and [onControl].
     */
    internal val liveExecutions: LiveExecutions get() = live

    /**
     * Answers one validated request with its ordered event stream.
     *
     * The refusal cases are terminal single events. The executed case streams
     * the live log; the duplicate case replays the recorded prefix and follows
     * the running execution, or replays the completed record. Collection may
     * suspend while `requires_mseq` is not applied yet.
     */
    fun onRequest(request: ExecRequest): Flow<ExecEvent> = flow {
        val toolName = request.argv.first()

        if (!admission.isOpen()) {
            logger.info("exec refused: admission closed exec_id=${request.execId}")
            emit(refusal(request, CODE_ADMISSION_CLOSED, MESSAGE_ADMISSION_CLOSED))
            return@flow
        }
        if (deadlinePassed(request)) {
            logger.info("exec refused: deadline already passed exec_id=${request.execId}")
            emit(refusal(request, CODE_DEADLINE_EXCEEDED, MESSAGE_DEADLINE_EXCEEDED))
            return@flow
        }
        if (toolName !in capability.names) {
            // The command string is not logged: argv[0] can name a private path.
            logger.warn("exec refused: the command is not an advertised accelerator exec_id=${request.execId}")
            emit(refusal(request, CODE_UNSUPPORTED, MESSAGE_UNSUPPORTED))
            return@flow
        }
        if (request.stdin is StdinSpec.Pipe) {
            // exec.md §3: an in-process accelerator produces bytes, not a stdin
            // pipe. Refuse explicitly; a dropped pipe would hang the Worker.
            logger.warn("exec refused: stdin pipe is not supported by an in-process accelerator exec_id=${request.execId}")
            emit(refusal(request, CODE_UNSUPPORTED, MESSAGE_STDIN_PIPE_UNSUPPORTED))
            return@flow
        }

        when (val readiness = awaitWorkspace(request)) {
            Readiness.Ready -> Unit
            is Readiness.Refused -> {
                emit(refusal(request, readiness.code, readiness.message))
                return@flow
            }
        }

        // The wait can span a LIFECYCLE/FENCE change; both facts are re-read at
        // the dispatch edge so a closed admission never starts a command.
        if (!admission.isOpen()) {
            logger.info("exec refused after waiting: admission closed exec_id=${request.execId}")
            emit(refusal(request, CODE_ADMISSION_CLOSED, MESSAGE_ADMISSION_CLOSED))
            return@flow
        }
        if (deadlinePassed(request)) {
            logger.info("exec refused after waiting: deadline passed exec_id=${request.execId}")
            emit(refusal(request, CODE_DEADLINE_EXCEEDED, MESSAGE_DEADLINE_EXCEEDED))
            return@flow
        }
        if (!claimExecId(request)) {
            logger.warn("exec refused: exec_id was already used for another idem_key exec_id=${request.execId}")
            emit(refusal(request, CODE_EXEC_ID_CONFLICT, MESSAGE_EXEC_ID_REUSED))
            return@flow
        }

        when (val claim = live.claim(request, clock.nowMillis())) {
            is LiveExecutions.Claim.Conflict -> {
                // exec.md §2: conflict detection compares argv and cwd only.
                logger.warn("exec refused: idem_key was used with another argv or cwd exec_id=${request.execId}")
                emit(refusal(request, CODE_EXEC_ID_CONFLICT, MESSAGE_IDEM_CONFLICT))
            }

            is LiveExecutions.Claim.Join -> {
                logger.info(
                    "exec join: idem_key=${request.idemKey} exec_id=${request.execId} " +
                        "recorded_exec_id=${claim.execution.execId}",
                )
                emitAll(claim.execution.stream(replayed = true))
            }

            is LiveExecutions.Claim.Start -> {
                logger.info(
                    "exec dispatch: tool=$toolName exec_id=${request.execId} " +
                        "idem_key=${request.idemKey} requires_mseq=${request.requiresMseq}",
                )
                val execution = claim.execution
                val job: Job = executionScope.launch { drive(request, toolName, execution) }
                job.invokeOnCompletion { cause ->
                    // A cancelled bridge scope never runs the driver body; the
                    // subscriber must still see a terminal event.
                    if (cause != null) execution.failTerminal(CODE_INTERNAL, MESSAGE_INTERNAL)
                }
                emitAll(execution.stream(replayed = false))
            }
        }
    }

    /**
     * Dispatches one decoded `EXEC_CTL` control (channel.md §4.4).
     *
     * Safe to call from the channel thread while the execution runs. It never
     * throws for an unknown [ExecControl.execId]: a control that targets nothing
     * is reported as [ExecControlOutcome.Ignored] (cancel) or answered with a
     * standalone terminal event ([ExecControlOutcome.Emit]) so the refusal is
     * never silent.
     *
     * ### `stdin` terminates the execution on purpose
     *
     * A `stdin` control ends a live execution with a terminal `unsupported`
     * error. An in-process accelerator has no stdin pipe, and EXEC_EVT has no
     * non-terminal refusal: `error` is a terminal event type, so ending the
     * execution is the only protocol-compliant way to refuse. This deliberately
     * differs from the landed Swift handler, which appends an `error` event and
     * lets the execution continue; that behaviour contradicts the terminal
     * definition of `error` and is not followed here.
     *
     * @return what the caller must do with the control; only [ExecControlOutcome.Emit]
     *   requires sending a frame, and an applied cancel/refusal reaches the
     *   Worker through the execution's own EXEC_EVT stream
     */
    fun onControl(control: ExecControl): ExecControlOutcome = when (control) {
        is ExecControl.Cancel -> {
            val execution = live.findByExecId(control.execId)
            if (execution == null || execution.isTerminal) {
                logger.info("exec cancel ignored: no live execution exec_id=${control.execId}")
                ExecControlOutcome.Ignored
            } else {
                execution.cancel()
                logger.info("exec cancel: exec_id=${control.execId}")
                ExecControlOutcome.Applied
            }
        }

        is ExecControl.Stdin -> {
            val execution = live.findByExecId(control.execId)
            if (execution == null || execution.isTerminal) {
                // The landed handler answers 501 for stdin; on the ordered
                // channel a terminal error event is the closest representation.
                logger.warn("exec stdin refused: no live execution exec_id=${control.execId}")
                ExecControlOutcome.Emit(
                    ExecEvent.Error(
                        execId = control.execId,
                        seq = ExecEvent.SEQUENCE_START,
                        code = CODE_UNSUPPORTED,
                        message = MESSAGE_STDIN_CONTROL_UNSUPPORTED,
                    ),
                )
            } else {
                logger.warn("exec stdin refused: in-process accelerator has no stdin exec_id=${control.execId}")
                execution.failTerminal(CODE_UNSUPPORTED, MESSAGE_STDIN_CONTROL_UNSUPPORTED)
                ExecControlOutcome.Refused(CODE_UNSUPPORTED)
            }
        }
    }

    /**
     * Drives one owned execution: the ledger decides whether this call is a new
     * run or a durable replay, and the live log is the one stream either way.
     */
    private suspend fun drive(request: ExecRequest, toolName: String, execution: LiveExecution) {
        try {
            val invocation = ToolInvocation(
                requestId = request.idemKey,
                tool = toolName,
                argumentsJson = request.toJson(),
            )
            when (val answer = registry.call(invocation)) {
                is ToolAnswer.Executed -> {
                    // RecordingTool published the events; a missing terminal is a
                    // defect, and the subscriber must not wait forever.
                    if (!execution.isTerminal) {
                        logger.error("exec tool answered without a terminal event exec_id=${request.execId}")
                        execution.failTerminal(CODE_INTERNAL, MESSAGE_INTERNAL)
                    }
                }

                is ToolAnswer.Replayed -> publishReplay(request, execution, answer.outcome)

                is ToolAnswer.InFlight -> {
                    // Another ledger owner (for example a second bridge in the
                    // same process) admitted the key first; this bridge has no
                    // handle to join, so it answers the old terminal refusal
                    // rather than starting a second run.
                    logger.warn("exec duplicate while in flight under another owner exec_id=${request.execId}")
                    execution.failTerminal(CODE_IN_FLIGHT, MESSAGE_IN_FLIGHT)
                }

                is ToolAnswer.Rejected -> {
                    logger.warn("exec rejected by the tool seam: ${answer.code} exec_id=${request.execId}")
                    val code = if (answer.code == PhoneToolBridge.CODE_REQUEST_ID_REUSED) {
                        CODE_EXEC_ID_CONFLICT
                    } else {
                        CODE_EXEC_REJECTED
                    }
                    execution.failTerminal(code, MESSAGE_EXEC_REJECTED)
                }
            }
        } catch (cancelled: CancellationException) {
            execution.failTerminal(CODE_INTERRUPTED, MESSAGE_INTERRUPTED)
            throw cancelled
        } catch (failure: Exception) {
            logger.warn("exec driver failed with ${failure.javaClass.simpleName} exec_id=${request.execId}")
            execution.failTerminal(CODE_INTERNAL, MESSAGE_INTERNAL)
        } finally {
            if (!execution.isTerminal) execution.failTerminal(CODE_INTERNAL, MESSAGE_INTERNAL)
            live.settled(execution)
        }
    }

    /**
     * Publishes the ledger's recorded answer into the live log.
     *
     * exec.md §2: replay keeps the recorded `exec_id` and marks the `start`
     * event; a recorded stream that is not replayable answers the same terminal
     * errors the previous implementation used. A recovered in-flight entry is a
     * structured `Failure` from the ledger and becomes its terminal `error`.
     */
    private fun publishReplay(request: ExecRequest, execution: LiveExecution, outcome: ToolOutcome) {
        when (outcome) {
            is ToolOutcome.Success -> {
                val record = try {
                    ExecRecord.parse(outcome.resultJson)
                } catch (corrupt: IllegalArgumentException) {
                    logger.error("exec record is not replayable (${corrupt.message?.substringBefore(':')})")
                    execution.failTerminal(CODE_RECORD_CORRUPT, MESSAGE_RECORD_CORRUPT)
                    return
                }
                if (record.idemKey != request.idemKey) {
                    logger.error("exec replay names another idem_key exec_id=${request.execId}")
                    execution.failTerminal(CODE_RECORD_CORRUPT, MESSAGE_RECORD_CORRUPT)
                    return
                }
                if (record.argv != request.argv || record.cwd != request.cwd) {
                    logger.warn("exec replay conflict: argv/cwd differ exec_id=${request.execId}")
                    execution.failTerminal(CODE_EXEC_ID_CONFLICT, MESSAGE_IDEM_CONFLICT)
                    return
                }
                logger.info(
                    "exec replay: exec_id=${record.execId} idem_key=${record.idemKey}; no second run",
                )
                execution.publishRecord(record)
            }

            is ToolOutcome.Failure -> {
                logger.warn("exec ledger holds a terminal failure (${outcome.code}) exec_id=${request.execId}")
                execution.publishStandaloneError(outcome.code, outcome.message)
            }
        }
    }

    /** exec.md §2.1: wait, never dispatch early. */
    private suspend fun awaitWorkspace(request: ExecRequest): Readiness {
        if (request.requiresMseq == 0L) return Readiness.Ready
        val started = clock.monotonicMillis()
        var announced = false
        while (workspace.appliedMseq() < request.requiresMseq) {
            if (!announced) {
                logger.info(
                    "exec waits for VFS: requires_mseq=${request.requiresMseq} " +
                        "applied_mseq=${workspace.appliedMseq()} exec_id=${request.execId}",
                )
                announced = true
            }
            if (!admission.isOpen()) {
                return Readiness.Refused(CODE_ADMISSION_CLOSED, MESSAGE_ADMISSION_CLOSED)
            }
            if (deadlinePassed(request)) {
                return Readiness.Refused(CODE_DEADLINE_EXCEEDED, MESSAGE_DEADLINE_EXCEEDED)
            }
            if (clock.monotonicMillis() - started >= readinessWaitLimitMs) {
                logger.warn(
                    "exec refused: the workspace did not reach requires_mseq=" +
                        "${request.requiresMseq} exec_id=${request.execId}",
                )
                return Readiness.Refused(CODE_WORKSPACE_NOT_READY, MESSAGE_WORKSPACE_NOT_READY)
            }
            delay(readinessPollMs)
        }
        return Readiness.Ready
    }

    private fun deadlinePassed(request: ExecRequest): Boolean =
        request.deadline?.let { clock.nowMillis() >= it } ?: false

    /**
     * exec.md §2: "An `exec_id` may not be reused for a different `idem_key`."
     *
     * Bounded like the ledger: forgetting an old owner only widens the reuse
     * window, it never allows two live owners of one exec_id at the same time.
     */
    private fun claimExecId(request: ExecRequest): Boolean {
        synchronized(execIdLock) {
            val owner = execIdOwners[request.execId]
            if (owner != null && owner != request.idemKey) return false
            execIdOwners[request.execId] = request.idemKey
            if (execIdOwners.size > MAX_TRACKED_EXEC_IDS) {
                val oldest = execIdOwners.keys.iterator()
                if (oldest.hasNext()) {
                    oldest.next()
                    oldest.remove()
                }
            }
        }
        return true
    }

    private fun refusal(request: ExecRequest, code: String, message: String): ExecEvent =
        ExecEvent.Error(execId = request.execId, seq = ExecEvent.SEQUENCE_START, code = code, message = message)

    private sealed interface Readiness {
        data object Ready : Readiness

        data class Refused(val code: String, val message: String) : Readiness
    }

    /**
     * Wraps one registered tool so the ledger stores the *record* of the live
     * execution, not the raw result. A tool failure is recorded as `start` +
     * terminal `error`, and a cancelled execution stores the cancelled stream
     * even though the in-process tool kept running, so a replay answers the
     * same terminal event instead of a different one.
     */
    private class RecordingTool(
        private val delegate: PhoneTool,
        private val logger: HostLog,
        private val live: LiveExecutions,
    ) : PhoneTool {
        override suspend fun invoke(invocation: ToolInvocation): ToolOutcome {
            val request = try {
                ExecRequest.parse(invocation.argumentsJson)
            } catch (invalid: ExecRequestException) {
                // Impossible for a request this bridge produced; fail closed.
                logger.error("exec tool could not re-read its dispatch request")
                return ToolOutcome.Failure(ExecRecordException.CODE_CORRUPT, "the dispatch request is unreadable")
            }
            val execution = live.find(request.idemKey)
                ?: return ToolOutcome.Failure(ExecRecordException.CODE_CORRUPT, "the live execution is missing")
            execution.begin()
            val events = try {
                when (val outcome = delegate.invoke(invocation)) {
                    is ToolOutcome.Success -> ExecToolResult.parse(outcome.resultJson).events(execution.execId)
                    is ToolOutcome.Failure -> {
                        logger.warn(
                            "exec tool reported a failure (${outcome.code}) exec_id=${request.execId}",
                        )
                        if (outcome.code == CODE_UNSUPPORTED) {
                            // The tool refused the *request shape* (stdin, a
                            // subcommand it does not implement), not a command
                            // that ran and failed. exec.md §3 already has the
                            // precise code; the Worker must not have to guess it
                            // from `tool_failed`.
                            //
                            // The tool's own text is forwarded: it is the only
                            // part that names *which* shape was refused
                            // (`only `phone info` is implemented`). Replacing
                            // it with the generic constant hid that explanation
                            // from the model, which then read the whole
                            // accelerator as broken.
                            terminalFailure(
                                execution.execId,
                                CODE_UNSUPPORTED,
                                refusalMessage(outcome.message),
                            )
                        } else {
                            terminalFailure(execution.execId, CODE_TOOL_FAILED, MESSAGE_TOOL_FAILED)
                        }
                    }
                }
            } catch (cancelled: CancellationException) {
                // The id is abandoned by PhoneToolBridge, so a retry may run.
                throw cancelled
            } catch (invalid: ExecToolResultException) {
                logger.warn("exec tool result is not usable (${invalid.code}) exec_id=${request.execId}")
                val message = if (invalid.code == ExecToolResultException.CODE_TOO_LARGE) {
                    MESSAGE_OUTPUT_TOO_LARGE
                } else {
                    MESSAGE_RESULT_INVALID
                }
                terminalFailure(execution.execId, invalid.code, message)
            } catch (failure: Exception) {
                logger.warn(
                    "exec tool threw ${failure.javaClass.simpleName} exec_id=${request.execId}",
                )
                terminalFailure(execution.execId, CODE_TOOL_FAILED, MESSAGE_TOOL_FAILED)
            }
            // A cancel may have ended the stream while the tool ran; publish
            // then drops every event, and the record is the cancelled stream.
            execution.publish(events)
            return ToolOutcome.Success(execution.toRecord().toJson())
        }

        private fun terminalFailure(execId: String, code: String, message: String): List<ExecEvent> =
            listOf(
                ExecEvent.Start(execId = execId, seq = 0L),
                ExecEvent.Error(execId = execId, seq = 1L, code = code, message = message),
            )

        /**
         * The message a terminal `unsupported` event carries.
         *
         * A [PhoneTool] refusal names the shape it cannot honour and never
         * copies argv or file content into the text (the tool contract), so
         * forwarding it is what lets the model learn the real surface instead
         * of reading a generic "not supported". A blank message falls back to
         * the bridge's own text, and the result is bounded so a pathological
         * tool cannot oversize the event frame.
         */
        private fun refusalMessage(message: String): String {
            val text = message.trim()
            if (text.isEmpty()) return MESSAGE_REQUEST_UNSUPPORTED
            return if (text.length <= MAX_REFUSAL_MESSAGE_CHARS) {
                text
            } else {
                text.take(MAX_REFUSAL_MESSAGE_CHARS - TRUNCATION_MARKER.length) + TRUNCATION_MARKER
            }
        }
    }

    companion object {
        /** exec.md §2 "Admission": no execution, terminal error. */
        const val CODE_ADMISSION_CLOSED: String = "admission_closed"

        /** exec.md §2.2: a deadline that already passed yields a terminal error. */
        const val CODE_DEADLINE_EXCEEDED: String = "deadline_exceeded"

        /**
         * exec.md §3: this host cannot execute the request.
         *
         * Two paths answer it: an `argv[0]` that is not an advertised
         * accelerator (checked before dispatch), and a tool's protocol-level
         * refusal — stdin, or a command shape the C ABI cannot represent. A tool
         * that ran and failed answers [CODE_TOOL_FAILED] instead.
         */
        const val CODE_UNSUPPORTED: String = "unsupported"

        /** Host-side fail-loud bound of exec.md §2.1, used only when no deadline exists. */
        const val CODE_WORKSPACE_NOT_READY: String = "workspace_not_ready"

        /** exec.md §2: a repeated key with another argv/cwd, or a reused exec_id. */
        const val CODE_EXEC_ID_CONFLICT: String = "exec_id_conflict"

        /** Another ledger owner admitted the same key; this bridge cannot join it. */
        const val CODE_IN_FLIGHT: String = "exec_in_flight"

        /** The tool returned a structured failure. */
        const val CODE_TOOL_FAILED: String = "tool_failed"

        /** The tool's result did not follow the exec result contract. */
        const val CODE_RESULT_INVALID: String = ExecToolResultException.CODE_INVALID

        /** The recorded entry could not be replayed. */
        const val CODE_RECORD_CORRUPT: String = ExecRecordException.CODE_CORRUPT

        /** The tool seam refused for another reason (bad name or id). */
        const val CODE_EXEC_REJECTED: String = "exec_rejected"

        /** A host-side failure that is not the tool's (landed handler's `internal`). */
        const val CODE_INTERNAL: String = "internal"

        /** The bridge scope stopped the execution before its terminal event. */
        const val CODE_INTERRUPTED: String = "interrupted"

        /** How often a waiting request re-reads the applied watermark. */
        const val DEFAULT_READINESS_POLL_MS: Long = 10L

        /**
         * A waiting request's fail-loud bound when the request carries no
         * deadline. Never a dispatch: crossing it answers a terminal error.
         */
        const val DEFAULT_READINESS_WAIT_LIMIT_MS: Long = 30_000L

        /** Bound on the in-memory exec_id ownership table. */
        const val MAX_TRACKED_EXEC_IDS: Int = 1024

        /**
         * Longest tool-supplied `unsupported` message the bridge forwards.
         *
         * The tool contract already keeps these token-free and short; the bound
         * exists so one misbehaving tool cannot oversize the terminal event.
         */
        const val MAX_REFUSAL_MESSAGE_CHARS: Int = 240

        /** Mark one forwarded refusal message that was cut at the bound. */
        const val TRUNCATION_MARKER: String = "..."

        private const val MESSAGE_ADMISSION_CLOSED: String =
            "admission is closed; the host started no execution"
        private const val MESSAGE_DEADLINE_EXCEEDED: String =
            "the deadline passed before dispatch; the host started no execution"
        private const val MESSAGE_UNSUPPORTED: String =
            "the command is not an advertised accelerator; it was not executed"
        private const val MESSAGE_STDIN_PIPE_UNSUPPORTED: String =
            "stdin mode pipe is not supported by an in-process accelerator; nothing executed"
        private const val MESSAGE_STDIN_CONTROL_UNSUPPORTED: String =
            "stdin is not supported: an in-process accelerator has no stdin pipe"
        private const val MESSAGE_WORKSPACE_NOT_READY: String =
            "the workspace did not reach requires_mseq; the host started no execution"
        private const val MESSAGE_EXEC_ID_REUSED: String =
            "exec_id was already used for another idem_key; nothing executed"
        private const val MESSAGE_IDEM_CONFLICT: String =
            "idem_key was already executed with a different argv or cwd; nothing executed"
        private const val MESSAGE_IN_FLIGHT: String =
            "the same idem_key is still running under another ledger owner"
        private const val MESSAGE_EXEC_REJECTED: String =
            "the tool registry refused the request; nothing executed"
        private const val MESSAGE_REQUEST_UNSUPPORTED: String =
            "the request is not supported by this in-process accelerator; nothing executed"
        private const val MESSAGE_TOOL_FAILED: String =
            "the tool failed; see the host log"
        private const val MESSAGE_RESULT_INVALID: String =
            "the tool result did not follow the exec result contract"
        private const val MESSAGE_OUTPUT_TOO_LARGE: String =
            "the tool output exceeded the event budget"
        private const val MESSAGE_RECORD_CORRUPT: String =
            "the recorded event stream cannot be replayed; nothing executed"
        private const val MESSAGE_INTERNAL: String =
            "the host failed the execution; see the host log"
        private const val MESSAGE_INTERRUPTED: String =
            "the host stopped the execution before its terminal event"
    }
}
