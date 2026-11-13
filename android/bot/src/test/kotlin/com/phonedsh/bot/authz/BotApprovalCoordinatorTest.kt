// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.gateway.BotAttribution
import com.phonedsh.bot.gateway.BotGatewayPrincipal
import com.phonedsh.bot.session.BotSessionKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BotApprovalCoordinatorTest {
    private val t0 = 1_760_000_000_000L
    private val arguments = JsonObject(emptyMap())
    private val digest = BotArgumentsDigest.string(arguments)
    private val principal = BotGatewayPrincipal(
        botId = "main",
        sessionId = "gb-task",
        kind = BotSessionKind.TASK,
        expiresAt = t0 + 12 * 60 * 60 * 1_000,
        incarnation = "a".repeat(32),
    )
    private val call = BotResolvedToolCall(
        sessionId = "gb-task",
        callId = "call-1",
        botId = "main",
        principal = principal,
        attribution = BotAttribution(
            id = "attribution-1",
            sessionId = "gb-task",
            incarnation = principal.incarnation,
            callId = "call-1",
            name = "UpdateMemory",
            argsDigest = digest,
            runtimeId = "phone-worker@0",
            createdAt = t0,
            expiresAt = t0 + BotAttributionRegistryTtl,
        ),
        arguments = arguments,
    )
    private val effect = BotToolEffect(
        tool = "memory",
        operation = "memory.write",
        resource = "memory:agent&tier=log&fact=x",
        mutability = BotToolMutability.WRITE,
        policy = BotToolPolicy.ASK,
        execution = "memory",
    )

    @Test
    fun durablePendingIsRebuiltFromTheEventLog() {
        val clock = MutableClock(t0)
        val log = InMemoryAuthzEventLog()
        val first = BotApprovalCoordinator(
            grants = BotGrantStore(log, { clock.value }),
            eventLog = log,
            now = { clock.value },
            scheduler = ManualApprovalScheduler(clock),
        )
        val pending = first.request(
            call = call,
            effects = listOf(effect),
            action = "update memory",
            detail = "",
            command = "",
            alwaysScope = "until",
            persistence = BotApprovalPersistence.DURABLE,
        )
        assertTrue(pending.pending)
        val approvalId = pending.approvalId!!

        val second = BotApprovalCoordinator(
            grants = BotGrantStore(log, { clock.value }),
            eventLog = log,
            now = { clock.value },
            scheduler = ManualApprovalScheduler(clock),
        )
        second.restoreDurable()
        assertEquals(listOf(approvalId), second.pendingIDs())
        assertEquals(digest, second.pendingDigest(approvalId))
        assertEquals(
            BotApprovalResolution.Resolved,
            second.resolve(approvalId, BotApprovalDecision.ALLOW_ONCE, digest),
        )
        assertEquals(BotApprovalDurableStatus.ALLOWED, second.durableStatus(approvalId))
    }

    @Test
    fun oneInteractiveApprovalConsumesTheOnceGrantAtDecisionTime() {
        val clock = MutableClock(t0)
        val store = BotGrantStore(now = { clock.value })
        val coordinator = BotApprovalCoordinator(
            grants = store,
            now = { clock.value },
            scheduler = ManualApprovalScheduler(clock),
        )
        val interactiveCall = call.copy(
            principal = principal.copy(kind = BotSessionKind.CHAT),
        )
        val thread = Thread {
            coordinator.request(
                call = interactiveCall,
                effects = listOf(effect.copy(execution = null)),
                action = "update memory",
                detail = "",
                command = "",
                alwaysScope = "until",
            )
        }
        thread.start()
        val deadline = System.nanoTime() + 2_000_000_000
        var approvalId: String? = null
        while (System.nanoTime() < deadline) {
            approvalId = coordinator.pendingIDs().firstOrNull()
            if (approvalId != null) break
            Thread.sleep(1)
        }
        val id = approvalId ?: error("approval never became pending")
        assertEquals(
            BotApprovalResolution.Resolved,
            coordinator.resolve(id, BotApprovalDecision.ALLOW_ONCE, digest),
        )
        thread.join(2_000)
        assertTrue("no once grant survives an interactive allowOnce", store.list().isEmpty())
    }

    private companion object {
        const val BotAttributionRegistryTtl: Long = 330_000
    }
}
