// The daily brief: the stored snapshot, its items, the sources and the run report.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row DailyBriefPage (每日简报; entry: 基线无入口
// （孤页）; exit: 不可达; P5 `later`), §3.1 rule 3 (a page with no harness event
// anchor projects the host's read-only snapshot) and §5 (`insets`).
//
// §1 records this page as unreachable in the baseline: the page exists, no call
// site exists. That is why `onBack` is optional — a page nobody navigates to must
// not pretend it was pushed.
//
// This is a line-for-line port of the iOS baseline's `DailyBriefPage.swift`:
//
//   header        "每日简报" / "还没有简报", the last-success or no-source hint,
//                 the last-attempt line, the in-flight spinner, the 分享 action
//                 and (when the host reported a run) the three-part report line
//   latest issue  "最新一期" with one row per item, or the empty state with the
//                 newspaper glyph and the baseline's two-way hint
//   sources       "资讯来源": name + URL + an on/off Switch, a trailing
//                 swipe-to-delete action, and the 添加 RSS / Atom 来源 button
//   issues        "本次更新问题" only when this run had any
//
// The three controls the baseline draws are standard controls here: the source
// toggle is a Material 3 `Switch`, the delete gesture is a Material 3
// `SwipeToDismissBox` (the baseline's `.swipeActions`), and the add-source sheet
// is a Material 3 dialog with the same two fields and footer.
//
// The relative timestamps are **host-formatted strings**; the page never reads a
// clock, so `date, style: .relative` becomes a fact, not a formatter. A refresh
// error does not clear the previous brief in the baseline ("失败时不会清空上一
// 期"), so a run error is an orange note on a READY page, while a failed *read*
// is the FAILED state's fail-loud line.
//
// ScreenState: `DailyBriefScreenState.from(facts)` is the whole projection,
// including the empty-items hint variant. The editor's open/closed state and its
// two fields are local UI events (§3.1 rule 2); every action is a host callback.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.sheet.PdshSheet
import com.phonedsh.ui.sheet.SheetBackHost
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * One item of the latest brief.
 *
 * @param id a stable item id.
 * @param title the item title.
 * @param summary the host's summary; `null` when it has none.
 * @param sourceName the source the item came from, `null` when unattributed.
 * @param publishedText the host-formatted publication time (never a clock read).
 * @param hasLink whether the item carries a link the host can open.
 */
@Immutable
public data class DailyBriefItem(
    public val id: String,
    public val title: String,
    public val summary: String? = null,
    public val sourceName: String? = null,
    public val publishedText: String? = null,
    public val hasLink: Boolean = false,
)

/**
 * One subscribed source.
 *
 * @param id a stable source id.
 * @param name the source's display name.
 * @param url the source's address, shown verbatim.
 * @param enabled whether the source is on; [FactState.UNKNOWN] when unread.
 */
@Immutable
public data class DailyBriefSource(
    public val id: String,
    public val name: String,
    public val url: String,
    public val enabled: FactState = FactState.UNKNOWN,
)

/**
 * One problem this run had with a source.
 *
 * @param id a stable issue id.
 * @param sourceName the source that failed, `null` when the host did not say.
 * @param message the host's message.
 */
@Immutable
public data class DailyBriefIssue(
    public val id: String,
    public val sourceName: String? = null,
    public val message: String,
)

/**
 * The last run's measured totals; every field is nullable because a partial
 * report is a real host answer and 0 is a measured value, not a default.
 */
@Immutable
public data class DailyBriefReport(
    public val itemCount: Int? = null,
    public val newItemCount: Int? = null,
    public val networkBytes: Long? = null,
    public val modelCalls: Int? = null,
    public val billingLabel: String? = null,
)

