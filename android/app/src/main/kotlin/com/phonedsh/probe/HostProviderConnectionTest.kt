// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.ui.page.ProviderDraft
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID

/** A user-safe result for the provider editor; it never contains a key or response body. */
internal sealed interface ProviderConnectionTestResult {
    val message: String

    data class Success(override val message: String) : ProviderConnectionTestResult
    data class Failure(override val message: String) : ProviderConnectionTestResult
}

/** One real endpoint probe. Secret-bearing headers are intentionally absent from toString(). */
internal class ProviderProbeRequest(
    val url: URL,
    val headers: Map<String, String>,
    val body: ByteArray,
    val method: String = "POST",
) {
    override fun toString(): String = "ProviderProbeRequest($method ${url.path})"
}

internal data class ProviderProbeResponse(
    val statusCode: Int,
    val body: String = "",
    val bodyTooLarge: Boolean = false,
)

/** A model-list result correlated to the editor request and profile that started it. */
internal data class HostProviderModelsResult(
    val requestId: String,
    val profileId: String?,
    val models: List<String>?,
    val message: String,
) {
    val succeeded: Boolean get() = models != null
}

/** Typed save outcome, separating service-record persistence from a key-write failure. */
internal data class HostProviderSaveResult(
    val recordWritten: Boolean,
    val succeeded: Boolean,
    val message: String,
    val requestId: String = "",
    val profileId: String? = null,
    val isNew: Boolean = false,
)

/** Native HTTP connection test bound to the editor request that started it. */
internal data class HostProviderTestResult(
    val requestId: String,
    val profileId: String?,
    val result: ProviderConnectionTestResult,
)

internal fun interface ProviderProbeTransport {
    suspend fun execute(request: ProviderProbeRequest): ProviderProbeResponse
}

/**
 * Test the same endpoint formats the iOS editor tests, with the draft key taking
 * precedence and stored credentials read only for an existing profile. The test
 * is a one-token ping; it never writes the key and never logs the request.
 */
internal suspend fun testProviderConnection(
    draft: ProviderDraft,
    keyProvider: () -> String? = {
        val store = ApiKeyStore.active()
        val account = providerAccountFor(draft)
        if (store == null || account == null) null else store.readKey(account)
    },
    storedEndpointProvider: () -> String? = { storedProviderFor(draft)?.endpoint },
    launchEndpointProvider: () -> String? = { ProbeLaunchConfig.active().deepseekBaseUrl },
    transport: ProviderProbeTransport = UrlConnectionProviderProbeTransport,
): ProviderConnectionTestResult = withContext(Dispatchers.IO) {
    val endpointText = providerEndpointForDraft(
        draft, storedEndpointProvider, launchEndpointProvider,
    ).orEmpty()
    val endpoint = validateProbeEndpoint(endpointText)
        ?: return@withContext ProviderConnectionTestResult.Failure(endpointFailure(endpointText))

    val model = draft.model.trim()
    if (model.isEmpty()) {
        return@withContext ProviderConnectionTestResult.Failure("模型名是空的。")
    }

    val key = when {
        draft.apiKey.isNotBlank() -> draft.apiKey.trim()
        draft.isNew || draft.removeStoredKey -> ""
        else -> try {
            keyProvider().orEmpty()
        } catch (_: Exception) {
            return@withContext ProviderConnectionTestResult.Failure("读不到已保存的密钥；输入新密钥后可重新测试。")
        }
    }
    if (key.isEmpty()) {
        return@withContext ProviderConnectionTestResult.Failure("还没有可用于测试的密钥。")
    }
    if (key.length < ApiKeyStore.MIN_KEY_LENGTH || key.any { it !in '!'..'~' }) {
        return@withContext ProviderConnectionTestResult.Failure("密钥格式不符合要求；请检查后重试。")
    }

    val anthropicFirst = endpoint.toString().lowercase().contains("/anthropic")
    val attempts = if (anthropicFirst) listOf(ProviderProtocol.ANTHROPIC, ProviderProtocol.OPENAI)
    else listOf(ProviderProtocol.OPENAI, ProviderProtocol.ANTHROPIC)
    var lastStatus: Int? = null
    for (protocol in attempts) {
        val request = buildProviderProbeRequest(endpoint, protocol, model, key)
        val response = try {
            transport.execute(request)
        } catch (_: Exception) {
            return@withContext ProviderConnectionTestResult.Failure("连不上模型服务；请检查网络和接口地址。")
        }
        val status = response.statusCode
        lastStatus = status
        when (status) {
            in 200..299 -> return@withContext ProviderConnectionTestResult.Success(
                "连接正常（HTTP $status，${protocol.title}，${protocol.pathLabel}）。密钥可用。",
            )
            401, 403 -> return@withContext ProviderConnectionTestResult.Failure(
                "密钥被服务拒绝（HTTP $status）。请确认密钥与服务地址属于同一平台。",
            )
            429 -> return@withContext ProviderConnectionTestResult.Failure(
                "请求太频繁（HTTP 429）；服务已收到测试请求。",
            )
            in 300..399 -> return@withContext ProviderConnectionTestResult.Failure(
                "服务要求重定向（HTTP $status）；为保护密钥，测试未跟随跳转。",
            )
            else -> Unit // Try the other protocol, matching the iOS editor.
        }
    }
    ProviderConnectionTestResult.Failure(
        "测试失败（HTTP ${lastStatus ?: 0}）。请检查接口地址、协议和模型名。",
    )
}

