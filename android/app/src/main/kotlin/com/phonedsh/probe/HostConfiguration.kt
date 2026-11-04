// The live DSH configuration reads/writes behind NativeConfigurationPage.
// SPDX-License-Identifier: MIT
//
// The page is a pure function of facts; this file is the host half. It performs
// the same four independent reads as iOS `NativeConfigurationModel.refresh`
// (settings/describe, pluginInventory/list, session/modelCatalog,
// permissionPresets/catalog), keeps their partial failures separate, and writes
// through settings/update or settings/mutate with the namespace revision as a
// CAS guard. No value is invented: a failed read clears only its own section.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.dsh.turn.DshTurnClient
import com.phonedsh.ui.page.ConfigurationExperimentalPlugin
import com.phonedsh.ui.page.ConfigurationFacts
import com.phonedsh.ui.page.ConfigurationField
import com.phonedsh.ui.page.ConfigurationFieldKind
import com.phonedsh.ui.page.ConfigurationGroup
import com.phonedsh.ui.page.ConfigurationModelRoute
import com.phonedsh.ui.page.ConfigurationPermissionMode
import com.phonedsh.ui.page.ConfigurationPlugin
import com.phonedsh.ui.page.ConfigurationSnapshot
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.UiStrings
import java.math.BigDecimal
import kotlinx.coroutines.async
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope

/** One settings namespace exactly as `settings/describe` reported it. */
internal data class NamespaceDescriptor(
    val ns: String,
    val revision: Int?,
    val value: JsonObject?,
    val base: JsonObject?,
    val user: JsonObject?,
    val properties: JsonObject?,
)

/** Fields the iOS configuration model actually admits from `settings/describe`. */
internal val CONFIGURATION_FIELD_ALLOWLIST: Map<String, List<String>> = linkedMapOf(
    "subagent" to listOf("maxDepth", "maxActiveSubagents"),
    SUBAGENT_MODEL_NS to listOf("enabled", "allowedModels"),
    "agent-loop" to listOf("maxParallelToolCalls"),
    "bash-sandbox" to listOf("timeoutMs", "maxOutputBytes"),
)

/**
 * Reads all four DSH sources concurrently and projects them into the page facts.
 * Each read has its own failure field, so one unavailable source does not erase
 * the others.
 */