/**
 * The host's read-only brief snapshot.
 *
 * @param lastSuccessText the host-formatted time of the last successful refresh.
 * @param lastAttemptText the host-formatted time of the last attempt.
 * @param refreshing whether a refresh is running right now.
 * @param report the last run's totals; `null` when unreported.
 * @param errorMessage the last refresh error (the previous brief is kept).
 * @param items the latest brief's items; `null` means the host reported no list.
 * @param sources the sources; `null` means the host reported no list.
 * @param issues this run's source issues; `null` means the host reported none.
 * @param shareText the text the share action would hand to the share sheet.
 */
@Immutable
public data class DailyBriefSnapshot(
    public val lastSuccessText: String? = null,
    public val lastAttemptText: String? = null,
    public val refreshing: FactState = FactState.UNKNOWN,
    public val report: DailyBriefReport? = null,
    public val errorMessage: String? = null,
    public val items: List<DailyBriefItem>? = null,
    public val sources: List<DailyBriefSource>? = null,
    public val issues: List<DailyBriefIssue>? = null,
    public val shareText: String? = null,
) {
    /** True when the host measured at least one fact of this page. */
    internal val hasMeasurement: Boolean
        get() = lastSuccessText != null || lastAttemptText != null ||
            refreshing != FactState.UNKNOWN || report != null || errorMessage != null ||
            items != null || sources != null || issues != null ||
            !shareText.isNullOrBlank()
}

/**
 * The page's read-only input.
 *
 * @param snapshot the host's snapshot; `null` means the host did not report one.
 * @param failure the host's read failure; non-null makes the state FAILED.
 */
