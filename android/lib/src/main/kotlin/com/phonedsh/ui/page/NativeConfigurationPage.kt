// Session configuration: the built-in settings groups, permissions and plugins.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row NativeConfigurationPage (会话级与插件配置;
// entry: 页头 `⋯` → 本会话设置; exit: sheet), §3.1 (the ScreenState layer) and
// §5 (`insets`).
//
// The page has no harness event anchor. Every group, field, permission mode and
// plugin entry is a host read, so §3.1 rule 3 makes the read-only snapshot the
// UiState-side input and `from(snapshot, local)` a pure function. The page stages
// local edits; the host applies them through DSH's revision-guarded settings API
// and returns a request-bound receipt before the page clears a draft.
//
// The states that look alike are kept apart:
//   * a snapshot with no reported content is the empty state;
//   * an unreported snapshot is 未知, never "no settings" and never `0 个条目`;
//   * a failed read is 失败 and drops every value claim;
//   * inside a group, a null field list is 设置项未知, while an empty list is
//     这个分组没有设置项. Inside the plugin inventory the same split holds for
//     the plugin list and the experimental-plugin list.
//
// The source is a pushed page with an inline title and two trailing toolbar
// actions (插件说明 / 刷新; `NativeConfigurationPage.swift:35-53`). 插件说明 opens
// its own medium/large sheet (`:55-77`), and 已加载插件 is a link to the inventory
// subpage (`NativeConfigurationPage.swift:324-335`).
// The toolbar capsules, glyphs, warning line and globe live in their shared
// surface components, with the page geometry that justifies their shape.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`, toolbar capsule
// inset/elevation, and `pageListGap`). The header, section header and InfoRow
// floors live in `PageScaffold.kt`/`SettingsChrome.kt`; no signature-surface
// geometry is reused in this file.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.background
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.sheet.PdshSheet
import com.phonedsh.ui.sheet.SheetBackHost
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.surface.GlobeGlyph
import com.phonedsh.ui.surface.InfoCircleGlyph
import com.phonedsh.ui.surface.PageBarCapsule
import com.phonedsh.ui.surface.RefreshGlyph
import com.phonedsh.ui.surface.SettingsFormRow
import com.phonedsh.ui.surface.SettingsNavBar
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSectionHeader
import com.phonedsh.ui.surface.WarningLine
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * One settings field as the host reported it.
 *
 * @param id the host's stable field id.
 * @param title the field label.
 * @param value the host-formatted value; `null` means the host did not report
 *   it, which renders 未知 rather than a default.
 * @param detail the host's own explanation line, if any.
 * @param overridden whether the host says this value is a user override.
 */
/** The control a schema field needs; the page never guesses from its text. */
public enum class ConfigurationFieldKind { TOGGLE, NUMBER, TEXT, ENUM, MODEL_SELECTION, READ_ONLY }

@Immutable
public data class ConfigurationField(
    public val id: String,
    public val title: String,
    public val value: String? = null,
    public val detail: String? = null,
    public val overridden: Boolean = false,
    public val kind: ConfigurationFieldKind = ConfigurationFieldKind.READ_ONLY,
    public val options: List<String> = emptyList(),
    /** The exact JSON value the host read, used to seed the editor without guessing. */
    public val rawValue: String? = null,
)

/**
 * One built-in settings group.
 *
 * @param namespace the host's namespace key (for example `agent-loop`).
 * @param title the group title.
 * @param detail the group's own description.
 * @param writable whether the host says this group can be edited.
 * @param fields the fields; `null` means unread, `emptyList()` means the group
 *   really has no field.
 */
@Immutable
public data class ConfigurationGroup(
    public val namespace: String,
    public val title: String,
    public val detail: String? = null,
    public val writable: FactState = FactState.UNKNOWN,
    public val fields: List<ConfigurationField>? = null,
    /** Namespace revision the write CAS must quote. */
    public val revision: Int? = null,
)

/** One permission preset the host can assign to new sessions. */
@Immutable
public data class ConfigurationPermissionMode(
    public val id: String,
    public val name: String,
    public val detail: String? = null,
)

/** One DSH Loader plugin entry. */
@Immutable
public data class ConfigurationPlugin(
    public val id: String,
    public val module: String,
    public val enabled: FactState = FactState.UNKNOWN,
    public val phase: String? = null,
)

/** One model route the host advertised for sub-agent selection. */
@Immutable
public data class ConfigurationModelRoute(
    public val provider: String,
    public val providerName: String,
    public val model: String,
    public val modelName: String,
    public val available: Boolean = true,
) {
    public val id: String get() = "$provider/$model"
}

/** One experimental plugin row; `loaded` is a three-valued fact. */
@Immutable
public data class ConfigurationExperimentalPlugin(
    public val id: String,
    public val title: String,
    public val status: String? = null,
    public val loaded: FactState = FactState.UNKNOWN,
)

/**
 * The permission presets the host reported, and which one new sessions get.
 *
 * @param modes the presets; `null` means the catalog was not read.
 * @param selected the preset the host says is the current default, if any.
 * @param failure the catalog read's own failure message, if it failed.
 * @param writable whether this one field can be written; the provider-wide
 *   `settingsWritable` is not enough for a value pinned by the phone image's
 *   startup home patch.
 * @param readOnlyReason why the picker is disabled, when the host measured a lock.
 */
@Immutable
public data class ConfigurationPermissionView(
    public val modes: List<ConfigurationPermissionMode>? = null,
    public val selected: ConfigurationPermissionMode? = null,
    public val failure: String? = null,
    public val revision: Int? = null,
    public val writable: Boolean = false,
    public val readOnlyReason: String? = null,
) {
    /** True when the host did not report the catalog: the page says 未知. */
    public val isUnknown: Boolean get() = modes == null

    /** True when the host reported a catalog with no preset in it. */
    public val isEmpty: Boolean get() = modes != null && modes.isEmpty()
}

/**
 * The host's read-only configuration snapshot.
 *
 * @param sessionTitle the session this sheet configures, when resolved.
 * @param settingsWritable whether the host accepts a settings write.
 * @param groups the built-in groups; `null` means the read failed or did not run.
 * @param permissionModes the available presets; `null` means unread.
 * @param defaultPermissionModeId the current preset id, if any.
 * @param plugins the DSH Loader entries; `null` means unread.
 * @param experimentalPlugins the experimental-plugin rows; `null` means unread.
 * @param pluginManagementMessage the host's own explanation of what the phone
 *   can and cannot do with plugins.
 * @param settingsFailure a failure specific to the settings read.
 * @param inventoryFailure a failure specific to the plugin-inventory read.
 * @param permissionFailure a failure specific to the permission catalog read.
 */
@Immutable
public data class ConfigurationSnapshot(
    public val sessionTitle: String? = null,
    public val settingsWritable: FactState = FactState.UNKNOWN,
    public val groups: List<ConfigurationGroup>? = null,
    public val permissionModes: List<ConfigurationPermissionMode>? = null,
    public val defaultPermissionModeId: String? = null,
    public val plugins: List<ConfigurationPlugin>? = null,
    public val experimentalPlugins: List<ConfigurationExperimentalPlugin>? = null,
    public val pluginManagementMessage: String? = null,
    public val settingsFailure: String? = null,
    public val inventoryFailure: String? = null,
    public val permissionFailure: String? = null,
    /** Model routes; null means unread, empty means read with no route. */
    public val modelRoutes: List<ConfigurationModelRoute>? = null,
    /** Effective allowed subagent routes; null means the namespace field was unread. */
    public val selectedSubagentModelIds: Set<String>? = null,
    public val modelCatalogFailure: String? = null,
    /** Revision of the `permission` namespace, used by the default-preset CAS. */
    public val permissionRevision: Int? = null,
    /**
     * Per-field write capability for the new-session default. `null` keeps the
     * historical fallback to [settingsWritable]; the host sets it from the
     * measured startup-lock facts for the phone image.
     */
    public val defaultPermissionWritable: Boolean? = null,
    /** Why the new-session default is read-only, when the host measured a lock. */
    public val defaultPermissionReadOnlyReason: String? = null,
) {
    /** True when the snapshot carries at least one thing the page can show. */
    internal val hasContent: Boolean
        get() = sessionTitle != null ||
            settingsWritable != FactState.UNKNOWN ||
            !groups.isNullOrEmpty() ||
            !permissionModes.isNullOrEmpty() ||
            !plugins.isNullOrEmpty() ||
            !experimentalPlugins.isNullOrEmpty() ||
            pluginManagementMessage != null ||
            settingsFailure != null ||
            inventoryFailure != null ||
            permissionFailure != null
}

/**
 * The page's read-only input.
 *
 * @param snapshot the host's snapshot; `null` means the host did not report one.
 * @param failure the host's read failure; non-null when the last read failed.
 */
@Immutable
public data class ConfigurationFacts(
    public val snapshot: ConfigurationSnapshot? = null,
    public val failure: String? = null,
    public val loading: Boolean = false,
)

