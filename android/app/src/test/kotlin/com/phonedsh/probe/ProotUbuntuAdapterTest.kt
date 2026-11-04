// phone-dsh — :app JVM test: the real proot adapter over fakes.
// SPDX-License-Identifier: MIT
//
// What these tests pin, without a device: the exact proot argv and environment
// the adapter hands the launcher, the `Refused` answers that must never start a
// process (`cwd` outside /dsh/workspace, a rootfs failure, a missing binary),
// exit/tail reporting with the approved empty manifest, `stop`'s true/false
// answer, and `readArtifact`'s range and path-escape refusals. The launcher,
// process and rootfs provider are fakes; no Android class is called.

package com.phonedsh.probe

import com.phonedsh.dsh.localexec.UbuntuAdapterStatus
import com.phonedsh.dsh.localexec.UbuntuStartAck
import com.phonedsh.platform.Clock
import com.phonedsh.platform.android.ProotLaunchPlan
import com.phonedsh.platform.android.ProotLauncher
import com.phonedsh.platform.android.ProotRuntime
import com.phonedsh.platform.android.UbuntuProcess
import com.phonedsh.platform.android.UbuntuRootfsProvider
import com.phonedsh.platform.android.UbuntuRootfsResult
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProotUbuntuAdapterTest {
    private val clock = object : Clock {
        override fun nowMillis(): Long = System.nanoTime() / 1_000_000L
        override fun monotonicMillis(): Long = System.nanoTime() / 1_000_000L
    }

    private fun nativeLibraryDir(): Path {
        val dir = Files.createTempDirectory("pdsh-proot-native")
        for (name in listOf(
            ProotRuntime.PROOT,
            ProotRuntime.LOADER,
            ProotRuntime.TALLOC,
            ProotRuntime.SHMEM,
        )) {
            val file = dir.resolve(name)
            Files.write(file, byteArrayOf(0x7f, 'E'.code.toByte(), 'L'.code.toByte(), 'F'.code.toByte()))
        }
        Files.setPosixFilePermissions(
            dir.resolve(ProotRuntime.PROOT),
            PosixFilePermissions.fromString("rwxr-xr-x"),
        )
        return dir
    }

    private fun fixture(
        rootfs: UbuntuRootfsProvider = FakeRootfs(UbuntuRootfsResult.Ready(Files.createTempDirectory("pdsh-rootfs"), "24.04.5")),
        lib: Path = nativeLibraryDir(),
        launcher: RecordingLauncher = RecordingLauncher(),
        stopGraceMs: Long = 30L,
        killGraceMs: Long = 30L,
    ): Fixture {
        val jobs = Files.createTempDirectory("pdsh-ubuntu-jobs")
        val workspace = Files.createTempDirectory("pdsh-ubuntu-workspace")
        val runtime = ProotRuntime(lib, Files.createTempDirectory("pdsh-proot-tmp"), launcher)
        return Fixture(
            adapter = ProotUbuntuAdapter(
                rootfs = rootfs,
                runtime = runtime,
                hostWorkspace = workspace,
                jobsRoot = jobs,
                clock = clock,
                stopGraceMs = stopGraceMs,
                killGraceMs = killGraceMs,
            ),
            launcher = launcher,
            jobs = jobs,
            workspace = workspace,
            lib = lib,
        )
    }

    private data class Fixture(
        val adapter: ProotUbuntuAdapter,
        val launcher: RecordingLauncher,
        val jobs: Path,
        val workspace: Path,
        val lib: Path,
    )

    @Test
    fun start_hands_the_launcher_the_pinned_command_and_environment() = runBlocking {
        val f = fixture()
        val ack = f.adapter.start("uj-abc", listOf("uname", "-a"), "/dsh/workspace")
        assertEquals(UbuntuStartAck.Accepted, ack)
        val plan = assertNotNullPlan(f.launcher.plan)
        assertEquals(f.lib.resolve("libproot.so").toString(), plan.command[0])
        assertEquals("--kill-on-exit", plan.command[1])
        assertEquals("-0", plan.command[2])
        assertEquals("-r", plan.command[3])
        assertTrue(plan.command[4].contains("pdsh-rootfs"))
        assertEquals("-b", plan.command[5])
        assertEquals("${f.workspace}:/dsh/workspace", plan.command[6])
        assertEquals("-w", plan.command[7])
        assertEquals("/dsh/workspace", plan.command[8])
        assertEquals(listOf("uname", "-a"), plan.command.takeLast(2))
        assertEquals(
            f.lib.resolve("libproot_loader.so").toString(),
            plan.environment["PROOT_LOADER"],
        )
        assertEquals(f.lib.toString(), plan.environment["LD_LIBRARY_PATH"])
        assertTrue(plan.environment.getValue("PROOT_TMP_DIR").contains("pdsh-proot-tmp"))
        assertEquals("1", plan.environment["PROOT_NO_SECCOMP"])
        assertEquals(f.jobs.resolve("uj-abc/stdout"), f.launcher.stdout)
        assertEquals(f.jobs.resolve("uj-abc/stderr"), f.launcher.stderr)
    }

    @Test
    fun start_refuses_a_cwd_outside_the_one_workspace_root() = runBlocking {
        val f = fixture()
        for (cwd in listOf("/", "/etc", "/dsh/workspacex", "/dsh/workspace/../etc", "/dsh/workspace/..")) {
            val ack = f.adapter.start("uj-abc", listOf("uname"), cwd)
            assertEquals(
                cwd,
                UbuntuStartAck.Refused("cwd_outside_workspace"),
                ack,
            )
        }
        assertNull(f.launcher.plan)
    }

    @Test
    fun start_refuses_when_the_rootfs_is_not_ready() = runBlocking {
        val f = fixture(rootfs = FakeRootfs(UbuntuRootfsResult.Failed("sha256_mismatch")))
        assertEquals(
            UbuntuStartAck.Refused("sha256_mismatch"),
            f.adapter.start("uj-abc", listOf("uname"), "/dsh/workspace"),
        )
        assertNull(f.launcher.plan)
    }

    @Test
    fun start_refuses_when_a_proot_binary_is_missing() = runBlocking {
        val empty = Files.createTempDirectory("pdsh-proot-empty")
        val f = fixture(lib = empty)
        assertEquals(
            UbuntuStartAck.Refused("proot_missing"),
            f.adapter.start("uj-abc", listOf("uname"), "/dsh/workspace"),
        )
        assertNull(f.launcher.plan)
    }

    @Test
    fun poll_reports_running_then_the_exit_and_an_empty_manifest() = runBlocking {
        val f = fixture()
        f.adapter.start("uj-abc", listOf("uname", "-a"), "/dsh/workspace")
        Files.write(f.jobs.resolve("uj-abc/stdout"), "Linux localhost aarch64\n".toByteArray(StandardCharsets.UTF_8))
        Files.write(f.jobs.resolve("uj-abc/stderr"), "warn\n".toByteArray(StandardCharsets.UTF_8))
        val running = f.adapter.poll("uj-abc")
        assertTrue(running is UbuntuAdapterStatus.Running)
        assertTrue((running as UbuntuAdapterStatus.Running).logTail.contains("Linux localhost aarch64"))
        assertTrue(running.logTail.contains("warn"))

        f.launcher.process.exit = 0
        val exited = f.adapter.poll("uj-abc")
        assertTrue("expected Exited, was $exited", exited is UbuntuAdapterStatus.Exited)
        val done = exited as UbuntuAdapterStatus.Exited
        assertEquals(0, done.exitCode)
        assertTrue(done.logTail.contains("Linux localhost aarch64"))
        assertTrue(done.artifacts.isEmpty())
        assertEquals(UbuntuAdapterStatus.Gone, f.adapter.poll("uj-abc"))
    }

    @Test
    fun stop_is_true_only_when_an_exit_will_be_reported() = runBlocking {
        val cooperative = fixture()
        cooperative.adapter.start("uj-abc", listOf("uname"), "/dsh/workspace")
        cooperative.launcher.process.onTerminate = { cooperative.launcher.process.exit = 143 }
        assertTrue(cooperative.adapter.stop("uj-abc"))

        val stubborn = fixture()
        stubborn.adapter.start("uj-abc", listOf("uname"), "/dsh/workspace")
        assertFalse(stubborn.adapter.stop("uj-abc"))
        assertEquals(1, stubborn.launcher.process.terminateCalls)
        assertEquals(1, stubborn.launcher.process.killCalls)
        // The handle is intentionally kept: a poll after `unknown` still reports
        // the truth the moment the process does end.
        stubborn.launcher.process.exit = 137
        val late = stubborn.adapter.poll("uj-abc")
        assertTrue(late is UbuntuAdapterStatus.Exited)
        assertEquals(137, (late as UbuntuAdapterStatus.Exited).exitCode)
    }

    @Test
    fun read_artifact_reads_ranges_and_refuses_escapes() = runBlocking {
        val f = fixture()
        val artifacts = f.jobs.resolve("uj-abc/artifacts")
        Files.createDirectories(artifacts)
        Files.write(artifacts.resolve("ok.bin"), "0123456789".toByteArray(StandardCharsets.UTF_8))

        val middle = f.adapter.readArtifact("uj-abc", "ok.bin", 2, 3)
        assertNotNull(middle)
        assertEquals("234", String(middle!!.bytes, StandardCharsets.UTF_8))
        assertFalse(middle.eof)

        val tail = f.adapter.readArtifact("uj-abc", "ok.bin", 8, 16)
        assertNotNull(tail)
        assertEquals("89", String(tail!!.bytes, StandardCharsets.UTF_8))
        assertTrue(tail.eof)

        assertNull(f.adapter.readArtifact("uj-abc", "ok.bin", 99, 1))
        assertNull(f.adapter.readArtifact("uj-abc", "ok.bin", -1, 1))
        assertNull(f.adapter.readArtifact("uj-abc", "../stdout", 0, 1))
        assertNull(f.adapter.readArtifact("uj-abc", "missing.bin", 0, 1))

        // A symlink inside artifacts/ must not be followed to an outside file.
        val outside = Files.createTempFile("pdsh-proot-outside", ".txt")
        Files.write(outside, "secret".toByteArray(StandardCharsets.UTF_8))
        Files.createSymbolicLink(artifacts.resolve("link.bin"), outside)
        assertNull(f.adapter.readArtifact("uj-abc", "link.bin", 0, 10))
    }

    private fun assertNotNullPlan(plan: ProotLaunchPlan?): ProotLaunchPlan {
        assertNotNull(plan)
        return plan!!
    }

    // ------------------------------------------------------------- fakes

    private class FakeRootfs(private val result: UbuntuRootfsResult) : UbuntuRootfsProvider {
        override suspend fun ensureInstalled(): UbuntuRootfsResult = result
        override fun installedVersion(): String? = null
        override suspend fun delete() = Unit
    }

    private class RecordingLauncher : ProotLauncher {
        var plan: ProotLaunchPlan? = null
        var stdout: Path? = null
        var stderr: Path? = null
        val process = FakeProcess()

        override suspend fun launch(plan: ProotLaunchPlan, stdout: Path, stderr: Path): UbuntuProcess {
            this.plan = plan
            this.stdout = stdout
            this.stderr = stderr
            Files.createDirectories(stdout.parent)
            Files.createFile(stdout)
            Files.createFile(stderr)
            return process
        }
    }

    private class FakeProcess : UbuntuProcess {
        override val pid: Long = 4242L
        var exit: Int? = null
        var terminateCalls: Int = 0
        var killCalls: Int = 0
        var onTerminate: (() -> Unit)? = null
        var onKill: (() -> Unit)? = null

        override fun exitCodeOrNull(): Int? = exit
        override suspend fun awaitExit(): Int = exit ?: 0
        override fun terminate() {
            terminateCalls += 1
            onTerminate?.invoke()
        }

        override fun kill() {
            killCalls += 1
            onKill?.invoke()
        }
    }
}
