// phone-dsh — :app: the device record of the model services this host applies.
// SPDX-License-Identifier: MIT
//
// Why this store exists: `ModelProviderSettingsPage` says 添加 / 编辑 / 删除 and
// 配置会在下次启动主机时生效. Before this file the page's write gestures had nowhere
// to land, so the host reported `writable = NO` and every row was grey — an honest
// answer, but one that made the page's form impossible to use (and impossible to
// IME-test). This is the storage half of the (a) answer: the non-secret record
// (name, endpoint, model catalog, effort, credential reference) lives in one
// file; the key does not live here at all — it stays in [ApiKeyStore], the
// AndroidKeyStore envelope that already backs the gateway, so this file never
// sees a credential.
//
// What the record is: one document with many profiles and one selected id,
// mirroring iOS `PhoneModelProviderSettings`. A selected profile is the one the
// next host boot applies; a non-selected profile is an editable alternative. The
// document is versioned. Version 1 was the single-service properties file; a
// version-1 read is returned as one migrated profile without writing, so an old
// key account and every old value survive until the first deliberate write.
//
// Where a save takes effect: [ProbeLaunchConfig] overlays the selected profile on
// the launch extras at the next process start (an explicit
// `pdsh.deepseek.baseUrl` / `pdsh.model.name` still wins). That is what makes
// 下次启动主机时生效 true rather than copy.
//
// Failure behaviour: a missing file is [ProviderStoreRead.Empty] (first run), a
// corrupt one is [ProviderStoreRead.Unreadable] (the page then prints its
// CONFIG_UNREADABLE line instead of silently falling back), and a failed write
// is [ProviderWriteOutcome.Unavailable] (the page is told 未保存, never that it
// saved). Nothing here logs a value: only stable, token-free labels reach logcat.

package com.phonedsh.probe

import android.content.Context
import android.util.Log
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.ui.page.ProviderDraft
import java.io.File
import java.net.URI
import java.util.Properties
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

/** One model definition a provider exposes, including the optional source fields. */
internal data class ProviderModel(
    val id: String,
    val name: String? = null,
    val contextWindow: Int? = null,
    val maxTokens: Int? = null,
    val textInput: Boolean = true,
    val imageInput: Boolean = false,
    val reasoningEffort: String? = null,
)

/**
 * The non-secret half of one model service: what the engine needs to address it.
 *
 * @param id the page's stable row id.
 * @param name the display name the row shows.
 * @param model the default model id sent as `PDSH_MODEL_NAME`; empty means "the
 *   launch default", never a made-up id.
 * @param endpoint the Messages base URL (may carry a path prefix), stored
 *   verbatim once it parses as an absolute http(s) URL.
 * @param reasoningEffort the profile-level effort, when one was chosen.
 * @param models the per-model definitions; an empty list is normalized to the
 *   default model so a legacy row keeps a real selector.
 * @param credentialRef the key-store account for this profile. A migrated
 *   version-1 row keeps the legacy account so its key is not lost.
 */
internal data class ProviderRecord(
    val id: String,
    val name: String,
    val model: String,
    val endpoint: String,
    val reasoningEffort: String? = null,
    val models: List<ProviderModel> = listOf(ProviderModel(model.ifBlank { DEFAULT_MODEL })),
    val credentialRef: String? = null,
) {
    /** The account [ApiKeyStore] must read/write for this profile. */
    fun credentialAccount(): String =
        credentialRef?.takeIf { it.isNotBlank() } ?: providerCredentialRef(id)

    companion object {
        const val DEFAULT_MODEL: String = "deepseek-flash"

        /** New profiles get their own key account; a migrated row keeps the legacy one. */
        fun providerCredentialRef(id: String): String = "provider.${id.ifBlank { "default" }}"
    }
}

/** One read of the whole provider document. */
internal data class ProviderSnapshot(
    val profiles: List<ProviderRecord>,
    val selectedId: String?,
) {
    /** The explicitly selected profile, or the first one as the document default. */
    val selected: ProviderRecord? get() =
        selectedId?.let { id -> profiles.firstOrNull { it.id == id } } ?: profiles.firstOrNull()

    companion object {
        val EMPTY: ProviderSnapshot = ProviderSnapshot(emptyList(), null)
    }
}

