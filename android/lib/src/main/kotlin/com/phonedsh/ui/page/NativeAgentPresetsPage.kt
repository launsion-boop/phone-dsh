// Agent presets: the preset roster, its default, and the read-only YAML view.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/NativeAgentPresetsPage.swift` at iOS
// HEAD 86a39aac (182 lines). Contract: `spec/ui/v1/pages/native-agent-presets.json`.
//
// Section shape (contract: 3 sections, 12 rows, none titled)
// ---------------------------------------------------------
//   1. the creator entry — 让 Agent 创建预设 plus its footnote. No header, exactly
//      like the baseline's first `Section { … }` (`NativeAgentPresetsPage.swift:106`);
//   2. the roster — 正在读取预设… while the read is in flight, then one card per
//      preset with its badges (默认 / 自定义), its wire id, its description, its
//      broken reason and the 查看配置 / 使用预设 pair, plus the section's
//      `默认已锁定` marker and its footer read-only reason;
//   3. the error line and its 重新读取 verb, only when the host reported one
//      (`:185` in the PR26 baseline).
//
// The page draws no section captions at all, because the baseline draws none: its
// three groups are visually separated by the inset-grouped card gap, not by a
// title. Adding one here would be a second design.
//
// 查看配置 opens the read-only configuration panel (the baseline's `.sheet`,
// `:166`): a monospace document that cannot be edited, closed by 完成. The YAML is
// the host's text verbatim — the page never pretty-prints or re-indents it.
//
// Facts: the roster is `null` until the host reports it, and "not reported" is a
// different statement from "the engine has no presets": the first renders the
// unknown line, the second renders 当前引擎没有预设。 — the PR26 baseline's own
// empty statement. 使用预设 is never disabled on a guess — only when the host
// itself reported the preset as broken (`:160`).
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * One preset the engine publishes.
 *
 * @param id the preset's wire id, also the row's second line.
 * @param title its display name; the host falls back to [id] itself, so this is
 *   never blank.
 * @param detail the preset's own description; empty when it has none.
 * @param isDefault whether the engine currently starts sessions from it.
 * @param broken the engine's reason the preset cannot be loaded, or `null`.
 * @param custom whether the preset is user-authored rather than built in.
 */
@Immutable
public data class NativeAgentPreset(
    public val id: String,
    public val title: String,
    public val detail: String = "",
    public val isDefault: Boolean = false,
    public val broken: String? = null,
    public val custom: Boolean = false,
)

/**
 * The page's read-only input.
 *
 * @param presets the roster; **`null` means the host has not reported one**, which
 *   is rendered as 未知 rather than as an empty engine.
 * @param isLoading whether a roster read is in flight (only shown when there is
 *   nothing to list yet, `NativeAgentPresetsPage.swift:119`).
 * @param error the host's failure text, or `null`.
 */
@Immutable
public data class NativeAgentPresetsFacts(
    public val presets: List<NativeAgentPreset>? = null,
    public val isLoading: Boolean = false,
    public val error: String? = null,
)

/** One preset's read-only configuration document, as the host returned it. */
@Immutable
public data class AgentPresetDocument(
    public val presetId: String,
    public val title: String,
    public val yaml: String,
)

/**
 * One `agentPresets/read` answer.
 *
 * The host wraps either the document or the failure, because the read is an IO
 * call the composition only starts: the page must not decide "no document" from
 * an exception it never saw.
 *
 * @param document the host's verbatim configuration, or `null` on failure.
 * @param failure the host's `code: message`, or `null` on success.
 */
@Immutable
public data class AgentPresetReadOutcome(
    public val document: AgentPresetDocument? = null,
    public val failure: String? = null,
)

/**
 * The host half of the preset page's three reads/writes.
 *
 * @param refresh re-read `agentPresets/list` (the page calls it on entry and on
 *   重新读取). It only starts the host read; the facts arrive through
 *   [NativeAgentPresetsFacts].
 * @param read `agentPresets/read` for one preset id.
 * @param use create a new session with `request.agentPreset`: `null` means the
 *   new session exists and the host moved to it, otherwise the message to show.
 */
