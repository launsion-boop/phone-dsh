// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the `ubuntu.exec` failure vocabulary.
// SPDX-License-Identifier: MIT
//
// ---- the rule this file obeys ----------------------------------------------
// bridge.md §12.6: reuse the vocabulary `spec/v1/` already has. The four codes
// below are the phone-provider set the repo already returns to the worker
// (`plugins/shell-ext/src/phone-errors.ts:38-58`, `exec.md` §2.2) and the three
// outcomes are its three outcomes; `cause` is that file's own sub-reason member,
// not a fifth code. Nothing here invents a code: a condition that has no word is
// reported as the nearest existing one plus a `cause`, and the cause set is
// closed in [UbuntuCause].
//
// ---- the one that needs explaining ------------------------------------------
// A **seal** failure is `provider_unavailable` + `cause = "seal_failed"`, not
// `admission_closed`. The host is admitting work and refusing *this* job because
// a precondition it controls did not hold; `admission_closed` means the host is
// not admitting at all (`exec.md` §2, `foreground_required: true`). Collapsing
// the two would make the audit unable to tell "come back to the foreground" from
// "this device could not protect its own storage", which are different things
// for the user to do something about.
//
// ---- `retryable` is not a mood ---------------------------------------------
// §12.6: `false` whenever `outcome != not_started` (the command may have run, so
// a retry could duplicate a side effect — the rule `exec.md` §2.2 states for
// artifact-producing writes). For a job that did not start it is the cause's
// judgement: `true` for `admission_closed` and `memory_insufficient`, `false`
// for `env_unavailable`, `seal_failed` and `snapshot_too_large`, which a retry
// of the same command cannot fix.

package com.phonedsh.dsh.localexec

/** The three `outcome` values the existing provider vocabulary has. */
object UbuntuOutcome {
    /** No `argv` ran; the command did not start. Retrying is safe. */
    const val NOT_STARTED = "not_started"

    /** A caller or the host stopped the job. */
    const val CANCELLED = "cancelled"

    /** The command may have run and its exit is not in hand. Never auto-retried. */
    const val UNKNOWN = "unknown"
}

/** The closed `cause` set of bridge.md §12.6 plus §12.3's boot rows. */
object UbuntuCause {
    const val ENV_UNAVAILABLE = "env_unavailable"
    const val MEMORY_INSUFFICIENT = "memory_insufficient"
    const val SNAPSHOT_TOO_LARGE = "snapshot_too_large"
    const val SEAL_FAILED = "seal_failed"
    const val HOST_DRAINING = "host_draining"
    const val DRAIN_DEADLINE = "drain_deadline"
    const val JOB_TIMEOUT = "job_timeout"
    const val MEMORY_RECLAIMED = "memory_reclaimed"
    const val ADAPTER_GONE = "adapter_gone"
    const val ADAPTER_FAILED = "adapter_failed"
    const val ADAPTER_REFUSED = "adapter_refused"
    const val HANDOFF_LOST = "handoff_lost"
    const val HOST_LOST = "host_lost"
    const val INGEST_LOST = "ingest_lost"
    const val PAGE_CANCEL = "page_cancel"

    /**
     * The user declined the local environment for this session (design §3
     * layer 1). A cancel that never reached an adapter: nothing ran.
     */
    const val APPROVAL_DENIED = "approval_denied"

    /** No confirmation could be shown or answered, so the run failed closed. */
    const val APPROVAL_UNAVAILABLE = "approval_unavailable"
}

