// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the `ubuntu` host tool.
// SPDX-License-Identifier: MIT
//
// ---- what this is ----
// The host half of the Agent-facing `ubuntu` command. The Worker sends
// `phone ubuntu <op> ...` through the exec bridge (the same host-tool
// dispatcher `phone info` uses), and this class turns each op into one
// `ubuntu.exec` / `ubuntu.status` call on the L47 mock lane:
//
//   probe            is a local environment attached? (the boot probe)
//   run … -- …       ubuntu.exec: approve this session, admit a job, read its record
//   status <jobId>   ubuntu.status
//   fetch <jobId> <name> [--offset N] [--path P]   ubuntu.fetch: one artifact chunk
//   close            stop the environment
//
// ---- the approval gate is before the lane, not inside it --------------------
// `run` asks [UbuntuApprovalGate] first (design §3 layer 1: one approval per
// session). A refusal never reaches `UbuntuJobLane.submit`; it writes a
// `failed` record through `recordRefusal`, so the audit keeps the user's
// decision and `ubuntu.status` can answer for the attempt.
//
// ---- the session is out-of-band, and only the `ubuntu` command carries it ---
// `phone` is an accelerator, so the Worker registers it as an ordinary `bash`
// command: `bash -c 'phone ubuntu run --session S2 -- …'` would be a model-
// typed flag, and binding a grant to it would let the model spend another
// session's approval. The session id therefore never appears in `argv`. The
// Worker's `ubuntu` command reads it from the trusted tool-call context and the
// exec bridge writes it into the EXEC_REQ `env` member
// (`shell-ext/src/bridge.ts`'s `TOOL_CALL_SESSION_ENV`), from which
// [SESSION_ENV] reads it here.
//
// That member is also how "did the `ubuntu` command build this dispatch?" is
// answered: every OTHER dispatch of this tool — a script invoking `phone`
// directly — arrives with the name deleted, and is refused before any dialog.
// A refusal is the honest answer there: the host cannot tell such a request
// from a forged one, so it must not try to ask on its behalf. `probe` is the one
// exception: the boot probe runs before any tool call exists and only reports
// whether this host has an environment.
//
// ---- why the answer is JSON on stdout ----
// `bridge.md` §12.8's status payload is an object, and the Worker command is the
// only place that decides how to render it for the model. Keeping the host side
// structured means the Agent's text is produced once, in `shell-ext`, and the
// host never grows a second wording for the same facts.
//
// ---- what this does NOT do ----
// It does not snapshot, fork a process or read a workspace byte. The session it
// asks is injected: the default is the mock, and the composition root passes a
// factory over the proot adapter. Every answer's `backend` is read from that
// session, so `backend=mock` and `backend=proot` describe which one actually
// answered; this file never writes either as a literal. The seal is not this
// file's either: it is injected (see the `seal` constructor parameter), and
// every answer renders `sealMock` from that implementation instead of writing a
// literal. A real environment replaces the session, not this dispatch surface.

package com.phonedsh.dsh.localexec

import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.dsh.exec.ExecRequest
import com.phonedsh.dsh.exec.ExecRequestException
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.tools.PhoneTool
import com.phonedsh.dsh.tools.ToolInvocation
import com.phonedsh.dsh.tools.ToolOutcome
import com.phonedsh.platform.Clock
import java.util.Base64
import kotlinx.coroutines.CancellationException
import org.json.JSONArray
import org.json.JSONObject