@Immutable
public data class AgentPresetActions(
    public val refresh: () -> Unit = {},
    public val read: (suspend (String) -> AgentPresetReadOutcome)? = null,
    public val use: (suspend (String) -> String?)? = null,
)

// ---------------------------------------------------------------------------
// Local state
// ---------------------------------------------------------------------------

/**
 * The configuration panel this page owns locally.
 *
 * @param document the document on screen, or `null` when the panel is closed.
 */
@Immutable
public data class NativeAgentPresetsLocalState(
    public val document: AgentPresetDocument? = null,
)

/** The local events the roster raises. */
public sealed interface NativeAgentPresetsUiEvent {
    /** 查看配置 returned a document: open the read-only panel on it. */
    public data class OpenDocument(public val document: AgentPresetDocument) : NativeAgentPresetsUiEvent

    /** 完成: close the panel. */
    public data object CloseDocument : NativeAgentPresetsUiEvent
}

/** Folds one local event; pure, so a JVM test can replay the sequence. */
public fun NativeAgentPresetsLocalState.apply(
    event: NativeAgentPresetsUiEvent,
): NativeAgentPresetsLocalState = when (event) {
    is NativeAgentPresetsUiEvent.OpenDocument -> copy(document = event.document)
    NativeAgentPresetsUiEvent.CloseDocument -> copy(document = null)
}

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** One roster card, display-ready. */
@Immutable
public data class AgentPresetRowView(
    public val id: String,
    public val title: String,
    /** The preset's own description; `null` hides the line (the baseline's `isEmpty`). */
    public val detail: String?,
    public val isDefault: Boolean,
    public val custom: Boolean,
    /** The engine's broken reason, or `null` when the preset loads. */
    public val broken: String?,
) {
    /** 使用预设 is disabled only when the host itself said the preset is broken. */
    public val canUse: Boolean get() = broken == null

    /** Kept for the pre-PR26 call sites; the roster verb is 使用预设 now. */
    @Deprecated("Use canUse: the row's verb is 使用预设, not 设为默认.", ReplaceWith("canUse"))
    public val canBeDefault: Boolean get() = canUse
}

