// Session activity: the eight sections the baseline shows for one session.
// SPDX-License-Identifier: MIT
//
// Mirror source: `examples/probe-app/PhoneDSHProbe/SessionActivityPage.swift`
// (read line by line; every section, row, control and string below names the
// lines it copies). The baseline is one `List` whose sections are, in this order:
// 会话 (`:16`), 计划 (`:21`), 待办 (`:31`), 目标 (`:47`), 子智能体 (`:66`),
// 计划任务 (`:82`), 后台作业 (`:100`), 技能目录 (`:120`) and one 暂不可用 section
// per failed read (`:140`–`:148`).
//
// The baseline has no separate loading, empty or failure body: an unreported list
// is an empty list there, so every section is always on screen with its own empty
// sentence (`:33`, `:61`, `:68`, `:84`, `:102`, `:122`). A failed read is a
// 暂不可用 disclosure, not a banner. This page therefore renders the same fixed
// section sequence; a list the *Android host* has not reported (`null`) is a
// single 未知 row instead of the empty sentence, because "not reported" and
// "reported empty" are different facts and the empty sentence claims the second.
//
// ScreenState: `SessionActivityScreenState.from(source, local)` is pure. The
// source is the host's read-only snapshot, the local script is the confirmation
// and the disclosure the user opened. §3.1 rule 3 makes that snapshot the
// UiState-side input on this page, so the section sequence and the confirmation
// sequence are asserted on the JVM.
//
// Geometry: the page margin and the compact row floor are page-level tokens
// (`geometry.pageOuterMarginH`, `geometry.pageListRowMinHeight`,
// `geometry.pageRowMinHeight`); the confirm panel reuses the approval card's
// `cardOuterMarginV` and says so. Nothing here invents a colour or a length.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The plan-mode row (`SessionActivityPage.swift:22`–`:28`).
 *
 * @param active `management.planActive`; `null` is the baseline's "plan mode was
 *   never enabled for this session" branch, not an unread value.
 * @param pending `management.planPending`: a mode change is being applied.
 */
@Immutable
public data class ActivityPlan(
    public val active: Boolean,
    public val pending: Boolean,
)

/** One todo row (`:36`–`:43`). */
@Immutable
public data class ActivityTodo(
    public val id: String,
    public val title: String,
    public val status: String? = null,
)

/**
 * The session's goal (`:47`–`:64`).
 *
 * @param phase the host's raw phase; the label is derived, and a phase the
 *   baseline cannot translate is shown as its raw value (`:226`–`:235`).
 * @param roundsStarted `null` when unmeasured: the row says 未知 instead of 0.
 * @param maxGoalRounds `null` when unmeasured.
 */
@Immutable
public data class ActivityGoal(
    public val objective: String,
    public val phase: String,
    public val roundsStarted: Int? = null,
    public val maxGoalRounds: Int? = null,
)

/** One sub-agent row (`:71`–`:79`). */
@Immutable
public data class ActivitySubagent(
    public val id: String,
    public val title: String,
    public val detail: String,
    public val status: String? = null,
)

/** One scheduled task row (`:87`–`:97`). */
@Immutable
public data class ActivitySchedule(
    public val id: String,
    public val title: String,
    public val detail: String,
    public val status: String? = null,
)

/** One background job row (`:105`–`:117`). */
@Immutable
public data class ActivityJob(
    public val id: String,
    public val title: String,
    public val detail: String,
    public val status: String? = null,
)

/** One skill row (`:125`–`:137`). */
@Immutable
public data class ActivitySkill(
    public val id: String,
    public val title: String,
    public val detail: String,
    public val status: String? = null,
)

/**
 * The page's read-only input: one host read per section.
 *
 * A `null` list means the Android host did not report that read. The baseline has
 * no such state (its model arrays are always present), so the page renders a 未知
 * row there instead of the baseline's empty sentence.
 *
 * @param errors `management.activityErrors`: one 暂不可用 section per entry,
 *   iterated in the baseline's sorted key order (`:140`).
 */
