// Session activity: the eight fixed sections, their rows and their script.
// SPDX-License-Identifier: MIT
//
// The mirror source is `SessionActivityPage.swift`; the assertions below are the
// section sequence, the rows, the conditions and the strings that file renders.
// The page is not one of the six signature surfaces, so nothing here compares a
// screenshot or a font metric.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.filterToOne
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.disclosure.DisclosureKind
import com.phonedsh.ui.disclosure.DisclosureMotion
import com.phonedsh.ui.disclosure.PdshDisclosureTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class SessionActivityPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val source = SessionActivitySource(
        plan = ActivityPlan(active = true, pending = false),
        todos = listOf(
            ActivityTodo(id = "t1", title = "写测试", status = "completed"),
            ActivityTodo(id = "t2", title = "跑测试", status = "in_progress"),
            ActivityTodo(id = "t3", title = "发版", status = null),
        ),
        goal = ActivityGoal(
            objective = "把 Android 适配做完",
            phase = "active",
            roundsStarted = 2,
            maxGoalRounds = 5,
        ),
        subagents = listOf(
            ActivitySubagent(id = "s1", title = "读取仓库", detail = "3 个文件", status = "continuable"),
            ActivitySubagent(id = "s2", title = "已完成的子智能体", detail = "完成", status = "completed"),
        ),
        schedules = listOf(
            ActivitySchedule(id = "p1", title = "每日简报", detail = "每天 09:00", status = "active"),
        ),
        jobs = listOf(
            ActivityJob(id = "j1", title = "构建", detail = "exit 0", status = "running"),
            ActivityJob(id = "j2", title = "旧作业", detail = "exit 1", status = "failed"),
        ),
        skills = listOf(
            ActivitySkill(id = "k1", title = "图片处理", detail = "读写本地图片", status = "active"),
            ActivitySkill(id = "k2", title = "未知档位", detail = "说明", status = "beta"),
        ),
        errors = mapOf("逐字稿" to "读不到逐字稿", "计划" to "读不到计划"),
    )

    private fun show(
        state: SessionActivityScreenState,
        onRefresh: () -> Unit = {},
        onToggleError: (String) -> Unit = {},
        onConfirm: () -> Unit = {},
        onCancel: () -> Unit = {},
        onRequestGoal: (ActivityGoalAction) -> Unit = {},
        onRequestDeleteSchedule: (String) -> Unit = {},
        onRequestStopJob: (String) -> Unit = {},
        onRequestInterruptSubagent: (String) -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme {
                SessionActivityPage(
                    state = state,
                    onRefresh = onRefresh,
                    onToggleError = onToggleError,
                    onConfirm = onConfirm,
                    onCancel = onCancel,
                    onRequestGoal = onRequestGoal,
                    onRequestDeleteSchedule = onRequestDeleteSchedule,
                    onRequestStopJob = onRequestStopJob,
                    onRequestInterruptSubagent = onRequestInterruptSubagent,
                )
            }
        }
    }

    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.ACTIVITY_LIST).performScrollToNode(hasTestTag(tag))
    }

    // ----------------------------------------------------------------- state

    @Test
    fun `the eight baseline sections are always there, in the baseline's order`() {
        val empty = SessionActivityScreenState.from(SessionActivitySource())
        assertEquals(
            listOf(
                ActivitySectionKind.SESSION,
                ActivitySectionKind.PLAN,
                ActivitySectionKind.TODOS,
                ActivitySectionKind.GOAL,
                ActivitySectionKind.SUBAGENTS,
                ActivitySectionKind.SCHEDULES,
                ActivitySectionKind.JOBS,
                ActivitySectionKind.SKILLS,
            ),
            empty.kinds,
        )
        // Nothing was reported: 未知 rows, never the baseline's "there is none"
        // sentences, which would claim a measured empty list.
        val todos = empty.sections.filterIsInstance<ActivitySection.Todos>().single()
        assertNull(todos.rows)
        assertNull(todos.emptyLabel)
        val plan = empty.sections.filterIsInstance<ActivitySection.Plan>().single()
        assertNull(plan.modeLabel)
        assertEquals(UiStrings.ACTIVITY_PLAN_NONE, plan.emptyLabel)
        val goal = empty.sections.filterIsInstance<ActivitySection.Goal>().single()
        assertEquals(UiStrings.ACTIVITY_GOAL_NONE, goal.emptyLabel)
    }

    @Test
    fun `an empty reported list shows the baseline's empty sentence`() {
        val state = SessionActivityScreenState.from(
            SessionActivitySource(todos = emptyList(), subagents = emptyList()),
        )
        assertEquals(
            UiStrings.ACTIVITY_TODOS_EMPTY,
            state.sections.filterIsInstance<ActivitySection.Todos>().single().emptyLabel,
        )
        assertEquals(
            UiStrings.ACTIVITY_SUBAGENTS_EMPTY,
            state.sections.filterIsInstance<ActivitySection.Subagents>().single().emptyLabel,
        )
    }

    @Test
    fun `plan mode renders its mode, its pending row or the none sentence`() {
        val active = SessionActivityScreenState.from(
            SessionActivitySource(plan = ActivityPlan(active = true, pending = true)),
        ).sections.filterIsInstance<ActivitySection.Plan>().single()
        assertEquals(UiStrings.ACTIVITY_PLAN_ON, active.modeLabel)
        assertTrue(active.pending)
        val off = SessionActivityScreenState.from(
            SessionActivitySource(plan = ActivityPlan(active = false, pending = false)),
        ).sections.filterIsInstance<ActivitySection.Plan>().single()
        assertEquals(UiStrings.ACTIVITY_PLAN_OFF, off.modeLabel)
        assertFalse(off.pending)
    }

    @Test
    fun `todo rows carry the baseline's three labels and glyphs`() {
        val rows = SessionActivityScreenState.from(source)
            .sections.filterIsInstance<ActivitySection.Todos>().single().rows.orEmpty()
        assertEquals(listOf("写测试", "跑测试", "发版"), rows.map { it.title })
        assertEquals(
            listOf(UiStrings.ACTIVITY_TODO_DONE, UiStrings.ACTIVITY_TODO_RUNNING, UiStrings.ACTIVITY_TODO_PENDING),
            rows.map { it.label },
        )
        assertEquals(listOf("✓", "◐", "○"), rows.map { it.icon })
        assertEquals(listOf(true, false, false), rows.map { it.completed })
    }

    @Test
    fun `the goal row derives its phase, its rounds and its three buttons`() {
        val active = SessionActivityScreenState.from(source)
            .sections.filterIsInstance<ActivitySection.Goal>().single().row
        assertEquals("把 Android 适配做完", active?.objective)
        assertEquals(UiStrings.ACTIVITY_PHASE_ACTIVE, active?.phaseLabel)
        assertEquals("2 / 5", active?.roundsLabel)
        assertTrue(active?.canPause == true)
        assertFalse(active?.canResume == true)
        assertTrue(active?.canComplete == true)

        val paused = SessionActivityScreenState.from(
            SessionActivitySource(goal = ActivityGoal("o", "paused")),
        ).sections.filterIsInstance<ActivitySection.Goal>().single().row
        assertFalse(paused?.canPause == true)
        assertTrue(paused?.canResume == true)
        // Rounds unmeasured: 未知, not 0 / 0.
        assertEquals(UiStrings.UNKNOWN, paused?.roundsLabel)

        val complete = SessionActivityScreenState.from(
            SessionActivitySource(goal = ActivityGoal("o", "complete")),
        ).sections.filterIsInstance<ActivitySection.Goal>().single().row
        assertFalse(complete?.canComplete == true)
    }

    @Test
    fun `the button conditions compare the raw phase like the baseline`() {
        // The label translates case-insensitively, the buttons compare exactly.
        val row = SessionActivityScreenState.from(
            SessionActivitySource(goal = ActivityGoal("o", "Active")),
        ).sections.filterIsInstance<ActivitySection.Goal>().single().row
        assertEquals(UiStrings.ACTIVITY_PHASE_ACTIVE, row?.phaseLabel)
        assertFalse(row?.canPause == true)
    }

    @Test
    fun `sub-agent, schedule, job and skill rows keep their conditional actions`() {
        val state = SessionActivityScreenState.from(source)
        val subagents = state.sections.filterIsInstance<ActivitySection.Subagents>().single().rows.orEmpty()
        assertEquals(listOf(true, false), subagents.map { it.canInterrupt })
        val schedules = state.sections.filterIsInstance<ActivitySection.Schedules>().single().rows.orEmpty()
        assertEquals(UiStrings.ACTIVITY_STATUS_ACTIVE, schedules.single().statusLabel)
        val jobs = state.sections.filterIsInstance<ActivitySection.Jobs>().single().rows.orEmpty()
        assertEquals(listOf(true, false), jobs.map { it.canStop })
        assertEquals(
            listOf(UiStrings.ACTIVITY_STATUS_RUNNING, UiStrings.ACTIVITY_STATUS_FAILED),
            jobs.map { it.statusLabel },
        )
        val skills = state.sections.filterIsInstance<ActivitySection.Skills>().single().rows.orEmpty()
        // A recognised status is shown; an unrecognised one is not repeated raw.
        assertEquals(listOf(UiStrings.ACTIVITY_STATUS_ACTIVE, null), skills.map { it.statusLabel })
    }

    @Test
    fun `a translated status is title-cased only through the table`() {
        assertEquals(UiStrings.ACTIVITY_STATUS_UNKNOWN, statusLabel(null))
        assertEquals(UiStrings.ACTIVITY_STATUS_UNKNOWN, statusLabel("unknown"))
        assertEquals(UiStrings.ACTIVITY_STATUS_STOPPING, statusLabel("STOPPING"))
        assertEquals("beta", statusLabel("beta"))
        assertEquals(UiStrings.ACTIVITY_PHASE_FAILED, goalPhaseLabel("failed"))
        assertEquals("legacy", goalPhaseLabel("legacy"))
    }

    @Test
    fun `every failed read is a 暂不可用 section after the fixed eight, sorted by key`() {
        val state = SessionActivityScreenState.from(source)
        assertEquals(10, state.sections.size)
        val errors = state.sections.filterIsInstance<ActivitySection.Unavailable>()
        assertEquals(listOf("计划", "逐字稿"), errors.map { it.row.key })
        assertEquals(UiStrings.ACTIVITY_ERRORS_DETAIL.format("计划"), errors.first().row.title)
        assertFalse(errors.first().row.expanded)
        assertEquals(ActivitySectionKind.UNAVAILABLE, errors.first().kind)
    }

    @Test
    fun `the confirmation script names the right dialog for each action`() {
        var local = SessionActivityLocalState()
        local = local.apply(SessionActivityUiEvent.RequestGoal(ActivityGoalAction.PAUSE))
        var state = SessionActivityScreenState.from(source, local)
        assertEquals(UiStrings.ACTIVITY_CONFIRM_GOAL_PAUSE, state.confirmTitle)
        assertEquals(UiStrings.ACTIVITY_CONFIRM_GOAL_MESSAGE, state.confirmMessage)
        assertFalse(state.confirmDestructive)

        local = local.apply(SessionActivityUiEvent.Cancel)
        assertNull(SessionActivityScreenState.from(source, local).confirm)

        local = local.apply(SessionActivityUiEvent.RequestGoal(ActivityGoalAction.COMPLETE))
        state = SessionActivityScreenState.from(source, local)
        assertEquals(UiStrings.ACTIVITY_CONFIRM_GOAL_COMPLETE, state.confirmTitle)
        assertTrue(state.confirmDestructive)

        local = local.apply(SessionActivityUiEvent.Confirmed)
        state = SessionActivityScreenState.from(source, local)
        assertNull(state.confirm)

        local = local.apply(SessionActivityUiEvent.RequestDeleteSchedule("p1"))
        assertEquals(UiStrings.ACTIVITY_CONFIRM_SCHEDULE, SessionActivityScreenState.from(source, local).confirmTitle)
        local = local.apply(SessionActivityUiEvent.Cancel)
        local = local.apply(SessionActivityUiEvent.RequestStopJob("j1"))
        assertEquals(UiStrings.ACTIVITY_CONFIRM_JOB, SessionActivityScreenState.from(source, local).confirmTitle)
        local = local.apply(SessionActivityUiEvent.Cancel)
        local = local.apply(SessionActivityUiEvent.RequestInterruptSubagent("s1"))
        assertEquals(
            UiStrings.ACTIVITY_CONFIRM_SUBAGENT,
            SessionActivityScreenState.from(source, local).confirmTitle,
        )
    }

    @Test
    fun `the same snapshot and script always yield the same sections`() {
        val script = listOf(
            SessionActivityUiEvent.RequestGoal(ActivityGoalAction.PAUSE),
            SessionActivityUiEvent.Cancel,
            SessionActivityUiEvent.ToggleError("计划"),
        )
        fun run(): List<SessionActivityScreenState> {
            var local = SessionActivityLocalState()
            val out = mutableListOf(SessionActivityScreenState.from(source, local))
            script.forEach { event ->
                local = local.apply(event)
                out += SessionActivityScreenState.from(source, local)
            }
            return out
        }
        assertEquals(run(), run())
        assertEquals(listOf(false, true, false, false), run().map { it.confirm != null })
        assertEquals(
            listOf(false, false, false, true),
            run().map { state ->
                state.sections.filterIsInstance<ActivitySection.Unavailable>()
                    .first { it.row.key == "计划" }.row.expanded
            },
        )
    }

    // ------------------------------------------------------------------ page

    @Test
    fun `the page renders the fixed section titles`() {
        show(SessionActivityScreenState.from(source))
        compose.onNodeWithTag(UiPageTags.ACTIVITY_SESSION_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ACTIVITY_SESSION_INTRO).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_PLAN).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_TODOS).assertIsDisplayed()
        compose.onAllNodesWithTag(UiPageTags.ACTIVITY_TODO_ROW).assertCountEquals(3)
        compose.onNodeWithText("写测试").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ACTIVITY_TODO_DONE).assertIsDisplayed()
    }

    @Test
    fun `the nine group titles are the kind titles, in the baseline's order`() {
        // The page spells the nine titles as literals so the contract can read them
        // where the groups are drawn; this pins the copy to the one table the rest of
        // the page still uses (`ActivitySectionKind.title`), in the same order.
        assertEquals(
            listOf(
                UiStrings.ACTIVITY_SESSION_TITLE,
                UiStrings.ACTIVITY_PLAN_TITLE,
                UiStrings.ACTIVITY_TODOS_TITLE,
                UiStrings.ACTIVITY_GOAL_TITLE,
                UiStrings.ACTIVITY_SUBAGENTS_TITLE,
                UiStrings.ACTIVITY_SCHEDULES_TITLE,
                UiStrings.ACTIVITY_JOBS_TITLE,
                UiStrings.ACTIVITY_SKILLS_TITLE,
                UiStrings.ACTIVITY_ERRORS_TITLE,
            ),
            ActivitySectionKind.entries.map { it.title },
        )
    }

    @Test
    fun `every group header draws its title at the group`() {
        show(SessionActivityScreenState.from(source))
        val headers = listOf(
            UiPageTags.ACTIVITY_SESSION_SECTION to UiStrings.ACTIVITY_SESSION_TITLE,
            UiPageTags.ACTIVITY_PLAN to UiStrings.ACTIVITY_PLAN_TITLE,
            UiPageTags.ACTIVITY_TODOS to UiStrings.ACTIVITY_TODOS_TITLE,
            UiPageTags.ACTIVITY_GOAL to UiStrings.ACTIVITY_GOAL_TITLE,
            UiPageTags.ACTIVITY_SUBAGENTS to UiStrings.ACTIVITY_SUBAGENTS_TITLE,
            UiPageTags.ACTIVITY_SCHEDULES to UiStrings.ACTIVITY_SCHEDULES_TITLE,
            UiPageTags.ACTIVITY_JOBS to UiStrings.ACTIVITY_JOBS_TITLE,
            UiPageTags.ACTIVITY_SKILLS to UiStrings.ACTIVITY_SKILLS_TITLE,
            UiPageTags.ACTIVITY_ERROR_SECTION_PREFIX + "计划" to UiStrings.ACTIVITY_ERRORS_TITLE,
        )
        headers.forEach { (tag, title) ->
            scrollTo(tag)
            // `ACTIVITY_GOAL` tags the header and the objective row (a pre-existing
            // collision), so the assertion picks the node that carries the title.
            compose.onAllNodesWithTag(tag).filterToOne(hasText(title)).assertIsDisplayed()
        }
    }

    @Test
    fun `the plan section shows 已启用 and the pending line`() {
        show(
            SessionActivityScreenState.from(
                SessionActivitySource(plan = ActivityPlan(active = true, pending = true)),
            ),
        )
        scrollTo(UiPageTags.ACTIVITY_PLAN_MODE)
        compose.onNodeWithTag(UiPageTags.ACTIVITY_PLAN_MODE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ACTIVITY_PLAN_ON).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_PLAN_PENDING).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ACTIVITY_PLAN_PENDING, substring = true).assertIsDisplayed()
    }

    @Test
    fun `no plan mode shows the baseline's sentence, not an empty value`() {
        show(SessionActivityScreenState.from(SessionActivitySource()))
        scrollTo(UiPageTags.ACTIVITY_PLAN_NONE)
        compose.onNodeWithTag(UiPageTags.ACTIVITY_PLAN_NONE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ACTIVITY_PLAN_NONE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_PLAN_MODE).assertDoesNotExist()
    }

    @Test
    fun `an unreported list is a 未知 row, not the empty sentence`() {
        show(SessionActivityScreenState.from(SessionActivitySource()))
        scrollTo(UiPageTags.ACTIVITY_UNKNOWN_ROW_PREFIX + "todos")
        compose.onNodeWithTag(UiPageTags.ACTIVITY_UNKNOWN_ROW_PREFIX + "todos").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_TODOS_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `an empty todo list shows the baseline's empty sentence`() {
        show(SessionActivityScreenState.from(SessionActivitySource(todos = emptyList())))
        scrollTo(UiPageTags.ACTIVITY_TODOS_EMPTY)
        compose.onNodeWithText(UiStrings.ACTIVITY_TODOS_EMPTY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_UNKNOWN_ROW_PREFIX + "todos").assertDoesNotExist()
    }

    @Test
    fun `the goal section shows its objective, phase and rounds and reports the pause`() {
        var requested: ActivityGoalAction? = null
        show(SessionActivityScreenState.from(source), onRequestGoal = { requested = it })
        scrollTo(UiPageTags.ACTIVITY_GOAL)
        compose.onNodeWithText("把 Android 适配做完").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL_PHASE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL_ROUNDS).assertIsDisplayed()
        compose.onNodeWithText("2 / 5").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL_PAUSE).performClick()
        assertEquals(ActivityGoalAction.PAUSE, requested)
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL_RESUME).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL_COMPLETE).assertIsDisplayed()
    }

    @Test
    fun `a paused goal offers 恢复目标 instead of 暂停目标`() {
        show(
            SessionActivityScreenState.from(
                SessionActivitySource(goal = ActivityGoal("o", "paused")),
            ),
        )
        scrollTo(UiPageTags.ACTIVITY_GOAL_RESUME)
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL_RESUME).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL_PAUSE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL_COMPLETE).assertIsDisplayed()
    }

    @Test
    fun `a completed goal offers no 标记完成`() {
        show(
            SessionActivityScreenState.from(
                SessionActivitySource(goal = ActivityGoal("o", "complete")),
            ),
        )
        scrollTo(UiPageTags.ACTIVITY_GOAL_PHASE)
        compose.onNodeWithTag(UiPageTags.ACTIVITY_GOAL_COMPLETE).assertDoesNotExist()
    }

    @Test
    fun `a sub-agent that is continuable offers 中断子智能体 and reports it`() {
        var interrupted: String? = null
        show(SessionActivityScreenState.from(source), onRequestInterruptSubagent = { interrupted = it })
        scrollTo(UiPageTags.ACTIVITY_SUBAGENT_INTERRUPT)
        compose.onNodeWithTag(UiPageTags.ACTIVITY_SUBAGENT_INTERRUPT).performClick()
        assertEquals("s1", interrupted)
    }

    @Test
    fun `a schedule offers 删除计划任务 and reports it`() {
        var deleted: String? = null
        show(SessionActivityScreenState.from(source), onRequestDeleteSchedule = { deleted = it })
        scrollTo(UiPageTags.ACTIVITY_SCHEDULE_DELETE)
        compose.onNodeWithTag(UiPageTags.ACTIVITY_SCHEDULE_DELETE).performClick()
        assertEquals("p1", deleted)
    }

    @Test
    fun `only a running or stopping job offers 停止后台作业`() {
        var stopped: String? = null
        show(SessionActivityScreenState.from(source), onRequestStopJob = { stopped = it })
        scrollTo(UiPageTags.ACTIVITY_JOB_STOP)
        // One job is running, the other failed: exactly one stop action.
        compose.onNodeWithTag(UiPageTags.ACTIVITY_JOB_STOP).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_JOB_STOP).performClick()
        assertEquals("j1", stopped)
    }

    @Test
    fun `a 暂不可用 section hides its detail until it is opened`() {
        var toggled: String? = null
        show(SessionActivityScreenState.from(source), onToggleError = { toggled = it })
        scrollTo(UiPageTags.ACTIVITY_ERROR_ROW_PREFIX + "计划")
        compose.onNodeWithTag(UiPageTags.ACTIVITY_ERROR_SECTION_PREFIX + "计划").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_ERROR_ROW_PREFIX + "计划").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ACTIVITY_ERRORS_DETAIL.format("计划")).assertIsDisplayed()
        compose.onNodeWithText("读不到计划").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_ERROR_ROW_PREFIX + "计划").performClick()
        assertEquals("计划", toggled)
    }

    @Test
    fun `an opened 暂不可用 section shows the failure detail`() {
        val local = SessionActivityLocalState(expandedErrors = setOf("计划"))
        show(SessionActivityScreenState.from(source, local))
        scrollTo(UiPageTags.ACTIVITY_ERROR_ROW_PREFIX + "计划")
        compose.onNodeWithText("读不到计划").assertIsDisplayed()
    }

    @Test
    fun `the 暂不可用 body runs motion disclosure`() {
        var local by mutableStateOf(SessionActivityLocalState())
        compose.setContent {
            PdshTheme {
                SessionActivityPage(
                    state = SessionActivityScreenState.from(source, local),
                    onRefresh = {},
                    onToggleError = { key ->
                        local = local.apply(SessionActivityUiEvent.ToggleError(key))
                    },
                    onConfirm = {},
                    onCancel = {},
                )
            }
        }
        val rowTag = UiPageTags.ACTIVITY_ERROR_ROW_PREFIX + "计划"
        val bodyTag = PdshDisclosureTags.body(rowTag)
        compose.onNodeWithTag(UiPageTags.ACTIVITY_LIST).performScrollToNode(hasTestTag(rowTag))
        compose.onNodeWithTag(bodyTag).assertDoesNotExist()

        // Freeze the clock so the body's own motion is what these samples see.
        compose.mainClock.autoAdvance = false
        compose.onNodeWithTag(rowTag).performClick()
        compose.mainClock.advanceTimeByFrame()

        var elapsed = 0L
        val samples = mutableListOf<Pair<Long, Float>>()
        repeat(24) {
            compose.mainClock.advanceTimeByFrame()
            elapsed += 16
            samples += elapsed to compose.onNodeWithTag(bodyTag).fetchSemanticsNode().boundsInRoot.height
        }
        val full = samples.last().second
        assertTrue("the detail body reached its full height", full > 1f)
        val mid = samples.first { it.first >= 64L }.second
        assertTrue("the body is mid-animation at 64 ms (height=$mid, full=$full)", mid > 0f && mid < full - 1f)
        val durationMs = DisclosureMotion
            .specFor(DisclosureKind.BODY, reducedMotion = false)
            .durationMs
        val firstFull = samples.first { it.second >= full - 0.5f }.first
        assertTrue(
            "the body runs motion.disclosure (${durationMs}ms); it was first full at ${firstFull}ms",
            firstFull in (durationMs - 10L)..(durationMs + 40L),
        )
    }

    @Test
    fun `the toolbar 刷新 reports the refresh`() {
        var refreshes = 0
        show(SessionActivityScreenState.from(source), onRefresh = { refreshes += 1 })
        compose.onNodeWithTag(UiPageTags.ACTIVITY_REFRESH).performClick()
        assertEquals(1, refreshes)
    }

    @Test
    fun `the goal confirmation renders the baseline's copy and reports both actions`() {
        var confirmed = 0
        var cancelled = 0
        val local = SessionActivityLocalState(confirm = ActivityConfirm.Goal(ActivityGoalAction.PAUSE))
        show(
            SessionActivityScreenState.from(source, local),
            onConfirm = { confirmed += 1 },
            onCancel = { cancelled += 1 },
        )
        // A modal dialog, not a page panel: `isDialog()` is true for its root.
        compose.onNodeWithTag(UiPageTags.ACTIVITY_CONFIRM).assertIsDisplayed()
        compose.onNode(isDialog()).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ACTIVITY_CONFIRM_GOAL_PAUSE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ACTIVITY_CONFIRM_GOAL_MESSAGE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_CONFIRM_ACTION).performClick()
        assertEquals(1, confirmed)
        compose.onNodeWithTag(UiPageTags.ACTIVITY_CONFIRM_CANCEL).performClick()
        assertEquals(1, cancelled)
        // The dialog spells the verb the row offers (暂停目标), not the baseline's
        // short 暂停: the page has no short-form control of its own. The row below
        // the dialog carries the same words, so the assertion is the button's own.
        compose.onNodeWithTag(UiPageTags.ACTIVITY_CONFIRM_ACTION)
            .assertTextEquals(UiStrings.ACTIVITY_GOAL_PAUSE)
    }

    @Test
    fun `a job confirmation names 停止作业`() {
        val local = SessionActivityLocalState(confirm = ActivityConfirm.StopJob("j1"))
        show(SessionActivityScreenState.from(source, local))
        compose.onNodeWithTag(UiPageTags.ACTIVITY_CONFIRM_ACTION)
            .assertTextEquals(UiStrings.ACTIVITY_CONFIRM_JOB_ACTION)
        compose.onNodeWithTag(UiPageTags.ACTIVITY_CONFIRM_CANCEL).assertIsDisplayed()
    }

    @Test
    fun `a sub-agent confirmation names 中断`() {
        val local = SessionActivityLocalState(confirm = ActivityConfirm.InterruptSubagent("s1"))
        show(SessionActivityScreenState.from(source, local))
        compose.onNodeWithTag(UiPageTags.ACTIVITY_CONFIRM_ACTION)
            .assertTextEquals(UiStrings.ACTIVITY_CONFIRM_SUBAGENT_ACTION)
    }

    @Test
    fun `a schedule confirmation has no message line`() {
        val local = SessionActivityLocalState(confirm = ActivityConfirm.DeleteSchedule("p1"))
        show(SessionActivityScreenState.from(source, local))
        compose.onNodeWithTag(UiPageTags.ACTIVITY_CONFIRM).assertIsDisplayed()
        compose.onNode(isDialog()).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ACTIVITY_CONFIRM_SCHEDULE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ACTIVITY_CONFIRM_GOAL_MESSAGE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.ACTIVITY_CONFIRM_MESSAGE).assertDoesNotExist()
    }
}
