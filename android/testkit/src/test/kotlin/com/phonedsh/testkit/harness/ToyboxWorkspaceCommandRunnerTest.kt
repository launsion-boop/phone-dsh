// :testkit harness tests — the workspace_command executor's honesty boundary.
// SPDX-License-Identifier: MIT
//
// These tests pin the two halves of `ToyboxWorkspaceCommandRunner`: what it
// really runs (a spawned `sh` against a throwaway copy of the materialized
// tree, whose exit code is returned unchanged) and what it refuses to guess
// (`git`, `python3`, bash-only syntax, path commands, `find -exec`, a missing
// shell). A deferral is always `PENDING_HOST`; a refusal must never look like a
// pass.

package com.phonedsh.testkit.harness

import com.phonedsh.testkit.scenario.CommandStatus
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ToyboxWorkspaceCommandRunnerTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private fun trees(): WorkspaceTrees {
        val root = temporary.newFolder().toPath()
        val workspace = root.resolve("workspace")
        val home = root.resolve("home")
        Files.createDirectories(workspace.resolve("notes"))
        Files.createDirectories(home)
        Files.write(workspace.resolve("notes/a.md"), "hello 世界\n".toByteArray(Charsets.UTF_8))
        Files.write(workspace.resolve("data.txt"), "one\ntwo\n".toByteArray(Charsets.UTF_8))
        return WorkspaceTrees(workspace, home)
    }

    private fun runner(shell: String = "/bin/sh") = ToyboxWorkspaceCommandRunner(shell = shell)

    private fun assertDeferred(command: String) {
        val outcome = runner().run(command, trees())
        assertEquals(
            "a command that cannot run must be deferred, not failed or passed: $command",
            CommandStatus.PENDING_HOST,
            outcome.status,
        )
        assertFalse(outcome.detail!!, outcome.detail!!.contains("exit 0"))
        assertTrue(outcome.detail, outcome.detail!!.startsWith("pending_host:"))
    }

    @Test
    fun hostOnlyToolsAreDeferredWithTheToolNamed() {
        val cases = mapOf(
            "git log --oneline" to "git",
            "python3 -c \"print(1)\"" to "python3",
            "cd /dsh/workspace && bash backup.sh" to "bash",
            "/usr/bin/git log" to "git",
            "ls | xargs rm" to "xargs",
        )
        for ((command, tool) in cases) {
            val outcome = runner().run(command, trees())
            assertEquals(command, CommandStatus.PENDING_HOST, outcome.status)
            assertTrue(
                "the deferral must name `$tool`: ${outcome.detail}",
                outcome.detail!!.contains("`$tool`"),
            )
        }
    }

    @Test
    fun bashOnlySyntaxAndIndirectionAreDeferred() {
        val commands = listOf(
            "echo \${HOME}",
            "[[ -f data.txt ]]",
            "cat <<EOF\nhi\nEOF",
            "./run.sh",
            "find . -name '*.md' -exec rm {} ;",
            "echo $'x'",
        )
        for (command in commands) {
            assertDeferred(command)
        }
    }

    @Test
    fun amissingShellIsDeferredNotPassed() {
        val outcome = runner(shell = "/definitely/not/a/shell").run("test -f data.txt", trees())
        assertEquals(CommandStatus.PENDING_HOST, outcome.status)
        assertTrue(outcome.detail!!, outcome.detail!!.contains("no POSIX shell"))
    }

    @Test
    fun aRealCommandRunsInAThrowawayCopyAndPasses() {
        val materialized = trees()
        val outcome = runner().run(
            "cd /dsh/workspace && echo changed > data.txt && test -f notes/a.md && grep -q 世界 notes/a.md",
            materialized,
        )
        assertEquals(outcome.detail, CommandStatus.EVALUATED, outcome.status)
        assertEquals(0, outcome.exitCode)
        assertTrue(outcome.detail!!, outcome.detail!!.startsWith("exit 0"))
        assertTrue("the executor must be named: ${outcome.detail}", outcome.detail!!.contains("host-sh"))
        // The throwaway copy was written; the materialized tree was not.
        assertEquals(
            "one\ntwo\n",
            Files.readAllBytes(materialized.workspace.resolve("data.txt")).toString(Charsets.UTF_8),
        )
    }

    @Test
    fun aNonZeroExitCodeIsReturnedUnchanged() {
        val outcome = runner().run("test -e missing.txt", trees())
        assertEquals(CommandStatus.EVALUATED, outcome.status)
        assertEquals(1, outcome.exitCode)
        assertTrue(outcome.detail!!, outcome.detail!!.startsWith("exit 1"))
    }

    @Test
    fun theVfsPathIsRewrittenToTheCopy() {
        val outcome = runner().run("cd /dsh/workspace && pwd", trees())
        assertEquals(CommandStatus.EVALUATED, outcome.status)
        assertEquals(0, outcome.exitCode)
        assertEquals("pwd ran in the staged copy", "workspace", outcome.stdout.substringAfterLast('/'))
        assertNotEquals("/dsh/workspace", outcome.stdout.trim())
    }

    @Test
    fun aTimeoutIsAFailureNotADeferral() {
        val outcome = ToyboxWorkspaceCommandRunner(timeoutMillis = 100L).run("sleep 5", trees())
        assertEquals(CommandStatus.EVALUATED, outcome.status)
        assertTrue(outcome.timedOut)
        assertEquals(-1, outcome.exitCode)
        assertTrue(outcome.detail!!, outcome.detail!!.startsWith("timed out after 100 ms"))
    }

    @Test
    fun missingFilesProduceTheRealShellDiagnostic() {
        val outcome = runner().run("cd /dsh/workspace && grep -q x missing.txt", trees())
        assertEquals(CommandStatus.EVALUATED, outcome.status)
        assertEquals(2, outcome.exitCode)
        assertTrue(
            "the shell's own message is the evidence: ${outcome.detail}",
            outcome.detail!!.contains("missing.txt"),
        )
    }
}
