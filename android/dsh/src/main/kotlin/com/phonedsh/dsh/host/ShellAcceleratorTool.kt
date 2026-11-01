// phone-dsh — :dsh / com.phonedsh.dsh.host: one exec/1 tool over a :shell accelerator.
// SPDX-License-Identifier: MIT
//
// This is the one adapter between the exec tool seam (`PhoneTool`) and the
// `:shell` `Accelerator`. It contains no command logic: it validates the
// dispatch request, maps the deadline and the output budget, calls the
// accelerator, and renders the answer as the `ExecToolResult` JSON contract.
//
// Two request shapes cannot be honoured and are refused as `unsupported`
// instead of being run with a substitute meaning:
//   * any stdin other than `ignore` — the pdsh-ffi C ABI has no stdin channel,
//     so a `stdin.data` payload would be silently dropped;
//   * `jaq FILTER` with neither a file operand nor `-n` — pdsh-jaq would read
//     the host process's inherited standard input (`stdin.mode = ignore` only
//     promises the command sees EOF, not that reading it is intended). The
//     decision is made by `JaqAccelerator.readsProcessStdin`, which asks the
//     Rust parser, so Kotlin carries no second copy of the jq option grammar.
//
// The per-stream budget is `ExecToolResult.MAX_STREAM_BYTES - OUTPUT_MARGIN_BYTES`
// on purpose. pdsh-core's truncation keeps the head and tail of the budget and
// inserts a marker line that is not counted in the budget, so a stream that hit
// exactly `MAX_STREAM_BYTES` would arrive a few dozen bytes over the frame
// budget and `ExecToolResult.parse` would reject a legitimate result as
// `output_too_large`. The 1 KiB margin is far larger than the marker
// (`[pdsh-shell truncated N bytes]` plus a newline) and small enough to be
// irrelevant to the worker.
//
// `argv`, `cwd` and the output are never copied into a log line or a failure
// message here; a command line can carry a private path. [CODE_UNSUPPORTED] is
// protocol-level: `ExecBridge` forwards it as the terminal `unsupported` event.
// Every other failure code is log-only, because a tool that ran and failed is
// reported on the wire as `tool_failed`.

package com.phonedsh.dsh.host

import com.phonedsh.dsh.exec.ExecEvent
import com.phonedsh.dsh.exec.ExecRequest
import com.phonedsh.dsh.exec.ExecRequestException
import com.phonedsh.dsh.exec.ExecToolResult
import com.phonedsh.dsh.exec.StdinSpec
import com.phonedsh.dsh.tools.PhoneTool
import com.phonedsh.dsh.tools.ToolInvocation
import com.phonedsh.dsh.tools.ToolOutcome
import com.phonedsh.platform.Clock
import com.phonedsh.shell.Accelerator
import com.phonedsh.shell.AcceleratorException
import com.phonedsh.shell.AcceleratorLimits
import com.phonedsh.shell.AcceleratorMount
import com.phonedsh.shell.AcceleratorPanicException
import com.phonedsh.shell.AcceleratorRequest
import com.phonedsh.shell.AcceleratorResult
import com.phonedsh.shell.AcceleratorUnavailable
import com.phonedsh.shell.JaqAccelerator
import java.util.Base64
import org.json.JSONObject

/**
 * Dispatches one registered accelerator (`rg`, `jaq`) for an `EXEC_REQ`.
 *
 * The tool exists only while its accelerator is available and the host has a
 * mount, so [ToolOutcome.Failure] here is not an availability stub: every path
 * either ran the Rust command or refused a request shape the C ABI cannot
 * represent.
 *
 * @param accelerator the `:shell` accelerator this tool is registered under;
 *   its [Accelerator.name] must equal the registry key `ExecBridge` dispatches
 *   on (`HostExec` builds both from the same list).
 * @param mounts the guest-to-host mounts the accelerator may read; the same list
 *   that made `ShellAccelerators.detect` return the accelerator.
 * @param clock wall time for the request's absolute `deadline`; the accelerator
 *   timeout is relative, so the remaining budget is computed once here.
 */