/** A typed write request from the page; request IDs bind a completion to its draft. */
@Immutable
public sealed interface ConfigurationWriteRequest {
    public val requestId: String

    public data class SaveGroup(
        public val namespace: String,
        public val patch: Map<String, String>,
        public val expectedRevision: Int,
        override val requestId: String,
    ) : ConfigurationWriteRequest

    public data class ResetField(
        public val namespace: String,
        public val field: String,
        public val expectedRevision: Int,
        override val requestId: String,
    ) : ConfigurationWriteRequest

    public data class SaveDefaultPermission(
        public val modeId: String,
        public val expectedRevision: Int,
        override val requestId: String,
    ) : ConfigurationWriteRequest

    public data class Refresh(override val requestId: String) : ConfigurationWriteRequest
}

/** A host completion; success is published only after the targeted reread confirms it. */
@Immutable
public data class ConfigurationWriteReceipt(
    public val requestId: String,
    public val success: Boolean,
    public val message: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The four outcomes the page distinguishes. */
public enum class ConfigurationStatus {
    /** At least one group, permission preset or plugin was reported. */
    READY,

    /** The host returned a snapshot but nothing in it was measured. */
    EMPTY,

    /** The last host read failed; no value claim survives it. */
    FAILED,

    /** The host did not report a snapshot: the page says 未知, never "none". */
    UNKNOWN,
}

/** One display-ready field or explanation row. */
@Immutable
public data class ConfigurationRowView(
    public val id: String,
    public val title: String,
    public val value: String? = null,
    public val subtitle: String? = null,
    public val tone: PageTone = PageTone.NORMAL,
    public val enabled: Boolean = true,
    public val kind: ConfigurationFieldKind = ConfigurationFieldKind.READ_ONLY,
    public val options: List<String> = emptyList(),
    public val namespace: String? = null,
    public val fieldId: String? = null,
    public val rawValue: String? = null,
)

/** One collapsible group of rows, with an explicit empty-text case. */
@Immutable
public data class ConfigurationSectionView(
    public val id: String,
    public val title: String,
    public val trailing: String?,
    public val expanded: Boolean,
    public val rows: List<ConfigurationRowView>,
    public val emptyText: String? = null,
    /** True when the host reports this group writable: the save verbs arm. */
    public val writable: Boolean = false,
    /** Routes for the subagent allowedModels catalog; `null` means unread. */
    public val modelRoutes: List<ConfigurationModelRoute>? = null,
    /** Currently stored allowed route IDs; `null` means unread. */
    public val selectedModelIds: Set<String>? = null,
    public val modelCatalogFailure: String? = null,
    /** Whether the special allowed-model catalog itself was read. */
    public val allowedModelsRead: Boolean = false,
    public val revision: Int? = null,
    /** A source-owned unsupported-group placeholder, rather than a real group. */
    public val unavailable: Boolean = false,
    /** The host section footer, kept outside its editable field rows. */
    public val detail: String? = null,
)

private data class ConfigurationGroupFallback(
    val namespace: String,
    val title: String,
    val unsupported: String,
)

/** The four groups NativeConfigurationPage always names, even if a host omits one. */
private val CONFIGURATION_GROUP_FALLBACKS = listOf(
    ConfigurationGroupFallback("subagent", "子 Agent", "这台主机不支持调整子代理。"),
    ConfigurationGroupFallback(
        "subagent-model-selection-settings", "子 Agent 模型", "这台主机不支持为子代理指定模型。",
    ),
    ConfigurationGroupFallback("agent-loop", "自动执行轮次", "这台主机不支持调整自动执行的轮次。"),
    ConfigurationGroupFallback("bash-sandbox", "终端", "这台主机不支持调整终端设置。"),
)

/**
 * The complete configuration screen state.
 *
 * @param status the four-state outcome; [ConfigurationStatus.FAILED] wins because
 *   a failed read proves nothing about the values.
 * @param sessionTitle the configured session's title, or `null` when unread.
 * @param writableValue the visible read/write word.
 * @param writableTone its ink.
 * @param sections the built-in groups (only while the 内置插件设置 fold is open)
 *   plus the about area (only while 插件说明 is open) and the fixed
 *   experimental-plugin and installed-plugin groups.
 * @param webSearchRow the navigation row into the web-search page; always present
 *   in [ConfigurationStatus.READY] because it does not depend on the snapshot.
 * @param permission the new-session permission presets and the current default.
 * @param builtInExpanded whether the 内置插件设置 master fold is open.
 * @param aboutExpanded whether the about area (本机管理范围 / 手机 Worker 限制) is open.
 * @param notes cross-cutting partial failures.
 * @param failure the host's failure message, re-shown by the page.
 * @param hasUnmeasuredValues true when a visible row is 未知, so the page can
 *   explain the word once.
 */
@Immutable
public data class ConfigurationScreenState(
    public val status: ConfigurationStatus,
    public val sessionTitle: String?,
    public val writableValue: String,
    public val writableTone: PageTone,
    public val sections: List<ConfigurationSectionView>,
    public val webSearchRow: ConfigurationRowView?,
    public val permission: ConfigurationPermissionView,
    public val builtInExpanded: Boolean,
    public val aboutExpanded: Boolean,
    public val notes: List<PageNote>,
    public val failure: String?,
    public val hasUnmeasuredValues: Boolean,
    public val loading: Boolean = false,
    public val modelRoutes: List<ConfigurationModelRoute>? = null,
    public val selectedSubagentModelIds: Set<String>? = null,
    public val modelCatalogFailure: String? = null,
    public val pluginManagementMessage: String? = null,
) {
    /** True when the host reported no snapshot. */
    public val isUnknown: Boolean get() = status == ConfigurationStatus.UNKNOWN

    /** True when the host reported an empty snapshot. */
    public val isEmpty: Boolean get() = status == ConfigurationStatus.EMPTY

    /** True when the last read failed. */
    public val isFailed: Boolean get() = status == ConfigurationStatus.FAILED

    /**
     * A stable, display-free signature of the sequence-relevant state.
     *
     * The sequence test compares these strings and then replays the fold script,
     * so a clock, an I/O read or a settings write would show up as a mismatch.
     */
    public fun signature(): String = buildString {
        append(status.name).append(':')
        append(writableTone.name).append(':')
        append(if (webSearchRow != null) "web" else "-").append(':')
        append(if (builtInExpanded) "in" else "-").append(':')
        append(if (aboutExpanded) "about" else "-").append(':')
        append(if (permission.isUnknown) "perm?" else "perm:${permission.modes?.size ?: 0}").append(':')
        append(sections.joinToString(",") { section ->
            "${section.id}=${if (section.expanded) "1" else "0"}:${section.rows.size}"
        }).append(':')
        append(notes.size).append(':')
        append(if (hasUnmeasuredValues) "partial" else "complete")
    }

    public companion object {
        /** The permission block's stable id (it is a block, not a titled section). */
        public const val PERMISSION_SECTION_ID: String = "config.permission"
        /** The 插件说明 about area's fold id: it owns 本机管理范围 and 手机 Worker 限制. */
        public const val INFO_SECTION_ID: String = "config.info"
        public const val BUILT_IN_SECTION_ID: String = "config.built-in"
        public const val SCOPE_SECTION_ID: String = "config.scope"
        public const val LIMITS_SECTION_ID: String = "config.limits"
        public const val EXPERIMENTAL_SECTION_ID: String = "config.experimental"
        public const val INSTALLED_SECTION_ID: String = "config.installed"
        public const val WEB_SEARCH_ROW_ID: String = "config.websearch"

        /** The prefix every host settings group's section id carries. */
        public const val GROUP_SECTION_PREFIX: String = "config.group."

        /** The host namespace a group row belongs to, as a stable section id. */
        public fun groupSectionId(namespace: String): String = GROUP_SECTION_PREFIX + namespace

        /** True when [id] is one of the host's built-in setting groups. */
        public fun isGroupSection(id: String): Boolean = id.startsWith(GROUP_SECTION_PREFIX)

        /**
         * Projects (facts, fold script) into the screen state.
         *
         * Pure: no clock, no I/O and no engine call. The host supplies every
         * value and every failure message, so the same facts and the same fold
         * script always yield the same state sequence (§3.1).
         */
        @Suppress("UNUSED_PARAMETER")
        public fun from(
            facts: ConfigurationFacts,
            local: ConfigurationLocalState = ConfigurationLocalState(),
        ): ConfigurationScreenState {
            val snapshot = facts.snapshot
            val status = when {
                facts.failure != null -> ConfigurationStatus.FAILED
                snapshot == null -> ConfigurationStatus.UNKNOWN
                !snapshot.hasContent -> ConfigurationStatus.EMPTY
                else -> ConfigurationStatus.READY
            }
            val measured = snapshot ?: ConfigurationSnapshot()
            val settingsWritable = measured.settingsWritable
            val builtInExpanded = true
            val aboutExpanded = false
            val permissionWritable = measured.defaultPermissionWritable
                ?: (settingsWritable == FactState.YES)
            val permission = ConfigurationPermissionView(
                modes = measured.permissionModes,
                selected = measured.defaultPermissionModeId?.let { id ->
                    measured.permissionModes?.firstOrNull { mode -> mode.id == id }
                },
                failure = measured.permissionFailure,
                revision = measured.permissionRevision,
                writable = permissionWritable,
                readOnlyReason = when {
                    permissionWritable -> null
                    !measured.defaultPermissionReadOnlyReason.isNullOrBlank() ->
                        measured.defaultPermissionReadOnlyReason
                    else -> UiStrings.DEFAULT_PERMISSION_READ_ONLY_FALLBACK_REASON
                },
            )
            val groupsByNamespace = measured.groups.orEmpty().associateBy { it.namespace }
            val sections = buildList {
                CONFIGURATION_GROUP_FALLBACKS.forEach { fallback ->
                    val group = groupsByNamespace[fallback.namespace]
                    if (group != null) {
                        add(groupSection(group.copy(title = fallback.title), measured))
                    } else {
                        val id = groupSectionId(fallback.namespace)
                        add(
                            ConfigurationSectionView(
                                id = id,
                                title = fallback.title,
                                trailing = null,
                                expanded = true,
                                rows = listOf(
                                    ConfigurationRowView(
                                        id = "$id.unavailable",
                                        title = CONFIGURATION_UNAVAILABLE,
                                        value = null,
                                        subtitle = measured.settingsFailure ?: when (measured.settingsWritable) {
                                            FactState.YES, FactState.NO -> fallback.unsupported
                                            FactState.UNKNOWN -> UiStrings.SETTINGS_UNKNOWN_HINT
                                        },
                                        tone = PageTone.NORMAL,
                                    ),
                                ),
                                writable = false,
                                unavailable = true,
                            ),
                        )
                    }
                }
                add(experimentalSection(measured))
                add(installedSection(measured))
            }
            val notes = buildList {
                if (measured.settingsFailure != null) {
                    add(
                        PageNote(
                            id = "config.note.settings",
                            text = UiStrings.CONFIGURATION_PARTIAL_FAILURE_FORMAT.format(
                                measured.settingsFailure,
                            ),
                            tone = PageTone.DEGRADED,
                        ),
                    )
                }
                if (measured.inventoryFailure != null) {
                    add(
                        PageNote(
                            id = "config.note.inventory",
                            text = UiStrings.CONFIGURATION_PARTIAL_FAILURE_FORMAT.format(
                                measured.inventoryFailure,
                            ),
                            tone = PageTone.DEGRADED,
                        ),
                    )
                }
                if (measured.permissionFailure != null) {
                    add(
                        PageNote(
                            id = "config.note.permission",
                            text = UiStrings.CONFIGURATION_PARTIAL_FAILURE_FORMAT.format(
                                measured.permissionFailure,
                            ),
                            tone = PageTone.DEGRADED,
                        ),
                    )
                }
                if (measured.modelCatalogFailure != null) {
                    add(
                        PageNote(
                            id = "config.note.models",
                            text = UiStrings.CONFIGURATION_PARTIAL_FAILURE_FORMAT.format(
                                measured.modelCatalogFailure,
                            ),
                            tone = PageTone.DEGRADED,
                        ),
                    )
                }
            }
            val hasUnmeasuredValues = measured.sessionTitle == null ||
                settingsWritable == FactState.UNKNOWN ||
                permission.isUnknown ||
                sections.any { section -> section.rows.any { row -> row.tone == PageTone.UNKNOWN } }
            return ConfigurationScreenState(
                status = status,
                sessionTitle = snapshot?.sessionTitle,
                writableValue = when (settingsWritable) {
                    FactState.YES -> UiStrings.CONFIGURATION_WRITABLE_YES
                    FactState.NO -> UiStrings.CONFIGURATION_WRITABLE_NO
                    FactState.UNKNOWN -> UiStrings.CONFIGURATION_WRITABLE_UNKNOWN
                },
                writableTone = when (settingsWritable) {
                    FactState.YES -> PageTone.ON
                    FactState.NO -> PageTone.NORMAL
                    FactState.UNKNOWN -> PageTone.UNKNOWN
                },
                sections = sections,
                webSearchRow = ConfigurationRowView(id = WEB_SEARCH_ROW_ID, title = UiStrings.CONFIGURATION_WEB_SEARCH),
                permission = permission,
                builtInExpanded = builtInExpanded,
                aboutExpanded = aboutExpanded,
                notes = notes,
                failure = facts.failure,
                hasUnmeasuredValues = hasUnmeasuredValues,
                loading = facts.loading,
                modelRoutes = measured.modelRoutes,
                selectedSubagentModelIds = measured.selectedSubagentModelIds,
                modelCatalogFailure = measured.modelCatalogFailure,
                pluginManagementMessage = measured.pluginManagementMessage,
            )
        }

        private fun groupSection(
            group: ConfigurationGroup,
            snapshot: ConfigurationSnapshot,
        ): ConfigurationSectionView {
            val id = groupSectionId(group.namespace)
            val fields = group.fields
            val fieldRows = if (fields == null) {
                listOf(
                    ConfigurationRowView(
                        id = "$id.unknown",
                        title = UiStrings.CONFIGURATION_GROUP_UNKNOWN,
                        value = UiStrings.UNKNOWN,
                        subtitle = UiStrings.SETTINGS_UNKNOWN_HINT,
                        tone = PageTone.UNKNOWN,
                    ),
                )
            } else {
                fields.mapNotNull { field ->
                    if (group.namespace == SUBAGENT_MODEL_NS && field.id == ALLOWED_MODELS_FIELD) {
                        return@mapNotNull null
                    }
                    ConfigurationRowView(
                        id = "$id.${field.id}",
                        title = field.title,
                        value = field.value ?: UiStrings.UNKNOWN,
                        subtitle = when {
                            field.value == null -> UiStrings.SETTINGS_UNKNOWN_HINT
                            field.overridden -> UiStrings.CONFIGURATION_FIELD_OVERRIDDEN
                            else -> field.detail
                        },
                        tone = if (field.value == null) PageTone.UNKNOWN else PageTone.NORMAL,
                        kind = field.kind,
                        options = field.options,
                        namespace = group.namespace,
                        fieldId = field.id,
                        rawValue = field.rawValue,
                    )
                }
            }
            return ConfigurationSectionView(
                id = id,
                title = group.title,
                trailing = if (fields == null) {
                    UiStrings.UNKNOWN
                } else {
                    UiStrings.CONFIGURATION_GROUP_ITEMS.format(fields.size)
                },
                expanded = true,
            rows = fieldRows,
                emptyText = if (fields != null && fields.isEmpty()) {
                    UiStrings.CONFIGURATION_GROUP_EMPTY
                } else {
                    null
                },
                writable = group.writable == FactState.YES,
                modelRoutes = if (group.namespace == SUBAGENT_MODEL_NS) snapshot.modelRoutes else null,
                selectedModelIds = if (group.namespace == SUBAGENT_MODEL_NS) {
                    snapshot.selectedSubagentModelIds
                } else null,
                modelCatalogFailure = if (group.namespace == SUBAGENT_MODEL_NS) {
                    snapshot.modelCatalogFailure
                } else null,
                allowedModelsRead = group.namespace == SUBAGENT_MODEL_NS &&
                    fields?.any { it.id == ALLOWED_MODELS_FIELD && it.rawValue != null } == true,
                revision = group.revision,
            detail = group.detail,
            )
        }

        private fun scopeSection(snapshot: ConfigurationSnapshot): ConfigurationSectionView =
            ConfigurationSectionView(
                id = SCOPE_SECTION_ID,
                title = UiStrings.CONFIGURATION_SCOPE_SECTION,
                trailing = null,
                expanded = true,
                rows = listOf(
                    ConfigurationRowView(
                        id = "$SCOPE_SECTION_ID.scope",
                        title = UiStrings.CONFIGURATION_SCOPE_TEXT,
                    ),
                ),
            )

        private fun limitsSection(snapshot: ConfigurationSnapshot): ConfigurationSectionView =
            ConfigurationSectionView(
                id = LIMITS_SECTION_ID,
                title = UiStrings.CONFIGURATION_LIMITS_SECTION,
                trailing = null,
                expanded = true,
                rows = listOf(
                    ConfigurationRowView(
                        id = "$LIMITS_SECTION_ID.message",
                        // The host's measured sentence, or this phone's own wording of the
                        // same fact. The baseline names an *iPhone* Worker; Android does
                        // not print that about the device it runs on.
                        title = snapshot.pluginManagementMessage
                            ?: UiStrings.PLUGIN_INVENTORY_MANAGEMENT_NOTICE,
                    ),
                    ConfigurationRowView(
                        id = "$LIMITS_SECTION_ID.loaded",
                        title = UiStrings.CONFIGURATION_ONLY_LOADED_TEXT,
                    ),
                ),
            )

        private fun experimentalSection(
            snapshot: ConfigurationSnapshot,
        ): ConfigurationSectionView {
            val plugins = snapshot.experimentalPlugins
            val rows = plugins.orEmpty().map { plugin ->
                ConfigurationRowView(
                    id = "$EXPERIMENTAL_SECTION_ID.${plugin.id}",
                    title = plugin.title,
                    value = when (plugin.loaded) {
                        FactState.YES -> UiStrings.CONFIGURATION_PLUGIN_LOADED
                        FactState.NO -> UiStrings.CONFIGURATION_PLUGIN_NOT_LOADED
                        FactState.UNKNOWN -> UiStrings.UNKNOWN
                    },
                    subtitle = plugin.status ?: if (plugin.loaded == FactState.UNKNOWN) {
                        UiStrings.SETTINGS_UNKNOWN_HINT
                    } else {
                        null
                    },
                    tone = when (plugin.loaded) {
                        FactState.YES -> PageTone.ON
                        FactState.NO -> PageTone.NORMAL
                        FactState.UNKNOWN -> PageTone.UNKNOWN
                    },
                )
            }
            return ConfigurationSectionView(
                id = EXPERIMENTAL_SECTION_ID,
                title = UiStrings.CONFIGURATION_EXPERIMENTAL,
                trailing = if (plugins == null) {
                    UiStrings.UNKNOWN
                } else {
                    UiStrings.CONFIGURATION_GROUP_ITEMS.format(plugins.size)
                },
                expanded = true,
                rows = rows,
                emptyText = when {
                    plugins == null -> UiStrings.CONFIGURATION_EXPERIMENTAL_UNKNOWN
                    plugins.isEmpty() -> UiStrings.CONFIGURATION_EXPERIMENTAL_EMPTY
                    else -> null
                },
            )
        }

        private fun installedSection(
            snapshot: ConfigurationSnapshot,
        ): ConfigurationSectionView {
            val plugins = snapshot.plugins
            val rows = plugins.orEmpty().map { plugin ->
                ConfigurationRowView(
                    id = "$INSTALLED_SECTION_ID.${plugin.id}",
                    title = plugin.module,
                    value = when (plugin.enabled) {
                        FactState.YES -> UiStrings.CONFIGURATION_PLUGIN_ENABLED
                        FactState.NO -> UiStrings.CONFIGURATION_PLUGIN_DISABLED
                        FactState.UNKNOWN -> UiStrings.UNKNOWN
                    },
                    subtitle = plugin.phase?.let { phase ->
                        UiStrings.CONFIGURATION_PLUGIN_META_FORMAT.format(
                            UiStrings.CONFIGURATION_PLUGIN_ENTRY.format(plugin.id),
                            UiStrings.CONFIGURATION_PLUGIN_PHASE.format(phase),
                        )
                    } ?: UiStrings.CONFIGURATION_PLUGIN_ENTRY.format(plugin.id),
                    tone = when (plugin.enabled) {
                        FactState.YES -> PageTone.ON
                        FactState.NO -> PageTone.NORMAL
                        FactState.UNKNOWN -> PageTone.UNKNOWN
                    },
                )
            }
            return ConfigurationSectionView(
                id = INSTALLED_SECTION_ID,
                title = UiStrings.CONFIGURATION_INSTALLED,
                trailing = if (plugins == null) {
                    UiStrings.UNKNOWN
                } else {
                    UiStrings.CONFIGURATION_INSTALLED_COUNT.format(plugins.size)
                },
                expanded = true,
                rows = rows,
                emptyText = when {
                    plugins == null -> UiStrings.CONFIGURATION_INSTALLED_UNKNOWN
                    plugins.isEmpty() -> UiStrings.CONFIGURATION_INSTALLED_EMPTY
                    else -> null
                },
            )
        }
    }
}

/** The local UI events of the configuration page: only the group folds. */
public sealed interface ConfigurationUiEvent {
    /** Collapse or expand one group. */
    public data class ToggleSection(public val id: String) : ConfigurationUiEvent
}

/**
 * The fold script; [apply] is pure, so a test drives it like a reducer.
 *
 * The installed-plugin group starts collapsed because the baseline renders it as
 * a disclosure; the about area starts collapsed because the baseline keeps it
 * behind the 插件说明 sheet; every other group starts expanded.
 *
 * @param fold which sections the user collapsed.
 */
@Immutable
public data class ConfigurationLocalState(
    public val fold: FoldState = FoldState(
        collapsedIds = setOf(
            ConfigurationScreenState.INSTALLED_SECTION_ID,
            ConfigurationScreenState.INFO_SECTION_ID,
        ),
    ),
) {
    /** Applies one local event. */
    public fun apply(event: ConfigurationUiEvent): ConfigurationLocalState = when (event) {
        is ConfigurationUiEvent.ToggleSection -> copy(fold = fold.toggle(event.id))
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The session-configuration sheet.
 *
 * The control set is the baseline's (`NativeConfigurationPage.swift`): the two
 * toolbar actions, the loaded-plugin destination, the 内置插件设置 master fold over
 * the host's groups, the new-session permission block, and the 插件说明 sheet.
 * Write controls use only host callbacks that return a request-bound
 * receipt; the measured `settingsWritable` fact disables them when the host
 * cannot write.
 *
 * @param state the pure screen state (`ConfigurationScreenState.from`).
 * @param onDone close the sheet (the baseline's `完成`).
 * @param onToggleSection a group header was tapped; the host applies
 *   `ConfigurationUiEvent.ToggleSection` and re-projects.
 * @param onRefresh re-read the snapshot; `null` renders 刷新 disabled (the
 *   baseline always draws the pill, so this page never hides it).
 * @param onOpenWebSearch open the web-search page; `null` makes the row read-only.
 * @param onRetry retry the failed read; `null` renders no retry row.
 * @param onDismissFailure dismiss the failure line; `null` renders no dismiss row.
 * @param onSaveGroup save one built-in group (the group's namespace); `null`
 *   disables 保存.
 * @param onDiscardGroup discard one built-in group's drafts; `null` disables 撤销.
 * @param onResetField reset one overridden field (section id, row id); `null`
 *   disables 恢复默认.
 * @param onPickDefaultPermission open the new-session permission picker; `null`
 *   (or a read-only host) disables the 默认权限 row.
 * @param onSaveDefaultPermission save the staged permission default; `null`
 *   disables 保存默认.
 * @param onDiscardDefaultPermission discard the staged permission default;
 *   `null` disables its 撤销.
 * @param onOpenPluginInventory open the measured plugin inventory subpage; a
 *   `null` host keeps 已加载插件 visible but explicitly unavailable.
 */
@Composable
public fun NativeConfigurationPage(
    state: ConfigurationScreenState,
    onDone: () -> Unit,
    onToggleSection: (String) -> Unit,
    modifier: Modifier = Modifier,
    onRefresh: (() -> Unit)? = null,
    onOpenWebSearch: (() -> Unit)? = null,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
    onSaveGroup: ((String) -> Unit)? = null,
    onDiscardGroup: ((String) -> Unit)? = null,
    onResetField: ((String, String) -> Unit)? = null,
    onPickDefaultPermission: (() -> Unit)? = null,
    onSaveDefaultPermission: (() -> Unit)? = null,
    onDiscardDefaultPermission: (() -> Unit)? = null,
    onSaveGroupDrafts: ((String, Map<String, String>) -> Unit)? = null,
    onApplyDefaultPermission: ((String) -> Unit)? = null,
    embedded: Boolean = false,
    /** Async host write/readback path; the page clears only the matching confirmed draft. */
    onConfigurationWrite: (suspend (ConfigurationWriteRequest) -> ConfigurationWriteReceipt)? = null,
    onOpenPluginInventory: (() -> Unit)? = null,
) {
    var drafts by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var baseRevisions by remember { mutableStateOf<Map<String, Int>>(emptyMap()) }
    var permissionDraft by remember { mutableStateOf<String?>(null) }
    var permissionBaseRevision by remember { mutableStateOf<Int?>(null) }
    var pendingWrites by remember { mutableStateOf<Map<String, ConfigurationWriteRequest>>(emptyMap()) }
    var writeFailures by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var pluginInformationOpen by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun dispatchWrite(
        request: ConfigurationWriteRequest,
        errorKey: String,
        onConfirmed: () -> Unit = {},
    ) {
        val writer = onConfigurationWrite ?: return
        if (pendingWrites.isNotEmpty()) return
        pendingWrites = pendingWrites + (request.requestId to request)
        scope.launch {
            val receipt = try {
                writer(request)
            } catch (cancelled: CancellationException) {
                pendingWrites = pendingWrites - request.requestId
                throw cancelled
            } catch (failure: Exception) {
                ConfigurationWriteReceipt(
                    requestId = request.requestId,
                    success = false,
                    message = failure.message?.substringBefore('\n')?.take(180)
                        ?: "配置写入失败，草稿仍保留。",
                )
            }
            if (pendingWrites[request.requestId] != request) return@launch
            pendingWrites = pendingWrites - request.requestId
            if (receipt.requestId != request.requestId) {
                writeFailures = writeFailures + (errorKey to "写入确认与当前请求不匹配，草稿仍保留。")
            } else if (receipt.success) {
                writeFailures = writeFailures - errorKey
                onConfirmed()
            } else {
                writeFailures = writeFailures +
                    (errorKey to (receipt.message ?: "写入没有确认，草稿仍保留。"))
            }
        }
    }
    val refreshBlocked = state.loading || drafts.isNotEmpty() || permissionDraft != null || pendingWrites.isNotEmpty()
    val refreshAction: (() -> Unit)? = when {
        refreshBlocked -> null
        onConfigurationWrite != null -> {
            {
                val request = ConfigurationWriteRequest.Refresh(java.util.UUID.randomUUID().toString())
                dispatchWrite(request, WRITE_ERROR_REFRESH)
            }
        }
        else -> onRefresh
    }

    val saveGroupDrafts: ((String, Map<String, String>) -> Unit)? = if (onConfigurationWrite != null) {
        { namespace, patch ->
            if (patch.isNotEmpty()) {
                val revision = baseRevisions[namespace]
                    ?: state.sections.firstOrNull {
                        it.id == ConfigurationScreenState.groupSectionId(namespace)
                    }?.revision
                if (revision == null) {
                    writeFailures = writeFailures +
                        (namespace to "配置分组版本未知，请刷新后重试；草稿仍保留。")
                } else {
                    val request = ConfigurationWriteRequest.SaveGroup(
                        namespace = namespace,
                        patch = patch,
                        expectedRevision = revision,
                        requestId = java.util.UUID.randomUUID().toString(),
                    )
                    val submittedPatch = patch.toMap()
                    dispatchWrite(request, namespace) {
                        val prefix = "$namespace/"
                        drafts = drafts.filter { (key, value) ->
                            !key.startsWith(prefix) || submittedPatch[key.removePrefix(prefix)] != value
                        }
                        if (drafts.keys.none { it.startsWith(prefix) }) {
                            baseRevisions = baseRevisions - namespace
                        }
                    }
                }
            }
        }
    } else null
    val discardGroupDrafts: ((String) -> Unit) = { namespace ->
        drafts = drafts.filterKeys { !it.startsWith("$namespace/") }
        baseRevisions = baseRevisions - namespace
        writeFailures = writeFailures - namespace
        onDiscardGroup?.invoke(namespace)
    }
    val resetField: ((String, String) -> Unit)? = if (onConfigurationWrite != null) {
        { namespace, field ->
            val revision = state.sections.firstOrNull {
                it.id == ConfigurationScreenState.groupSectionId(namespace)
            }?.revision
            if (revision == null) {
                writeFailures = writeFailures +
                    ("$namespace/$field" to "配置分组版本未知，请刷新后重试。")
            } else {
                val request = ConfigurationWriteRequest.ResetField(
                    namespace = namespace,
                    field = field,
                    expectedRevision = revision,
                    requestId = java.util.UUID.randomUUID().toString(),
                )
                val submittedDraft = drafts["$namespace/$field"]
                dispatchWrite(request, "$namespace/$field") {
                    val fieldKey = "$namespace/$field"
                    if (drafts[fieldKey] == submittedDraft) {
                        drafts = drafts - fieldKey
                    }
                    if (drafts.keys.none { it.startsWith("$namespace/") }) {
                        baseRevisions = baseRevisions - namespace
                    }
                }
            }
        }
    } else null
    val saveDefaultPermission: ((String) -> Unit)? = if (onConfigurationWrite != null) {
        { modeId ->
            val revision = permissionBaseRevision ?: state.permission.revision
            if (revision == null) {
                writeFailures = writeFailures +
                    (PERMISSION_WRITE_ERROR to "权限预设版本未知，请刷新后重试。")
            } else {
                val request = ConfigurationWriteRequest.SaveDefaultPermission(
                    modeId = modeId,
                    expectedRevision = revision,
                    requestId = java.util.UUID.randomUUID().toString(),
                )
                dispatchWrite(request, PERMISSION_WRITE_ERROR) {
                    if (permissionDraft == modeId) {
                        permissionDraft = null
                        permissionBaseRevision = null
                    }
                }
            }
        }
    } else null
    val tokens = LocalUiTokens.current
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(tokens.colors.page)
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))
            .testTag(UiPageTags.CONFIGURATION_ROOT),
    ) {
        if (!embedded) {
            SettingsNavBar(
                title = UiStrings.CONFIGURATION_TITLE,
                onBack = onDone,
                backTag = UiPageTags.CONFIGURATION_ROOT + ".back",
                trailing = {
                    Row(horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText)) {
                        Box(
                            modifier = Modifier.size(com.phonedsh.ui.HomeMetrics.navButton)
                                .clickable(role = androidx.compose.ui.semantics.Role.Button) { pluginInformationOpen = true }
                                .semantics { contentDescription = UiStrings.CONFIGURATION_PLUGIN_INFO }
                                .testTag(UiPageTags.CONFIGURATION_PLUGIN_INFO_ACTION),
                            contentAlignment = Alignment.Center,
                        ) { InfoCircleGlyph(tokens.colors.textPrimary) }
                        Box(
                            modifier = Modifier.size(com.phonedsh.ui.HomeMetrics.navButton)
                                .clickable(enabled = refreshAction != null, role = androidx.compose.ui.semantics.Role.Button) { refreshAction?.invoke() }
                                .semantics { contentDescription = UiStrings.CONFIGURATION_REFRESH }
                                .testTag(UiPageTags.CONFIGURATION_REFRESH),
                            contentAlignment = Alignment.Center,
                        ) { RefreshGlyph(tokens.colors.textPrimary) }
                    }
                },
            )
        }
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .navigationBarsPadding(),
        ) {
        ConfigurationContent(
            state = state,
            failure = state.failure,
            loading = state.loading,
            onRetry = if (onConfigurationWrite != null) refreshAction else onRetry,
            onOpenWebSearch = onOpenWebSearch,
            onOpenPluginInventory = onOpenPluginInventory,
            onSaveGroup = if (onConfigurationWrite != null) onSaveGroup else null,
            onDiscardGroup = discardGroupDrafts,
            onResetField = resetField,
            onPickDefaultPermission = onPickDefaultPermission,
            onSaveDefaultPermission = if (onConfigurationWrite != null) onSaveDefaultPermission else null,
            onDiscardDefaultPermission = onDiscardDefaultPermission,
            drafts = drafts,
            writeFailures = writeFailures,
            pendingNamespaces = pendingWrites.values.mapNotNull { request ->
                when (request) {
                    is ConfigurationWriteRequest.SaveGroup -> request.namespace
                    is ConfigurationWriteRequest.ResetField -> request.namespace
                    is ConfigurationWriteRequest.SaveDefaultPermission -> PERMISSION_WRITE_ERROR
                    is ConfigurationWriteRequest.Refresh -> WRITE_ERROR_REFRESH
                }
            }.toSet(),
            onDraft = { key, value ->
                drafts = drafts + (key to value)
                val namespace = key.substringBefore('/')
                val revision = state.sections.firstOrNull {
                    it.id == ConfigurationScreenState.groupSectionId(namespace)
                }?.revision
                if (revision != null && namespace !in baseRevisions) {
                    baseRevisions = baseRevisions + (namespace to revision)
                }
                writeFailures = writeFailures - key.substringBefore('/')
            },
            onClearDrafts = { namespace ->
                drafts = drafts.filterKeys { !it.startsWith("$namespace/") }
                baseRevisions = baseRevisions - namespace
            },
            onSaveGroupDrafts = saveGroupDrafts,
            permissionDraft = permissionDraft,
            onStagePermission = { modeId ->
                if (modeId == state.permission.selected?.id) {
                    permissionDraft = null
                    permissionBaseRevision = null
                } else {
                    permissionDraft = modeId
                    if (permissionBaseRevision == null) {
                        permissionBaseRevision = state.permission.revision
                    }
                }
            },
            onClearPermission = {
                permissionDraft = null
                permissionBaseRevision = null
                writeFailures = writeFailures - PERMISSION_WRITE_ERROR
                onDiscardDefaultPermission?.invoke()
            },
            onApplyDefaultPermission = saveDefaultPermission,
        )
        }
    }
    if (pluginInformationOpen) {
        ConfigurationPluginInformationSheet(
            managementMessage = state.pluginManagementMessage,
            onDone = { pluginInformationOpen = false },
        )
    }
}