/**
 * Fetches the profile's actual `/models` catalog over native
 * HTTP. This works before Worker startup and does not borrow a key for a new
 * profile. The request id/profile id travel with the result so callers can ignore
 * a late response after the editor has moved on.
 */
internal suspend fun testProviderConnectionBound(
    draft: ProviderDraft,
    requestId: String,
    keyProvider: () -> String? = {
        val store = ApiKeyStore.active()
        val account = providerAccountFor(draft)
        if (store == null || account == null) null else store.readKey(account)
    },
    storedEndpointProvider: () -> String? = { storedProviderFor(draft)?.endpoint },
    launchEndpointProvider: () -> String? = { ProbeLaunchConfig.active().deepseekBaseUrl },
    transport: ProviderProbeTransport = UrlConnectionProviderProbeTransport,
): HostProviderTestResult = HostProviderTestResult(
    requestId = requestId,
    profileId = draft.id.takeIf { it.isNotBlank() },
    result = testProviderConnection(draft, keyProvider, storedEndpointProvider, launchEndpointProvider, transport),
)

/** Persists one profile/key pair and returns a result bound to this save request. */
internal suspend fun saveProviderDraft(
    draft: ProviderDraft,
    requestId: String,
    store: ProviderConfigStore? = ProviderConfigStore.active(),
    keyStore: ApiKeyStore? = ApiKeyStore.active(),
    launch: ProbeLaunchConfig = ProbeLaunchConfig.active(),
): HostProviderSaveResult = withContext(Dispatchers.IO) {
    var resultProfileId = draft.id.trim().takeIf(String::isNotEmpty)
    fun failed(message: String, written: Boolean = false) = HostProviderSaveResult(
        recordWritten = written,
        succeeded = false,
        message = message,
        requestId = requestId,
        profileId = resultProfileId,
        isNew = draft.isNew,
    )

    if (store == null) return@withContext failed("本宿主没有安装模型服务存储，本次未保存")
    val keyReason = if (draft.apiKey.isBlank()) null else ProviderDraftRules.keyRejection(draft.apiKey)
    if (keyReason != null) return@withContext failed(keyReason)
    if ((draft.apiKey.isNotBlank() || draft.removeStoredKey) && keyStore == null) {
        return@withContext failed("本宿主没有安装密钥存储，本次未保存密钥")
    }
    draft.modelValidationError?.let { return@withContext failed(it) }

    val existingSnapshot = when (val read = store.read()) {
        is ProviderStoreRead.Stored -> read.snapshot
        ProviderStoreRead.Empty -> ProviderSnapshot.EMPTY
        ProviderStoreRead.Unreadable -> return@withContext failed(
            "现有模型服务配置无法读取；为避免覆盖，本次未保存",
        )
    }
    val requestedId = draft.id.trim()
    val previous = if (draft.isNew) {
        if (requestedId.isNotEmpty() && existingSnapshot.profiles.any { it.id == requestedId }) {
            return@withContext failed("这个模型服务标识已存在；本次未覆盖现有服务")
        }
        null
    } else {
        existingSnapshot.profiles.firstOrNull { it.id == requestedId }
            ?: if (existingSnapshot.profiles.isEmpty() && requestedId == ProviderConfigStore.DEFAULT_ID) {
                // The empty store's `local` row is a view of the process launch,
                // not a persisted profile. Editing it creates the first record
                // while retaining its exact launch binding, or allocating an
                // isolated account when an explicit launch override was unbound.
                ProviderRecord(
                    id = requestedId,
                    name = draft.name,
                    model = launch.modelName,
                    endpoint = launch.deepseekBaseUrl.orEmpty(),
                    credentialRef = launch.credentialAccount
                        ?: ProviderRecord.providerCredentialRef("local-${UUID.randomUUID()}"),
                )
            } else {
                return@withContext failed("这个模型服务已不存在；请重新载入后再保存")
            }
    }
    val normalizedDraft = if (draft.isNew) {
        val id = if (requestedId.isNotEmpty()) requestedId else {
            var generated: String
            do {
                generated = UUID.randomUUID().toString().lowercase()
            } while (existingSnapshot.profiles.any { it.id == generated })
            generated
        }
        draft.copy(id = id)
    } else {
        draft.copy(id = previous!!.id)
    }
    resultProfileId = normalizedDraft.id
    val record = ProviderConfigStore.recordOf(
        normalizedDraft,
        previous,
        launch.deepseekBaseUrl,
        launch.modelName,
    )
    ProviderDraftRules.endpointRejection(record.endpoint)?.let { return@withContext failed(it) }
    if (record.name.isEmpty()) return@withContext failed("模型服务名不能为空，本次未保存")

    // Unknown key-store state is never a request to delete the credential. A
    // typed replacement is deliberate and remains allowed, as on iOS. A stale
    // delete toggle must fail before the service document is written at all.
    val unreadableRemovalRequested = !draft.isNew && draft.removeStoredKey &&
        draft.apiKey.isBlank() && keyStore?.read(record.credentialAccount()) is ApiKeyState.Unreadable
    if (unreadableRemovalRequested) {
        return@withContext failed("无法读取此设备的密钥，不能删除服务或密钥。请解锁设备后重新载入页面再试。")
    }
    val removeStoredKey = draft.removeStoredKey
    when (val outcome = store.save(record, selectAsDefault = draft.isNew)) {
        ProviderWriteOutcome.Saved -> Unit
        is ProviderWriteOutcome.Rejected -> return@withContext failed(outcome.reason)
        else -> return@withContext failed("本机存储不可写，本次未保存")
    }
    val keyLine = try {
        when {
            removeStoredKey -> {
                keyStore?.clear(record.credentialAccount())
                "，密钥已删除"
            }
            draft.apiKey.isNotBlank() -> {
                keyStore?.save(draft.apiKey, record.credentialAccount())
                if (keyStore?.readKey(record.credentialAccount()) != draft.apiKey.trim()) {
                    throw IllegalStateException("key readback failed")
                }
                "，密钥已保存"
            }
            else -> ""
        }
    } catch (_: IllegalArgumentException) {
        return@withContext failed("配置已保存；密钥未通过校验，本次未保存密钥", true)
    } catch (_: Exception) {
        return@withContext failed("配置已保存；密钥写入失败或读取确认失败，本次未确认密钥变更", true)
    }
    val readback = store.snapshot()
    val savedProfile = readback?.profiles?.firstOrNull { it.id == record.id }
    if (savedProfile != record || (draft.isNew && readback?.selectedId != record.id)) {
        return@withContext failed("保存请求已完成，但模型服务记录没有读回；请刷新确认结果。", true)
    }
    HostProviderSaveResult(
        recordWritten = true,
        succeeded = true,
        message = if (keyLine.isEmpty()) "已保存到本机：模型服务（下次启动 App 时生效）"
            else "已保存到本机：模型服务$keyLine（模型服务在下次启动 App 时生效）",
        requestId = requestId,
        profileId = record.id,
        isNew = draft.isNew,
    )
}

