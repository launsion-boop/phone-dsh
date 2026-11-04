// 配置文件: the redacted settings document DSH exposes, read-only, with a share.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/NativeSettingsDocumentPage.swift`
// (39 lines) at iOS HEAD, mirrored through
// `spec/ui/v1/pages/native-settings-document.json` (1 untitled region / 2 rows /
// 2 actions):
//
//   * a `.footnote` line that says what the document is: 仅显示 DSH 已脱敏的设置
//     描述与 revision；密钥和本机路径不会出现在这里。;
//   * a disabled, monospaced `TextEditor` holding `model.settingsDocument()` —
//     the redacted JSON the settings model builds, never a secret and never a
//     local path;
//   * a leading `ShareLink` (accessible名 导出脱敏配置, disabled while the
//     document is empty) and a trailing 完成 that dismisses the sheet.
//
// The baseline never renders a failure: `.task` refreshes the model and the
// `settingsDocument()` fallback is `{}`. Android's host may genuinely not have
// the read yet — `PdshNavFacts` carries no settings document — so the page keeps
// the states apart instead of drawing an empty editor that would read as "DSH
// has no settings":
//
//   LOADING  — a read is in flight;
//   READY    — a non-blank document, drawn verbatim in 17 pt monospace;
//   EMPTY    — the host reported an empty document (`""`, not `null`);
//   UNKNOWN  — the host did not report one at all (`null`), the honest default;
//   FAILED   — the read failed; the reason is shown, no document is claimed.
//
// Geometry: the sub-page frame, the page margin and the type roles come from
// `com.phonedsh.ui.surface` / `LocalUiType`; the document's 17 pt *monospace* is
// the baseline's `.system(.body, design: .monospaced)`, composed from the
// `typography.rowLabel` size and the platform's monospace family, because
// `tokens.json` declares no 17 pt mono role.
//
// Contract note: 完成 is the contract's only labelled action here (the share is
// an unlabelled glyph action whose accessible name is 导出脱敏配置), so the bar
// action is a page-local composable whose first parameter is the label — the
// checker's documented page-local button-wrapper idiom.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.settingsFootnoteStyle
import com.phonedsh.ui.surface.settingsLabelStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Facts and state
// ---------------------------------------------------------------------------

/** What the document read produced. */
public enum class SettingsDocumentStatus {
    /** A read is in flight; no value is claimed yet. */
    LOADING,

    /** A non-blank redacted document. */
    READY,

    /** The host reported an empty document (it read, and there is nothing). */
    EMPTY,

    /** The host did not report a document at all. */
    UNKNOWN,

    /** The read failed; [SettingsDocumentScreenState.failure] says why. */
    FAILED,
}

/**
 * The page's read-only input.
 *
 * @param document the redacted document text. `null` = not reported; `""` = read
 *   and empty — the two are different states and render differently.
 * @param failure the read's failure message, when it failed.
 * @param loading whether a read is in flight. It wins over [document], because a
 *   document it already returned is the previous read's.
 */
@Immutable
public data class SettingsDocumentFacts(
    public val document: String? = null,
    public val failure: String? = null,
    public val loading: Boolean = false,
)

/**
 * The page state.
 *
 * @param status the one state this page is in.
 * @param document the document to draw; non-null only for [SettingsDocumentStatus.READY]
 *   (and the resolved text for `EMPTY` is `""`).
 * @param failure the failure text; non-null only for [SettingsDocumentStatus.FAILED].
 * @param canShare true when the host can share *and* there is a document to share.
 *
 * The document is always read-only: the baseline's editor is `.disabled(true)`, so
 * there is no write path to model and no field pretending one could be enabled.
 */
