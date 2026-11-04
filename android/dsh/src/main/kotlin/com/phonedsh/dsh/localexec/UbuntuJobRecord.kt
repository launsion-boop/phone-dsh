// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the `ubuntu.exec` record and its limits.
// SPDX-License-Identifier: MIT
//
// ---- what the record is -----------------------------------------------------
// The durable JobRef of bridge.md §12.2 plus the §12.8 status payload. It is one
// JSON object per job, replaced atomically (`Durability.atomicReplace`), because
// every write here is either a state change or an artifact-state change and a
// half-written record would break the only thing this file is for: after a
// process kill the job must still be readable and its `egress` /
// `authorityExited` testimony must still be true.
//
// ---- the three numbers ------------------------------------------------------
// 15 MiB is `channel.md` §6's **per-mutation** bound, not a file bound — that
// document says so in as many words ("a larger file is one complete write plus
// appended suffixes"), and budgets.md §6 records that 15 MiB "survives only as
// the per-mutation frame bound". So:
//
//   * one mutation carries at most [MUTATION_MAX_BYTES] (15 MiB);
//   * one artifact may be ingested up to `fileLimitBytes`, which defaults to
//     the same 15 MiB — one atomic mutation that cannot leave half a file — and
//     an environment may raise it to the tier's `single_file_limit`
//     (16 MiB … 256 MiB, budgets.md §4), in which case the append chain of
//     channel.md §6 carries it;
//   * the aggregate is the workspace bucket, 288 MB on the default 8 GiB row.
//
// The raise is declared in the JobRef, so the limit a caller has to respect is a
// published number rather than a surprise found halfway through an ingest.
//
// ---- why the fetch chunk is 512 KiB ----------------------------------------
// bridge.md §4 caps one binary payload at 512 KiB decoded (699 052 base64
// characters, chosen there to leave room under the 1 MiB response cap). The
// host therefore cannot hand 15 MiB over in one message, and the page cannot ask
// for it: [FETCH_CHUNK_BYTES] is that bound, not a new constant.

package com.phonedsh.dsh.localexec

import com.phonedsh.controller.ControllerBudgets

/** The JobRef's `limits` member and the constants behind it (bridge.md §12.7). */
data class UbuntuJobLimits(
    val fileLimitBytes: Long,
    val workspaceLimitBytes: Long,
    val rssLimitBytes: Long?,
) {
    init {
        require(fileLimitBytes in DEFAULT_FILE_LIMIT_BYTES..MAX_FILE_LIMIT_BYTES) {
            "fileLimitBytes $fileLimitBytes is outside " +
                "$DEFAULT_FILE_LIMIT_BYTES..$MAX_FILE_LIMIT_BYTES"
        }
        require(workspaceLimitBytes > 0) { "workspaceLimitBytes must be positive" }
    }

    companion object {
        const val MIB: Long = 1_048_576L

        /** `channel.md` §3.1/§6: one `op = 1` mutation carries at most 15 MiB. */
        const val MUTATION_MAX_BYTES: Long = 15L * MIB

        /** The default per-artifact ingest bound: exactly one complete mutation. */
        const val DEFAULT_FILE_LIMIT_BYTES: Long = MUTATION_MAX_BYTES

        /** budgets.md §4's floor for a configured `single_file_limit`. */
        const val MIN_FILE_LIMIT_BYTES: Long = 16L * MIB

        /** budgets.md §4's ceiling for a configured `single_file_limit`. */
        const val MAX_FILE_LIMIT_BYTES: Long = 256L * MIB

        /** bridge.md §4: one binary payload decodes to at most 512 KiB. */
        const val FETCH_CHUNK_BYTES: Long = 512L * 1024L

        /** bridge.md §12.8: the log tail is bounded at 256 KiB. */
        const val LOG_TAIL_MAX_BYTES: Int = 262_144

        /**
         * The limits for one job: the adapter's configured file limit clamped the
         * way budgets.md §4 clamps `single_file_limit`, and the tier's workspace
         * bucket.
         *
         * A configured value below the floor is clamped up rather than refused:
         * budgets.md §4 says "a value outside the range is clamped, never a start
         * failure", and a limit the caller asked to be smaller than one mutation
         * cannot be honoured anyway.
         */
        fun of(
            budgets: ControllerBudgets,
            configuredFileLimitBytes: Long = DEFAULT_FILE_LIMIT_BYTES,
            rssLimitBytes: Long? = null,
        ): UbuntuJobLimits {
            val tierMaximum = budgets.singleFileBytes.coerceAtLeast(MIN_FILE_LIMIT_BYTES)
            val fileLimit = if (configuredFileLimitBytes <= DEFAULT_FILE_LIMIT_BYTES) {
                // The default is deliberately one mutation: an ingest that is a
                // single complete write cannot leave half a file behind.
                DEFAULT_FILE_LIMIT_BYTES
            } else {
                // A raise is a `single_file_limit`-shaped value: the floor is
                // 16 MiB and the ceiling is this tier's file budget.
                configuredFileLimitBytes.coerceIn(MIN_FILE_LIMIT_BYTES, tierMaximum)
            }
            return UbuntuJobLimits(
                fileLimitBytes = fileLimit,
                workspaceLimitBytes = budgets.workspaceBytes,
                rssLimitBytes = rssLimitBytes,
            )
        }
    }
}