/** The source's medium/large 插件说明 NavigationStack sheet, with its own Done bar. */
@Composable
internal fun ConfigurationPluginInformationSheet(
    managementMessage: String?,
    onDone: () -> Unit,
) {
    // 完成, the scrim, drag-down and system back all leave through the shared
    // sheet's platform hide; the host is told only when the sheet has gone.
    val sheetBackHost = remember { SheetBackHost() }
    PdshSheet(
        pageId = "configurationInfo",
        backHost = sheetBackHost,
        onDismissRequest = onDone,
        modifier = Modifier.testTag(CONFIGURATION_PLUGIN_INFO_SHEET_TAG),
    ) {
        SettingsSubPageFrame(
            title = UiStrings.CONFIGURATION_PLUGIN_INFO,
            // The page id's frozen detents are [medium, large]; the content does
            // not impose a page-specific height cap.
            modifier = Modifier.fillMaxWidth(),
            trailing = {
                SessionTextAction(
                    label = UiStrings.CONFIGURATION_DONE,
                    onClick = { sheetBackHost.dispatch() },
                    tone = SessionActionTone.ACCENT,
                    modifier = Modifier.testTag(CONFIGURATION_PLUGIN_INFO_DONE_TAG),
                )
            },
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize().testTag(CONFIGURATION_PLUGIN_INFO_LIST_TAG),
            ) {
                item(key = "config.info.scope.header") {
                    SettingsSectionLabel(UiStrings.CONFIGURATION_SCOPE_SECTION)
                }
                item(key = "config.info.scope.body") {
                    SettingsFormRow(title = UiStrings.CONFIGURATION_SCOPE_TEXT, value = null)
                }
                item(key = "config.info.limits.header") {
                    SettingsSectionLabel(UiStrings.CONFIGURATION_LIMITS_SECTION)
                }
                item(key = "config.info.limits.body") {
                    SettingsFormRow(
                        title = managementMessage ?: UiStrings.PLUGIN_INVENTORY_MANAGEMENT_NOTICE,
                        value = null,
                    )
                }
                item(key = "config.info.loaded.body") {
                    SettingsFormRow(title = UiStrings.CONFIGURATION_ONLY_LOADED_TEXT, value = null)
                }
            }
        }
    }
}