/** One job failure; `message` never carries a path, a token or a file byte. */
data class UbuntuJobFailure(
    val code: String,
    val message: String,
    val outcome: String,
    val retryable: Boolean,
    val foregroundRequired: Boolean = false,
    val cause: String? = null,
) {
    init {
        require(code in CODES) { "not a code spec/v1 already has: $code" }
        require(outcome in OUTCOMES) { "not an outcome spec/v1 already has: $outcome" }
        require(message.length <= MAX_MESSAGE) { "message is over $MAX_MESSAGE characters" }
        require(!retryable || outcome == UbuntuOutcome.NOT_STARTED) {
            "a job that may have run is never automatically retryable (exec.md §2.2)"
        }
    }

    companion object {
        const val PROVIDER_UNAVAILABLE = "provider_unavailable"
        const val PROVIDER_TIMEOUT = "provider_timeout"
        const val ADMISSION_CLOSED = "admission_closed"
        const val CANCELLED = "cancelled"

        /** The four codes §12.6 is allowed to use; anything else is a new word. */
        val CODES: Set<String> =
            setOf(PROVIDER_UNAVAILABLE, PROVIDER_TIMEOUT, ADMISSION_CLOSED, CANCELLED)

        val OUTCOMES: Set<String> =
            setOf(UbuntuOutcome.NOT_STARTED, UbuntuOutcome.CANCELLED, UbuntuOutcome.UNKNOWN)

        /** bridge.md §5's 512-character bound, applied to a job message too. */
        const val MAX_MESSAGE = 512
    }
}

