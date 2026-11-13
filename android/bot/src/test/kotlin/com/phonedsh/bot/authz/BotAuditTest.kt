// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.bot.session.BotSessionKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BotAuditTest {
    private val effect = BotToolEffect(
        tool = "write", operation = "file.write", resource = "dir=/tmp/shared",
        mutability = BotToolMutability.WRITE, policy = BotToolPolicy.ASK,
    )

    @Test
    fun auditLogMapsOntoExistingEventTypesAndKeepsDigests() {
        val log = InMemoryAuthzEventLog()
        val audit = BotAuditLog(log)
        val record = BotAuditRecord(
            at = 1_000,
            source = "execution",
            decision = BotGrantDecision.ALLOW,
            principal = BotAuditPrincipal(
                botId = "main", sessionId = "gb-main", kind = "model",
                sessionKind = BotSessionKind.CHAT, certain = true,
            ),
            effects = listOf(BotExecutionAuditing.effect(effect, "a".repeat(64))),
            reason = "auto-policy",
        )
        assertTrue(audit.append(record))
        val event = log.all().single()
        assertEquals("effect.attempted", event.type)
        assertEquals("main", event.principal?.botId)
        assertEquals("chat", event.principal?.kind)
        assertEquals(record.toJson(), event.data)
        assertFalse(
            "unknown audit events are rejected instead of inventing a type",
            audit.append(record.copy(event = "unknown")),
        )
    }

    @Test
    fun inMemoryRecorderCapturesEveryRecord() {
        val recorder = BotInMemoryAuditRecorder()
        val record = BotAuditRecord(
            at = 1, source = "execution", decision = BotGrantDecision.DENY,
            principal = BotAuditPrincipal("main", kind = "model", certain = true),
            reason = "missing-grant",
        )
        assertTrue(recorder.append(record))
        assertEquals(listOf(record), recorder.records)
    }
}