internal const val CONFIGURATION_PLUGIN_INFO_SHEET_TAG = "pdsh.configuration.plugin-info.sheet"
internal const val CONFIGURATION_PLUGIN_INFO_DONE_TAG = "pdsh.configuration.plugin-info.done"
internal const val CONFIGURATION_PLUGIN_INFO_LIST_TAG = "pdsh.configuration.plugin-info.list"
private const val CONFIGURATION_UNAVAILABLE = "暂不可用"

/**
 * The unknown snapshot: a scrollable pair of lines so the negative assertion in
 * the test runs against a composed node, not against a window that never held it.
 */
@Composable
private fun ConfigurationUnknownList() {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.CONFIGURATION_LIST),
        verticalArrangement = Arrangement.Top,
    ) {
        item(key = "config.unknown") {
            SettingsFormRow(
                title = UiStrings.CONFIGURATION_UNKNOWN_STATE,
                value = null,
                subtitle = UiStrings.CONFIGURATION_UNKNOWN_HINT,
                modifier = Modifier.testTag(UiPageTags.CONFIGURATION_UNKNOWN),
            )
        }
        item(key = "config.unknown.detail") {
            SettingsFormRow(
                title = UiStrings.UNKNOWN,
                value = null,
                subtitle = UiStrings.CONFIGURATION_UNKNOWN_DETAIL,
                tone = PageTone.UNKNOWN,
                modifier = Modifier.testTag(UiPageTags.CONFIGURATION_UNKNOWN_DETAIL),
            )
        }
    }
}