@Immutable
public data class DailyBriefFacts(
    public val snapshot: DailyBriefSnapshot? = null,
    public val failure: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The four outcomes the page distinguishes. */
public enum class DailyBriefStatus {
    /** The host reported at least one measured fact. */
    READY,

    /** The host reported a snapshot but no fact in it was measured. */
    EMPTY,

    /** The last read failed; the page offers a retry. */
    FAILED,

    /** The host did not report a snapshot: the page says 未知, never 0 items. */
    UNKNOWN,
}

/**
 * The complete daily-brief screen state.
 *
 * @param status the four-state outcome; a failed read wins.
 * @param hasSnapshot whether the host reported a snapshot at all. The baseline's
 *   headline keys on exactly that (`DailyBriefPage.swift:21`:
 *   `model.snapshot == nil ? "还没有简报" : "每日简报"`), not on whether a refresh
 *   has ever succeeded.
 * @param hasBrief whether a brief exists (a success time or at least one item).
 * @param lastSuccessText the host's success line, `null` when never succeeded.
 * @param lastAttemptText the host's attempt line, `null` when never attempted.
 * @param refreshing whether a refresh runs right now.
 * @param report the last run's totals, `null` when unreported.
 * @param errorMessage the last refresh error; the page keeps the brief and shows
 *   this as an orange note, exactly like the baseline.
 * @param items the items, `null` when the host reported no list.
 * @param sources the sources, `null` when the host reported no list.
 * @param issues this run's issues, `null` when the host reported none.
 * @param emptyHint the hint under "还没有可显示的内容"; `null` when the source
 *   list itself is unreported, because neither baseline hint would be honest.
 * @param shareable whether the host has share text worth offering.
 * @param failure the read failure, `null` unless FAILED.
 */
@Immutable
public data class DailyBriefScreenState(
    public val status: DailyBriefStatus,
    public val hasSnapshot: Boolean,
    public val hasBrief: Boolean,
    public val lastSuccessText: String?,
    public val lastAttemptText: String?,
    public val refreshing: FactState,
    public val report: DailyBriefReport?,
    public val errorMessage: String?,
    public val items: List<DailyBriefItem>?,
    public val sources: List<DailyBriefSource>?,
    public val issues: List<DailyBriefIssue>?,
    public val emptyHint: String?,
    public val shareable: Boolean,
    public val failure: String?,
) {
    /** True when the host reported an empty snapshot. */
    public val isEmpty: Boolean get() = status == DailyBriefStatus.EMPTY

    /** True when the host reported no snapshot. */
    public val isUnknown: Boolean get() = status == DailyBriefStatus.UNKNOWN

    /** True when the last read failed. */
    public val isFailed: Boolean get() = status == DailyBriefStatus.FAILED

    /** True when the host reported an empty item list. */
    public val itemsEmpty: Boolean get() = items != null && items.isEmpty()

    /**
     * True when the refresh action is allowed. The baseline disables the toolbar
     * action while refreshing and when the source list is empty.
     */
    public val canRefresh: Boolean
        get() = refreshing != FactState.YES && !sources.isNullOrEmpty()

    /** True when the add-source action is allowed (the baseline's 50 cap). */
    public val canAddSource: Boolean
        get() = refreshing != FactState.YES &&
            (sources?.size ?: 0) < MAXIMUM_SOURCES

    /** True when at least one rendered value is 未知 inside a measured brief. */
    public val hasUnmeasuredValues: Boolean
        get() = status == DailyBriefStatus.READY && (
            refreshing == FactState.UNKNOWN || lastSuccessText == null ||
                lastAttemptText == null || report == null || items == null ||
                sources == null || issues == null ||
                sources.orEmpty().any { it.enabled == FactState.UNKNOWN } ||
                report?.itemCount == null || report?.newItemCount == null ||
                report?.networkBytes == null || report?.modelCalls == null
            )

    /**
     * A display-free signature of the sequence-relevant state.
     *
     * Item ids and source ids are included, the copy is not, so a replay compares
     * the shape without depending on the host's text.
     */
    public fun signature(): String = buildString {
        append(status.name).append('|').append(refreshing.name)
        append("|brief=").append(hasBrief)
        append("|items=").append(items?.joinToString(",") { it.id })
        append("|sources=").append(sources?.joinToString(",") { it.id + ':' + it.enabled.name })
        append("|issues=").append(issues?.joinToString(",") { it.id })
        append("|report=").append(report != null)
        if (errorMessage != null) append("|error")
        if (failure != null) append("|failure")
    }

    public companion object {
        /** `DailyBriefLimits.maximumSources` in the baseline. */
        public const val MAXIMUM_SOURCES: Int = 50

        /**
         * Projects (facts) into the screen state.
         *
         * Pure: no clock, no network and no refresh. The host owns the run, so the
         * same facts always yield the same state and the same hint variant.
         */
        public fun from(facts: DailyBriefFacts): DailyBriefScreenState {
            val snapshot = facts.snapshot
            val failure = facts.failure
            val status = when {
                failure != null -> DailyBriefStatus.FAILED
                snapshot == null -> DailyBriefStatus.UNKNOWN
                !snapshot.hasMeasurement -> DailyBriefStatus.EMPTY
                else -> DailyBriefStatus.READY
            }
            val measured = snapshot.takeIf { status == DailyBriefStatus.READY }
            val items = measured?.items
            val sources = measured?.sources
            val emptyHint = when {
                sources == null -> null
                sources.isEmpty() -> UiStrings.DAILY_BRIEF_ITEMS_EMPTY_NO_SOURCE
                else -> UiStrings.DAILY_BRIEF_ITEMS_EMPTY_SOURCES
            }
            return DailyBriefScreenState(
                status = status,
                hasSnapshot = snapshot != null,
                hasBrief = measured?.lastSuccessText != null || items.orEmpty().isNotEmpty(),
                lastSuccessText = measured?.lastSuccessText?.takeUnless { it.isBlank() },
                lastAttemptText = measured?.lastAttemptText?.takeUnless { it.isBlank() },
                refreshing = measured?.refreshing ?: FactState.UNKNOWN,
                report = measured?.report,
                errorMessage = measured?.errorMessage?.takeUnless { it.isBlank() },
                items = items,
                sources = sources,
                issues = measured?.issues,
                emptyHint = emptyHint,
                shareable = !measured?.shareText.isNullOrBlank(),
                failure = failure,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The daily-brief page.
 *
 * @param state the pure screen state (`DailyBriefScreenState.from`).
 * @param onRefresh ask the host to refresh (the toolbar action and pull-to-refresh).
 * @param modifier the caller's modifier.
 * @param onBack leave the page; `null` hides the action because §1 records no
 *   entry and therefore no way back.
 * @param onAddSource add one source (name and URL) from the baseline form;
 *   `null` hides the add action.
 * @param onToggleSource switch one source on or off; `null` disables the switches.
 * @param onRemoveSource remove one source from the trailing swipe action; `null`
 *   disables the swipe.
 * @param onOpenItem open one item's link; `null` leaves the rows read-only.
 * @param onShare share the brief text through the platform share sheet; `null`
 *   hides the action (`share-sheet` in §5 keeps it a page action).
 * @param onRefreshIfNeeded the baseline's `.task { refreshIfNeeded }`; it runs
 *   once when the page enters the composition.
 * @param onRetry retry the host read; `null` hides the retry.
 * @param onDismissFailure dismiss the failure line; `null` hides it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
public fun DailyBriefPage(
    state: DailyBriefScreenState,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onAddSource: ((String, String) -> Unit)? = null,
    onToggleSource: ((String, Boolean) -> Unit)? = null,
    onRemoveSource: ((String) -> Unit)? = null,
    onOpenItem: ((String) -> Unit)? = null,
    onShare: (() -> Unit)? = null,
    onRefreshIfNeeded: (() -> Unit)? = null,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
) {
    var addingSource by remember { mutableStateOf(false) }
    // The baseline refreshes if needed when the page appears.
    LaunchedEffect(Unit) {
        onRefreshIfNeeded?.invoke()
    }
    PageFrame(
        title = UiStrings.DAILY_BRIEF_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.BRIEF_ROOT,
        modifier = modifier,
        actions = {
            SessionTextAction(
                label = UiStrings.DAILY_BRIEF_REFRESH,
                onClick = onRefresh,
                tone = SessionActionTone.ACCENT,
                enabled = state.canRefresh,
                modifier = Modifier.testTag(UiPageTags.BRIEF_REFRESH),
            )
        },
    ) {
        ProbeControlsTheme {
            PullToRefreshBox(
                isRefreshing = state.refreshing == FactState.YES,
                onRefresh = onRefresh,
                modifier = Modifier.fillMaxSize(),
            ) {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag(UiPageTags.BRIEF_LIST),
                    verticalArrangement = Arrangement.spacedBy(pageListGap),
                ) {
                    state.failure?.let { failure ->
                        item(key = "brief.failure") {
                            SessionFailureLine(
                                message = failure,
                                tag = UiPageTags.BRIEF_FAILURE,
                                retryLabel = if (onRetry != null) UiStrings.RETRY else null,
                                onRetry = onRetry,
                                onDismiss = onDismissFailure,
                            )
                        }
                    }
                    headerBlock(state, onShare)
                    itemsBlock(state, onOpenItem)
                    sourcesBlock(
                        state = state,
                        onAddSource = onAddSource,
                        onToggleSource = onToggleSource,
                        onRemoveSource = onRemoveSource,
                        onOpenEditor = if (onAddSource != null) {
                            { addingSource = true }
                        } else {
                            null
                        },
                    )
                    issuesBlock(state)
                }
            }
        }
    }
    if (addingSource) {
        AddSourceDialog(
            onDismiss = { addingSource = false },
            onAdd = { name, url ->
                addingSource = false
                onAddSource?.invoke(name, url)
            },
        )
    }
}

/** The snapshot header, its report line and the share action. */
private fun LazyListScope.headerBlock(
    state: DailyBriefScreenState,
    onShare: (() -> Unit)?,
) {
    item(key = "brief.header") {
        val tokens = LocalUiTokens.current
        val type = LocalUiType.current
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                )
                .testTag(UiPageTags.BRIEF_HEADER),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
                ) {
                    BasicText(
                        text = if (state.hasSnapshot) {
                            UiStrings.DAILY_BRIEF_TITLE
                        } else {
                            UiStrings.DAILY_BRIEF_NO_BRIEF
                        },
                        style = type.headline.copy(color = tokens.colors.primary),
                        modifier = Modifier.testTag(UiPageTags.BRIEF_HEADLINE),
                    )
                    if (state.lastSuccessText != null) {
                        BasicText(
                            text = UiStrings.DAILY_BRIEF_LAST_SUCCESS.format(
                                state.lastSuccessText,
                            ),
                            style = type.caption.copy(color = tokens.colors.secondary),
                            modifier = Modifier.testTag(UiPageTags.BRIEF_LAST_SUCCESS),
                        )
                    } else {
                        BasicText(
                            text = UiStrings.DAILY_BRIEF_NO_SOURCE_HINT,
                            style = type.caption.copy(color = tokens.colors.secondary),
                            modifier = Modifier.testTag(UiPageTags.BRIEF_LAST_SUCCESS),
                        )
                    }
                    state.lastAttemptText?.let { attempt ->
                        BasicText(
                            text = UiStrings.DAILY_BRIEF_LAST_ATTEMPT.format(attempt),
                            style = type.caption.copy(color = tokens.colors.tertiary),
                            modifier = Modifier.testTag(UiPageTags.BRIEF_LAST_ATTEMPT),
                        )
                    }
                }
                if (state.refreshing == FactState.YES) {
                    CircularProgressIndicator(
                        color = tokens.colors.accent,
                        modifier = Modifier.testTag(UiPageTags.BRIEF_REFRESH + ".progress"),
                    )
                }
                if (onShare != null && state.shareable) {
                    SessionTextAction(
                        label = UiStrings.DAILY_BRIEF_SHARE_ACTION,
                        onClick = onShare,
                        tone = SessionActionTone.ACCENT,
                        modifier = Modifier.testTag(UiPageTags.BRIEF_SHARE),
                    )
                }
            }
            state.report?.let { report ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(UiPageTags.BRIEF_REPORT),
                    horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                ) {
                    BasicText(
                        text = report.itemCount?.let {
                            UiStrings.DAILY_BRIEF_REPORT_ITEMS.format(it)
                        } ?: UiStrings.UNKNOWN,
                        style = type.caption.copy(color = tokens.colors.secondary),
                    )
                    Box(modifier = Modifier.weight(1f))
                    BasicText(
                        text = report.newItemCount?.let {
                            UiStrings.DAILY_BRIEF_REPORT_NEW.format(it)
                        } ?: UiStrings.UNKNOWN,
                        style = type.caption.copy(color = tokens.colors.secondary),
                    )
                    Box(modifier = Modifier.weight(1f))
                    BasicText(
                        text = reportTail(report),
                        style = type.caption.copy(
                            color = tokens.colors.secondary,
                            textAlign = TextAlign.End,
                        ),
                    )
                }
            }
            state.errorMessage?.let { error ->
                SelectionContainer {
                    BasicText(
                        text = error,
                        style = type.caption.copy(color = tokens.colors.warning),
                        modifier = Modifier.testTag(UiPageTags.BRIEF_ERROR),
                    )
                }
            }
        }
    }
}

