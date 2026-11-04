// The echo adapter: the whole chain, from "begin" to "result + internalAccessObserved".
// SPDX-License-Identifier: MIT
//
// ---- why an echo job is the acceptance ------------------------------------
// Plan §6 phase 1 says to build the seal and the tripwire **before** any Ubuntu
// is involved, and to prove the chain with a fake job (`sh -c 'echo hi'`).
// Bringing proot in first would add "a process that can read things" before
// anything has shown that the reads are bounded and observed. The echo adapter
// is the smallest real chain:
//
//   seal -> (job process in its own process group) -> reap -> restore ->
//   read the audit -> report the state
//
// Every step is the production one except the command: the seal is the real
// `chmod 000`, the watch is the real `FileObserver`, the reap is the real
// `/proc` walk, and the restore is the real one. Only the guest is replaced, so
// a green run says "the safety machinery works", not "Ubuntu works".
//
// ---- the two things a run must report ------------------------------------
//   1. **the state** -- `IdleSealed` before the job (roots at 000 while the
//      environment is alive), `Closed` after the close;
//   2. **`internalAccessObserved`** -- whether the job's window saw an access,
//      which is the field `ubuntu.status` carries (plan §4.5 item 4).
//
// The evidence for (1) is not the state object alone: [EchoJobOutcome.modesAtIdle]
// is the mode read back from the filesystem at the idle-sealed moment, so a test
// can assert `0` rather than trust a flag.
//
// ---- the job runs in its own process group ---------------------------------
// [ShellJobLauncher] starts the job through `/system/bin/setsid`, so the pid the
// job writes into its pid file is its own process-group id. That is what lets
// the reaper kill the **group** rather than the pid -- the whole point of
// §5.1.1. Android's `ProcessBuilder` alone would leave the job in this app's
// group, where `kill(-pgid)` would kill the app.

package com.phonedsh.platform.android

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.TimeUnit

/** One running job process, as the adapter needs to see it. */
interface JobProcess {
    /** The pid; it must also be the process-group id (see [ShellJobLauncher]). */
    val pid: Int

    /** Everything the process wrote to stdout, after it exited. */
    fun stdout(): String

    /**
     * Waits for the exit.
     *
     * @return the exit code, or `null` when the timeout expired first.
     */
    fun await(timeoutMs: Long): Int?

    /** Best effort; the real close is the reaper's, not this. */
    fun destroy()
}

/** Starts one job process; the seam the JVM suite fakes. */
fun interface JobLauncher {
    /** @throws IOException when the process cannot be started. */
    fun launch(command: List<String>): JobProcess
}

/**
 * Starts a job in a new session/process group through the platform's `setsid`.
 *
 * The inner shell writes its own pid before `exec`ing the job, so the pid file
 * names the process that is also the group leader. `$$` is taken *inside* the
 * `setsid`ed shell, which is what makes that true even when `setsid` itself had
 * to fork (it forks only when the caller was already a group leader).
 *
 * The child inherits no descriptor above stdio: Android's `ProcessBuilder`
 * closes them before `exec` (measured, not assumed — L60 #3 device test). That
 * closes the inheritance half of the pre-opened-fd bypass; the other half, a job
 * reading `/proc/<app-pid>/fd/<n>` of this app, stays open and is declared as the
 * design's §2 residual instead of being papered over with a sweep that cannot
 * work from Kotlin (see [launch]).
 *
 * The job's argv is passed as positional parameters rather than spliced into a
 * command string, so a command containing quotes or spaces needs no escaping.
 *
 * @param workingDirectory where the pid file is created and the job runs.
 * @param setsid the `setsid` binary; `/system/bin/setsid` on Android.
 * @param sh the shell; `/system/bin/sh` on Android.
 */