/** The measured configuration: identity, groups, permissions and plugins. */
@Composable
private fun ConfigurationContent(
    state: ConfigurationScreenState,
    failure: String?,
    loading: Boolean,
    onRetry: (() -> Unit)?,
    onOpenWebSearch: (() -> Unit)?,
    onOpenPluginInventory: (() -> Unit)?,
    onSaveGroup: ((String) -> Unit)?,
    onDiscardGroup: ((String) -> Unit)?,
    onResetField: ((String, String) -> Unit)?,
    onPickDefaultPermission: (() -> Unit)?,
    onSaveDefaultPermission: (() -> Unit)?,
    onDiscardDefaultPermission: (() -> Unit)?,
    drafts: Map<String, String>,
    writeFailures: Map<String, String>,
    pendingNamespaces: Set<String>,
    onDraft: (String, String) -> Unit,
    onClearDrafts: (String) -> Unit,
    onSaveGroupDrafts: ((String, Map<String, String>) -> Unit)?,
    permissionDraft: String?,
    onStagePermission: (String) -> Unit,
    onClearPermission: () -> Unit,
    onApplyDefaultPermission: ((String) -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val writable = state.writableTone == PageTone.ON
    val sectionsById = state.sections.associateBy { it.id }
    val groups = CONFIGURATION_GROUP_FALLBACKS.mapNotNull { fallback ->
        sectionsById[ConfigurationScreenState.groupSectionId(fallback.namespace)]
    }
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.CONFIGURATION_LIST),
        verticalArrangement = Arrangement.Top,
    ) {
        if (loading && state.status in setOf(ConfigurationStatus.UNKNOWN, ConfigurationStatus.EMPTY)) {
            item(key = "config.loading") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            horizontal = tokens.geometry.pageOuterMarginH,
                            vertical = tokens.spacing.badgeInsetV,
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                ) {
                    CircularProgressIndicator(Modifier.size(tokens.geometry.statusDotDiameter))
                    BasicText(
                        text = CONFIGURATION_LOADING_TEXT,
                        style = type.secondary.copy(color = tokens.colors.secondary),
                    )
                }
            }
        }
        failure?.let { message ->
            item(key = "config.failure") {
                WarningLine(text = message, tag = UiPageTags.CONFIGURATION_FAILURE)
            }
        }
        state.notes.forEach { note ->
            item(key = "config.note." + note.id) {
                WarningLine(text = note.text, tag = UiPageTags.CONFIGURATION_NOTE_PREFIX + note.id)
            }
        }

        groups.forEach { group ->
            val namespace = group.id.removePrefix(ConfigurationScreenState.GROUP_SECTION_PREFIX)
            val draftPrefix = "$namespace/"
            val groupDrafts = drafts.filterKeys { it.startsWith(draftPrefix) }
            val groupHasDrafts = groupDrafts.isNotEmpty()
            val groupBusy = namespace in pendingNamespaces
            val groupWritable = group.writable && writable
            item(key = "config.header." + group.id) {
                SettingsSectionLabel(
                    title = group.title,
                    modifier = Modifier.testTag(UiPageTags.CONFIGURATION_SECTION_PREFIX + group.id),
                )
            }
            val visibleRows = group.rows.filter { it.kind != ConfigurationFieldKind.MODEL_SELECTION }
            items(count = visibleRows.size, key = { index -> visibleRows[index].id }) { index ->
                val row = visibleRows[index]
                val fieldKey = row.namespace?.let { rowNamespace ->
                    row.fieldId?.let { field -> "$rowNamespace/$field" }
                }
                val resetFailure = fieldKey?.let(writeFailures::get)
                Column(modifier = Modifier.fillMaxWidth()) {
                    SettingsFormRow(
                        title = row.title,
                        value = row.value,
                        subtitle = resetFailure ?: row.subtitle,
                        tone = if (resetFailure != null) PageTone.DEGRADED else row.tone,
                        enabled = row.enabled,
                        trailing = if (row.subtitle == UiStrings.CONFIGURATION_FIELD_OVERRIDDEN) {
                            {
                                SessionTextAction(
                                    label = UiStrings.CONFIGURATION_RESET,
                                    onClick = {
                                        onResetField?.invoke(namespace, row.id.removePrefix(group.id + "."))
                                    },
                                    tone = SessionActionTone.SECONDARY,
                                    enabled = groupWritable && onResetField != null &&
                                        !groupHasDrafts && !groupBusy,
                                    modifier = Modifier.testTag(
                                        UiPageTags.CONFIGURATION_ROW_RESET_PREFIX + row.id,
                                    ),
                                )
                            }
                        } else {
                            null
                        },
                    )
                    if (fieldKey != null && row.kind != ConfigurationFieldKind.READ_ONLY) {
                        ConfigurationFieldEditor(
                            field = row,
                            draft = drafts[fieldKey] ?: row.value.orEmpty(),
                            enabled = groupWritable && !groupBusy && row.enabled,
                            onDraft = { value -> onDraft(fieldKey, value) },
                        )
                    }
                }
            }
            if (namespace == SUBAGENT_MODEL_NS) {
                when {
                    group.modelCatalogFailure != null -> item(key = "config.models.failure") {
                        ConfigurationNoteRow(
                            text = UiStrings.MODEL_LIST_UNAVAILABLE,
                            tag = UiPageTags.CONFIGURATION_NOTE_PREFIX + "models",
                        )
                    }
                    group.modelRoutes == null -> item(key = "config.models.unknown") {
                        SettingsFormRow(
                            title = UiStrings.CONFIGURATION_GROUP_UNKNOWN,
                            value = UiStrings.UNKNOWN,
                            tone = PageTone.UNKNOWN,
                            subtitle = UiStrings.SETTINGS_UNKNOWN_HINT,
                        )
                    }
                    group.modelRoutes.isEmpty() -> item(key = "config.models.empty") {
                        SettingsFormRow(title = UiStrings.SUBTASK_MODELS_EMPTY, value = null)
                    }
                    else -> {
                        val selectedModelIds = decodeConfigurationModelIds(
                            groupDrafts["$namespace/$ALLOWED_MODELS_FIELD"],
                        ) ?: group.selectedModelIds.orEmpty()
                        items(items = group.modelRoutes, key = { route -> "config.model." + route.id }) { route ->
                            val selected = route.id in selectedModelIds
                            val enabled = groupWritable && !groupBusy && group.allowedModelsRead
                            val changeSelection: (Boolean) -> Unit = { checked ->
                                if (enabled) {
                                    val updated = selectedModelIds.toMutableSet().apply {
                                        if (checked) add(route.id) else remove(route.id)
                                    }
                                    onDraft(
                                        "$namespace/$ALLOWED_MODELS_FIELD",
                                        encodeConfigurationModelIds(updated),
                                    )
                                }
                            }
                            SettingsFormRow(
                                title = route.modelName,
                                value = if (selected) UiStrings.SELECTED else null,
                                subtitle = buildString {
                                    append(route.providerName).append(" · ")
                                        .append(route.provider).append('/').append(route.model)
                                    if (!route.available) append(" · ").append(UiStrings.UNAVAILABLE)
                                },
                                tone = if (route.available) PageTone.NORMAL else PageTone.UNKNOWN,
                                enabled = enabled,
                                trailing = {
                                    androidx.compose.material3.Switch(
                                        checked = selected,
                                        onCheckedChange = changeSelection,
                                        enabled = enabled,
                                    )
                                },
                                onClick = { changeSelection(!selected) },
                                modifier = Modifier.testTag(CONFIGURATION_MODEL_ROUTE_PREFIX + route.id),
                            )
                        }
                    }
                }
            }
            if (group.emptyText != null) {
                item(key = "config.empty." + group.id) {
                    SettingsFormRow(title = group.emptyText, value = null, tone = PageTone.UNKNOWN)
                }
            }
            if (groupHasDrafts) {
                item(key = "config.group-actions." + group.id) {
                    Column {
                        writeFailures[namespace]?.let { writeFailure ->
                            ConfigurationNoteRow(
                                text = writeFailure,
                                tag = UiPageTags.CONFIGURATION_NOTE_PREFIX + "write.$namespace",
                            )
                        }
                        ConfigurationGroupActions(
                            groupId = group.id,
                            writable = groupWritable,
                            canSave = onSaveGroupDrafts != null || onSaveGroup != null,
                            busy = groupBusy,
                            onSave = {
                                val patch = groupDrafts.mapKeys { (key, _) -> key.removePrefix(draftPrefix) }
                                if (patch.isNotEmpty() && onSaveGroupDrafts != null) {
                                    onSaveGroupDrafts.invoke(namespace, patch)
                                } else if (patch.isNotEmpty()) {
                                    onSaveGroup?.invoke(namespace)
                                }
                            },
                            canDiscard = true,
                            onDiscard = {
                                onClearDrafts(namespace)
                                onDiscardGroup?.invoke(namespace)
                            },
                        )
                    }
                }
            }
            if (group.detail != null) {
                item(key = "config.footer." + group.id) {
                    ConfigurationNoteRow(text = group.detail)
                }
            }
        }

        item(key = "config.tools.header") { SettingsSectionLabel(CONFIGURATION_TOOLS_SECTION) }
        state.webSearchRow?.let { row ->
            item(key = "config.websearch") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = tokens.geometry.pageOuterMarginH),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                ) {
                    GlobeGlyph(tint = tokens.colors.accent)
                    InfoRow(
                        title = UiStrings.CONFIGURATION_WEB_SEARCH,
                        value = null,
                        subtitle = row.subtitle,
                        onClick = onOpenWebSearch,
                        modifier = Modifier.weight(1f).testTag(UiPageTags.CONFIGURATION_WEB_SEARCH),
                    )
                }
            }
        }
        item(key = "config.permission") {
            ConfigurationPermissionBlock(
                permission = state.permission,
                busy = PERMISSION_WRITE_ERROR in pendingNamespaces,
                writeFailure = writeFailures[PERMISSION_WRITE_ERROR],
                onPick = onPickDefaultPermission,
                onSave = onSaveDefaultPermission,
                onDiscard = {
                    onClearPermission()
                    onDiscardDefaultPermission?.invoke()
                },
                draft = permissionDraft,
                onStage = onStagePermission,
                onApply = onApplyDefaultPermission,
            )
        }

        val experimental = state.sections.firstOrNull {
            it.id == ConfigurationScreenState.EXPERIMENTAL_SECTION_ID
        }
        if (experimental != null) {
            item(key = "config.header." + experimental.id) {
                SettingsSectionLabel(experimental.title)
            }
            items(items = experimental.rows, key = { row -> row.id }) { row ->
                SettingsFormRow(
                    title = row.title,
                    value = row.value,
                    subtitle = row.subtitle,
                    tone = row.tone,
                )
            }
            if (experimental.trailing == UiStrings.UNKNOWN && experimental.emptyText != null) {
                item(key = "config.empty." + experimental.id) {
                    SettingsFormRow(
                        title = experimental.emptyText,
                        value = null,
                        tone = PageTone.UNKNOWN,
                    )
                }
            }
        }
        val installed = state.sections.firstOrNull {
            it.id == ConfigurationScreenState.INSTALLED_SECTION_ID
        }
        if (installed != null) {
            item(key = "config.installed.link") {
                if (installed.trailing == UiStrings.UNKNOWN) {
                    SettingsFormRow(
                        title = installed.emptyText ?: UiStrings.CONFIGURATION_INSTALLED_UNKNOWN,
                        value = null,
                        tone = PageTone.UNKNOWN,
                        modifier = Modifier.testTag(UiPageTags.CONFIGURATION_INSTALLED),
                    )
                } else {
                    InfoRow(
                        title = UiStrings.CONFIGURATION_INSTALLED,
                        value = installed.rows.size.takeIf { it > 0 }?.let { installed.trailing },
                        subtitle = if (onOpenPluginInventory == null) UiStrings.UNAVAILABLE else null,
                        enabled = onOpenPluginInventory != null,
                        onClick = { onOpenPluginInventory?.invoke() },
                        modifier = Modifier.testTag(UiPageTags.CONFIGURATION_INSTALLED),
                    )
                }
            }
        }
    }
}

