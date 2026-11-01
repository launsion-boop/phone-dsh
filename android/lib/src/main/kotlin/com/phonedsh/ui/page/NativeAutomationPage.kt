// Scheduled automation: the catalog, one schedule's detail and its delivery history.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row NativeAutomationPage (定时任务、计划详情与历史;
// entries: 抽屉「定时任务」、会话页入口; exit: push; child pages
// ScheduleDetailPage, ScheduleHistoryPage, ScheduleEditorPage), §3.1 (the
// ScreenState layer) and §5 (`insets`).
//
// The page has no harness event anchor: every schedule, time string and delivery
// is a host read, so §3.1 rule 3 makes the read-only snapshot the UiState-side
// input and `from(snapshot, local)` a pure function. The page never reads a
// clock: `nextRun`, `latestDelivery`, `deliveredAt` and `scheduledAt` are already
// formatted by the host, and a missing one renders 未知 with an explanation.
//
// The three outcomes that look alike are kept apart. A reported empty schedule
// list is 还没有定时任务; an unreported list is 未知 (never `0 个任务`); a failed
// read is 失败 and drops every schedule claim. The same rule applies inside the
// history: a null delivery list is 未知, an empty one is 没有投递记录, and a
// failure is 投递记录读取失败.
//
// The catalog, detail and history are one ScreenState with a pure route field.
// The editor is not re-implemented here: the baseline's ScheduleEditorPage is a
// host sheet, and the Android host currently exposes no schedule-write command.
// The page hands creation and editing to the host through `onNewSchedule` and
// `onEditSchedule`, so this file never invents a second schedule store. That
// handoff is recorded as an open parity question in the lane receipt rather
// than hidden.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageListRowMinHeight`); the header and InfoRow floors live in
// `PageScaffold.kt`, and the list gap comes from `pageListGap`. No
// signature-surface geometry is reused, so no `unverified geometry` marker
// applies.
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
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/** The schedule's state as the host reported it. [UNKNOWN] is not `已停止`. */
public enum class ScheduleStatus {
    ACTIVE,
    STOPPED,
    UNKNOWN,
}

/**
 * One schedule in the host's read-only snapshot.
 *
 * @param id the host's stable id; also the row tag suffix.
 * @param title the schedule name.
 * @param prompt what the scheduled turn will be asked; `null` when unreported.
 * @param status the active/stopped fact; [ScheduleStatus.UNKNOWN] when unread.
 * @param rule the host's rule spelling (`after`, `every`, a cron expression...).
 * @param nextRun the host-formatted next run; the page never computes it.
 * @param latestDelivery the host-formatted last delivery, if one happened.
 * @param sessionTitle the target session's title, if the host resolved it.
 * @param detail an optional host-supplied one-line detail.
 */
@Immutable
public data class AutomationSchedule(
    public val id: String,
    public val title: String,
    public val prompt: String? = null,
    public val status: ScheduleStatus = ScheduleStatus.UNKNOWN,
    public val rule: String? = null,
    public val nextRun: String? = null,
    public val latestDelivery: String? = null,
    public val sessionTitle: String? = null,
    public val detail: String? = null,
)

/**
 * One delivery row in a schedule's history.
 *
 * @param id the host's stable id.
 * @param deliveredAt the host-formatted delivery time.
 * @param scheduledAt the host-formatted planned time.
 * @param prompt the delivered prompt, when the host retains it.
 */
@Immutable
public data class AutomationDelivery(
    public val id: String,
    public val deliveredAt: String,
    public val scheduledAt: String,
    public val prompt: String? = null,
)

/**
 * One schedule's delivery history as the host reported it.
 *
 * @param scheduleId which schedule this history belongs to.
 * @param deliveries the rows; `null` means the host did not report them, while
 *   `emptyList()` means it reported "none".
 * @param notice the host's own explanation line (for example a retention
 *   notice), never page-invented.
 * @param hasMore whether the host says older rows can still be loaded.
 * @param failure a failure specific to this history read, or `null`.
 */
@Immutable
public data class AutomationHistory(
    public val scheduleId: String,
    public val deliveries: List<AutomationDelivery>? = null,
    public val notice: String? = null,
    public val hasMore: Boolean = false,
    public val failure: String? = null,
)

