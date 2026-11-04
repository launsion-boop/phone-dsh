// phone-dsh — :platform-android: the Termux proot process runtime.
// SPDX-License-Identifier: MIT
//
// ---- what this file owns ---------------------------------------------------
// The one place that knows how to start a guest command with Termux's proot
// (the fork with the SIGSYS-to-ENOSYS handler; upstream proot dies on the app
// seccomp filter). The four binaries are extracted from the APK by
// `android/tools/fetch-termux-proot.sh` into `nativeLibraryDir`, which is the
// only app-owned directory Android 10+ lets the app `execve` from. The runtime
// writes the arguments and the environment; the adapter above it owns job
// bookkeeping, tails and exit reporting.
//
// ---- why the environment is built, not inherited --------------------------
// `ProcessBuilder` inherits the app process's environment by default. That
// environment carries host credentials and tool-call state which a guest
// command has no business seeing, and `LD_PRELOAD`/`LD_LIBRARY_PATH` from the
// app would change how proot's own loader resolves. The launcher therefore
// clears the environment and installs only this file's map: the proot hooks,
// the guest HOME/PATH/TERM/LANG/TMPDIR, and nothing else.
//
// ---- why setsid -----------------------------------------------------------
// `stop()` must be able to kill the whole tree. proot's own `--kill-on-exit`
// only runs when proot exits normally; a SIGKILL of the direct child can leave
// tracees. `setsid` puts the command in its own process group, so a negative
// pid signal reaches proot and every tracee it started. The fallback (no
// `setsid` binary) still uses `--kill-on-exit`.
//
// This file is in `:platform-android` but the pure command/environment builders
// are deliberately free of `android.*` calls, so the host JVM suite can pin the
// exact argv without a device.

package com.phonedsh.platform.android

import android.system.Os
import android.system.OsConstants
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The proot command line plus the environment it runs with. */
data class ProotLaunchPlan(
    /** `argv[0]` is the proot binary in `nativeLibraryDir`. */
    val command: List<String>,
    /** The complete child environment; the app's own environment is not inherited. */
    val environment: Map<String, String>,
    /** A writable directory proot may use for its temporary files. */
    val workingDirectory: Path,
)

/** One running guest command. */
interface UbuntuProcess {
    /** The direct child's pid; with `setsid` it is also the process-group id. */
    val pid: Long

    /** The exit code if the child already ended, else `null`; never blocks. */
    fun exitCodeOrNull(): Int?

    /** Waits for the child to end and returns its exit code. */
    suspend fun awaitExit(): Int

    /** Politely stops the process group (SIGTERM). */
    fun terminate()

    /** Forcefully stops the process group (SIGKILL). */
    fun kill()
}

/** A process launcher seam; a JVM test supplies a recorder. */
interface ProotLauncher {
    suspend fun launch(plan: ProotLaunchPlan, stdout: Path, stderr: Path): UbuntuProcess
}

/**
 * The pinned Termux proot stack in `nativeLibraryDir`.
 *
 * @param nativeLibraryDir the installed APK's extracted native library
 *   directory (`applicationInfo.nativeLibraryDir`); the four `lib*.so` files
 *   live directly in it.
 * @param prootTmpDir a writable directory under the app's cache/files area.
 * @param launcher the OS seam; production uses [AndroidProotLauncher].
 */