/** The latest items; the empty state keeps the baseline's two-way hint. */
private fun LazyListScope.itemsBlock(
    state: DailyBriefScreenState,
    onOpenItem: ((String) -> Unit)?,
) {
    val items = state.items.orEmpty()
    if (items.isEmpty()) {
        item(key = "brief.items.empty") {
            EmptyBrief(hint = state.emptyHint)
        }
        return
    }
    item(key = "brief.items.label") {
        SessionSectionLabel(
            text = UiStrings.DAILY_BRIEF_SECTION_LATEST,
            modifier = Modifier.testTag(UiPageTags.BRIEF_ITEMS),
        )
    }
    items.forEach { entry ->
        item(key = "brief.item.${entry.id}") {
            DailyBriefItemRow(
                item = entry,
                onOpen = onOpenItem?.takeIf { entry.hasLink }?.let { callback ->
                    { callback.invoke(entry.id) }
                },
            )
        }
    }
}

/** The baseline's empty state: newspaper glyph, headline and hint. */
@Composable
private fun EmptyBrief(hint: String?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            .testTag(UiPageTags.BRIEF_ITEMS_EMPTY),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.DAILY_BRIEF_NEWSPAPER_GLYPH,
            style = type.headline.copy(color = tokens.colors.secondary),
            modifier = Modifier.testTag(UiPageTags.BRIEF_EMPTY_ICON),
        )
        BasicText(
            text = UiStrings.DAILY_BRIEF_ITEMS_EMPTY,
            style = type.headline.copy(color = tokens.colors.primary),
        )
        if (hint != null) {
            BasicText(
                text = hint,
                // `DailyBriefPage.swift:83`: the hint under the empty title is
                // `.font(.subheadline)` (15 pt), centred.
                style = type.subheadline.copy(
                    color = tokens.colors.secondary,
                    textAlign = TextAlign.Center,
                ),
            )
        }
    }
}

