// 工作过程设置：只向现有偏好写入已知选项。
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import com.phonedsh.ui.SettingsMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SettingsCardGap
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsGroupCard
import com.phonedsh.ui.surface.SettingsGroupedRow
import com.phonedsh.ui.surface.SettingsRowFrame
import com.phonedsh.ui.surface.SettingsRowLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsSwitch
import com.phonedsh.ui.theme.LocalUiTokens

/** Controls backed by the host's existing work-process preference store. */
@Composable
public fun ConversationSettingsPage(
    preferences: SettingsPreferences,
    languageId: String? = null,
    busyEnterMode: BusyEnterMode?,
    onSelectPreference: ((SettingsPreferenceChoice) -> Unit)?,
    onSelectBusyEnterMode: ((BusyEnterMode) -> Unit)?,
    onToggleDeveloperTools: ((Boolean) -> Unit)?,
    modifier: Modifier = Modifier,
    embedded: Boolean = true,
    onBack: () -> Unit = {},
) {
    fun native(chinese: String, english: String): String = UiStrings.settingsNativeText(languageId, chinese, english)
    val screen: @Composable () -> Unit = {
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag(CONVERSATION_SETTINGS_LIST_TAG),
            contentPadding = PaddingValues(top = com.phonedsh.ui.surface.SettingsSubPageGroupedTopInset),
            verticalArrangement = Arrangement.spacedBy(SettingsCardGap),
        ) {
            item(key = "work-steps") {
                Column {
                    com.phonedsh.ui.surface.SettingsSectionLabel(native("工作步骤", UiStrings.WORK_DETAILS_STEPS_EN))
                    SettingsGroupCard {
                        ChoiceRow(
                            title = native(UiStrings.WORK_DETAILS_SHOW, UiStrings.WORK_DETAILS_SHOW_EN),
                            tag = SettingsScreenState.TRANSCRIPT_VIEW_ROW_ID,
                            current = preferences.transcriptView?.id?.let { transcriptLabel(it, languageId) },
                            options = TranscriptViewMode.entries.map { SettingsMenuOption(it.id, transcriptLabel(it.id, languageId)) },
                            enabled = onSelectPreference != null,
                            onSelect = { id -> onSelectPreference?.invoke(SettingsPreferenceChoice(SettingsScreenState.TRANSCRIPT_VIEW_ROW_ID, id)) },
                        )
                        ChoiceRow(
                            title = native(UiStrings.WORK_DETAILS_COLLAPSE, UiStrings.WORK_DETAILS_COLLAPSE_EN),
                            tag = SettingsScreenState.COLLAPSE_TIMING_ROW_ID,
                            current = preferences.collapseTiming?.id?.let { collapseLabel(it, languageId) },
                            options = CollapseTiming.entries.map { SettingsMenuOption(it.id, collapseLabel(it.id, languageId)) },
                            enabled = onSelectPreference != null,
                            onSelect = { id -> onSelectPreference?.invoke(SettingsPreferenceChoice(SettingsScreenState.COLLAPSE_TIMING_ROW_ID, id)) },
                        )
                        DeveloperToolsRow(preferences.developerTools, onToggleDeveloperTools, languageId)
                    }
                }
            }
            item(key = "sending-usage") {
                Column {
                    com.phonedsh.ui.surface.SettingsSectionLabel(native(UiStrings.WORK_DETAILS_SENDING, UiStrings.WORK_DETAILS_SENDING_EN))
                    SettingsGroupCard {
                        ChoiceRow(
                            title = native(UiStrings.WORK_DETAILS_BUSY, UiStrings.WORK_DETAILS_BUSY_EN),
                            tag = SettingsScreenState.BUSY_ENTER_ROW_ID,
                            current = busyEnterMode?.let { busyEnterLabel(it, languageId) },
                            options = listOf(
                                SettingsMenuOption("queue", native(UiStrings.WORK_DETAILS_QUEUE, UiStrings.WORK_DETAILS_QUEUE_EN)),
                                SettingsMenuOption("steer", native(UiStrings.WORK_DETAILS_STEER, UiStrings.WORK_DETAILS_STEER_EN)),
                            ),
                            enabled = onSelectBusyEnterMode != null,
                            onSelect = { id -> BusyEnterMode.entries.firstOrNull { it.id == id }?.let { onSelectBusyEnterMode?.invoke(it) } },
                        )
                        ChoiceRow(
                            title = native(UiStrings.WORK_DETAILS_PERF, UiStrings.WORK_DETAILS_PERF_EN),
                            tag = SettingsScreenState.PERFORMANCE_ROW_ID,
                            current = preferences.performanceUsage?.id?.let { performanceLabel(it, languageId) },
                            options = PerformanceUsage.entries.map { SettingsMenuOption(it.id, performanceLabel(it.id, languageId)) },
                            enabled = onSelectPreference != null,
                            onSelect = { id -> onSelectPreference?.invoke(SettingsPreferenceChoice(SettingsScreenState.PERFORMANCE_ROW_ID, id)) },
                            dividerBelow = false,
                        )
                    }
                    SettingsFootnoteRow(
                        text = native(
                            UiStrings.WORK_DETAILS_QUEUE_FOOTER,
                            UiStrings.WORK_DETAILS_QUEUE_FOOTER_EN,
                        ),
                        modifier = Modifier.testTag(CONVERSATION_SETTINGS_NOTE_TAG),
                    )
                }
            }
        }
    }
    if (embedded) screen() else {
        SettingsSubPageFrame(title = native(UiStrings.SETTINGS_ROW_WORK_DETAILS, UiStrings.SETTINGS_ROW_WORK_DETAILS_EN), onBack = onBack, modifier = modifier, grouped = true) { screen() }
    }
}

