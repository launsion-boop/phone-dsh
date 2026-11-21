// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.gateway.CredentialUnavailableException
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.EgressPolicy
import com.phonedsh.gateway.GatewayHttpEgress
import com.phonedsh.gateway.GatewaySession
import com.phonedsh.gateway.GatewayUrl
import com.phonedsh.gateway.HttpUrlConnectionGatewayTransport
import com.phonedsh.gateway.McpEgressCredential
import com.phonedsh.gateway.McpEgressCredentialProvider
import com.phonedsh.gateway.McpEgressGate
import com.phonedsh.gateway.McpEgressPolicy
import com.phonedsh.loopback.BotMcpEndpoint
import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackHttpRequest
import com.phonedsh.loopback.LoopbackHttpResponse
import java.net.URI

internal class AppBotMcpEgress(private val fallback: LoopbackHttpEgress?) : LoopbackHttpEgress {
    private val policy = McpEgressPolicy()
    private var endpointOrigin: String? = null
    private var token: String? = null
    private val gateway = McpEgressGate(
        policy,
        GatewayHttpEgress(
            GatewaySession(
                transport = HttpUrlConnectionGatewayTransport(readTimeoutMillis = 180_000),
                credentialProvider = McpEgressCredentialProvider(policy, GatewayCredentialProvider { throw CredentialUnavailableException() }),
                egress = object : EgressPolicy {
                    override fun permits(url: GatewayUrl): Boolean = policy.allowsEgressHost(url)
                    override fun admitsMcpGrant(url: GatewayUrl): Boolean = permits(url)
                },
                maxRedirects = 0,
            ),
        ),
    )

    @Synchronized
    fun install(endpoint: BotMcpEndpoint): String {
        if (endpoint.origin != endpointOrigin) {
            policy.grantBotRuntimeEndpoint(endpoint.mcpUrl(), endpoint.token)
            endpointOrigin = endpoint.origin
            token = McpEgressCredential.make().also(policy::installEgressToken)
        }
        return checkNotNull(token)
    }

    override fun handle(request: LoopbackHttpRequest): LoopbackHttpResponse {
        if (!policy.allowsEgressHost(request.targetUrl)) {
            return fallback?.handle(request) ?: LoopbackHttpResponse(
                status = 403,
                headers = mapOf("content-type" to "application/json", "x-pdsh-proxy-error" to "host_not_allowed"),
                body = """{"error":{"code":"host_not_allowed","message":"host is not allowed"}}""".toByteArray(),
            )
        }
        val uri = URI(request.targetUrl)
        if (uri.rawQuery != null || uri.rawFragment != null || uri.rawPath !in routes) {
            return LoopbackHttpResponse(400)
        }
        return gateway.handle(request.copy(headers = request.headers.filterKeys {
            !it.equals("origin", ignoreCase = true)
        }))
    }

    private companion object {
        val routes = setOf("/mcp", "/identity/register", "/identity/cancel", "/approval")
    }
}
