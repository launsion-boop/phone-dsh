// phone-dsh — :app / com.phonedsh.probe: the real proot-backed Ubuntu adapter.
// SPDX-License-Identifier: MIT
//
// ---- what this adapter is --------------------------------------------------
// The `UbuntuAdapter` implementation the composition root injects into
// `HostUbuntuSession`. It owns exactly the four environment questions
// bridge.md §12.1 leaves to an adapter: start the command, report what happened,
// stop it, and read an artifact range. The lane still owns admission, the state
// machine, the seal, limits and the durable record.
//
// ---- what this first slice really does -------------------------------------
// `start` ensures the pinned rootfs (downloading on first use) and launches
// Termux proot with the plan `ProotRuntime` builds. `poll` observes the exit
// code and returns the tails. `stop` kills the process group. `readArtifact`
// reads a bounded range from the job's artifact directory; this slice
// deliberately returns an **empty manifest**, so `uname -a` answers with no
// artifacts and `ubuntu fetch` has nothing to fetch. That is the approved slice;
// an artifact convention is a later change, not something to invent here.
//
// `egress = false` and `authorityExited = "worker-vfs"` are bridge.md §12.5's
// local pair. The guest shares the device network, so a command that opens a
// socket *can* send bytes; the honest reading of that fact is a remaining risk
// in the receipt, not an `egress = true` that the contract reserves for a cloud
// adapter (and whose invariant requires `authorityExited = "device"`).
//
// ---- failure mapping -------------------------------------------------------
// Any failure before the process exists is `UbuntuStartAck.Refused`, never an
// exception: the lane then records `not_started` truthfully. A failure after
// the process started is `UbuntuAdapterStatus.Failed`; a vanished handle is
// `Gone`, which the lane reports as `adapter_gone` rather than inventing an
// exit code.

package com.phonedsh.probe

import com.phonedsh.dsh.localexec.UbuntuAdapter
import com.phonedsh.dsh.localexec.UbuntuAdapterStatus
import com.phonedsh.dsh.localexec.UbuntuArtifactChunk
import com.phonedsh.dsh.localexec.UbuntuArtifactRecord
import com.phonedsh.dsh.localexec.UbuntuJobLimits
import com.phonedsh.dsh.localexec.UbuntuJobRecord
import com.phonedsh.dsh.localexec.UbuntuStartAck
import com.phonedsh.platform.Clock
import com.phonedsh.platform.android.ProotRuntime
import com.phonedsh.platform.android.UbuntuProcess
import com.phonedsh.platform.android.UbuntuRootfsProvider
import com.phonedsh.platform.android.UbuntuRootfsResult
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/**
 * The real local environment (see the file header).
 *
 * @param rootfs the pinned Ubuntu Base store; `start` ensures it is installed.
 * @param runtime the process runtime over the four Termux binaries.
 * @param hostWorkspace the host directory bound at `/dsh/workspace`.
 * @param jobsRoot one directory per job (`stdout`, `stderr`, `artifacts/`).
 * @param clock wall time for the stop grace windows.
 */
