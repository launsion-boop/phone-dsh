// 字号设置页：字号与字体名仅在宿主报告并提供写入时可编辑。
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.SettingsMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SettingsCardGap
import com.phonedsh.ui.surface.SettingsGroupCard
import com.phonedsh.ui.surface.SettingsRowFrame
import com.phonedsh.ui.surface.SettingsRowLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsHairline
import com.phonedsh.ui.surface.settingsLabelStyle
import com.phonedsh.ui.theme.LocalUiTokens

/** Font controls backed by existing size preference IDs and optional host font-family seams. */
@Composable
public fun FontSizeSettingsPage(
    preferences: SettingsPreferences,
    languageId: String? = null,
    onSelectPreference: ((SettingsPreferenceChoice) -> Unit)?,
    onSelectFontFamily: ((rowId: String, family: String) -> Unit)? = null,
    modifier: Modifier = Modifier,
    embedded: Boolean = true,
    onBack: () -> Unit = {},
) {
    fun native(chinese: String, english: String): String = UiStrings.settingsNativeText(languageId, chinese, english)
    val content: @Composable () -> Unit = {
        val values = listOf(
            FontSizeRole(native("会话内容", "Conversation"), SettingsScreenState.TEXT_FONT_SIZE_ROW_ID, preferences.fontSizeConversation,
                preferences.fontFamilyConversation, 10..22),
            FontSizeRole(native("代码", "Code"), SettingsScreenState.CODE_FONT_SIZE_ROW_ID, preferences.fontSizeCode,
                preferences.fontFamilyCode, 10..16),
            FontSizeRole(native("终端", UiStrings.FONT_SIZE_TERMINAL_EN), SettingsScreenState.TERMINAL_FONT_SIZE_ROW_ID, preferences.fontSizeTerminal,
                preferences.fontFamilyTerminal, 10..20),
        )
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag(FONT_SIZE_LIST_TAG),
            contentPadding = PaddingValues(top = com.phonedsh.ui.surface.SettingsSubPageGroupedTopInset),
            verticalArrangement = Arrangement.spacedBy(SettingsCardGap),
        ) {
            values.forEach { role ->
                item(key = role.rowId) {
                    Column {
                        com.phonedsh.ui.surface.SettingsSectionLabel(role.title)
                        SettingsGroupCard {
                            if (role.size == null) {
                                com.phonedsh.ui.surface.SettingsGroupedRow(
                                    title = native("字号", UiStrings.SETTINGS_ROW_FONT_SIZE_EN),
                                    value = UiStrings.UNAVAILABLE,
                                    enabled = false,
                                    modifier = Modifier.testTag(role.rowId),
                                )
                            } else {
                                FontSizeStepper(
                                    role = role,
                                    languageId = languageId,
                                    enabled = onSelectPreference != null,
                                    onChange = { next -> onSelectPreference?.invoke(SettingsPreferenceChoice(role.rowId, next.toString())) },
                                )
                            }
                            FontFamilyField(
                                rowId = role.rowId,
                                value = role.fontFamily,
                                onChange = onSelectFontFamily?.let { writer -> { family -> writer(role.rowId, family) } },
                                languageId = languageId,
                            )
                        }
                    }
                }
            }
        }
    }
    if (embedded) content() else {
        SettingsSubPageFrame(title = native("字号", UiStrings.SETTINGS_ROW_FONT_SIZE_EN), onBack = onBack, modifier = modifier, grouped = true) { content() }
    }
}

private data class FontSizeRole(
    val title: String,
    val rowId: String,
    val size: Int?,
    val fontFamily: String?,
    val range: IntRange,
)

@Composable
private fun FontSizeStepper(role: FontSizeRole, languageId: String?, enabled: Boolean, onChange: (Int) -> Unit) {
    val size = requireNotNull(role.size)
    val tokens = LocalUiTokens.current
    Column {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = HomeMetrics.DEFAULT_MIN_LIST_ROW_HEIGHT_PT.dp)
                .padding(horizontal = SettingsMetrics.ROW_CONTENT_INSET_PT.dp)
                .testTag(role.rowId),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SettingsRowLabel(text = UiStrings.settingsNativeText(languageId, "字号", UiStrings.SETTINGS_ROW_FONT_SIZE_EN), modifier = Modifier.weight(1f))
            BasicText(text = "$size pt", style = settingsLabelStyle().copy(color = tokens.colors.textSecondary))
            StepperControl(
                enabled = enabled,
                canDecrease = size > role.range.first,
                canIncrease = size < role.range.last,
                onDecrease = { onChange(size - 1) },
                onIncrease = { onChange(size + 1) },
                roleId = role.rowId,
            )
        }
        SettingsHairline()
    }
}

/**
 * The paint uses the shared HomeSpec neutral fill as the closest existing token
 * to the captured UIKit gray. Only the light capture is available; dark-stepper
 * pixel parity is not asserted. The owner can add a dedicated semantic fill token.
 */
