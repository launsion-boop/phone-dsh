// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the per-session approval gate.
// SPDX-License-Identifier: MIT
//
// ---- what this file is ------------------------------------------------------
// Design §3 layer 1 asks for **one user approval per session**: the first
// `ubuntu run` in a session shows a confirmation, the user's answer covers the
// rest of that session, and the grant dies with the session. This file is that
// gate. It is deliberately separate from the UI: the gate owns the decision and
// its scope, the app owns the dialog.
//
// ---- why the session id comes from the caller ---------------------------------
// The gate cannot know what a session is: `:dsh` sees host tool calls, not DSH
// conversations. The Worker does know — the ambient tool-call context carries
// the session id — so `ubuntu run` forwards it out of band (the EXEC_REQ `env`
// member the exec bridge writes from that context; never an argv flag, because
// `phone` is an ordinary `bash` command and `--session` would be a flag the
// model can type) and the gate binds the grant to exactly that id. Two
// consequences, both intended:
//
//   * an unknown session id (no tool-call context) never binds: the gate asks on
//     **every** run, because it has nothing to scope a grant to. The `ubuntu`
//     host tool refuses such a dispatch before it reaches this gate, so in the
//     device's own lane this is a defence-in-depth branch, not the normal path;
//   * a *different* session id invalidates the previous grant, so "the approval
//     does not cross a session" holds even if the app process outlives the
//     session that granted it. [endSession] is the explicit hook for the case
//     where the session ends without another one starting (the app calls it when
//     the local engine stops).
//
// ---- refusal is not a timeout and not a success ------------------------------
// A denial is answered with the job failure `cancelled` / `outcome: not_started`
// / `cause: approval_denied` and a record of its own, so the audit can see that
// nothing ran and why. An absent UI — a headless host, a test without a prompt —
// is `approval_unavailable`, the same truthful class: the host could not ask,
// so it must not run. Both fail closed.
//
// ---- why a denial is remembered ----------------------------------------------
// A denial binds to the session exactly like an approval does. Re-asking on
// every `run` would turn the confirmation into the reflex the design §3 says
// per-session approval exists to avoid; the user can clear it with [revoke]
// (or by ending the session), after which the next run asks again.

package com.phonedsh.dsh.localexec

import com.phonedsh.dsh.host.HostLog
import com.phonedsh.platform.Clock
import java.security.MessageDigest
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * What one approval request tells the user.
 *
 * It never carries `argv`: the dialog describes the *environment* and the use,
 * and the command itself is named by [argvDigest] in the audit (the job record's
 * own rule — a command line is where a credential leaks).
 *
 * @param sessionId the DSH session the grant would bind to, or `null` when the
 *   caller had no session context (then no grant is stored). The `ubuntu` host
 *   tool only reaches this request with a session it read out of band from the
 *   Worker, so a `null` here means "a path the host does not let a model take".
 * @param env the environment id the job would run in (`ubuntu-24.04`, …).
 * @param backend the session's backend name (`mock` or `proot`); read from the
 *   session, never from a constant, so a real environment cannot show as a mock.
 * @param label the caller's short audit label, if any.
 * @param argvDigest the job's `argv` digest, never the argv.
 * @param argvLength how many arguments the command has.
 */
data class UbuntuApprovalRequest(
    val sessionId: String?,
    val env: String,
    val backend: String,
    val label: String?,
    val argvDigest: String,
    val argvLength: Int,
) {
    init {
        require(env.isNotEmpty()) { "an approval request names its environment" }
        require(argvDigest.length == 64) { "argvDigest is a sha256 hex digest" }
        require(argvLength >= 1) { "an approved command has at least one argument" }
    }
}

/** What the user — or the absence of a UI — answered. */
sealed interface UbuntuApprovalDecision {
    /** The user allowed this session. */
    data object Approved : UbuntuApprovalDecision

    /** The user declined this session. */
    data object Denied : UbuntuApprovalDecision

    /**
     * Nobody could answer: no dialog is attached, or it did not answer in time.
     * [reason] is a short stable token (`no_approval_surface`, `approval_timeout`).
     */
    data class Unavailable(val reason: String) : UbuntuApprovalDecision
}

/** The host surface that shows the confirmation and returns the user's answer. */
fun interface UbuntuApprovalPrompt {
    /**
     * Shows one confirmation and suspends until it is answered.
     *
     * Implementations must not throw for a user gesture: a dismissed dialog is
     * [UbuntuApprovalDecision.Denied], and a surface that cannot render at all is
     * [UbuntuApprovalDecision.Unavailable].
     */
    suspend fun ask(request: UbuntuApprovalRequest): UbuntuApprovalDecision
}

/**
 * One decision as it is written into the job record's `approval` member.
 *
 * @param state `granted` / `denied` / `unavailable` (bridge.md §12.2).
 * @param sessionId the session the decision was bound to, or `null` when the
 *   caller had no session context.
 * @param atMs when the decision was taken.
 */