/** One manifest line, before and after ingest (bridge.md §12.7/§12.8). */
data class UbuntuArtifactRecord(
    val name: String,
    val bytes: Long,
    val sha256: String?,
    val state: UbuntuArtifactState,
    val path: String? = null,
    val refusal: UbuntuVfsRefusal? = null,
) {
    init {
        require(NAME.matches(name)) { "not a legal artifact name: $name" }
        require(bytes >= 0) { "artifact bytes must be non-negative" }
        require((state == UbuntuArtifactState.REFUSED) == (refusal != null)) {
            "a refused artifact names its refusal, and only a refused one does"
        }
    }

    companion object {
        /**
         * `^[A-Za-z0-9._-]{1,64}$`, not `.` or `..`.
         *
         * The name is a leaf, never a path: the target path is the host's to pick
         * (§12.8's default) so a manifest cannot steer a write outside the
         * workspace.
         */
        val NAME = Regex("^[A-Za-z0-9._-]{1,64}$")
    }
}

/** `artifacts[].state` (bridge.md §12.8). */
enum class UbuntuArtifactState(val wire: String) {
    /** Prechecked and fetchable; nothing has been written yet. */
    AVAILABLE("available"),

    /** Written to `path`. */
    INGESTED("ingested"),

    /** The precheck or a sink refused it; `refusal` says why. */
    REFUSED("refused"),

    /** A mutation chain stopped halfway; the file on disk is a prefix. */
    PARTIAL("partial"),

    /** The adapter no longer has the bytes. */
    MISSING("missing"),

    ;

    companion object {
        fun ofWire(raw: String): UbuntuArtifactState? = entries.firstOrNull { it.wire == raw }
    }
}

/** `channel.md` §4.8's `VFS_REFUSED`, reused verbatim (bridge.md §12.7). */
data class UbuntuVfsRefusal(
    val reason: String,
    val limit: Long,
    val bytes: Long,
    val code: String = CODE,
) {
    init {
        require(reason in REASONS) { "not a channel.md §4.8 refusal reason: $reason" }
    }

    companion object {
        const val CODE = "VFS_REFUSED"
        const val FILE_TOO_LARGE = "file-too-large"
        const val NO_SPACE = "no-space"
        const val QUOTA_EXCEEDED = "quota-exceeded"

        /** The three `reason` values channel.md §4.8 enumerates. */
        val REASONS: Set<String> = setOf(FILE_TOO_LARGE, NO_SPACE, QUOTA_EXCEEDED)
    }
}

/** `seal.state` (bridge.md §12.8). */
enum class UbuntuSealState(val wire: String) {
    PENDING("pending"),
    SEALED("sealed"),
    RESTORED("restored"),
    FAILED("failed"),

    ;

    companion object {
        fun ofWire(raw: String): UbuntuSealState? = entries.firstOrNull { it.wire == raw }
    }
}

/**
 * The `ubuntu.exec` request the lane accepts (bridge.md §12.2).
 *
 * @param env the environment id; the adapter registry key.
 * @param argv the command, never a shell line.
 * @param workspace the one workspace subtree the job may read.
 * @param cwd the guest working directory; must be inside [workspace].
 * @param label a short audit label, never a credential.
 * @param jobTimeoutMs the *job's* deadline, distinct from a bridge `timeoutMs`.
 */
