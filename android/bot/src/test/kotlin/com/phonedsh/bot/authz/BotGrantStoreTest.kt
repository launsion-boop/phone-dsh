// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class BotGrantStoreTest {
    private val t0 = 1_760_000_000_000L
    private val effect = BotToolEffect(
        tool = "write",
        operation = "file.write",
        resource = "dir=/tmp/shared",
        mutability = BotToolMutability.WRITE,
        policy = BotToolPolicy.ASK,
    )
    private val principal = BotExecutionPrincipal(
        botId = "main",
        sessionId = "gb-main",
        sessionKind = com.phonedsh.bot.session.BotSessionKind.CHAT,
    )

    @Test
    fun addFindExtendConsumeAndRevokeUseCanonicalResources() {
        val clock = MutableClock(t0)
        val store = BotGrantStore(now = { clock.value })
        store.recover()
        val grant = store.add(
            BotGrant(
                botId = "main",
                tool = "write",
                operation = "file.write",
                resource = "dir=/tmp/shared",
                scope = BotGrantScope.ONCE,
                sessionId = "gb-main",
                decision = BotGrantDecision.ALLOW,
            ),
        )
        assertEquals("dir=/tmp/shared", grant.resource)
        assertEquals("/tmp/shared", BotResourceNormalizer.normalize("/tmp/shared/../shared"))
        assertEquals(grant.id, store.find("main", "gb-main", effect)?.id)
        assertNull(store.find("other", "gb-main", effect))

        val extended = store.add(
            grant.copy(
                resource = "dir=/tmp/shared",
                expiresAt = t0 + BotGrantStore.ONCE_TTL_MILLISECONDS + 10_000,
            ),
        )
        assertEquals(grant.id, extended.id)
        assertEquals(1, store.list("main").size)

        assertTrue(store.consumeOnceAtomically(listOf(grant.id)))
        assertFalse("a consumed once grant is gone", store.consumeOnceAtomically(listOf(grant.id)))
        assertNull(store.find("main", "gb-main", effect))
    }

    @Test
    fun sessionScopeRequiresTheSameSessionAndDenyWinsAtEqualSpecificity() {
        val store = BotGrantStore(now = { t0 })
        store.recover()
        store.add(
            BotGrant(
                botId = "main", tool = "write", operation = "file.write",
                resource = "dir=/tmp/shared", scope = BotGrantScope.SESSION,
                sessionId = "gb-main", decision = BotGrantDecision.ALLOW,
            ),
        )
        assertNotNull(store.find("main", "gb-main", effect))
        assertNull(store.find("main", "gb-task", effect))
        store.add(
            BotGrant(
                botId = "main", tool = "write", operation = "file.write",
                resource = "dir=/tmp/shared", scope = BotGrantScope.UNTIL,
                decision = BotGrantDecision.DENY,
            ),
        )
        assertEquals(BotGrantDecision.DENY, store.find("main", "gb-main", effect)?.decision)
        assertEquals(1, store.revokeSession("gb-main"))
        assertEquals(
            "the until deny is not a session grant",
            BotGrantDecision.DENY,
            store.find("main", "gb-main", effect)?.decision,
        )
    }

    @Test
    fun snapshotRoundTripsTheElevenFrozenMembersAndRejectsUnknownOnes() {
        val store = BotGrantStore(now = { t0 })
        store.recover()
        val grant = store.add(
            BotGrant(
                botId = "main", tool = "bash", operation = "rm-destructive",
                resource = "rm -rf build", scope = BotGrantScope.UNTIL,
                decision = BotGrantDecision.ALLOW, createdAt = t0,
            ),
        )
        val data = BotGrantSnapshot.encode(listOf(grant))
        assertEquals(setOf("grants"), data.members.keys)
        val entry = ((data.members["grants"] as com.phonedsh.agentcore.JsonArray).values.single()
            as JsonObject).members
        assertEquals(
            setOf(
                "grantId", "botId", "tool", "operation", "canonicalResource", "scope",
                "sessionId", "expiresAt", "createdAt", "source", "decision",
            ),
            entry.keys,
        )
        assertEquals(JsonValue.parse("null"), entry["sessionId"])
        assertEquals(BotJson.number(grant.expiresAt!!), entry["expiresAt"])
        val nullExpiry = BotGrantSnapshot.encode(listOf(grant.copy(expiresAt = null)))
        val nullEntry = ((nullExpiry.members["grants"] as com.phonedsh.agentcore.JsonArray)
            .values.single() as JsonObject).members
        assertEquals(JsonValue.parse("null"), nullEntry["expiresAt"])
        val decoded = BotGrantSnapshot.decode(data, t0)
        assertEquals(listOf(grant), decoded)

        val tampered = JsonObject(
            linkedMapOf(
                "grants" to com.phonedsh.agentcore.JsonArray(
                    listOf(
                        JsonObject(entry + ("unknown" to JsonString("x"))),
                    ),
                ),
            ),
        )
        try {
            BotGrantSnapshot.decode(tampered, t0)
            fail("unknown snapshot member must be rejected")
        } catch (error: BotGrantRecoveryException) {
            assertEquals(BotGrantRecoveryReason.INVALID_SNAPSHOT, error.reason)
        }
    }

    @Test
    fun recoveryUsesTheLatestSnapshotAndDropsExpiredEntries() {
        val clock = MutableClock(t0)
        val log = InMemoryAuthzEventLog()
        val first = BotGrantStore(log, { clock.value })
        first.recover()
        val grant = first.add(
            BotGrant(
                botId = "main", tool = "write", operation = "file.write",
                resource = "dir=/tmp/shared", scope = BotGrantScope.UNTIL,
                decision = BotGrantDecision.ALLOW,
            ),
        )
        val recovered = BotGrantStore(log, { clock.value })
        recovered.recover()
        assertEquals(grant, recovered.find("main", null, effect))

        clock.value = t0 + BotGrantStore.UNTIL_TTL_MILLISECONDS + 1
        val pruned = BotGrantStore(log, { clock.value })
        pruned.recover()
        assertTrue(pruned.list().isEmpty())
    }

    @Test
    fun missingSnapshotAndEmptyLogFollowTheFrozenRecoverySemantics() {
        val emptyLog = InMemoryAuthzEventLog()
        val empty = BotGrantStore(emptyLog, { t0 })
        empty.recover()
        assertEquals(BotGrantSnapshot.EVENT_TYPE, emptyLog.all().single().type)

        val unrelated = InMemoryAuthzEventLog()
        unrelated.append(
            BotAuthzEvent(
                sequence = 0, type = "approval.requested", eventId = "e1", time = t0,
                principal = null, data = JsonObject(emptyMap()),
            ),
        )
        val broken = BotGrantStore(unrelated, { t0 })
        try {
            broken.recover()
            fail("events without a snapshot must fail closed")
        } catch (error: BotGrantRecoveryException) {
            assertEquals(BotGrantRecoveryReason.MISSING_SNAPSHOT, error.reason)
        }
    }

    @Test
    fun authorizerConsumesOnceOnlyAfterAllAskEffectsMatch() {
        val clock = MutableClock(t0)
        val store = BotGrantStore(now = { clock.value })
        store.recover()
        val before = store.add(
            BotGrant(
                botId = "main", tool = "write", operation = "file.write",
                resource = "dir=/tmp/shared", scope = BotGrantScope.ONCE,
                sessionId = "gb-main", decision = BotGrantDecision.ALLOW,
            ),
        )
        val authorizer = BotExecutionAuthorizer(store, BotInMemoryAuditRecorder())
        val allowed = authorizer.authorizeExecution(principal, listOf(effect))
        assertTrue(allowed.allowed)
        assertEquals("grant matched", allowed.reason)
        assertNull(store.list().firstOrNull { it.id == before.id })

        val denied = authorizer.authorizeExecution(principal, listOf(effect))
        assertFalse(denied.allowed)
        assertEquals("missing-grant", denied.reason)
    }

    @Test
    fun authorizerFailsClosedForInvalidAttributionAndEffect() {
        val authorizer = BotExecutionAuthorizer(BotGrantStore())
        val unknown = authorizer.authorizeExecution(
            BotExecutionPrincipal(null, kind = BotExecutionPrincipalKind.UNKNOWN, certain = false),
            listOf(effect),
        )
        assertFalse(unknown.allowed)
        assertEquals("unattributed", unknown.reason)
        val empty = authorizer.authorizeExecution(principal, emptyList())
        assertFalse(empty.allowed)
        assertEquals("empty-effects", empty.reason)
        val invalid = authorizer.authorizeExecution(principal, listOf(effect.copy(resource = " ")))
        assertFalse(invalid.allowed)
        assertEquals("invalid-effect", invalid.reason)
    }
}