/**
 * The baseline's 保存 / 撤销 pair under one built-in settings group.
 *
 * The pair is rendered even when the host reports the group read-only: the
 * baseline declares the controls, and a disabled control states the measured
 * fact. A `null` callback (a host with no write command) also disables it.
 */
@Composable
private fun ConfigurationGroupActions(
    groupId: String,
    writable: Boolean,
    canSave: Boolean,
    busy: Boolean,
    onSave: () -> Unit,
    canDiscard: Boolean,
    onDiscard: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SessionTextAction(
            label = UiStrings.CONFIGURATION_SAVE,
            onClick = onSave,
            tone = SessionActionTone.ACCENT,
            enabled = writable && canSave && !busy,
            modifier = Modifier.testTag(UiPageTags.CONFIGURATION_GROUP_SAVE_PREFIX + groupId),
        )
        SessionTextAction(
            label = UiStrings.CONFIGURATION_DISCARD,
            onClick = onDiscard,
            tone = SessionActionTone.SECONDARY,
            enabled = writable && canDiscard && !busy,
            modifier = Modifier.testTag(UiPageTags.CONFIGURATION_GROUP_DISCARD_PREFIX + groupId),
        )
    }
}

/** The inline control for one schema field; values are staged until 保存. */
@Composable
private fun ConfigurationFieldEditor(
    field: ConfigurationRowView,
    draft: String,
    enabled: Boolean,
    onDraft: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    when (field.kind) {
        ConfigurationFieldKind.TOGGLE -> Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.badgeInsetV),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = field.title,
                style = LocalUiType.current.secondary.copy(color = tokens.colors.secondary),
                modifier = Modifier.weight(1f),
            )
            androidx.compose.material3.Switch(
                checked = draft == "true" || draft == "开启",
                onCheckedChange = { onDraft(if (it) "true" else "false") },
                enabled = enabled,
                modifier = Modifier.testTag(
                    "pdsh.configuration.field.${field.namespace}.${field.fieldId}",
                ),
            )
        }

        ConfigurationFieldKind.NUMBER,
        ConfigurationFieldKind.TEXT,
        -> BasicTextField(
            value = draft,
            onValueChange = onDraft,
            enabled = enabled,
            singleLine = true,
            textStyle = LocalUiType.current.body.copy(color = tokens.colors.primary),
            cursorBrush = SolidColor(tokens.colors.accent),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.badgeInsetV)
                .testTag("pdsh.configuration.field.${field.namespace}.${field.fieldId}"),
        )

        ConfigurationFieldKind.ENUM -> {
            var expanded by remember { mutableStateOf(false) }
            Box {
                SessionTextAction(
                    label = if (draft.isEmpty()) field.title else "$draft",
                    onClick = { expanded = true },
                    tone = SessionActionTone.SECONDARY,
                    enabled = enabled,
                    modifier = Modifier.padding(horizontal = tokens.geometry.pageOuterMarginH),
                )
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    field.options.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option) },
                            onClick = {
                                expanded = false
                                onDraft(option)
                            },
                            enabled = enabled,
                        )
                    }
                }
            }
        }

        ConfigurationFieldKind.MODEL_SELECTION -> Unit // rendered by the model-route catalog rows

        ConfigurationFieldKind.READ_ONLY -> Unit
    }
}