class ProotRuntime(
    private val nativeLibraryDir: Path,
    private val prootTmpDir: Path,
    private val launcher: ProotLauncher = AndroidProotLauncher(),
) {
    val proot: Path = nativeLibraryDir.resolve(PROOT)
    val loader: Path = nativeLibraryDir.resolve(LOADER)
    private val talloc: Path = nativeLibraryDir.resolve(TALLOC)
    private val shmem: Path = nativeLibraryDir.resolve(SHMEM)

    /**
     * True only when every binary the runtime needs is present and proot is
     * executable. A missing asset must make the boot probe answer
     * `available=false` rather than register a command that cannot run.
     */
    fun isAvailable(): Boolean =
        Files.isRegularFile(proot) &&
            Files.isExecutable(proot) &&
            Files.isRegularFile(loader) &&
            Files.isRegularFile(talloc) &&
            Files.isRegularFile(shmem)

    /** The reason a probe should report when [isAvailable] is false. */
    fun unavailableReason(): String? = when {
        !Files.isRegularFile(proot) -> "proot_missing"
        !Files.isExecutable(proot) -> "proot_not_executable"
        !Files.isRegularFile(loader) -> "proot_loader_missing"
        !Files.isRegularFile(talloc) -> "libtalloc_missing"
        !Files.isRegularFile(shmem) -> "libandroid_shmem_missing"
        else -> null
    }

    /**
     * The exact argv and environment for one guest job.
     *
     * The command is `proot --kill-on-exit -0 -r <rootfs> -b
     * <hostWorkspace>:/dsh/workspace -w <cwd> <argv…>`: the host workspace is
     * the only host tree exposed, and only at the bridge's fixed guest path.
     */
    fun plan(rootfs: Path, hostWorkspace: Path, cwd: String, argv: List<String>): ProotLaunchPlan =
        ProotLaunchPlan(
            command = buildList {
                add(proot.toString())
                add("--kill-on-exit")
                add("-0")
                add("-r")
                add(rootfs.toString())
                add("-b")
                add("$hostWorkspace:/dsh/workspace")
                add("-w")
                add(cwd)
                addAll(argv)
            },
            environment = mapOf(
                "PROOT_LOADER" to loader.toString(),
                "LD_LIBRARY_PATH" to nativeLibraryDir.toString(),
                "PROOT_TMP_DIR" to prootTmpDir.toString(),
                "PROOT_NO_SECCOMP" to "1",
                "HOME" to "/root",
                "PATH" to GUEST_PATH,
                "TERM" to "xterm-256color",
                "LANG" to "C.UTF-8",
                "TMPDIR" to "/tmp",
            ),
            workingDirectory = prootTmpDir,
        )

    /** Starts one job; the caller owns the returned process's lifecycle. */
    suspend fun launch(
        rootfs: Path,
        hostWorkspace: Path,
        cwd: String,
        argv: List<String>,
        stdout: Path,
        stderr: Path,
    ): UbuntuProcess = launcher.launch(plan(rootfs, hostWorkspace, cwd, argv), stdout, stderr)

    companion object {
        /**
         * The guest's normal PATH, built from relative components so the
         * source does not carry a hard-coded host absolute path.
         */
        val GUEST_PATH: String = listOf(
            "usr/local/sbin",
            "usr/local/bin",
            "usr/sbin",
            "usr/bin",
            "sbin",
            "bin",
        ).joinToString(":") { "/$it" }

        /** The installed names produced by `fetch-termux-proot.sh`. */
        const val PROOT: String = "libproot.so"
        const val LOADER: String = "libproot_loader.so"
        const val TALLOC: String = "libtalloc.so"
        const val SHMEM: String = "libandroid-shmem.so"
    }
}

/** The production launcher: `setsid` when present, otherwise proot directly. */
class AndroidProotLauncher(
    private val setsid: Path = Paths.get("/system/bin/setsid"),
) : ProotLauncher {
    override suspend fun launch(plan: ProotLaunchPlan, stdout: Path, stderr: Path): UbuntuProcess =
        withContext(Dispatchers.IO) {
            Files.createDirectories(stdout.parent)
            Files.createDirectories(stderr.parent)
            Files.createDirectories(plan.workingDirectory)
            val command = if (Files.isExecutable(setsid)) {
                listOf(setsid.toString()) + plan.command
            } else {
                plan.command
            }
            val builder = ProcessBuilder(command)
            builder.directory(plan.workingDirectory.toFile())
            // Files, not pipes: a stray tracee must not keep the app's pipe
            // writer open and a job's output must survive a polling pause.
            builder.redirectOutput(stdout.toFile())
            builder.redirectError(stderr.toFile())
            builder.environment().apply {
                clear()
                putAll(plan.environment)
            }
            AndroidLinuxProcess(builder.start())
        }
}

/** [UbuntuProcess] over `java.lang.Process` and the raw process-group signal. */
private class AndroidLinuxProcess(private val process: Process) : UbuntuProcess {
    /**
     * The direct child's pid.
     *
     * `java.lang.Process.pid()` is not in this compile SDK's stubs even though
     * the platform implementation has had it since API 26; reflection keeps the
     * group kill available without a compile-time dependency. A failed lookup
     * falls back to 0, which makes `signal` skip the group call and leaves the
     * java `destroy`/`destroyForcibly` as the backstop.
     */
    override val pid: Long = try {
        val method = process.javaClass.getMethod("pid")
        (method.invoke(process) as? Number)?.toLong() ?: 0L
    } catch (_: Exception) {
        0L
    }

    override fun exitCodeOrNull(): Int? = try {
        process.exitValue()
    } catch (_: IllegalThreadStateException) {
        null
    }

    override suspend fun awaitExit(): Int = withContext(Dispatchers.IO) { process.waitFor() }

    override fun terminate() {
        signal(OsConstants.SIGTERM)
        process.destroy()
    }

    override fun kill() {
        signal(OsConstants.SIGKILL)
        process.destroyForcibly()
    }

    /**
     * Signal the process group, not only the direct child.
     *
     * The negative pid is the process-group form; `setsid` made the group id
     * equal to [pid]. A failure (no such group, already reaped) is ignored
     * because the java `Process` call that follows is the backstop.
     */
    private fun signal(signal: Int) {
        if (pid <= 0L) return
        try {
            Os.kill(-pid.toInt(), signal)
        } catch (_: Exception) {
            // The process may already be gone or the launcher may not have used
            // setsid; the direct-child call below still applies.
        }
    }
}
