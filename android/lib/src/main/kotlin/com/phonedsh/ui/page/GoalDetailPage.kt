// The goal bar and the goal detail sheet.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §3 "目标" rows (a goal is read through the goal API,
// not a harness event; `active` shows 暂停, `paused`/`blocked` show 继续; 清除 is the
// `/goal clear` path; a failed read is *fail-quiet* and keeps the previous goal) and
// §1 `GoalDetailPage` (单个目标的 objective / 状态 / 动作; entry: ChatPage 的目标条;
// sheet; 打开失败保留上一个目标 fail-quiet; P5 `later`). This lane delivers the bar,
// the sheet body and the state machine; the host owns the sheet presentation.
//
// Host contract: `spec/host/v1/schema/harness-goal.schema.json` — objective, phase
// (`active|paused|blocked|complete`), `rounds_started` / `max_goal_rounds`, and
// `blocked_reason` exactly when blocked. Nothing here invents a goal: a session
// without one renders the empty state, and a failed re-read keeps the last one.
//
// `GoalDetailScreenState.from` is a pure function of the host projection and the
// read flags, so a JVM test replays the same bar/detail sequence.
//
// Geometry: every horizontal length here is the page-level
// `geometry.pageOuterMarginH`; the bar, the notices, the objective and the action
// row all align to the page margin. Nothing here reuses signature-surface geometry,
// so no `unverified geometry` marker remains.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.phonedsh.agentcore.HarnessGoal
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.state.GoalBarState
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/** Whether the goal has been read, is still waiting, or the last read failed. */
public enum class GoalStatus { WAITING, READY, FAILED }

/** The three actions §3 gives the goal surface. */
public enum class GoalAction { PAUSE, RESUME, CLEAR }

/** One action with its copy resolved. */
public data class GoalActionView(
    public val action: GoalAction,
    public val label: String,
)

/**
 * The goal detail state.
 *
 * A visible goal always keeps `status = READY`: §3 says a failed re-read is
 * fail-quiet, so [statusLine] carries the notice and the previous goal stays on
 * screen. [status] is only `FAILED` when there is no previous goal to keep.
 *
 * @param roundsLabel "started / max 轮", both host counts and nothing derived.
 * @param blockedReason the host's reason; non-null exactly for a blocked goal.
 * @param actions the actions the current phase allows (never a disabled guess).
 */
public data class GoalDetailScreenState(
    public val status: GoalStatus,
    public val failure: String?,
    public val statusLine: String?,
    public val objective: String?,
    public val phaseLabel: String?,
    public val roundsLabel: String?,
    public val blockedReason: String?,
    public val actions: List<GoalActionView>,
) {
    public val hasGoal: Boolean get() = objective != null
    public val waiting: Boolean get() = status == GoalStatus.WAITING

    public companion object {
        /**
         * Projects the host goal projection into the detail state.
         *
         * Pure: the same `(goal, waiting, failure)` always yields the same rows,
         * actions and notice.
         *
         * @param goal the host projection, or `null` when the session has no goal.
         * @param waiting true before the first successful read.
         * @param failure non-null when the last read failed.
         */
        public fun from(
            goal: HarnessGoal?,
            waiting: Boolean = false,
            failure: String? = null,
        ): GoalDetailScreenState {
            if (goal == null) {
                val status = when {
                    failure != null -> GoalStatus.FAILED
                    waiting -> GoalStatus.WAITING
                    else -> GoalStatus.READY
                }
                return GoalDetailScreenState(
                    status = status,
                    failure = failure.takeIf { status == GoalStatus.FAILED },
                    statusLine = null,
                    objective = null,
                    phaseLabel = null,
                    roundsLabel = null,
                    blockedReason = null,
                    actions = emptyList(),
                )
            }
            val actions = when (goal.phase) {
                HarnessGoal.Phase.ACTIVE -> listOf(
                    GoalActionView(GoalAction.PAUSE, UiStrings.GOAL_PAUSE),
                    GoalActionView(GoalAction.CLEAR, UiStrings.GOAL_CLEAR),
                )

                HarnessGoal.Phase.PAUSED,
                HarnessGoal.Phase.BLOCKED,
                -> listOf(
                    GoalActionView(GoalAction.RESUME, UiStrings.GOAL_RESUME),
                    GoalActionView(GoalAction.CLEAR, UiStrings.GOAL_CLEAR),
                )

                HarnessGoal.Phase.COMPLETE -> listOf(
                    GoalActionView(GoalAction.CLEAR, UiStrings.GOAL_CLEAR),
                )
            }
            return GoalDetailScreenState(
                status = GoalStatus.READY,
                failure = null,
                // Fail-quiet (§3): the old goal stays, the notice is one line.
                statusLine = if (failure != null) UiStrings.GOAL_READ_FAILED else null,
                objective = goal.objective,
                phaseLabel = goal.phase.label,
                roundsLabel = UiStrings.GOAL_ROUNDS.format(goal.roundsStarted, goal.maxGoalRounds),
                blockedReason = goal.blockedReason,
                actions = actions,
            )
        }
    }
}