internal data class ProviderDeleteReceipt(
    val profileRemoved: Boolean,
    val keyRemoved: Boolean,
    val message: String,
)

/** Deletes only after a readable key and a confirmed key-store removal. */
internal fun deleteProviderRecord(
    id: String,
    store: ProviderConfigStore?,
    keyStore: ApiKeyStore?,
): ProviderDeleteReceipt {
    if (store == null) return ProviderDeleteReceipt(false, false, "本宿主没有安装模型服务存储，本次未删除")
    val record = store.snapshot()?.profiles?.firstOrNull { it.id == id }
        ?: return ProviderDeleteReceipt(false, false, "只能删除本机保存的模型服务；启动配置的服务不能删除")
    if (keyStore == null) {
        return ProviderDeleteReceipt(false, false, "无法读取此设备的密钥，不能删除服务或密钥。请解锁设备后重新载入页面再试。")
    }
    val account = record.credentialAccount()
    if (keyStore.read(account) is ApiKeyState.Unreadable) {
        return ProviderDeleteReceipt(false, false, "无法读取此设备的密钥，不能删除服务或密钥。请解锁设备后重新载入页面再试。")
    }
    try {
        keyStore.clear(account)
    } catch (_: Exception) {
        return ProviderDeleteReceipt(false, false, "密钥删除没有确认；模型服务未删除，请重试")
    }
    // Removing one of several profiles writes the remaining document, so the
    // store reports Saved; it reports Deleted only when the last row went away.
    // Both mean the write was accepted. The readback below, not the outcome
    // variant, decides whether the profile is really gone.
    when (store.delete(id)) {
        ProviderWriteOutcome.Saved, ProviderWriteOutcome.Deleted -> Unit
        else -> return ProviderDeleteReceipt(false, true, "密钥已删除；模型服务配置未删除，请刷新后重试")
    }
    val profileRemains = when (val readback = store.read()) {
        is ProviderStoreRead.Stored -> readback.snapshot.profiles.any { it.id == id }
        ProviderStoreRead.Empty -> false
        ProviderStoreRead.Unreadable -> true
    }
    if (profileRemains) {
        return ProviderDeleteReceipt(false, true, "密钥已删除；模型服务配置删除结果无法确认，请刷新后检查")
    }
    return ProviderDeleteReceipt(true, true, "已删除本机保存的模型服务与密钥")
}

