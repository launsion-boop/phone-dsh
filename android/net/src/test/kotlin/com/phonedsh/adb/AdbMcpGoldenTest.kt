// phone-dsh — :net tests: the shared native-MCP vectors through the real Android server.
// SPDX-License-Identifier: MIT
//
// `spec/v1/golden/native-mcp/*.json` is the judge (P05). Each Android-tool vector
// is decoded from the shared file, sent as the exact JSON-RPC body to
// `AdbMcpServer.handle` (and, for tap.json, through the authenticated loopback
// route in LoopbackNativeMcpTest), and both the Android shell command and the
// whole JSON-RPC response must equal the vector. Every file in the directory
// must be classified here, so a new vector cannot be silently skipped.

package com.phonedsh.adb

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.gateway.GatewayVectorRunner
import com.phonedsh.loopback.NativeMcpRequest
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class AdbMcpGoldenTest {
    private val directory: Path = GatewayVectorRunner.findRepositoryRoot().resolve("spec/v1/golden/native-mcp")

    private fun load(name: String): JsonValue =
        JsonValue.parse(String(Files.readAllBytes(directory.resolve(name)), Charsets.UTF_8))

    private fun body(value: JsonValue): ByteArray = value.toJsonString().toByteArray()

    @Test
    fun everyNativeMcpVectorIsClassified() {
        val files = Files.list(directory).use { stream -> stream.map { it.fileName.toString() }.sorted().toList() }
        assertEquals(RUN_ON_ANDROID + NOT_SERVED_ON_ANDROID.keys, files.toSet())
    }

    @Test
    fun tapVectorRunsThroughTheRealServer() = runBlocking<Unit> {
        val golden = load("tap.json") as JsonObject
        val recorder = RecordingAdb()
        val server = AdbFixtures.server(recorder)
        assertEquals("/mcp/native", (golden["path"] as JsonString).value)
        val response = server.handle(NativeMcpRequest((golden["method"] as JsonString).value, emptyMap(), body(golden["request"]!!)))
        assertEquals(200, response.status)
        assertEquals(golden["response"], JsonValue.parse(String(response.body, Charsets.UTF_8)))
        assertEquals(listOf((golden["android_command"] as JsonString).value), recorder.commands.toList())
    }

    @Test
    fun connectVectorEnablesADisabledTargetAndPersistsIt() = runBlocking<Unit> {
        val golden = load("connect.json") as JsonObject
        val recorder = RecordingAdb()
        val storage = InMemoryAdbSettingsStorage()
        val server = AdbFixtures.server(recorder, enabled = false, storage = storage)
        val response = server.handle(NativeMcpRequest("POST", emptyMap(), body(golden["request"]!!)))
        assertEquals(golden["response"], JsonValue.parse(String(response.body, Charsets.UTF_8)))
        assertEquals(listOf((golden["android_command"] as JsonString).value), recorder.commands.toList())
        assertEquals(listOf(AdbEndpoint("192.0.2.2", 5556)), recorder.endpoints.toList())
        assertEquals(AdbConfiguration(true, "192.0.2.2", 5556), AdbSettings(storage).load())
    }

    @Test
    fun packageManagementVectorsRunThroughTheRealServer() = runBlocking<Unit> {
        val vectors = (load("package-management.json") as JsonArray).values.map { it as JsonObject }
        assertEquals(3, vectors.size)
        for (vector in vectors) {
            val command = (vector["android_command"] as JsonString).value
            val stdout = (vector["stdout"] as JsonString).value
            val recorder = RecordingAdb(outputs = mapOf(command to AdbShellResult(stdout = stdout.toByteArray())))
            val server = AdbFixtures.server(recorder)
            val response = server.handle(NativeMcpRequest("POST", emptyMap(), body(vector["request"]!!)))
            assertEquals(command, vector["response"], JsonValue.parse(String(response.body, Charsets.UTF_8)))
            assertEquals(listOf(command), recorder.commands.toList())
        }
    }

    companion object {
        val RUN_ON_ANDROID: Set<String> = setOf("tap.json", "connect.json", "package-management.json")

        /** Vectors whose surface this Android host does not serve, with the reason. */
        val NOT_SERVED_ON_ANDROID: Map<String, String> = mapOf(
            "file-transfer.json" to "Worker `adb push/pull/stat` needs HELLO accelerator:adb; Android does not advertise it",
            "ble-devices.json" to "BLE tools are iOS-only on /mcp/native (native-mcp.md §BLE tools)",
            "iphone-agent-volume-policy.json" to "iPhone agent volume guidance is iOS-only; Android has no iphone_agent_run surface",
        )
    }
}