/**
 * One picker row plus its option list.
 *
 * The iOS source (`SettingsPage.swift:508`, `:515`, `:527`, `:532`) is a
 * `Picker`, i.e. a system menu; it is not a `DisclosureGroup` and has no
 * `withAnimation` / `motion.disclosure`. The inline rows below are Android's
 * rendering of that menu, so they stay static: §7 motion is not added where the
 * baseline does not animate the disclosure.
 */
@Composable
private fun ChoiceRow(
    title: String,
    tag: String,
    current: String?,
    options: List<SettingsMenuOption>,
    enabled: Boolean,
    onSelect: (String) -> Unit,
    dividerBelow: Boolean = true,
) {
    var expanded by remember { mutableStateOf(false) }
    SettingsGroupedRow(
        title = title,
        value = current ?: UiStrings.UNKNOWN,
        chevron = true,
        enabled = enabled,
        dividerBelow = dividerBelow && !expanded,
        modifier = Modifier.testTag(tag),
        onClick = if (enabled) ({ expanded = !expanded }) else null,
    )
    if (expanded) {
        options.forEachIndexed { index, option ->
            SettingsGroupedRow(
                title = option.title,
                modifier = Modifier.testTag("$tag.option.${option.id}"),
                dividerBelow = index != options.lastIndex,
                onClick = {
                    expanded = false
                    onSelect(option.id)
                },
            )
        }
    }
}

@Composable
private fun DeveloperToolsRow(value: FactState, onToggle: ((Boolean) -> Unit)?, languageId: String?) {
    val label = UiStrings.settingsNativeText(languageId, UiStrings.WORK_DETAILS_CODE_VIEW, UiStrings.WORK_DETAILS_CODE_VIEW_EN)
    val known = value != FactState.UNKNOWN && onToggle != null
    val checked = value == FactState.YES
    if (!known) {
        SettingsGroupedRow(
            title = label,
            value = when (value) {
                FactState.YES -> UiStrings.SETTINGS_BACKGROUND_ON
                FactState.NO -> UiStrings.SETTINGS_BACKGROUND_OFF
                FactState.UNKNOWN -> UiStrings.UNKNOWN
            },
            enabled = false,
            dividerBelow = false,
            modifier = Modifier.testTag(SettingsScreenState.DEVELOPER_TOOLS_ROW_ID),
        )
        return
    }
    SettingsRowFrame(
        dividerBelow = false,
        role = Role.Switch,
        enabled = true,
        onClick = { onToggle?.invoke(!checked) },
        stateValue = if (checked) UiStrings.SETTINGS_BACKGROUND_ON else UiStrings.SETTINGS_BACKGROUND_OFF,
        modifier = Modifier.testTag(SettingsScreenState.DEVELOPER_TOOLS_ROW_ID),
    ) {
        SettingsRowLabel(text = label, modifier = Modifier.weight(1f))
        SettingsSwitch(checked = checked, enabled = true)
    }
}

private fun busyEnterLabel(mode: BusyEnterMode, languageId: String?): String = when (mode) {
    BusyEnterMode.QUEUE -> UiStrings.settingsNativeText(languageId, UiStrings.WORK_DETAILS_QUEUE, UiStrings.WORK_DETAILS_QUEUE_EN)
    BusyEnterMode.STEER -> UiStrings.settingsNativeText(languageId, UiStrings.WORK_DETAILS_STEER, UiStrings.WORK_DETAILS_STEER_EN)
}

private fun transcriptLabel(id: String, languageId: String?): String = when (id) {
    TranscriptViewMode.COMPACT.id -> UiStrings.settingsNativeText(languageId, UiStrings.WORK_DETAILS_COMPACT, UiStrings.WORK_DETAILS_COMPACT_EN)
    TranscriptViewMode.STANDARD.id -> UiStrings.settingsNativeText(languageId, "标准", "Standard")
    TranscriptViewMode.DETAILED.id -> UiStrings.settingsNativeText(languageId, "详细", "Detailed")
    TranscriptViewMode.VERBOSE.id -> UiStrings.settingsNativeText(languageId, UiStrings.WORK_DETAILS_VERBOSE, UiStrings.WORK_DETAILS_VERBOSE_EN)
    else -> id
}

private fun collapseLabel(id: String, languageId: String?): String = when (id) {
    CollapseTiming.COMPLETION.id -> UiStrings.settingsNativeText(languageId, UiStrings.WORK_DETAILS_COLLAPSE_DONE, UiStrings.WORK_DETAILS_COLLAPSE_DONE_EN)
    CollapseTiming.NEXT_INPUT.id -> UiStrings.settingsNativeText(languageId, UiStrings.WORK_DETAILS_COLLAPSE_NEXT, UiStrings.WORK_DETAILS_COLLAPSE_NEXT_EN)
    else -> id
}

private fun performanceLabel(id: String, languageId: String?): String = when (id) {
    PerformanceUsage.COMPACT.id -> UiStrings.settingsNativeText(languageId, UiStrings.WORK_DETAILS_COMPACT, UiStrings.WORK_DETAILS_COMPACT_EN)
    PerformanceUsage.DETAILED.id -> UiStrings.settingsNativeText(languageId, UiStrings.WORK_DETAILS_VERBOSE, "Detailed")
    else -> id
}

internal const val CONVERSATION_SETTINGS_LIST_TAG: String = "pdsh.settings.conversation.list"
internal const val CONVERSATION_SETTINGS_NOTE_TAG: String = "pdsh.settings.conversation.note"
