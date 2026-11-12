// SPDX-License-Identifier: MIT
package com.phonedsh.bot.gateway

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.authz.BotArgumentsDigest
import com.phonedsh.bot.authz.MutableClock
import com.phonedsh.bot.session.BotSessionKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class BotIdentityRegistrationServiceTest {
    private val t0 = 1_760_000_000_000L

    @Test
    fun malformedDigestWithArgumentsIsTheFrozenDigestMismatch() {
        val clock = MutableClock(t0)
        val tokens = BotTokenRegistry(now = { clock.value })
        val identity = BotIdentityRegistrationService(
            tokens = tokens,
            attributions = BotAttributionRegistry(now = { clock.value }),
            now = { clock.value },
        )
        val issued = tokens.issueSession("main", "gb-main", BotSessionKind.CHAT)
        val result = identity.register(
            BotIdentityRegistrationRequest(
                runtimeId = BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                sessionId = "gb-main",
                callId = "call-1",
                name = "ListRoutines",
                arguments = JsonObject(emptyMap()),
                argsDigest = BotArgumentsDigest.string().uppercase(),
                sessionToken = issued.token,
            ),
        )
        assertEquals(false, result.ok)
        assertEquals("argument digest mismatch", result.error)
    }

    @Test
    fun bodyParserRequiresTheHandlerGuardMembers() {
        val body = com.phonedsh.agentcore.JsonValue.parse(
            """{"runtimeId":"phone-worker","sessionId":"gb-main","callId":"call-1","name":"ListRoutines"}""",
        ) as JsonObject
        val parsed = BotIdentityRegistrationRequest.fromJson(body)
        assertNotNull(parsed)
        assertEquals(false, parsed!!.argumentsProvided)
        val missingName = com.phonedsh.agentcore.JsonObject(
            linkedMapOf(
                "runtimeId" to com.phonedsh.agentcore.JsonString("phone-worker"),
                "sessionId" to com.phonedsh.agentcore.JsonString("gb-main"),
                "callId" to com.phonedsh.agentcore.JsonString("call-1"),
            ),
        )
        assertNull(BotIdentityRegistrationRequest.fromJson(missingName))
    }

    @Test
    fun workerRestartAdvancesTheGenerationAndRemovesOldRegistrations() {
        val clock = MutableClock(t0)
        val tokens = BotTokenRegistry(now = { clock.value })
        val attributions = BotAttributionRegistry(now = { clock.value })
        val identity = BotIdentityRegistrationService(
            tokens = tokens,
            attributions = attributions,
            now = { clock.value },
        )
        val issued = tokens.issueSession("main", "gb-main", BotSessionKind.CHAT)
        val registered = identity.register(
            BotIdentityRegistrationRequest(
                runtimeId = BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                sessionId = "gb-main",
                callId = "call-1",
                name = "ListRoutines",
                arguments = JsonObject(emptyMap()),
                argsDigest = BotArgumentsDigest.string(),
                sessionToken = issued.token,
            ),
        )
        assertEquals(true, registered.ok)
        assertNotNull(
            identity.resolve(
                BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                "gb-main",
                "call-1",
            ),
        )
        assertEquals("phone-worker@0", identity.scopedRuntimeId())
        identity.workerRestarted()
        assertEquals("phone-worker@1", identity.scopedRuntimeId())
        assertEquals(0, identity.registrationCount())
        assertNull(
            identity.resolve(
                BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                "gb-main",
                "call-1",
            ),
        )
        assertEquals(0, attributions.pendingCount("phone-worker@0"))
    }
}
