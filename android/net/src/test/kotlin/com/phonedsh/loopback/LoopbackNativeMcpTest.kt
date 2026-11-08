// phone-dsh — :loopback tests: `/mcp/native` behind the token gate and admission.
// SPDX-License-Identifier: MIT
//
// Ports ADBMCPTests.testAuthenticatedLoopbackMCPAndAdmission: the shared tap
// vector goes over real HTTP to the real AdbMcpServer through this origin.

package com.phonedsh.loopback

import com.phonedsh.adb.AdbConfiguration
import com.phonedsh.adb.AdbMcpServer
import com.phonedsh.adb.AdbReceiptStore
import com.phonedsh.adb.AdbSettings
import com.phonedsh.adb.InMemoryAdbSettingsStorage
import com.phonedsh.adb.RecordingAdb
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.gateway.GatewayVectorRunner
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsBytes
import io.ktor.http.ContentType
import io.ktor.http.contentType
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LoopbackNativeMcpTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private val assets: Path by lazy { Fixtures.write(Path.of(temporary.newFolder("assets").absolutePath)) }

    private fun adb(recorder: RecordingAdb): AdbMcpServer {
        val settings = AdbSettings(InMemoryAdbSettingsStorage())
        settings.save(AdbConfiguration(true, "192.0.2.1"))
        return AdbMcpServer(settings, recorder, AdbReceiptStore(Path.of(temporary.newFolder().absolutePath)))
    }

    private val tap: JsonObject by lazy {
        val path = GatewayVectorRunner.findRepositoryRoot().resolve("spec/v1/golden/native-mcp/tap.json")
        JsonValue.parse(String(Files.readAllBytes(path), Charsets.UTF_8)) as JsonObject
    }

    @Test
    fun tapVectorOverAuthenticatedHttp() = runBlocking<Unit> {
        val recorder = RecordingAdb()
        LoopbackServer(nativeMcp = adb(recorder)).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val url = endpoint.urlFor((tap["path"] as JsonString).value)
                val unauthorized = http.post(url) { setBody(tap["request"]!!.toJsonString()) }
                assertEquals(401, unauthorized.status.value)
                val response = http.post(url) {
                    header("Authorization", "Bearer ${endpoint.token}")
                    contentType(ContentType.Application.Json)
                    setBody(tap["request"]!!.toJsonString())
                }
                assertEquals(200, response.status.value)
                assertEquals(tap["response"], JsonValue.parse(String(response.bodyAsBytes(), Charsets.UTF_8)))
                val get = http.get(url) { header("Authorization", "Bearer ${endpoint.token}") }
                assertEquals(405, get.status.value)
            }
        }
        assertEquals(listOf((tap["android_command"] as JsonString).value), recorder.commands.toList())
    }

    @Test
    fun closedAdmissionRejectsToolCallsButNotOtherMethods() = runBlocking<Unit> {
        val recorder = RecordingAdb()
        LoopbackServer(nativeMcp = adb(recorder), nativeMcpAdmission = { false }).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val url = endpoint.urlFor("/mcp/native")
                val rejected = http.post(url) {
                    header("Authorization", "Bearer ${endpoint.token}")
                    setBody(tap["request"]!!.toJsonString())
                }
                assertEquals(503, rejected.status.value)
                val listed = http.post(url) {
                    header("Authorization", "Bearer ${endpoint.token}")
                    setBody("""{"jsonrpc":"2.0","id":2,"method":"tools/list"}""")
                }
                assertEquals(200, listed.status.value)
            }
        }
        assertEquals(emptyList<String>(), recorder.commands.toList())
    }

    @Test
    fun withoutANativeServerThePathIsNotMounted() = runBlocking<Unit> {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val response = http.post(endpoint.urlFor("/mcp/native")) {
                    header("Authorization", "Bearer ${endpoint.token}")
                    setBody(tap["request"]!!.toJsonString())
                }
                assertEquals(405, response.status.value)
            }
        }
    }
}
