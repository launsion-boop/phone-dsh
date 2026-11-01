// phone-dsh — :dsh / com.phonedsh.dsh.tools: the tool registry + dispatch seam.
// SPDX-License-Identifier: MIT
//
// plan §13.7-J3/J4: a worker's EXEC_REQ is dispatched to a registered host tool,
// once per `requestId`, and the answer is what the worker observes. This file is
// the dispatch half; the wire half (EXEC_REQ decode, EXEC_EVT encode) belongs to
// the exec lane and is deliberately absent, which is also why `exec/1` is not in
// the host HELLO capabilities yet (see HostCapabilities.CURRENT).
//
// The registry is intentionally minimal: a name -> handler map with no ordering,
// no priority, no discovery and no permissions. A tool that needs approval is
// `:lib`'s ApprovalCard plus a policy above this seam; a tool that needs the
// network goes through `:net`'s GatewaySession. Keeping this object dumb is what
// makes it safe to put under every future tool.

package com.phonedsh.dsh.tools

import com.phonedsh.dsh.host.HostLog
import kotlinx.coroutines.CancellationException

/**
 * The host tool registry, with `requestId` idempotency in front of every call.
 *
 * [call] never throws for a tool failure: a throwing tool becomes
 * [ToolOutcome.Failure] with a stable code and its class name, because an
 * exception escaping into the caller would be a host defect visible to the page.
 * Cancellation is the exception: it is rethrown after the id is abandoned, so a
 * cancelled call can be retried rather than replaying a half-finished result.
 */
class PhoneToolBridge(
    private val ledger: RequestLedger = InMemoryRequestLedger(),
    private val logger: HostLog = HostLog.Println,
) {
    private val lock = Any()
    private val tools = LinkedHashMap<String, PhoneTool>()

    /** Registers [tools]; a duplicate name replaces the previous handler. */
    fun registerTools(tools: Collection<RegisteredTool>) {
        for (registered in tools) registerTool(registered.name, registered.tool)
    }

    /** Registers one tool under a D6-valid name. */
    fun registerTool(name: String, tool: PhoneTool) {
        require(NAME_PATTERN.matches(name)) {
            "tool name must match ${NAME_PATTERN.pattern}, was \"$name\""
        }
        synchronized(lock) { tools[name] = tool }
        logger.info("tool registered: $name")
    }

    /** Registered names, in registration order. */
    fun registeredTools(): List<String> = synchronized(lock) { tools.keys.toList() }

    /** Whether a tool is registered under [name]. */
    fun isRegistered(name: String): Boolean = synchronized(lock) { name in tools }

    /**
     * Dispatches [invocation] at most once per `requestId`.
     *
     * Order: validate the id, find the tool, then ask the ledger. The ledger is
     * asked *after* the tool lookup so an unknown tool never consumes an id (the
     * worker can fix the name and retry with the same id).
     */
    suspend fun call(invocation: ToolInvocation): ToolAnswer {
        if (!REQUEST_ID_PATTERN.matches(invocation.requestId)) {
            return ToolAnswer.Rejected(
                code = CODE_BAD_REQUEST_ID,
                detail = "requestId must match ${REQUEST_ID_PATTERN.pattern}",
            )
        }
        val tool = synchronized(lock) { tools[invocation.tool] }
            ?: return ToolAnswer.Rejected(
                code = CODE_UNKNOWN_TOOL,
                detail = "no tool registered as \"${invocation.tool}\"",
            )
        return when (val admission = ledger.admit(invocation.requestId, invocation.tool)) {
            is RequestLedger.Admission.Replay -> {
                if (admission.tool != invocation.tool) {
                    // Reusing one id for two tools would make the stored answer a
                    // lie about what ran; refuse instead of replaying it.
                    ToolAnswer.Rejected(
                        code = CODE_REQUEST_ID_REUSED,
                        detail = "requestId \"${invocation.requestId}\" already completed for " +
                            "\"${admission.tool}\", not \"${invocation.tool}\"",
                    )
                } else {
                    logger.info(
                        "tool replay: ${invocation.tool} requestId=${invocation.requestId}; " +
                            "the handler does not run again",
                    )
                    ToolAnswer.Replayed(admission.outcome)
                }
            }

            RequestLedger.Admission.InFlight -> {
                logger.warn(
                    "tool duplicate while in flight: ${invocation.tool} " +
                        "requestId=${invocation.requestId}; refusing to run it twice",
                )
                ToolAnswer.InFlight(invocation.requestId)
            }

            RequestLedger.Admission.Proceed -> execute(invocation, tool)
        }
    }

    private suspend fun execute(invocation: ToolInvocation, tool: PhoneTool): ToolAnswer {
        val outcome = try {
            tool.invoke(invocation)
        } catch (cancelled: CancellationException) {
            // The call did not finish; the worker may retry it, so the id must not
            // answer a replay of an outcome that was never produced.
            ledger.abandon(invocation.requestId)
            throw cancelled
        } catch (failure: Exception) {
            // Recorded, not rethrown: the host survives a broken tool, and a retry
            // of the same id must not run the side effect a second time. The text is
            // the class name only — a tool's message can carry user data.
            ToolOutcome.Failure(code = CODE_TOOL_FAILED, message = failure.javaClass.simpleName)
        }
        ledger.complete(invocation.requestId, outcome)
        logger.info("tool executed: ${invocation.tool} requestId=${invocation.requestId}")
        return ToolAnswer.Executed(outcome)
    }

    companion object {
        /** channel.md §6 / D6 string id: `[A-Za-z0-9._-]{1,64}`. */
        val REQUEST_ID_PATTERN: Regex = Regex("[A-Za-z0-9._-]{1,64}")

        /** The same D6 shape for the tool name the worker addresses. */
        val NAME_PATTERN: Regex = Regex("[A-Za-z0-9._-]{1,64}")

        /** The id is not a D6 string. */
        const val CODE_BAD_REQUEST_ID: String = "BAD_REQUEST_ID"

        /** Nothing is registered under that name. */
        const val CODE_UNKNOWN_TOOL: String = "UNKNOWN_TOOL"

        /** The id was already completed for a different tool. */
        const val CODE_REQUEST_ID_REUSED: String = "REQUEST_ID_REUSED"

        /** The tool threw; the answer is stored, so the same id never re-runs it. */
        const val CODE_TOOL_FAILED: String = "TOOL_FAILED"
    }
}
