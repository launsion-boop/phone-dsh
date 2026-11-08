// phone-dsh — :dsh / com.phonedsh.dsh.tools: the phone-tool vocabulary.
// SPDX-License-Identifier: MIT
//
// Plan §13.7-J3/J4: the worker's EXEC_REQ must reach a registered host tool and
// its result must travel back as EXEC_EVT. The wire shapes belong to
// `spec/v1/exec.md`; this file only names the three values the dispatch seam
// needs, so the registry and the idempotency ledger can be tested before the
// frame codec for EXEC_REQ exists.
//
// Nothing here parses `argumentsJson`. The argument schema is the tool's own
// contract (`exec.md` §4.1) and inventing a second JSON dialect here would be a
// second source of truth; the field is carried through verbatim.

package com.phonedsh.dsh.tools

/**
 * One tool call as the host hands it to a [PhoneTool].
 *
 * [requestId] is the worker's idempotency key (`exec.md`: a retry of the same
 * work reuses it). It is validated against D6 (`[A-Za-z0-9._-]{1,64}`) before any
 * tool runs, because it becomes part of the ledger key and, in P3, a filename.
 */
data class ToolInvocation(
    val requestId: String,
    val tool: String,
    /** The tool's argument object, unmodified. */
    val argumentsJson: String,
)

/** What a tool produced. Both variants are safe to log: no token, no URL. */
sealed interface ToolOutcome {
    /** The tool's result object, unmodified. */
    data class Success(val resultJson: String) : ToolOutcome

    /** A structured failure: stable [code], human [message]. */
    data class Failure(val code: String, val message: String) : ToolOutcome
}

/** One host tool. [invoke] must be idempotent for a given [ToolInvocation.requestId]. */
fun interface PhoneTool {
    suspend fun invoke(invocation: ToolInvocation): ToolOutcome
}

/**
 * A tool whose running invocation can be interrupted by `EXEC_CTL cancel`.
 *
 * [com.phonedsh.dsh.exec.ExecBridge] records the terminal `cancelled` exit
 * itself; this hook only lets a tool that owns an external resource (an SSH
 * connection) release it, so cancellation is not merely an observed stop
 * (exec.md §2: cancel/deadline delivers SIGTERM). The tool's eventual result is
 * still discarded by the bridge, and the ledger keeps the cancelled record, so
 * a retry with the same `idem_key` replays rather than re-running a remote side
 * effect.
 */
interface CancellableTool : PhoneTool {
    /** Interrupts the invocation whose request carries [execId]; a no-op when none runs. */
    fun cancelExecution(execId: String)
}

/** A tool plus the name the worker addresses it by. */
data class RegisteredTool(val name: String, val tool: PhoneTool)

/**
 * The answer to one dispatch.
 *
 * [Executed] and [Replayed] are separate values on purpose: "the tool ran" and
 * "the ledger returned the earlier answer" are different facts, and a caller that
 * cannot tell them apart will double-count side effects in telemetry.
 */
sealed interface ToolAnswer {
    /** The tool ran now; [outcome] is its result. */
    data class Executed(val outcome: ToolOutcome) : ToolAnswer

    /** The same `requestId` was already completed; [outcome] is the stored result. */
    data class Replayed(val outcome: ToolOutcome) : ToolAnswer

    /** The same `requestId` is still running; the duplicate must not execute. */
    data class InFlight(val requestId: String) : ToolAnswer

    /** Nothing ran: an unknown tool, a malformed id, or an id reused for another tool. */
    data class Rejected(val code: String, val detail: String) : ToolAnswer
}