internal suspend fun getProviderModels(
    draft: ProviderDraft,
    requestId: String,
    keyProvider: () -> String? = {
        val store = ApiKeyStore.active()
        val account = providerAccountFor(draft)
        if (store == null || account == null) null else store.readKey(account)
    },
    storedEndpointProvider: () -> String? = { storedProviderFor(draft)?.endpoint },
    launchEndpointProvider: () -> String? = { ProbeLaunchConfig.active().deepseekBaseUrl },
    transport: ProviderProbeTransport = UrlConnectionProviderProbeTransport,
): HostProviderModelsResult = withContext(Dispatchers.IO) {
    fun result(models: List<String>?, message: String) =
        HostProviderModelsResult(requestId, draft.id.takeIf { it.isNotBlank() }, models, message)

    val endpointText = providerEndpointForDraft(
        draft, storedEndpointProvider, launchEndpointProvider,
    ).orEmpty()
    val endpoint = validateProbeEndpoint(endpointText)
        ?: return@withContext result(null, endpointFailure(endpointText))
    if (endpoint.scheme.lowercase() != "https") {
        return@withContext result(null, "获取模型列表必须使用 HTTPS 地址。")
    }
    val key = when {
        draft.apiKey.isNotBlank() -> draft.apiKey.trim()
        draft.isNew || draft.removeStoredKey -> ""
        else -> try {
            keyProvider().orEmpty()
        } catch (_: Exception) {
            return@withContext result(null, "读不到已保存的密钥，请解锁设备后重试。")
        }
    }
    if (key.isEmpty()) return@withContext result(null, "还没有可用于读取模型列表的密钥。")
    if (key.length < ApiKeyStore.MIN_KEY_LENGTH || key.any { it !in '!'..'~' }) {
        return@withContext result(null, "密钥格式不符合要求；请检查后重试。")
    }

    val basePath = endpoint.rawPath.orEmpty().trimEnd('/')
    val anthropic = basePath.lowercase().contains("anthropic")
    fun request(url: URL): ProviderProbeRequest {
        val headers = linkedMapOf("Accept" to "application/json", "Authorization" to "Bearer $key")
        if (anthropic) {
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"
        }
        return ProviderProbeRequest(url, headers, byteArrayOf(), method = "GET")
    }
    val profileURL = URL("${endpoint.scheme}://${endpoint.rawAuthority}${basePath.ifEmpty { "" }}/models")
    val response = try {
        var received = transport.execute(request(profileURL))
        if (received.statusCode == 404 && anthropic) {
            val originURL = URL("${endpoint.scheme}://${endpoint.rawAuthority}/models")
            if (originURL.toExternalForm() != profileURL.toExternalForm()) {
                received = transport.execute(request(originURL))
            }
        }
        received
    } catch (_: Exception) {
        return@withContext result(null, "连不上模型服务；请检查网络和接口地址。")
    }
    if (response.bodyTooLarge || response.body.toByteArray(Charsets.UTF_8).size > MAX_PROVIDER_CATALOG_BYTES) {
        return@withContext result(null, "模型列表过大，请在高级设置中手动添加。")
    }
    if (response.statusCode !in 200..299) {
        val message = when (response.statusCode) {
            401, 403 -> "密钥被服务拒绝（HTTP ${response.statusCode}）。请确认密钥与服务地址属于同一平台。"
            in 300..399 -> "服务要求重定向（HTTP ${response.statusCode}）；为保护密钥，未跟随跳转。"
            404, 405 -> "此地址不支持获取模型，请检查 API 地址或在高级设置中手动添加。"
            429 -> "请求过于频繁，请稍后再试。"
            else -> "读取模型列表失败（HTTP ${response.statusCode}）。请检查接口地址和服务兼容性。"
        }
        return@withContext result(null, message)
    }
    val models = parseProviderModelCatalog(response.body)
        ?: return@withContext result(null, "服务返回的模型列表无法读取。")
    if (models.isEmpty() || models.size > MAX_PROVIDER_MODEL_COUNT) {
        return@withContext result(null, "服务未返回可用的模型列表。")
    }
    result(models, "已获取 ${models.size} 个模型，选择后点保存。")
}