@Composable
private fun StepperControl(
    enabled: Boolean,
    canDecrease: Boolean,
    canIncrease: Boolean,
    onDecrease: () -> Unit,
    onIncrease: () -> Unit,
    roleId: String,
) {
    val pillHeight = SettingsMetrics.FONT_STEPPER_HEIGHT_PT.dp
    val tokens = LocalUiTokens.current
    val pillFill = tokens.colors.userBubble
    val glyphBoxWidth = SettingsMetrics.FONT_STEPPER_WIDTH_PT.dp / 2f
    Box(
        modifier = Modifier
            .width(SettingsMetrics.FONT_STEPPER_WIDTH_PT.dp)
            .height(HomeMetrics.DEFAULT_MIN_LIST_ROW_HEIGHT_PT.dp)
            .testTag("$roleId.stepper"),
    ) {
        Canvas(
            modifier = Modifier
                .align(Alignment.Center)
                .width(SettingsMetrics.FONT_STEPPER_WIDTH_PT.dp)
                .height(pillHeight)
                .testTag("$roleId.stepper.pill"),
        ) {
            val radius = size.height / 2f
            drawRoundRect(
                color = pillFill,
                cornerRadius = CornerRadius(radius, radius),
            )
            val separatorTop = (size.height - SettingsMetrics.FONT_STEPPER_SEPARATOR_HEIGHT_PT.dp.toPx()) / 2f
            drawLine(
                color = tokens.colors.separator,
                start = Offset(size.width / 2f, separatorTop),
                end = Offset(size.width / 2f, separatorTop + SettingsMetrics.FONT_STEPPER_SEPARATOR_HEIGHT_PT.dp.toPx()),
                strokeWidth = tokens.stroke.hairline.toPx(),
            )
        }
        Row(
            modifier = Modifier.fillMaxSize(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            StepperGlyph(
                increasing = false,
                description = "减小字号",
                enabled = enabled && canDecrease,
                width = glyphBoxWidth,
                onClick = onDecrease,
                tag = "$roleId.decrease",
            )
            StepperGlyph(
                increasing = true,
                description = "增大字号",
                enabled = enabled && canIncrease,
                width = glyphBoxWidth,
                onClick = onIncrease,
                tag = "$roleId.increase",
            )
        }
    }
}


@Composable
private fun StepperGlyph(
    increasing: Boolean,
    description: String,
    enabled: Boolean,
    width: androidx.compose.ui.unit.Dp,
    onClick: () -> Unit,
    tag: String,
) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier
            .width(width)
            .height(HomeMetrics.DEFAULT_MIN_LIST_ROW_HEIGHT_PT.dp)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.width(SettingsMetrics.FONT_STEPPER_GLYPH_PT.dp).height(SettingsMetrics.FONT_STEPPER_GLYPH_PT.dp)) {
            val stroke = SettingsMetrics.FONT_STEPPER_STROKE_PT.dp.toPx()
            val center = size.width / 2f
            val inset = stroke / 2f
            val ink = if (enabled) tokens.colors.textPrimary else tokens.colors.textTertiary
            drawLine(
                color = ink,
                start = Offset(inset, center),
                end = Offset(size.width - inset, center),
                strokeWidth = stroke,
                cap = StrokeCap.Round,
            )
            if (increasing) {
                drawLine(
                    color = ink,
                    start = Offset(center, inset),
                    end = Offset(center, size.height - inset),
                    strokeWidth = stroke,
                    cap = StrokeCap.Round,
                )
            }
        }
    }
}

@Composable
private fun FontFamilyField(rowId: String, value: String?, onChange: ((String) -> Unit)?, languageId: String?) {
    val tokens = LocalUiTokens.current
    val editable = value != null && onChange != null
    var draft by remember(value) { mutableStateOf(value.orEmpty()) }
    SettingsRowFrame(
        dividerBelow = false,
        enabled = editable,
        modifier = Modifier.testTag("$rowId.fontFamily"),
    ) {
        BasicTextField(
            value = draft,
            onValueChange = { text ->
                draft = text
                onChange?.invoke(text)
            },
            enabled = editable,
            singleLine = true,
            textStyle = settingsLabelStyle().copy(
                color = if (editable) tokens.colors.textPrimary else tokens.colors.textTertiary,
            ),
            modifier = Modifier.weight(1f).testTag("$rowId.fontFamily.input"),
            decorationBox = { innerTextField ->
                Box {
                    if (draft.isEmpty()) {
                        BasicText(
                            text = UiStrings.settingsNativeText(languageId, FONT_FAMILY_PLACEHOLDER, UiStrings.FONT_SIZE_FAMILY_PLACEHOLDER_EN),
                            style = settingsLabelStyle().copy(color = tokens.colors.textTertiary),
                        )
                    }
                    innerTextField()
                }
            },
        )
        if (value == null) {
            BasicText(
                text = UiStrings.UNAVAILABLE,
                style = settingsLabelStyle().copy(color = tokens.colors.textTertiary),
            )
        }
    }
}

private const val FONT_FAMILY_PLACEHOLDER = "字体（留空使用系统默认）"
internal const val FONT_SIZE_LIST_TAG: String = "pdsh.settings.font-size.list"
