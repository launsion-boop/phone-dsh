// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the seal seam and the ingest math.
// SPDX-License-Identifier: MIT
//
// ---- the seal is a seam, not an implementation ------------------------------
// §3 layer 3 of the design is "chmod 000 the three internal roots for the job's
// window", and the real POSIX implementation lives in the Android port
// (`com.phonedsh.platform.android.BuildSeal`, with its marker, its idempotent
// restore and its boot repair). This module must not link that one — `:dsh`
// depends on the SPI, not on a platform adapter — and a mock does not need it:
// what the *job machine* owes the seal is an ordering, and an ordering is exactly
// what a seam can prove:
//
//   * no adapter is contacted unless `seal` returned [UbuntuSealResult.Sealed]
//     (fail-closed; §12.3 row 5);
//   * every path out of the window restores, including a failure path;
//   * `observed(jobId)` is read **after** the restore and before the terminal
//     record, so `internalAccessObserved` describes a closed window;
//   * a boot repairs whatever a kill left sealed (§12.3's boot paragraph).
//
// `UbuntuSeal.unwired` therefore answers *"failed"*, not *"sealed"*: a host that
// never wired the seal has no protection to claim, and a job must not start on a
// claim.
//
// ---- who implements it in production ---------------------------------------
// `BuildSealUbuntu` in `:platform-android` (over `BuildSeal` + `BuildSealTripwire`
// + the real `FileObserver`), constructed by the composition root (`:app`),
// which injects it through `HostExec.defaultTools` and runs its `repair()` on
// boot before the workspace opens. `:dsh` still links no platform adapter; the
// seam is what keeps that direction.
//
// ---- the ingest math --------------------------------------------------------
// [UbuntuArtifactIngest.precheck] is the single place bridge.md §12.7's two
// limits are applied. It runs in ascending `name` order and adds each accepted
// size to a running total, so the verdict for one manifest never depends on the
// order a caller fetches in — the same table always produces the same answer,
// which is what lets the verdict decide the job's terminal state before a byte
// moves.
//
// [UbuntuArtifactIngest.plan] is channel.md §6 transcribed: one complete `op = 1`
// write of at most 15 MiB, then appended suffixes whose `append_from` is the
// accepted logical length, each at most 15 MiB. It is the *page's* plan (the
// Worker is the only writer of VFS_MUT), and a raised `fileLimitBytes` is what
// makes the append arm reachable at all.

package com.phonedsh.dsh.localexec

/** What a seal, a restore or the boot repair answered. */
sealed interface UbuntuSealResult {
    /** The window is open (seal) or closed again (restore). */
    data object Sealed : UbuntuSealResult

    /** The seal could not be established or restored; [reason] is a short stable token. */
    data class Failed(val reason: String) : UbuntuSealResult
}

/**
 * The seal of the three internal roots for one job's window.
 *
 * The implementation is the Android port's; this interface exists so the job
 * machine can be tested without a filesystem and so `:dsh` never grows a second
 * chmod implementation.
 */
interface UbuntuSeal {
    /** Opens the window for [jobId]; nothing may reach an adapter before it returns [UbuntuSealResult.Sealed]. */
    suspend fun seal(jobId: String): UbuntuSealResult

    /** Closes the window for [jobId]; idempotent, and must be called on every path out. */
    suspend fun restore(jobId: String): UbuntuSealResult

    /** `true` when the tripwire saw an access to the internal roots during [jobId]'s window. */
    fun observed(jobId: String): Boolean

    /** Repairs a seal a killed process left behind; idempotent, run once per boot. */
    suspend fun repair(): Boolean

    /**
     * `true` when this seal protects nothing.
     *
     * The job record and `ubuntu.status` carry a `sealMock` flag, and it must be
     * read from the implementation rather than written as a literal by the host
     * tool: the composition root now injects the real `BuildSeal` adapter
     * (`BuildSealUbuntu` in `:platform-android`), and a hard-coded `true` would
     * report a protected window as a mock one — or, worse, the opposite.
     * [MockUbuntuSeal] answers `true`; a real seal and [unwired] answer `false`.
     */
    val isMock: Boolean get() = false

    companion object {
        /**
         * A seam no one wired: every seal fails.
         *
         * Deliberately not a permissive no-op. A job that starts on a seal which
         * never existed would report `internalAccessObserved: false` about a
         * window that was never closed, and that is the audit lying.
         */
        val unwired: UbuntuSeal = object : UbuntuSeal {
            override suspend fun seal(jobId: String): UbuntuSealResult =
                UbuntuSealResult.Failed("seal_unavailable")

            override suspend fun restore(jobId: String): UbuntuSealResult =
                UbuntuSealResult.Failed("seal_unavailable")

            override fun observed(jobId: String): Boolean = false

            override suspend fun repair(): Boolean = true
        }
    }
}