/** What one read of the device record found. */
internal sealed interface ProviderStoreRead {
    /** The host read the store and holds no record (first run, or after 删除). */
    data object Empty : ProviderStoreRead

    /** The stored document; the selected record is kept for legacy callers. */
    data class Stored(
        val record: ProviderRecord,
        val snapshot: ProviderSnapshot = ProviderSnapshot(listOf(record), record.id),
    ) : ProviderStoreRead

    /** The record exists but cannot be read; never treated as "no service". */
    data object Unreadable : ProviderStoreRead
}

/** The outcome of one write gesture; the host turns it into one honest line. */
internal sealed interface ProviderWriteOutcome {
    /** The record is on disk and the next facts read will show it. */
    data object Saved : ProviderWriteOutcome

    /** The record is gone (the page's row falls back to the launch service). */
    data object Deleted : ProviderWriteOutcome

    /**
     * The gesture was refused before anything was written.
     *
     * [reason] is host copy that names the rule (never the value), so the notice
     * bar can say why the tap did not save.
     */
    data class Rejected(val reason: String) : ProviderWriteOutcome

    /** The device store could not be written; nothing was saved. */
    data object Unavailable : ProviderWriteOutcome
}

/**
 * The pure rules the page's draft must satisfy before the host stores it.
 *
 * They live here, not in the page, because they are the *host's* acceptance
 * rules: the page only requires a name and a non-empty endpoint for a new
 * service, and every other validity question is the device's.
 */
internal object ProviderDraftRules {
    /** The one accepted shape: an absolute http(s) URL with a host and no user info. */
    fun endpointRejection(raw: String): String? {
        val text = raw.trim()
        if (text.isEmpty()) return REASON_ENDPOINT
        val uri = try {
            URI(text)
        } catch (_: Exception) {
            return REASON_ENDPOINT
        }
        val scheme = uri.scheme?.lowercase()
        if ((scheme != "http" && scheme != "https") || uri.host.isNullOrEmpty()) {
            return REASON_ENDPOINT
        }
        if (uri.userInfo != null) return REASON_CREDENTIALS
        if (uri.rawQuery != null || uri.rawFragment != null) return REASON_QUERY_FRAGMENT
        if (scheme == "http" && uri.host != LOOPBACK_HOST) return REASON_CLEAR_TEXT
        return null
    }

    /**
     * The key rule [ApiKeyStore] already enforces, checked before the write so a
     * rejected key is a notice rather than an exception.
     */
    fun keyRejection(raw: String): String? {
        val text = raw.trim()
        return if (text.length >= ApiKeyStore.MIN_KEY_LENGTH && text.all { it in '!'..'~' }) {
            null
        } else {
            REASON_KEY
        }
    }

    private const val REASON_ENDPOINT: String = "地址必须是 http(s) 绝对地址，本次未保存"
    private const val REASON_CREDENTIALS: String = "地址不能内嵌用户名或密码，本次未保存"
    private const val REASON_QUERY_FRAGMENT: String = "地址不能包含 query 或 fragment，本次未保存"
    private const val REASON_CLEAR_TEXT: String = "公网模型服务必须使用 HTTPS；HTTP 仅允许 127.0.0.1"
    private const val LOOPBACK_HOST: String = "127.0.0.1"
    private const val REASON_KEY: String = "密钥需至少 8 个可打印 ASCII 字符，本次未保存"
}

/**
 * The provider document, over one properties file under the app's files dir.
 *
 * Version 2 stores one JSON document in the `document` property. Version 1
 * (the old `version=1` + top-level fields) is still readable as one migrated
 * profile. The format is `java.util.Properties` as the container because it
 * escapes the JSON string safely and is plain text a device can inspect; the
 * JSON itself is parsed with the dependency-free [JsonValue].
 *
 * @param file the record; the instrumented/JVM suites pass a temp file, the app
 *   passes `<filesDir>/settings/model-provider.v1.properties`.
 */