@Immutable
public data class SettingsDocumentScreenState(
    public val status: SettingsDocumentStatus,
    public val document: String?,
    public val failure: String?,
    public val canShare: Boolean,
) {
    public companion object {
        /**
         * Projects the facts into the page state.
         *
         * @param facts what the host read.
         * @param shareAvailable whether the host can hand the document to the
         *   system share sheet. `false` keeps the bar glyph disabled instead of
         *   drawing a share that cannot happen.
         */
        public fun from(
            facts: SettingsDocumentFacts,
            shareAvailable: Boolean = false,
        ): SettingsDocumentScreenState {
            val status = when {
                facts.loading -> SettingsDocumentStatus.LOADING
                facts.failure != null -> SettingsDocumentStatus.FAILED
                facts.document == null -> SettingsDocumentStatus.UNKNOWN
                facts.document.isBlank() -> SettingsDocumentStatus.EMPTY
                else -> SettingsDocumentStatus.READY
            }
            return SettingsDocumentScreenState(
                status = status,
                document = facts.document,
                failure = facts.failure,
                canShare = shareAvailable && status == SettingsDocumentStatus.READY,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

/**
 * The 配置文件 page.
 *
 * @param state the pure screen state ([SettingsDocumentScreenState.from]).
 * @param onShare the baseline's `ShareLink`; `null` when the host has no share
 *   command (the glyph then stays disabled and the page says why).
 * @param onDone the baseline's 完成: dismiss the sheet.
 */
@Composable
public fun NativeSettingsDocumentPage(
    state: SettingsDocumentScreenState,
    onShare: (() -> Unit)?,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    SettingsSubPageFrame(
        modifier = modifier,
        title = UiStrings.SETTINGS_DOCUMENT_TITLE,
        rootTag = UiPageTags.SETTINGS_DOCUMENT_ROOT,
        trailing = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                SettingsDocumentShareAction(
                    onShare = onShare,
                    canShare = state.canShare,
                    modifier = Modifier.testTag(UiPageTags.SETTINGS_DOCUMENT_SHARE),
                )
                SettingsDocumentBarAction(
                    label = UiStrings.SETTINGS_DONE,
                    onClick = onDone,
                    modifier = Modifier.testTag(UiPageTags.SETTINGS_DOCUMENT_DONE),
                )
            }
        },
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = tokens.geometry.pageOuterMarginH),
        ) {
            BasicText(
                text = UiStrings.SETTINGS_DOCUMENT_REDACTION_NOTE,
                style = settingsFootnoteStyle().copy(color = tokens.colors.secondary),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = tokens.spacing.cardInset)
                    .testTag(UiPageTags.SETTINGS_DOCUMENT_NOTE),
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .padding(top = tokens.spacing.iconText),
            ) {
                when (state.status) {
                    SettingsDocumentStatus.READY -> BasicText(
                        text = state.document.orEmpty(),
                        style = type.rowLabel.copy(
                            fontFamily = FontFamily.Monospace,
                            color = tokens.colors.primary,
                        ),
                        modifier = Modifier
                            .fillMaxSize()
                            .testTag(UiPageTags.SETTINGS_DOCUMENT_BODY)
                            .verticalScroll(rememberScrollState()),
                    )

                    SettingsDocumentStatus.LOADING -> SettingsDocumentMessage(
                        text = UiStrings.SETTINGS_DOCUMENT_LOADING,
                        ink = tokens.colors.tertiary,
                    )

                    SettingsDocumentStatus.EMPTY -> SettingsDocumentMessage(
                        text = UiStrings.SETTINGS_DOCUMENT_EMPTY,
                        ink = tokens.colors.secondary,
                    )

                    SettingsDocumentStatus.UNKNOWN -> SettingsDocumentMessage(
                        text = UiStrings.SETTINGS_DOCUMENT_UNKNOWN,
                        detail = UiStrings.SETTINGS_DOCUMENT_UNKNOWN_HINT,
                        ink = tokens.colors.tertiary,
                    )

                    SettingsDocumentStatus.FAILED -> SettingsDocumentMessage(
                        text = UiStrings.SETTINGS_DOCUMENT_FAILED.format(state.failure ?: ""),
                        ink = tokens.colors.warning,
                    )
                }
            }
            BasicText(
                text = if (state.canShare) {
                    UiStrings.SETTINGS_DOCUMENT_READ_ONLY
                } else {
                    UiStrings.SETTINGS_DOCUMENT_SHARE_UNAVAILABLE
                },
                style = settingsFootnoteStyle().copy(color = tokens.colors.tertiary),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = tokens.spacing.iconText)
                    .testTag(UiPageTags.SETTINGS_DOCUMENT_READ_ONLY),
            )
        }
    }
}

/** One status line, optionally with its explanatory second line. */
@Composable
private fun SettingsDocumentMessage(
    text: String,
    ink: Color,
    detail: String? = null,
) {
    val tokens = LocalUiTokens.current
    Column(modifier = Modifier.fillMaxWidth()) {
        BasicText(
            text = text,
            style = LocalUiType.current.body.copy(color = ink),
            modifier = Modifier.testTag(UiPageTags.SETTINGS_DOCUMENT_STATUS),
        )
        if (detail != null) {
            BasicText(
                text = detail,
                style = LocalUiType.current.secondary.copy(color = tokens.colors.tertiary),
                modifier = Modifier.padding(top = tokens.spacing.iconText),
            )
        }
    }
}

/**
 * The share glyph (`square.and.arrow.up`): a bar action whose accessible name is
 * 导出脱敏配置, disabled while there is nothing to share or no host share.
 */
@Composable
private fun SettingsDocumentShareAction(
    onShare: (() -> Unit)?,
    canShare: Boolean,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val enabled = canShare && onShare != null
    BasicText(
        text = SHARE_GLYPH,
        style = settingsLabelStyle().copy(
            color = if (enabled) tokens.colors.accent else tokens.colors.tertiary,
        ),
        modifier = modifier
            .clickable(enabled = enabled, role = Role.Button) { onShare?.invoke() }
            .semantics { contentDescription = UiStrings.SETTINGS_DOCUMENT_SHARE }
            .padding(tokens.spacing.iconText),
    )
}

/**
 * The bar's 完成: 17 pt accent text in the 44 pt bar.
 *
 * The first parameter is [label] on purpose — see the file header's contract
 * note; the page-structure contract lists 完成 as this page's labelled action.
 */
@Composable
private fun SettingsDocumentBarAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = label,
        style = settingsLabelStyle().copy(color = tokens.colors.accent),
        maxLines = 1,
        modifier = modifier
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label }
            .padding(tokens.spacing.iconText),
    )
}

/** The baseline's `square.and.arrow.up`, drawn as its nearest text glyph. */
private const val SHARE_GLYPH: String = "⤴"

/** The tokens this page reads; `PageTokenReferenceTest` pins the inventory. */
internal object NativeSettingsDocumentPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_ROW_LABEL,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
    )
}
