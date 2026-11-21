// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.loopback.BotMcpListener
import com.phonedsh.loopback.BotMcpRequest
import com.phonedsh.loopback.BotMcpRequestHandler
import com.phonedsh.loopback.BotMcpResponse
import com.phonedsh.loopback.LoopbackHttpRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AppBotMcpEgressTest {
    @Test
    fun onlyTheCurrentHostCredentialReachesTheListener() {
        val handler = object : BotMcpRequestHandler {
            override val mcpSessionId = "test-session"
            var calls = 0

            override suspend fun handle(request: BotMcpRequest): BotMcpResponse {
                calls++
                check(request.header("x-pdsh-mcp-egress") == null)
                check(request.header("origin") == null)
                return BotMcpResponse.Json(body = """{"jsonrpc":"2.0","id":1,"result":{}}""".toByteArray())
            }
        }
        BotMcpListener(handler).use { listener ->
            val endpoint = listener.startOrThrow()
            val egress = AppBotMcpEgress(null)
            val credential = egress.install(endpoint)
            val url = endpoint.mcpUrl()
            fun request(token: String?, target: String = url): LoopbackHttpRequest {
                val headers = mutableMapOf(
                    "x-pdsh-target-url" to target,
                    "content-type" to "application/json",
                    "origin" to "http://127.0.0.1:4567",
                    "x-pdsh-upstream-authorization" to "Bearer phone-host-injects-bot-mcp-token",
                )
                token?.let { headers["x-pdsh-mcp-egress"] = it }
                return LoopbackHttpRequest(
                    method = "POST",
                    targetUrl = target,
                    targetMethod = "POST",
                    headers = headers,
                    body = """{"jsonrpc":"2.0","id":1,"method":"ping"}""".toByteArray(),
                )
            }
            assertEquals(403, egress.handle(request(null)).status)
            assertEquals(403, egress.handle(request("wrong")).status)
            assertEquals(400, egress.handle(request(credential, "$url?unexpected=1")).status)
            assertEquals(0, handler.calls)
            val response = egress.handle(request(credential))
            assertEquals(200, response.status)
            assertEquals(1, handler.calls)
            assertFalse(response.bodyText().contains(endpoint.token))
        }
    }
}