class ShellJobLauncher(
    private val workingDirectory: Path,
    private val setsid: Path = Path.of("/system/bin/setsid"),
    private val sh: Path = Path.of("/system/bin/sh"),
) : JobLauncher {

    override fun launch(command: List<String>): JobProcess {
        require(command.isNotEmpty()) { "a job needs a command" }
        val pidFile = Files.createTempFile(workingDirectory, "l46-job-", ".pid")
        Files.write(pidFile, ByteArray(0))
        val argv = listOf(
            setsid.toString(),
            sh.toString(),
            "-c",
            PID_THEN_EXEC,
            "sh",
            pidFile.toString(),
        ) + command
        // No fd sweep happens here, and that is a measurement (L60 #3): the
        // platform's `ProcessBuilder` already closes every descriptor above stdio
        // in the child. Device-verified on API 35: an `Os.open` descriptor with
        // no `O_CLOEXEC` is absent from the job's `/proc/self/fd`, and only the
        // job's own stdio pipes are listed (see
        // `ShellJobLauncherFdIsolationDeviceTest`). The two Kotlin-side sweeps both
        // failed on the device: `mksh` only accepts single-digit descriptors in a
        // redirection (`exec 10>&-` is parsed as a command and exits 127), and
        // `ParcelFileDescriptor.adoptFd` aborts under fdsan for a descriptor
        // owned by another Java object. The zero-trace path that remains is not
        // inheritance at all: the job reads `/proc/<app-pid>/fd/<n>` of the app
        // itself, which no child-side sweep can close (design §2 residual).
        val process = ProcessBuilder(argv)
            .directory(workingDirectory.toFile())
            .redirectErrorStream(true)
            .start()
        return ShellJobProcess(pidFile, process)
    }

    /**
     * One launched job.
     *
     * stdout is drained on a daemon thread rather than read to EOF after the
     * exit, because the job's **background processes inherit the pipe**: a
     * `build &` holds the write end open long after the job's shell exits, and a
     * `readText()` would block until the background process dies. Reading as it
     * arrives means [stdout] can answer with what has been produced so far, even
     * when the pipe never reaches EOF.
     */
    private class ShellJobProcess(
        private val pidFile: Path,
        private val process: Process,
    ) : JobProcess {
        private val output = StringBuilder()
        private val outputLock = Any()

        private val drain: Thread = Thread {
            try {
                val reader = process.inputStream.bufferedReader()
                val buffer = CharArray(4 * 1024)
                while (true) {
                    val read = reader.read(buffer)
                    if (read <= 0) break
                    synchronized(outputLock) { output.append(buffer, 0, read) }
                }
            } catch (failure: IOException) {
                // The pipe closing under us is the normal way this thread ends.
            }
        }.apply {
            isDaemon = true
            name = "l46-job-stdout"
            start()
        }

        override val pid: Int by lazy { awaitPid(pidFile) }

        override fun stdout(): String = synchronized(outputLock) { output.toString() }

        override fun await(timeoutMs: Long): Int? = try {
            if (process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
                // The drain thread may still hold the last bytes; one short join
                // is cheaper than a sleep and is enough for a 4 KiB pipe.
                drain.join(DRAIN_JOIN_MS)
                process.exitValue()
            } else {
                null
            }
        } catch (failure: InterruptedException) {
            Thread.currentThread().interrupt()
            null
        }

        override fun destroy() {
            process.destroy()
        }
    }

    companion object {
        /**
         * Writes the shell's pid, then replaces the shell with the job.
         *
         * `$1` is the pid file; `shift` makes `$@` the job's argv.
         */
        const val PID_THEN_EXEC: String = "echo $$ > \"$1\"; shift; exec \"$@\""

        /** How long the launcher waits for the job to write its pid. */
        const val PID_WAIT_MS: Long = 5_000L

        /** How long the exit path waits for the stdout drain to catch up. */
        const val DRAIN_JOIN_MS: Long = 300L

        private fun awaitPid(pidFile: Path): Int {
            val deadline = System.currentTimeMillis() + PID_WAIT_MS
            while (System.currentTimeMillis() < deadline) {
                val text = try {
                    String(Files.readAllBytes(pidFile), Charsets.UTF_8).trim()
                } catch (failure: IOException) {
                    ""
                }
                val pid = text.toIntOrNull()
                if (pid != null && pid > 0) {
                    Files.deleteIfExists(pidFile)
                    return pid
                }
                Thread.sleep(10)
            }
            return -1
        }
    }
}