/** The complete agent-presets screen state. */
@Immutable
public data class NativeAgentPresetsScreenState(
    /** The roster; `null` = the host reported none (unknown, not empty). */
    public val presets: List<AgentPresetRowView>? = null,
    /** True only while a read is in flight and there is nothing to show yet. */
    public val loading: Boolean = false,
    public val error: String? = null,
    /** The open configuration panel, or `null`. */
    public val document: AgentPresetDocument? = null,
) {
    public companion object {
        /**
         * The baseline's wording when the engine returns no document for a preset
         * (`NativeAgentPresetsPage.swift:82`). The route shows it in the error line,
         * which is exactly what the baseline does when `showYAML` comes back false.
         */
        public const val NO_DOCUMENT_FAILURE: String = "引擎没有返回这个预设的配置内容。"

        /**
         * The baseline's wording when the engine exposes no writable default preset
         * (`NativeAgentPresetsPage.swift:61`).
         */
        public const val NO_WRITABLE_DEFAULT_FAILURE: String =
            "当前引擎没有提供可写的默认预设设置。"

        /** Projects the facts into the three untitled groups. */
        public fun from(
            facts: NativeAgentPresetsFacts,
            local: NativeAgentPresetsLocalState = NativeAgentPresetsLocalState(),
        ): NativeAgentPresetsScreenState = NativeAgentPresetsScreenState(
            presets = facts.presets?.map { preset ->
                AgentPresetRowView(
                    id = preset.id,
                    title = preset.title,
                    detail = preset.detail.ifEmpty { null },
                    isDefault = preset.isDefault,
                    custom = preset.custom,
                    broken = preset.broken,
                )
            },
            loading = facts.isLoading && facts.presets.isNullOrEmpty(),
            error = facts.error,
            document = local.document,
        )
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The agent-presets page.
 *
 * @param state the pure screen state (`NativeAgentPresetsScreenState.from`).
 * @param onBack leave the page (the sheet's 完成 is the shell's, this page has no
 *   toolbar of its own — the baseline's only 完成 belongs to the document panel).
 * @param onCreate 让 Agent 创建预设: open creator mode without sending a prompt.
 * @param onViewConfiguration 查看配置 for one preset id.
 * @param onUsePreset 使用预设 for one preset id: the host creates a new session
 *   with that preset and closes the settings sheet on success.
 * @param onReload 重新读取 in the error line: re-run `agentPresets/list`.
 * @param creatorUnavailableReason why 让 Agent 创建预设 is disabled (cordis absent
 *   or broken), or `null` when it is available.
 * @param openingPresetId the preset whose 使用预设 call is in flight, or `null`.
 * @param onCloseDocument 完成 in the read-only panel.
 * @param embedded render as the settings sheet's 预设 tab: no page header.
 */
@Composable
public fun NativeAgentPresetsPage(
    state: NativeAgentPresetsScreenState,
    onBack: () -> Unit = {},
    onCreate: () -> Unit = {},
    onViewConfiguration: (String) -> Unit = {},
    onUsePreset: (String) -> Unit = {},
    onReload: () -> Unit = {},
    onCloseDocument: () -> Unit = {},
    creatorUnavailableReason: String? = null,
    openingPresetId: String? = null,
    modifier: Modifier = Modifier,
    embedded: Boolean = false,
) {
    if (embedded) {
        Box(
            modifier = modifier
                .fillMaxSize()
                .windowInsetsPadding(
                    WindowInsets.safeDrawing.only(
                        WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom,
                    ),
                ),
        ) {
            AgentPresetsBody(
                state = state,
                onCreate = onCreate,
                onViewConfiguration = onViewConfiguration,
                onUsePreset = onUsePreset,
                onReload = onReload,
                creatorUnavailableReason = creatorUnavailableReason,
                openingPresetId = openingPresetId,
            )
        }
    } else {
        PageFrame(
            title = UiStrings.AGENT_PRESETS_TITLE,
            onBack = onBack,
            modifier = modifier,
        ) {
            AgentPresetsBody(
                state = state,
                onCreate = onCreate,
                onViewConfiguration = onViewConfiguration,
                onUsePreset = onUsePreset,
                onReload = onReload,
                creatorUnavailableReason = creatorUnavailableReason,
                openingPresetId = openingPresetId,
            )
        }
    }
    state.document?.let { document ->
        PresetDocumentPanel(document = document, onClose = onCloseDocument)
    }
}

/** The three untitled groups, in the baseline's order. */
@Composable
private fun AgentPresetsBody(
    state: NativeAgentPresetsScreenState,
    onCreate: () -> Unit,
    onViewConfiguration: (String) -> Unit,
    onUsePreset: (String) -> Unit,
    onReload: () -> Unit,
    creatorUnavailableReason: String?,
    openingPresetId: String?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.AGENT_PRESETS_LIST)
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        // unverified geometry: `spec/ui/v1/tokens.json` declares no page-level card
        // gap, so the approval card's outer vertical margin carries the gap between
        // this page's cards (and the list's own top/bottom inset).
        verticalArrangement = Arrangement.spacedBy(tokens.geometry.cardOuterMarginV),
        contentPadding = PaddingValues(vertical = tokens.geometry.cardOuterMarginV),
    ) {
        item(key = "creator") {
            val creatorEnabled = creatorUnavailableReason == null && !state.loading
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.AGENT_PRESETS_CREATOR)
                    .border(
                        width = tokens.stroke.hairline,
                        color = tokens.colors.border,
                        shape = RoundedCornerShape(tokens.radius.card),
                    )
                    .padding(tokens.spacing.cardInset),
                verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
            ) {
                // A clickable `BasicText`, not a `SessionTextAction`: this row is the
                // untitled group's criterion, and the gate reads a row's label from a
                // text call site (a shared action renders its label inside its own
                // file). Same ink and same tap target as every other page action.
                BasicText(
                    text = UiStrings.AGENT_PRESETS_CREATE,
                    style = type.body.copy(
                        color = if (creatorEnabled) tokens.colors.accent else tokens.colors.tertiary,
                    ),
                    modifier = Modifier
                        .clickable(enabled = creatorEnabled, role = Role.Button, onClick = onCreate)
                        .padding(
                            horizontal = tokens.spacing.badgeInsetH,
                            vertical = tokens.spacing.badgeInsetV,
                        ),
                )
                BasicText(
                    text = UiStrings.AGENT_PRESETS_CREATE_NOTE,
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
                BasicText(
                    text = UiStrings.AGENT_PRESETS_CREATE_NOTE_BUILTIN,
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
                creatorUnavailableReason?.let { reason ->
                    BasicText(
                        text = UiStrings.AGENT_PRESETS_CREATOR_UNAVAILABLE_PREFIX + reason,
                        style = type.caption.copy(color = tokens.colors.secondary),
                    )
                }
            }
        }
        item(key = "roster-loading") {
            if (state.loading) {
                BasicText(
                    text = UiStrings.AGENT_PRESETS_LOADING,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                    modifier = Modifier
                        .testTag(UiPageTags.AGENT_PRESETS_LOADING)
                        .padding(
                            horizontal = tokens.spacing.cardInset,
                            vertical = tokens.spacing.badgeInsetV,
                        ),
                )
            }
        }
        // A host that has not reported the roster says so; an engine that
        // reported an empty roster renders the baseline's 当前引擎没有预设 line.
        val presets = state.presets
        if (presets == null) {
            item(key = "roster-unread") {
                BasicText(
                    text = UiStrings.AGENT_PRESETS_UNREAD,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                    modifier = Modifier
                        .testTag(UiPageTags.AGENT_PRESETS_UNREAD)
                        .padding(horizontal = tokens.spacing.cardInset),
                )
            }
        } else {
            if (presets.isEmpty() && !state.loading && state.error == null) {
                item(key = "roster-empty") {
                    BasicText(
                        text = UiStrings.AGENT_PRESETS_EMPTY,
                        style = type.caption.copy(color = tokens.colors.tertiary),
                        modifier = Modifier.padding(horizontal = tokens.spacing.cardInset),
                    )
                }
            }
            items(items = presets, key = { it.id }) { row ->
                AgentPresetCard(
                    row = row,
                    opening = openingPresetId != null,
                    onViewConfiguration = onViewConfiguration,
                    onUsePreset = onUsePreset,
                )
            }
        }
        // The baseline's second section footer: like permission.defaultPreset the
        // phone image pins the default in its home patch, so the roster stays
        // readable but the default itself cannot be changed from here.
        item(key = "default-locked-footer") {
            BasicText(
                text = UiStrings.AGENT_PRESETS_DEFAULT_READ_ONLY_REASON,
                style = type.caption.copy(color = tokens.colors.tertiary),
                modifier = Modifier.padding(horizontal = tokens.spacing.cardInset),
            )
        }
        state.error?.let { error ->
            item(key = "error") {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = tokens.spacing.cardInset),
                    verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
                ) {
                    BasicText(
                        text = error,
                        style = type.caption.copy(color = tokens.colors.danger),
                        modifier = Modifier.testTag(UiPageTags.AGENT_PRESETS_ERROR),
                    )
                    // The error group's criterion row (the contract's
                    // `first-clickable-row`), exactly like the creator row above.
                    BasicText(
                        text = UiStrings.AGENT_PRESETS_RELOAD,
                        style = type.secondary.copy(color = tokens.colors.accent),
                        modifier = Modifier
                            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                            .clickable(role = Role.Button, onClick = onReload)
                            .padding(tokens.spacing.iconText),
                    )
                }
            }
        }
    }
}

