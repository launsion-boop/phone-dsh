// 新会话默认权限页。
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.surface.SettingsCardGap
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsGroupCard
import com.phonedsh.ui.surface.SettingsRowFrame
import com.phonedsh.ui.surface.SettingsRowLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.settingsLabelStyle
import com.phonedsh.ui.theme.LocalUiTokens

/** Preset choices for future sessions; an unread current value leaves all choices unselected. */
@Composable
public fun PermissionDefaultsPage(
    state: PermissionDefaultsState,
    onSelect: ((PermissionTier) -> Unit)?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    embedded: Boolean = false,
) {
    val page: @Composable () -> Unit = {
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag(PERMISSION_DEFAULTS_PAGE_TAG),
            contentPadding = PaddingValues(top = com.phonedsh.ui.surface.SettingsSubPageGroupedTopInset),
            verticalArrangement = Arrangement.spacedBy(SettingsCardGap),
        ) {
            item(key = "permission-defaults") {
                Column {
                    com.phonedsh.ui.surface.SettingsSectionLabel(
                        title = UiStrings.settingsNativeText(
                            state.languageId,
                            UiStrings.PERMISSION_DEFAULTS_NOTE,
                            UiStrings.PERMISSION_DEFAULTS_SCOPE_EN,
                        ),
                        modifier = Modifier.testTag(PERMISSION_DEFAULTS_NOTE_TAG),
                    )
                    state.statusMessage?.let { message ->
                        androidx.compose.foundation.text.BasicText(
                            text = message,
                            style = com.phonedsh.ui.theme.LocalUiType.current.secondary.copy(
                                color = if (state.failure != null) LocalUiTokens.current.colors.danger else LocalUiTokens.current.colors.textSecondary,
                            ),
                            modifier = Modifier.fillMaxWidth().testTag(PERMISSION_DEFAULTS_STATUS_TAG),
                        )
                    }
                    SettingsGroupCard {
                        state.options.forEachIndexed { index, option ->
                            SettingsRowFrame(
                                dividerBelow = index != state.options.lastIndex,
                                role = Role.RadioButton,
                                enabled = onSelect != null && state.writable && !state.busy && option.enabled,
                                onClick = onSelect?.let { callback -> ({ callback(option.tier) }) },
                                modifier = Modifier.testTag("$PERMISSION_DEFAULTS_OPTION_PREFIX${option.tier.name}"),
                                stateValue = if (option.selected) "已选择" else null,
                            ) {
                                SettingsRowLabel(text = option.title, modifier = Modifier.weight(1f))
                                if (option.selected) {
                                    PdshIconView(PdshIcon.CHECK, com.phonedsh.ui.HomeMetrics.composerIcon, LocalUiTokens.current.colors.accent, "已选择")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (embedded) page() else {
        SettingsSubPageFrame(
            title = UiStrings.PERMISSION_DEFAULTS_TITLE,
            onBack = onBack,
            modifier = modifier,
            grouped = true,
            rootTag = PERMISSION_DEFAULTS_PAGE_TAG,
        ) { page() }
    }
}

internal const val PERMISSION_DEFAULTS_PAGE_TAG: String = "pdsh.settings.permission-defaults"
internal const val PERMISSION_DEFAULTS_NOTE_TAG: String = "pdsh.settings.permission-defaults.note"
internal const val PERMISSION_DEFAULTS_STATUS_TAG: String = "pdsh.settings.permission-defaults.status"
internal const val PERMISSION_DEFAULTS_OPTION_PREFIX: String = "pdsh.settings.permission-defaults.option."