/** One item: title, summary and the source/time footer. */
@Composable
private fun DailyBriefItemRow(item: DailyBriefItem, onOpen: (() -> Unit)?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (onOpen != null) {
                    Modifier.clickable(onClick = onOpen)
                } else {
                    Modifier
                },
            )
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            .testTag(UiPageTags.BRIEF_ITEM_PREFIX + item.id),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = item.title,
            style = type.body.copy(
                color = tokens.colors.primary,
                fontWeight = FontWeight.SemiBold,
            ),
        )
        item.summary?.takeUnless { it.isBlank() }?.let { summary ->
            BasicText(
                text = summary,
                // `DailyBriefPage.swift:170`: the summary is `.font(.subheadline)`
                // (15 pt), the item title above it `.font(.body)` (17 pt).
                style = type.subheadline.copy(color = tokens.colors.secondary),
                maxLines = SUMMARY_LINE_LIMIT,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = item.sourceName ?: UiStrings.UNKNOWN,
                style = type.caption.copy(color = tokens.colors.tertiary),
                modifier = Modifier.weight(1f),
            )
            item.publishedText?.let { published ->
                BasicText(
                    text = published,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                )
            }
        }
    }
}

/** The source list, one swipeable row per source plus the add-source action. */
@OptIn(ExperimentalMaterial3Api::class)
private fun LazyListScope.sourcesBlock(
    state: DailyBriefScreenState,
    onAddSource: ((String, String) -> Unit)?,
    onToggleSource: ((String, Boolean) -> Unit)?,
    onRemoveSource: ((String) -> Unit)?,
    onOpenEditor: (() -> Unit)?,
) {
    item(key = "brief.sources.label") {
        SessionSectionLabel(
            text = UiStrings.DAILY_BRIEF_SECTION_SOURCES,
            modifier = Modifier.testTag(UiPageTags.BRIEF_SOURCES),
        )
    }
    state.sources.orEmpty().forEach { source ->
        item(key = "brief.source.${source.id}") {
            DailyBriefSourceRow(
                source = source,
                refreshing = state.refreshing == FactState.YES,
                onToggle = onToggleSource?.let { callback ->
                    { enabled -> callback.invoke(source.id, enabled) }
                },
                onRemove = onRemoveSource?.let { callback -> { callback.invoke(source.id) } },
            )
        }
    }
    if (onOpenEditor != null) {
        item(key = "brief.source.add") {
            val tokens = LocalUiTokens.current
            Button(
                onClick = onOpenEditor,
                enabled = state.canAddSource,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        horizontal = tokens.geometry.pageOuterMarginH,
                        vertical = tokens.spacing.badgeInsetV,
                    )
                    .testTag(UiPageTags.BRIEF_ADD_SOURCE),
            ) {
                Text(
                    text = UiStrings.DAILY_BRIEF_ADD_SOURCE_BUTTON,
                    style = LocalUiType.current.secondary,
                )
            }
        }
    }
}

