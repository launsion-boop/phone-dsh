// SPDX-License-Identifier: MIT
package com.phonedsh.bot.gateway

import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.authz.MutableClock
import com.phonedsh.bot.session.BotSessionKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class BotTokenRegistryTest {
    private val t0 = 1_760_000_000_000L

    @Test
    fun credentialContractMatchesTheSharedFixture() {
        val fixture = GoldenFixture.rawObject("identity-approval-cases.phone")
        val contract = GoldenFixture.objectValue(fixture, "credentialContract")
        val prefix = GoldenFixture.requireString(contract, "tokenPrefix")
        val length = GoldenFixture.requireLong(contract, "tokenLength").toInt()
        val alphabet = GoldenFixture.requireString(contract, "tokenURLSafeAlphabet").toSet()
        val incarnationLength = GoldenFixture.requireLong(contract, "incarnationHexLength").toInt()
        val ttl = GoldenFixture.requireLong(contract, "defaultTTLMilliseconds")
        val maximum = GoldenFixture.requireLong(contract, "maximumTokens").toInt()
        assertEquals(BotTokenRegistry.DEFAULT_TTL_MILLISECONDS, ttl)
        assertEquals(BotTokenRegistry.DEFAULT_MAXIMUM_TOKENS, maximum)

        val registry = BotTokenRegistry(now = { t0 })
        val issued = registry.issue(
            botId = "main", sessionId = "gb-main", kind = BotSessionKind.CHAT,
        )
        assertEquals(length, issued.token.length)
        assertTrue(issued.token.startsWith(prefix))
        assertTrue(issued.token.drop(prefix.length).all { it in alphabet })
        assertEquals(incarnationLength, issued.principal.incarnation.length)
        assertTrue(issued.principal.incarnation.all { it in '0'..'9' || it in 'a'..'f' })
        assertEquals(t0 + ttl, issued.principal.expiresAt)
        assertEquals(issued.principal, registry.lookup(issued.token))
        assertNull("token bytes are case-sensitive", registry.lookup(issued.token.uppercase()))
    }

    @Test
    fun issueSessionRevokesThePreviousIncarnationButIssueDoesNot() {
        val registry = BotTokenRegistry(now = { t0 })
        val first = registry.issueSession("main", "gb-main", BotSessionKind.CHAT)
        val second = registry.issueSession("main", "gb-main", BotSessionKind.CHAT)
        assertNull(registry.lookup(first.token))
        assertEquals(second.principal, registry.lookup(second.token))
        assertNotEquals(first.principal.incarnation, second.principal.incarnation)

        val looseFirst = registry.issue("main", "gb-other", BotSessionKind.CHAT)
        val looseSecond = registry.issue("main", "gb-other", BotSessionKind.CHAT)
        assertNotNull(registry.lookup(looseFirst.token))
        assertEquals(looseSecond.principal, registry.lookupSession("gb-other"))
    }

    @Test
    fun rotateReducesTheOldTokenAndPreservesTheExactExpiry() {
        val registry = BotTokenRegistry(now = { t0 })
        val issued = registry.issue("main", "gb-main", BotSessionKind.CHAT)
        val rotated = registry.rotate(issued.token)!!
        assertNull(registry.lookup(issued.token))
        assertEquals(rotated.principal, registry.lookup(rotated.token))
        assertEquals(issued.principal.expiresAt, rotated.principal.expiresAt)
        assertNotEquals(issued.principal.incarnation, rotated.principal.incarnation)
        assertNull(registry.rotate("dshg_missing"))
    }

    @Test
    fun revokeSessionRevokeBotAndPruneInvalidateTheCurrentIncarnation() {
        val clock = MutableClock(t0)
        val registry = BotTokenRegistry(now = { clock.value })
        val a = registry.issueSession("bot-a", "gb-a", BotSessionKind.CHAT)
        val b = registry.issueSession("bot-a", "gb-b", BotSessionKind.TASK)
        val c = registry.issueSession("bot-b", "gb-c", BotSessionKind.CHAT)
        assertEquals(3, registry.activeSessionIds().size)
        assertEquals(1, registry.revokeSession("gb-a"))
        assertNull(registry.lookup(a.token))
        assertEquals(1, registry.revokeBot("bot-a"))
        assertNull(registry.lookup(b.token))
        assertEquals(setOf("gb-c"), registry.activeSessionIds())
        assertEquals(1, registry.revokeBot("bot-b"))
        assertNull(registry.lookup(c.token))
        assertTrue(registry.activePrincipals().isEmpty())

        val expiring = registry.issue("main", "gb-exp", BotSessionKind.CHAT, ttlMilliseconds = 50)
        clock.value = t0 + 51
        assertEquals(1, registry.prune())
        assertNull(registry.lookup(expiring.token))
    }

    @Test
    fun lookupBearerAcceptsExactlyOneCaseInsensitiveSchemeAndOneToken() {
        val registry = BotTokenRegistry(now = { t0 })
        val issued = registry.issue("main", "gb-main", BotSessionKind.CHAT)
        assertEquals(issued.principal, registry.lookupBearer("Bearer ${issued.token}"))
        assertEquals(issued.principal, registry.lookupBearer("bearer   ${issued.token}"))
        assertNull(registry.lookupBearer("Token ${issued.token}"))
        assertNull(registry.lookupBearer("Bearer"))
        assertNull(registry.lookupBearer("Bearer ${issued.token} extra"))
    }

    @Test
    fun capacityIsEnforcedAfterPruning() {
        val registry = BotTokenRegistry(now = { t0 }, maximumTokens = 1)
        registry.issue("main", "gb-a", BotSessionKind.CHAT)
        try {
            registry.issue("main", "gb-b", BotSessionKind.CHAT)
            fail("the registry must reject a second live token")
        } catch (error: BotTokenRegistryException) {
            assertEquals("registryFull", error.code)
        }
    }

    @Test
    fun fixtureTokensResolveToTheSeededPrincipal() {
        val registry = BotTokenRegistry(now = { t0 })
        registry.seedForFixture(
            token = "dshg_wpf0_fixture_main",
            botId = "main",
            sessionId = "gb-main",
            kind = BotSessionKind.CHAT,
            expiresAt = t0 + BotTokenRegistry.DEFAULT_TTL_MILLISECONDS,
        )
        val principal = registry.lookup("dshg_wpf0_fixture_main")
        assertEquals("gb-main", principal?.sessionId)
        assertEquals("main", principal?.botId)
        assertEquals(principal, registry.lookupSession("gb-main"))
    }
}
