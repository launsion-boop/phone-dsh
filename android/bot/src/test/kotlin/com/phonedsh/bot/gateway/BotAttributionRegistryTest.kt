// SPDX-License-Identifier: MIT
package com.phonedsh.bot.gateway

import com.phonedsh.bot.authz.BotApprovalCoordinator
import com.phonedsh.bot.authz.BotArgumentsDigest
import com.phonedsh.bot.authz.MutableClock
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class BotAttributionRegistryTest {
    private val t0 = 1_760_000_000_000L

    @Test
    fun ttlIsTheApprovalTimeoutPlusThirtySeconds() {
        assertEquals(
            BotApprovalCoordinator.DEFAULT_TIMEOUT_MILLISECONDS + 30_000,
            BotAttributionRegistry.DEFAULT_TTL_MILLISECONDS,
        )
        assertEquals(4_096, BotAttributionRegistry.DEFAULT_MAXIMUM_ENTRIES)
    }

    @Test
    fun registerBindTheFrozenTupleAndPruneExpiredEntries() {
        val clock = MutableClock(t0)
        val registry = BotAttributionRegistry(now = { clock.value })
        val entry = registry.register(
            sessionId = "gb-main",
            incarnation = "a".repeat(32),
            callId = "call-1",
            name = "ListRoutines",
            arguments = com.phonedsh.agentcore.JsonObject(emptyMap()),
            runtimeId = "phone-worker@0",
        )
        assertEquals(32, entry.id.length)
        assertEquals(BotArgumentsDigest.string(), entry.argsDigest)
        assertEquals(t0 + BotAttributionRegistry.DEFAULT_TTL_MILLISECONDS, entry.expiresAt)
        assertEquals(listOf(entry), registry.entriesFor("phone-worker@0", "call-1", "gb-main"))
        clock.value = entry.expiresAt
        assertEquals(1, registry.prune())
        assertNull(registry.get(entry.id))
    }

    @Test
    fun duplicateRuleAndClaimAreExact() {
        val registry = BotAttributionRegistry(now = { t0 })
        val arguments = com.phonedsh.agentcore.JsonObject(
            linkedMapOf("path" to com.phonedsh.agentcore.JsonString("a.txt")),
        )
        val entry = registry.register(
            "gb-main", "b".repeat(32), "call-1", "write", arguments,
        )
        try {
            registry.register("gb-main", "b".repeat(32), "call-2", "write", arguments)
            fail("the same tuple must be duplicate")
        } catch (error: BotAttributionException) {
            assertEquals("duplicate", error.code)
        }
        assertNull(registry.claim("gb-main", "write", com.phonedsh.agentcore.JsonObject(emptyMap())))
        assertEquals(
            entry,
            registry.claim("gb-main", "write", arguments),
        )
        assertNull(registry.get(entry.id))
    }

    @Test
    fun refreshOnlyExtendsAndCancellationIsGenerationScoped() {
        val clock = MutableClock(t0)
        val registry = BotAttributionRegistry(now = { clock.value })
        val first = registry.register(
            "gb-main", "c".repeat(32), "call-1", "write",
            runtimeId = "phone-worker@0",
        )
        clock.value = t0 + 1_000
        val refreshed = registry.refresh(first.id)!!
        assertTrue(refreshed.expiresAt > first.expiresAt)
        assertNull(registry.refresh("missing"))

        val second = registry.register(
            "gb-main", "d".repeat(32), "call-2", "write",
            runtimeId = "phone-worker@1",
        )
        assertEquals(1, registry.cancelRuntime("phone-worker@0"))
        assertNull(registry.get(first.id))
        assertNotNull(registry.get(second.id))
        assertEquals(0, registry.revokeStale("gb-main", "d".repeat(32)))
        assertNotNull(registry.get(second.id))
    }

    @Test
    fun capacityIsEnforced() {
        val registry = BotAttributionRegistry(now = { t0 }, maximumEntries = 1)
        registry.register("gb-a", "a".repeat(32), "call", "write")
        try {
            registry.register("gb-b", "b".repeat(32), "call", "write")
            fail("the registry must reject the second entry")
        } catch (error: BotAttributionException) {
            assertEquals("full", error.code)
        }
    }
}