/**
 * One source row: the name and URL, the on/off Switch, and the baseline's
 * trailing swipe-to-delete. `confirmValueChange` returns false so the host's
 * re-projection removes the row; the page never keeps a local deleted copy.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DailyBriefSourceRow(
    source: DailyBriefSource,
    refreshing: Boolean,
    onToggle: ((Boolean) -> Unit)?,
    onRemove: (() -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart && onRemove != null && !refreshing) {
                onRemove()
            }
            false
        },
    )
    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        enableDismissFromEndToStart = onRemove != null && !refreshing,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.BRIEF_SOURCE_SWIPE_PREFIX + source.id),
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(tokens.colors.danger)
                    .padding(horizontal = tokens.geometry.pageOuterMarginH),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Text(
                    text = UiStrings.DAILY_BRIEF_REMOVE,
                    style = type.secondary.copy(color = tokens.colors.onAccent),
                )
            }
        },
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(tokens.colors.input)
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.iconText,
                )
                .testTag(UiPageTags.BRIEF_SOURCE_PREFIX + source.id),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
            ) {
                BasicText(
                    text = source.name,
                    style = type.body.copy(color = tokens.colors.primary),
                )
                BasicText(
                    text = source.url,
                    style = type.caption.copy(color = tokens.colors.secondary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (source.enabled == FactState.UNKNOWN) {
                BasicText(
                    text = UiStrings.DAILY_BRIEF_SOURCE_UNREAD,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                )
            }
            Switch(
                checked = source.enabled == FactState.YES,
                onCheckedChange = { enabled -> onToggle?.invoke(enabled) },
                enabled = onToggle != null &&
                    !refreshing &&
                    source.enabled != FactState.UNKNOWN,
                modifier = Modifier.testTag(UiPageTags.BRIEF_SOURCE_SWITCH_PREFIX + source.id),
            )
        }
    }
}

/** This run's source issues; the section exists only when there are any. */
private fun LazyListScope.issuesBlock(state: DailyBriefScreenState) {
    val issues = state.issues.orEmpty()
    if (issues.isEmpty()) return
    item(key = "brief.issues.label") {
        SessionSectionLabel(
            text = UiStrings.DAILY_BRIEF_SECTION_ISSUES,
            modifier = Modifier.testTag(UiPageTags.BRIEF_ISSUES),
        )
    }
    issues.forEach { issue ->
        item(key = "brief.issue.${issue.id}") {
            val tokens = LocalUiTokens.current
            val type = LocalUiType.current
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        horizontal = tokens.geometry.pageOuterMarginH,
                        vertical = tokens.spacing.badgeInsetV,
                    )
                    .testTag(UiPageTags.BRIEF_ISSUE_PREFIX + issue.id),
                verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
            ) {
                issue.sourceName?.takeUnless { it.isBlank() }?.let { name ->
                    BasicText(
                        text = name,
                        style = type.caption.copy(
                            color = tokens.colors.primary,
                            fontWeight = FontWeight.SemiBold,
                        ),
                    )
                }
                BasicText(
                    text = issue.message,
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
            }
        }
    }
}