/**
 * The host's read-only automation snapshot.
 *
 * @param schedules the catalog; `null` means the list was not reported (未知),
 *   while `emptyList()` is the empty state.
 * @param history the history for the selected schedule, if the host sent one.
 */
@Immutable
public data class AutomationSnapshot(
    public val schedules: List<AutomationSchedule>? = null,
    public val history: AutomationHistory? = null,
)

/**
 * The page's read-only input.
 *
 * @param snapshot the host's snapshot; `null` means no snapshot was reported.
 * @param failure the host's read failure; non-null when the last read failed.
 */
@Immutable
public data class AutomationFacts(
    public val snapshot: AutomationSnapshot? = null,
    public val failure: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The four outcomes the catalog distinguishes. */
public enum class AutomationStatus {
    /** At least one schedule was reported. */
    READY,

    /** The host reported an empty schedule list. */
    EMPTY,

    /** The last host read failed; no schedule claim survives it. */
    FAILED,

    /** The schedule list was not reported: the page says 未知, never `0 条`. */
    UNKNOWN,
}

/** Which child view of the page is showing. Pure local state, not a UiState node. */
public enum class AutomationRoute {
    CATALOG,
    DETAIL,
    HISTORY,
}

/** The four outcomes of one schedule's delivery history. */
public enum class AutomationHistoryStatus {
    READY,
    EMPTY,
    FAILED,
    UNKNOWN,
}

/** One display-ready schedule row. Missing host values are 未知, never a default. */
@Immutable
public data class AutomationScheduleView(
    public val id: String,
    public val title: String,
    public val prompt: String,
    public val statusText: String,
    public val statusTone: PageTone,
    public val ruleText: String,
    public val nextRunText: String,
    public val latestDeliveryText: String,
    public val sessionText: String,
    public val detailText: String?,
    /** True when a visible value is 未知, so the page can explain the word once. */
    public val hasUnmeasuredValues: Boolean,
)

/** One display-ready delivery row. */
@Immutable
public data class AutomationDeliveryView(
    public val id: String,
    public val deliveredAt: String,
    public val scheduledAt: String,
    public val prompt: String?,
)

/**
 * The complete automation screen state.
 *
 * @param status the four-state catalog outcome; [AutomationStatus.FAILED] wins
 *   because a failed read proves nothing about the schedules.
 * @param route the pure child route; forced to [AutomationRoute.CATALOG] unless
 *   the catalog is [AutomationStatus.READY], so a stale detail page cannot
 *   outlive the schedule list it belongs to.
 * @param schedules the display-ready catalog rows, in host order.
 * @param scheduleCount the reported count; `null` for 未知/失败, `0` only for a
 *   reported empty list.
 * @param selectedScheduleId the resolved selected id, or `null`.
 * @param detail the selected schedule's display row, or `null` when missing.
 * @param detailMissing true when the local route still points at a schedule the
 *   new snapshot no longer contains; the page then says 任务不存在.
 * @param historyStatus the selected schedule's history outcome.
 * @param deliveries the display-ready delivery rows; empty unless READY.
 * @param historyCount the reported delivery count; `null` when unread.
 * @param historyNotice the host's own history notice, or `null`.
 * @param historyHasMore true while the host offers older rows.
 * @param historyFailure the history-specific failure message, or `null`.
 * @param failure the catalog failure message, or `null`.
 * @param hasUnmeasuredValues true when a visible catalog/detail value is 未知.
 */
@Immutable
public data class AutomationScreenState(
    public val status: AutomationStatus,
    public val route: AutomationRoute,
    public val schedules: List<AutomationScheduleView>,
    public val scheduleCount: Int?,
    public val selectedScheduleId: String?,
    public val detail: AutomationScheduleView?,
    public val detailMissing: Boolean,
    public val historyStatus: AutomationHistoryStatus,
    public val deliveries: List<AutomationDeliveryView>,
    public val historyCount: Int?,
    public val historyNotice: String?,
    public val historyHasMore: Boolean,
    public val historyFailure: String?,
    public val failure: String?,
    public val hasUnmeasuredValues: Boolean,
) {
    /** True when the catalog list was not reported. */
    public val isUnknown: Boolean get() = status == AutomationStatus.UNKNOWN

    /** True when the host reported an empty catalog. */
    public val isEmpty: Boolean get() = status == AutomationStatus.EMPTY

    /** True when the last catalog read failed. */
    public val isFailed: Boolean get() = status == AutomationStatus.FAILED

    /**
     * A stable, display-free signature of the sequence-relevant state.
     *
     * The sequence test compares these strings and then replays the script, so a
     * clock, an I/O read or a schedule store call would show up as a mismatch.
     */
    public fun signature(): String = buildString {
        append(status.name).append(':')
        append(route.name).append(':')
        append(selectedScheduleId ?: "-").append(':')
        append(scheduleCount?.toString() ?: "-").append(':')
        append(historyStatus.name).append(':')
        append(historyCount?.toString() ?: "-").append(':')
        append(if (historyHasMore) "more" else "end").append(':')
        append(if (hasUnmeasuredValues) "partial" else "complete").append(':')
        append(schedules.joinToString(",") { it.id }).append(':')
        append(deliveries.joinToString(",") { it.id })
    }

    public companion object {
        /**
         * Projects (facts, local script) into the screen state.
         *
         * Pure: no clock, no I/O and no engine call. The host supplies every time
         * string, so the same facts and the same route script always yield the
         * same state sequence (§3.1).
         */
        public fun from(
            facts: AutomationFacts,
            local: AutomationLocalState = AutomationLocalState(),
        ): AutomationScreenState {
            val rawSchedules = facts.snapshot?.schedules
            val status = when {
                facts.failure != null -> AutomationStatus.FAILED
                rawSchedules == null -> AutomationStatus.UNKNOWN
                rawSchedules.isEmpty() -> AutomationStatus.EMPTY
                else -> AutomationStatus.READY
            }
            if (status != AutomationStatus.READY) {
                return AutomationScreenState(
                    status = status,
                    route = AutomationRoute.CATALOG,
                    schedules = emptyList(),
                    scheduleCount = if (status == AutomationStatus.EMPTY) 0 else null,
                    selectedScheduleId = null,
                    detail = null,
                    detailMissing = false,
                    historyStatus = AutomationHistoryStatus.UNKNOWN,
                    deliveries = emptyList(),
                    historyCount = null,
                    historyNotice = null,
                    historyHasMore = false,
                    historyFailure = null,
                    failure = facts.failure,
                    hasUnmeasuredValues = false,
                )
            }
            val schedules = rawSchedules.orEmpty().map(::scheduleView)
            val selected = local.selectedScheduleId?.let { id -> schedules.firstOrNull { it.id == id } }
            val detailMissing = local.route != AutomationRoute.CATALOG && selected == null
            val history = facts.snapshot?.history?.takeIf { it.scheduleId == selected?.id }
            val historyStatus = when {
                selected == null -> AutomationHistoryStatus.UNKNOWN
                history == null -> AutomationHistoryStatus.UNKNOWN
                history.failure != null -> AutomationHistoryStatus.FAILED
                history.deliveries == null -> AutomationHistoryStatus.UNKNOWN
                history.deliveries.isEmpty() -> AutomationHistoryStatus.EMPTY
                else -> AutomationHistoryStatus.READY
            }
            val deliveries = if (historyStatus == AutomationHistoryStatus.READY) {
                history?.deliveries.orEmpty().map { delivery ->
                    AutomationDeliveryView(
                        id = delivery.id,
                        deliveredAt = delivery.deliveredAt,
                        scheduledAt = delivery.scheduledAt,
                        prompt = delivery.prompt,
                    )
                }
            } else {
                emptyList()
            }
            val route = if (local.route == AutomationRoute.CATALOG) {
                AutomationRoute.CATALOG
            } else {
                local.route
            }
            return AutomationScreenState(
                status = AutomationStatus.READY,
                route = route,
                schedules = schedules,
                scheduleCount = schedules.size,
                selectedScheduleId = selected?.id,
                detail = selected,
                detailMissing = detailMissing,
                historyStatus = historyStatus,
                deliveries = deliveries,
                historyCount = when (historyStatus) {
                    AutomationHistoryStatus.READY,
                    AutomationHistoryStatus.EMPTY,
                    -> deliveries.size

                    AutomationHistoryStatus.FAILED,
                    AutomationHistoryStatus.UNKNOWN,
                    -> null
                },
                historyNotice = history?.notice,
                historyHasMore = historyStatus == AutomationHistoryStatus.READY && history?.hasMore == true,
                historyFailure = history?.failure,
                failure = null,
                hasUnmeasuredValues = schedules.any { it.hasUnmeasuredValues },
            )
        }

        private fun scheduleView(schedule: AutomationSchedule): AutomationScheduleView {
            val statusText = when (schedule.status) {
                ScheduleStatus.ACTIVE -> UiStrings.AUTOMATION_ACTIVE
                ScheduleStatus.STOPPED -> UiStrings.AUTOMATION_STOPPED
                ScheduleStatus.UNKNOWN -> UiStrings.AUTOMATION_STATUS_UNKNOWN
            }
            val statusTone = when (schedule.status) {
                ScheduleStatus.ACTIVE -> PageTone.ON
                ScheduleStatus.STOPPED -> PageTone.NORMAL
                ScheduleStatus.UNKNOWN -> PageTone.UNKNOWN
            }
            val prompt = schedule.prompt?.takeUnless { it.isBlank() }
            val rule = schedule.rule?.takeUnless { it.isBlank() }
            val nextRun = schedule.nextRun?.takeUnless { it.isBlank() }
            val latest = schedule.latestDelivery?.takeUnless { it.isBlank() }
            val session = schedule.sessionTitle?.takeUnless { it.isBlank() }
            return AutomationScheduleView(
                id = schedule.id,
                title = schedule.title,
                prompt = prompt ?: UiStrings.UNKNOWN,
                statusText = statusText,
                statusTone = statusTone,
                ruleText = rule ?: UiStrings.UNKNOWN,
                nextRunText = nextRun ?: UiStrings.UNKNOWN,
                latestDeliveryText = latest ?: UiStrings.UNKNOWN,
                sessionText = session ?: UiStrings.AUTOMATION_SESSION_UNKNOWN,
                detailText = schedule.detail?.takeUnless { it.isBlank() },
                hasUnmeasuredValues = schedule.status == ScheduleStatus.UNKNOWN ||
                    prompt == null ||
                    rule == null ||
                    nextRun == null ||
                    latest == null ||
                    session == null,
            )
        }
    }
}

/** The local UI events of the automation page: navigation only. */
public sealed interface AutomationUiEvent {
    /** Open one schedule's detail. */
    public data class OpenDetail(public val id: String) : AutomationUiEvent

    /** Open one schedule's delivery history. */
    public data class OpenHistory(public val id: String) : AutomationUiEvent

    /** Go back one child level; the catalog is the root of this page. */
    public data object Back : AutomationUiEvent
}

/**
 * The route script; [apply] is pure, so a test drives it like a reducer.
 *
 * @param route which child view is showing.
 * @param selectedScheduleId the schedule the child view belongs to.
 */
@Immutable
public data class AutomationLocalState(
    public val route: AutomationRoute = AutomationRoute.CATALOG,
    public val selectedScheduleId: String? = null,
) {
    /** Applies one local event. */
    public fun apply(event: AutomationUiEvent): AutomationLocalState = when (event) {
        is AutomationUiEvent.OpenDetail -> copy(
            route = AutomationRoute.DETAIL,
            selectedScheduleId = event.id,
        )

        is AutomationUiEvent.OpenHistory -> copy(
            route = AutomationRoute.HISTORY,
            selectedScheduleId = event.id,
        )

        AutomationUiEvent.Back -> when (route) {
            AutomationRoute.HISTORY -> if (selectedScheduleId != null) {
                copy(route = AutomationRoute.DETAIL)
            } else {
                copy(route = AutomationRoute.CATALOG, selectedScheduleId = null)
            }

            AutomationRoute.DETAIL -> copy(route = AutomationRoute.CATALOG, selectedScheduleId = null)
            AutomationRoute.CATALOG -> this
        }
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The scheduled-automation page.
 *
 * @param state the pure screen state (`AutomationScreenState.from`).
 * @param onBack close the page (the catalog is the page root).
 * @param onOpenDetail open one schedule's detail; the host applies
 *   `AutomationUiEvent.OpenDetail`.
 * @param onOpenHistory open one schedule's history; the host applies
 *   `AutomationUiEvent.OpenHistory`.
 * @param onBackToCatalog leave a child view; the host applies
 *   `AutomationUiEvent.Back`.
 * @param onRefresh re-read the snapshot; `null` hides the header action.
 * @param onNewSchedule open the host's editor for a new schedule; `null` hides
 *   the empty-state action and the header action.
 * @param onEditSchedule open the host's editor for an existing schedule; `null`
 *   hides the detail row.
 * @param onLoadMoreHistory ask the host for older delivery rows; `null` hides
 *   the action even when the host says more exist.
 * @param onRetry retry a failed read; `null` renders no retry row.
 * @param onDismissFailure dismiss the failure line; `null` renders no dismiss row.
 */
@Composable
public fun NativeAutomationPage(
    state: AutomationScreenState,
    onBack: () -> Unit,
    onOpenDetail: (String) -> Unit,
    onOpenHistory: (String) -> Unit,
    onBackToCatalog: () -> Unit,
    modifier: Modifier = Modifier,
    onRefresh: (() -> Unit)? = null,
    onNewSchedule: (() -> Unit)? = null,
    onEditSchedule: ((String) -> Unit)? = null,
    onLoadMoreHistory: (() -> Unit)? = null,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
) {
    val title = when (state.route) {
        AutomationRoute.CATALOG -> UiStrings.AUTOMATION_TITLE
        AutomationRoute.DETAIL -> UiStrings.AUTOMATION_DETAIL_TITLE
        AutomationRoute.HISTORY -> UiStrings.AUTOMATION_HISTORY_TITLE
    }
    PageFrame(
        title = title,
        onBack = {
            if (state.route == AutomationRoute.CATALOG) onBack() else onBackToCatalog()
        },
        modifier = modifier,
        rootTag = UiPageTags.AUTOMATION_ROOT,
        actions = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (onNewSchedule != null && state.route == AutomationRoute.CATALOG) {
                    SessionTextAction(
                        label = UiStrings.AUTOMATION_NEW,
                        onClick = onNewSchedule,
                        tone = SessionActionTone.ACCENT,
                    )
                }
                if (onRefresh != null) {
                    SessionTextAction(
                        label = UiStrings.AUTOMATION_REFRESH,
                        onClick = onRefresh,
                        tone = SessionActionTone.SECONDARY,
                    )
                }
            }
        },
    ) {
        when (state.status) {
            AutomationStatus.FAILED -> AutomationFailureBlock(
                failure = state.failure,
                onRetry = onRetry,
                onDismissFailure = onDismissFailure,
            )

            AutomationStatus.UNKNOWN -> AutomationUnknownList()

            AutomationStatus.EMPTY -> AutomationEmptyBlock(onNewSchedule = onNewSchedule)

            AutomationStatus.READY -> when (state.route) {
                AutomationRoute.CATALOG -> AutomationCatalogList(
                    state = state,
                    onOpenDetail = onOpenDetail,
                )

                AutomationRoute.DETAIL -> AutomationDetailList(
                    state = state,
                    onOpenHistory = onOpenHistory,
                    onEditSchedule = onEditSchedule,
                )

                AutomationRoute.HISTORY -> AutomationHistoryList(
                    state = state,
                    onLoadMore = onLoadMoreHistory,
                )
            }
        }
    }
}

/**
 * The unknown catalog: a scrollable pair of lines so the negative assertion in
 * the test runs against a composed node, not against a window that never held it.
 */
@Composable
private fun AutomationUnknownList() {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.AUTOMATION_LIST),
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        item(key = "automation.unknown") {
            InfoRow(
                title = UiStrings.AUTOMATION_UNKNOWN_STATE,
                value = null,
                subtitle = UiStrings.AUTOMATION_UNKNOWN_HINT,
                modifier = Modifier.testTag(UiPageTags.AUTOMATION_UNKNOWN),
            )
        }
        item(key = "automation.unknown.detail") {
            InfoRow(
                title = UiStrings.UNKNOWN,
                value = null,
                subtitle = UiStrings.AUTOMATION_UNKNOWN_DETAIL,
                tone = PageTone.UNKNOWN,
                modifier = Modifier.testTag(UiPageTags.AUTOMATION_UNKNOWN_DETAIL),
            )
        }
    }
}

