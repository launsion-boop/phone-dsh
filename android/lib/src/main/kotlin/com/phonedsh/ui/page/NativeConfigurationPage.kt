// Session configuration: the built-in settings groups, permissions and plugins.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row NativeConfigurationPage (会话级与插件配置;
// entry: 页头 `⋯` → 本会话设置; exit: sheet), §3.1 (the ScreenState layer) and
// §5 (`insets`).
//
// The page has no harness event anchor. Every group, field, permission mode and
// plugin entry is a host read, so §3.1 rule 3 makes the read-only snapshot the
// UiState-side input and `from(snapshot, local)` a pure function. The Android
// host does not expose a settings-write command yet; the page therefore shows
// the reported values, names the read/write fact and hands saving to the host.
// It never invents a second settings store.
//
// The states that look alike are kept apart:
//   * a snapshot with no reported content is the empty state;
//   * an unreported snapshot is 未知, never "no settings" and never `0 个条目`;
//   * a failed read is 失败 and drops every value claim;
//   * inside a group, a null field list is 设置项未知, while an empty list is
//     这个分组没有设置项. Inside the plugin inventory the same split holds for
//     the plugin list and the experimental-plugin list.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`); the header,
// section header and InfoRow floors live in `PageScaffold.kt`, and the list gap
// comes from `pageListGap`. No signature-surface geometry is reused, so no
// `unverified geometry` marker applies.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

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
@Immutable
public data class ConfigurationField(
    public val id: String,
    public val title: String,
    public val value: String? = null,
    public val detail: String? = null,
    public val overridden: Boolean = false,
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

/** One experimental plugin row; `loaded` is a three-valued fact. */
@Immutable
public data class ConfigurationExperimentalPlugin(
    public val id: String,
    public val title: String,
    public val status: String? = null,
    public val loaded: FactState = FactState.UNKNOWN,
)

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
)