/**
 * The 新会话默认权限 block.
 *
 * Three cases stay apart, as everywhere else on this page: an unread catalog is
 * 未知 (with its own failure line when the read failed), a measured-empty catalog
 * says 没有可选的权限预设, and a measured catalog shows the current 默认权限. The
 * picker row and the 保存默认 / 撤销 pair are the baseline's controls; this one
 * field's measured writability (and a `null` callback) disables them. A locked
 * startup overlay explains itself instead of painting a dead control.
 */
@Composable
private fun ConfigurationPermissionBlock(
    permission: ConfigurationPermissionView,
    busy: Boolean,
    writeFailure: String?,
    onPick: (() -> Unit)?,
    onSave: (() -> Unit)?,
    onDiscard: (() -> Unit)?,
    draft: String? = null,
    onStage: ((String) -> Unit)? = null,
    onApply: ((String) -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val modes = permission.modes
    val writable = permission.writable
    val controlsEnabled = writable && !busy
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.CONFIGURATION_PERMISSION),
    ) {
        SettingsSectionLabel(UiStrings.CONFIGURATION_DEFAULT_PERMISSION)
        when {
            modes == null -> InfoRow(
                title = UiStrings.CONFIGURATION_PERMISSION_UNKNOWN,
                value = UiStrings.UNKNOWN,
                subtitle = permission.failure ?: UiStrings.SETTINGS_UNKNOWN_HINT,
                tone = PageTone.UNKNOWN,
            )

            modes.isEmpty() -> InfoRow(
                title = UiStrings.CONFIGURATION_PERMISSION_EMPTY,
                value = null,
                subtitle = UiStrings.CONFIGURATION_DEFAULT_PERMISSION_HINT,
            )

            else -> {
                val chosen = draft ?: permission.selected?.id
                InfoRow(
                    title = UiStrings.CONFIGURATION_DEFAULT_PERMISSION_ROW,
                    value = (draft?.let { id -> modes.firstOrNull { it.id == id }?.name })
                        ?: permission.selected?.name ?: UiStrings.UNKNOWN,
                    subtitle = permission.selected?.detail
                        ?: UiStrings.CONFIGURATION_DEFAULT_PERMISSION_HINT,
                    tone = if (permission.selected == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    onClick = if (controlsEnabled) onPick else null,
                    modifier = Modifier.testTag(UiPageTags.CONFIGURATION_PERMISSION_ROW),
                )
                if (!permission.writable) {
                    permission.readOnlyReason?.let { reason ->
                        ConfigurationNoteRow(
                            text = reason,
                            tag = UiPageTags.CONFIGURATION_PERMISSION_READ_ONLY,
                        )
                    }
                }
                if (writable) {
                    modes.forEach { mode ->
                        InfoRow(
                            title = mode.name,
                            value = if (chosen == mode.id) "已选择" else null,
                            subtitle = mode.detail,
                            onClick = if (controlsEnabled) onStage?.let { stage -> { stage(mode.id) } } else null,
                        modifier = Modifier.testTag(CONFIGURATION_PERMISSION_OPTION_PREFIX + mode.id),
                        )
                    }
                }
                if (draft != null) {
                    writeFailure?.let {
                        ConfigurationNoteRow(
                            text = it,
                            tag = UiPageTags.CONFIGURATION_NOTE_PREFIX + PERMISSION_WRITE_ERROR,
                        )
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = tokens.geometry.pageOuterMarginH),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        SessionTextAction(
                            label = UiStrings.CONFIGURATION_SAVE_DEFAULT,
                            onClick = {
                                if (onApply != null) onApply.invoke(draft) else onSave?.invoke()
                            },
                            tone = SessionActionTone.ACCENT,
                            enabled = controlsEnabled && (onApply != null || onSave != null),
                            modifier = Modifier.testTag(UiPageTags.CONFIGURATION_PERMISSION_SAVE),
                        )
                        SessionTextAction(
                            label = UiStrings.CONFIGURATION_DISCARD,
                            onClick = { onDiscard?.invoke() },
                            tone = SessionActionTone.SECONDARY,
                            enabled = controlsEnabled && onDiscard != null,
                            modifier = Modifier.testTag(UiPageTags.CONFIGURATION_PERMISSION_DISCARD),
                        )
                    }
                }
            }
        }
    }
}

