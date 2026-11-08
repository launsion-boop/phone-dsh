// phone-dsh — :net / com.phonedsh.adb: stateless Streamable HTTP MCP on `/mcp/native`.
// SPDX-License-Identifier: MIT
//
// Kotlin end of `Sources/PhoneDSHADB/ADBMCPServer.swift` (P05,
// spec/v1/native-mcp.md). The official DSH MCP client registers these tools as
// `mcp__phone__android_*` when the host sets `PDSH_PHONE_MCP_URL`.
//
// Semantics kept from the Swift actor:
//   * single JSON-RPC POSTs (`initialize`, `ping`, `tools/list`, `tools/call`);
//     notifications answer an empty 202, any other HTTP method 405;
//   * Android operations are serialized: a second call while one runs is an
//     error result, never queued or run in parallel;
//   * with an `X-PDSH-Idempotency-Key`, the intent is fsynced before adbd sees
//     OPEN; a completed key replays its result, an unresolved or evicted one is
//     refused, a different fingerprint (tool, arguments, endpoint) is -32602;
//   * `notifications/cancelled` for the running request id cancels it; the
//     outcome is then reported as an error and recorded, not retried;
//   * JSON-RPC ids are used only for correlation and cancellation.
// The operation runs in this server's own scope so a dropped HTTP caller cannot
// leave a receipt without its result.

package com.phonedsh.adb

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.loopback.NativeMcpRequest
import com.phonedsh.loopback.NativeMcpResponse
import com.phonedsh.loopback.NativeMcpServing
import java.nio.file.Path
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

