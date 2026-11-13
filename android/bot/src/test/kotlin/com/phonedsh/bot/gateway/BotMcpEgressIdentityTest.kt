// SPDX-License-Identifier: MIT
package com.phonedsh.bot.gateway

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.authz.BotArgumentsDigest
import com.phonedsh.bot.authz.BotGrantStore
import com.phonedsh.bot.authz.InMemoryAuthzEventLog
import com.phonedsh.bot.authz.MutableClock
import com.phonedsh.bot.session.BotSessionKind
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The `identity` suite of `mcp-egress.phone`: the fixed fixture registry is
 * seeded into the real token registry and every request runs through the real
 * identity registration service. This is the credential half of the egress
 * vector; the HTTP header suite belongs to B5b, not this pure-JVM lane.
 */
class BotMcpEgressIdentityTest {
    private val t0 = 1_760_000_000_000L

    @Test
    fun identityValidAndInvalidCasesMatchTheFixture() {
        val fixture = GoldenFixture.rawObject("mcp-egress.phone")
        val cases = GoldenFixture.objects(fixture, "valid")
            .filter { GoldenFixture.string(it, "suite") == "identity" } +
            GoldenFixture.objects(fixture, "invalid")
                .filter { GoldenFixture.string(it, "suite") == "identity" }
        assertEquals(13, cases.size)
        var validated = 0
        for (case in cases) {
            val label = GoldenFixture.requireString(case, "name")
            val clock = MutableClock(t0)
            val tokens = BotTokenRegistry(now = { clock.value })
            for (entry in GoldenFixture.objects(case, "registry")) {
                val token = GoldenFixture.requireString(entry, "token")
                val sessionId = GoldenFixture.requireString(entry, "sessionId")
                val expired = GoldenFixture.bool(entry, "expired") == true
                val revoked = GoldenFixture.bool(entry, "revoked") == true
                tokens.seedForFixture(
                    token = token,
                    botId = "main",
                    sessionId = sessionId,
                    kind = BotSessionKind.CHAT,
                    expiresAt = if (expired) t0 - 1 else t0 + BotTokenRegistry.DEFAULT_TTL_MILLISECONDS,
                )
                if (revoked) tokens.revoke(token)
            }
            val request = GoldenFixture.objectValue(case, "request")
            val sessionId = GoldenFixture.requireString(request, "sessionId")
            val supplied = GoldenFixture.string(request, "sessionToken")
            val identity = BotIdentityRegistrationService(
                tokens = tokens,
                attributions = BotAttributionRegistry(now = { clock.value }),
                approvals = null,
                now = { clock.value },
            )
            val result = identity.register(
                BotIdentityRegistrationRequest(
                    runtimeId = BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                    sessionId = sessionId,
                    callId = "mcp-egress-identity",
                    name = "ListRoutines",
                    arguments = JsonObject(emptyMap()),
                    argsDigest = BotArgumentsDigest.string(),
                    sessionToken = supplied,
                ),
            )
            val expect = GoldenFixture.objectValue(case, "expect")
            for ((key, value) in expect.members) {
                val actual = result.toJson().members[key]
                assertEquals("$label: $key", value, actual)
            }
            validated++
        }
        assertEquals(13, validated)
    }

    @Test
    fun missingAndEmptyCredentialsNeverFallBackToBodySession() {
        val clock = MutableClock(t0)
        val tokens = BotTokenRegistry(now = { clock.value })
        tokens.seedForFixture(
            "dshg_wpf0_fixture_main", "main", "gb-main", BotSessionKind.CHAT,
            expiresAt = t0 + 1_000,
        )
        val identity = BotIdentityRegistrationService(
            tokens = tokens,
            attributions = BotAttributionRegistry(now = { clock.value }),
            approvals = null,
            now = { clock.value },
        )
        for (token in listOf(null, "")) {
            val result = identity.register(
                BotIdentityRegistrationRequest(
                    runtimeId = BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                    sessionId = "gb-main",
                    callId = "call",
                    name = "ListRoutines",
                    sessionToken = token,
                ),
            )
            assertEquals(false, result.ok)
            assertEquals("unauthorized", result.error)
        }
    }
}