/** One explanatory line; the ink is a token, never a second colour source. */
@Composable
private fun ConfigurationNoteRow(
    text: String,
    tag: String = UiPageTags.CONFIGURATION_READ_ONLY,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.tertiary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** The failure line: the host's message, a retry row and a dismiss row. */
@Composable
private fun ConfigurationFailureBlock(
    failure: String?,
    onRetry: (() -> Unit)?,
    onDismissFailure: (() -> Unit)?,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        SettingsFormRow(
            title = UiStrings.CONFIGURATION_LOAD_FAILED,
            value = null,
            subtitle = failure,
            modifier = Modifier.testTag(UiPageTags.CONFIGURATION_FAILURE),
        )
        if (onRetry != null) {
            SettingsFormRow(
                title = UiStrings.RETRY,
                value = null,
                onClick = onRetry,
                modifier = Modifier.testTag(UiPageTags.CONFIGURATION_RETRY),
            )
        }
        if (onDismissFailure != null) {
            SettingsFormRow(
                title = UiStrings.DISMISS,
                value = null,
                onClick = onDismissFailure,
                modifier = Modifier.testTag(UiPageTags.CONFIGURATION_DISMISS),
            )
        }
    }
}

private fun encodeConfigurationModelIds(ids: Set<String>): String = JsonArray(
    ids.sorted().mapNotNull { routeId ->
        val separator = routeId.indexOf('/')
        if (separator <= 0 || separator == routeId.lastIndex) return@mapNotNull null
        JsonObject(
            mapOf(
                "provider" to JsonString(routeId.substring(0, separator)),
                "model" to JsonString(routeId.substring(separator + 1)),
            ),
        )
    },
).toJsonString()

private fun decodeConfigurationModelIds(raw: String?): Set<String>? {
    if (raw == null) return null
    val rows = runCatching { JsonValue.parse(raw) as? JsonArray }.getOrNull() ?: return null
    return rows.values.mapNotNull { value ->
        val row = value as? JsonObject ?: return@mapNotNull null
        val provider = (row["provider"] as? JsonString)?.value ?: return@mapNotNull null
        val model = (row["model"] as? JsonString)?.value ?: return@mapNotNull null
        "$provider/$model"
    }.toSet()
}

private const val CONFIGURATION_LOADING_TEXT = "正在读取插件与设置…"
private const val CONFIGURATION_TOOLS_SECTION = "工具"
private const val SUBAGENT_MODEL_NS = "subagent-model-selection-settings"
private const val ALLOWED_MODELS_FIELD = "allowedModels"
private const val CONFIGURATION_MODEL_ROUTE_PREFIX = "pdsh.configuration.model-route."
private const val CONFIGURATION_PERMISSION_OPTION_PREFIX = "pdsh.configuration.permission-option."
private const val WRITE_ERROR_REFRESH = "configuration.refresh"
private const val PERMISSION_WRITE_ERROR = "permission"

/** Every token this file reads; kept equal to the source by `PageTokenReferenceTest`. */
internal object NativeConfigurationPageTokens {
    val refs: List<String> = listOf(
        "colors.accent",
        "colors.page",
        "colors.primary",
        "colors.secondary",
        "colors.tertiary",
        "colors.textPrimary",
        "geometry.pageOuterMarginH",
        "geometry.statusDotDiameter",
        "spacing.badgeInsetV",
        "spacing.iconText",
        "typography.body",
        "typography.caption",
        "typography.secondary",
    )
}