/**
 * What one echo run produced: the state, the audit and the close evidence.
 *
 * @property state the runtime state after the run; [BuildRuntimeState.Closed]
 *   on a clean run.
 * @property jobRan `false` when the seal failed and the job was refused
 *   (fail-closed) -- the command never executed.
 * @property refusal why the job was refused, when it was.
 * @property stdout what the job printed.
 * @property exitCode the job's exit status, or `null` when it timed out.
 * @property launchError why the job could not be started, when it could not.
 * @property internalAccessObserved the field `ubuntu.status` carries.
 * @property audit the full tripwire report (events, dropped, excused).
 * @property modesAtIdle the mode of every protected root read back while the
 *   environment was warm and no job was running; `0` is the whole point.
 * @property harvest the process-tree report from the close.
 * @property sealRestored whether the roots are back at their original modes.
 * @property protectedLabels the roots this run's seal actually protected.
 * @property exclusions the roots the seal deliberately left alone.
 */
data class EchoJobOutcome(
    val state: BuildRuntimeState,
    val jobRan: Boolean,
    val refusal: String?,
    val stdout: String,
    val exitCode: Int?,
    val launchError: String?,
    val internalAccessObserved: Boolean,
    val audit: TripwireReport,
    val modesAtIdle: Map<String, Int>,
    val harvest: HarvestReport?,
    val sealRestored: Boolean,
    val protectedLabels: List<String>,
    val exclusions: List<SealExclusion>,
) {
    /** A one-line status, in the shape `ubuntu.status` will carry. */
    fun statusLine(): String = buildString {
        append("state=").append(stateName(state))
        append(" jobRan=").append(jobRan)
        append(" internalAccessObserved=").append(internalAccessObserved)
        append(" exit=").append(exitCode?.toString() ?: "none")
        append(" sealRestored=").append(sealRestored)
        append(" protected=").append(protectedLabels)
        append(" residual=").append(harvest?.survivors ?: emptyList<Int>())
    }

    private companion object {
        fun stateName(state: BuildRuntimeState): String = when (state) {
            BuildRuntimeState.NotStarted -> "NotStarted"
            is BuildRuntimeState.IdleSealed -> "IdleSealed"
            is BuildRuntimeState.JobRunning -> "JobRunning"
            is BuildRuntimeState.Reaping -> "Reaping"
            BuildRuntimeState.Closed -> "Closed"
            is BuildRuntimeState.Broken -> "Broken(${state.failure})"
        }
    }
}

/**
 * The end-to-end chain: seal, run one job, reap, restore, report.
 *
 * @param runtime the state machine and seal owner.
 * @param launcher starts the job process.
 * @param modes the mode reader used for [EchoJobOutcome.modesAtIdle].
 * @param command the job; `sh -c 'echo hi'` in the acceptance run.
 * @param timeoutMs how long one job may run.
 */