public class AdbMcpServer(
    private val settings: AdbSettings,
    private val executor: AdbCommandExecuting,
    private val receiptStore: AdbReceiptStore,
    workspaceDirectory: Path? = null,
) : NativeMcpServing {
    private val mutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var workspaceDirectory: Path? = workspaceDirectory

    private class Active(val id: JsonValue, val work: Deferred<JsonValue>, val outer: Deferred<JsonValue>)

    @Volatile
    private var active: Active? = null

    private class Receipt(val fingerprint: ByteArray, var result: JsonValue? = null, var size: Int = 0)

    private val receipts = HashMap<String, Receipt>()
    private val order = ArrayDeque<String>()
    private var receiptBytes = 0L

    /** True while an Android operation (tool call or connection check) runs. */
    public val isBusy: Boolean get() = active != null

    public suspend fun setWorkspaceDirectory(directory: Path) {
        mutex.withLock {
            if (active != null) throw AdbFailure("Wait for the current Android operation before changing its workspace")
            workspaceDirectory = directory
        }
    }

    /** Save while idle; changing a target must not redirect an in-flight action. */
    public suspend fun configure(configuration: AdbConfiguration) {
        mutex.withLock {
            if (active != null) {
                throw AdbFailure("Wait for the current Android operation or cancel it before changing the connection")
            }
            settings.save(configuration)
        }
    }

    public fun load(): AdbConfiguration = settings.load()

    /** The page's 停止当前 Android 操作. */
    public fun cancel() {
        active?.work?.cancel()
    }

    override suspend fun cancelPendingOperations() {
        val current = mutex.withLock { active } ?: return
        current.work.cancel()
        runCatching { current.outer.await() }
    }

    /** The page's 测试连接: the same status command, serialized with tool calls, no receipt. */
    public suspend fun checkConnection(configuration: AdbConfiguration): String {
        val outer = mutex.withLock {
            if (active != null) throw AdbFailure("An Android operation is already running")
            val endpoint = configuration.endpoint()
            start(JsonString("native-connection-check"), finish = { it }) {
                try {
                    val result = executor.shell(endpoint, STATUS_COMMAND, ByteArray(0), 30_000, 65_536)
                    if (result.exitCode != 0) throw AdbFailure(String(result.stderr, Charsets.UTF_8))
                    JsonString(String(result.stdout, Charsets.UTF_8))
                } catch (failure: CancellationException) {
                    throw failure
                } catch (failure: Exception) {
                    obj("error" to JsonString(failure.message ?: "ADB connection failed"))
                }
            }
        }
        return when (val result = outer.await()) {
            is JsonString -> result.value
            is JsonObject -> throw AdbFailure(
                (result["error"] as? JsonString)?.value
                    ?: ((result["content"] as? JsonArray)?.values?.firstOrNull() as? JsonObject)
                        ?.let { (it["text"] as? JsonString)?.value } ?: "ADB connection failed",
            )
            else -> throw AdbFailure("ADB connection failed")
        }
    }

    override suspend fun handle(request: NativeMcpRequest): NativeMcpResponse {
        if (request.method != "POST") return NativeMcpResponse(405)
        val message = if (request.body.size <= 16 * 1024) {
            try {
                JsonValue.parse(String(request.body, Charsets.UTF_8)) as? JsonObject
            } catch (failure: Exception) {
                null
            }
        } else {
            null
        }
        val method = (message?.get("method") as? JsonString)?.value
        if (message == null || message["jsonrpc"] != JsonString("2.0") || method == null) {
            return rpcError(JsonNull, -32600, "Invalid JSON-RPC request")
        }
        val params = (message["params"] as? JsonObject)?.members.orEmpty()
        val id = message["id"]
        if (id == null) {
            if (method == "notifications/cancelled") {
                mutex.withLock {
                    val current = active
                    if (current != null && params["requestId"] == current.id) current.work.cancel()
                }
            }
            return NativeMcpResponse(202)
        }
        if (id !is JsonString && id !is JsonNumber) return rpcError(JsonNull, -32600, "Invalid request ID")
        return when (method) {
            "initialize" -> {
                val requested = (params["protocolVersion"] as? JsonString)?.value ?: ""
                response(
                    id,
                    obj(
                        "protocolVersion" to JsonString(if (requested in SUPPORTED_VERSIONS) requested else "2025-03-26"),
                        "capabilities" to obj("tools" to obj()),
                        "serverInfo" to obj("name" to JsonString("phone-dsh-android"), "version" to JsonString("1.0.0")),
                        "instructions" to JsonString(INSTRUCTIONS),
                    ),
                )
            }
            "ping" -> response(id, obj())
            "tools/list" -> response(id, obj("tools" to JsonArray(AdbTools.descriptors)))
            "tools/call" -> callTool(request, id, params)
            else -> rpcError(id, -32601, "Method not found")
        }
    }

    private suspend fun callTool(request: NativeMcpRequest, id: JsonValue, params: Map<String, JsonValue>): NativeMcpResponse {
        val name = (params["name"] as? JsonString)?.value ?: return rpcError(id, -32602, "Tool name required")
        val arguments = params["arguments"] ?: obj()
        val plan: AdbTools.Plan
        val endpoint: AdbEndpoint
        try {
            plan = AdbTools.plan(name, arguments)
            endpoint = (plan.connection ?: settings.load()).endpoint()
        } catch (failure: AdbFailure) {
            return response(id, AdbTools.textResult(failure.message ?: "Invalid Android tool call", error = true))
        }
        // A retry of the same journaled tool call must never tap/type twice.
        val key = request.header(IDEMPOTENCY_HEADER)
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(
            canonical(
                obj(
                    "name" to JsonString(name),
                    "arguments" to arguments,
                    "host" to JsonString(endpoint.host),
                    "port" to JsonNumber(endpoint.port.toString()),
                ),
            ).toByteArray(Charsets.UTF_8),
        )
        val outer = mutex.withLock {
            if (key != null && receipts[key] == null) {
                val saved = try {
                    receiptStore.load(key)
                } catch (failure: Exception) {
                    return response(
                        id,
                        AdbTools.textResult("Cannot read Android operation receipt; refusing to repeat an uncertain action.", error = true),
                    )
                }
                if (saved != null) {
                    if (!saved.fingerprint.contentEquals(fingerprint)) return rpcError(id, -32602, "Idempotency key conflict")
                    return response(
                        id,
                        saved.result ?: AdbTools.textResult(
                            "An earlier attempt at this Android operation was interrupted. Its outcome is unknown; " +
                                "inspect device state before issuing a new action.",
                            error = true,
                        ),
                    )
                }
            }
            if (key != null) {
                receipts[key]?.let { receipt ->
                    if (!receipt.fingerprint.contentEquals(fingerprint)) return rpcError(id, -32602, "Idempotency key conflict")
                    return response(
                        id,
                        receipt.result ?: AdbTools.textResult(
                            "This Android operation was already admitted; its result is pending or no longer retained. " +
                                "Inspect device state before issuing a new action.",
                            error = true,
                        ),
                    )
                }
            }
            if (active != null) {
                return response(
                    id,
                    AdbTools.textResult("An Android operation is already running; wait for it before the next action.", error = true),
                )
            }
            if (key != null) {
                if (key.length > 256 || key.isEmpty() || receipts.size >= 4096) {
                    return rpcError(id, -32602, "Invalid idempotency key or receipt capacity reached; restart the app")
                }
                try {
                    receiptStore.save(key, AdbReceipt(fingerprint))
                } catch (failure: Exception) {
                    return response(
                        id,
                        AdbTools.textResult("Cannot persist Android operation intent; no command was sent.", error = true),
                    )
                }
                receipts[key] = Receipt(fingerprint)
            }
            val workspace = workspaceDirectory
            start(id, finish = { result -> record(key, fingerprint, result) }) {
                try {
                    plan.connection?.let { settings.save(it) }
                    val apk = plan.workspaceApk
                    val shell = if (apk != null && plan.sha256 != null) {
                        val data = AdbWorkspaceApk.read(apk, workspace, plan.sha256)
                        executor.shell(endpoint, plan.command + " -S ${data.size} -", data, plan.timeoutMillis, plan.outputLimit)
                    } else {
                        executor.shell(endpoint, plan.command, ByteArray(0), plan.timeoutMillis, plan.outputLimit)
                    }
                    AdbTools.result(shell, plan)
                } catch (failure: CancellationException) {
                    throw failure
                } catch (failure: Exception) {
                    AdbTools.textResult((failure.message ?: "Android operation failed") + INTERRUPTED_NOTE, error = true)
                }
            }
        }
        return response(id, outer.await())
    }

    /** Called under [mutex]; returns the result the caller sees. */
    private fun record(key: String?, fingerprint: ByteArray, result: JsonValue): JsonValue {
        if (key == null) return result
        var final = result
        try {
            receiptStore.save(key, AdbReceipt(fingerprint, final))
        } catch (failure: Exception) {
            final = AdbTools.textResult(
                "Android operation ended, but its result could not be persisted. Inspect device state before repeating it.",
                error = true,
            )
        }
        val size = final.toJsonString().length
        receipts[key] = Receipt(fingerprint, final, size)
        receiptBytes += size
        order.addLast(key)
        while (receiptBytes > 16L * 1024 * 1024 && order.isNotEmpty()) {
            val old = order.removeFirst()
            receiptBytes -= receipts[old]?.size ?: 0
            receipts[old]?.let { it.result = null; it.size = 0 }
        }
        return final
    }

    /** Called under [mutex]: one operation at a time, recorded even if its caller left. */
    private fun start(
        id: JsonValue,
        finish: (JsonValue) -> JsonValue,
        body: suspend () -> JsonValue,
    ): Deferred<JsonValue> {
        val work = scope.async(start = CoroutineStart.LAZY) { body() }
        val outer = scope.async(start = CoroutineStart.LAZY) {
            val result = try {
                work.await()
            } catch (failure: CancellationException) {
                AdbTools.textResult("Android operation cancelled." + INTERRUPTED_NOTE, error = true)
            }
            withContext(NonCancellable) {
                mutex.withLock {
                    active = null
                    finish(result)
                }
            }
        }
        active = Active(id, work, outer)
        work.start()
        outer.start()
        return outer
    }

    private fun response(id: JsonValue, result: JsonValue): NativeMcpResponse = NativeMcpResponse(
        body = obj("jsonrpc" to JsonString("2.0"), "id" to id, "result" to result).toJsonString().toByteArray(Charsets.UTF_8),
    )

    private fun rpcError(id: JsonValue, code: Int, message: String): NativeMcpResponse = NativeMcpResponse(
        body = obj(
            "jsonrpc" to JsonString("2.0"),
            "id" to id,
            "error" to obj("code" to JsonNumber(code.toString()), "message" to JsonString(message)),
        ).toJsonString().toByteArray(Charsets.UTF_8),
    )

    public companion object {
        public const val IDEMPOTENCY_HEADER: String = "X-PDSH-Idempotency-Key"
        internal const val STATUS_COMMAND: String = "getprop ro.product.model; getprop ro.build.version.release; wm size"
        private val SUPPORTED_VERSIONS = listOf("2024-11-05", "2025-03-26", "2025-06-18")
        private const val INTERRUPTED_NOTE =
            "\nIf the connection was interrupted, the Android action may already have occurred. Inspect state before repeating it."

        /** The iOS server's instructions, verbatim (native-mcp.md is one contract for every host). */
        internal const val INSTRUCTIONS: String =
            "Android tools connect directly from iPhone over LAN TCP/IP ADB. Use android_connect with the user-provided host and optional port to enable control and save or change the target, including when control is disabled; do not ask the user to visit Settings. android_shell supports arbitrary commands within Android ADB shell permissions. For file transfers use the Worker bash commands adb push LOCAL REMOTE and adb pull REMOTE [LOCAL] (single files; /dsh/transfers/NAME streams up to 1 GiB on iPhone disk, /dsh/workspace/NAME uses the smaller Worker budget; pull defaults to /dsh/transfers; use bash timeoutMs=3600000 for large transfers; after a timeout call Worker adb stat LOCAL before retrying and distinguish running from saved); do not run adb inside android_shell. Use android_list_packages for installed apps and android_list_apk_files for installer files. Uninstall uses packageName. Install requires source=workspace or device; workspace APKs require /dsh/workspace/...apk and sha256sum. Use android_command_help to discover device-supported commands; android_shell runs on Android, without an adb shell prefix. Use a screenshot before choosing pixels. No automatic retries."

        /** Sorted-key compact JSON so a retry with reordered members has the same fingerprint. */
        internal fun canonical(value: JsonValue): String = when (value) {
            is JsonObject -> value.members.entries.sortedBy { it.key }
                .joinToString(",", "{", "}") { JsonString(it.key).toJsonString() + ":" + canonical(it.value) }
            is JsonArray -> value.values.joinToString(",", "[", "]") { canonical(it) }
            else -> value.toJsonString()
        }
    }
}