data class UbuntuExecRequest(
    val env: String,
    val argv: List<String>,
    val workspace: String = "/dsh/workspace",
    val cwd: String = "/dsh/workspace",
    val label: String? = null,
    val jobTimeoutMs: Long = DEFAULT_JOB_TIMEOUT_MS,
) {
    init {
        require(ENV.matches(env)) { "not a legal env id: $env" }
        require(argv.isNotEmpty()) { "argv must name a command" }
        require(argv.size <= MAX_ARGV) { "argv has more than $MAX_ARGV arguments" }
        require(argv.all { it.length <= MAX_ARG_BYTES && '\u0000' !in it }) {
            "an argument is over $MAX_ARG_BYTES bytes or contains NUL"
        }
        require(argv.sumOf { it.toByteArray(Charsets.UTF_8).size } <= MAX_ARGV_BYTES) {
            "argv is over $MAX_ARGV_BYTES bytes (bridge.md §12.2)"
        }
        require(label == null || (label.length <= MAX_LABEL && label.none { it.isISOControl() })) {
            "label must be at most $MAX_LABEL characters and carry no control character"
        }
        require(jobTimeoutMs in MIN_JOB_TIMEOUT_MS..MAX_JOB_TIMEOUT_MS) {
            "jobTimeoutMs must be in $MIN_JOB_TIMEOUT_MS..$MAX_JOB_TIMEOUT_MS"
        }
    }

    companion object {
        val ENV = Regex("^[a-z0-9][a-z0-9.:-]{0,63}$")
        const val MAX_ARGV = 256
        const val MAX_ARG_BYTES = 8_192
        const val MAX_ARGV_BYTES = 65_536
        const val MAX_LABEL = 120
        const val MIN_JOB_TIMEOUT_MS = 1_000L
        const val MAX_JOB_TIMEOUT_MS = 3_600_000L
        const val DEFAULT_JOB_TIMEOUT_MS = 600_000L
    }
}

/**
 * One durable job record: the JobRef of bridge.md §12.2 plus §12.8's payload.
 *
 * @param seq the status cursor; +1 per state change and per artifact-state change.
 * @param egress `true` iff a byte left the device; `false` until `remote` is reached.
 * @param authorityExited which authority the job left; `null` until `remote`.
 * @param argvDigest sha256 of the canonical JSON `argv`, so the audit can name the
 *   command without storing it.
 * @param approval the session approval that admitted this job, `null` only for a
 *   record written before the gate existed (a reader must not invent one).
 */
data class UbuntuJobRecord(
    val jobId: String,
    val env: String,
    val state: UbuntuJobState,
    val seq: Int,
    val createdAtMs: Long,
    val updatedAtMs: Long,
    val egress: Boolean,
    val authorityExited: String?,
    val argvDigest: String,
    val argvLength: Int,
    val cwd: String,
    val workspace: String,
    val limits: UbuntuJobLimits,
    val label: String?,
    val exitCode: Int?,
    val logTail: String,
    val artifacts: List<UbuntuArtifactRecord>,
    val failure: UbuntuJobFailure?,
    val internalAccessObserved: Boolean?,
    val seal: UbuntuSealState,
    val sealReason: String?,
    val jobTimeoutMs: Long,
    val approval: UbuntuJobApproval? = null,
) {
    init {
        require(jobId.matches(JOB_ID)) { "not a D6 job id: $jobId" }
        require(seq >= 1) { "seq starts at 1" }
        require((state == UbuntuJobState.FAILED || state == UbuntuJobState.CANCELLED) == (failure != null)) {
            "failure is present exactly for failed and cancelled (bridge.md §12.8)"
        }
        require(!egress || authorityExited != null) { "egress without an authority is not a fact" }
        require(authorityExited == null || authorityExited in AUTHORITIES) {
            "authorityExited must be worker-vfs or device"
        }
        // A gate refusal is recorded with its decision and its cause; neither
        // may appear without the other, or the audit could not say what happened.
        val approvalCause = failure?.cause
        if (approvalCause == UbuntuCause.APPROVAL_DENIED || approvalCause == UbuntuCause.APPROVAL_UNAVAILABLE) {
            require(state == UbuntuJobState.FAILED) { "an approval refusal is a failed job, not ${state.wire}" }
            require(approval != null) { "an approval refusal records its decision" }
            require(approval!!.state != UbuntuApprovalState.GRANTED) {
                "a granted approval cannot carry an approval refusal cause"
            }
        }
    }

    /** `true` once the job can no longer change except by §12.3 row 15. */
    val terminal: Boolean get() = state.terminal

    /** `true` when a caller may fetch this job's artifacts (§12.8). */
    val fetchable: Boolean get() = state == UbuntuJobState.SUCCEEDED || state == UbuntuJobState.INGEST_REFUSED

    fun artifact(name: String): UbuntuArtifactRecord? = artifacts.firstOrNull { it.name == name }

    companion object {
        /** channel.md §6's D6 identifier rule, which a job id follows. */
        val JOB_ID = Regex("^[A-Za-z0-9._-]{1,64}$")

        /** The two values bridge.md §12.5 allows. */
        val AUTHORITIES: Set<String> = setOf(AUTHORITY_WORKER_VFS, AUTHORITY_DEVICE)

        /** Left the Worker's VFS enforcement point, stayed on the device. */
        const val AUTHORITY_WORKER_VFS = "worker-vfs"

        /** Left the device. */
        const val AUTHORITY_DEVICE = "device"
    }
}

/** Bridge.md §4's request cap, applied to one `ubuntu.exec` call. */
object UbuntuBridgeCaps {
    const val REQUEST_BYTES = 262_144
    const val RESPONSE_BYTES = 1_048_576
}