/** The reported empty catalog, with the one write action the host owns. */
@Composable
private fun AutomationEmptyBlock(onNewSchedule: (() -> Unit)?) {
    Column(modifier = Modifier.fillMaxSize()) {
        EmptyHint(
            title = UiStrings.AUTOMATION_EMPTY,
            hint = UiStrings.AUTOMATION_EMPTY_HINT,
            tag = UiPageTags.AUTOMATION_EMPTY,
            modifier = Modifier.weight(1f),
        )
        if (onNewSchedule != null) {
            Box(
                modifier = Modifier.fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) {
                SessionTextAction(
                    label = UiStrings.AUTOMATION_NEW,
                    onClick = onNewSchedule,
                    tone = SessionActionTone.ACCENT,
                    modifier = Modifier.testTag(UiPageTags.AUTOMATION_NEW),
                )
            }
        }
    }
}

/** The measured catalog: one row per schedule, in host order. */
@Composable
private fun AutomationCatalogList(
    state: AutomationScreenState,
    onOpenDetail: (String) -> Unit,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.AUTOMATION_LIST),
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        if (state.hasUnmeasuredValues) {
            item(key = "automation.unmeasured") {
                InfoRow(
                    title = UiStrings.UNKNOWN,
                    value = null,
                    subtitle = UiStrings.AUTOMATION_UNMEASURED_HINT,
                    tone = PageTone.UNKNOWN,
                    modifier = Modifier.testTag(UiPageTags.AUTOMATION_UNMEASURED),
                )
            }
        }
        items(count = state.schedules.size, key = { index -> state.schedules[index].id }) { index ->
            val schedule = state.schedules[index]
            AutomationScheduleRow(
                schedule = schedule,
                onClick = { onOpenDetail(schedule.id) },
            )
        }
        item(key = "automation.read-only") {
            AutomationNoteRow(text = UiStrings.AUTOMATION_READ_ONLY)
        }
    }
}

