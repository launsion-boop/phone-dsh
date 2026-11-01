// phone-dsh — :dsh unit test: the :shell exec adapter's request/result contract.
// SPDX-License-Identifier: MIT
//
// These tests drive the real Rust accelerators through JNI (the same seam the
// HELLO tests use), so they prove the adapter's budget, timeout and refusal
// decisions against the code that will run on the device, not against a fake.

package com.phonedsh.dsh.host

import com.phonedsh.dsh.exec.ExecFixtures
import com.phonedsh.dsh.exec.ExecToolResult
import com.phonedsh.dsh.exec.ExecToolResultException
import com.phonedsh.dsh.exec.TestClock
import com.phonedsh.dsh.tools.ToolInvocation
import com.phonedsh.dsh.tools.ToolOutcome
import com.phonedsh.shell.AcceleratorMount
import com.phonedsh.shell.JaqAccelerator
import com.phonedsh.shell.NativeShell
import com.phonedsh.shell.RgAccelerator
import java.io.Closeable
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ShellAcceleratorToolTest {
    @Before
    fun requireNativeLibrary() {
        assertTrue(
            "libpdsh_jni must load for :dsh's shell adapter tests; failure=${NativeShell.failure}",
            NativeShell.available,
        )
    }

    @Test
    fun rg_runs_and_its_result_is_the_exec_tool_result_contract() {
        Workspace().use { workspace ->
            workspace.write("a.txt", "hello\nworld\n")
            val outcome = invoke(
                ShellAcceleratorTool(RgAccelerator(), workspace.mounts, TestClock()),
                "rg",
                listOf("rg", "-n", "hello"),
            )
            val parsed = ExecToolResult.parse(successJson(outcome))
            assertEquals(0, parsed.code)
            assertEquals("exited", parsed.status.wireName)
            assertTrue(String(parsed.stdout, Charsets.UTF_8).contains("a.txt:1:hello"))
            assertEquals(0, parsed.stderr.size)
        }
    }

    @Test
    fun the_budget_leaves_room_for_the_rust_truncation_marker() {
        // The point of the margin: a stream that hits the accelerator budget
        // arrives with the marker appended by pdsh-core, and the exec result
        // parser must still accept it. This asserts BOTH halves:
        //   1. `ExecToolResult.parse` does not throw (an over-budget stream
        //      throws `output_too_large` before any size assertion runs), and
        //   2. the decoded stream is inside MAX_STREAM_BYTES, i.e. the parser's
        //      inclusive boundary is what the margin protects.
        // With OUTPUT_MARGIN_BYTES = 0 the retained stream would be
        // MAX_STREAM_BYTES + marker bytes, so (1) would fail; changing the
        // constant alone cannot keep this test green.
        assertEquals(
            ExecToolResult.MAX_STREAM_BYTES.toLong() - 1024L,
            ShellAcceleratorTool.MAX_OUTPUT_BYTES,
        )
        Workspace().use { workspace ->
            workspace.write("a.txt", "x".repeat(9 * 1024 * 1024))
            val json = successJson(
                invoke(
                    ShellAcceleratorTool(RgAccelerator(), workspace.mounts, TestClock()),
                    "rg",
                    listOf("rg", "x"),
                ),
            )
            val parsed = parseWithoutThrowing(json)
            assertTrue(parsed.stdout.size <= ExecToolResult.MAX_STREAM_BYTES)
            val text = String(parsed.stdout, Charsets.UTF_8)
            assertTrue(text.take(120), text.contains("pdsh-shell truncated"))
        }
    }

    @Test
    fun the_result_parser_boundary_is_inclusive_at_exactly_the_frame_budget() {
        // Pins `<=` rather than `<`: a stream of exactly MAX_STREAM_BYTES is
        // legal, MAX_STREAM_BYTES + 1 is `output_too_large`. The margin above
        // only works because the boundary is inclusive; if it ever flips,
        // this test fails together with the truncation test.
        val atBudget = parseWithoutThrowing(
            ExecFixtures.resultJson(stdout = ByteArray(ExecToolResult.MAX_STREAM_BYTES)),
        )
        assertEquals(ExecToolResult.MAX_STREAM_BYTES, atBudget.stdout.size)

        val overBudget = assertThrows(ExecToolResultException::class.java) {
            ExecToolResult.parse(
                ExecFixtures.resultJson(stdout = ByteArray(ExecToolResult.MAX_STREAM_BYTES + 1)),
            )
        }
        assertEquals(ExecToolResultException.CODE_TOO_LARGE, overBudget.code)
    }

    @Test
    fun a_no_match_exit_code_is_exited_one() {
        Workspace().use { workspace ->
            workspace.write("a.txt", "hello\n")
            val parsed = ExecToolResult.parse(
                successJson(
                    invoke(
                        ShellAcceleratorTool(RgAccelerator(), workspace.mounts, TestClock()),
                        "rg",
                        listOf("rg", "absent"),
                    ),
                ),
            )
            assertEquals(1, parsed.code)
            assertEquals("exited", parsed.status.wireName)
        }
    }

    @Test
    fun jaq_with_null_input_is_dispatched() {
        Workspace().use { workspace ->
            val parsed = ExecToolResult.parse(
                successJson(
                    invoke(
                        ShellAcceleratorTool(JaqAccelerator(), workspace.mounts, TestClock()),
                        "jaq",
                        listOf("jaq", "-n", "."),
                    ),
                ),
            )
            assertEquals(0, parsed.code)
            assertEquals("null\n", String(parsed.stdout, Charsets.UTF_8))
        }
    }

    @Test
    fun jaq_that_would_read_process_stdin_is_refused() {
        Workspace().use { workspace ->
            val outcome = invoke(
                ShellAcceleratorTool(JaqAccelerator(), workspace.mounts, TestClock()),
                "jaq",
                listOf("jaq", "."),
            )
            val failure = outcome as? ToolOutcome.Failure
            assertEquals(ShellAcceleratorTool.CODE_UNSUPPORTED, failure?.code)
            assertEquals(ShellAcceleratorTool.MESSAGE_JAQ_STDIN, failure?.message)
        }
    }

    @Test
    fun stdin_data_is_refused_before_anything_runs() {
        Workspace().use { workspace ->
            val request = ExecFixtures.request(
                argv = listOf("jaq", ".a", "in.json"),
                stdin = JSONObject().put("mode", "data").put("data", "eyJhIjoxfQ=="),
            )
            val outcome = runBlocking {
                ShellAcceleratorTool(JaqAccelerator(), workspace.mounts, TestClock())
                    .invoke(ToolInvocation(ExecFixtures.IDEM_A, "jaq", request.toJson()))
            }
            val failure = outcome as? ToolOutcome.Failure
            assertEquals(ShellAcceleratorTool.CODE_UNSUPPORTED, failure?.code)
            assertEquals(ShellAcceleratorTool.MESSAGE_STDIN, failure?.message)
        }
    }

    @Test
    fun the_deadline_is_clamped_to_one_millisecond_not_zero() {
        Workspace().use { workspace ->
            val clock = TestClock(wall = 1_800_000_000_000L)
            // An already-expired absolute deadline must not become pdsh-ffi's
            // `0 = no deadline`; the command still runs with a 1 ms budget.
            val request = ExecFixtures.request(
                argv = listOf("rg", "--version"),
                deadline = clock.wall - 10_000L,
            )
            val outcome = runBlocking {
                ShellAcceleratorTool(RgAccelerator(), workspace.mounts, clock)
                    .invoke(ToolInvocation(ExecFixtures.IDEM_A, "rg", request.toJson()))
            }
            val parsed = ExecToolResult.parse(successJson(outcome))
            assertTrue(parsed.code == 0 || parsed.code == ShellAcceleratorTool.EXIT_TIMED_OUT)
        }
    }

    private fun invoke(
        tool: ShellAcceleratorTool,
        name: String,
        argv: List<String>,
    ): ToolOutcome = runBlocking {
        tool.invoke(
            ToolInvocation(
                requestId = ExecFixtures.IDEM_A,
                tool = name,
                argumentsJson = ExecFixtures.request(argv = argv).toJson(),
            ),
        )
    }

    /**
     * Runs [ExecToolResult.parse] and turns a throw into an explicit failure.
     *
     * JUnit 4.13 has no `assertDoesNotThrow`, and the point of the call sites is
     * exactly "the parser accepts this stream"; a bare call would fail with the
     * parser's exception without saying which half of the assertion broke.
     */
    private fun parseWithoutThrowing(json: String): ExecToolResult =
        try {
            ExecToolResult.parse(json)
        } catch (unexpected: RuntimeException) {
            throw AssertionError("the exec result parser rejected a legal stream", unexpected)
        }

    private fun successJson(outcome: ToolOutcome): String =
        (outcome as? ToolOutcome.Success)?.resultJson
            ?: throw AssertionError("expected a tool result, was $outcome")

    private class Workspace : Closeable {
        private val root = Files.createTempDirectory("pdsh-shell-adapter-")
        val mounts: List<AcceleratorMount> =
            listOf(AcceleratorMount(AcceleratorMount.WORKSPACE, root.toString()))

        fun write(name: String, text: String) {
            root.resolve(name).toFile().writeText(text)
        }

        override fun close() {
            root.toFile().deleteRecursively()
        }
    }
}
