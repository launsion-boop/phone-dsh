// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the external-environment adapter SPI.
// SPDX-License-Identifier: MIT
//
// ---- what an adapter is, and is not ----------------------------------------
// An adapter is the host's handle on one *environment* (`ubuntu-24.04`,
// `gh-actions:ubuntu-latest`, …). It is not an authority: it owns no VFS byte,
// it cannot open admission and it cannot write the workspace. It answers three
// questions — start this command, what happened, give me artifact bytes — and it
// declares the two audit facts bridge.md §12.5 refuses to let the host guess:
// `egress` and `authorityExited`.
//
// A local same-UID guest declares `egress = false, authorityExited =
// "worker-vfs"`: the bytes never left the device, but they did leave the Worker's
// VFS enforcement point (channel.md §6), which is the only place `EACCES` on the
// three internal roots is actually produced. An adapter that reaches a cloud
// declares `egress = true, authorityExited = "device"`. The two are separate
// members on purpose; a boolean cannot say both, and writing one for the other
// would make the audit state something untrue.
//
// ---- why `stop` returns a boolean ------------------------------------------
// The 20 s `Draining` deadline (budgets.md §1) turns on whether the environment
// acknowledged. `true` means "it will report an exit"; from there the job can be
// `cancelled` with an observed exit code. `false` means the host cannot observe
// the command's fate, and the honest answer is `outcome: "unknown"` — never
// `cancelled`, which would claim the host knows it stopped.

package com.phonedsh.dsh.localexec

/** One manifest line as an adapter reports it. */
data class UbuntuArtifactLine(val name: String, val bytes: Long, val sha256: String? = null)

/** What an adapter answers to `start`. */
sealed interface UbuntuStartAck {
    /** The snapshot was accepted and `argv` is running. */
    data object Accepted : UbuntuStartAck

    /** Nothing ran; the host may report `outcome: "not_started"` truthfully. */
    data class Refused(val reason: String) : UbuntuStartAck
}

/** What an adapter answers to `poll`. */
sealed interface UbuntuAdapterStatus {
    /** Still running; [logTail] is whatever the environment can show, bounded by the host. */
    data class Running(val logTail: String) : UbuntuAdapterStatus

    /** The command ended; [exitCode] is the environment's own value, including 124 for a deadline kill. */
    data class Exited(
        val exitCode: Int,
        val logTail: String,
        val artifacts: List<UbuntuArtifactLine>,
    ) : UbuntuAdapterStatus

    /** The environment no longer has this job (retention expired, environment reclaimed). */
    data object Gone : UbuntuAdapterStatus

    /** The environment failed while the job was in flight. */
    data class Failed(val reason: String) : UbuntuAdapterStatus
}

/** One artifact chunk; [bytes] is at most [UbuntuJobLimits.FETCH_CHUNK_BYTES]. */
class UbuntuArtifactChunk(val bytes: ByteArray, val eof: Boolean)

/** One external environment (bridge.md §12.1). */
interface UbuntuAdapter {
    /** The registry key; bridge.md §12.1's `env` pattern. */
    val env: String

    /** `true` iff a byte of the job leaves this device (bridge.md §12.5). */
    val egress: Boolean

    /** `"worker-vfs"` or `"device"` (bridge.md §12.5). */
    val authorityExited: String

    /** The adapter's configured ingest bound; the lane clamps it (bridge.md §12.7). */
    val fileLimitBytes: Long
        get() = UbuntuJobLimits.DEFAULT_FILE_LIMIT_BYTES

    /** The environment's declared RSS budget, or `null` for the app-process row. */
    val rssLimitBytes: Long?
        get() = null

    /** Hands the command to the environment. */
    suspend fun start(jobId: String, argv: List<String>, cwd: String): UbuntuStartAck

    /** Reads the job's current state; idempotent and safe to call after a restart. */
    suspend fun poll(jobId: String): UbuntuAdapterStatus

    /** Asks the environment to stop the job; `true` when it will report an exit. */
    suspend fun stop(jobId: String): Boolean

    /** Reads `[offset, offset + length)` of one artifact, or `null` when it is gone. */
    suspend fun readArtifact(jobId: String, name: String, offset: Long, length: Int): UbuntuArtifactChunk?
}
