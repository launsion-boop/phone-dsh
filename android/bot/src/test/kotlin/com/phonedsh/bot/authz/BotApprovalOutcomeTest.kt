// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BotApprovalOutcomeTest {
    @Test
    fun pendingIsRequiredAndOptionalMembersAreOmittedWhenUndefined() {
        val stale = BotApprovalOutcome.stale("stale:digest_mismatch")
        val members = stale.toJson().members
        assertEquals(setOf("ok", "allowed", "pending", "message"), members.keys)
        assertEquals(JsonBool(false), members["ok"])
        assertEquals(JsonBool(false), members["allowed"])
        assertEquals(JsonBool(false), members["pending"])
        assertEquals(JsonString("stale:digest_mismatch"), members["message"])

        val pending = BotApprovalOutcome(
            ok = true, allowed = false, pending = true, approvalId = "approval-1",
            message = "approval pending", expiresAt = 123,
        ).toJson().members
        assertEquals(
            setOf("ok", "allowed", "pending", "approvalId", "message", "expiresAt"),
            pending.keys,
        )
        assertFalse(pending.containsKey("approvalDecision"))
        assertFalse(pending.containsKey("scope"))

        val allowed = BotApprovalOutcome(
            ok = true, allowed = true, approvalId = "approval-2", message = "allowed",
            decision = BotApprovalDecision.ALWAYS, scope = "until",
        ).toJson().members
        assertEquals(JsonString("always"), allowed["approvalDecision"])
        assertEquals(JsonString("until"), allowed["scope"])
        assertNull(allowed["expiresAt"])
    }

    @Test
    fun denyKeepsTheDecisionButNotAScope() {
        val denied = BotApprovalOutcome(
            ok = false, allowed = false, approvalId = "approval-3", message = "approval denied",
            decision = BotApprovalDecision.DENY,
        ).toJson().members
        assertEquals(JsonBool(false), denied["ok"])
        assertEquals(JsonString("deny"), denied["approvalDecision"])
        assertFalse(denied.containsKey("scope"))
        assertTrue(denied.containsKey("pending"))
    }
}
