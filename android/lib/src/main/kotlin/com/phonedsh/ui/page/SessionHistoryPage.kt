// Session history: the turn list plus one turn's detail.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 `SessionHistoryPage` (历史回合列表与单回合详情;
// entry: 页头 `⋯` →「历史」, or the ChatPage goal row; push; 回合详情复用 ChatPage 的
// 折叠规则) and §3.1 (the ScreenState layer). §1 marks the page P5 `later`: this
// lane delivers the body and the state machine; the host owns the entry point, so
// no menu item or sheet is wired here. §1.1's "不可达" note is about
// `SessionActivityPage`, not this page.
//
// Two layers: the turn sequence comes from `UiState` (`groupTurns`), the selection
// and the expanded rows are local UI events. `SessionHistoryScreenState.from` is a
// pure function of both, so a JVM replay asserts the same turn list and the same
// detail rows without a device.
//
// The detail rows are projected by `ChatScreenState.from` over the turn's own
// nodes: one row renderer, one fold rule, no second implementation to drift.
//
// Geometry: the page margin and the compact list row read the page-level tokens
// declared in `tokens.json` (`geometry.pageOuterMarginH`,
// `geometry.pageListRowMinHeight`); nothing here reuses signature-surface geometry,
// so no `unverified geometry` marker remains.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.state.BannerState
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.surface.FailLoudBanner
import com.phonedsh.ui.surface.FailLoudKind
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/** Whether the history has been read, is still waiting, or the last read failed. */
public enum class HistoryStatus { WAITING, READY, FAILED }

/** Why the turn list is empty; only reported in `READY`. */
public enum class HistoryEmpty {
    NONE,

    /** The session has no turn rows. */
    NO_TURNS,
}

/** One turn row of the history list. */
public data class HistoryTurnView(
    public val turnID: String,
    /** 1-based position in the projection order. */
    public val ordinal: Int,
    public val label: String,
    public val outcomeLabel: String,
    /** "N 条消息 · M 次工具" — counts of real nodes, never a placeholder. */
    public val summary: String,
    public val selected: Boolean,
)

/**
 * One turn's detail: the same rows the chat page would show for that turn.
 *
 * @param pendingCount unanswered asks still attached to the turn; the history is
 *   read-only, so they are counted, not answerable.
 */
public data class TurnDetailView(
    public val turnID: String,
    public val label: String,
    public val outcomeLabel: String,
    public val rows: List<ChatRow>,
    public val banners: List<BannerState>,
    public val pendingCount: Int,
)

/** The local UI events of the history page. */
public data class SessionHistoryLocalState(
    public val selectedTurnID: String? = null,
    /** Rows whose detail the user expanded in the turn detail. */
    public val expandedRowIds: Set<String> = emptySet(),
)

/**
 * The history page state.
 *
 * @param detail the selected turn; `null` shows the list.
 */
public data class SessionHistoryScreenState(
    public val sessionID: String,
    public val status: HistoryStatus,
    public val failure: String?,
    public val turns: List<HistoryTurnView>,
    public val detail: TurnDetailView?,
    public val selectedTurnID: String?,
    public val empty: HistoryEmpty,
    public val expandedRowIds: Set<String> = emptySet(),
) {
    public val waiting: Boolean get() = status == HistoryStatus.WAITING

    public companion object {
        /**
         * Projects a UiState sequence into the history page state.
         *
         * Pure: the same nodes and local script always yield the same turn list,
         * the same detail rows and the same selection.
         *
         * @param nodes the session's UiState sequence (never reordered).
         * @param local the local UI events (selection, expanded rows).
         * @param waiting true before the first successful read.
         * @param failure non-null when the last read failed; the previous turns stay.
         */
        public fun from(
            nodes: List<UiStateNode>,
            local: SessionHistoryLocalState = SessionHistoryLocalState(),
            waiting: Boolean = false,
            failure: String? = null,
        ): SessionHistoryScreenState {
            val status = when {
                failure != null -> HistoryStatus.FAILED
                waiting -> HistoryStatus.WAITING
                else -> HistoryStatus.READY
            }
            val groups = if (status == HistoryStatus.WAITING) emptyList() else groupTurns(nodes)
            val selected = local.selectedTurnID?.let { id -> groups.firstOrNull { it.turnID == id } }
            val turns = groups.map { group ->
                HistoryTurnView(
                    turnID = group.turnID,
                    ordinal = group.ordinal,
                    label = UiStrings.TURN_LABEL.format(group.ordinal),
                    outcomeLabel = group.outcome.label(),
                    summary = UiStrings.TURN_COUNTS.format(group.messageCount, group.toolCallCount),
                    selected = group.turnID == selected?.turnID,
                )
            }
            val detail = selected?.let { group ->
                val projected = ChatScreenState.from(group.nodes)
                TurnDetailView(
                    turnID = group.turnID,
                    label = UiStrings.TURN_LABEL.format(group.ordinal),
                    outcomeLabel = group.outcome.label(),
                    rows = projected.rows,
                    banners = projected.banners,
                    pendingCount = projected.pending.count,
                )
            }
            val sessionID = nodes.firstOrNull { it.sessionID.isNotEmpty() }?.sessionID.orEmpty()
            return SessionHistoryScreenState(
                sessionID = sessionID,
                status = status,
                failure = failure,
                turns = turns,
                detail = detail,
                selectedTurnID = selected?.turnID,
                empty = if (status == HistoryStatus.READY && turns.isEmpty()) {
                    HistoryEmpty.NO_TURNS
                } else {
                    HistoryEmpty.NONE
                },
                expandedRowIds = local.expandedRowIds,
            )
        }
    }
}