/** One schedule row: name and status, prompt, then session and next run. */
@Composable
private fun AutomationScheduleRow(
    schedule: AutomationScheduleView,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.AUTOMATION_ROW_PREFIX + schedule.id)
            .clickable(role = Role.Button, onClick = onClick)
            // Page-level geometry: a schedule is a compact list row.
            .defaultMinSize(minHeight = tokens.geometry.pageListRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = schedule.title,
                style = type.body.copy(color = tokens.colors.primary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = schedule.statusText,
                style = type.caption.copy(color = schedule.statusTone.ink(tokens)),
                maxLines = 1,
            )
        }
        BasicText(
            text = schedule.prompt,
            style = type.secondary.copy(color = tokens.colors.secondary),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        BasicText(
            text = scheduleMeta(schedule),
            style = type.caption.copy(color = tokens.colors.tertiary),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** One schedule's detail, including the route into its delivery history. */
@Composable
private fun AutomationDetailList(
    state: AutomationScreenState,
    onOpenHistory: (String) -> Unit,
    onEditSchedule: ((String) -> Unit)?,
) {
    val detail = state.detail
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.AUTOMATION_DETAIL),
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        if (state.detailMissing || detail == null) {
            item(key = "automation.detail.missing") {
                InfoRow(
                    title = UiStrings.AUTOMATION_NOT_FOUND,
                    value = null,
                    subtitle = UiStrings.AUTOMATION_NOT_FOUND_HINT,
                    tone = PageTone.DEGRADED,
                )
            }
            return@LazyColumn
        }
        item(key = "automation.detail.status") {
            InfoRow(
                title = UiStrings.AUTOMATION_STATUS,
                value = detail.statusText,
                tone = detail.statusTone,
                subtitle = if (detail.statusTone == PageTone.UNKNOWN) {
                    UiStrings.AUTOMATION_STATUS_UNKNOWN
                } else {
                    null
                },
            )
        }
        item(key = "automation.detail.rule") {
            InfoRow(
                title = UiStrings.AUTOMATION_RULE,
                value = detail.ruleText,
                tone = if (detail.ruleText == UiStrings.UNKNOWN) PageTone.UNKNOWN else PageTone.NORMAL,
            )
        }
        item(key = "automation.detail.next") {
            InfoRow(
                title = UiStrings.AUTOMATION_NEXT_RUN,
                value = detail.nextRunText,
                tone = if (detail.nextRunText == UiStrings.UNKNOWN) PageTone.UNKNOWN else PageTone.NORMAL,
            )
        }
        item(key = "automation.detail.latest") {
            InfoRow(
                title = UiStrings.AUTOMATION_LATEST_DELIVERY,
                value = detail.latestDeliveryText,
                tone = if (detail.latestDeliveryText == UiStrings.UNKNOWN) {
                    PageTone.UNKNOWN
                } else {
                    PageTone.NORMAL
                },
            )
        }
        item(key = "automation.detail.session") {
            InfoRow(
                title = UiStrings.AUTOMATION_SESSION,
                value = detail.sessionText,
                tone = if (detail.sessionText == UiStrings.AUTOMATION_SESSION_UNKNOWN) {
                    PageTone.UNKNOWN
                } else {
                    PageTone.NORMAL
                },
            )
        }
        item(key = "automation.detail.prompt") {
            InfoRow(
                title = UiStrings.AUTOMATION_PROMPT,
                value = null,
                subtitle = detail.prompt,
            )
        }
        item(key = "automation.detail.history") {
            InfoRow(
                title = UiStrings.AUTOMATION_HISTORY_OPEN,
                value = null,
                onClick = { onOpenHistory(detail.id) },
                modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_OPEN),
            )
        }
        if (onEditSchedule != null) {
            item(key = "automation.detail.edit") {
                InfoRow(
                    title = UiStrings.AUTOMATION_EDIT,
                    value = null,
                    onClick = { onEditSchedule(detail.id) },
                    modifier = Modifier.testTag(UiPageTags.AUTOMATION_EDIT),
                )
            }
        }
        if (detail.hasUnmeasuredValues) {
            item(key = "automation.detail.unmeasured") {
                InfoRow(
                    title = UiStrings.UNKNOWN,
                    value = null,
                    subtitle = UiStrings.AUTOMATION_UNMEASURED_HINT,
                    tone = PageTone.UNKNOWN,
                    modifier = Modifier.testTag(UiPageTags.AUTOMATION_UNMEASURED),
                )
            }
        }
        item(key = "automation.detail.read-only") {
            AutomationNoteRow(text = UiStrings.AUTOMATION_READ_ONLY)
        }
    }
}