class ShellAcceleratorTool(
    private val accelerator: Accelerator,
    private val mounts: List<AcceleratorMount>,
    private val clock: Clock,
) : PhoneTool {
    override suspend fun invoke(invocation: ToolInvocation): ToolOutcome {
        val request = try {
            ExecRequest.parse(invocation.argumentsJson)
        } catch (invalid: ExecRequestException) {
            // The bridge produced this request; one it cannot read is a host
            // defect, and the payload is never echoed.
            return ToolOutcome.Failure(CODE_UNSUPPORTED, MESSAGE_UNREADABLE)
        }

        if (request.stdin !is StdinSpec.Ignore) {
            return ToolOutcome.Failure(CODE_UNSUPPORTED, MESSAGE_STDIN)
        }
        if (accelerator is JaqAccelerator && JaqAccelerator.readsProcessStdin(request.argv)) {
            return ToolOutcome.Failure(CODE_UNSUPPORTED, MESSAGE_JAQ_STDIN)
        }

        val environment = HashMap<String, String>(request.env.size)
        for ((name, value) in request.env) {
            // `null` means "unset" in exec.md §2.3; pdsh-ffi can only express
            // absent pairs, so an unset variable is omitted, never sent empty.
            if (value != null) environment[name] = value
        }

        val result = try {
            accelerator.run(
                AcceleratorRequest(
                    argv = request.argv,
                    cwd = request.cwd,
                    mounts = mounts,
                    env = environment,
                    limits = AcceleratorLimits(
                        timeoutMs = timeoutMillis(request),
                        maxOutputBytes = MAX_OUTPUT_BYTES,
                    ),
                ),
            )
        } catch (unavailable: AcceleratorUnavailable) {
            return ToolOutcome.Failure(CODE_ACCELERATOR_FAILED, MESSAGE_UNAVAILABLE)
        } catch (refused: AcceleratorException) {
            // The code is a stable `SHELL_*` string; the detail may name a
            // field but never an argv element or file content.
            return ToolOutcome.Failure(CODE_ACCELERATOR_FAILED, refused.code)
        } catch (panic: AcceleratorPanicException) {
            return ToolOutcome.Failure(CODE_ACCELERATOR_FAILED, MESSAGE_PANIC)
        } catch (invalid: IllegalArgumentException) {
            // Unreachable for a request ExecRequest validated; a wiring defect.
            return ToolOutcome.Failure(CODE_UNSUPPORTED, MESSAGE_UNREADABLE)
        }

        return ToolOutcome.Success(resultJson(result))
    }

    /**
     * The relative budget for the accelerator.
     *
     * `pdsh-ffi` treats `0` as "no deadline", so an expired request is clamped to
     * one millisecond rather than silently becoming unbounded. An absent
     * deadline uses the linked registry's 30 s default.
     */
    private fun timeoutMillis(request: ExecRequest): Long =
        request.deadline?.let { deadline -> (deadline - clock.nowMillis()).coerceAtLeast(1L) }
            ?: AcceleratorLimits.DEFAULT_TIMEOUT_MS

    /** The `ExecToolResult` result object for one completed run. */
    private fun resultJson(result: AcceleratorResult): String {
        val encoder = Base64.getEncoder()
        return JSONObject()
            .put("status", status(result.exitCode).wireName)
            .put("code", result.exitCode)
            .put("signal", JSONObject.NULL)
            .put("quiescent", true)
            .put("stdout", encoder.encodeToString(result.stdout))
            .put("stderr", encoder.encodeToString(result.stderr))
            .toString()
    }

    /**
     * Maps the accelerator exit code to the exit domain of exec-bridge v1.
     *
     * 124/130/70 are `pdsh-ffi`'s deadline, cancel and caught-panic codes; any
     * other code is the command's own (`rg` 0/1/2, `jaq` 0..5) and stays
     * `exited`.
     */
    private fun status(exitCode: Int): ExecEvent.ExitStatus = when (exitCode) {
        EXIT_TIMED_OUT -> ExecEvent.ExitStatus.TIMED_OUT
        EXIT_CANCELLED -> ExecEvent.ExitStatus.CANCELLED
        EXIT_PANIC -> ExecEvent.ExitStatus.FAILED
        else -> ExecEvent.ExitStatus.EXITED
    }

    companion object {
        /**
         * Stable failure code: the request cannot be dispatched at all.
         *
         * `ExecBridge` forwards this one as the terminal `unsupported` event
         * (exec.md §3); it is the only code from this tool that reaches the wire.
         */
        const val CODE_UNSUPPORTED: String = "unsupported"

        /**
         * Stable failure code: the native bridge refused or failed the run.
         *
         * Log-only: the wire reports `tool_failed`.
         */
        const val CODE_ACCELERATOR_FAILED: String = "accelerator_failed"

        /** Log-only detail: the dispatch request is not readable. */
        const val MESSAGE_UNREADABLE: String = "the dispatch request is unreadable"

        /** Log-only detail: the C ABI has no stdin channel. */
        const val MESSAGE_STDIN: String =
            "an in-process accelerator has no stdin; stdin.mode must be ignore"

        /** Log-only detail: `jaq` would read the host process's stdin. */
        const val MESSAGE_JAQ_STDIN: String =
            "jaq would read the process standard input, which the C ABI cannot supply; " +
                "name an input file or pass -n"

        /** Log-only detail: the accelerator became unavailable after registration. */
        const val MESSAGE_UNAVAILABLE: String = "the accelerator is unavailable"

        /** Log-only detail: a Rust panic crossed the JNI boundary. */
        const val MESSAGE_PANIC: String = "the accelerator panicked"

        /** Headroom kept below the exec frame budget for the truncation marker. */
        const val OUTPUT_MARGIN_BYTES: Int = 1024

        /**
         * The per-stream budget passed to `pdsh-ffi`.
         *
         * `ExecToolResult.parse` refuses more than `MAX_STREAM_BYTES` of decoded
         * output, and pdsh-core may add its truncation marker on top of the
         * budget, so the accelerator is asked for less than the frame allows.
         */
        val MAX_OUTPUT_BYTES: Long =
            (ExecToolResult.MAX_STREAM_BYTES - OUTPUT_MARGIN_BYTES).toLong()

        /** pdsh-ffi exit code of a run that hit its deadline. */
        const val EXIT_TIMED_OUT: Int = 124

        /** pdsh-ffi exit code of a cancelled run. */
        const val EXIT_CANCELLED: Int = 130

        /** pdsh-ffi exit code of a caught Rust panic. */
        const val EXIT_PANIC: Int = 70
    }
}
