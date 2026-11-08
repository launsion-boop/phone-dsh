// phone-dsh — :app: the independent Search/Fetch service the person configured.
// SPDX-License-Identifier: MIT
//
// Android half of iOS `PhoneWebSearchSettings` (`Sources/PhoneDSH/
// PhoneWebSearchSettings.swift`), under `spec/v1/gateway-independent-search.md` §5.
// The non-secret document `{version: 1, mode, baseUrl}` lives in one private file;
// the key lives only in [ApiKeyStore] under its own account, never the model
// account. An absent document is the follow-model default. A document this build
// cannot fully read is its own state: the page says so and both web tools stay off,
// so a broken search setup never falls back to the model key.
//
// Trust boundary: a key belongs to the base it was saved for. Committing a
// different base deletes the stored key *before* the document points at the new
// base, and a key is accepted only once a canonical base is stored. Nothing here
// logs a value; messages name the action, never the key.

package com.phonedsh.probe

import android.content.Context
import android.util.Log
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.gateway.IndependentSearchWebTools
import com.phonedsh.ui.page.maskKeySuffix
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference

/** The document's `mode` member. */
internal enum class WebSearchSettingsMode(val wire: String) {
    FOLLOW_MODEL("follow-model"),
    SEARCH_API("search-api"),
    ;

    companion object {
        fun fromWire(value: String): WebSearchSettingsMode? = entries.firstOrNull { it.wire == value }
    }
}

/** One valid document: [baseUrl] is empty or canonical (§1). */
internal data class WebSearchSettings(
    val mode: WebSearchSettingsMode,
    val baseUrl: String,
)

/** What one read of the document found. */
internal sealed interface WebSearchSettingsRead {
    /** No document: the follow-model default. */
    data object Absent : WebSearchSettingsRead

    /** A valid document. */
    data class Stored(val settings: WebSearchSettings) : WebSearchSettingsRead

    /** A document exists but violates §5: report it and keep both tools off. */
    data object Unreadable : WebSearchSettingsRead
}

/**
 * The outcome of one page gesture.
 *
 * @param message the note-bar line, or `null` when nothing should be shown.
 * @param changed true when the document or the key really changed.
 */
internal data class WebSearchWriteResult(val message: String?, val changed: Boolean)

/**
 * The independent Search/Fetch settings.
 *
 * @param file the private document (`<filesDir>/settings/web-search.v1.json`).
 * @param keys the device key store; the key uses [ACCOUNT] only.
 */