/** One VFS mutation the page would emit for an artifact (channel.md §3.1/§6). */
data class UbuntuMutation(val complete: Boolean, val appendFrom: Long, val length: Long) {
    init {
        require(length >= 0) { "a mutation carries no negative length" }
        require(length <= UbuntuJobLimits.MUTATION_MAX_BYTES) {
            "one mutation carries at most ${UbuntuJobLimits.MUTATION_MAX_BYTES} bytes"
        }
        require(complete == (appendFrom == 0L)) { "a complete write has append_from = 0" }
        require(complete || length > 0) { "an appended suffix carries at least one byte" }
    }
}

/** bridge.md §12.7's precheck, plan and tail bound, with no I/O. */
object UbuntuArtifactIngest {

    /**
     * Applies [limits] to [manifest] in ascending `name` order.
     *
     * An `ingested` entry is kept and its bytes count as already spent, so a
     * second pass after a restart cannot refuse a file it already wrote. Every
     * other entry comes back `available` or `refused` with the sentence that
     * says why.
     */
    fun precheck(
        manifest: List<UbuntuArtifactRecord>,
        limits: UbuntuJobLimits,
        workspaceUsedBytes: Long,
    ): List<UbuntuArtifactRecord> {
        require(workspaceUsedBytes >= 0) { "workspace usage cannot be negative" }
        var spent = workspaceUsedBytes + manifest.filter { it.state == UbuntuArtifactState.INGESTED }
            .sumOf { it.bytes }
        return manifest.sortedBy { it.name }.map { entry ->
            when {
                entry.state == UbuntuArtifactState.INGESTED -> entry
                entry.bytes > limits.fileLimitBytes -> entry.copy(
                    state = UbuntuArtifactState.REFUSED,
                    refusal = UbuntuVfsRefusal(
                        reason = UbuntuVfsRefusal.FILE_TOO_LARGE,
                        limit = limits.fileLimitBytes,
                        bytes = entry.bytes,
                    ),
                )

                spent + entry.bytes > limits.workspaceLimitBytes -> entry.copy(
                    state = UbuntuArtifactState.REFUSED,
                    refusal = UbuntuVfsRefusal(
                        reason = UbuntuVfsRefusal.QUOTA_EXCEEDED,
                        limit = limits.workspaceLimitBytes,
                        bytes = entry.bytes,
                    ),
                )

                else -> {
                    spent += entry.bytes
                    entry.copy(state = UbuntuArtifactState.AVAILABLE, refusal = null)
                }
            }
        }
    }

    /**
     * The mutation chain for one artifact of [bytes] bytes.
     *
     * Empty artifacts still need one complete write: `op = 1` with no data is how
     * a zero-length file is created (channel.md §3.1), and making it "no
     * mutations" would leave the file absent while the manifest says it landed.
     */
    fun plan(bytes: Long, mutationMax: Long = UbuntuJobLimits.MUTATION_MAX_BYTES): List<UbuntuMutation> {
        require(bytes >= 0) { "an artifact cannot have a negative size" }
        require(mutationMax in 1..UbuntuJobLimits.MUTATION_MAX_BYTES) {
            "mutationMax must be in 1..${UbuntuJobLimits.MUTATION_MAX_BYTES}"
        }
        val first = minOf(bytes, mutationMax)
        val mutations = mutableListOf(UbuntuMutation(complete = true, appendFrom = 0, length = first))
        var offset = first
        while (offset < bytes) {
            val length = minOf(bytes - offset, mutationMax)
            mutations += UbuntuMutation(complete = false, appendFrom = offset, length = length)
            offset += length
        }
        return mutations
    }

    /** How many `ubuntu.fetch` calls one artifact needs at bridge.md §4's 512 KiB. */
    fun chunkCount(bytes: Long): Int {
        require(bytes >= 0) { "an artifact cannot have a negative size" }
        if (bytes == 0L) return 1
        return ((bytes + UbuntuJobLimits.FETCH_CHUNK_BYTES - 1) / UbuntuJobLimits.FETCH_CHUNK_BYTES).toInt()
    }

    /**
     * The last [maxBytes] UTF-8 bytes of [text], on a code-point boundary.
     *
     * A tail is never a head (§12.8): a command's last lines explain its failure,
     * and a truncated head would replace them with a command line the reader
     * already has. The marker names how many bytes it dropped so a reader can
     * tell a short log from a truncated one.
     */
    fun tail(text: String, maxBytes: Int = UbuntuJobLimits.LOG_TAIL_MAX_BYTES): String {
        require(maxBytes > 0) { "a tail must keep at least one byte" }
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size <= maxBytes) return text
        var start = bytes.size - maxBytes
        // Move forward to a UTF-8 lead byte so the first code point is whole.
        while (start < bytes.size && (bytes[start].toInt() and 0xC0) == 0x80) start += 1
        return "[truncated $start bytes]\n" + String(bytes, start, bytes.size - start, Charsets.UTF_8)
    }

    /** channel.md §6's mutation path: `/dsh/workspace(/<component>)+`, no `.` or `..`. */
    fun isMutationPath(path: String): Boolean {
        if (!PATH_PREFIX.matches(path)) return false
        val components = path.split('/').drop(3)
        return components.isNotEmpty() && components.none { it.isEmpty() || it == "." || it == ".." }
    }

    private val PATH_PREFIX = Regex("^/dsh/workspace(/[^/]+)+$")
}
