// phone-dsh — :net tests: AdbMcpServer behaviour (ports ADBMCPTests.swift).
// SPDX-License-Identifier: MIT

package com.phonedsh.adb

import com.phonedsh.adb.AdbFixtures.call
import com.phonedsh.adb.AdbFixtures.json
import com.phonedsh.adb.AdbFixtures.num
import com.phonedsh.adb.AdbFixtures.request
import com.phonedsh.adb.AdbFixtures.result
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.loopback.NativeMcpRequest
import java.nio.file.Files
import java.util.Base64
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AdbMcpServerTest {
    private val error = "isError"

    @Test
    fun initializeListAndUnsupportedMethods() = runBlocking<Unit> {
        val server = AdbFixtures.server()
        val initialized = result(server.handle(request("initialize", obj("protocolVersion" to JsonString("2025-03-26")))))
        assertEquals(JsonString("2025-03-26"), initialized["protocolVersion"])
        val fallback = result(server.handle(request("initialize", obj("protocolVersion" to JsonString("1999-01-01")))))
        assertEquals(JsonString("2025-03-26"), fallback["protocolVersion"])
        val tools = (result(server.handle(request("tools/list")))["tools"] as JsonArray).values
        assertEquals(26, tools.size)
        assertEquals(26, tools.map { ((it as JsonObject)["name"] as JsonString).value }.toSet().size)
        assertTrue(tools.all { ((it as JsonObject)["name"] as JsonString).value.startsWith("android_") })
        assertEquals(202, server.handle(request("notifications/initialized", id = null)).status)
        assertEquals(405, server.handle(NativeMcpRequest("GET", emptyMap(), ByteArray(0))).status)
        val unknown = json(server.handle(request("unknown")))
        assertEquals(num(-32601), (unknown["error"] as JsonObject)["code"])
        val invalid = json(server.handle(NativeMcpRequest("POST", emptyMap(), "[1]".toByteArray())))
        assertEquals(num(-32600), (invalid["error"] as JsonObject)["code"])
        val oversized = json(server.handle(NativeMcpRequest("POST", emptyMap(), ByteArray(16 * 1024 + 1) { 32 })))
        assertEquals(num(-32600), (oversized["error"] as JsonObject)["code"])
    }

    @Test
    fun checkConnectionPreservesTheTypedFailureKind() {
        val executor = object : AdbCommandExecuting {
            override suspend fun shell(
                endpoint: AdbEndpoint,
                command: String,
                stdin: ByteArray,
                timeoutMillis: Long,
                outputLimit: Int,
            ): AdbShellResult = throw AdbFailure("waiting for the TV", AdbFailureKind.UNAUTHORIZED)
        }
        val server = AdbFixtures.server(executor)
        val failure = assertThrows(AdbFailure::class.java) {
            runBlocking {
                server.checkConnection(
                    AdbConfiguration(enabled = true, host = "192.0.2.81", port = 5555),
                    timeoutMillis = 4_000,
                )
            }
        }
        assertEquals(AdbFailureKind.UNAUTHORIZED, failure.kind)
    }

    @Test
    fun toolCallAndIdempotentReplayNeverRepeatTap() = runBlocking<Unit> {
        val recorder = RecordingAdb()
        val server = AdbFixtures.server(recorder)
        val req = call("android_tap", mapOf("x" to num(12), "y" to num(34)), key = "tap-once")
        val first = result(server.handle(req))
        val second = result(server.handle(req))
        assertEquals(first, second)
        assertEquals(listOf("input tap 12 34"), recorder.commands.toList())
        val conflict = json(server.handle(call("android_tap", mapOf("x" to num(1), "y" to num(2)), key = "tap-once")))
        assertNotNull(conflict["error"])
        // Reordered members are the same call, not a conflict.
        val reordered = NativeMcpRequest(
            "POST",
            mapOf("x-pdsh-idempotency-key" to "tap-once"),
            """{"params":{"arguments":{"y":34,"x":12},"name":"android_tap"},"id":9,"method":"tools/call","jsonrpc":"2.0"}""".toByteArray(),
        )
        assertEquals(first, result(server.handle(reordered)))
        assertEquals(1, recorder.commands.size)
    }

    @Test
    fun connectEnablesDisabledControlAndPersistsTarget() = runBlocking<Unit> {
        val recorder = RecordingAdb()
        val server = AdbFixtures.server(recorder, enabled = false)
        for (args in listOf(
            mapOf("host" to JsonString("")),
            mapOf("host" to JsonString("192.0.2.2"), "port" to num(0)),
            mapOf("host" to JsonString("192.0.2.2"), "port" to num(1.5)),
        )) {
            assertEquals(JsonBool(true), result(server.handle(call("android_connect", args)))[error])
        }
        val args = mapOf("host" to JsonString("192.0.2.2"), "port" to num(5556))
        val connected = result(server.handle(call("android_connect", args, key = "connect-once")))
        assertEquals(JsonBool(false), connected[error])
        assertEquals(connected, result(server.handle(call("android_connect", args, key = "connect-once"))))
        assertEquals(JsonBool(false), result(server.handle(call("android_status")))[error])
        assertEquals(2, recorder.commands.size)
        assertEquals(listOf(AdbEndpoint("192.0.2.2", 5556), AdbEndpoint("192.0.2.2", 5556)), recorder.endpoints.toList())
    }

    @Test
    fun disabledDeviceAndInvalidArgumentsNeverReachAdb() = runBlocking<Unit> {
        val recorder = RecordingAdb()
        val disabled = AdbFixtures.server(recorder, enabled = false)
        assertEquals(JsonBool(true), result(disabled.handle(call("android_status")))[error])
        val server = AdbFixtures.server(recorder)
        for (args in listOf(
            mapOf("x" to num(-1), "y" to num(2)),
            mapOf("x" to num(1.5), "y" to num(2)),
            mapOf("x" to num(1), "y" to num(2), "host" to JsonString("other")),
            mapOf("x" to JsonBool(true), "y" to num(2)),
        )) {
            assertEquals(JsonBool(true), result(server.handle(call("android_tap", args)))[error])
        }
        assertTrue(recorder.commands.isEmpty())
    }

    @Test
    fun persistentReceiptSurvivesRestartAndUnknownIntentFailsClosed() = runBlocking<Unit> {
        val directory = Files.createTempDirectory("adb-receipts")
        val recorder = RecordingAdb()
        val req = call("android_key", mapOf("key" to JsonString("HOME")), key = "survives-restart")
        val first = result(AdbFixtures.server(recorder, receipts = directory).handle(req))
        val replayed = result(AdbFixtures.server(recorder, receipts = directory).handle(req))
        assertEquals(first, replayed)
        val store = AdbReceiptStore(directory)
        val saved = requireNotNull(store.load("survives-restart"))
        store.save("survives-restart", AdbReceipt(saved.fingerprint))
        val unknown = result(AdbFixtures.server(recorder, receipts = directory).handle(req))
        assertEquals(JsonBool(true), unknown[error])
        Files.write(Files.list(directory).use { it.findFirst().get() }, "not json".toByteArray())
        val corrupt = result(AdbFixtures.server(recorder, receipts = directory).handle(req))
        assertEquals(JsonBool(true), corrupt[error])
        assertEquals(listOf("input keyevent KEYCODE_HOME"), recorder.commands.toList())
    }

    @Test
    fun screenshotIsMcpImageWithUnmodifiedPngBytes() = runBlocking<Unit> {
        val png = Base64.getDecoder().decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1sAAAAASUVORK5CYII=",
        )
        val server = AdbFixtures.server(RecordingAdb(AdbShellResult(stdout = png)))
        val content = (result(server.handle(call("android_screenshot")))["content"] as JsonArray).values.single() as JsonObject
        assertEquals(JsonString("image"), content["type"])
        assertEquals(JsonString("image/png"), content["mimeType"])
        assertEquals(JsonString(Base64.getEncoder().encodeToString(png)), content["data"])
        val bad = AdbFixtures.server(RecordingAdb(AdbShellResult(stdout = "not png".toByteArray())))
        assertEquals(JsonBool(true), result(bad.handle(call("android_screenshot")))[error])
    }

    @Test
    fun commandEscapingAndInputLimits() {
        val plan = AdbTools.plan("android_input_text", obj("text" to JsonString("hello';\$(id) & bye")))
        assertEquals("input text 'hello'\\'';\$(id)%s&%sbye'", plan.command)
        for (text in listOf("中文", "line\nfeed", "literal%s")) {
            assertThrows(AdbFailure::class.java) { AdbTools.plan("android_input_text", obj("text" to JsonString(text))) }
        }
        assertThrows(AdbFailure::class.java) { AdbTools.plan("android_launch_app", obj("packageName" to JsonString("x;reboot"))) }
        assertThrows(AdbFailure::class.java) { AdbTools.plan("android_key", obj("key" to JsonString("HOME;id"))) }
        assertThrows(AdbFailure::class.java) {
            AdbTools.plan("android_shell", obj("command" to JsonString("id"), "timeoutMs" to num(120001)))
        }
        assertThrows(AdbFailure::class.java) { AdbEndpoint.of("http://phone.invalid", 5555) }
        assertThrows(AdbFailure::class.java) { AdbEndpoint.of("phone", 0) }
    }

    @Test
    fun packageManagerFailureWithZeroExitIsAnError() = runBlocking<Unit> {
        val command = "pm uninstall --user current 'com.example.app'"
        val server = AdbFixtures.server(RecordingAdb(outputs = mapOf(command to AdbShellResult(stdout = "Failure [DELETE_FAILED]\n".toByteArray()))))
        val value = result(server.handle(call("android_uninstall_app", mapOf("packageName" to JsonString("com.example.app")))))
        assertEquals(JsonBool(true), value[error])
    }

    @Test
    fun serializesActionsAndCancellationSettles() = runBlocking<Unit> {
        val recorder = RecordingAdb(park = true)
        val server = AdbFixtures.server(recorder)
        val req = call("android_shell", mapOf("command" to JsonString("sleep 30")), key = "cancel-once")
        val running = async { server.handle(req) }
        withTimeout(5_000) { recorder.started.await() }
        val competing = result(server.handle(call("android_tap", mapOf("x" to num(1), "y" to num(2)))))
        assertEquals(JsonBool(true), competing[error])
        assertEquals(202, server.handle(request("notifications/cancelled", obj("requestId" to num(1)), id = null)).status)
        val cancelled = result(withTimeout(5_000) { running.await() })
        assertEquals(JsonBool(true), cancelled[error])
        assertEquals(cancelled, result(server.handle(req)))
        assertEquals(1, recorder.commands.size)
    }

    @Test
    fun shutdownCancelsAndRecordsPendingWork() = runBlocking<Unit> {
        val recorder = RecordingAdb(park = true)
        val directory = Files.createTempDirectory("adb-receipts")
        val server = AdbFixtures.server(recorder, receipts = directory)
        val running = async { server.handle(call("android_shell", mapOf("command" to JsonString("sleep 30")), key = "shutdown")) }
        withTimeout(5_000) { recorder.started.await() }
        withTimeout(5_000) { server.cancelPendingOperations() }
        assertEquals(JsonBool(true), result(running.await())[error])
        val saved = requireNotNull(AdbReceiptStore(directory).load("shutdown"))
        assertEquals(JsonBool(true), (saved.result as JsonObject)[error])
    }

    @Test
    fun workspaceApkStreamsVerifiedBytesAndRejectsMismatchBeforeAdb() = runBlocking<Unit> {
        val root = Files.createTempDirectory("workspace")
        Files.createDirectories(root.resolve("apps"))
        val apk = byteArrayOf(80, 75, 3, 4, 1, 2, 3)
        Files.write(root.resolve("apps/app.apk"), apk)
        val digest = AdbReceiptStore.sha256Hex(apk)
        val command = "pm install --user current -r -S 7 -"
        val recorder = RecordingAdb(outputs = mapOf(command to AdbShellResult(stdout = "Success\n".toByteArray())))
        val server = AdbFixtures.server(recorder, workspace = root)
        val wrong = result(
            server.handle(
                call(
                    "android_install_apk",
                    mapOf("source" to JsonString("workspace"), "apkPath" to JsonString("/dsh/workspace/apps/app.apk"), "sha256" to JsonString("0".repeat(64))),
                ),
            ),
        )
        assertEquals(JsonBool(true), wrong[error])
        assertTrue(recorder.commands.isEmpty())
        val ok = result(
            server.handle(
                call(
                    "android_install_apk",
                    mapOf("source" to JsonString("workspace"), "apkPath" to JsonString("/dsh/workspace/apps/app.apk"), "sha256" to JsonString(digest)),
                ),
            ),
        )
        assertEquals(JsonBool(false), ok[error])
        assertEquals(listOf(command), recorder.commands.toList())
        assertTrue(apk.contentEquals(recorder.inputs.single()))
    }

    @Test
    fun checkConnectionAndConfigureAreSerializedWithTools() = runBlocking<Unit> {
        val recorder = RecordingAdb(park = true)
        val server = AdbFixtures.server(recorder)
        val running = async { server.handle(call("android_status")) }
        withTimeout(5_000) { recorder.started.await() }
        assertThrows(AdbFailure::class.java) { runBlocking { server.configure(AdbConfiguration(true, "192.0.2.9")) } }
        assertThrows(AdbFailure::class.java) { runBlocking { server.checkConnection(AdbConfiguration(true, "192.0.2.9")) } }
        server.cancel()
        assertEquals(JsonBool(true), result(running.await())[error])
        assertThrows(AdbFailure::class.java) { runBlocking { server.checkConnection(AdbConfiguration(false, "192.0.2.9")) } }
        val ok = AdbFixtures.server(RecordingAdb())
        assertEquals("fixture", ok.checkConnection(AdbConfiguration(true, "192.0.2.9")))
        ok.configure(AdbConfiguration(true, "192.0.2.9", 5557))
        assertEquals(AdbConfiguration(true, "192.0.2.9", 5557), ok.load())
    }

    @Test
    fun settingsKeepTheIosKeyAndJsonShapeAndReadMalformedAsDefault() {
        val storage = InMemoryAdbSettingsStorage()
        AdbSettings(storage).save(AdbConfiguration(true, "192.0.2.4", 5555))
        assertEquals(
            JsonValue.parse("""{"enabled":true,"host":"192.0.2.4","port":5555}"""),
            JsonValue.parse(requireNotNull(storage.read("phone-dsh.android-adb.configuration.v1"))),
        )
        storage.write(AdbSettings.KEY, "{")
        assertEquals(AdbConfiguration(), AdbSettings(storage).load())
        assertThrows(AdbFailure::class.java) { AdbSettings(storage).save(AdbConfiguration(true, "", 5555)) }
    }
}