/** Parses only the provider's catalog response; no fallback model ids. */
private fun parseProviderModelCatalog(body: String): List<String>? {
    return try {
        val root = JsonValue.parse(body) as? JsonObject ?: return null
        val rows = (root["data"] as? JsonArray)?.values ?: return null
        val ids = rows.map { row ->
            ((row as? JsonObject)?.get("id") as? JsonString)?.value?.trim()?.takeIf(String::isNotEmpty)
                ?: return null
        }
        ids.distinct().sorted().takeIf { it.size <= MAX_PROVIDER_MODEL_COUNT }
    } catch (_: Exception) {
        null
    }
}

/** Resolve only the exact draft profile, except the explicit ephemeral local launch row. */
private fun providerEndpointForDraft(
    draft: ProviderDraft,
    storedEndpointProvider: () -> String?,
    launchEndpointProvider: () -> String?,
): String? {
    draft.endpoint.trim().takeIf(String::isNotEmpty)?.let { return it }
    if (draft.isNew) return null
    storedEndpointProvider()?.trim()?.takeIf(String::isNotEmpty)?.let { return it }
    if (draft.id.trim() != ProviderConfigStore.DEFAULT_ID) return null
    return when (ProviderConfigStore.active()?.read()) {
        ProviderStoreRead.Empty, null -> launchEndpointProvider()?.trim()?.takeIf(String::isNotEmpty)
        is ProviderStoreRead.Stored, ProviderStoreRead.Unreadable -> null
    }
}

/** The selected record for this draft id, or null for a new profile. */
internal fun storedProviderFor(draft: ProviderDraft): ProviderRecord? {
    val store = ProviderConfigStore.active() ?: return null
    return store.snapshot()?.profiles?.firstOrNull { it.id == draft.id.trim() }
}

/** The key account this draft reads/writes; new profiles get their own account. */
internal fun providerAccountFor(
    draft: ProviderDraft,
    providerRead: ProviderStoreRead? = ProviderConfigStore.active()?.read(),
    launchAccount: String? = ProbeLaunchConfig.active().credentialAccount,
): String? {
    val id = draft.id.trim()
    if (draft.isNew) return ProviderRecord.providerCredentialRef(id)
    return when (providerRead) {
        is ProviderStoreRead.Stored -> providerRead.snapshot.profiles.firstOrNull { it.id == id }?.credentialAccount()
        ProviderStoreRead.Empty, null -> if (id == ProviderConfigStore.DEFAULT_ID) launchAccount else null
        ProviderStoreRead.Unreadable -> null
    }
}

private enum class ProviderProtocol(
    val title: String,
    val pathLabel: String,
) {
    ANTHROPIC("Anthropic Messages", "/v1/messages"),
    OPENAI("OpenAI 兼容", "/chat/completions"),
}

