// phone-dsh — :dsh unit test: requestId idempotency (plan §13.7-J4).
// SPDX-License-Identifier: MIT
//
// The ledger is the one gate in front of every tool: a retried `requestId` must
// never run the side effect twice, and the caller must be able to tell "it ran"
// from "the earlier answer came back".

package com.phonedsh.dsh.tools

import com.phonedsh.dsh.host.HostLog
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class PhoneToolBridgeTest {
    private val invocations = AtomicInteger()

    private fun counterTool(outcome: ToolOutcome = ToolOutcome.Success("""{"ok":true}""")): PhoneTool =
        PhoneTool {
            invocations.incrementAndGet()
            outcome
        }

    private fun bridge(vararg tools: RegisteredTool): PhoneToolBridge = PhoneToolBridge(
        ledger = InMemoryRequestLedger(),
        logger = HostLog.None,
    ).also { it.registerTools(tools.toList()) }

    private fun invocation(requestId: String = "req-0001", tool: String = "write"): ToolInvocation =
        ToolInvocation(requestId = requestId, tool = tool, argumentsJson = "{}")

    @Test
    fun theSameRequestIdRunsTheHandlerOnce() = runBlocking {
        val bridge = bridge(RegisteredTool("write", counterTool()))

        val first = bridge.call(invocation())
        val second = bridge.call(invocation())

        // plan §13.7-J4: a retry replays the answer, it does not run the tool.
        assertEquals(1, invocations.get())
        assertTrue(first is ToolAnswer.Executed)
        assertTrue(second is ToolAnswer.Replayed)
        assertEquals(
            (first as ToolAnswer.Executed).outcome,
            (second as ToolAnswer.Replayed).outcome,
        )
    }

    @Test
    fun theLedgerDistinguishesANewIdFromAnInFlightOneAndFromACompletedOne() {
        val ledger = InMemoryRequestLedger()

        assertEquals(
            RequestLedger.Admission.Proceed,
            ledger.admit("req-1", "write"),
        )
        assertEquals(
            RequestLedger.Admission.InFlight,
            ledger.admit("req-1", "write"),
        )

        val outcome = ToolOutcome.Success("""{"bytes":3}""")
        ledger.complete("req-1", outcome)
        assertEquals(
            RequestLedger.Admission.Replay("write", outcome),
            ledger.admit("req-1", "write"),
        )
        assertEquals(listOf("req-1"), ledger.tracked())
    }

    @Test
    fun abandoningAnIdLetsItRunAgain() = runBlocking {
        val ledger = InMemoryRequestLedger()
        val bridge = PhoneToolBridge(ledger, HostLog.None)
        bridge.registerTool("write", counterTool())

        ledger.admit("req-9", "write")
        ledger.abandon("req-9")
        val answer = bridge.call(invocation(requestId = "req-9"))

        assertEquals(1, invocations.get())
        assertTrue(answer is ToolAnswer.Executed)
    }

    @Test
    fun aBrokenToolIsRecordedSoTheIdNeverRunsTwice() = runBlocking {
        val bridge = bridge(
            RegisteredTool(
                "exec",
                PhoneTool {
                    invocations.incrementAndGet()
                    throw IllegalStateException("boom")
                },
            ),
        )

        val first = bridge.call(invocation(requestId = "req-2", tool = "exec"))
        val second = bridge.call(invocation(requestId = "req-2", tool = "exec"))

        assertEquals(1, invocations.get())
        assertTrue(first is ToolAnswer.Executed)
        assertEquals(
            ToolOutcome.Failure(PhoneToolBridge.CODE_TOOL_FAILED, "IllegalStateException"),
            (first as ToolAnswer.Executed).outcome,
        )
        assertTrue(second is ToolAnswer.Replayed)
    }

    @Test
    fun anUnknownToolDoesNotConsumeTheRequestId() = runBlocking {
        val bridge = bridge()

        val rejected = bridge.call(invocation(requestId = "req-3", tool = "nope"))
        bridge.registerTool("nope", counterTool())
        val executed = bridge.call(invocation(requestId = "req-3", tool = "nope"))

        assertEquals(
            ToolAnswer.Rejected(
                PhoneToolBridge.CODE_UNKNOWN_TOOL,
                "no tool registered as \"nope\"",
            ),
            rejected,
        )
        assertTrue(executed is ToolAnswer.Executed)
        assertEquals(1, invocations.get())
    }

    @Test
    fun aRequestIdReusedForAnotherToolIsRefusedInsteadOfReplayed() = runBlocking {
        val bridge = bridge(
            RegisteredTool("write", counterTool()),
            RegisteredTool("remove", counterTool()),
        )

        bridge.call(invocation(requestId = "req-4", tool = "write"))
        val answered = bridge.call(invocation(requestId = "req-4", tool = "remove"))

        assertEquals(1, invocations.get())
        assertEquals(
            ToolAnswer.Rejected(
                PhoneToolBridge.CODE_REQUEST_ID_REUSED,
                "requestId \"req-4\" already completed for \"write\", not \"remove\"",
            ),
            answered,
        )
    }

    @Test
    fun aMalformedRequestIdIsRejectedBeforeAnyToolRuns() = runBlocking {
        val bridge = bridge(RegisteredTool("write", counterTool()))

        val answer = bridge.call(invocation(requestId = "has space"))

        assertEquals(0, invocations.get())
        assertEquals(
            ToolAnswer.Rejected(
                PhoneToolBridge.CODE_BAD_REQUEST_ID,
                "requestId must match ${PhoneToolBridge.REQUEST_ID_PATTERN.pattern}",
            ),
            answer,
        )
    }

    @Test
    fun theRegistryRejectsNamesTheWireCannotCarry() {
        val bridge = PhoneToolBridge(logger = HostLog.None)
        for (bad in listOf("", "a b", "x/y", "a".repeat(65))) {
            try {
                bridge.registerTool(bad, counterTool())
                throw AssertionError("tool name \"$bad\" should have been refused")
            } catch (expected: IllegalArgumentException) {
                // expected: the name becomes an EXEC_REQ field (D6 shape).
            }
        }
        bridge.registerTools(listOf(RegisteredTool("read", counterTool())))
        assertEquals(listOf("read"), bridge.registeredTools())
        assertTrue(bridge.isRegistered("read"))
    }
}