/**
 * The complete configuration screen state.
 *
 * @param status the four-state outcome; [ConfigurationStatus.FAILED] wins because
 *   a failed read proves nothing about the values.
 * @param sessionTitle the configured session's title, or `null` when unread.
 * @param writableValue the visible read/write word.
 * @param writableTone its ink.
 * @param sections the built-in groups plus the fixed permission, plugin-info,
 *   experimental-plugin and installed-plugin groups.
 * @param webSearchRow the navigation row into the web-search page; always present
 *   in [ConfigurationStatus.READY] because it does not depend on the snapshot.
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
    public val notes: List<PageNote>,
    public val failure: String?,
    public val hasUnmeasuredValues: Boolean,
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
        append(sections.joinToString(",") { section ->
            "${section.id}=${if (section.expanded) "1" else "0"}:${section.rows.size}"
        }).append(':')
        append(notes.size).append(':')
        append(if (hasUnmeasuredValues) "partial" else "complete")
    }

    public companion object {
        public const val PERMISSION_SECTION_ID: String = "config.permission"
        public const val INFO_SECTION_ID: String = "config.info"
        public const val EXPERIMENTAL_SECTION_ID: String = "config.experimental"
        public const val INSTALLED_SECTION_ID: String = "config.installed"
        public const val WEB_SEARCH_ROW_ID: String = "config.websearch"

        /** The host namespace a group row belongs to, as a stable section id. */
        public fun groupSectionId(namespace: String): String = "config.group.$namespace"

        /**
         * Projects (facts, fold script) into the screen state.
         *
         * Pure: no clock, no I/O and no engine call. The host supplies every
         * value and every failure message, so the same facts and the same fold
         * script always yield the same state sequence (§3.1).
         */
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
            if (status != ConfigurationStatus.READY) {
                return ConfigurationScreenState(
                    status = status,
                    sessionTitle = snapshot?.sessionTitle,
                    writableValue = UiStrings.UNKNOWN,
                    writableTone = PageTone.UNKNOWN,
                    sections = emptyList(),
                    webSearchRow = null,
                    notes = emptyList(),
                    failure = facts.failure,
                    hasUnmeasuredValues = false,
                )
            }
            val measured = requireNotNull(snapshot)
            val settingsWritable = measured.settingsWritable
            val sections = buildList {
                measured.groups.orEmpty().forEach { group ->
                    add(groupSection(group, local))
                }
                add(permissionSection(measured, local))
                add(infoSection(measured, local))
                add(experimentalSection(measured, local))
                add(installedSection(measured, local))
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
            }
            val hasUnmeasuredValues = measured.sessionTitle == null ||
                settingsWritable == FactState.UNKNOWN ||
                sections.any { section -> section.rows.any { row -> row.tone == PageTone.UNKNOWN } }
            return ConfigurationScreenState(
                status = ConfigurationStatus.READY,
                sessionTitle = measured.sessionTitle,
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
                webSearchRow = ConfigurationRowView(
                    id = WEB_SEARCH_ROW_ID,
                    title = UiStrings.CONFIGURATION_WEB_SEARCH,
                ),
                notes = notes,
                failure = null,
                hasUnmeasuredValues = hasUnmeasuredValues,
            )
        }

        private fun groupSection(
            group: ConfigurationGroup,
            local: ConfigurationLocalState,
        ): ConfigurationSectionView {
            val id = groupSectionId(group.namespace)
            val fields = group.fields
            val writableRow = ConfigurationRowView(
                id = "$id.writable",
                title = UiStrings.CONFIGURATION_WRITABLE,
                value = when (group.writable) {
                    FactState.YES -> UiStrings.CONFIGURATION_WRITABLE_YES
                    FactState.NO -> UiStrings.CONFIGURATION_WRITABLE_NO
                    FactState.UNKNOWN -> UiStrings.CONFIGURATION_WRITABLE_UNKNOWN
                },
                subtitle = group.detail,
                tone = when (group.writable) {
                    FactState.YES -> PageTone.ON
                    FactState.NO -> PageTone.NORMAL
                    FactState.UNKNOWN -> PageTone.UNKNOWN
                },
            )
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
                fields.map { field ->
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
                    )
                }
            }
            val rows = listOf(writableRow) + fieldRows
            return ConfigurationSectionView(
                id = id,
                title = group.title,
                trailing = if (fields == null) {
                    UiStrings.UNKNOWN
                } else {
                    UiStrings.CONFIGURATION_GROUP_ITEMS.format(fields.size)
                },
                expanded = local.fold.isExpanded(id),
                rows = rows,
                emptyText = if (fields != null && fields.isEmpty()) {
                    UiStrings.CONFIGURATION_GROUP_EMPTY
                } else {
                    null
                },
            )
        }

        private fun permissionSection(
            snapshot: ConfigurationSnapshot,
            local: ConfigurationLocalState,
        ): ConfigurationSectionView {
            val modes = snapshot.permissionModes
            val selected = snapshot.defaultPermissionModeId?.let { id ->
                modes?.firstOrNull { it.id == id }
            }
            val rows = when {
                modes == null -> listOf(
                    ConfigurationRowView(
                        id = "$PERMISSION_SECTION_ID.unknown",
                        title = UiStrings.CONFIGURATION_PERMISSION_UNKNOWN,
                        value = UiStrings.UNKNOWN,
                        subtitle = snapshot.permissionFailure ?: UiStrings.SETTINGS_UNKNOWN_HINT,
                        tone = PageTone.UNKNOWN,
                    ),
                )

                modes.isEmpty() -> listOf(
                    ConfigurationRowView(
                        id = "$PERMISSION_SECTION_ID.empty",
                        title = UiStrings.CONFIGURATION_PERMISSION_EMPTY,
                        subtitle = UiStrings.CONFIGURATION_DEFAULT_PERMISSION_HINT,
                    ),
                )

                else -> listOf(
                    ConfigurationRowView(
                        id = "$PERMISSION_SECTION_ID.current",
                        title = UiStrings.CONFIGURATION_DEFAULT_PERMISSION_ROW,
                        value = selected?.name ?: UiStrings.UNKNOWN,
                        subtitle = selected?.detail
                            ?: UiStrings.CONFIGURATION_DEFAULT_PERMISSION_HINT,
                        tone = if (selected == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    ),
                )
            }
            return ConfigurationSectionView(
                id = PERMISSION_SECTION_ID,
                title = UiStrings.CONFIGURATION_DEFAULT_PERMISSION,
                trailing = when {
                    modes == null -> UiStrings.UNKNOWN
                    else -> UiStrings.CONFIGURATION_PERMISSION_COUNT.format(modes.size)
                },
                expanded = local.fold.isExpanded(PERMISSION_SECTION_ID),
                rows = rows,
            )
        }

        private fun infoSection(
            snapshot: ConfigurationSnapshot,
            local: ConfigurationLocalState,
        ): ConfigurationSectionView {
            val message = snapshot.pluginManagementMessage
            return ConfigurationSectionView(
                id = INFO_SECTION_ID,
                title = UiStrings.CONFIGURATION_PLUGIN_INFO,
                trailing = null,
                expanded = local.fold.isExpanded(INFO_SECTION_ID),
                rows = listOf(
                    ConfigurationRowView(
                        id = "$INFO_SECTION_ID.message",
                        title = UiStrings.CONFIGURATION_PLUGIN_SCOPE,
                        value = null,
                        subtitle = message ?: UiStrings.CONFIGURATION_PLUGIN_INFO_UNKNOWN,
                        tone = if (message == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    ),
                    ConfigurationRowView(
                        id = "$INFO_SECTION_ID.add",
                        title = UiStrings.CONFIGURATION_ADD_DISABLED,
                        value = UiStrings.UNAVAILABLE,
                        subtitle = UiStrings.CONFIGURATION_ADD_DISABLED_HINT,
                        tone = PageTone.DEGRADED,
                        enabled = false,
                    ),
                ),
            )
        }

        private fun experimentalSection(
            snapshot: ConfigurationSnapshot,
            local: ConfigurationLocalState,
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
                expanded = local.fold.isExpanded(EXPERIMENTAL_SECTION_ID),
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
            local: ConfigurationLocalState,
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
                expanded = local.fold.isExpanded(INSTALLED_SECTION_ID),
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
 * a disclosure; every other group starts expanded.
 *
 * @param fold which sections the user collapsed.
 */
@Immutable
public data class ConfigurationLocalState(
    public val fold: FoldState = FoldState(
        collapsedIds = setOf(ConfigurationScreenState.INSTALLED_SECTION_ID),
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
 * @param state the pure screen state (`ConfigurationScreenState.from`).
 * @param onDone close the sheet (the baseline's `完成`).
 * @param onToggleSection a group header was tapped; the host applies
 *   `ConfigurationUiEvent.ToggleSection` and re-projects.
 * @param onRefresh re-read the snapshot; `null` hides the header action.
 * @param onOpenWebSearch open the web-search page; `null` makes the row read-only.
 * @param onRetry retry the failed read; `null` renders no retry row.
 * @param onDismissFailure dismiss the failure line; `null` renders no dismiss row.
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
) {
    PageFrame(
        title = UiStrings.CONFIGURATION_TITLE,
        modifier = modifier,
        rootTag = UiPageTags.CONFIGURATION_ROOT,
        actions = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (onRefresh != null) {
                    SessionTextAction(
                        label = UiStrings.CONFIGURATION_REFRESH,
                        onClick = onRefresh,
                        tone = SessionActionTone.SECONDARY,
                    )
                }
                SessionTextAction(
                    label = UiStrings.CONFIGURATION_DONE,
                    onClick = onDone,
                    tone = SessionActionTone.ACCENT,
                    modifier = Modifier.testTag(UiPageTags.CONFIGURATION_DONE),
                )
            }
        },
    ) {
        when (state.status) {
            ConfigurationStatus.FAILED -> ConfigurationFailureBlock(
                failure = state.failure,
                onRetry = onRetry,
                onDismissFailure = onDismissFailure,
            )

            ConfigurationStatus.UNKNOWN -> ConfigurationUnknownList()

            ConfigurationStatus.EMPTY -> EmptyHint(
                title = UiStrings.CONFIGURATION_EMPTY,
                hint = UiStrings.CONFIGURATION_EMPTY_HINT,
                tag = UiPageTags.CONFIGURATION_EMPTY,
            )

            ConfigurationStatus.READY -> ConfigurationContent(
                state = state,
                onToggleSection = onToggleSection,
                onOpenWebSearch = onOpenWebSearch,
            )
        }
    }
}

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
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        item(key = "config.unknown") {
            InfoRow(
                title = UiStrings.CONFIGURATION_UNKNOWN_STATE,
                value = null,
                subtitle = UiStrings.CONFIGURATION_UNKNOWN_HINT,
                modifier = Modifier.testTag(UiPageTags.CONFIGURATION_UNKNOWN),
            )
        }
        item(key = "config.unknown.detail") {
            InfoRow(
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
    onToggleSection: (String) -> Unit,
    onOpenWebSearch: (() -> Unit)?,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.CONFIGURATION_LIST),
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        item(key = "config.intro") {
            ConfigurationIntro()
        }
        if (state.hasUnmeasuredValues) {
            item(key = "config.unmeasured") {
                InfoRow(
                    title = UiStrings.UNKNOWN,
                    value = null,
                    subtitle = UiStrings.CONFIGURATION_UNMEASURED_HINT,
                    tone = PageTone.UNKNOWN,
                    modifier = Modifier.testTag(UiPageTags.CONFIGURATION_UNMEASURED),
                )
            }
        }
        item(key = "config.session") {
            InfoRow(
                title = UiStrings.CONFIGURATION_SESSION,
                value = state.sessionTitle ?: UiStrings.UNKNOWN,
                tone = if (state.sessionTitle == null) PageTone.UNKNOWN else PageTone.NORMAL,
                subtitle = if (state.sessionTitle == null) UiStrings.SETTINGS_UNKNOWN_HINT else null,
                modifier = Modifier.testTag(UiPageTags.CONFIGURATION_SESSION),
            )
        }
        item(key = "config.writable") {
            InfoRow(
                title = UiStrings.CONFIGURATION_WRITABLE,
                value = state.writableValue,
                tone = state.writableTone,
                subtitle = if (state.writableTone == PageTone.UNKNOWN) {
                    UiStrings.SETTINGS_UNKNOWN_HINT
                } else {
                    null
                },
                modifier = Modifier.testTag(UiPageTags.CONFIGURATION_WRITABLE),
            )
        }
        state.webSearchRow?.let { row ->
            item(key = "config.websearch") {
                InfoRow(
                    title = row.title,
                    value = row.value,
                    subtitle = row.subtitle,
                    onClick = onOpenWebSearch,
                    modifier = Modifier.testTag(UiPageTags.CONFIGURATION_WEB_SEARCH),
                )
            }
        }
        state.notes.forEach { note ->
            item(key = "config.note.${note.id}") {
                SessionFailureLine(
                    message = note.text,
                    tag = UiPageTags.CONFIGURATION_NOTE_PREFIX + note.id,
                )
            }
        }
        state.sections.forEach { section ->
            item(key = "config.header.${section.id}") {
                SectionHeader(
                    title = section.title,
                    expanded = section.expanded,
                    onToggle = { onToggleSection(section.id) },
                    trailing = section.trailing,
                    tag = UiPageTags.CONFIGURATION_SECTION_PREFIX + section.id,
                )
            }
            if (section.expanded) {
                items(count = section.rows.size, key = { index -> section.rows[index].id }) { index ->
                    val row = section.rows[index]
                    InfoRow(
                        title = row.title,
                        value = row.value,
                        subtitle = row.subtitle,
                        tone = row.tone,
                        enabled = row.enabled,
                        modifier = if (row.id.startsWith("config.installed.")) {
                            Modifier.testTag(UiPageTags.CONFIGURATION_PLUGIN_ROW_PREFIX + row.id)
                        } else {
                            Modifier
                        },
                    )
                }
                if (section.emptyText != null) {
                    item(key = "config.empty.${section.id}") {
                        InfoRow(
                            title = section.emptyText,
                            value = null,
                            tone = PageTone.UNKNOWN,
                        )
                    }
                }
            }
        }
        item(key = "config.read-only") {
            ConfigurationNoteRow(text = UiStrings.CONFIGURATION_READ_ONLY)
        }
    }
}

/** The sheet's one-sentence purpose, inked with the secondary token. */
@Composable
private fun ConfigurationIntro() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = UiStrings.CONFIGURATION_INTRO,
        style = type.secondary.copy(color = tokens.colors.secondary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.CONFIGURATION_INTRO)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** One explanatory line; the ink is a token, never a second colour source. */
@Composable
private fun ConfigurationNoteRow(text: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.tertiary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.CONFIGURATION_READ_ONLY)
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
        InfoRow(
            title = UiStrings.CONFIGURATION_LOAD_FAILED,
            value = null,
            subtitle = failure,
            modifier = Modifier.testTag(UiPageTags.CONFIGURATION_FAILURE),
        )
        if (onRetry != null) {
            InfoRow(
                title = UiStrings.RETRY,
                value = null,
                onClick = onRetry,
                modifier = Modifier.testTag(UiPageTags.CONFIGURATION_RETRY),
            )
        }
        if (onDismissFailure != null) {
            InfoRow(
                title = UiStrings.DISMISS,
                value = null,
                onClick = onDismissFailure,
                modifier = Modifier.testTag(UiPageTags.CONFIGURATION_DISMISS),
            )
        }
    }
}

/** Every token this file reads; kept equal to the source by `PageTokenReferenceTest`. */
internal object NativeConfigurationPageTokens {
    val refs: List<String> = listOf(
        "colors.secondary",
        "colors.tertiary",
        "geometry.pageOuterMarginH",
        "spacing.badgeInsetV",
        "typography.caption",
        "typography.secondary",
    )
}