/**
 * The baseline's add-source form: two fields, the footer and 添加.
 *
 * PR #60 removed the editor's 取消 (`DailyBriefPage.swift:213`): the sheet is
 * dismissed by its own gesture. The bottom sheet's swipe, scrim tap and system
 * back are that gesture here ([onDismiss]).
 */
@Composable
private fun AddSourceDialog(onDismiss: () -> Unit, onAdd: (String, String) -> Unit) {
    var name by remember { mutableStateOf("") }
    var url by remember { mutableStateOf("") }
    // 添加 closes through the same platform hide as the scrim and system back;
    // the host receives the values only after the sheet has left the screen.
    var submitted by remember { mutableStateOf<Pair<String, String>?>(null) }
    val sheetBackHost = remember { SheetBackHost() }
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    PdshSheet(
        pageId = "dailyBriefSource",
        backHost = sheetBackHost,
        onDismissRequest = {
            val values = submitted
            submitted = null
            if (values != null) onAdd(values.first, values.second) else onDismiss()
        },
        modifier = Modifier.testTag(UiPageTags.BRIEF_SOURCE_EDITOR),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                ),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            Text(
                text = UiStrings.DAILY_BRIEF_ADD_SOURCE_TITLE,
                style = type.headline.copy(color = tokens.colors.primary),
            )
            SourceDialogField(
                label = UiStrings.DAILY_BRIEF_NAME_OPTIONAL,
                value = name,
                onValueChange = { name = it },
                tag = UiPageTags.BRIEF_SOURCE_NAME_FIELD,
            )
            SourceDialogField(
                label = UiStrings.DAILY_BRIEF_URL_PLACEHOLDER,
                value = url,
                onValueChange = { url = it },
                tag = UiPageTags.BRIEF_SOURCE_URL_FIELD,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                ),
            )
            Text(
                text = UiStrings.DAILY_BRIEF_SOURCE_FOOTER,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(
                    onClick = {
                        submitted = name to url
                        sheetBackHost.dispatch()
                    },
                    enabled = url.isNotBlank(),
                    modifier = Modifier.testTag(UiPageTags.BRIEF_SOURCE_ADD_CONFIRM),
                ) {
                    Text(text = UiStrings.DAILY_BRIEF_ADD)
                }
            }
        }
    }
}