/** One preset: title and badges, wire id, description, broken reason, two actions. */
@Composable
private fun AgentPresetCard(
    row: AgentPresetRowView,
    opening: Boolean,
    onViewConfiguration: (String) -> Unit,
    onUsePreset: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.AGENT_PRESETS_ROW_PREFIX + row.id)
            .border(
                width = tokens.stroke.hairline,
                color = tokens.colors.border,
                shape = RoundedCornerShape(tokens.radius.card),
            )
            .padding(tokens.spacing.cardInset),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = row.title,
                style = type.headline.copy(color = tokens.colors.primary),
                modifier = Modifier.weight(1f),
            )
            if (row.isDefault) {
                DefaultBadge()
            }
            if (row.custom) {
                BasicText(
                    text = UiStrings.AGENT_PRESETS_CUSTOM,
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
            }
        }
        BasicText(
            text = row.id,
            style = type.code.copy(color = tokens.colors.secondary),
        )
        row.detail?.let { detail ->
            BasicText(
                text = detail,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
        }
        row.broken?.let { broken ->
            BasicText(
                text = broken,
                style = type.caption.copy(color = tokens.colors.warning),
            )
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            // The roster's criterion row, for the same reason as the creator row.
            BasicText(
                text = UiStrings.AGENT_PRESETS_VIEW_CONFIG,
                style = type.secondary.copy(color = tokens.colors.accent),
                modifier = Modifier
                    .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                    .clickable(role = Role.Button) { onViewConfiguration(row.id) }
                    .padding(tokens.spacing.iconText),
            )
            SessionTextAction(
                label = UiStrings.AGENT_PRESETS_USE_PRESET,
                onClick = { onUsePreset(row.id) },
                tone = SessionActionTone.SECONDARY,
                enabled = row.canUse && !opening,
            )
            BasicText(
                text = UiStrings.AGENT_PRESETS_DEFAULT_LOCKED,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
    }
}

/** 默认: the baseline's capsule badge in the accent at 12 % (`:126`). */
@Composable
private fun DefaultBadge() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .clip(CircleShape)
            // The baseline's `Color.accentColor.opacity(0.12)`: a token colour at
            // the baseline's own alpha, not a second colour.
            .background(tokens.colors.accent.copy(alpha = BADGE_ALPHA))
            .padding(
                horizontal = tokens.spacing.badgeInsetH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    ) {
        BasicText(
            text = UiStrings.AGENT_PRESETS_DEFAULT,
            style = type.caption.copy(color = tokens.colors.accent),
        )
    }
}

