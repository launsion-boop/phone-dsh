// phone-dsh — :net tests: ADB recorders, a scripted adbd and fixture helpers.
// SPDX-License-Identifier: MIT

package com.phonedsh.adb

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.loopback.NativeMcpRequest
import com.phonedsh.loopback.NativeMcpResponse
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.security.KeyPairGenerator
import java.security.interfaces.RSAPrivateCrtKey
import java.util.Collections
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation

/** Records every command; optionally parks until cancelled. */
internal class RecordingAdb(
    private val output: AdbShellResult = AdbShellResult(stdout = "fixture".toByteArray()),
    private val park: Boolean = false,
    private val outputs: Map<String, AdbShellResult> = emptyMap(),
) : AdbCommandExecuting {
    val commands: MutableList<String> = Collections.synchronizedList(ArrayList())
    val endpoints: MutableList<AdbEndpoint> = Collections.synchronizedList(ArrayList())
    val inputs: MutableList<ByteArray> = Collections.synchronizedList(ArrayList())
    val started = CompletableDeferred<Unit>()

    override suspend fun shell(
        endpoint: AdbEndpoint,
        command: String,
        stdin: ByteArray,
        timeoutMillis: Long,
        outputLimit: Int,
    ): AdbShellResult {
        commands += command
        endpoints += endpoint
        if (stdin.isNotEmpty()) inputs += stdin
        started.complete(Unit)
        if (park) awaitCancellation()
        return outputs[command] ?: output
    }
}

internal fun newIdentity(): AdbIdentity {
    val generator = KeyPairGenerator.getInstance("RSA")
    generator.initialize(2048)
    return AdbIdentity(generator.generateKeyPair().private as RSAPrivateCrtKey)
}

internal fun shellFrame(kind: Int, payload: ByteArray): ByteArray {
    val out = ByteArrayOutputStream()
    out.write(kind)
    out.appendLe(payload.size.toLong())
    out.write(payload)
    return out.toByteArray()
}

internal fun connected(): AdbPacket = AdbPacket(
    AdbPacket.CONNECT, 0x01000000, 4096, "device::ro.product.name=test;features=shell_v2,cmd;\u0000".toByteArray(),
)

/** A scripted adbd: replies are pre-encoded, writes are recorded. */
internal class ScriptedAdb(bytes: ByteArray) : AdbTransport {
    constructor(packets: List<AdbPacket>) : this(packets.fold(ByteArray(0)) { acc, p -> acc + p.encoded() })

    private var remaining = bytes
    val sent: MutableList<ByteArray> = Collections.synchronizedList(ArrayList())

    @Volatile
    var closed: Boolean = false

    override fun start() {}

    override fun read(count: Int): ByteArray = synchronized(this) {
        if (remaining.size < count) throw AdbFailure("fixture EOF")
        val value = remaining.copyOfRange(0, count)
        remaining = remaining.copyOfRange(count, remaining.size)
        value
    }

    override fun write(bytes: ByteArray) {
        sent += bytes
    }

    override fun close() {
        closed = true
    }
}

internal object AdbFixtures {
    fun server(
        executor: AdbCommandExecuting = RecordingAdb(),
        enabled: Boolean = true,
        receipts: Path = Files.createTempDirectory("adb-receipts"),
        storage: AdbSettingsStorage = InMemoryAdbSettingsStorage(),
        workspace: Path? = null,
    ): AdbMcpServer {
        val settings = AdbSettings(storage)
        settings.save(AdbConfiguration(enabled = enabled, host = "192.0.2.1"))
        return AdbMcpServer(settings, executor, AdbReceiptStore(receipts), workspace)
    }

    fun request(method: String, params: JsonValue = JsonObject(emptyMap()), key: String? = null, id: JsonValue? = num(1)): NativeMcpRequest {
        val members = linkedMapOf<String, JsonValue>("jsonrpc" to JsonString("2.0"), "method" to JsonString(method), "params" to params)
        if (id != null) members["id"] = id
        return NativeMcpRequest(
            "POST",
            if (key == null) emptyMap() else mapOf(AdbMcpServer.IDEMPOTENCY_HEADER to key),
            JsonObject(members).toJsonString().toByteArray(),
        )
    }

    fun call(name: String, args: Map<String, JsonValue> = emptyMap(), key: String? = null, id: JsonValue = num(1)): NativeMcpRequest =
        request("tools/call", obj("name" to JsonString(name), "arguments" to JsonObject(LinkedHashMap(args))), key, id)

    fun json(response: NativeMcpResponse): JsonObject = JsonValue.parse(String(response.body, Charsets.UTF_8)) as JsonObject

    fun result(response: NativeMcpResponse): JsonObject = json(response)["result"] as JsonObject

    fun num(value: Number): JsonValue = com.phonedsh.agentcore.JsonNumber(value.toString())
}