internal class WebSearchSettingsStore(
    private val file: File,
    private val keys: ApiKeyStore,
    private val log: (String) -> Unit = { message -> Log.w(TAG, message) },
) {
    /** Reads the document; every failure is its own state. */
    @Synchronized
    fun read(): WebSearchSettingsRead {
        if (!file.isFile) return WebSearchSettingsRead.Absent
        val root = try {
            JsonValue.parse(file.readText(Charsets.UTF_8)) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return unreadable()
        if (root.members.keys != ROOT_FIELDS) return unreadable()
        if ((root["version"] as? JsonNumber)?.asLongOrNull() != VERSION) return unreadable()
        val mode = (root["mode"] as? JsonString)?.value?.let(WebSearchSettingsMode::fromWire)
            ?: return unreadable()
        val baseUrl = (root["baseUrl"] as? JsonString)?.value ?: return unreadable()
        if (baseUrl.isNotEmpty() && IndependentSearchWebTools.canonicalBase(baseUrl) != baseUrl) return unreadable()
        return WebSearchSettingsRead.Stored(WebSearchSettings(mode, baseUrl))
    }

    /** The independent key's three-state fact. */
    fun keyState(): ApiKeyState = keys.read(ACCOUNT)

    /** The injection path: the independent key, read again on every request. */
    fun readKey(): String? = keys.readKey(ACCOUNT)

    /** The last four characters of a usable key, for the page. */
    fun keyTail(): String? = (keyState() as? ApiKeyState.Valid)?.let { maskKeySuffix(it.value) }

    /** Selects which search the next engine start uses; the stored base and key stay. */
    @Synchronized
    fun setMode(mode: WebSearchSettingsMode): WebSearchWriteResult {
        val current = when (val read = read()) {
            WebSearchSettingsRead.Absent -> WebSearchSettings(WebSearchSettingsMode.FOLLOW_MODEL, "")
            is WebSearchSettingsRead.Stored -> read.settings
            WebSearchSettingsRead.Unreadable -> return refusedUnreadable()
        }
        if (current.mode == mode && file.isFile) return WebSearchWriteResult(null, false)
        if (!write(current.copy(mode = mode))) return WebSearchWriteResult(NOT_SAVED, false)
        return WebSearchWriteResult(
            when (mode) {
                WebSearchSettingsMode.FOLLOW_MODEL -> "已切换为沿用模型服务的搜索；重启本地引擎后生效"
                WebSearchSettingsMode.SEARCH_API ->
                    "已切换为自己填的搜索服务；保存地址和密钥并重启本地引擎后生效"
            },
            true,
        )
    }

    /**
     * Stores a new base. A different base deletes the old key first (§5), so an
     * old key can never be paired with a new service.
     */
    @Synchronized
    fun commitAddress(raw: String): WebSearchWriteResult {
        if (raw.isBlank()) return WebSearchWriteResult(null, false)
        val canonical = IndependentSearchWebTools.canonicalBase(raw)
            ?: return WebSearchWriteResult(INVALID_ADDRESS, false)
        val current = when (val read = read()) {
            WebSearchSettingsRead.Absent -> WebSearchSettings(WebSearchSettingsMode.SEARCH_API, "")
            is WebSearchSettingsRead.Stored -> read.settings
            WebSearchSettingsRead.Unreadable -> return refusedUnreadable()
        }
        if (current.baseUrl == canonical) {
            return WebSearchWriteResult("地址没有变化：$canonical", false)
        }
        val hadKey = keyState() != ApiKeyState.Absent
        if (hadKey) {
            try {
                keys.clear(ACCOUNT)
            } catch (_: Exception) {
                log("web-search key delete failed before an address change")
                return WebSearchWriteResult("原来的密钥无法删除，为避免把它用于新地址，本次未保存", false)
            }
        }
        if (!write(WebSearchSettings(WebSearchSettingsMode.SEARCH_API, canonical))) {
            return WebSearchWriteResult(
                if (hadKey) "地址未保存；原来的密钥已删除，请重新保存" else NOT_SAVED,
                hadKey,
            )
        }
        val keyLine = if (hadKey) "地址变了，原来的密钥已删除，请重新保存这个服务的密钥" else "请再保存这个服务的密钥"
        return WebSearchWriteResult("已保存地址 $canonical；$keyLine", true)
    }

    /** Stores the key for the stored base; never without one. */
    @Synchronized
    fun commitKey(raw: String): WebSearchWriteResult {
        val settings = (read() as? WebSearchSettingsRead.Stored)?.settings
        if (settings == null || settings.mode != WebSearchSettingsMode.SEARCH_API || settings.baseUrl.isEmpty()) {
            return WebSearchWriteResult("请先保存搜索服务地址，再保存密钥；本次未保存", false)
        }
        try {
            keys.save(raw, ACCOUNT)
        } catch (_: IllegalArgumentException) {
            return WebSearchWriteResult(
                "密钥需至少 ${ApiKeyStore.MIN_KEY_LENGTH} 个可打印 ASCII 字符，本次未保存",
                false,
            )
        } catch (_: Exception) {
            log("web-search key write failed")
            return WebSearchWriteResult("密钥未能写入安全存储，本次未保存", false)
        }
        return WebSearchWriteResult("已保存搜索服务密钥；重启本地引擎后生效", true)
    }

    /** Deletes only the key; the mode and base stay. */
    @Synchronized
    fun clearKey(): WebSearchWriteResult = try {
        keys.clear(ACCOUNT)
        WebSearchWriteResult("已清除搜索服务密钥；重启本地引擎后网页搜索关闭", true)
    } catch (_: Exception) {
        log("web-search key delete failed")
        WebSearchWriteResult("密钥无法删除，本次没有改动", false)
    }

    /** Deletes the key, then the document: the next start follows the model. */
    @Synchronized
    fun remove(): WebSearchWriteResult {
        try {
            keys.clear(ACCOUNT)
        } catch (_: Exception) {
            log("web-search key delete failed during removal")
            return WebSearchWriteResult("密钥无法删除，搜索服务保留，本次没有改动", false)
        }
        val deleted = try {
            !file.exists() || file.delete()
        } catch (_: Exception) {
            false
        }
        if (!deleted) {
            log("web-search document delete failed")
            return WebSearchWriteResult("密钥已删除，但配置文件无法删除", true)
        }
        return WebSearchWriteResult("已删除这个搜索服务；重启本地引擎后回到沿用模型服务", true)
    }

    private fun write(settings: WebSearchSettings): Boolean {
        val parent = file.parentFile
        if (parent != null && !parent.isDirectory && !parent.mkdirs()) {
            log("web-search document directory not writable")
            return false
        }
        val text = JsonObject(
            linkedMapOf(
                "version" to JsonNumber(VERSION.toString()),
                "mode" to JsonString(settings.mode.wire),
                "baseUrl" to JsonString(settings.baseUrl),
            ),
        ).toJsonString()
        return try {
            val temporary = File(parent, file.name + ".tmp")
            temporary.writeText(text, Charsets.UTF_8)
            if (temporary.renameTo(file)) {
                true
            } else {
                temporary.delete()
                log("web-search document rename failed")
                false
            }
        } catch (_: IOException) {
            log("web-search document write failed")
            false
        }
    }

    private fun unreadable(): WebSearchSettingsRead {
        log("web-search document unreadable")
        return WebSearchSettingsRead.Unreadable
    }

    private fun refusedUnreadable(): WebSearchWriteResult =
        WebSearchWriteResult("现有网页搜索配置无法读取；请先删除这个搜索服务再重新配置，本次未保存", false)

    companion object {
        const val TAG: String = "PDSHWebSearch"

        /** The independent key's account; never the model account. */
        const val ACCOUNT: String = "search.deepseek.api"

        const val FILE_NAME: String = "settings/web-search.v1.json"

        private const val VERSION: Long = 1L
        private val ROOT_FIELDS: Set<String> = setOf("version", "mode", "baseUrl")
        private const val NOT_SAVED: String = "网页搜索配置未能写入，本次未保存"
        private const val INVALID_ADDRESS: String =
            "地址无效：需要 https://域名/路径，不能带端口、账号、查询参数，也不能以 /search 或 /fetch 结尾；本次未保存"

        private val installed = AtomicReference<WebSearchSettingsStore?>(null)

        /** Binds the process-wide store; idempotent like [ApiKeyStore.install]. */
        @Synchronized
        fun install(context: Context, keys: ApiKeyStore): WebSearchSettingsStore {
            installed.get()?.let { return it }
            val created = WebSearchSettingsStore(File(context.applicationContext.filesDir, FILE_NAME), keys)
            installed.set(created)
            return created
        }

        /** The installed store, or `null` before the composition root ran. */
        fun active(): WebSearchSettingsStore? = installed.get()
    }
}