/**
 * The `ubuntu` host tool over the in-process mock environment.
 *
 * @param clock wall time for the lane, the adapter and the wait bound.
 * @param logger token-free host log.
 * @param budgets the tier numbers the JobRef publishes. The mock has no device
 *   measurement, so the caller passes its own tier when it has one; the default
 *   is budgets.md's 8 GiB row.
 * @param admissionOpen the host's admission state, read at job start; the exec
 *   bridge already refused the dispatch when admission was closed.
 * @param approval the session gate. The default is the process-wide gate the app
 *   installs its dialog into; a test passes its own so no global state leaks.
 * @param seal the seal the lane runs each job inside. The mock default keeps this
 *   class's own unit suite device-free; the composition root injects the real
 *   `BuildSealUbuntu` through `HostExec.defaultTools`, whose own default is the
 *   fail-closed `UbuntuSeal.unwired` rather than this one. Every answer renders
 *   `sealMock` from it, so a real chmod window can never be reported as a mock.
 * @param sessionFactory the environment seam. The default is the mock session
 *   this class shipped with, built from the same clock/logger/seal as before;
 *   the composition root injects a factory over `ProotUbuntuAdapter`. Every
 *   answer's `backend` is read from the session this factory returns, never
 *   from a constant, so `backend=proot` cannot appear beside mock behaviour or
 *   the reverse.
 */
