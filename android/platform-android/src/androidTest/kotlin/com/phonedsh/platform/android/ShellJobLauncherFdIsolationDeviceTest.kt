// phone-dsh — :platform-android / androidTest: what a job inherits from us (L60 #3).
// SPDX-License-Identifier: MIT
//
// The audit's device finding, reproduced through the production launch path:
//
//   * `exec 9<file; chmod 000 dir; cat <&9` reads the bytes with **no** open and
//     no chmod inside the window — no `IN_OPEN`, no `IN_ATTRIB`;
//   * a same-uid process reads another process's `/proc/<pid>/fd/N` directly,
//     across the directory permissions.
//
// The launcher itself adds no sweep, because the platform already does the job:
// Android's `ProcessBuilder` closes every descriptor above stdio in the child.
// This suite proves that on a device (an `Os.open` fd with no `O_CLOEXEC` is
// absent from the job's `/proc/self/fd`), so the "pre-opened fd" read has no
// inheritance path here. It also measures the half that remains, which no
// launcher can close. Concretely:
//
//   1. the job's own `/proc/self/fd` does not name the app's pre-opened file;
//   2. the launch path still works (pid file, pipes, exit code);
//   3. the residual: the job can still `cat /proc/<app-pid>/fd/N`. That read
//      happens in the *app's* fd table, needs no inheritance and produces no
//      inotify event — §2 of the design doc declares it, and the test prints
//      what the platform answered instead of asserting a claim either way.

package com.phonedsh.platform.android

import android.content.Context
import android.os.Process
import android.system.Os
import android.system.OsConstants
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.io.FileDescriptor
import java.nio.file.Files
import java.nio.file.Path
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ShellJobLauncherFdIsolationDeviceTest {
    private lateinit var directory: Path
    private var inheritedDescriptor: FileDescriptor? = null
    private var inheritedFdNumber: Int = -1

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        directory = Files.createTempDirectory(context.cacheDir.toPath(), "l60-fd-")
    }

    @After
    fun tearDown() {
        inheritedDescriptor?.let { descriptor -> runCatching { Os.close(descriptor) } }
        inheritedDescriptor = null
        if (this::directory.isInitialized) {
            directory.toFile().deleteRecursively()
        }
    }

    @Test
    fun aDescriptorOpenedWithoutCloseOnExecIsNotInheritedByTheJob() {
        val marker = directory.resolve("session.jsonl")
        val markerPath = marker.toAbsolutePath().toString()
        Files.write(marker, "SECRET-SESSION-BYTES".toByteArray())
        // The adversarial shape: a raw fd with no O_CLOEXEC, as a native layer or
        // a ParcelFileDescriptor dup hands the app. ProcessBuilder must not leak
        // it into the guest job.
        val descriptor = Os.open(markerPath, OsConstants.O_RDONLY, 0)
        inheritedDescriptor = descriptor
        inheritedFdNumber = fdNumberFor(markerPath)
        assertTrue(
            "the fixture needs a real fd above stdio (found $inheritedFdNumber)",
            inheritedFdNumber > 2,
        )

        val launcher = ShellJobLauncher(directory)
        val script = """
            for f in /proc/self/fd/*; do
              printf 'SELF %s %s\n' "${'$'}f" "${'$'}(readlink "${'$'}f")"
            done
            printf 'APPFD '
            cat "/proc/${'$'}1/fd/${'$'}2" 2>/dev/null || printf '<unreadable>'
            printf '\n'
        """.trimIndent()
        val job = launcher.launch(
            listOf(
                "/system/bin/sh",
                "-c",
                script,
                "sh",
                Process.myPid().toString(),
                inheritedFdNumber.toString(),
            ),
        )

        assertNotNull("the job must exit within the bound", job.await(10_000L))
        val output = job.stdout()
        val wanted = canonical(markerPath)
        val inheritedNames = output.lineSequence()
            .filter { it.startsWith("SELF ") }
            .mapNotNull { line -> line.split(' ').getOrNull(2) }
            .filter { target -> canonical(target) == wanted }
            .toList()
        assertFalse(
            "the job inherited the app's pre-opened descriptor $inheritedFdNumber: " +
                "$inheritedNames\n$output",
            inheritedNames.isNotEmpty(),
        )
        val appFdProbe = output.lineSequence().firstOrNull { it.startsWith("APPFD ") }.orEmpty()
        // Diagnostic, not an assertion: whether the same-uid job can read the
        // *app's* fd table is the residual §2 declares, and it is a property of
        // the platform image, not of the sweep.
        println("L60 #3 residual /proc/<app-pid>/fd read: $appFdProbe")
    }

    @Test
    fun theLauncherKeepsTheJobPipesPidFileAndExitCode() {
        val launcher = ShellJobLauncher(directory)
        val job = launcher.launch(listOf("/system/bin/sh", "-c", "echo hi; exit 3"))
        assertEquals("the exit code must survive the wrapper", 3, job.await(10_000L))
        assertTrue("stdout must survive the wrapper: '${job.stdout()}'", job.stdout().contains("hi"))
    }

    /** The fd number of the open descriptor whose target is [path], or -1. */
    private fun fdNumberFor(path: String): Int {
        val wanted = canonical(path)
        return File("/proc/self/fd")
            .listFiles()
            .orEmpty()
            .firstNotNullOfOrNull { entry ->
                val target = runCatching { Os.readlink(entry.path) }.getOrNull()
                if (target != null && canonical(target) == wanted) entry.name.toIntOrNull() else null
            } ?: -1
    }

    /**
     * `/data/user/0/...` is a symlink to `/data/data/...`, and `/proc/self/fd`
     * reports the resolved path — compare canonical names, not the strings.
     */
    private fun canonical(path: String): String =
        runCatching { File(path).canonicalPath }.getOrDefault(path)
}