/**
 * The read-only configuration panel (the baseline's `.sheet`): a monospace
 * document that cannot be edited, closed by 完成.
 */
@Composable
private fun PresetDocumentPanel(
    document: AgentPresetDocument,
    onClose: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .fillMaxSize()
            // The panel is a page of its own; `colors.input` is the surface the
            // settings sheet's page tabs use, so it reads as a modal above them.
            .background(tokens.colors.input)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .testTag(UiPageTags.AGENT_PRESETS_DOCUMENT),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
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
                BasicText(
                    text = document.title,
                    style = type.headline.copy(color = tokens.colors.primary),
                    modifier = Modifier
                        .weight(1f)
                        .semantics { heading() },
                )
                SessionTextAction(
                    label = UiStrings.SETTINGS_DONE,
                    onClick = onClose,
                    tone = SessionActionTone.ACCENT,
                )
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(
                        horizontal = tokens.geometry.pageOuterMarginH,
                        vertical = tokens.spacing.cardInset,
                    ),
            ) {
                BasicText(
                    text = document.yaml,
                    style = type.code.copy(color = tokens.colors.primary),
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Constants and the token inventory
// ---------------------------------------------------------------------------

/** The 默认 badge's fill: the baseline's `Color.accentColor.opacity(0.12)`. */
private const val BADGE_ALPHA: Float = 0.12f

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest` asserts that this list equals the tokens the source
 * reads, so an unlisted use and a stale entry both fail.
 */
internal object NativeAgentPresetsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_INPUT,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_CODE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_H,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_CARD_OUTER_MARGIN_V,
    )
}