/** One schedule's delivery history, with the empty/unknown/failed split. */
@Composable
private fun AutomationHistoryList(
    state: AutomationScreenState,
    onLoadMore: (() -> Unit)?,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.AUTOMATION_HISTORY_LIST),
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        if (state.detailMissing || state.detail == null) {
            item(key = "automation.history.missing") {
                InfoRow(
                    title = UiStrings.AUTOMATION_NOT_FOUND,
                    value = null,
                    subtitle = UiStrings.AUTOMATION_NOT_FOUND_HINT,
                    tone = PageTone.DEGRADED,
                )
            }
            return@LazyColumn
        }
        state.historyNotice?.let { notice ->
            item(key = "automation.history.notice") {
                InfoRow(title = UiStrings.AUTOMATION_HISTORY_TITLE, value = null, subtitle = notice)
            }
        }
        when (state.historyStatus) {
            AutomationHistoryStatus.UNKNOWN -> {
                item(key = "automation.history.unknown") {
                    InfoRow(
                        title = UiStrings.AUTOMATION_HISTORY_UNKNOWN,
                        value = null,
                        subtitle = UiStrings.AUTOMATION_HISTORY_UNKNOWN_HINT,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_UNKNOWN),
                    )
                }
                item(key = "automation.history.unknown.detail") {
                    InfoRow(
                        title = UiStrings.UNKNOWN,
                        value = null,
                        subtitle = UiStrings.AUTOMATION_HISTORY_UNKNOWN_DETAIL,
                        tone = PageTone.UNKNOWN,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_UNKNOWN_DETAIL),
                    )
                }
            }

            AutomationHistoryStatus.FAILED -> {
                item(key = "automation.history.failure") {
                    InfoRow(
                        title = UiStrings.AUTOMATION_HISTORY_FAILED,
                        value = null,
                        subtitle = state.historyFailure,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_FAILURE),
                    )
                }
            }

            AutomationHistoryStatus.EMPTY -> {
                item(key = "automation.history.empty") {
                    InfoRow(
                        title = UiStrings.AUTOMATION_HISTORY_EMPTY,
                        value = null,
                        subtitle = UiStrings.AUTOMATION_HISTORY_EMPTY_HINT,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_EMPTY),
                    )
                }
            }

            AutomationHistoryStatus.READY -> {
                items(
                    count = state.deliveries.size,
                    key = { index -> state.deliveries[index].id },
                ) { index ->
                    AutomationDeliveryRow(delivery = state.deliveries[index])
                }
                if (state.historyHasMore && onLoadMore != null) {
                    item(key = "automation.history.more") {
                        InfoRow(
                            title = UiStrings.AUTOMATION_HISTORY_MORE,
                            value = null,
                            onClick = onLoadMore,
                            modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_MORE),
                        )
                    }
                }
            }
        }
    }
}

