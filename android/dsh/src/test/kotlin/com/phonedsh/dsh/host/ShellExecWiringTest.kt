// phone-dsh — :dsh unit test: exec/1 advertises and executes the :shell accelerators.
// SPDX-License-Identifier: MIT
//
// This is the wiring acceptance at the bridge boundary: HELLO caps are exactly
// the executable tool set, an `EXEC_REQ` whose `argv[0]` is `rg` really runs the
// Rust accelerator through JNI, and a host without mounts advertises only
// `phone`. The tool/Rust contract itself is covered by ShellAcceleratorToolTest.

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerSignal
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.exec.ExecBridge
import com.phonedsh.dsh.exec.ExecEvent
import com.phonedsh.dsh.exec.ExecFixtures
import com.phonedsh.dsh.exec.TestClock
import com.phonedsh.dsh.tools.PhoneTool
import com.phonedsh.dsh.tools.ToolOutcome
import com.phonedsh.shell.AcceleratorMount
import com.phonedsh.shell.NativeShell
import java.io.Closeable
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.util.Base64
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ShellExecWiringTest {
    @Before
    fun requireNativeLibrary() {
        assertTrue(
            "libpdsh_jni must load for :dsh's exec wiring tests; failure=${NativeShell.failure}",
            NativeShell.available,
        )
    }

    @Test
    fun mounts_add_exactly_rg_and_jaq_to_the_advertised_capability() {
        Workspace().use { workspace ->
            assertEquals(
                setOf("exec/1", "accelerator:phone", "accelerator:rg", "accelerator:jaq"),
                bridge(workspace.mounts).capability.caps(),
            )
        }
    }

    @Test
    fun without_mounts_only_phone_is_advertised() {
        assertEquals(
            setOf("exec/1", "accelerator:phone"),
            bridge(emptyList()).capability.caps(),
        )
    }

    @Test
    fun an_exec_request_for_rg_reaches_the_rust_accelerator() {
        Workspace().use { workspace ->
            workspace.write("a.txt", "hello\nworld\n")
            val events = runBlocking {
                bridge(workspace.mounts)
                    .onRequest(ExecFixtures.request(argv = listOf("rg", "-n", "hello")))
                    .toList()
            }
            assertEquals("a.txt:1:hello\n", stdout(events))
            val exit = events.filterIsInstance<ExecEvent.Exit>().single()
            assertEquals(ExecEvent.ExitStatus.EXITED, exit.status)
            assertEquals(0, exit.code)
        }
    }

    @Test
    fun an_exec_request_for_jaq_with_null_input_reaches_the_rust_accelerator() {
        Workspace().use { workspace ->
            workspace.write("a.json", """{"a":1}""")
            val events = runBlocking {
                bridge(workspace.mounts)
                    .onRequest(ExecFixtures.request(argv = listOf("jaq", "-n", ".")))
                    .toList()
            }
            assertEquals("null\n", stdout(events))
            assertEquals(0, events.filterIsInstance<ExecEvent.Exit>().single().code)
        }
    }

    @Test
    fun jaq_without_input_becomes_a_terminal_unsupported_event() {
        Workspace().use { workspace ->
            val events = runBlocking {
                bridge(workspace.mounts)
                    .onRequest(ExecFixtures.request(argv = listOf("jaq", ".")))
                    .toList()
            }
            val error = events.filterIsInstance<ExecEvent.Error>().single()
            // exec.md §3: a request shape the host cannot honour is
            // `unsupported`, not `tool_failed`.
            assertEquals(ExecBridge.CODE_UNSUPPORTED, error.code)
            // ...and the event carries the *tool's* explanation. The bridge used
            // to replace it with a generic "not supported" sentence, which hid
            // the one line that says what the host can actually do.
            assertEquals(ShellAcceleratorTool.MESSAGE_JAQ_STDIN, error.message)
            assertFalse(events.any { event -> event is ExecEvent.Exit })
        }
    }

    @Test
    fun a_phone_tool_refusal_forwards_the_tools_own_message() {
        // The production tool: `phone files.list` is not a shape it implements,
        // so the model must be told that — not "the request is not supported by
        // this in-process accelerator".
        val events = runBlocking {
            ExecFixtures.bridge(PhoneInfoTool(), name = PhoneInfoTool.NAME)
                .onRequest(ExecFixtures.request(argv = listOf("phone", "files.list", "{}")))
                .toList()
        }
        val error = events.filterIsInstance<ExecEvent.Error>().single()
        assertEquals(ExecBridge.CODE_UNSUPPORTED, error.code)
        assertEquals(PhoneInfoTool.MESSAGE_UNSUPPORTED, error.message)
        assertFalse(events.any { event -> event is ExecEvent.Exit })
    }

    @Test
    fun an_unsupported_refusal_without_a_message_keeps_the_bridge_text() {
        val silent = PhoneTool { ToolOutcome.Failure(ExecBridge.CODE_UNSUPPORTED, "") }
        val events = runBlocking {
            ExecFixtures.bridge(silent, name = "phone")
                .onRequest(ExecFixtures.request(argv = listOf("phone", "info")))
                .toList()
        }
        val error = events.filterIsInstance<ExecEvent.Error>().single()
        assertEquals(ExecBridge.CODE_UNSUPPORTED, error.code)
        assertEquals(
            "the request is not supported by this in-process accelerator; nothing executed",
            error.message,
        )
    }

    @Test
    fun a_tool_that_ran_and_failed_stays_tool_failed() {
        val failing = PhoneTool { ToolOutcome.Failure("phone_info_failed", "boom") }
        val bridge = ExecFixtures.bridge(failing, name = "phone")
        val events = runBlocking {
            bridge.onRequest(ExecFixtures.request(argv = listOf("phone", "info"))).toList()
        }
        val error = events.filterIsInstance<ExecEvent.Error>().single()
        assertEquals(ExecBridge.CODE_TOOL_FAILED, error.code)
        assertFalse(events.any { event -> event is ExecEvent.Exit })
    }

    @Test
    fun a_stdin_data_request_is_refused_before_dispatch() {
        Workspace().use { workspace ->
            val events = runBlocking {
                bridge(workspace.mounts)
                    .onRequest(
                        ExecFixtures.request(
                            argv = listOf("jaq", "-n", "."),
                            stdin = org.json.JSONObject()
                                .put("mode", "data")
                                .put("data", "eyJhIjoxfQ=="),
                        ),
                    )
                    .toList()
            }
            val error = events.filterIsInstance<ExecEvent.Error>().single()
            assertEquals(ExecBridge.CODE_UNSUPPORTED, error.code)
            assertFalse(events.any { event -> event is ExecEvent.Exit })
        }
    }

    private fun bridge(mounts: List<AcceleratorMount>): ExecBridge = HostExec.defaultTools(
        clock = TestClock(),
        controller = openAdmission(),
        wal = null,
        logger = HostLog.None,
        shellMounts = mounts,
    )

    /** The D14 machine in `Running`, i.e. admission open. */
    private fun openAdmission(): ControllerStateMachine =
        ControllerStateMachine.boot(persistedState = null).apply {
            handle(ControllerSignal.LeaseCheckResult(verified = true), atMillis = 0L)
        }

    /** Concatenates the base64 `output` events of one execution. */
    private fun stdout(events: List<ExecEvent>): String {
        val bytes = ByteArrayOutputStream()
        for (event in events.filterIsInstance<ExecEvent.Output>()) {
            if (event.stream == ExecEvent.Stream.STDOUT) {
                bytes.write(Base64.getDecoder().decode(event.data))
            }
        }
        return bytes.toString(Charsets.UTF_8.name())
    }

    private class Workspace : Closeable {
        private val root = Files.createTempDirectory("pdsh-exec-wiring-")
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