internal suspend fun readConfigurationFacts(
    client: DshTurnClient,
): ConfigurationFacts = coroutineScope {
    val settings = async { readConfigurationSource { client.call("settings/describe", timeoutMillis = 5_000) } }
    val inventory = async { readConfigurationSource { client.call("pluginInventory/list", timeoutMillis = 5_000) } }
    val catalog = async { readConfigurationSource { client.call("session/modelCatalog", timeoutMillis = 5_000) } }
    val permissions = async { readConfigurationSource { client.call("permissionPresets/catalog", timeoutMillis = 5_000) } }

    val settingsResult = settings.await()
    val inventoryResult = inventory.await()
    val catalogResult = catalog.await()
    val permissionsResult = permissions.await()

    val settingsRoot = settingsResult.getOrNull() as? JsonObject
    val writable = (settingsRoot?.bool("writable") ?: false)
    val namespaces = (settingsRoot?.get("namespaces") as? JsonArray)?.values.orEmpty()
        .mapNotNull(::namespaceOf)
    val groups = buildGroups(namespaces, writable)
    val settingsError = settingsResult.exceptionOrNull()?.userMessage()

    val inventoryRoot = inventoryResult.getOrNull() as? JsonObject
    val entries = (inventoryRoot?.get("entries") as? JsonArray)?.values.orEmpty().mapNotNull { value ->
        val row = value as? JsonObject ?: return@mapNotNull null
        val id = row.text("entryId") ?: return@mapNotNull null
        val module = row.text("moduleName") ?: return@mapNotNull null
        ConfigurationPlugin(
            id = id,
            module = module,
            enabled = if (row.bool("enabled")) FactState.YES else FactState.NO,
            phase = row.text("fiberPhase"),
        )
    }
    val inventoryError = inventoryResult.exceptionOrNull()?.userMessage()

    val catalogRoot = catalogResult.getOrNull() as? JsonObject
    val routes = (catalogRoot?.get("groups") as? JsonArray)?.values.orEmpty().flatMap { groupValue ->
        val group = groupValue as? JsonObject ?: return@flatMap emptyList()
        val provider = group.text("id") ?: return@flatMap emptyList()
        val providerName = group.text("name") ?: provider
        (group["models"] as? JsonArray)?.values.orEmpty().mapNotNull { modelValue ->
            val model = modelValue as? JsonObject ?: return@mapNotNull null
            val id = model.text("id") ?: return@mapNotNull null
            ConfigurationModelRoute(
                provider = provider,
                providerName = providerName,
                model = id,
                modelName = model.text("name") ?: id,
                available = true,
            )
        }
    }.toMutableList()
    val savedRoutes = namespaces.firstOrNull { it.ns == SUBAGENT_MODEL_NS }
        ?.value?.get("allowedModels") as? JsonArray
    val availableIds = routes.map { "${it.provider}/${it.model}" }.toSet()
    savedRoutes?.values.orEmpty().forEach { rowValue ->
        val row = rowValue as? JsonObject ?: return@forEach
        val provider = row.text("provider") ?: return@forEach
        val model = row.text("model") ?: return@forEach
        if ("$provider/$model" !in availableIds) {
            routes += ConfigurationModelRoute(provider, provider, model, model, available = false)
        }
    }
    val catalogError = catalogResult.exceptionOrNull()?.userMessage()

    val permissionsRoot = permissionsResult.getOrNull() as? JsonObject
    val modes = (permissionsRoot?.get("defaultOptions") as? JsonArray)?.values.orEmpty().mapNotNull { value ->
        val row = value as? JsonObject ?: return@mapNotNull null
        val id = row.text("value") ?: return@mapNotNull null
        ConfigurationPermissionMode(
            id = id,
            name = row.text("name") ?: id,
            detail = row.text("description"),
        )
    }
    val selectedMode = permissionsRoot?.text("defaultPreset")
    val permissionError = permissionsResult.exceptionOrNull()?.userMessage()

    val selectedSubagentModels = namespaces.firstOrNull { it.ns == SUBAGENT_MODEL_NS }
        ?.value?.get(ALLOWED_MODELS_FIELD)?.let(::modelSelectionIds)

    ConfigurationFacts(
        snapshot = ConfigurationSnapshot(
            settingsWritable = when {
                settingsRoot == null -> FactState.UNKNOWN
                writable -> FactState.YES
                else -> FactState.NO
            },
            groups = if (settingsRoot == null) null else groups,
            permissionModes = if (permissionsRoot == null) null else modes,
            defaultPermissionModeId = selectedMode,
            plugins = if (inventoryRoot == null) null else entries,
            experimentalPlugins = if (inventoryRoot == null) null else experimentalPlugins(entries),
            pluginManagementMessage = UiStrings.PLUGIN_INVENTORY_MANAGEMENT_NOTICE,
            settingsFailure = settingsError,
            inventoryFailure = inventoryError,
            permissionFailure = permissionError,
            modelRoutes = if (catalogRoot == null) null else routes,
            modelCatalogFailure = catalogError,
            permissionRevision = namespaces.firstOrNull { it.ns == "permission" }?.revision,
            selectedSubagentModelIds = selectedSubagentModels,
        ),
    )
}