/** One delivery row: delivered time, planned time and the retained prompt. */
@Composable
private fun AutomationDeliveryRow(delivery: AutomationDeliveryView) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.AUTOMATION_HISTORY_ROW)
            // Page-level geometry: a delivery is a compact list row.
            .defaultMinSize(minHeight = tokens.geometry.pageListRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = delivery.deliveredAt,
            style = type.secondary.copy(color = tokens.colors.primary),
        )
        BasicText(
            text = UiStrings.AUTOMATION_PLANNED_AT_FORMAT.format(delivery.scheduledAt),
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
        delivery.prompt?.let { prompt ->
            BasicText(
                text = prompt,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
        }
    }
}

/** The catalog failure line with the shared retry/dismiss vocabulary. */
@Composable
private fun AutomationFailureBlock(
    failure: String?,
    onRetry: (() -> Unit)?,
    onDismissFailure: (() -> Unit)?,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        InfoRow(
            title = UiStrings.AUTOMATION_LOAD_FAILED,
            value = null,
            subtitle = failure,
            modifier = Modifier.testTag(UiPageTags.AUTOMATION_FAILURE),
        )
        if (onRetry != null) {
            InfoRow(
                title = UiStrings.RETRY,
                value = null,
                onClick = onRetry,
                modifier = Modifier.testTag(UiPageTags.AUTOMATION_RETRY),
            )
        }
        if (onDismissFailure != null) {
            InfoRow(
                title = UiStrings.DISMISS,
                value = null,
                onClick = onDismissFailure,
                modifier = Modifier.testTag(UiPageTags.AUTOMATION_DISMISS),
            )
        }
    }
}

/** One explanatory line; the ink is a token, never a second colour source. */
@Composable
private fun AutomationNoteRow(text: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.tertiary),
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** The one-line catalog subtitle: the session, then the next run or detail. */
private fun scheduleMeta(schedule: AutomationScheduleView): String =
    UiStrings.AUTOMATION_META_FORMAT.format(schedule.sessionText, schedule.nextRunText)

/** Every token this file reads; kept equal to the source by `PageTokenReferenceTest`. */
internal object NativeAutomationPageTokens {
    val refs: List<String> = listOf(
        "colors.primary",
        "colors.secondary",
        "colors.tertiary",
        "geometry.pageListRowMinHeight",
        "geometry.pageOuterMarginH",
        "spacing.badgeInsetV",
        "spacing.iconText",
        "typography.body",
        "typography.caption",
        "typography.secondary",
    )
}
