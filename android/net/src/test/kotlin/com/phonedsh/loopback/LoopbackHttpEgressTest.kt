// phone-dsh — :loopback tests: the `/v1/http` route is a proxy, not an asset.
// SPDX-License-Identifier: MIT

package com.phonedsh.loopback

import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsBytes
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Path

class LoopbackHttpEgressTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private val assets: Path by lazy {
        Fixtures.write(Path.of(temporary.newFolder("assets").absolutePath))
    }

    @Test
    fun theRouteCarriesTheTargetAndMethodToTheEgress() = runBlocking {
        val seen = ArrayList<LoopbackHttpRequest>()
        val egress = LoopbackHttpEgress { request ->
            seen += request
            LoopbackHttpResponse(
                status = 200,
                headers = mapOf("content-type" to "application/json"),
                body = """{"ok":true}""".toByteArray(),
            )
        }
        LoopbackServer(httpEgress = egress).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val response = http.post(endpoint.urlFor("/v1/http")) {
                    header("Authorization", "Bearer ${endpoint.token}")
                    header("X-PDSH-Target-URL", "https://api.example.test/v1/chat")
                    header("X-PDSH-Target-Method", "POST")
                    contentType(ContentType.Application.Json)
                    setBody("""{"prompt":"hi"}""")
                }
                assertEquals(200, response.status.value)
                assertEquals("""{"ok":true}""", response.bodyAsBytes().toString(Charsets.UTF_8))
            }
        }
        assertEquals(1, seen.size)
        val request = seen.single()
        assertEquals("https://api.example.test/v1/chat", request.targetUrl)
        assertEquals("POST", request.targetMethod)
        assertEquals("""{"prompt":"hi"}""", request.body.toString(Charsets.UTF_8))
        assertTrue(request.headers.containsKey("x-pdsh-target-url"))
    }

    @Test
    fun aStartWithoutAnEgressPolicyAnswers503() = runBlocking {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val response = http.post(endpoint.urlFor("/v1/http")) {
                    header("Authorization", "Bearer ${endpoint.token}")
                    header("X-PDSH-Target-URL", "https://api.example.test/")
                }
                assertEquals(503, response.status.value)
            }
        }
    }

    @Test
    fun aMissingTargetHeaderIs400BeforeThePolicyRuns() = runBlocking {
        var called = false
        LoopbackServer(httpEgress = { called = true; LoopbackHttpResponse(200) }).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val response = http.post(endpoint.urlFor("/v1/http")) {
                    header("Authorization", "Bearer ${endpoint.token}")
                }
                assertEquals(400, response.status.value)
            }
        }
        assertEquals(false, called)
    }

    @Test
    fun theEgressRouteStillNeedsTheOriginToken() = runBlocking {
        LoopbackServer(httpEgress = { LoopbackHttpResponse(200) }).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val response = http.post(endpoint.urlFor("/v1/http")) {
                    header("X-PDSH-Target-URL", "https://api.example.test/")
                }
                assertEquals(401, response.status.value)
            }
        }
    }

    @Test
    fun aPolicyResponseIsCopiedByteForByte() = runBlocking {
        val payload = byteArrayOf(0x00, 0x01, 0x7F, 0xFF.toByte())
        val egress = LoopbackHttpEgress {
            LoopbackHttpResponse(
                status = 207,
                headers = mapOf("content-type" to "application/octet-stream", "x-upstream" to "one"),
                body = payload,
            )
        }
        LoopbackServer(httpEgress = egress).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val response = http.post(endpoint.urlFor("/v1/http")) {
                    header("Authorization", "Bearer ${endpoint.token}")
                    header("X-PDSH-Target-URL", "https://api.example.test/bin")
                }
                assertEquals(207, response.status.value)
                assertArrayEquals(payload, response.bodyAsBytes())
            }
        }
    }
}
