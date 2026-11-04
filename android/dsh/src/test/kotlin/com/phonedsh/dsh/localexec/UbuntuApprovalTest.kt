// phone-dsh — :dsh unit test: the per-session approval gate.
// SPDX-License-Identifier: MIT
//
// What this pins is the design §3 layer 1 promise: **one approval per session**.
// The gate, not the dialog, owns the scope, so these tests can prove the scope
// without a device: a second run in the same session does not ask, a different
// session does, a denial is remembered but revocable, and "nobody could ask" is
// never turned into a grant.

package com.phonedsh.dsh.localexec

import com.phonedsh.dsh.host.HostLog
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UbuntuApprovalTest {
    private val clock = TestClock()

    private fun request(session: String? = "sess-a", env: String = "ubuntu-24.04"): UbuntuApprovalRequest =
        UbuntuApprovalRequest(
            sessionId = session,
            env = env,
            backend = "mock",
            label = null,
            argvDigest = "a".repeat(64),
            argvLength = 3,
        )

    @Test
    fun one_approval_covers_the_rest_of_the_session() = runBlocking {
        val (gate, prompt) = approvalGate(clock = clock)
        val first = gate.authorize(request())
        assertEquals(UbuntuApprovalState.GRANTED, first.state)
        assertTrue(first.prompted)
        assertEquals("sess-a", first.sessionId)

        val second = gate.authorize(request())
        assertEquals(UbuntuApprovalState.GRANTED, second.state)
        assertFalse("the second run must not show a dialog", second.prompted)
        assertEquals("the dialog was shown exactly once", 1, prompt.requests.size)
        // The cached answer keeps the decision time, so the audit does not claim
        // the user was asked again.
        assertEquals(first.atMs, second.atMs)
    }

    @Test
    fun a_denial_is_remembered_for_the_session_and_nothing_asks_again() = runBlocking {
        val (gate, prompt) = approvalGate(answer = UbuntuApprovalDecision.Denied, clock = clock)
        val first = gate.authorize(request())
        assertEquals(UbuntuApprovalState.DENIED, first.state)
        assertTrue(first.prompted)
        val second = gate.authorize(request())
        assertEquals(UbuntuApprovalState.DENIED, second.state)
        assertFalse(second.prompted)
        assertEquals(1, prompt.requests.size)
    }

    @Test
    fun a_different_session_invalidates_the_previous_decision() = runBlocking {
        val (gate, prompt) = approvalGate(clock = clock)
        gate.authorize(request(session = "sess-a"))
        assertEquals("sess-a", gate.boundSession())

        val other = gate.authorize(request(session = "sess-b"))
        assertEquals(UbuntuApprovalState.GRANTED, other.state)
        assertTrue("a new session must ask again", other.prompted)
        assertEquals(2, prompt.requests.size)
        assertEquals("sess-b", prompt.requests[1].sessionId)
        assertEquals("sess-b", gate.boundSession())
    }

    @Test
    fun ending_or_revoking_the_session_makes_the_next_run_ask_again() = runBlocking {
        val (gate, prompt) = approvalGate(clock = clock)
        gate.authorize(request())
        gate.endSession()
        assertNull(gate.boundSession())
        val afterEnd = gate.authorize(request())
        assertTrue(afterEnd.prompted)
        assertEquals(2, prompt.requests.size)

        gate.revoke()
        val afterRevoke = gate.authorize(request())
        assertTrue(afterRevoke.prompted)
        assertEquals(3, prompt.requests.size)
    }

    @Test
    fun no_dialog_is_unavailable_and_is_never_cached() = runBlocking {
        val gate = UbuntuApprovalGate(prompt = { null }, clock = clock)
        val first = gate.authorize(request())
        assertEquals(UbuntuApprovalState.UNAVAILABLE, first.state)
        assertEquals(UbuntuApprovalGate.REASON_NO_SURFACE, first.reason)
        assertFalse(first.prompted)
        val second = gate.authorize(request())
        assertEquals(UbuntuApprovalState.UNAVAILABLE, second.state)
    }

    @Test
    fun an_unanswered_dialog_times_out_as_unavailable_not_denied() = runBlocking {
        val hang = object : UbuntuApprovalPrompt {
            override suspend fun ask(request: UbuntuApprovalRequest): UbuntuApprovalDecision {
                delay(10_000)
                return UbuntuApprovalDecision.Approved
            }
        }
        val gate = UbuntuApprovalGate(prompt = { hang }, clock = clock, timeoutMillis = 20)
        val answer = gate.authorize(request())
        assertEquals(UbuntuApprovalState.UNAVAILABLE, answer.state)
        assertEquals(UbuntuApprovalGate.REASON_TIMEOUT, answer.reason)
        assertNull("a timeout cannot bind a grant", gate.boundSession())
    }

    @Test
    fun a_malformed_session_id_never_binds_and_asks_every_time() = runBlocking {
        val (gate, prompt) = approvalGate(clock = clock)
        gate.authorize(request(session = "not a session"))
        gate.authorize(request(session = "not a session"))
        assertEquals(2, prompt.requests.size)
        assertNull(gate.boundSession())
        // The request still carries what the caller sent; the gate is what
        // refuses to bind a grant to an id it cannot validate.
        assertEquals("not a session", prompt.requests[0].sessionId)
    }

    @Test
    fun the_dialog_summary_is_eight_hex_of_the_session_digest() {
        // The confirmation prints this string. It is the user's only way to tell
        // "the same session asking again" from "a different session asking", so
        // the shape and the stability are both contract: 8 lowercase hex, the
        // same for one session, different for another, never the raw id.
        val summary = UbuntuApprovalGate.summary("sess-a")
        assertEquals(UbuntuApprovalGate.digest("sess-a"), summary)
        assertEquals(8, summary.length)
        assertTrue("expected 8 lowercase hex, was $summary", summary.matches(Regex("[0-9a-f]{8}")))
        assertEquals(summary, UbuntuApprovalGate.summary("sess-a"))
        assertFalse(UbuntuApprovalGate.summary("sess-b") == summary)
        assertEquals("the summary never prints the session id", false, summary.contains("sess-a"))
        // A session the gate cannot validate has no summary; the dialog says so
        // instead of inventing one (the host tool refuses such a dispatch before
        // it reaches the dialog at all — this is the defensive shape).
        assertEquals(UbuntuApprovalGate.NO_SESSION, UbuntuApprovalGate.summary(null))
        assertEquals(UbuntuApprovalGate.NO_SESSION, UbuntuApprovalGate.summary("not a session"))
    }

    @Test
    fun the_audit_line_names_the_decision_and_never_the_raw_session_id() = runBlocking {
        val lines = mutableListOf<String>()
        val log = object : HostLog {
            override fun debug(message: String) = Unit
            override fun info(message: String) {
                lines += message
            }

            override fun warn(message: String) {
                lines += message
            }

            override fun error(message: String) = Unit
        }
        val gate = UbuntuApprovalGate(
            prompt = { RecordingApprovalPrompt(UbuntuApprovalDecision.Approved) },
            clock = clock,
            logger = log,
        )
        gate.authorize(request(session = "sess-secret-identifier"))
        val line = lines.single()
        assertTrue(line.contains("ubuntu approval=granted"))
        assertTrue(line.contains("env=ubuntu-24.04"))
        assertTrue("the session id is named by digest only", !line.contains("sess-secret-identifier"))
        assertEquals(
            UbuntuApprovalGate.digest("sess-secret-identifier"),
            line.substringAfter("session=").substringBefore(' ').trim(),
        )
    }
}