/**
 * The history page.
 *
 * @param state the pure screen state ([SessionHistoryScreenState.from]).
 * @param onSelectTurn select a turn, or `null` to go back to the list.
 * @param onToggleRow expand/collapse a row in the turn detail.
 * @param onRetry retry a failed read.
 * @param onDismissFailure dismiss the failure line.
 * @param onBack leave the page.
 */
@Composable
public fun SessionHistoryPage(
    state: SessionHistoryScreenState,
    onSelectTurn: (String?) -> Unit,
    onToggleRow: (String) -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
    onBack: (() -> Unit)? = null,
) {
    val inDetail = state.detail != null
    PageFrame(
        title = if (inDetail) UiStrings.HISTORY_DETAIL_TITLE else UiStrings.HISTORY_TITLE,
        onBack = if (inDetail) {
            { onSelectTurn(null) }
        } else {
            onBack
        },
        rootTag = UiPageTags.HISTORY_ROOT,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            if (state.failure != null) {
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.HISTORY_FAILURE,
                    retryLabel = UiStrings.RETRY,
                    onRetry = onRetry,
                    onDismiss = onDismissFailure,
                )
            }
            val detail = state.detail
            when {
                state.waiting -> EmptyHint(
                    title = UiStrings.WAITING_ENGINE,
                    hint = UiStrings.HISTORY_EMPTY_HINT,
                    tag = UiPageTags.HISTORY_EMPTY,
                )

                detail != null -> TurnDetail(
                    detail = detail,
                    expandedRowIds = state.expandedRowIds,
                    onToggleRow = onToggleRow,
                )

                // A failed read with nothing to keep is the failure line only.
                state.turns.isEmpty() && state.status == HistoryStatus.FAILED -> Unit

                state.empty == HistoryEmpty.NO_TURNS -> EmptyHint(
                    title = UiStrings.HISTORY_EMPTY,
                    hint = UiStrings.HISTORY_EMPTY_HINT,
                    tag = UiPageTags.HISTORY_EMPTY,
                )

                else -> LazyColumn(
                    modifier = Modifier.fillMaxSize().testTag(UiPageTags.HISTORY_LIST),
                ) {
                    items(items = state.turns, key = { it.turnID }) { turn ->
                        HistoryTurnRow(turn = turn, onSelect = onSelectTurn)
                        SessionHairline()
                    }
                }
            }
        }
    }
}

/** One turn row: label, counts, outcome. Tapping opens the detail. */
@Composable
private fun HistoryTurnRow(turn: HistoryTurnView, onSelect: (String?) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.HISTORY_TURN)
            .clickable(role = Role.Button, onClick = { onSelect(turn.turnID) })
            // Page-level geometry: a turn row is a compact list row and uses the
            // page margin.
            .defaultMinSize(minHeight = tokens.geometry.pageListRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            BasicText(
                text = turn.label,
                style = type.body.copy(
                    color = if (turn.selected) tokens.colors.accent else tokens.colors.primary,
                ),
                maxLines = 1,
            )
            BasicText(
                text = turn.summary,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
        BasicText(
            text = turn.outcomeLabel,
            style = type.caption.copy(color = tokens.colors.secondary),
            modifier = Modifier.semantics { contentDescription = turn.outcomeLabel },
        )
    }
}

/** One turn in full: its fail-loud banners, declared asks and projected rows. */
@Composable
private fun TurnDetail(
    detail: TurnDetailView,
    expandedRowIds: Set<String>,
    onToggleRow: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(modifier = Modifier.fillMaxSize().testTag(UiPageTags.HISTORY_DETAIL)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.iconText,
                ),
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = detail.label,
                style = type.secondary.copy(color = tokens.colors.primary),
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = detail.outcomeLabel,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
        }
        detail.banners.forEach { banner ->
            // A past turn's failure is a record: shown, not re-runnable.
            FailLoudBanner(kind = FailLoudKind.TURN, message = banner.message)
        }
        if (detail.pendingCount > 0) {
            BasicText(
                text = UiStrings.TURN_PENDING.format(detail.pendingCount),
                style = type.caption.copy(color = tokens.colors.tertiary),
                modifier = Modifier.padding(horizontal = tokens.geometry.pageOuterMarginH),
            )
        }
        if (detail.rows.isEmpty() && detail.banners.isEmpty() && detail.pendingCount == 0) {
            EmptyHint(
                title = UiStrings.HISTORY_DETAIL_EMPTY,
                hint = null,
                tag = UiPageTags.HISTORY_DETAIL_EMPTY,
            )
        } else {
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                ChatRowList(
                    rows = detail.rows,
                    expandedRowIds = expandedRowIds,
                    onToggleRow = onToggleRow,
                    tag = UiPageTags.HISTORY_ROWS,
                )
            }
        }
    }
}

/**
 * The token inventory of this page; `PageTokenReferenceTest` fails when a use
 * site reads a token that is not listed here.
 */
internal object SessionHistoryPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.GEOMETRY_PAGE_LIST_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
    )
}