class ProotUbuntuAdapter(
    override val env: String = DEFAULT_ENV,
    private val rootfs: UbuntuRootfsProvider,
    private val runtime: ProotRuntime,
    private val hostWorkspace: Path,
    private val jobsRoot: Path,
    private val clock: Clock,
    private val logger: (String) -> Unit = {},
    override val egress: Boolean = false,
    override val authorityExited: String = UbuntuJobRecord.AUTHORITY_WORKER_VFS,
    override val fileLimitBytes: Long = UbuntuJobLimits.DEFAULT_FILE_LIMIT_BYTES,
    override val rssLimitBytes: Long? = null,
    private val stopGraceMs: Long = STOP_GRACE_MS,
    private val killGraceMs: Long = KILL_GRACE_MS,
) : UbuntuAdapter {

    /** True when every proot binary is present and executable. */
    val available: Boolean get() = runtime.isAvailable()

    /** The token the probe reports when [available] is false. */
    val unavailableReason: String? get() = runtime.unavailableReason()

    private val processes = ConcurrentHashMap<String, RunningJob>()

    override suspend fun start(jobId: String, argv: List<String>, cwd: String): UbuntuStartAck {
        if (argv.isEmpty()) return UbuntuStartAck.Refused("empty_argv")
        if (!UbuntuJobRecord.JOB_ID.matches(jobId)) return UbuntuStartAck.Refused("invalid_job_id")
        if (!isGuestWorkspace(cwd)) return UbuntuStartAck.Refused("cwd_outside_workspace")
        if (!available) return UbuntuStartAck.Refused(runtime.unavailableReason() ?: "proot_unavailable")
        val installed = try {
            rootfs.ensureInstalled()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            logger("ubuntu proot: rootfs ensure failed (${failure.javaClass.simpleName})")
            return UbuntuStartAck.Refused("rootfs_unavailable")
        }
        val ready = when (installed) {
            is UbuntuRootfsResult.Failed -> {
                logger("ubuntu proot: rootfs refused (${installed.reason})")
                return UbuntuStartAck.Refused(installed.reason)
            }

            is UbuntuRootfsResult.Ready -> installed
        }
        val jobDir = jobsRoot.resolve(jobId)
        val stdout = jobDir.resolve("stdout")
        val stderr = jobDir.resolve("stderr")
        return try {
            Files.createDirectories(jobDir.resolve(ARTIFACTS))
            val process = runtime.launch(
                rootfs = ready.rootfs,
                hostWorkspace = hostWorkspace,
                cwd = cwd,
                argv = argv,
                stdout = stdout,
                stderr = stderr,
            )
            processes[jobId] = RunningJob(process, stdout, stderr)
            UbuntuStartAck.Accepted
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            // Before the process exists nothing ran: a refusal, not a job
            // failure, so the lane can write `not_started`.
            logger("ubuntu proot: launch failed (${failure.javaClass.simpleName})")
            UbuntuStartAck.Refused("proot_launch_failed")
        }
    }

    override suspend fun poll(jobId: String): UbuntuAdapterStatus {
        val job = processes[jobId] ?: return UbuntuAdapterStatus.Gone
        val exitCode = job.process.exitCodeOrNull() ?: return UbuntuAdapterStatus.Running(tail(job))
        processes.remove(jobId, job)
        return UbuntuAdapterStatus.Exited(
            exitCode = exitCode,
            logTail = tail(job),
            // The approved slice returns no artifacts; the artifact directory
            // and readArtifact path exist for the later convention, but this
            // adapter does not invent a manifest it cannot describe.
            artifacts = emptyList(),
        )
    }

    override suspend fun stop(jobId: String): Boolean {
        val job = processes[jobId] ?: return false
        job.process.terminate()
        val gracefulAt = clock.nowMillis() + stopGraceMs
        while (clock.nowMillis() < gracefulAt) {
            if (job.process.exitCodeOrNull() != null) return true
            delay(POLL_INTERVAL_MS)
        }
        // The lane's drain window is bounded; a second forceful attempt keeps
        // the answer honest ("will an exit be reported?") instead of claiming
        // success because a SIGTERM was sent.
        job.process.kill()
        val forcedAt = clock.nowMillis() + killGraceMs
        while (clock.nowMillis() < forcedAt) {
            if (job.process.exitCodeOrNull() != null) return true
            delay(POLL_INTERVAL_MS)
        }
        logger("ubuntu proot: $jobId did not report an exit after SIGKILL")
        return false
    }

    override suspend fun readArtifact(
        jobId: String,
        name: String,
        offset: Long,
        length: Int,
    ): UbuntuArtifactChunk? {
        if (!UbuntuJobRecord.JOB_ID.matches(jobId)) return null
        if (!UbuntuArtifactRecord.NAME.matches(name) || name == "." || name == "..") return null
        if (offset < 0 || length < 0 || length > UbuntuJobLimits.FETCH_CHUNK_BYTES) return null
        val dir = jobsRoot.resolve(jobId).resolve(ARTIFACTS).normalize()
        val file = dir.resolve(name).normalize()
        if (!file.startsWith(dir)) return null
        // A guest-created symlink is not an artifact: refuse to follow it out
        // of the job directory.
        if (!Files.isRegularFile(file, java.nio.file.LinkOption.NOFOLLOW_LINKS)) return null
        val size = try {
            Files.size(file)
        } catch (_: IOException) {
            return null
        }
        if (offset > size) return null
        val end = minOf(offset + length, size)
        if (end < offset) return null
        val count = (end - offset).toInt()
        val bytes = ByteArray(count)
        if (count > 0) {
            try {
                FileChannel.open(file, StandardOpenOption.READ).use { channel ->
                    var position = offset
                    var written = 0
                    while (written < count) {
                        val read = channel.read(java.nio.ByteBuffer.wrap(bytes, written, count - written), position)
                        if (read < 0) return null
                        written += read
                        position += read
                    }
                }
            } catch (_: IOException) {
                return null
            }
        }
        return UbuntuArtifactChunk(bytes, eof = end >= size)
    }

    /** The guest path the host workspace is mounted at (bridge.md §12.2). */
    internal fun isGuestWorkspace(cwd: String): Boolean {
        if (!cwd.startsWith(WORKSPACE)) return false
        if (cwd == WORKSPACE) return true
        if (!cwd.startsWith("$WORKSPACE/")) return false
        return cwd.removePrefix("$WORKSPACE/").split('/').all { it.isNotEmpty() && it != "." && it != ".." }
    }

    private fun tail(job: RunningJob): String =
        readTail(job.stdout) + readTail(job.stderr)

    private fun readTail(path: Path): String {
        if (!Files.isRegularFile(path)) return ""
        return try {
            val size = Files.size(path)
            val start = (size - TAIL_BYTES).coerceAtLeast(0L)
            val length = (size - start).toInt()
            val bytes = ByteArray(length)
            FileChannel.open(path, StandardOpenOption.READ).use { channel ->
                var position = start
                var written = 0
                while (written < length) {
                    val read = channel.read(java.nio.ByteBuffer.wrap(bytes, written, length - written), position)
                    if (read < 0) break
                    written += read
                    position += read
                }
            }
            String(bytes, Charsets.UTF_8)
        } catch (_: IOException) {
            ""
        }
    }

    private class RunningJob(
        val process: UbuntuProcess,
        val stdout: Path,
        val stderr: Path,
    )

    companion object {
        /** The registry key and the guest environment id. */
        const val DEFAULT_ENV: String = "ubuntu-24.04"

        /** The one guest workspace root. */
        const val WORKSPACE: String = "/dsh/workspace"

        /** The per-job artifact directory name. */
        const val ARTIFACTS: String = "artifacts"

        /** How much of each stream a poll returns; the lane bounds it again. */
        const val TAIL_BYTES: Long = 256L * 1024L

        /** How long a SIGTERM is given before the forced kill. */
        const val STOP_GRACE_MS: Long = 5_000L

        /** How long a SIGKILL is given before `stop` reports `false`. */
        const val KILL_GRACE_MS: Long = 2_000L

        private const val POLL_INTERVAL_MS: Long = 20L
    }
}