@Immutable
public data class SessionActivitySource(
    public val plan: ActivityPlan? = null,
    public val todos: List<ActivityTodo>? = null,
    public val goal: ActivityGoal? = null,
    public val subagents: List<ActivitySubagent>? = null,
    public val schedules: List<ActivitySchedule>? = null,
    public val jobs: List<ActivityJob>? = null,
    public val skills: List<ActivitySkill>? = null,
    public val errors: Map<String, String> = emptyMap(),
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The goal actions the baseline's confirmation dialog can perform (`:53`–`:59`). */
public enum class ActivityGoalAction { PAUSE, RESUME, COMPLETE }

/** What a confirmation is waiting for; `null` means none is open. */
public sealed interface ActivityConfirm {
    /** 暂停目标 / 恢复目标 / 标记完成 (`:53`–`:59`). */
    public data class Goal(public val action: ActivityGoalAction) : ActivityConfirm

    /** 删除计划任务 (`:95`). */
    public data class DeleteSchedule(public val id: String) : ActivityConfirm

    /** 停止后台作业 (`:114`). */
    public data class StopJob(public val id: String) : ActivityConfirm

    /** 中断子智能体 (`:76`). */
    public data class InterruptSubagent(public val id: String) : ActivityConfirm
}

/** Which fixed section a [ActivitySection] is; the section titles are one table. */
public enum class ActivitySectionKind {
    SESSION,
    PLAN,
    TODOS,
    GOAL,
    SUBAGENTS,
    SCHEDULES,
    JOBS,
    SKILLS,
    UNAVAILABLE,
}

/** The section title (`:16`, `:21`, `:31`, `:47`, `:66`, `:82`, `:100`, `:120`, `:142`). */
public val ActivitySectionKind.title: String
    get() = when (this) {
        ActivitySectionKind.SESSION -> UiStrings.ACTIVITY_SESSION_TITLE
        ActivitySectionKind.PLAN -> UiStrings.ACTIVITY_PLAN_TITLE
        ActivitySectionKind.TODOS -> UiStrings.ACTIVITY_TODOS_TITLE
        ActivitySectionKind.GOAL -> UiStrings.ACTIVITY_GOAL_TITLE
        ActivitySectionKind.SUBAGENTS -> UiStrings.ACTIVITY_SUBAGENTS_TITLE
        ActivitySectionKind.SCHEDULES -> UiStrings.ACTIVITY_SCHEDULES_TITLE
        ActivitySectionKind.JOBS -> UiStrings.ACTIVITY_JOBS_TITLE
        ActivitySectionKind.SKILLS -> UiStrings.ACTIVITY_SKILLS_TITLE
        ActivitySectionKind.UNAVAILABLE -> UiStrings.ACTIVITY_ERRORS_TITLE
    }

/** A todo row with its derived label and ink (`:210`–`:224`). */
@Immutable
public data class TodoRowView(
    public val id: String,
    public val title: String,
    /** ✓ / ◐ / ○, the baseline's three SF Symbols as text glyphs. */
    public val icon: String,
    /** 已完成 / 进行中 / 待办. */
    public val label: String,
    public val completed: Boolean,
)

/** The goal section's derived rows (`:48`–`:59`). */
@Immutable
public data class GoalRowView(
    public val objective: String,
    /** The translated phase, or the raw value when the baseline cannot translate it. */
    public val phaseLabel: String,
    /** "N / M", or 未知 when a bound was not measured. */
    public val roundsLabel: String,
    /** `:52`: phase is exactly "active". */
    public val canPause: Boolean,
    /** `:54`: phase is exactly "paused" or "blocked". */
    public val canResume: Boolean,
    /** `:57`: phase is not exactly "complete". */
    public val canComplete: Boolean,
)

/** One sub-agent row with its conditional action (`:71`–`:79`). */
@Immutable
public data class SubagentRowView(
    public val id: String,
    public val title: String,
    public val detail: String,
    /** `:75`: status is exactly "continuable". */
    public val canInterrupt: Boolean,
)

/** One scheduled-task row (`:87`–`:96`): the status label and the delete action. */
@Immutable
public data class ScheduleRowView(
    public val id: String,
    public val title: String,
    public val detail: String,
    public val statusLabel: String,
)

/** One background-job row (`:105`–`:117`): the status label and the stop action. */
@Immutable
public data class JobRowView(
    public val id: String,
    public val title: String,
    public val detail: String,
    public val statusLabel: String,
    /** `:113`: status is "running" or "stopping". */
    public val canStop: Boolean,
)

/** One skill row (`:125`–`:137`): the status label is shown only when translated. */
@Immutable
public data class SkillRowView(
    public val id: String,
    public val title: String,
    public val detail: String,
    /** `null` when the baseline would repeat the raw value, i.e. show nothing. */
    public val statusLabel: String?,
)

/** One 暂不可用 section (`:142`–`:146`): the key's title and the failure detail. */
@Immutable
public data class UnavailableRowView(
    public val key: String,
    /** 「<key>的详细原因」. */
    public val title: String,
    public val detail: String,
    public val expanded: Boolean,
)

/**
 * One section, already resolved into the rows it renders.
 *
 * A `null` row list on [Todos]/[Subagents]/[Schedules]/[Jobs]/[Skills] is the
 * Android host's "not reported"; the page draws a 未知 row for it.
 */
public sealed interface ActivitySection {
    public val kind: ActivitySectionKind

    /** 会话: the one-line introduction (`:17`). */
    public data class Session(public val intro: String) : ActivitySection {
        override val kind: ActivitySectionKind get() = ActivitySectionKind.SESSION
    }

    /** 计划 (`:22`–`:28`): a value row, an optional pending row, or the empty line. */
    public data class Plan(
        public val modeLabel: String?,
        public val pending: Boolean,
        public val emptyLabel: String?,
    ) : ActivitySection {
        override val kind: ActivitySectionKind get() = ActivitySectionKind.PLAN
    }

    /** 待办 (`:32`–`:45`). */
    public data class Todos(
        public val rows: List<TodoRowView>?,
        public val emptyLabel: String?,
    ) : ActivitySection {
        override val kind: ActivitySectionKind get() = ActivitySectionKind.TODOS
    }

    /** 目标 (`:48`–`:63`). */
    public data class Goal(
        public val row: GoalRowView?,
        public val emptyLabel: String?,
    ) : ActivitySection {
        override val kind: ActivitySectionKind get() = ActivitySectionKind.GOAL
    }

    /** 子智能体 (`:67`–`:80`). */
    public data class Subagents(
        public val rows: List<SubagentRowView>?,
        public val emptyLabel: String?,
    ) : ActivitySection {
        override val kind: ActivitySectionKind get() = ActivitySectionKind.SUBAGENTS
    }

    /** 计划任务 (`:83`–`:98`). */
    public data class Schedules(
        public val rows: List<ScheduleRowView>?,
        public val emptyLabel: String?,
    ) : ActivitySection {
        override val kind: ActivitySectionKind get() = ActivitySectionKind.SCHEDULES
    }

    /** 后台作业 (`:101`–`:118`). */
    public data class Jobs(
        public val rows: List<JobRowView>?,
        public val emptyLabel: String?,
    ) : ActivitySection {
        override val kind: ActivitySectionKind get() = ActivitySectionKind.JOBS
    }

    /** 技能目录 (`:121`–`:138`). */
    public data class Skills(
        public val rows: List<SkillRowView>?,
        public val emptyLabel: String?,
    ) : ActivitySection {
        override val kind: ActivitySectionKind get() = ActivitySectionKind.SKILLS
    }

    /** 暂不可用 (`:142`–`:146`): one section per failed read, keyed by its name. */
    public data class Unavailable(public val row: UnavailableRowView) : ActivitySection {
        override val kind: ActivitySectionKind get() = ActivitySectionKind.UNAVAILABLE
    }
}

/**
 * The activity page state.
 *
 * @param sections the fixed section sequence followed by the failure sections.
 * @param confirm the open confirmation, if any.
 */
@Immutable
public data class SessionActivityScreenState(
    public val sections: List<ActivitySection>,
    public val confirm: ActivityConfirm? = null,
) {
    /** The section kinds in render order; the test asserts the baseline's order. */
    public val kinds: List<ActivitySectionKind> get() = sections.map { it.kind }

    /** The goal confirmation's title (`:192`–`:199`). */
    public val confirmTitle: String?
        get() = when (val c = confirm) {
            is ActivityConfirm.Goal -> goalConfirmTitle(c.action)
            is ActivityConfirm.DeleteSchedule -> UiStrings.ACTIVITY_CONFIRM_SCHEDULE
            is ActivityConfirm.StopJob -> UiStrings.ACTIVITY_CONFIRM_JOB
            is ActivityConfirm.InterruptSubagent -> UiStrings.ACTIVITY_CONFIRM_SUBAGENT
            null -> null
        }

    /** The goal dialog's message (`:165`); the other three have none. */
    public val confirmMessage: String?
        get() = if (confirm is ActivityConfirm.Goal) UiStrings.ACTIVITY_CONFIRM_GOAL_MESSAGE else null

    /** True when the confirmation's action is destructive (`:160`, `:168`, …). */
    public val confirmDestructive: Boolean
        get() = when (val c = confirm) {
            is ActivityConfirm.Goal -> c.action == ActivityGoalAction.COMPLETE
            is ActivityConfirm.DeleteSchedule, is ActivityConfirm.StopJob,
            is ActivityConfirm.InterruptSubagent,
            -> true
            null -> false
        }

    public companion object {
        /**
         * Projects (host snapshot, local script) into the page state.
         *
         * Pure: the same snapshot and script always yield the same sections.
         */
        public fun from(
            source: SessionActivitySource,
            local: SessionActivityLocalState = SessionActivityLocalState(),
        ): SessionActivityScreenState {
            val sections = buildList {
                add(ActivitySection.Session(intro = UiStrings.ACTIVITY_SESSION_INTRO))

                // `:21`–`:29`
                add(
                    ActivitySection.Plan(
                        modeLabel = source.plan?.let {
                            if (it.active) UiStrings.ACTIVITY_PLAN_ON else UiStrings.ACTIVITY_PLAN_OFF
                        },
                        pending = source.plan?.pending == true,
                        emptyLabel = if (source.plan == null) UiStrings.ACTIVITY_PLAN_NONE else null,
                    ),
                )

                // `:31`–`:45`
                add(
                    ActivitySection.Todos(
                        rows = source.todos?.map { todo ->
                            TodoRowView(
                                id = todo.id,
                                title = todo.title,
                                icon = todoIcon(todo.status),
                                label = todoLabel(todo.status),
                                completed = todo.status == "completed",
                            )
                        },
                        emptyLabel = source.todos?.let {
                            if (it.isEmpty()) UiStrings.ACTIVITY_TODOS_EMPTY else null
                        },
                    ),
                )

                // `:47`–`:64`
                add(
                    ActivitySection.Goal(
                        row = source.goal?.let { goal ->
                            GoalRowView(
                                objective = goal.objective,
                                phaseLabel = goalPhaseLabel(goal.phase),
                                roundsLabel = if (goal.roundsStarted != null && goal.maxGoalRounds != null) {
                                    UiStrings.ACTIVITY_GOAL_ROUNDS_VALUE.format(
                                        goal.roundsStarted,
                                        goal.maxGoalRounds,
                                    )
                                } else {
                                    UiStrings.UNKNOWN
                                },
                                // The baseline compares the raw phase, not the label.
                                canPause = goal.phase == "active",
                                canResume = goal.phase == "paused" || goal.phase == "blocked",
                                canComplete = goal.phase != "complete",
                            )
                        },
                        emptyLabel = if (source.goal == null) UiStrings.ACTIVITY_GOAL_NONE else null,
                    ),
                )

                // `:66`–`:80`
                add(
                    ActivitySection.Subagents(
                        rows = source.subagents?.map { row ->
                            SubagentRowView(
                                id = row.id,
                                title = row.title,
                                detail = row.detail,
                                canInterrupt = row.status == "continuable",
                            )
                        },
                        emptyLabel = source.subagents?.let {
                            if (it.isEmpty()) UiStrings.ACTIVITY_SUBAGENTS_EMPTY else null
                        },
                    ),
                )

                // `:82`–`:98`
                add(
                    ActivitySection.Schedules(
                        rows = source.schedules?.map { row ->
                            ScheduleRowView(
                                id = row.id,
                                title = row.title,
                                detail = row.detail,
                                statusLabel = statusLabel(row.status),
                            )
                        },
                        emptyLabel = source.schedules?.let {
                            if (it.isEmpty()) UiStrings.ACTIVITY_SCHEDULES_EMPTY else null
                        },
                    ),
                )

                // `:100`–`:118`
                add(
                    ActivitySection.Jobs(
                        rows = source.jobs?.map { row ->
                            JobRowView(
                                id = row.id,
                                title = row.title,
                                detail = row.detail,
                                statusLabel = statusLabel(row.status),
                                canStop = row.status == "running" || row.status == "stopping",
                            )
                        },
                        emptyLabel = source.jobs?.let {
                            if (it.isEmpty()) UiStrings.ACTIVITY_JOBS_EMPTY else null
                        },
                    ),
                )

                // `:120`–`:138`
                add(
                    ActivitySection.Skills(
                        rows = source.skills?.map { row ->
                            val label = row.status?.let(::statusLabel)
                            SkillRowView(
                                id = row.id,
                                title = row.title,
                                detail = row.detail,
                                // `:130`–`:133`: the label is drawn only when it is a
                                // translation; an unrecognised status shows nothing.
                                statusLabel = label?.takeIf { it != row.status },
                            )
                        },
                        emptyLabel = source.skills?.let {
                            if (it.isEmpty()) UiStrings.ACTIVITY_SKILLS_EMPTY else null
                        },
                    ),
                )

                // `:140`–`:148`: one section per failed read, sorted by key.
                source.errors.keys.sorted().forEach { key ->
                    val detail = source.errors[key] ?: return@forEach
                    add(
                        ActivitySection.Unavailable(
                            UnavailableRowView(
                                key = key,
                                title = UiStrings.ACTIVITY_ERRORS_DETAIL.format(key),
                                detail = detail,
                                expanded = key in local.expandedErrors,
                            ),
                        ),
                    )
                }
            }
            return SessionActivityScreenState(sections = sections, confirm = local.confirm)
        }
    }
}

/** 已完成 / 进行中 / 待办 (`:218`–`:224`). */
public fun todoLabel(status: String?): String = when (status) {
    "completed" -> UiStrings.ACTIVITY_TODO_DONE
    "in_progress" -> UiStrings.ACTIVITY_TODO_RUNNING
    else -> UiStrings.ACTIVITY_TODO_PENDING
}

/** The baseline's three SF Symbols as text glyphs (`:210`–`:216`). */
public fun todoIcon(status: String?): String = when (status) {
    "completed" -> DONE_GLYPH
    "in_progress" -> RUNNING_GLYPH
    else -> TODO_GLYPH
}

/** The goal phase's label; an unknown phase stays raw (`:226`–`:235`). */
public fun goalPhaseLabel(phase: String): String = when (phase.lowercase()) {
    "active" -> UiStrings.ACTIVITY_PHASE_ACTIVE
    "paused" -> UiStrings.ACTIVITY_PHASE_PAUSED
    "blocked" -> UiStrings.ACTIVITY_PHASE_BLOCKED
    "complete", "completed" -> UiStrings.ACTIVITY_PHASE_COMPLETE
    "failed" -> UiStrings.ACTIVITY_PHASE_FAILED
    else -> phase
}

/** A schedule/job/skill status; an unknown status stays raw (`:237`–`:250`). */
public fun statusLabel(status: String?): String = when (status?.lowercase()) {
    "active" -> UiStrings.ACTIVITY_STATUS_ACTIVE
    "pending" -> UiStrings.ACTIVITY_STATUS_PENDING
    "running" -> UiStrings.ACTIVITY_STATUS_RUNNING
    "stopping" -> UiStrings.ACTIVITY_STATUS_STOPPING
    "completed", "complete" -> UiStrings.ACTIVITY_STATUS_COMPLETE
    "failed", "error" -> UiStrings.ACTIVITY_STATUS_FAILED
    "cancelled", "canceled" -> UiStrings.ACTIVITY_STATUS_CANCELLED
    "paused" -> UiStrings.ACTIVITY_STATUS_PAUSED
    "unknown", null -> UiStrings.ACTIVITY_STATUS_UNKNOWN
    else -> status
}

/** The goal dialog's title (`:192`–`:199`). */
public fun goalConfirmTitle(action: ActivityGoalAction): String = when (action) {
    ActivityGoalAction.PAUSE -> UiStrings.ACTIVITY_CONFIRM_GOAL_PAUSE
    ActivityGoalAction.RESUME -> UiStrings.ACTIVITY_CONFIRM_GOAL_RESUME
    ActivityGoalAction.COMPLETE -> UiStrings.ACTIVITY_CONFIRM_GOAL_COMPLETE
}

// ---------------------------------------------------------------------------
// Local script
// ---------------------------------------------------------------------------

/** The local UI events: opening/closing a confirmation and a disclosure. */
public sealed interface SessionActivityUiEvent {
    /** 暂停目标 / 恢复目标 / 标记完成 was tapped; the dialog opens. */
    public data class RequestGoal(public val action: ActivityGoalAction) : SessionActivityUiEvent

    /** 删除计划任务 was tapped for [id]. */
    public data class RequestDeleteSchedule(public val id: String) : SessionActivityUiEvent

    /** 停止后台作业 was tapped for [id]. */
    public data class RequestStopJob(public val id: String) : SessionActivityUiEvent

    /** 中断子智能体 was tapped for [id]. */
    public data class RequestInterruptSubagent(public val id: String) : SessionActivityUiEvent

    /** 取消 (`:164`, `:172`, `:180`, `:188`). */
    public data object Cancel : SessionActivityUiEvent

    /** The dialog's action was confirmed; the host then performs it. */
    public data object Confirmed : SessionActivityUiEvent

    /** A 暂不可用 disclosure was opened or closed (`:143`). */
    public data class ToggleError(public val key: String) : SessionActivityUiEvent
}

/**
 * The local script; [apply] is pure, so a test drives it like a reducer.
 *
 * @param confirm the open confirmation, if any.
 * @param expandedErrors the failure keys whose disclosure the user opened; the
 *   baseline's DisclosureGroup starts collapsed.
 */
@Immutable
public data class SessionActivityLocalState(
    public val confirm: ActivityConfirm? = null,
    public val expandedErrors: Set<String> = emptySet(),
) {
    /** Applies one local event. */
    public fun apply(event: SessionActivityUiEvent): SessionActivityLocalState = when (event) {
        is SessionActivityUiEvent.RequestGoal -> copy(confirm = ActivityConfirm.Goal(event.action))
        is SessionActivityUiEvent.RequestDeleteSchedule ->
            copy(confirm = ActivityConfirm.DeleteSchedule(event.id))
        is SessionActivityUiEvent.RequestStopJob -> copy(confirm = ActivityConfirm.StopJob(event.id))
        is SessionActivityUiEvent.RequestInterruptSubagent ->
            copy(confirm = ActivityConfirm.InterruptSubagent(event.id))
        SessionActivityUiEvent.Cancel -> copy(confirm = null)
        SessionActivityUiEvent.Confirmed -> copy(confirm = null)
        is SessionActivityUiEvent.ToggleError -> copy(
            expandedErrors = if (event.key in expandedErrors) {
                expandedErrors - event.key
            } else {
                expandedErrors + event.key
            },
        )
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The activity page (`SessionActivityPage.swift`).
 *
 * @param state the pure screen state ([SessionActivityScreenState.from]).
 * @param onRefresh the toolbar's 刷新 (`:155`).
 * @param onToggleError open/close a 暂不可用 disclosure (`:143`).
 * @param onConfirm the dialog's action; the host performs it.
 * @param onCancel the dialog's 取消.
 * @param onBack leave the page (the baseline is a sheet; §5 `back-gesture`).
 * @param onRequestGoal a goal action row was tapped (`:53`–`:59`).
 * @param onRequestDeleteSchedule a schedule's 删除计划任务 (`:95`).
 * @param onRequestStopJob a job's 停止后台作业 (`:114`).
 * @param onRequestInterruptSubagent a sub-agent's 中断子智能体 (`:76`).
 */
@Composable
public fun SessionActivityPage(
    state: SessionActivityScreenState,
    onRefresh: () -> Unit,
    onToggleError: (String) -> Unit,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onRequestGoal: (ActivityGoalAction) -> Unit = {},
    onRequestDeleteSchedule: (String) -> Unit = {},
    onRequestStopJob: (String) -> Unit = {},
    onRequestInterruptSubagent: (String) -> Unit = {},
) {
    PageFrame(
        title = UiStrings.ACTIVITY_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.ACTIVITY_ROOT,
        modifier = modifier,
        actions = {
            SessionTextAction(
                label = UiStrings.ACTIVITY_REFRESH,
                onClick = onRefresh,
                tone = SessionActionTone.ACCENT,
                modifier = Modifier.testTag(UiPageTags.ACTIVITY_REFRESH),
            )
        },
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // `.confirmationDialog` (`:158`–`:189`) is a modal on the baseline, so
            // this is the standard Material dialog, not a page-level panel: the
            // interaction (scrim, dismiss, one action) has to match, not just the
            // words. Its colours and radius come from the theme tokens.
            if (state.confirm != null) {
                ConfirmDialog(
                    confirm = state.confirm,
                    title = state.confirmTitle.orEmpty(),
                    message = state.confirmMessage,
                    destructive = state.confirmDestructive,
                    onConfirm = onConfirm,
                    onCancel = onCancel,
                )
            }
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(UiPageTags.ACTIVITY_LIST),
            ) {
                state.sections.forEach { section ->
                    item(key = "section.${section.kind}.${section.unavailableKey()}") {
                        ActivityGroupLabel(section)
                    }
                    when (section) {
                        is ActivitySection.Session -> item(key = "session.intro") {
                            BodyLine(
                                text = section.intro,
                                tag = UiPageTags.ACTIVITY_INTRO,
                                tone = BodyTone.SECONDARY,
                                role = BodyRole.CAPTION,
                            )
                        }

                        is ActivitySection.Plan -> {
                            if (section.modeLabel != null) {
                                item(key = "plan.mode") {
                                    InfoRow(
                                        title = UiStrings.ACTIVITY_PLAN_MODE,
                                        value = section.modeLabel,
                                        modifier = Modifier.testTag(UiPageTags.ACTIVITY_PLAN_MODE),
                                    )
                                }
                                if (section.pending) {
                                    item(key = "plan.pending") {
                                        BodyLine(
                                            text = PENDING_GLYPH + " " + UiStrings.ACTIVITY_PLAN_PENDING,
                                            tag = UiPageTags.ACTIVITY_PLAN_PENDING,
                                            tone = BodyTone.PRIMARY,
                                        )
                                    }
                                }
                            } else {
                                item(key = "plan.none") {
                                    BodyLine(
                                        text = section.emptyLabel.orEmpty(),
                                        tag = UiPageTags.ACTIVITY_PLAN_NONE,
                                        tone = BodyTone.SECONDARY,
                                    )
                                }
                            }
                        }

                        is ActivitySection.Todos -> {
                            val rows = section.rows
                            if (rows == null) {
                                item(key = "todos.unknown") {
                                    UnknownRow(tag = UiPageTags.ACTIVITY_UNKNOWN_ROW_PREFIX + "todos")
                                }
                            } else if (rows.isEmpty()) {
                                item(key = "todos.empty") {
                                    BodyLine(
                                        text = section.emptyLabel.orEmpty(),
                                        tag = UiPageTags.ACTIVITY_TODOS_EMPTY,
                                        tone = BodyTone.SECONDARY,
                                    )
                                }
                            } else {
                                items(items = rows, key = { "todo.${it.id}" }) { row ->
                                    TodoRow(row)
                                    SessionHairline()
                                }
                            }
                        }

                        is ActivitySection.Goal -> {
                            val row = section.row
                            if (row == null) {
                                item(key = "goal.empty") {
                                    BodyLine(
                                        text = section.emptyLabel.orEmpty(),
                                        tag = UiPageTags.ACTIVITY_GOAL_NONE,
                                        tone = BodyTone.SECONDARY,
                                    )
                                }
                            } else {
                                item(key = "goal.objective") {
                                    BodyLine(
                                        text = row.objective,
                                        tag = UiPageTags.ACTIVITY_GOAL,
                                        tone = BodyTone.PRIMARY,
                                    )
                                }
                                item(key = "goal.phase") {
                                    InfoRow(
                                        title = UiStrings.ACTIVITY_GOAL_PHASE,
                                        value = row.phaseLabel,
                                        modifier = Modifier.testTag(UiPageTags.ACTIVITY_GOAL_PHASE),
                                    )
                                }
                                item(key = "goal.rounds") {
                                    InfoRow(
                                        title = UiStrings.ACTIVITY_GOAL_ROUNDS,
                                        value = row.roundsLabel,
                                        modifier = Modifier.testTag(UiPageTags.ACTIVITY_GOAL_ROUNDS),
                                    )
                                }
                                if (row.canPause) {
                                    item(key = "goal.pause") {
                                        SessionTextAction(
                                            label = UiStrings.ACTIVITY_GOAL_PAUSE,
                                            onClick = { onRequestGoal(ActivityGoalAction.PAUSE) },
                                            tone = SessionActionTone.ACCENT,
                                            modifier = Modifier.testTag(UiPageTags.ACTIVITY_GOAL_PAUSE),
                                        )
                                    }
                                } else if (row.canResume) {
                                    item(key = "goal.resume") {
                                        SessionTextAction(
                                            label = UiStrings.ACTIVITY_GOAL_RESUME,
                                            onClick = { onRequestGoal(ActivityGoalAction.RESUME) },
                                            tone = SessionActionTone.ACCENT,
                                            modifier = Modifier.testTag(UiPageTags.ACTIVITY_GOAL_RESUME),
                                        )
                                    }
                                }
                                if (row.canComplete) {
                                    item(key = "goal.complete") {
                                        SessionTextAction(
                                            label = UiStrings.ACTIVITY_GOAL_COMPLETE,
                                            onClick = { onRequestGoal(ActivityGoalAction.COMPLETE) },
                                            tone = SessionActionTone.DANGER,
                                            modifier = Modifier.testTag(UiPageTags.ACTIVITY_GOAL_COMPLETE),
                                        )
                                    }
                                }
                            }
                        }

                        is ActivitySection.Subagents -> {
                            val rows = section.rows
                            when {
                                rows == null -> item(key = "subagents.unknown") {
                                    UnknownRow(tag = UiPageTags.ACTIVITY_UNKNOWN_ROW_PREFIX + "subagents")
                                }
                                rows.isEmpty() -> item(key = "subagents.empty") {
                                    BodyLine(
                                        text = section.emptyLabel.orEmpty(),
                                        tag = UiPageTags.ACTIVITY_SUBAGENTS_EMPTY,
                                        tone = BodyTone.SECONDARY,
                                    )
                                }
                                else -> items(items = rows, key = { "subagent.${it.id}" }) { row ->
                                    DetailRow(
                                        title = row.title,
                                        detail = row.detail,
                                        tag = UiPageTags.ACTIVITY_SUBAGENT_ROW,
                                        trailing = null,
                                        action = if (row.canInterrupt) {
                                            {
                                                SessionTextAction(
                                                    label = UiStrings.ACTIVITY_SUBAGENT_INTERRUPT,
                                                    onClick = { onRequestInterruptSubagent(row.id) },
                                                    tone = SessionActionTone.DANGER,
                                                    modifier = Modifier.testTag(
                                                        UiPageTags.ACTIVITY_SUBAGENT_INTERRUPT,
                                                    ),
                                                )
                                            }
                                        } else {
                                            null
                                        },
                                    )
                                }
                            }
                        }

                        is ActivitySection.Schedules -> {
                            val rows = section.rows
                            when {
                                rows == null -> item(key = "schedules.unknown") {
                                    UnknownRow(tag = UiPageTags.ACTIVITY_UNKNOWN_ROW_PREFIX + "schedules")
                                }
                                rows.isEmpty() -> item(key = "schedules.empty") {
                                    BodyLine(
                                        text = section.emptyLabel.orEmpty(),
                                        tag = UiPageTags.ACTIVITY_SCHEDULES_EMPTY,
                                        tone = BodyTone.SECONDARY,
                                    )
                                }
                                else -> items(items = rows, key = { "schedule.${it.id}" }) { row ->
                                    DetailRow(
                                        title = row.title,
                                        detail = row.detail,
                                        tag = UiPageTags.ACTIVITY_SCHEDULE_ROW,
                                        trailing = row.statusLabel,
                                        action = {
                                            SessionTextAction(
                                                label = UiStrings.ACTIVITY_SCHEDULE_DELETE,
                                                onClick = { onRequestDeleteSchedule(row.id) },
                                                tone = SessionActionTone.DANGER,
                                                modifier = Modifier.testTag(
                                                    UiPageTags.ACTIVITY_SCHEDULE_DELETE,
                                                ),
                                            )
                                        },
                                    )
                                }
                            }
                        }

                        is ActivitySection.Jobs -> {
                            val rows = section.rows
                            when {
                                rows == null -> item(key = "jobs.unknown") {
                                    UnknownRow(tag = UiPageTags.ACTIVITY_UNKNOWN_ROW_PREFIX + "jobs")
                                }
                                rows.isEmpty() -> item(key = "jobs.empty") {
                                    BodyLine(
                                        text = section.emptyLabel.orEmpty(),
                                        tag = UiPageTags.ACTIVITY_JOBS_EMPTY,
                                        tone = BodyTone.SECONDARY,
                                    )
                                }
                                else -> items(items = rows, key = { "job.${it.id}" }) { row ->
                                    DetailRow(
                                        title = row.title,
                                        detail = row.detail,
                                        tag = UiPageTags.ACTIVITY_JOB_ROW,
                                        trailing = row.statusLabel,
                                        action = if (row.canStop) {
                                            {
                                                SessionTextAction(
                                                    label = UiStrings.ACTIVITY_JOB_STOP,
                                                    onClick = { onRequestStopJob(row.id) },
                                                    tone = SessionActionTone.DANGER,
                                                    modifier = Modifier.testTag(UiPageTags.ACTIVITY_JOB_STOP),
                                                )
                                            }
                                        } else {
                                            null
                                        },
                                    )
                                }
                            }
                        }

                        is ActivitySection.Skills -> {
                            val rows = section.rows
                            when {
                                rows == null -> item(key = "skills.unknown") {
                                    UnknownRow(tag = UiPageTags.ACTIVITY_UNKNOWN_ROW_PREFIX + "skills")
                                }
                                rows.isEmpty() -> item(key = "skills.empty") {
                                    BodyLine(
                                        text = section.emptyLabel.orEmpty(),
                                        tag = UiPageTags.ACTIVITY_SKILLS_EMPTY,
                                        tone = BodyTone.SECONDARY,
                                    )
                                }
                                else -> items(items = rows, key = { "skill.${it.id}" }) { row ->
                                    DetailRow(
                                        title = row.title,
                                        detail = row.detail,
                                        tag = UiPageTags.ACTIVITY_SKILL_ROW,
                                        trailing = row.statusLabel,
                                        action = null,
                                    )
                                }
                            }
                        }

                        is ActivitySection.Unavailable -> {
                            val row = section.row
                            item(key = "error.${row.key}") {
                                DisclosureRow(
                                    title = row.title,
                                    expanded = row.expanded,
                                    detail = row.detail,
                                    tag = UiPageTags.ACTIVITY_ERROR_ROW_PREFIX + row.key,
                                    onToggle = { onToggleError(row.key) },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/** One todo row (`:37`–`:43`): glyph, title, spacer, status label. */
@Composable
private fun TodoRow(row: TodoRowView) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.ACTIVITY_TODO_ROW)
            // Page-level geometry: a todo row is a compact list row.
            .defaultMinSize(minHeight = tokens.geometry.pageListRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = row.icon,
            style = type.body.copy(
                color = if (row.completed) tokens.colors.success else tokens.colors.secondary,
            ),
        )
        BasicText(
            text = row.title,
            style = type.body.copy(color = tokens.colors.primary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = row.label,
            style = type.caption.copy(color = tokens.colors.secondary),
        )
    }
}

/**
 * A sub-agent / schedule / job / skill row.
 *
 * The baseline's four rows share one shape — a medium title, a caption detail and
 * one optional action — so they share one composable; what differs is only which
 * action the caller passes.
 */
@Composable
private fun DetailRow(
    title: String,
    detail: String,
    tag: String,
    trailing: String?,
    action: (@Composable () -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = title,
                // `SessionActivityPage.swift:73`, `:90`, `:108`, `:128`: the four
                // detail rows share `.font(.body.weight(.medium))`.
                style = type.body.copy(
                    color = tokens.colors.primary,
                    fontWeight = FontWeight.Medium,
                ),
                modifier = Modifier.weight(1f),
            )
            if (trailing != null) {
                BasicText(
                    text = trailing,
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
            }
        }
        // `SessionActivityPage.swift:74`, `:94`, `:112`, `:135`: every detail line is
        // `.textSelection(.enabled)`.
        SelectionContainer {
            BasicText(
                text = detail,
                style = type.caption.copy(color = tokens.colors.secondary),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        action?.invoke()
    }
}

/** The type role of a one-line body row: the baseline uses `.body` for eight of them. */
private enum class BodyRole { BODY, CAPTION }

/** A one-line body row: the baseline's `Text(...)` inside a section. */
@Composable
private fun BodyLine(
    text: String,
    tag: String,
    tone: BodyTone,
    role: BodyRole = BodyRole.BODY,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val ink = when (tone) {
        BodyTone.PRIMARY -> tokens.colors.primary
        BodyTone.SECONDARY -> tokens.colors.secondary
    }
    val base = when (role) {
        BodyRole.BODY -> type.body
        // `Text("查看此会话的计划、待办、目标和后台活动。").font(.caption)`
        // (`SessionActivityPage.swift:17`).
        BodyRole.CAPTION -> type.caption
    }
    BasicText(
        text = text,
        style = base.copy(color = ink),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** The row a not-reported list shows: 未知, never the empty sentence. */
@Composable
private fun UnknownRow(tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = UiStrings.UNKNOWN,
        style = type.body.copy(color = tokens.colors.tertiary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** One 暂不可用 disclosure (`:143`–`:145`): a title that expands into the red detail. */
@Composable
private fun DisclosureRow(
    title: String,
    expanded: Boolean,
    detail: String,
    tag: String,
    onToggle: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .testTag(tag)
                // Page-level geometry: the disclosure's title is a page row.
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .clickable(role = Role.Button, onClick = onToggle)
                .semantics(mergeDescendants = true) {
                    contentDescription = title
                }
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = if (expanded) EXPANDED_GLYPH else COLLAPSED_GLYPH,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
            BasicText(
                text = title,
                style = type.body.copy(color = tokens.colors.primary),
                modifier = Modifier.weight(1f),
            )
        }
        if (expanded) {
            BasicText(
                text = detail,
                // `SessionActivityPage.swift:144`: `.font(.footnote)` (13 pt) red.
                style = type.secondary.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        horizontal = tokens.geometry.pageOuterMarginH,
                        vertical = tokens.spacing.badgeInsetV,
                    ),
            )
        }
    }
}

/**
 * The baseline's `.confirmationDialog` (`SessionActivityPage.swift:158`–`:189`).
 *
 * Compose's standard [AlertDialog] is the same control class — a modal with a
 * title, an optional message, one confirm action and 取消 — so the interaction
 * matches the baseline instead of being re-invented as an inline panel. The four
 * dialogs differ only in their copy and in whether the confirm action is
 * destructive (标记完成 / 删除计划任务 / 停止作业 / 中断).
 */
@Composable
private fun ConfirmDialog(
    confirm: ActivityConfirm,
    title: String,
    message: String?,
    destructive: Boolean,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val tone = if (destructive) SessionActionTone.DANGER else SessionActionTone.ACCENT
    val messageSlot: (@Composable () -> Unit)? = if (message != null) {
        {
            BasicText(
                text = message,
                style = type.secondary.copy(color = tokens.colors.secondary),
                modifier = Modifier.testTag(UiPageTags.ACTIVITY_CONFIRM_MESSAGE),
            )
        }
    } else {
        null
    }
    AlertDialog(
        onDismissRequest = onCancel,
        modifier = Modifier.testTag(UiPageTags.ACTIVITY_CONFIRM),
        title = {
            BasicText(
                text = title,
                style = type.headline.copy(color = tokens.colors.primary),
            )
        },
        text = messageSlot,
        // Each dialog names its own verb: the baseline's goal dialog takes its verb
        // from the pending action (`:201`–`:208`), so the three goal verbs are the
        // page's own three rows rather than a value the dialog receives.
        confirmButton = {
            when (confirm) {
                is ActivityConfirm.Goal -> when (confirm.action) {
                    // KNOWN GAP (L82): `SessionActivityPage.swift:201`–`208` gives the
                    // dialog the short verbs 暂停 / 恢复 / 标记完成, while the section
                    // rows above say 暂停目标 / 恢复目标. The page can only render one
                    // label per control, and `spec/ui/v1/pages/session-activity.json`
                    // declares the confirmation action at `:160` with a *dynamic*
                    // label (`Button(goalActionLabel, …)`) and no alternatives, so
                    // 暂停 / 恢复 are reported by `page_structure_check` as
                    // `extra-action` and the gate turns red. The dialog therefore keeps
                    // the row verbs
                    // (`ACTIVITY_CONFIRM_GOAL_*_ACTION` holds the baseline's short
                    // wording, unused, for the lane that can widen the contract).
                    ActivityGoalAction.PAUSE -> SessionTextAction(
                        label = UiStrings.ACTIVITY_GOAL_PAUSE,
                        onClick = onConfirm,
                        tone = tone,
                        modifier = Modifier.testTag(UiPageTags.ACTIVITY_CONFIRM_ACTION),
                    )

                    ActivityGoalAction.RESUME -> SessionTextAction(
                        label = UiStrings.ACTIVITY_GOAL_RESUME,
                        onClick = onConfirm,
                        tone = tone,
                        modifier = Modifier.testTag(UiPageTags.ACTIVITY_CONFIRM_ACTION),
                    )

                    ActivityGoalAction.COMPLETE -> SessionTextAction(
                        label = UiStrings.ACTIVITY_CONFIRM_GOAL_COMPLETE_ACTION,
                        onClick = onConfirm,
                        tone = tone,
                        modifier = Modifier.testTag(UiPageTags.ACTIVITY_CONFIRM_ACTION),
                    )
                }

                is ActivityConfirm.DeleteSchedule -> SessionTextAction(
                    label = UiStrings.ACTIVITY_SCHEDULE_DELETE,
                    onClick = onConfirm,
                    tone = tone,
                    modifier = Modifier.testTag(UiPageTags.ACTIVITY_CONFIRM_ACTION),
                )

                is ActivityConfirm.StopJob -> SessionTextAction(
                    label = UiStrings.ACTIVITY_CONFIRM_JOB_ACTION,
                    onClick = onConfirm,
                    tone = tone,
                    modifier = Modifier.testTag(UiPageTags.ACTIVITY_CONFIRM_ACTION),
                )

                is ActivityConfirm.InterruptSubagent -> SessionTextAction(
                    label = UiStrings.ACTIVITY_CONFIRM_SUBAGENT_ACTION,
                    onClick = onConfirm,
                    tone = tone,
                    modifier = Modifier.testTag(UiPageTags.ACTIVITY_CONFIRM_ACTION),
                )
            }
        },
        dismissButton = {
            SessionTextAction(
                label = UiStrings.CANCEL,
                onClick = onCancel,
                tone = SessionActionTone.SECONDARY,
                modifier = Modifier.testTag(UiPageTags.ACTIVITY_CONFIRM_CANCEL),
            )
        },
        shape = RoundedCornerShape(tokens.radius.card),
        containerColor = tokens.colors.input,
        titleContentColor = tokens.colors.primary,
        textContentColor = tokens.colors.secondary,
    )
}

/**
 * One group header: the kind's fixed title (`SessionActivityPage.swift:16`–`:148`).
 *
 * The nine titles are fixed copy in the baseline, so they are spelled here. The
 * page used to render `section.kind.title` — the same nine strings, but reached
 * through the kind, which meant the words were not visible where the group is
 * drawn. `SessionActivityPageTest` asserts this table, in this order, against
 * `ActivitySectionKind.title`, so the copy still has one source of truth.
 */
@Composable
private fun ActivityGroupLabel(section: ActivitySection) {
    val modifier = Modifier
        .testTag(section.sectionTag())
        .sectionSemantics(section)
    when (section.kind) {
        ActivitySectionKind.SESSION -> SessionSectionLabel(
            text = UiStrings.ACTIVITY_SESSION_TITLE,
            modifier = modifier,
        )

        ActivitySectionKind.PLAN -> SessionSectionLabel(
            text = UiStrings.ACTIVITY_PLAN_TITLE,
            modifier = modifier,
        )

        ActivitySectionKind.TODOS -> SessionSectionLabel(
            text = UiStrings.ACTIVITY_TODOS_TITLE,
            modifier = modifier,
        )

        ActivitySectionKind.GOAL -> SessionSectionLabel(
            text = UiStrings.ACTIVITY_GOAL_TITLE,
            modifier = modifier,
        )

        ActivitySectionKind.SUBAGENTS -> SessionSectionLabel(
            text = UiStrings.ACTIVITY_SUBAGENTS_TITLE,
            modifier = modifier,
        )

        ActivitySectionKind.SCHEDULES -> SessionSectionLabel(
            text = UiStrings.ACTIVITY_SCHEDULES_TITLE,
            modifier = modifier,
        )

        ActivitySectionKind.JOBS -> SessionSectionLabel(
            text = UiStrings.ACTIVITY_JOBS_TITLE,
            modifier = modifier,
        )

        ActivitySectionKind.SKILLS -> SessionSectionLabel(
            text = UiStrings.ACTIVITY_SKILLS_TITLE,
            modifier = modifier,
        )

        ActivitySectionKind.UNAVAILABLE -> SessionSectionLabel(
            text = UiStrings.ACTIVITY_ERRORS_TITLE,
            modifier = modifier,
        )
    }
}

/** The ink of a one-line body row. */
private enum class BodyTone { PRIMARY, SECONDARY }

/** The tag of one section's header; a failure section keys on its own name. */
private fun ActivitySection.sectionTag(): String = when (this) {
    is ActivitySection.Session -> UiPageTags.ACTIVITY_SESSION_SECTION
    is ActivitySection.Plan -> UiPageTags.ACTIVITY_PLAN
    is ActivitySection.Todos -> UiPageTags.ACTIVITY_TODOS
    is ActivitySection.Goal -> UiPageTags.ACTIVITY_GOAL
    is ActivitySection.Subagents -> UiPageTags.ACTIVITY_SUBAGENTS
    is ActivitySection.Schedules -> UiPageTags.ACTIVITY_SCHEDULES
    is ActivitySection.Jobs -> UiPageTags.ACTIVITY_JOBS
    is ActivitySection.Skills -> UiPageTags.ACTIVITY_SKILLS
    is ActivitySection.Unavailable -> UiPageTags.ACTIVITY_ERROR_SECTION_PREFIX + row.key
}

/** The section label's a11y description: the section title, plus a heading mark. */
private fun Modifier.sectionSemantics(section: ActivitySection): Modifier =
    semantics { contentDescription = section.kind.title; heading() }

/** The disclosure key of a section; empty for the fixed eight. */
private fun ActivitySection.unavailableKey(): String =
    if (this is ActivitySection.Unavailable) row.key else ""

private const val DONE_GLYPH: String = "✓"
private const val RUNNING_GLYPH: String = "◐"
private const val TODO_GLYPH: String = "○"
private const val PENDING_GLYPH: String = "◷"
private const val EXPANDED_GLYPH: String = "⌄"
private const val COLLAPSED_GLYPH: String = "›"

/**
 * The token inventory of this page; `PageTokenReferenceTest` fails when a use
 * site reads a token that is not listed here.
 */
internal object SessionActivityPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_INPUT,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_PAGE_LIST_ROW_MIN_HEIGHT,
    )
}