/**
 * The goal bar above the composer: phase, one-line objective, pause/resume, clear.
 *
 * @param goal the bar state; [GoalBarState.Hidden] renders nothing.
 * @param onPause pause an active goal; `null` hides the action.
 * @param onResume resume a paused/blocked goal; `null` hides the action.
 * @param onClear clear the goal (`/goal clear` upstream); `null` hides the action.
 * @param onOpenDetail open the goal detail sheet; `null` hides the affordance.
 */
@Composable
public fun GoalBar(
    goal: GoalBarState,
    modifier: Modifier = Modifier,
    onPause: (() -> Unit)? = null,
    onResume: (() -> Unit)? = null,
    onClear: (() -> Unit)? = null,
    onOpenDetail: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val visible = goal as? GoalBarState.Visible ?: return
    val paused = visible.phase == PAUSED || visible.phase == BLOCKED
    Row(
        modifier = modifier
            .fillMaxWidth()
            .testTag(UiTags.GOAL_BAR)
            .padding(horizontal = tokens.geometry.pageOuterMarginH)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = visible.phase,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
        BasicText(
            text = visible.objective,
            style = type.secondary.copy(color = tokens.colors.secondary),
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        val toggleLabel = if (paused) UiStrings.GOAL_RESUME else UiStrings.GOAL_PAUSE
        val toggle = if (paused) onResume else onPause
        if (toggle != null) {
            SessionTextAction(
                label = toggleLabel,
                onClick = toggle,
                tone = SessionActionTone.ACCENT,
            )
        }
        if (onClear != null) {
            SessionTextAction(
                label = UiStrings.GOAL_CLEAR,
                onClick = onClear,
                tone = SessionActionTone.TERTIARY,
            )
        }
        if (onOpenDetail != null) {
            BasicText(
                text = DETAIL_GLYPH,
                style = type.caption.copy(color = tokens.colors.tertiary),
                modifier = Modifier
                    .testTag(UiPageTags.GOAL_BAR_DETAIL)
                    .clickable(role = Role.Button, onClick = onOpenDetail)
                    .semantics { contentDescription = UiStrings.GOAL_DETAIL }
                    .padding(tokens.spacing.iconText),
            )
        }
    }
}

/**
 * The goal detail sheet.
 *
 * @param state the pure screen state ([GoalDetailScreenState.from]).
 * @param onPause pause the goal.
 * @param onResume resume the goal.
 * @param onClear clear the goal.
 * @param onRetry retry a failed read.
 * @param onDismissFailure dismiss the failure line.
 * @param onBack leave the sheet.
 */
@Composable
public fun GoalDetailPage(
    state: GoalDetailScreenState,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
    onBack: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    PageFrame(
        title = UiStrings.GOAL_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.GOAL_ROOT,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            if (state.failure != null) {
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.GOAL_FAILURE,
                    retryLabel = UiStrings.RETRY,
                    onRetry = onRetry,
                    onDismiss = onDismissFailure,
                )
            }
            if (state.statusLine != null) {
                // Fail-quiet: the previous goal stays readable, the notice is one line.
                BasicText(
                    text = state.statusLine,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                    modifier = Modifier.padding(horizontal = tokens.geometry.pageOuterMarginH),
                )
            }
            when {
                state.waiting -> EmptyHint(
                    title = UiStrings.WAITING_ENGINE,
                    hint = null,
                    tag = UiPageTags.GOAL_EMPTY,
                )

                // A failed first read is the failure line, not "this session has no goal":
                // the page does not know whether a goal exists.
                state.status == GoalStatus.FAILED -> Unit

                !state.hasGoal -> EmptyHint(
                    title = UiStrings.GOAL_EMPTY,
                    hint = null,
                    tag = UiPageTags.GOAL_EMPTY,
                )

                else -> Column(modifier = Modifier.fillMaxWidth()) {
                    BasicText(
                        text = state.objective.orEmpty(),
                        style = type.body.copy(color = tokens.colors.primary),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(UiPageTags.GOAL_OBJECTIVE)
                            .padding(
                                horizontal = tokens.geometry.pageOuterMarginH,
                                vertical = tokens.spacing.iconText,
                            ),
                    )
                    InfoRow(
                        title = UiStrings.GOAL_TITLE,
                        value = state.phaseLabel,
                        modifier = Modifier.testTag(UiPageTags.GOAL_PHASE),
                    )
                    InfoRow(
                        title = UiStrings.ACTIVITY_ROUNDS,
                        value = state.roundsLabel,
                        modifier = Modifier.testTag(UiPageTags.GOAL_ROUNDS),
                    )
                    if (state.blockedReason != null) {
                        InfoRow(
                            title = UiStrings.GOAL_BLOCKED_REASON,
                            value = state.blockedReason,
                            tone = PageTone.DEGRADED,
                            modifier = Modifier.testTag(UiPageTags.GOAL_REASON),
                        )
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = tokens.geometry.pageOuterMarginH),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                    ) {
                        state.actions.forEach { action ->
                            SessionTextAction(
                                label = action.label,
                                onClick = when (action.action) {
                                    GoalAction.PAUSE -> onPause
                                    GoalAction.RESUME -> onResume
                                    GoalAction.CLEAR -> onClear
                                },
                                tone = when (action.action) {
                                    GoalAction.CLEAR -> SessionActionTone.SECONDARY
                                    else -> SessionActionTone.ACCENT
                                },
                                modifier = Modifier.testTag(
                                    when (action.action) {
                                        GoalAction.PAUSE -> UiPageTags.GOAL_PAUSE
                                        GoalAction.RESUME -> UiPageTags.GOAL_RESUME
                                        GoalAction.CLEAR -> UiPageTags.GOAL_CLEAR
                                    },
                                ),
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * The token inventory of this file; `PageTokenReferenceTest` fails when a use site
 * reads a token that is not listed here.
 */
internal object GoalDetailTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
    )
}

/** `harness-goal.schema.json` phase values the bar compares against. */
private const val PAUSED: String = "paused"
private const val BLOCKED: String = "blocked"

/** The detail affordance on the bar. */
private const val DETAIL_GLYPH: String = "›"

/** The phase label; never the wire value. */
private val HarnessGoal.Phase.label: String
    get() = when (this) {
        HarnessGoal.Phase.ACTIVE -> UiStrings.GOAL_ACTIVE
        HarnessGoal.Phase.PAUSED -> UiStrings.GOAL_PAUSED
        HarnessGoal.Phase.BLOCKED -> UiStrings.GOAL_BLOCKED
        HarnessGoal.Phase.COMPLETE -> UiStrings.GOAL_COMPLETE
    }
