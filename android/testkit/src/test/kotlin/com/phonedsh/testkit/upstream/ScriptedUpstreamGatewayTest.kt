// :testkit upstream — the scripted model upstream, reached through the REAL :net gateway.
// SPDX-License-Identifier: MIT
//
// ---- what these tests prove -------------------------------------------------
// The gateway's 28 security vectors use a scripted TRANSPORT: they prove policy,
// not sockets. These tests are the complement: the scripted model upstream is a
// real HTTP server on a real loopback port, and the request that reaches it went
// through the real `GatewaySession` (`:net`), not a fake. What is asserted:
//
//   * the first model request is answered with a tool call for `phone info`;
//   * the second request — the one whose transcript carries the tool result —
//     is answered with the final assistant text;
//   * the allow-list entry is one exact origin, and a different port is denied
//     before any contact (no loosening);
//   * the caller's `authorization` never reaches the scripted upstream (the
//     anonymous credential path of gateway-security.md §2/§3).
//
// The model is still a SCRIPT. This test does not claim a model ran; it claims
// the transport, the egress decision and the response parsing are real.

package com.phonedsh.testkit.upstream

import com.phonedsh.gateway.AllowListEgressPolicy
import com.phonedsh.gateway.CredentialScope
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GatewayDispatch
import com.phonedsh.gateway.GatewayFailureCode
import com.phonedsh.gateway.GatewayHostRule
import com.phonedsh.gateway.GatewayRequest
import com.phonedsh.gateway.GatewaySession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScriptedUpstreamGatewayTest {
    @Test
    fun theFirstRequestGetsAToolCallAndTheSecondWithItsResultGetsTheFinalText() {
        val upstream = ScriptedModelUpstream().start()
        try {
            val gateway = gatewayTo(upstream.port)
            val first = gateway.exchange(
                GatewayRequest(
                    method = "POST",
                    url = "${upstream.baseUrl}${upstream.chatCompletionsPath}",
                    headers = mapOf("content-type" to "application/json"),
                    body = requestBody(openAiTranscript(toolResult = false)),
                ),
            )
            assertEquals("the allowed origin must be dispatched", GatewayDispatch.ALLOW, first.dispatch)
            assertEquals(200, first.responseStatus)
            assertEquals(1, first.upstreamContacts)
            val firstBody = String(first.responseBody, Charsets.UTF_8)
            assertTrue(firstBody, firstBody.contains("\"tool_calls\""))
            assertTrue(firstBody, firstBody.contains("\"name\":\"bash\""))
            assertTrue(firstBody, firstBody.contains("phone info"))
            assertEquals("tool_calls", finishReason(firstBody))

            // The second request carries the tool result: the script answers text.
            val second = gateway.exchange(
                GatewayRequest(
                    method = "POST",
                    url = "${upstream.baseUrl}${upstream.chatCompletionsPath}",
                    headers = mapOf("content-type" to "application/json"),
                    body = requestBody(openAiTranscript(toolResult = true)),
                ),
            )
            assertEquals(200, second.responseStatus)
            val secondBody = String(second.responseBody, Charsets.UTF_8)
            assertTrue(secondBody, secondBody.contains(ScriptedModelScript().finalText))
            assertEquals("stop", finishReason(secondBody))
            assertFalse(secondBody, secondBody.contains("\"tool_calls\""))

            val received = upstream.requests
            assertEquals("one request per assistant turn", 2, received.size)
            assertTrue("the first request carries no tool result", !received[0].carriesToolResult)
            assertTrue("the second request carries the tool result", received[1].carriesToolResult)
            assertFalse(
                "the anonymous credential path injects no Authorization",
                received.any { it.hasAuthorization },
            )
        } finally {
            upstream.stop()
        }
    }

    @Test
    fun theMessagesWireFormatFollowsTheSameScript() {
        val upstream = ScriptedModelUpstream().start()
        try {
            val gateway = gatewayTo(upstream.port)
            val toolTurn = gateway.exchange(
                GatewayRequest(
                    method = "POST",
                    url = "${upstream.baseUrl}${upstream.messagesPath}",
                    headers = mapOf("content-type" to "application/json"),
                    body = requestBody(messagesTranscript(toolResult = false)),
                ),
            )
            assertEquals(200, toolTurn.responseStatus)
            val toolBody = String(toolTurn.responseBody, Charsets.UTF_8)
            assertTrue(toolBody, toolBody.contains("event: message_start"))
            assertTrue(toolBody, toolBody.contains("\"type\":\"tool_use\""))
            assertTrue(toolBody, toolBody.contains("\"stop_reason\":\"tool_use\""))
            assertTrue(toolBody, toolBody.contains("phone info"))

            val finalTurn = gateway.exchange(
                GatewayRequest(
                    method = "POST",
                    url = "${upstream.baseUrl}${upstream.messagesPath}",
                    headers = mapOf("content-type" to "application/json"),
                    body = requestBody(messagesTranscript(toolResult = true)),
                ),
            )
            val finalBody = String(finalTurn.responseBody, Charsets.UTF_8)
            assertTrue(finalBody, finalBody.contains("event: message_stop"))
            assertTrue(finalBody, finalBody.contains("\"stop_reason\":\"end_turn\""))
            assertTrue(finalBody, finalBody.contains(ScriptedModelScript().finalText))
        } finally {
            upstream.stop()
        }
    }

    @Test
    fun aWorkerSuppliedAuthorizationIsStrippedBeforeTheUpstreamSeesIt() {
        val upstream = ScriptedModelUpstream().start()
        try {
            val gateway = gatewayTo(upstream.port)
            val outcome = gateway.exchange(
                GatewayRequest(
                    method = "POST",
                    url = "${upstream.baseUrl}${upstream.chatCompletionsPath}",
                    headers = mapOf(
                        "content-type" to "application/json",
                        "authorization" to "Bearer worker-forged-key",
                        "cookie" to "pdsh-dsh-session=loopback-cookie",
                        "x-pdsh-internal" to "1",
                    ),
                    body = requestBody(openAiTranscript(toolResult = false)),
                ),
            )
            assertEquals(200, outcome.responseStatus)
            assertTrue(outcome.stripped.contains("authorization"))
            assertTrue(outcome.stripped.contains("cookie"))
            assertEquals(1, outcome.workerCredentialsDropped)
            val received = upstream.requests.single()
            assertFalse(received.hasAuthorization)
            assertFalse(received.headers.containsKey("cookie"))
            assertFalse(received.headers.containsKey("x-pdsh-internal"))
            assertEquals("a caller header outside the denylist survives", "application/json", received.headers["content-type"])
        } finally {
            upstream.stop()
        }
    }

    @Test
    fun anAllowListEntryForAnotherPortDeniesBeforeAnyContact() {
        val upstream = ScriptedModelUpstream().start()
        try {
            // The grant names an origin nobody bound; the upstream's own port is not
            // in the list, so the same host:port rule that admits nothing here must
            // deny before a socket is opened.
            val gateway = gatewayTo(upstream.port + 1)
            val outcome = gateway.exchange(
                GatewayRequest(
                    method = "POST",
                    url = "${upstream.baseUrl}${upstream.chatCompletionsPath}",
                    headers = mapOf("content-type" to "application/json"),
                    body = requestBody(openAiTranscript(toolResult = false)),
                ),
            )
            assertEquals(GatewayDispatch.DENY, outcome.dispatch)
            assertNotNull(outcome.failure)
            assertEquals(GatewayFailureCode.HOST_NOT_ALLOWED, outcome.failure?.code)
            assertEquals("a pre-flight deny sends nothing", 0, outcome.upstreamContacts)
            assertTrue("the upstream never heard of it", upstream.requests.isEmpty())
            assertEquals("", outcome.outboundUrl)
        } finally {
            upstream.stop()
        }
    }

    // ------------------------------------------------------------------ setup

    private fun gatewayTo(port: Int): GatewaySession {
        val rule = GatewayHostRule.parse("http://127.0.0.1:$port")
            ?: throw IllegalStateException("the test grant must parse")
        val provider = object : GatewayCredentialProvider {
            override fun resolve(scope: CredentialScope): GatewayCredential = GatewayCredential.None
        }
        return GatewaySession(
            transport = UrlConnectionGatewayTransport(),
            credentialProvider = provider,
            egress = AllowListEgressPolicy(listOf(rule)),
        )
    }

    /** One OpenAI chat request; the transcript shape is what selects the script branch. */
    private fun openAiTranscript(toolResult: Boolean): String {
        val messages = StringBuilder()
        messages.append("""{"role":"user","content":"run the phone info tool"}""")
        if (toolResult) {
            messages.append(""",""").append("""{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","""")
                .append(""""type":"function","function":{"name":"bash","arguments":"""")
                .append(""""{\\"command\\":\\"phone info\\"}"}}]}""")
            messages.append(""",""").append(
                """{"role":"tool","tool_call_id":"call_1","content":"{\\"sdk\\":35,\\"model\\":\\"sdk_gphone\\"}"}""",
            )
        }
        return """{"model":"deepseek-flash","stream":false,"messages":[$messages]}"""
    }

    /** The Messages-wire transcript; a `tool_result` block selects the final branch. */
    private fun messagesTranscript(toolResult: Boolean): String {
        val messages = StringBuilder()
        messages.append("""{"role":"user","content":[{"type":"text","text":"run the phone info tool"}]}""")
        if (toolResult) {
            messages.append(""",""").append(
                """{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1",""" +
                    """"name":"bash","input":{"command":"phone info"}}]}""",
            )
            messages.append(""",""").append(
                """{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1",""" +
                    """"content":[{"type":"text","text":"{\\"sdk\\":35}"}]}]}""",
            )
        }
        return """{"model":"deepseek-flash","max_tokens":256,"messages":[$messages]}"""
    }

    private fun finishReason(body: String): String =
        Regex("\"finish_reason\"\\s*:\\s*\"([a-z_]+)\"").find(body)?.groupValues?.get(1) ?: "missing"
}
