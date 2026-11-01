// phone-dsh — :gateway tests: `/v1/http` is default-deny before any contact.
// SPDX-License-Identifier: MIT
//
// The claim these tests pin is `gw-egress-002`: an unlisted upstream is refused
// by the egress policy before the transport is touched. A fake transport makes
// "no socket was opened" an assertion instead of a hope.

package com.phonedsh.gateway

import com.phonedsh.loopback.LoopbackHttpRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GatewayHttpEgressTest {
    private class RecordingTransport(
        private val response: GatewayTransportResponse = GatewayTransportResponse(200),
    ) : GatewayTransport {
        val requests = ArrayList<GatewayTransportRequest>()

        override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
            requests += request
            return response
        }
    }

    private fun egressFor(
        origin: String,
        transport: GatewayTransport,
    ): GatewayHttpEgress {
        val grant = GatewayHostRule.parse(origin) ?: error("the test grant must parse")
        val session = GatewaySession(
            transport = transport,
            credentialProvider = { GatewayCredential.None },
            egress = AllowListEgressPolicy(listOf(grant)),
        )
        return GatewayHttpEgress(session)
    }

    @Test
    fun anUnlistedHostIsDeniedBeforeTheTransportIsTouched() {
        val transport = RecordingTransport()
        val egress = egressFor("http://127.0.0.1:7861", transport)
        val response = egress.handle(
            request(target = "https://unlisted.example/mcp", method = "POST"),
        )
        assertEquals(403, response.status)
        assertEquals("forbidden", response.headers["x-pdsh-proxy-error"])
        assertEquals("host_not_allowed", response.headers["x-pdsh-deny-reason"])
        assertTrue(response.bodyText().contains("host_not_allowed"))
        assertTrue("no upstream contact was allowed", transport.requests.isEmpty())
    }

    @Test
    fun anExactOriginGrantAllowsTheHop() {
        val transport = RecordingTransport(
            GatewayTransportResponse(
                status = 200,
                headers = mapOf("content-type" to "application/json"),
                body = """{"ok":true}""".toByteArray(),
            ),
        )
        val egress = egressFor("http://127.0.0.1:7861", transport)
        val response = egress.handle(
            request(
                target = "http://127.0.0.1:7861/v1/messages",
                method = "POST",
                headers = mapOf(
                    "content-type" to "application/json",
                    // A worker-supplied credential must never reach the upstream.
                    "authorization" to "Bearer worker-key",
                    "cookie" to "launch=secret",
                ),
            ),
        )
        assertEquals(200, response.status)
        assertEquals("""{"ok":true}""", response.bodyText())
        assertEquals(1, transport.requests.size)
        val outbound = transport.requests.single()
        assertEquals("http://127.0.0.1:7861/v1/messages", outbound.url)
        assertEquals("POST", outbound.method)
        assertFalse("caller authorization must be stripped", outbound.headers.containsKey("authorization"))
        assertFalse("loopback cookie must be stripped", outbound.headers.containsKey("cookie"))
    }

    @Test
    fun aPortMismatchIsDeniedBeforeTheTransportIsTouched() {
        val transport = RecordingTransport()
        val egress = egressFor("http://127.0.0.1:7861", transport)
        val response = egress.handle(
            request(target = "http://127.0.0.1:7862/v1/messages", method = "POST"),
        )
        assertEquals(403, response.status)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun aMissingTargetIsA400AndNoContact() {
        val transport = RecordingTransport()
        val egress = egressFor("http://127.0.0.1:7861", transport)
        val response = egress.handle(request(target = "", method = "POST"))
        assertEquals(400, response.status)
        assertEquals("bad_request", response.headers["x-pdsh-proxy-error"])
        assertTrue(transport.requests.isEmpty())
    }

    private fun request(
        target: String,
        method: String,
        headers: Map<String, String> = emptyMap(),
        body: ByteArray = ByteArray(0),
    ): LoopbackHttpRequest {
        val all = LinkedHashMap(headers)
        if (target.isNotEmpty()) all["x-pdsh-target-url"] = target
        all["x-pdsh-target-method"] = method
        return LoopbackHttpRequest(
            method = "POST",
            targetUrl = target,
            targetMethod = method,
            headers = all,
            body = body,
        )
    }
}
