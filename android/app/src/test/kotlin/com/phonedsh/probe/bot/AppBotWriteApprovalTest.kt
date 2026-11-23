// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.authz.BotApprovalCoordinator
import com.phonedsh.bot.authz.BotApprovalDecision
import com.phonedsh.bot.authz.BotGrantStore
import com.phonedsh.bot.gateway.BotAttributionRegistry
import com.phonedsh.bot.gateway.BotIdentityRegistrationRequest
import com.phonedsh.bot.gateway.BotIdentityRegistrationService
import com.phonedsh.bot.session.BotSessionKind
import com.phonedsh.bot.session.BotSessionTokenRegistry
import com.phonedsh.gateway.GatewayUrls
import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class AppBotWriteApprovalTest {
    @Test fun taskSubsetAppliesBeforeTheCardOrAnyGrant() {
        val fixtures = JSONObject(File(System.getProperty("pdsh.repo.root"),
            "spec/bot/v1/golden/mcp-egress.phone.json").readText())
        var checked = 0
        for (group in listOf("valid", "invalid")) {
            val cases = fixtures.getJSONArray(group)
            for (i in 0 until cases.length()) {
                val case = cases.getJSONObject(i)
                if (case.optString("boundary") !in setOf("task-network-write", "chat-unaffected")) continue
                checked++
                val input = case.getJSONObject("request")
                val expected = case.getJSONObject("expect")
                val registry = BotSessionTokenRegistry()
                val tokens = AppBotSessionPrincipals(registry)
                val identity = BotIdentityRegistrationService(tokens, BotAttributionRegistry())
                val approvals = BotApprovalCoordinator(BotGrantStore())
                val actor = AppBotWriteApproval(identity, tokens, approvals, System::currentTimeMillis)
                val caps = input.getJSONArray("capabilities")
                val issued = registry.issueSession("main", "session", BotSessionKind.fromWire(input.getString("sessionKind")),
                    (0 until caps.length()).map(caps::getString))
                repeat(input.getInt("activeBashCalls")) {
                    assertTrue(identity.register(BotIdentityRegistrationRequest(identity.runtimeId, "session", "call-$it", "bash",
                        JsonObject(mapOf("command" to JsonString("fixture"))), sessionToken = issued.token)).ok)
                }
                val url = checkNotNull(GatewayUrls.parse(input.getString("url")))
                val method = input.getString("method")
                val first = actor.check(method, url, false)
                assertEquals(case.getString("name"), expected.getInt("approvalRequests"), approvals.pendingIDs().size)
                if (expected.getString("decision") == "allow") {
                    assertNotNull(first)
                    val pending = approvals.pendingIDs().single()
                    approvals.resolve(pending, BotApprovalDecision.ALLOW_ONCE, approvals.pendingDigest(pending)!!)
                    assertNull(actor.check(method, url, false))
                } else assertEquals(expected.getString("error"), first?.code?.wire)
            }
        }
        assertTrue(checked >= 3)
    }
}