private fun validateProbeEndpoint(raw: String): URI? {
    if (raw.isBlank() || raw.any(Char::isWhitespace)) return null
    val uri = try {
        URI(raw)
    } catch (_: Exception) {
        return null
    }
    val scheme = uri.scheme?.lowercase() ?: return null
    if (scheme !in setOf("http", "https") || uri.host.isNullOrBlank()) return null
    if (uri.userInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
    // The app's Network Security Config permits cleartext only to this exact
    // loopback host. Do not present a public HTTP endpoint as testable.
    if (scheme == "http" && uri.host != "127.0.0.1") return null
    return uri
}

private fun endpointFailure(raw: String): String {
    if (raw.isBlank()) return "接口地址是空的。"
    val uri = try { URI(raw) } catch (_: Exception) { null }
    if (uri?.userInfo != null) return "接口地址不能内嵌用户名或密码。"
    if (uri?.rawQuery != null || uri?.rawFragment != null) return "接口地址不能带 query 或 fragment。"
    if (uri?.scheme?.lowercase() == "http" && uri.host != "127.0.0.1") {
        return "公网模型服务必须使用 HTTPS；HTTP 仅允许 127.0.0.1。"
    }
    return "接口地址必须是可用的 HTTP(S) 绝对地址。"
}

private fun buildProviderProbeRequest(
    base: URI,
    protocol: ProviderProtocol,
    model: String,
    key: String,
): ProviderProbeRequest {
    val basePath = base.rawPath.orEmpty().trimEnd('/')
    val suffix = when (protocol) {
        ProviderProtocol.ANTHROPIC -> {
            val root = if (basePath.endsWith("/v1")) basePath else "$basePath/v1"
            "$root/messages"
        }
        ProviderProtocol.OPENAI -> "$basePath/chat/completions"
    }.ifEmpty { "/" }
    val url = URL("${base.scheme}://${base.rawAuthority}$suffix")
    val members = linkedMapOf<String, JsonValue>(
        "model" to JsonString(model),
        "messages" to JsonArray(
            listOf(JsonObject(mapOf("role" to JsonString("user"), "content" to JsonString("ping")))),
        ),
        "max_tokens" to JsonNumber("1"),
    )
    if (protocol == ProviderProtocol.OPENAI) members["stream"] = JsonBool(false)
    val body = JsonObject(members).toJsonString()
    val headers = linkedMapOf(
        "Content-Type" to "application/json",
    )
    if (protocol == ProviderProtocol.ANTHROPIC) {
        headers["x-api-key"] = key
        headers["anthropic-version"] = "2023-06-01"
    }
    headers["Authorization"] = "Bearer $key"
    return ProviderProbeRequest(url, headers, body.toByteArray(Charsets.UTF_8))
}

private object UrlConnectionProviderProbeTransport : ProviderProbeTransport {
    override suspend fun execute(request: ProviderProbeRequest): ProviderProbeResponse = withContext(Dispatchers.IO) {
        val connection = request.url.openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 20_000
            connection.readTimeout = 20_000
            connection.requestMethod = request.method
            connection.doOutput = request.method != "GET"
            connection.setRequestProperty("Connection", "close")
            request.headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            if (request.method != "GET") connection.outputStream.use { output -> output.write(request.body) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val bytes = stream?.use { readBounded(it, MAX_PROVIDER_CATALOG_BYTES + 1) } ?: byteArrayOf()
            ProviderProbeResponse(
                statusCode = status,
                body = bytes.toString(Charsets.UTF_8),
                bodyTooLarge = bytes.size > MAX_PROVIDER_CATALOG_BYTES,
            )
        } finally {
            connection.disconnect()
        }
    }
}

private fun readBounded(stream: java.io.InputStream, maximum: Int): ByteArray {
    val output = java.io.ByteArrayOutputStream(minOf(maximum, 8 * 1024))
    val buffer = ByteArray(8 * 1024)
    var remaining = maximum
    while (remaining > 0) {
        val count = stream.read(buffer, 0, minOf(buffer.size, remaining))
        if (count < 0) break
        output.write(buffer, 0, count)
        remaining -= count
    }
    return output.toByteArray()
}

private const val MAX_PROVIDER_CATALOG_BYTES = 2 * 1024 * 1024
private const val MAX_PROVIDER_MODEL_COUNT = 2_000