class EchoJobAdapter(
    private val runtime: BuildRuntime,
    private val launcher: JobLauncher,
    private val command: List<String> = listOf("sh", "-c", "echo hi"),
    private val timeoutMs: Long = 30_000L,
    private val modes: ModeControl = PosixModeControl,
) {
    /**
     * Runs the chain once.
     *
     * The close is unconditional: it runs after a successful job, after a
     * failed launch and after a refused job, because a seal that is left
     * standing is the failure mode this whole lane exists to prevent.
     *
     * @param job the job id.
     */
    suspend fun run(job: String = "echo-1"): EchoJobOutcome {
        val started = runtime.start(job = "$job:warm")
        val startedFrom = when (started) {
            is Transition.Accepted -> started.to
            is Transition.Refused -> started.state
        }
        if (startedFrom !is BuildRuntimeState.IdleSealed) {
            val refusal = when (started) {
                is Transition.Refused -> started.reason
                is Transition.Accepted -> "the seal did not reach the idle-sealed state: $startedFrom"
            }
            // Fail-closed: no job process is started, and the close still runs so
            // a half-applied seal cannot survive the refusal.
            val close = runtime.close(CloseReason.AGENT)
            return refusedOutcome(refusal, startedFrom, close)
        }

        val seal = startedFrom.seal
        val modesAtIdle = readModes(seal)

        val begun = runtime.beginJob(job)
        if (begun !is Transition.Accepted) {
            val close = runtime.close(CloseReason.AGENT)
            val refusal = (begun as Transition.Refused).reason
            return refusedOutcome(refusal, begun.state, close).copy(modesAtIdle = modesAtIdle)
        }

        var stdout = ""
        var exitCode: Int? = null
        var launchError: String? = null
        var timedOut = false
        var close: CloseOutcome? = null
        try {
            val launched = launcher.launch(command)
            runtime.noteProcess(launched.pid)
            exitCode = launched.await(timeoutMs)
            timedOut = exitCode == null
            stdout = launched.stdout()
        } catch (failure: Throwable) {
            launchError = failure.message ?: failure.javaClass.simpleName
        } finally {
            // The chain always finishes: the job's audit window closes even when
            // the launch threw, and the close (reap then restore) runs even when
            // the caller was cancelled, because a standing seal is the one
            // outcome this lane must never produce. BuildRuntime.close is
            // NonCancellable for the same reason.
            if (runtime.snapshot() is BuildRuntimeState.JobRunning) {
                try {
                    runtime.endJob(job)
                } catch (ignored: Throwable) {
                    // A failed endJob must not skip the close below: the close
                    // disarms the audit itself when it is still armed.
                }
            }
            close = runtime.close(if (timedOut) CloseReason.SYSTEM_TIMEOUT else CloseReason.AGENT)
        }

        val audit = runtime.lastAudit()
        val closed = close ?: runtime.close(CloseReason.AGENT)
        return EchoJobOutcome(
            state = closed.state,
            jobRan = true,
            refusal = null,
            stdout = stdout,
            exitCode = exitCode,
            launchError = launchError,
            internalAccessObserved = audit.observed,
            audit = audit,
            modesAtIdle = modesAtIdle,
            harvest = closed.harvest,
            sealRestored = closed.sealRestored,
            protectedLabels = seal.protectedLabels,
            exclusions = seal.exclusions,
        )
    }

    private suspend fun refusedOutcome(
        refusal: String,
        state: BuildRuntimeState,
        close: CloseOutcome,
    ): EchoJobOutcome {
        val seal = (state as? BuildRuntimeState.IdleSealed)?.seal
        return EchoJobOutcome(
            state = close.state,
            jobRan = false,
            refusal = refusal,
            stdout = "",
            exitCode = null,
            launchError = null,
            internalAccessObserved = false,
            audit = runtime.lastAudit(),
            modesAtIdle = emptyMap(),
            harvest = close.harvest,
            sealRestored = close.sealRestored,
            protectedLabels = seal?.protectedLabels.orEmpty(),
            exclusions = seal?.exclusions.orEmpty(),
        )
    }

    private fun readModes(seal: SealHandle): Map<String, Int> {
        val modes = LinkedHashMap<String, Int>()
        for (entry in seal.entries) {
            if (entry.originalMode == null) continue
            modes[entry.label] = try {
                this.modes.read(entry.path)
            } catch (failure: IOException) {
                -1
            }
        }
        return modes
    }
}