/** The report's third slot: network bytes, model calls and the billing label. */
private fun reportTail(report: DailyBriefReport): String {
    val network = report.networkBytes?.let {
        UiStrings.DAILY_BRIEF_REPORT_NETWORK.format(formatByteSize(it))
    } ?: UiStrings.UNKNOWN
    val model = report.modelCalls?.let {
        UiStrings.DAILY_BRIEF_REPORT_MODEL.format(it)
    } ?: UiStrings.UNKNOWN
    val billing = report.billingLabel?.takeUnless { it.isBlank() } ?: UiStrings.UNKNOWN
    return listOf(network, model, billing).joinToString(" · ")
}

/** The item summary's line limit, from the baseline's `.lineLimit(4)`. */
private const val SUMMARY_LINE_LIMIT: Int = 4

/** Every token this file reads; kept equal to the source by `PageTokenReferenceTest`. */
internal object DailyBriefPageTokens {
    val refs: List<String> = listOf(
        "colors.accent",
        "colors.danger",
        "colors.input",
        "colors.onAccent",
        "colors.primary",
        "colors.secondary",
        "colors.tertiary",
        "colors.warning",
        "geometry.pageOuterMarginH",
        "spacing.badgeInsetV",
        "spacing.iconText",
        "typography.body",
        "typography.caption",
        "typography.headline",
        "typography.secondary",
        "typography.subheadline",
    )
}

/** One baseline form field: a label above a single-line field. */
@Composable
private fun SourceDialogField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    tag: String,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Text(
            text = label,
            style = type.caption.copy(color = tokens.colors.secondary),
        )
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = type.secondary.copy(color = tokens.colors.primary),
            cursorBrush = SolidColor(tokens.colors.accent),
            keyboardOptions = keyboardOptions,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(tag)
                .semantics { contentDescription = label },
            decorationBox = { inner ->
                if (value.isEmpty()) {
                    BasicText(
                        text = label,
                        style = type.secondary.copy(color = tokens.colors.tertiary),
                    )
                }
                inner()
            },
        )
    }
}