data class UbuntuJobApproval(
    val state: UbuntuApprovalState,
    val sessionId: String?,
    val atMs: Long,
) {
    init {
        require(atMs >= 0) { "an approval timestamp is non-negative" }
        require(sessionId == null || UbuntuApprovalGate.SESSION_ID.matches(sessionId)) {
            "an approval session id is a D6 identifier"
        }
    }
}

/** `approval.state` (bridge.md §12.2). */
enum class UbuntuApprovalState(val wire: String) {
    /** The user allowed this session; the job may run. */
    GRANTED("granted"),

    /** The user declined this session; nothing started. */
    DENIED("denied"),

    /** The host had no way to ask; nothing started. */
    UNAVAILABLE("unavailable"),

    ;

    companion object {
        fun ofWire(raw: String): UbuntuApprovalState? = entries.firstOrNull { it.wire == raw }
    }
}

/**
 * One gate answer: the decision plus the facts the job record needs.
 *
 * @param state the wire decision.
 * @param sessionId the bound session (may be `null`).
 * @param prompted `true` when a dialog was actually shown. `false` means the
 *   grant or denial from an earlier run answered it.
 * @param atMs the decision time.
 * @param reason a stable token for [UbuntuApprovalState.UNAVAILABLE].
 */
data class UbuntuApprovalOutcome(
    val state: UbuntuApprovalState,
    val sessionId: String?,
    val prompted: Boolean,
    val atMs: Long,
    val reason: String? = null,
) {
    /** The audit member for the job record. */
    fun record(): UbuntuJobApproval = UbuntuJobApproval(state, sessionId, atMs)
}

/**
 * The session-scoped approval gate.
 *
 * @param prompt the current UI surface, read at each decision so an app may
 *   install or remove it after this object exists; `null` means "cannot ask".
 * @param clock wall time, for the decision's `atMs`.
 * @param logger token-free host log; every decision leaves one line.
 * @param timeoutMillis how long a dialog may stay unanswered. A timeout is
 *   [UbuntuApprovalDecision.Unavailable], never a denial: the user did not say no.
 */