/** The §12.6 table, one factory per row. */
object UbuntuFailures {
    fun envUnavailable(env: String): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.PROVIDER_UNAVAILABLE,
        message = "no adapter for env '$env' on this host",
        outcome = UbuntuOutcome.NOT_STARTED,
        retryable = false,
        cause = UbuntuCause.ENV_UNAVAILABLE,
    )

    fun memoryInsufficient(availableBytes: Long, requiredBytes: Long): UbuntuJobFailure =
        UbuntuJobFailure(
            code = UbuntuJobFailure.PROVIDER_UNAVAILABLE,
            message = "available memory $availableBytes is below the job's $requiredBytes budget",
            outcome = UbuntuOutcome.NOT_STARTED,
            retryable = true,
            cause = UbuntuCause.MEMORY_INSUFFICIENT,
        )

    fun snapshotTooLarge(bytes: Long, stagingLimitBytes: Long): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.PROVIDER_UNAVAILABLE,
        message = "input snapshot is $bytes bytes; the $stagingLimitBytes staging bucket is smaller",
        outcome = UbuntuOutcome.NOT_STARTED,
        retryable = false,
        cause = UbuntuCause.SNAPSHOT_TOO_LARGE,
    )

    /** Fail-closed: the job must not start, and nothing may reach an adapter. */
    fun sealFailed(reason: String): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.PROVIDER_UNAVAILABLE,
        message = "the internal roots could not be sealed ($reason); the job was not started",
        outcome = UbuntuOutcome.NOT_STARTED,
        retryable = false,
        cause = UbuntuCause.SEAL_FAILED,
    )

    /** `admission_closed`'s own row: after a resume the host is not accepting work. */
    fun admissionClosed(): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.ADMISSION_CLOSED,
        message = "the host is not admitting work; return to the foreground or wait for recovery",
        outcome = UbuntuOutcome.NOT_STARTED,
        retryable = true,
        foregroundRequired = true,
    )

    fun cancelled(cause: String): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.CANCELLED,
        message = "the job was stopped by the host ($cause)",
        outcome = UbuntuOutcome.CANCELLED,
        // The command ran for a while: a retry could duplicate what it already
        // did, so the host never re-issues it on the caller's behalf (§12.6).
        retryable = false,
        cause = cause,
    )

    /**
     * A cancel that arrived before any adapter was contacted.
     *
     * `outcome: not_started` is the truth and it is the one case where a
     * cancelled job may be retried: nothing ran.
     */
    fun cancelledBeforeStart(cause: String): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.CANCELLED,
        message = "the job was cancelled before anything left the host ($cause)",
        outcome = UbuntuOutcome.NOT_STARTED,
        retryable = true,
        cause = cause,
    )

    /**
     * The user declined the local environment for this session (design §3
     * layer 1).
     *
     * `code = cancelled` with `outcome = not_started` is the existing vocabulary's
     * own reading of "a stop arrived before any adapter was contacted"; the
     * message says what actually happened. `retryable = false` because the
     * denial is bound to the session: the same run would be refused again until
     * the session ends or the user revokes.
     */
    fun approvalDenied(): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.CANCELLED,
        message = "the user declined the local environment for this session; nothing was started",
        outcome = UbuntuOutcome.NOT_STARTED,
        retryable = false,
        cause = UbuntuCause.APPROVAL_DENIED,
    )

    /**
     * No confirmation could be shown or answered, so the run failed closed.
     *
     * This is not a denial: the user never said no. It is also not a job that
     * ran — `outcome = not_started` is the fact, and no adapter was contacted.
     */
    fun approvalUnavailable(reason: String): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.PROVIDER_UNAVAILABLE,
        message = "the approval confirmation could not be answered ($reason); nothing was started",
        outcome = UbuntuOutcome.NOT_STARTED,
        retryable = false,
        cause = UbuntuCause.APPROVAL_UNAVAILABLE,
    )

    fun adapterFailed(reason: String): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.PROVIDER_UNAVAILABLE,
        message = "the environment failed while the job was in flight ($reason)",
        outcome = UbuntuOutcome.UNKNOWN,
        retryable = false,
        cause = UbuntuCause.ADAPTER_FAILED,
    )

    /** A resumed job whose window could not be re-established: the command may have run. */
    fun sealLost(reason: String): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.PROVIDER_UNAVAILABLE,
        message = "the job's seal could not be re-established after a restart ($reason)",
        outcome = UbuntuOutcome.UNKNOWN,
        retryable = false,
        cause = UbuntuCause.SEAL_FAILED,
    )

    fun drainDeadline(): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.PROVIDER_TIMEOUT,
        message = "the drain deadline expired before the environment reported an exit",
        outcome = UbuntuOutcome.UNKNOWN,
        retryable = false,
        cause = UbuntuCause.DRAIN_DEADLINE,
    )

    fun jobTimeout(): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.PROVIDER_TIMEOUT,
        message = "the job deadline expired and the environment did not report an exit",
        outcome = UbuntuOutcome.UNKNOWN,
        retryable = false,
        cause = UbuntuCause.JOB_TIMEOUT,
    )

    fun adapterGone(): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.PROVIDER_UNAVAILABLE,
        message = "the environment no longer has this job",
        outcome = UbuntuOutcome.UNKNOWN,
        retryable = false,
        cause = UbuntuCause.ADAPTER_GONE,
    )

    fun adapterRefused(reason: String): UbuntuJobFailure = UbuntuJobFailure(
        code = UbuntuJobFailure.PROVIDER_UNAVAILABLE,
        message = "the environment refused to start the command ($reason)",
        outcome = UbuntuOutcome.NOT_STARTED,
        retryable = true,
        cause = UbuntuCause.ADAPTER_REFUSED,
    )

    /**
     * The host process died with the job in a durable non-terminal state.
     *
     * [outcome] is the boot row's decision and never a guess: a job that never
     * reached an adapter is `not_started` (and retryable, because nothing ran),
     * one that did is `unknown` (and never auto-retried).
     */
    fun lost(cause: String, outcome: String = UbuntuOutcome.UNKNOWN): UbuntuJobFailure =
        UbuntuJobFailure(
            code = UbuntuJobFailure.PROVIDER_UNAVAILABLE,
            message = when {
                outcome == UbuntuOutcome.NOT_STARTED ->
                    "the host process died before the job reached an environment"

                cause == UbuntuCause.MEMORY_RECLAIMED ->
                    "the app was reclaimed under memory pressure while the job was in flight"

                else -> "the host process died with the job in flight"
            },
            outcome = outcome,
            retryable = outcome == UbuntuOutcome.NOT_STARTED,
            cause = cause,
        )
}
