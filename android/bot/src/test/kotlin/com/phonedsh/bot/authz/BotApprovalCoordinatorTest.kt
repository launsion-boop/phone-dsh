// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.gateway.BotAttribution
import com.phonedsh.bot.gateway.BotGatewayPrincipal
import com.phonedsh.bot.session.BotSessionKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicReference

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

    @Test
    fun destructiveAlwaysDecisionIsAConsumedOneShotAndTheCardOffersNone() {
        val clock = MutableClock(t0)
        val log = InMemoryAuthzEventLog()
        val store = BotGrantStore(now = { clock.value })
        val coordinator = BotApprovalCoordinator(
            grants = store,
            eventLog = log,
            now = { clock.value },
            scheduler = ManualApprovalScheduler(clock),
        )
        val interactiveCall = call.copy(principal = principal.copy(kind = BotSessionKind.CHAT))
        val destructive = BotToolEffect(
            tool = "bash",
            operation = "rm-destructive",
            resource = "/tmp/c6-approval",
            target = "/tmp/c6-approval",
            mutability = BotToolMutability.DESTRUCTIVE,
            policy = BotToolPolicy.ASK,
        )
        val pending = startInteractive(coordinator, interactiveCall, listOf(destructive))
        val requested = log.all().first { event ->
            event.type == "approval.requested" &&
                BotJson.string(event.data.members["approvalID"]) == pending.approvalId
        }
        assertEquals(
            "a destructive effect must not offer a standing answer",
            JsonString("none"),
            requested.data.members["alwaysScope"],
        )
        val outcome = pending.resolve(coordinator, digest, BotApprovalDecision.ALWAYS)
        assertTrue(outcome.allowed)
        assertEquals(BotApprovalDecision.ALWAYS, outcome.decision)
        assertEquals("once", outcome.scope)
        assertTrue(
            "an interactive always-turned-once grant is consumed at decision time",
            store.list().isEmpty(),
        )
        assertNull(
            "the next destructive call must ask again",
            coordinator.standingDecision(interactiveCall, listOf(destructive), deferConsumption = false),
        )
    }

    @Test
    fun fileEgressAlwaysKeepsTheParentDirectoryScope() {
        val clock = MutableClock(t0)
        val store = BotGrantStore(now = { clock.value })
        val coordinator = BotApprovalCoordinator(
            grants = store,
            now = { clock.value },
            scheduler = ManualApprovalScheduler(clock),
        )
        val interactiveCall = call.copy(principal = principal.copy(kind = BotSessionKind.CHAT))
        val workspace = "/dsh/workspace/.dshbot/agents/main"
        val effects = BotEgressEffects.fileEffects(
            tool = "write",
            arguments = jsonObject("file_path" to JsonString("/tmp/c6-approval-out.txt")),
            workspaceRoot = workspace,
        )
        assertEquals("dir=/tmp", effects.single().grantResource)
        val pending = startInteractive(coordinator, interactiveCall, effects)
        val outcome = pending.resolve(coordinator, digest, BotApprovalDecision.ALWAYS)
        assertEquals("until", outcome.scope)
        val grant = store.list().single()
        assertEquals(BotGrantScope.UNTIL, grant.scope)
        assertEquals("dir=/tmp", grant.resource)
        assertNull(
            "a grant for /tmp must not authorize another directory",
            coordinator.standingDecision(
                interactiveCall,
                BotEgressEffects.fileEffects(
                    tool = "write",
                    arguments = jsonObject("file_path" to JsonString("/var/tmp/other.txt")),
                    workspaceRoot = workspace,
                ),
                deferConsumption = false,
            ),
        )
        assertTrue(
            "a grant for /tmp authorizes the next write in /tmp",
            coordinator.standingDecision(
                interactiveCall,
                BotEgressEffects.fileEffects(
                    tool = "write",
                    arguments = jsonObject("file_path" to JsonString("/tmp/another.txt")),
                    workspaceRoot = workspace,
                ),
                deferConsumption = false,
            )?.allowed == true,
        )
    }

    @Test
    fun oldRestoredPendingCannotCreateStandingGrantsForDestructiveOrUnknownEffects() {
        val clock = MutableClock(t0)
        val log = InMemoryAuthzEventLog()
        val store = BotGrantStore(now = { clock.value })
        val authzPrincipal = BotAuthzPrincipal(
            botId = "main",
            sessionId = "gb-task",
            kind = "task",
        )
        val destructive = BotToolEffect(
            tool = "bash",
            operation = "rm-destructive",
            resource = "/tmp/old-destructive",
            target = "/tmp/old-destructive",
            mutability = BotToolMutability.DESTRUCTIVE,
            policy = BotToolPolicy.ASK,
        )
        val unknown = BotToolEffect(
            tool = "phone",
            operation = "tool.unclassified",
            resource = "unclassified=phone&args=legacy",
            target = "phone",
            mutability = BotToolMutability.WRITE,
            policy = BotToolPolicy.ASK,
            known = false,
        )
        appendLegacyPending(log, authzPrincipal, "approval-old-destructive", destructive, clock.value)
        appendLegacyPending(log, authzPrincipal, "approval-old-unknown", unknown, clock.value)
        val coordinator = BotApprovalCoordinator(
            grants = store,
            eventLog = log,
            now = { clock.value },
            scheduler = ManualApprovalScheduler(clock),
        )
        coordinator.restoreDurable()
        assertEquals(
            listOf("approval-old-destructive", "approval-old-unknown"),
            coordinator.pendingIDs(),
        )
        assertEquals(
            BotApprovalResolution.Resolved,
            coordinator.resolve("approval-old-destructive", BotApprovalDecision.ALWAYS, digest),
        )
        assertEquals(
            BotApprovalResolution.Resolved,
            coordinator.resolve("approval-old-unknown", BotApprovalDecision.ALWAYS, digest),
        )
        val stored = store.list().sortedBy { it.resource }
        assertEquals(2, stored.size)
        assertTrue(
            "an old event's until scope must not survive on an ineligible effect",
            stored.all { it.scope == BotGrantScope.ONCE },
        )
        assertEquals(
            listOf("/tmp/old-destructive", "unclassified=phone&args=legacy"),
            stored.map { it.resource },
        )
        assertEquals(
            BotApprovalDurableStatus.ALLOWED,
            coordinator.durableStatus("approval-old-destructive"),
        )
    }

    @Test
    fun legacyMixedEffectsCannotLeaveAStandingGrant() {
        val clock = MutableClock(t0)
        val log = InMemoryAuthzEventLog()
        val store = BotGrantStore(now = { clock.value })
        val principal = BotAuthzPrincipal(botId = "main", sessionId = "gb-task", kind = "task")
        val destructive = BotToolEffect(
            tool = "bash", operation = "rm-destructive", resource = "/tmp/old",
            mutability = BotToolMutability.DESTRUCTIVE, policy = BotToolPolicy.ASK,
        )
        val network = BotToolEffect(
            tool = "egress", operation = "egress.post", resource = "host=a.example",
            mutability = BotToolMutability.EXTERNAL_SEND, policy = BotToolPolicy.ASK,
            grantResource = "host=a.example",
        )
        appendLegacyPending(log, principal, "approval-mixed", destructive, clock.value, listOf(network))
        val coordinator = BotApprovalCoordinator(
            grants = store, eventLog = log, now = { clock.value },
            scheduler = ManualApprovalScheduler(clock),
        )
        coordinator.restoreDurable()
        assertEquals(BotApprovalResolution.Resolved,
            coordinator.resolve("approval-mixed", BotApprovalDecision.ALWAYS, digest))
        val grants = store.list()
        assertEquals(2, grants.size)
        assertTrue("a mixed approval containing a destructive effect must remain one-shot",
            grants.all { it.scope == BotGrantScope.ONCE })
    }

    private class StartedApproval(
        val approvalId: String,
        private val thread: Thread,
        private val outcome: AtomicReference<BotApprovalOutcome>,
    ) {
        fun resolve(
            coordinator: BotApprovalCoordinator,
            digest: String,
            decision: BotApprovalDecision,
        ): BotApprovalOutcome {
            assertEquals(
                BotApprovalResolution.Resolved,
                coordinator.resolve(approvalId, decision, digest),
            )
            thread.join(2_000)
            assertFalse("the waiting request must return after a decision", thread.isAlive)
            return outcome.get() ?: error("the waiting request returned no outcome")
        }
    }

    private fun startInteractive(
        coordinator: BotApprovalCoordinator,
        call: BotResolvedToolCall,
        effects: List<BotToolEffect>,
        alwaysScope: String = "until",
    ): StartedApproval {
        val outcome = AtomicReference<BotApprovalOutcome>()
        val thread = Thread {
            outcome.set(
                coordinator.request(
                    call = call,
                    effects = effects,
                    action = "test action",
                    detail = "",
                    command = "",
                    alwaysScope = alwaysScope,
                ),
            )
        }
        thread.isDaemon = true
        thread.start()
        val deadline = System.nanoTime() + 2_000_000_000
        while (System.nanoTime() < deadline) {
            coordinator.pendingIDs().firstOrNull()?.let { id ->
                return StartedApproval(id, thread, outcome)
            }
            Thread.sleep(1)
        }
        thread.interrupt()
        error("approval never became pending")
    }

    private fun appendLegacyPending(
        log: InMemoryAuthzEventLog,
        principal: BotAuthzPrincipal,
        approvalId: String,
        effect: BotToolEffect,
        now: Long,
        additionalEffects: List<BotToolEffect> = emptyList(),
    ) {
        log.append(
            BotAuthzEvent(
                sequence = 0,
                type = "approval.requested",
                eventId = "requested:$approvalId",
                time = now,
                principal = principal,
                data = jsonObject(
                    "approvalID" to JsonString(approvalId),
                    "status" to JsonString("pending"),
                    "action" to JsonString("legacy pending"),
                    "detail" to JsonString(""),
                    "digest" to JsonString(digest),
                    "command" to JsonString(""),
                    // The old build offered until for every effect. Restore
                    // must not turn that stale offer into a standing grant.
                    "alwaysScope" to JsonString("until"),
                    "deferConsumption" to JsonBool(true),
                    "effects" to JsonArray((listOf(effect) + additionalEffects).map { it.toJson() }),
                    "persistent" to JsonBool(true),
                    "kind" to JsonString("task"),
                    "origin" to JsonString("structural"),
                    "requestedAt" to BotJson.number(now),
                    "expiresAt" to BotJson.number(now + 60_000),
                ),
            ),
        )
    }

    private companion object {
        const val BotAttributionRegistryTtl: Long = 330_000
    }
}