class UbuntuApprovalGate(
    private val prompt: () -> UbuntuApprovalPrompt?,
    private val clock: Clock,
    private val logger: HostLog = HostLog.None,
    private val timeoutMillis: Long = DEFAULT_TIMEOUT_MS,
) {
    private val mutex = Mutex()

    /** The session the current [decision] belongs to, or `null` for none. */
    @Volatile
    private var session: String? = null

    @Volatile
    private var decision: UbuntuApprovalDecision? = null

    @Volatile
    private var decidedAtMs: Long = 0L

    /**
     * Decides whether one job may run.
     *
     * One dialog at a time: a second `run` that arrives while the first is
     * waiting serializes behind it and then reads the decision. The prompt is
     * shown while [mutex] is held, because a dialog *is* the critical section:
     * two concurrent confirmations for one session would be the same question
     * asked twice.
     *
     * @param request the facts the dialog and the audit need.
     * @returns the decision, bound to [UbuntuApprovalRequest.sessionId].
     */
    suspend fun authorize(request: UbuntuApprovalRequest): UbuntuApprovalOutcome = mutex.withLock {
        val key = request.sessionId?.takeIf { SESSION_ID.matches(it) }
        if (key != null && key == session) {
            when (val prior = decision) {
                UbuntuApprovalDecision.Approved -> {
                    logger.info("ubuntu approval=granted env=${request.env} session=${digest(key)} prompted=false")
                    return@withLock UbuntuApprovalOutcome(
                        state = UbuntuApprovalState.GRANTED,
                        sessionId = key,
                        prompted = false,
                        atMs = decidedAtMs,
                    )
                }

                UbuntuApprovalDecision.Denied -> {
                    logger.info("ubuntu approval=denied env=${request.env} session=${digest(key)} prompted=false")
                    return@withLock UbuntuApprovalOutcome(
                        state = UbuntuApprovalState.DENIED,
                        sessionId = key,
                        prompted = false,
                        atMs = decidedAtMs,
                    )
                }

                else -> Unit
            }
        }
        // A different session (or no session) invalidates the previous grant:
        // an approval never crosses a session boundary.
        if (key != session) {
            session = key
            decision = null
            decidedAtMs = 0L
        }
        val surface = prompt()
        if (surface == null) {
            logger.warn("ubuntu approval=unavailable env=${request.env} reason=no_approval_surface")
            return@withLock UbuntuApprovalOutcome(
                state = UbuntuApprovalState.UNAVAILABLE,
                sessionId = key,
                prompted = false,
                atMs = clock.nowMillis(),
                reason = REASON_NO_SURFACE,
            )
        }
        val answer = withTimeoutOrNull(timeoutMillis) { surface.ask(request) }
            ?: UbuntuApprovalDecision.Unavailable(REASON_TIMEOUT)
        val atMs = clock.nowMillis()
        when (answer) {
            UbuntuApprovalDecision.Approved -> {
                session = key
                decision = answer
                decidedAtMs = atMs
                logger.info("ubuntu approval=granted env=${request.env} session=${key?.let(::digest) ?: "-"} prompted=true")
                UbuntuApprovalOutcome(UbuntuApprovalState.GRANTED, key, prompted = true, atMs = atMs)
            }

            UbuntuApprovalDecision.Denied -> {
                session = key
                decision = answer
                decidedAtMs = atMs
                logger.info("ubuntu approval=denied env=${request.env} session=${key?.let(::digest) ?: "-"} prompted=true")
                UbuntuApprovalOutcome(UbuntuApprovalState.DENIED, key, prompted = true, atMs = atMs)
            }

            is UbuntuApprovalDecision.Unavailable -> {
                // Not remembered: "the host could not ask" is not the user's answer.
                logger.warn("ubuntu approval=unavailable env=${request.env} reason=${answer.reason}")
                UbuntuApprovalOutcome(
                    state = UbuntuApprovalState.UNAVAILABLE,
                    sessionId = key,
                    prompted = true,
                    atMs = atMs,
                    reason = answer.reason,
                )
            }
        }
    }

    /**
     * Drops the grant (and the denial) for the current session.
     *
     * The app's hook for "the session ended": the next `ubuntu run` asks again.
     * Idempotent, and safe to call while a dialog is open — that dialog's answer
     * binds to the session it named, and [endSession] after it clears again.
     */
    fun endSession(): Boolean {
        synchronized(this) {
            val had = decision != null
            session = null
            decision = null
            decidedAtMs = 0L
            return had
        }
    }

    /**
     * The user's "revoke this session": the next run asks again. Same as
     * [endSession], and it reports whether there was anything to undo — the
     * settings row says "nothing was granted" instead of claiming a change it
     * did not make.
     */
    fun revoke(): Boolean = endSession()

    /**
     * The session a current grant/denial is bound to, for tests and diagnostics.
     *
     * `null` while the last answer was "the host could not ask": a session with
     * no decision is not a bound session.
     */
    fun boundSession(): String? = synchronized(this) { session.takeIf { decision != null } }

    companion object {
        /** channel.md §6's D6 identifier rule; a session id follows it. */
        val SESSION_ID = Regex("^[A-Za-z0-9._-]{1,64}$")

        /** How long a confirmation may stay unanswered before it is "unavailable". */
        const val DEFAULT_TIMEOUT_MS: Long = 60_000L

        const val REASON_NO_SURFACE: String = "no_approval_surface"
        const val REASON_TIMEOUT: String = "approval_timeout"

        /** A short, token-free name for one session in a log line. */
        fun digest(sessionId: String): String {
            val bytes = MessageDigest.getInstance("SHA-256").digest(sessionId.toByteArray(Charsets.UTF_8))
            return bytes.take(4).joinToString("") { byte -> "%02x".format(byte) }
        }

        /** What [summary] says when the caller had no bindable session. */
        const val NO_SESSION: String = "none"

        /**
         * The session name a person can read and compare: 8 hex of [digest].
         *
         * The `ubuntu` confirmation shows this string. It has to be shown even
         * though the dialog is native and the gate already knows the session,
         * because the user's only defence against a later forged-session path is
         * recognizing "this is not the session I just refused". Two properties
         * are load-bearing:
         *
         *   * it is derived from the session id, so the same session always
         *     shows the same 8 hex and a different one shows different hex;
         *   * it is a digest, not the id, so the dialog never prints a raw DSH
         *     session identifier.
         */
        fun summary(sessionId: String?): String =
            sessionId?.takeIf { SESSION_ID.matches(it) }?.let(::digest) ?: NO_SESSION
    }
}

/**
 * The process-wide gate and the one place an app installs its dialog.
 *
 * The app calls [install] with a prompt; a host that never installs one keeps
 * failing closed (`approval_unavailable`), which is the honest answer for "no
 * user can be asked here".
 */
object UbuntuApproval {
    @Volatile
    private var installed: UbuntuApprovalPrompt? = null

    /**
     * The gate's clock. `:dsh` depends on the `Clock` SPI, not on a platform
     * adapter, so the process-wide gate reads the system clock directly — the
     * same two readings `AndroidClock` makes.
     */
    private object WallClock : Clock {
        override fun nowMillis(): Long = System.currentTimeMillis()

        override fun monotonicMillis(): Long = System.nanoTime() / 1_000_000L
    }

    /** The one gate the `ubuntu` host tool uses when it is not given one. */
    val gate: UbuntuApprovalGate = UbuntuApprovalGate(
        prompt = { installed },
        clock = WallClock,
    )

    /**
     * Installs (or clears) the dialog.
     * @param prompt the surface, or `null` to remove it.
     * @returns the prompt this replaced, so a test or a host can restore it.
     */
    fun install(prompt: UbuntuApprovalPrompt?): UbuntuApprovalPrompt? {
        val previous = installed
        installed = prompt
        return previous
    }

    /** The currently installed surface, or `null`. */
    fun installedPrompt(): UbuntuApprovalPrompt? = installed

    /** The session ended: the next run asks again. */
    fun endSession() = gate.endSession()

    /** The user revoked the session's grant: the next run asks again. */
    fun revoke() = gate.revoke()
}