class UbuntuHostTool(
    private val clock: Clock,
    private val logger: HostLog = HostLog.None,
    private val budgets: ControllerBudgets = ControllerBudgets.forTier(ControllerBudgets.DEFAULT_TIER),
    private val admissionOpen: () -> Boolean = { true },
    private val approval: UbuntuApprovalGate = UbuntuApproval.gate,
    private val seal: UbuntuSeal = MockUbuntuSeal(),
    private val sessionFactory: UbuntuSessionFactory = UbuntuSessionFactory(
        backend = MockUbuntuSession.BACKEND,
    ) {
        MockUbuntuSession(
            clock = clock,
            budgets = budgets,
            logger = logger,
            seal = seal,
            admissionOpen = admissionOpen,
        )
    },
) : PhoneTool {

    private val lock = Any()

    private var created: UbuntuSession? = null

    /** The lazily created session; construction is cheap and probe touches it. */
    private fun session(): UbuntuSession = synchronized(lock) {
        created ?: sessionFactory.create().also { created = it }
    }

    /** Drop the closed session so the next op opens a fresh one over the store. */
    private fun forget(session: UbuntuSession) {
        synchronized(lock) {
            if (created === session) created = null
        }
    }

    /**
     * The `sealMock` member every answer carries.
     *
     * `UbuntuSeal.isMock` is answered by the implementation, not by the class
     * that renders it: `MockUbuntuSeal` says `true`, the real `BuildSealUbuntu`
     * and the fail-closed `unwired` say `false`. The distinction is the audit's:
     * a `seal: sealed/restored` pair produced by a seam that opens nothing must
     * never read as a protected window, and a real one must not read as a mock.
     */
    private fun sealIsMock(): Boolean = session().sealIsMock

    override suspend fun invoke(invocation: ToolInvocation): ToolOutcome {
        val request = try {
            ExecRequest.parse(invocation.argumentsJson)
        } catch (invalid: ExecRequestException) {
            return ToolOutcome.Failure(CODE_UNSUPPORTED, "the dispatch request is unreadable")
        }
        val argv = request.argv
        if (argv.size < 3 || argv[0] != PHONE_TOOL || argv[1] != UBUNTU_TOOL) {
            return ToolOutcome.Failure(CODE_UNSUPPORTED, REFUSED_OPS)
        }
        val op = argv[2]
        // The boot probe is the one op that runs outside a tool call: it reports
        // whether this host has an environment, decides nothing and starts
        // nothing, so it needs no session to bind.
        if (op == OP_PROBE) return probe()
        if (op !in SESSION_OPS) return ToolOutcome.Failure(CODE_UNSUPPORTED, REFUSED_OPS)
        val session = trustedSession(request)
        if (session == null) {
            // Not "no session to bind, so ask every time": a request the
            // `ubuntu` command did not build is indistinguishable from a forged
            // one, and asking the user on its behalf is the attack. Refuse it
            // before the gate, before any job id and before any dialog.
            logger.warn("ubuntu $op refused: the dispatch carried no trusted tool-call session")
            return ToolOutcome.Failure(CODE_UNSUPPORTED, REFUSED_UNTRUSTED)
        }
        return when (op) {
            OP_RUN -> run(request, argv.subList(3, argv.size), session)
            OP_STATUS -> status(argv.subList(3, argv.size))
            OP_FETCH -> fetch(argv.subList(3, argv.size))
            OP_CLOSE -> close(argv.subList(3, argv.size))
            else -> ToolOutcome.Failure(CODE_UNSUPPORTED, REFUSED_OPS)
        }
    }

    /**
     * The session the Worker carried out of band, or `null` when there is none.
     *
     * [SESSION_ENV] is written by the exec bridge from the trusted tool-call
     * context and deleted from the caller's environment first, so a script that
     * exports the same name changes nothing. A value that is not a D6 identifier
     * is treated as absent: an id the gate cannot validate must not scope a
     * grant, and must not turn into a dialog either.
     */
    private fun trustedSession(request: ExecRequest): String? =
        request.env[SESSION_ENV]?.takeIf { UbuntuApprovalGate.SESSION_ID.matches(it) }

    /** The boot probe: available only when the session's environment really opened. */
    private suspend fun probe(): ToolOutcome {
        val session = try {
            session().also { it.lane() }
        } catch (failure: Exception) {
            logger.warn("ubuntu probe failed (${failure.javaClass.simpleName}); the command stays unregistered")
            return ToolOutcome.Success(
                resultJson(
                    JSONObject()
                        .put("available", false)
                        .put("backend", sessionFactory.backend)
                        .put("reason", "the environment session could not be created"),
                ),
            )
        }
        if (!session.available) {
            return ToolOutcome.Success(
                resultJson(
                    JSONObject()
                        .put("available", false)
                        .put("backend", session.backend)
                        .put("env", session.env)
                        .put("reason", session.unavailableReason ?: "the environment is unavailable"),
                ),
            )
        }
        return ToolOutcome.Success(
            resultJson(
                JSONObject()
                    .put("available", true)
                    .put("backend", session.backend)
                    .put("env", session.env)
                    .put("commands", JSONArray(listOf(OP_RUN, OP_STATUS, OP_FETCH, OP_CLOSE))),
            ),
        )
    }

    /**
     * `ubuntu.exec` behind the session approval gate, then the terminal wait.
     *
     * Ordering is the point: no record is admitted and no adapter is contacted
     * until the gate answers [UbuntuApprovalState.GRANTED]. A refusal is a
     * terminal `failed` record with `outcome = not_started` — a job that never
     * ran, kept in the audit because the user's decision is testimony.
     *
     * @param session the trusted tool-call session that scopes the grant; never
     *   read from `argv` (see the file header).
     */
    private suspend fun run(request: ExecRequest, args: List<String>, session: String): ToolOutcome {
        val parsed = parseRun(args)
            ?: return ToolOutcome.Failure(CODE_UNSUPPORTED, RUN_USAGE)
        val hostSession = session()
        val cwd = parsed.cwd ?: DEFAULT_GUEST_ROOT
        // The real guest receives the host workspace as a bind mount at
        // /dsh/workspace; a cwd outside it would either escape the one subtree
        // the job is allowed to read or fail opaquely inside proot. The adapter
        // checks again (it is the enforcement point); this refusal keeps an
        // impossible request from opening an approval dialog.
        if (hostSession.backend != MockUbuntuSession.BACKEND && !isGuestWorkspace(cwd)) {
            return ToolOutcome.Failure(CODE_UNSUPPORTED, CWD_USAGE)
        }
        val job = try {
            UbuntuExecRequest(
                env = parsed.env ?: hostSession.env,
                argv = parsed.command,
                cwd = cwd,
                workspace = DEFAULT_GUEST_ROOT,
                label = parsed.label,
                jobTimeoutMs = parsed.jobTimeoutMs,
            )
        } catch (invalid: IllegalArgumentException) {
            // The Worker command validates its own flags; a request this side
            // cannot represent is a host defect, not a job. Never echo argv.
            logger.warn("ubuntu run refused a malformed request (${invalid.javaClass.simpleName})")
            return ToolOutcome.Failure(CODE_UNSUPPORTED, "the run request is not representable")
        }
        val decision = approval.authorize(
            UbuntuApprovalRequest(
                sessionId = session,
                env = job.env,
                backend = hostSession.backend,
                label = job.label,
                argvDigest = UbuntuJobLane.digest(job.argv),
                argvLength = job.argv.size,
            ),
        )
        // One audit line per decision, on the host's own logger. The gate's
        // logger is the process-wide default (`None`); this is the log the app
        // actually collects, and the record carries the same decision durably.
        logger.info(
            "ubuntu approval=${decision.state.wire} env=${job.env} " +
                "session=${decision.sessionId?.let(UbuntuApprovalGate::digest) ?: "-"} " +
                "prompted=${decision.prompted}",
        )
        if (decision.state != UbuntuApprovalState.GRANTED) {
            val failure = when (decision.state) {
                UbuntuApprovalState.DENIED -> UbuntuFailures.approvalDenied()
                else -> UbuntuFailures.approvalUnavailable(decision.reason ?: "unknown")
            }
            logger.info("ubuntu run refused before admission: cause=${failure.cause}")
            val record = session().lane().recordRefusal(job, failure, decision.record())
            return if (record != null) {
                ToolOutcome.Success(resultJson(jobPayload(record)))
            } else {
                // The store refused the audit line; answer the same failure
                // without inventing a job id.
                ToolOutcome.Success(resultJson(refusalPayload(failure, decision.record())))
            }
        }
        return when (val submitted = session().submit(job, decision.record())) {
            is UbuntuSubmit.Refused -> ToolOutcome.Success(
                resultJson(failurePayload(submitted.bridgeCode, submitted.message)),
            )

            is UbuntuSubmit.Accepted -> {
                val jobId = submitted.job.jobId
                val waitMs = waitBudgetMs(request, job.jobTimeoutMs)
                val record = try {
                    session().awaitTerminal(jobId, waitMs) ?: submitted.job
                } catch (cancelled: CancellationException) {
                    // The dispatch coroutine is gone, but the job is not: without
                    // this the proot process would keep running after the turn
                    // that asked for it was cancelled. The lane records the
                    // cancellation; the adapter stops the process group.
                    session().lane().cancel(jobId)
                    throw cancelled
                }
                ToolOutcome.Success(resultJson(jobPayload(record)))
            }
        }
    }

    /**
     * `ubuntu.fetch`: one artifact chunk at bridge.md §4's 512 KiB bound.
     *
     * The bytes are base64 in the payload; the Worker writes them through the
     * standard VFS mutation path (it is the only writer of VFS_MUT). The host
     * stages nothing: a chunk is read from the adapter at fetch time.
     */
    private suspend fun fetch(args: List<String>): ToolOutcome {
        val parsed = parseFetch(args)
            ?: return ToolOutcome.Failure(CODE_UNSUPPORTED, FETCH_USAGE)
        if (parsed.path != null && !UbuntuArtifactIngest.isMutationPath(parsed.path)) {
            return ToolOutcome.Failure(CODE_UNSUPPORTED, "the fetch path is not a channel.md §6 mutation path")
        }
        val answer = session().lane().fetchChunk(parsed.jobId, parsed.name, parsed.offset)
        return ToolOutcome.Success(resultJson(fetchPayload(answer)))
    }

    /** `ubuntu.status`: one record, or a truthful "unknown job". */
    private suspend fun status(args: List<String>): ToolOutcome {
        if (args.size != 1 || args[0].isEmpty()) {
            return ToolOutcome.Failure(CODE_UNSUPPORTED, "status takes exactly one job id")
        }
        val jobId = args[0]
        val record = session().status(jobId)
            ?: return ToolOutcome.Success(
                resultJson(
                    JSONObject()
                        .put("backend", session().backend)
                        .put("jobId", jobId)
                        .put("state", "unknown")
                        .put("exitCode", JSONObject.NULL)
                        .put("logTail", "")
                        .put("artifacts", JSONArray())
                        .put("failure", failureObject("provider_unavailable", "unknown", "adapter_gone", "no job $jobId on this host"))
                        .put("internalAccessObserved", JSONObject.NULL)
                        .put("seal", JSONObject().put("state", "pending").put("reason", JSONObject.NULL))
                        .put("sealMock", sealIsMock())
                        .put("egress", false)
                        .put("authorityExited", JSONObject.NULL)
                        .put("approval", JSONObject.NULL),
                ),
            )
        return ToolOutcome.Success(resultJson(jobPayload(record)))
    }

    /** `ubuntu close`: stop every non-terminal job, then report the ids. */
    private suspend fun close(args: List<String>): ToolOutcome {
        if (args.isNotEmpty()) return ToolOutcome.Failure(CODE_UNSUPPORTED, "close takes no arguments")
        val active = session()
        val cancelled = try {
            active.close()
        } catch (failure: Exception) {
            logger.warn("ubuntu close failed (${failure.javaClass.simpleName})")
            return ToolOutcome.Failure(CODE_TOOL_FAILED, "the environment could not be closed")
        }
        // The next op opens a fresh session over the same durable store; the
        // adapter handles of the closed one are already released.
        forget(active)
        return ToolOutcome.Success(
            resultJson(
                JSONObject()
                    .put("closed", true)
                    .put("backend", active.backend)
                    .put("cancelled", JSONArray(cancelled)),
            ),
        )
    }

    /** The one `ExecToolResult` envelope: exit 0, stdout is the JSON payload. */
    private fun resultJson(payload: JSONObject, exitCode: Int = 0): String {
        val stdout = Base64.getEncoder().encodeToString(
            (payload.toString() + "\n").toByteArray(Charsets.UTF_8),
        )
        return JSONObject()
            .put("status", "exited")
            .put("code", exitCode)
            .put("signal", JSONObject.NULL)
            .put("quiescent", true)
            .put("stdout", stdout)
            .put("stderr", "")
            .toString()
    }

    /** The §12.8 record as JSON (never argv, never artifact bytes). */
    private fun jobPayload(record: UbuntuJobRecord): JSONObject {
        val artifacts = JSONArray()
        for (artifact in record.artifacts) {
            artifacts.put(
                JSONObject()
                    .put("name", artifact.name)
                    .put("bytes", artifact.bytes)
                    .put("state", artifact.state.wire)
                    .put("sha256", artifact.sha256 ?: JSONObject.NULL),
            )
        }
        val failure = record.failure?.let { failure ->
            failureObject(
                code = failure.code,
                outcome = failure.outcome,
                cause = failure.cause,
                message = failure.message,
            ).put("retryable", failure.retryable)
                .put("foregroundRequired", failure.foregroundRequired)
        }
        return JSONObject()
            .put("backend", session().backend)
            .put("env", record.env)
            .put("jobId", record.jobId)
            .put("state", record.state.wire)
            .put("seq", record.seq)
            .put("exitCode", record.exitCode ?: JSONObject.NULL)
            .put("logTail", record.logTail)
            .put("artifacts", artifacts)
            .put("failure", failure ?: JSONObject.NULL)
            .put("internalAccessObserved", record.internalAccessObserved ?: JSONObject.NULL)
            .put("seal", JSONObject().put("state", record.seal.wire).put("reason", record.sealReason ?: JSONObject.NULL))
            // Read from the seal that actually ran the job, never written as a
            // literal: `sealed`/`restored` means a real `chmod 000` window unless
            // this flag says the seam that produced it opens nothing.
            .put("sealMock", sealIsMock())
            .put("egress", record.egress)
            .put("authorityExited", record.authorityExited ?: JSONObject.NULL)
            .put("argvDigest", record.argvDigest)
            .put("label", record.label ?: JSONObject.NULL)
            .put("approval", approvalObject(record.approval))
            .put(
                "limits",
                JSONObject()
                    .put("fileLimitBytes", record.limits.fileLimitBytes)
                    .put("workspaceLimitBytes", record.limits.workspaceLimitBytes)
                    .put("rssLimitBytes", record.limits.rssLimitBytes ?: JSONObject.NULL),
            )
    }

    /**
     * The `approval` member of §12.2.
     *
     * `null` means "this record cannot say" — an old record, or a job admitted
     * before the gate existed. It is never a stand-in for a grant.
     */
    private fun approvalObject(approval: UbuntuJobApproval?): Any = if (approval == null) {
        JSONObject.NULL
    } else {
        JSONObject()
            .put("state", approval.state.wire)
            .put("sessionId", approval.sessionId ?: JSONObject.NULL)
            .put("atMs", approval.atMs)
    }

    /** A refusal that created no record, in the status shape the renderer reads. */
    private fun failurePayload(code: String, message: String): JSONObject = JSONObject()
        .put("backend", session().backend)
        .put("state", "failed")
        .put("exitCode", JSONObject.NULL)
        .put("logTail", "")
        .put("artifacts", JSONArray())
        .put("failure", failureObject("provider_unavailable", UbuntuOutcome.NOT_STARTED, null, "$code: $message"))
        .put("internalAccessObserved", JSONObject.NULL)
        .put("seal", JSONObject().put("state", "pending").put("reason", JSONObject.NULL))
        .put("sealMock", sealIsMock())
        .put("egress", false)
        .put("authorityExited", JSONObject.NULL)
        .put("approval", JSONObject.NULL)

    /**
     * A gate refusal whose record could not be persisted: the same failure,
     * answered without a job id. The decision is still carried, because the
     * Worker's renderer reads it and the caller may show it.
     */
    private fun refusalPayload(failure: UbuntuJobFailure, approval: UbuntuJobApproval): JSONObject = JSONObject()
        .put("backend", session().backend)
        .put("state", UbuntuJobState.FAILED.wire)
        .put("exitCode", JSONObject.NULL)
        .put("logTail", "")
        .put("artifacts", JSONArray())
        .put(
            "failure",
            failureObject(failure.code, failure.outcome, failure.cause, failure.message)
                .put("retryable", failure.retryable)
                .put("foregroundRequired", failure.foregroundRequired),
        )
        .put("internalAccessObserved", JSONObject.NULL)
        .put("seal", JSONObject().put("state", UbuntuSealState.PENDING.wire).put("reason", JSONObject.NULL))
        .put("sealMock", sealIsMock())
        .put("egress", false)
        .put("authorityExited", JSONObject.NULL)
        .put("approval", approvalObject(approval))

    /** One `ubuntu.fetch` answer (bridge.md §12.8): chunk, refusal or error. */
    private fun fetchPayload(answer: UbuntuFetch): JSONObject = when (answer) {
        is UbuntuFetch.Chunk -> JSONObject()
            .put("backend", session().backend)
            .put("jobId", answer.jobId)
            .put("name", answer.name)
            .put("offset", answer.offset)
            .put("bytes", answer.bytes)
            .put("eof", answer.eof)
            .put("chunk", Base64.getEncoder().encodeToString(answer.chunk))
            .put("refusal", JSONObject.NULL)
            .put("failure", JSONObject.NULL)
            .put("limits", limitsObject(answer.limits))

        is UbuntuFetch.Refused -> JSONObject()
            .put("backend", session().backend)
            .put("jobId", answer.jobId)
            .put("name", answer.name)
            .put("offset", 0L)
            .put("bytes", answer.refusal.bytes)
            .put("eof", false)
            .put("chunk", JSONObject.NULL)
            .put(
                "refusal",
                JSONObject()
                    .put("code", answer.refusal.code)
                    .put("reason", answer.refusal.reason)
                    .put("limit", answer.refusal.limit)
                    .put("bytes", answer.refusal.bytes),
            )
            .put("failure", JSONObject.NULL)
            .put("limits", limitsObject(answer.limits))

        is UbuntuFetch.Unavailable -> JSONObject()
            .put("backend", session().backend)
            .put("jobId", answer.jobId)
            .put("name", answer.name)
            .put("offset", 0L)
            .put("bytes", JSONObject.NULL)
            .put("eof", false)
            .put("chunk", JSONObject.NULL)
            .put("refusal", JSONObject.NULL)
            .put(
                "failure",
                failureObject(answer.bridgeCode, UbuntuOutcome.NOT_STARTED, null, answer.message),
            )
            .put("limits", JSONObject.NULL)
    }

    /** The JobRef `limits` block, as every answer that carries one renders it. */
    private fun limitsObject(limits: UbuntuJobLimits): JSONObject = JSONObject()
        .put("fileLimitBytes", limits.fileLimitBytes)
        .put("workspaceLimitBytes", limits.workspaceLimitBytes)
        .put("rssLimitBytes", limits.rssLimitBytes ?: JSONObject.NULL)

    private fun failureObject(code: String, outcome: String, cause: String?, message: String): JSONObject =
        JSONObject()
            .put("code", code)
            .put("message", message)
            .put("outcome", outcome)
            .put("retryable", false)
            .put("cause", cause ?: JSONObject.NULL)

    /** How long `run` waits for the record; never past the dispatch deadline. */
    private fun waitBudgetMs(request: ExecRequest, jobTimeoutMs: Long): Long {
        val remaining = request.deadline?.let { (it - clock.nowMillis()).coerceAtLeast(1L) }
            ?: DEFAULT_WAIT_MS
        return remaining.coerceAtMost(jobTimeoutMs + WAIT_MARGIN_MS).coerceAtLeast(1L)
    }

    /**
     * Whether [cwd] is the guest workspace or a directory inside it.
     *
     * One canonical spelling: `/dsh/workspace` itself or `/dsh/workspace/...`,
     * with no empty, `.` or `..` path segment. Checked only for a non-mock
     * backend so the mock's historical acceptance is unchanged; the real
     * adapter repeats the check because it is the enforcement point.
     */
    internal fun isGuestWorkspace(cwd: String): Boolean {
        if (!cwd.startsWith(DEFAULT_GUEST_ROOT)) return false
        if (cwd == DEFAULT_GUEST_ROOT) return true
        if (!cwd.startsWith("$DEFAULT_GUEST_ROOT/")) return false
        return cwd.removePrefix("$DEFAULT_GUEST_ROOT/").split('/').all { it.isNotEmpty() && it != "." && it != ".." }
    }

    /** One parsed `run`. */
    private class RunArgs(
        val env: String?,
        val cwd: String?,
        val label: String?,
        val jobTimeoutMs: Long,
        val command: List<String>,
    )

    /**
     * Parse the run flags; null for any shape this tool cannot honour.
     *
     * `--session` is not one of them: the session is identity and arrives out of
     * band (see the file header). An argv that carries it is refused with
     * [RUN_USAGE] rather than ignored — a silently dropped flag would let a
     * caller believe it chose a session.
     */
    private fun parseRun(args: List<String>): RunArgs? {
        var env: String? = null
        var cwd: String? = null
        var label: String? = null
        var timeoutMs = UbuntuExecRequest.DEFAULT_JOB_TIMEOUT_MS
        var index = 0
        while (index < args.size) {
            val word = args[index]
            if (word == "--") {
                index += 1
                break
            }
            if (
                word != "--env" && word != "--cwd" && word != "--label" &&
                word != "--timeout-ms"
            ) {
                return null
            }
            val value = args.getOrNull(index + 1) ?: return null
            index += 2
            when (word) {
                "--env" -> env = value
                "--cwd" -> cwd = value
                "--label" -> label = value
                "--timeout-ms" -> timeoutMs = value.toLongOrNull() ?: return null
            }
        }
        val command = args.subList(index, args.size)
        if (command.isEmpty()) return null
        return RunArgs(env, cwd, label, timeoutMs, command)
    }

    /** One parsed `fetch`. */
    private class FetchArgs(
        val jobId: String,
        val name: String,
        val offset: Long,
        val path: String?,
    )

    /** Parse `fetch <jobId> <name> [--offset N] [--path P]`; null for a bad shape. */
    private fun parseFetch(args: List<String>): FetchArgs? {
        val positional = mutableListOf<String>()
        var offset = 0L
        var path: String? = null
        var index = 0
        while (index < args.size) {
            val word = args[index]
            if (word == "--offset" || word == "--path") {
                val value = args.getOrNull(index + 1) ?: return null
                index += 2
                if (word == "--offset") {
                    offset = value.toLongOrNull()?.takeIf { it >= 0L } ?: return null
                } else {
                    if (value.isEmpty()) return null
                    path = value
                }
                continue
            }
            if (word.startsWith("--")) return null
            positional += word
            index += 1
        }
        if (positional.size != 2) return null
        if (!UbuntuJobRecord.JOB_ID.matches(positional[0])) return null
        if (!UbuntuArtifactRecord.NAME.matches(positional[1])) return null
        return FetchArgs(positional[0], positional[1], offset, path)
    }

    companion object {
        /** The `phone` tool name; `argv[0]` of every dispatch. */
        const val PHONE_TOOL: String = "phone"

        /** The sub-tool this class owns. */
        const val UBUNTU_TOOL: String = "ubuntu"

        /** The five ops. */
        const val OP_PROBE: String = "probe"
        const val OP_RUN: String = "run"
        const val OP_STATUS: String = "status"
        const val OP_FETCH: String = "fetch"
        const val OP_CLOSE: String = "close"

        /**
         * The ops that need a trusted tool-call session: every op but the probe.
         *
         * `probe` runs before any tool call exists and decides nothing; the rest
         * are the Agent's lane and are only reachable through the Worker's
         * `ubuntu` command (see the file header).
         */
        val SESSION_OPS: Set<String> = setOf(OP_RUN, OP_STATUS, OP_FETCH, OP_CLOSE)

        /**
         * The EXEC_REQ `env` member that carries the trusted tool-call session.
         *
         * Written by the exec bridge from the Worker's `currentToolCall()`
         * context (`shell-ext/src/bridge.ts`'s `TOOL_CALL_SESSION_ENV`), and
         * deleted from whatever the shell exported first. It is not part of the
         * EXEC_REQ schema — `env` is — so the wire does not change; this is the
         * host-private payload the session binding travels in.
         */
        const val SESSION_ENV: String = "PDSH_TOOL_CALL_SESSION"

        /** The refusal message for an op outside the five. */
        const val REFUSED_OPS: String = "only `phone ubuntu <probe|run|status|fetch|close>` is implemented"

        /**
         * The refusal for a dispatch that carried no trusted session.
         *
         * It names the only caller entitled to dispatch this tool, because the
         * model can read this sentence after `phone ubuntu run …` from a script.
         */
        const val REFUSED_UNTRUSTED: String =
            "ubuntu run/status/fetch/close are only reachable through the Worker's `ubuntu` command; " +
                "this dispatch carried no trusted tool-call session"

        /** The `run` and `fetch` shapes, for a malformed dispatch. */
        const val RUN_USAGE: String = "run takes [--env V] [--cwd P] [--label L] [--timeout-ms N] -- <command…>"
        const val FETCH_USAGE: String = "fetch takes <jobId> <name> [--offset N] [--path P]"

        /** The refusal for a real-backend cwd outside the one bound subtree. */
        const val CWD_USAGE: String = "run --cwd must be /dsh/workspace or a directory inside it for the real backend"

        /** The one guest root the mock advertises (bridge.md §12.2's default). */
        const val DEFAULT_GUEST_ROOT: String = "/dsh/workspace"

        /** Fallback wait when the dispatch carried no deadline. */
        const val DEFAULT_WAIT_MS: Long = 60_000L

        /** Slack over the job deadline before `run` stops waiting. */
        const val WAIT_MARGIN_MS: Long = 5_000L

        /** Stable refusal: the request shape is not this tool's. */
        const val CODE_UNSUPPORTED: String = "unsupported"

        /** Stable refusal: the environment could not be stopped. */
        const val CODE_TOOL_FAILED: String = "tool_failed"
    }
}