internal class ProviderConfigStore(
    private val file: File,
    /**
     * Where a stable failure label goes; the app passes logcat, the JVM suite
     * passes a collector so it can assert the state *and* not touch `android.util.Log`
     * (the unit-test class path has no framework).
     */
    private val log: (String) -> Unit = { message -> Log.w(TAG, message) },
) {

    /** Reads the document; every failure is its own state, never an empty one. */
    fun read(): ProviderStoreRead {
        if (!file.isFile) return ProviderStoreRead.Empty
        val properties = Properties()
        try {
            file.reader(Charsets.UTF_8).use { reader -> properties.load(reader) }
        } catch (error: Exception) {
            log("provider record unreadable: io")
            return ProviderStoreRead.Unreadable
        }
        val version = properties.getProperty(FIELD_VERSION)?.trim()
        val knownProperties = when (version) {
            VERSION_1 -> VERSION_1_FIELDS
            VERSION_2 -> VERSION_2_FIELDS
            else -> return unreadable()
        }
        if (properties.stringPropertyNames().any { it !in knownProperties }) return unreadable()
        return when (version) {
            VERSION_1 -> readVersion1(properties)
            VERSION_2 -> readVersion2(properties)
            else -> unreadable()
        }
    }

    /** The selected record, or `null` when there is none (or it cannot be read). */
    fun current(): ProviderRecord? = snapshot()?.selected

    /** The whole document, or `null` when unreadable or empty. */
    fun snapshot(): ProviderSnapshot? = when (val read = read()) {
        is ProviderStoreRead.Stored -> read.snapshot
        ProviderStoreRead.Empty, ProviderStoreRead.Unreadable -> null
    }

    /**
     * Upserts one validated record. The selected profile is unchanged unless the
     * document had no selection yet; the first write of a migrated document selects
     * the migrated record.
     */
    fun save(record: ProviderRecord, selectAsDefault: Boolean = false): ProviderWriteOutcome {
        val existing = when (val read = read()) {
            is ProviderStoreRead.Stored -> read.snapshot
            ProviderStoreRead.Empty -> ProviderSnapshot.EMPTY
            ProviderStoreRead.Unreadable -> return ProviderWriteOutcome.Rejected(
                "现有模型服务配置无法读取；为避免覆盖，本次未保存",
            )
        }
        val index = existing.profiles.indexOfFirst { it.id == record.id }
        val profiles = existing.profiles.toMutableList().also { list ->
            if (index >= 0) list[index] = record else list += record
        }
        val selected = if (selectAsDefault) record.id
            else existing.selectedId?.takeIf { id -> profiles.any { it.id == id } } ?: record.id
        return write(ProviderSnapshot(profiles, selected))
    }

    /** Makes one existing profile the selected one without changing its fields. */
    fun select(id: String): ProviderWriteOutcome {
        val existing = when (val read = read()) {
            is ProviderStoreRead.Stored -> read.snapshot
            ProviderStoreRead.Empty -> return ProviderWriteOutcome.Rejected("没有可选择的模型服务")
            ProviderStoreRead.Unreadable -> return ProviderWriteOutcome.Rejected("模型服务配置无法读取")
        }
        if (existing.profiles.none { it.id == id }) {
            return ProviderWriteOutcome.Rejected("这个模型服务已经不存在")
        }
        return write(existing.copy(selectedId = id))
    }

    /** Removes the selected profile (the legacy single-row call). */
    fun delete(): ProviderWriteOutcome = current()?.id?.let(::delete) ?: deleteFile()

    /** Removes one profile; a missing profile is already the requested state. */
    fun delete(id: String): ProviderWriteOutcome {
        val existing = when (val read = read()) {
            is ProviderStoreRead.Stored -> read.snapshot
            ProviderStoreRead.Empty -> return ProviderWriteOutcome.Deleted
            ProviderStoreRead.Unreadable -> return ProviderWriteOutcome.Rejected("模型服务配置无法读取")
        }
        val profiles = existing.profiles.filterNot { it.id == id }
        if (profiles.isEmpty()) return deleteFile()
        val selected = existing.selectedId?.takeIf { current -> profiles.any { it.id == current } }
            ?: profiles.first().id
        return write(ProviderSnapshot(profiles, selected))
    }

    private fun readVersion1(properties: Properties): ProviderStoreRead {
        val record = ProviderRecord(
            id = properties.getProperty(FIELD_ID).orEmpty().trim(),
            name = properties.getProperty(FIELD_NAME).orEmpty().trim(),
            model = properties.getProperty(FIELD_MODEL).orEmpty().trim(),
            endpoint = properties.getProperty(FIELD_ENDPOINT).orEmpty().trim(),
            // The legacy key account is the one the old single-service store used.
            credentialRef = ApiKeyStore.ACCOUNT,
        )
        return validateOne(record)?.let {
            ProviderStoreRead.Stored(it, ProviderSnapshot(listOf(it), it.id))
        } ?: unreadable()
    }

    private fun readVersion2(properties: Properties): ProviderStoreRead {
        val raw = properties.getProperty(FIELD_DOCUMENT) ?: return unreadable()
        val root = try {
            JsonValue.parse(raw) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return unreadable()
        if (root.members.keys.any { it !in ROOT_FIELDS }) return unreadable()
        if ((root["version"] as? JsonNumber)?.asLongOrNull() != VERSION_2.toLong()) return unreadable()
        val selected = when (val rawSelected = root["selectedId"]) {
            JsonNull -> null
            is JsonString -> rawSelected.value.takeIf(String::isNotBlank) ?: return unreadable()
            else -> return unreadable()
        }
        val rawProfiles = root["profiles"] as? JsonArray ?: return unreadable()
        val profiles = ArrayList<ProviderRecord>(rawProfiles.values.size)
        for (value in rawProfiles.values) {
            val row = value as? JsonObject ?: return unreadable()
            if (row.members.keys.any { it !in PROFILE_FIELDS }) return unreadable()
            val id = (row["id"] as? JsonString)?.value?.trim()?.takeIf(String::isNotEmpty)
                ?: return unreadable()
            val name = (row["name"] as? JsonString)?.value?.trim()?.takeIf(String::isNotEmpty)
                ?: return unreadable()
            val model = (row["model"] as? JsonString)?.value ?: return unreadable()
            val endpoint = (row["endpoint"] as? JsonString)?.value ?: return unreadable()
            val reasoning = when (val field = row["reasoningEffort"]) {
                null, JsonNull -> null
                is JsonString -> field.value.trim().takeIf(String::isNotEmpty)
                else -> return unreadable()
            }
            val credentialRef = when (val field = row["credentialRef"]) {
                null, JsonNull -> null
                is JsonString -> field.value.trim().takeIf(String::isNotEmpty)
                else -> return unreadable()
            }
            val rawModels = row["models"] as? JsonArray ?: return unreadable()
            if (rawModels.values.isEmpty()) return unreadable()
            val models = ArrayList<ProviderModel>(rawModels.values.size)
            for (modelValue in rawModels.values) {
                val modelRow = modelValue as? JsonObject ?: return unreadable()
                if (modelRow.members.keys.any { it !in MODEL_FIELDS }) return unreadable()
                val modelId = (modelRow["id"] as? JsonString)?.value?.trim()?.takeIf(String::isNotEmpty)
                    ?: return unreadable()
                val modelName = when (val field = modelRow["name"]) {
                    null, JsonNull -> null
                    is JsonString -> field.value.trim().takeIf(String::isNotEmpty)
                    else -> return unreadable()
                }
                val contextWindow = when (val field = modelRow["contextWindow"]) {
                    null, JsonNull -> null
                    is JsonNumber -> {
                        val number = field.asLongOrNull()?.takeIf { it in 1..Int.MAX_VALUE.toLong() }
                            ?: return unreadable()
                        number.toInt()
                    }
                    else -> return unreadable()
                }
                val maxTokens = when (val field = modelRow["maxTokens"]) {
                    null, JsonNull -> null
                    is JsonNumber -> {
                        val number = field.asLongOrNull()?.takeIf { it in 1..Int.MAX_VALUE.toLong() }
                            ?: return unreadable()
                        number.toInt()
                    }
                    else -> return unreadable()
                }
                val textInput = (modelRow["textInput"] as? JsonBool)?.value ?: return unreadable()
                val imageInput = (modelRow["imageInput"] as? JsonBool)?.value ?: return unreadable()
                if (!textInput && !imageInput) return unreadable()
                val effort = when (val field = modelRow["reasoningEffort"]) {
                    null, JsonNull -> null
                    is JsonString -> field.value.trim().takeIf(String::isNotEmpty)
                    else -> return unreadable()
                }
                models += ProviderModel(
                    id = modelId,
                    name = modelName,
                    contextWindow = contextWindow,
                    maxTokens = maxTokens,
                    textInput = textInput,
                    imageInput = imageInput,
                    reasoningEffort = effort,
                )
            }
            val record = ProviderRecord(
                id = id,
                name = name,
                model = model,
                endpoint = endpoint,
                reasoningEffort = reasoning,
                models = models,
                credentialRef = credentialRef,
            )
            profiles += validateOne(record) ?: return unreadable()
        }
        if (profiles.isEmpty()) {
            if (selected != null) return unreadable()
            return ProviderStoreRead.Empty
        }
        if (profiles.map { it.id }.distinct().size != profiles.size) return unreadable()
        val selectedId = selected ?: return unreadable()
        val selectedRecord = profiles.firstOrNull { it.id == selectedId } ?: return unreadable()
        return ProviderStoreRead.Stored(selectedRecord, ProviderSnapshot(profiles, selectedId))
    }

    private fun validateOne(record: ProviderRecord): ProviderRecord? {
        if (record.id.isEmpty() || record.name.isEmpty()) return null
        if (ProviderDraftRules.endpointRejection(record.endpoint) != null) return null
        return record.copy(
            model = record.model.trim(),
            models = record.models.ifEmpty {
                listOf(ProviderModel(record.model.ifBlank { ProviderRecord.DEFAULT_MODEL }))
            },
        )
    }

    private fun write(snapshot: ProviderSnapshot): ProviderWriteOutcome {
        val payload = Properties()
        payload.setProperty(FIELD_VERSION, VERSION_2)
        payload.setProperty(FIELD_DOCUMENT, encode(snapshot))
        return write(payload)
    }

    private fun deleteFile(): ProviderWriteOutcome = try {
        if (file.isFile && !file.delete()) {
            ProviderWriteOutcome.Unavailable
        } else {
            ProviderWriteOutcome.Deleted
        }
    } catch (error: Exception) {
        log("provider record delete failed")
        ProviderWriteOutcome.Unavailable
    }

    private fun write(payload: Properties): ProviderWriteOutcome {
        val parent = file.parentFile
        if (parent != null && !parent.isDirectory && !parent.mkdirs()) {
            log("provider record directory not writable")
            return ProviderWriteOutcome.Unavailable
        }
        return try {
            val temporary = File(parent, file.name + SUFFIX_TEMPORARY)
            temporary.writer(Charsets.UTF_8).use { writer -> payload.store(writer, null) }
            if (!temporary.renameTo(file)) {
                temporary.delete()
                log("provider record rename failed")
                ProviderWriteOutcome.Unavailable
            } else {
                ProviderWriteOutcome.Saved
            }
        } catch (error: Exception) {
            log("provider record write failed")
            ProviderWriteOutcome.Unavailable
        }
    }

    private fun unreadable(): ProviderStoreRead {
        log("provider record unreadable: content")
        return ProviderStoreRead.Unreadable
    }

    private fun encode(snapshot: ProviderSnapshot): String = JsonObject(
        linkedMapOf(
            "version" to JsonNumber(VERSION_2),
            "selectedId" to (snapshot.selectedId?.let(::JsonString) ?: JsonNull),
            "profiles" to JsonArray(snapshot.profiles.map { record ->
                JsonObject(
                    linkedMapOf(
                        "id" to JsonString(record.id),
                        "name" to JsonString(record.name),
                        "model" to JsonString(record.model),
                        "endpoint" to JsonString(record.endpoint),
                        "reasoningEffort" to (record.reasoningEffort?.let(::JsonString) ?: JsonNull),
                        "credentialRef" to (record.credentialRef?.let(::JsonString) ?: JsonNull),
                        "models" to JsonArray(record.models.map { model ->
                            JsonObject(
                                linkedMapOf(
                                    "id" to JsonString(model.id),
                                    "name" to (model.name?.let(::JsonString) ?: JsonNull),
                                    "contextWindow" to (model.contextWindow?.let { JsonNumber(it.toString()) } ?: JsonNull),
                                    "maxTokens" to (model.maxTokens?.let { JsonNumber(it.toString()) } ?: JsonNull),
                                    "textInput" to JsonBool(model.textInput),
                                    "imageInput" to JsonBool(model.imageInput),
                                    "reasoningEffort" to (model.reasoningEffort?.let(::JsonString) ?: JsonNull),
                                ),
                            )
                        }),
                    ),
                )
            }),
        ),
    ).toJsonString()

    companion object {
        /** The stable, token-free log tag. */
        const val TAG: String = "PDSHProvider"

        private const val FIELD_VERSION: String = "version"
        private const val FIELD_ID: String = "id"
        private const val FIELD_NAME: String = "name"
        private const val FIELD_MODEL: String = "model"
        private const val FIELD_ENDPOINT: String = "endpoint"
        private const val FIELD_DOCUMENT: String = "document"
        private const val VERSION_1: String = "1"
        private const val VERSION_2: String = "2"
        private val VERSION_1_FIELDS = setOf(FIELD_VERSION, FIELD_ID, FIELD_NAME, FIELD_MODEL, FIELD_ENDPOINT)
        private val VERSION_2_FIELDS = setOf(FIELD_VERSION, FIELD_DOCUMENT)
        private val ROOT_FIELDS = setOf("version", "selectedId", "profiles")
        private val PROFILE_FIELDS = setOf(
            "id", "name", "model", "endpoint", "reasoningEffort", "credentialRef", "models",
        )
        private val MODEL_FIELDS = setOf(
            "id", "name", "contextWindow", "maxTokens", "textInput", "imageInput", "reasoningEffort",
        )
        private const val SUFFIX_TEMPORARY: String = ".tmp"

        /** The file name under `<filesDir>/settings`; also the test's temp name. */
        const val FILE_NAME: String = "settings/model-provider.v1.properties"

        private val installed = AtomicReference<ProviderConfigStore?>(null)

        /**
         * Binds the process-wide record to [context]'s files dir.
         *
         * Idempotent, like [ApiKeyStore.install]: a second Activity or a
         * configuration change must not replace the store under a running engine.
         */
        @Synchronized
        fun install(context: Context): ProviderConfigStore {
            installed.get()?.let { return it }
            val created = ProviderConfigStore(File(context.applicationContext.filesDir, FILE_NAME))
            installed.set(created)
            return created
        }

        /** The installed store, or `null` before the composition root ran. */
        fun active(): ProviderConfigStore? = installed.get()

        /** The draft fields the host stores; shared by the save caller and its tests. */
        fun recordOf(
            draft: ProviderDraft,
            previous: ProviderRecord?,
            launchEndpoint: String?,
            launchModel: String,
        ): ProviderRecord {
            val id = draft.id.trim().ifEmpty {
                if (draft.isNew) UUID.randomUUID().toString().lowercase() else previous?.id ?: DEFAULT_ID
            }
            val modelName = draft.model.trim().ifEmpty { previous?.model ?: launchModel }
            val models = draft.models.mapNotNull { model ->
                val modelId = model.id.trim()
                if (modelId.isEmpty()) return@mapNotNull null
                ProviderModel(
                    id = modelId,
                    name = model.name?.trim()?.takeIf { it.isNotEmpty() },
                    contextWindow = model.contextWindow,
                    maxTokens = model.maxTokens,
                    textInput = model.textInput,
                    imageInput = model.imageInput,
                    reasoningEffort = model.reasoningEffort?.trim()?.takeIf { it.isNotEmpty() },
                )
            }.ifEmpty { listOf(ProviderModel(modelName)) }
            return ProviderRecord(
                id = id,
                name = draft.name.trim(),
                model = modelName,
                endpoint = draft.endpoint.trim().ifEmpty {
                    previous?.endpoint ?: launchEndpoint.orEmpty()
                },
                reasoningEffort = draft.reasoningEffort?.trim()?.takeIf { it.isNotEmpty() },
                models = models,
                credentialRef = if (draft.isNew) ProviderRecord.providerCredentialRef(id)
                    else previous?.credentialRef ?: ProviderRecord.providerCredentialRef(id),
            )
        }

        /** The id the one row gets when the person left the field blank. */
        const val DEFAULT_ID: String = "local"
    }
}