/** Capture one source independently without converting caller cancellation into read failure. */
internal suspend fun readConfigurationSource(read: suspend () -> JsonValue): Result<JsonValue> = try {
    Result.success(read())
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (failure: Exception) {
    Result.failure(failure)
}

/** Writes one namespace patch, guarded by the revision the page last read. */
internal suspend fun saveConfigurationGroup(
    client: DshTurnClient,
    namespace: String,
    patch: Map<String, String>,
    expectedRevision: Int,
    kinds: Map<String, ConfigurationFieldKind>,
): String? = try {
    val body = JsonObject(
        linkedMapOf(
            "ns" to JsonString(namespace),
            "patch" to JsonObject(patch.mapValues { (key, raw) ->
                configurationPatchValue(kinds[key] ?: error("field is not allowlisted"), raw)
                    ?: error("field value is invalid")
            }),
            "expectedRevision" to JsonNumber(expectedRevision.toString()),
        ),
    )
    client.call("settings/update", body, timeoutMillis = 5_000)
    null
} catch (failure: Exception) {
    failure.userMessage()
}

/** Resets one overridden field to its DSH default with the revision CAS. */
internal suspend fun resetConfigurationField(
    client: DshTurnClient,
    namespace: String,
    field: String,
    expectedRevision: Int,
): String? = try {
    client.call(
        "settings/mutate",
        JsonObject(
            linkedMapOf(
                "ns" to JsonString(namespace),
                "ops" to JsonArray(
                    listOf(
                        JsonObject(
                            linkedMapOf(
                                "op" to JsonString("unset"),
                                "path" to JsonArray(listOf(JsonString(field))),
                            ),
                        ),
                    ),
                ),
                "expectedRevision" to JsonNumber(expectedRevision.toString()),
            ),
        ),
        timeoutMillis = 5_000,
    )
    null
} catch (failure: Exception) {
    failure.userMessage()
}

/** Saves the new-session permission default through the permission namespace CAS. */
internal suspend fun saveDefaultPermissionMode(
    client: DshTurnClient,
    modeId: String,
    expectedRevision: Int,
): String? = try {
    client.call(
        "settings/update",
        JsonObject(
            linkedMapOf(
                "ns" to JsonString("permission"),
                "patch" to JsonObject(mapOf("defaultPreset" to JsonString(modeId))),
                "expectedRevision" to JsonNumber(expectedRevision.toString()),
            ),
        ),
        timeoutMillis = 5_000,
    )
    null
} catch (failure: Exception) {
    failure.userMessage()
}

private fun namespaceOf(value: JsonValue): NamespaceDescriptor? {
    val row = value as? JsonObject ?: return null
    val ns = row.text("ns") ?: return null
    return NamespaceDescriptor(
        ns = ns,
        revision = (row["revision"] as? JsonNumber)?.asLongOrNull()?.toInt(),
        value = row["value"] as? JsonObject,
        base = row["base"] as? JsonObject,
        user = row["user"] as? JsonObject,
        properties = (row["schema"] as? JsonObject)?.get("properties") as? JsonObject,
    )
}

internal fun buildGroups(
    namespaces: List<NamespaceDescriptor>,
    writable: Boolean,
): List<ConfigurationGroup> {
    val byName = namespaces.associateBy { it.ns }
    return GROUP_ORDER.map { (ns, title, detail) ->
        val descriptor = byName[ns]
        val revision = descriptor?.revision
        val fields = descriptor?.let(::fieldsOf)
        ConfigurationGroup(
            namespace = ns,
            title = title,
            detail = detail.ifEmpty { null },
            writable = when {
                !writable -> FactState.NO
                descriptor == null || revision == null -> FactState.UNKNOWN
                else -> FactState.YES
            },
            fields = fields,
            revision = revision,
        )
    }
}

private fun fieldsOf(descriptor: NamespaceDescriptor): List<ConfigurationField> {
    val properties = descriptor.properties ?: JsonObject(emptyMap())
    val value = descriptor.value
    val base = descriptor.base
    val user = descriptor.user
    return configurationFields(descriptor.ns, value, base, user, properties)
}

/** Applies the source field allowlist and uses only DSH's effective value. */
internal fun configurationFields(
    namespace: String,
    value: JsonObject?,
    base: JsonObject?,
    user: JsonObject?,
    properties: JsonObject,
): List<ConfigurationField> {
    val allowed = CONFIGURATION_FIELD_ALLOWLIST[namespace] ?: return emptyList()
    return allowed.mapNotNull { key ->
        // `settings/describe.value` is the effective setting. Base defaults and
        // user overrides are provenance only and must not stand in for a missing
        // effective value, exactly as NativeConfigurationModel.fields(in:) does.
        val current = value?.get(key) ?: return@mapNotNull null
        val schema = properties[key] as? JsonObject
        val scalar = current is JsonBool || current is JsonNumber || current is JsonString || current == JsonNull
        val kind = when {
            namespace == SUBAGENT_MODEL_NS && key == ALLOWED_MODELS_FIELD && current is JsonArray ->
                ConfigurationFieldKind.MODEL_SELECTION
            schema == null && scalar -> ConfigurationFieldKind.READ_ONLY
            current is JsonBool && schema?.text("type") == "boolean" -> ConfigurationFieldKind.TOGGLE
            current is JsonNumber && schema?.text("type") in setOf("number", "integer") ->
                ConfigurationFieldKind.NUMBER
            current is JsonString && schema?.text("type") == "string" -> ConfigurationFieldKind.TEXT
            scalar -> ConfigurationFieldKind.READ_ONLY
            // The allowlisted source field remains visible, but a structured or
            // type-mismatched value is never stringified into the UI or an editor.
            else -> return@mapNotNull null
        }
        ConfigurationField(
            id = key,
            title = FIELD_TITLES[key] ?: schema?.text("title") ?: key,
            value = displayValue(current),
            detail = schema?.text("description"),
            overridden = user?.get(key) != null && user[key] != base?.get(key),
            kind = kind,
            options = emptyList(),
            rawValue = current.toJsonString(),
        )
    }
}

/** Converts one allowlisted field's staged text back to its schema-supported wire value. */
internal fun configurationPatchValue(
    kind: ConfigurationFieldKind,
    raw: String,
): JsonValue? = when (kind) {
    ConfigurationFieldKind.TOGGLE -> when (raw) {
        "true" -> JsonBool(true)
        "false" -> JsonBool(false)
        else -> null
    }
    ConfigurationFieldKind.NUMBER -> runCatching { JsonNumber(raw.trim()) }.getOrNull()
    ConfigurationFieldKind.TEXT -> JsonString(raw)
    ConfigurationFieldKind.MODEL_SELECTION -> runCatching {
        (JsonValue.parse(raw) as? JsonArray)?.also { array ->
            require(array.values.all { rowValue ->
                val row = rowValue as? JsonObject ?: return@all false
                row.text("provider") != null && row.text("model") != null
            })
        } ?: error("model route selection is malformed")
    }.getOrNull()
    ConfigurationFieldKind.ENUM, ConfigurationFieldKind.READ_ONLY -> null
}

/** True only when every patched field was returned with the requested effective value. */
internal fun configurationPatchMatches(
    group: ConfigurationGroup?,
    patch: Map<String, String>,
    kinds: Map<String, ConfigurationFieldKind>,
): Boolean {
    if (group == null || patch.isEmpty()) return false
    val fields = group.fields?.associateBy { it.id } ?: return false
    return patch.all { (id, raw) ->
        val kind = kinds[id] ?: return@all false
        val expected = configurationPatchValue(kind, raw) ?: return@all false
        val stored = fields[id]?.rawValue ?: return@all false
        val actual = runCatching { JsonValue.parse(stored) }.getOrNull() ?: return@all false
        when (kind) {
            ConfigurationFieldKind.MODEL_SELECTION -> modelSelectionIds(expected) == modelSelectionIds(actual)
            ConfigurationFieldKind.NUMBER -> {
                val expectedNumber = (expected as? JsonNumber)?.raw?.let { runCatching { BigDecimal(it) }.getOrNull() }
                val actualNumber = (actual as? JsonNumber)?.raw?.let { runCatching { BigDecimal(it) }.getOrNull() }
                expectedNumber != null && actualNumber != null && expectedNumber.compareTo(actualNumber) == 0
            }
            else -> expected.toJsonString() == actual.toJsonString()
        }
    }
}

internal fun configurationPatchModelIds(raw: String): Set<String>? =
    runCatching { JsonValue.parse(raw) }.getOrNull()?.let(::modelSelectionIds)

private fun modelSelectionIds(value: JsonValue): Set<String>? = (value as? JsonArray)?.values?.mapNotNull { rowValue ->
    val row = rowValue as? JsonObject ?: return@mapNotNull null
    val provider = row.text("provider") ?: return@mapNotNull null
    val model = row.text("model") ?: return@mapNotNull null
    "$provider/$model"
}?.toSet()

private fun experimentalPlugins(entries: List<ConfigurationPlugin>): List<ConfigurationExperimentalPlugin> =
    EXPERIMENTAL.map { (id, title, module) ->
        val entry = entries.firstOrNull { it.module == module || it.module.startsWith("$module/") }
        val loaded = entry?.enabled == FactState.YES && entry.phase == "active"
        ConfigurationExperimentalPlugin(
            id = id,
            title = title,
            status = if (loaded) {
                "Worker 当前已加载 · ${entry?.phase ?: "active"}"
            } else {
                "Worker 未加载；安装/启用不能从此手机页面执行。"
            },
            loaded = if (loaded) FactState.YES else FactState.NO,
        )
    }

private fun displayValue(value: JsonValue): String = when (value) {
    is JsonBool -> if (value.value) "开启" else "关闭"
    is JsonNumber -> value.raw
    is JsonString -> value.value
    JsonNull -> ""
    else -> value.toJsonString()
}

private fun JsonValue.textOrNull(): String? = when (this) {
    is JsonString -> value
    is JsonNumber -> raw
    is JsonBool -> if (value) "true" else "false"
    else -> null
}

private fun JsonObject.text(name: String): String? = (this[name] as? JsonString)?.value
private fun JsonObject.bool(name: String): Boolean = (this[name] as? JsonBool)?.value == true

private fun Throwable.userMessage(): String =
    message?.substringBefore('\n')?.take(180) ?: javaClass.simpleName

private const val SUBAGENT_MODEL_NS: String = "subagent-model-selection-settings"

private const val ALLOWED_MODELS_FIELD: String = "allowedModels"

private val GROUP_ORDER: List<Triple<String, String, String>> = listOf(
    Triple("subagent", "子 Agent", "控制 DSH 子 Agent 的递归深度和并发容量。"),
    Triple("subagent-model-selection-settings", "子 Agent 模型", "设置子 Agent 可使用的模型路由。"),
    Triple("agent-loop", "Agent 循环", "限制单步并行执行的安全工具调用数。"),
    Triple("bash-sandbox", "终端", "调整 DSH Bash 执行器的时限和输出预算。"),
)

private val FIELD_TITLES: Map<String, String> = mapOf(
    "maxDepth" to "最大递归层级",
    "maxActiveSubagents" to "最大并发子 Agent",
    "enabled" to "允许子 Agent 选择模型",
    "allowedModels" to "允许的子 Agent 模型",
    "maxParallelToolCalls" to "并行工具调用上限",
    "timeoutMs" to "单条命令时限（毫秒）",
    "maxOutputBytes" to "每路输出上限（字节）",
)

private val EXPERIMENTAL: List<Triple<String, String, String>> = listOf(
    Triple("agent-team", "智能体团队", "@deepseek-ai/dsh-experimental-agent-team-profile"),
    Triple("voice-input", "语音输入", "@deepseek-ai/dsh-experimental-voice-input-bundle"),
    Triple("auto-review", "自动授权审查", "@deepseek-ai/dsh-experimental-auto-review"),
    Triple("developer-tools", "开发者工具", "@deepseek-ai/dsh-client-ui-settings-general"),
)
