// NativeAutomationPage: four states, the lazy-list unknown rule and the route sequence.
// SPDX-License-Identifier: MIT
//
// The unknown-value tests locate their region with `performScrollToNode` before
// asserting that an empty/zero value is absent: the catalog and history are lazy
// items, so a bare `assertDoesNotExist` on a row that was never composed would
// pass for the wrong reason.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
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
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class NativeAutomationPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun fullFacts(): AutomationFacts = AutomationFacts(
        snapshot = AutomationSnapshot(
            schedules = listOf(
                AutomationSchedule(
                    id = "daily",
                    title = "每日构建",
                    prompt = "跑一遍构建",
                    status = ScheduleStatus.ACTIVE,
                    rule = "cron 0 9 * * 1-5",
                    nextRun = "2026-11-02 09:00",
                    latestDelivery = "2026-10-31 09:00",
                    sessionTitle = "发布会话",
                    detail = "工作日运行",
                ),
                AutomationSchedule(
                    id = "weekly",
                    title = "每周周报",
                    prompt = "总结这一周",
                    status = ScheduleStatus.STOPPED,
                    rule = "weekly",
                    nextRun = "2026-11-06 18:00",
                    latestDelivery = "2026-10-30 18:00",
                    sessionTitle = "周报会话",
                ),
            ),
            history = AutomationHistory(
                scheduleId = "daily",
                deliveries = listOf(
                    AutomationDelivery(
                        id = "delivery-1",
                        deliveredAt = "2026-10-31 09:00",
                        scheduledAt = "2026-10-31 09:00",
                        prompt = "跑一遍构建",
                    ),
                ),
                notice = "保留最近 7 天",
                hasMore = true,
            ),
        ),
    )

    private fun show(
        state: AutomationScreenState,
        onOpenDetail: (String) -> Unit = {},
        onOpenHistory: (String) -> Unit = {},
        onNewSchedule: (() -> Unit)? = null,
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                NativeAutomationPage(
                    state = state,
                    onBack = {},
                    onOpenDetail = onOpenDetail,
                    onOpenHistory = onOpenHistory,
                    onBackToCatalog = {},
                    onNewSchedule = onNewSchedule,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )
            }
        }
    }

    /** A host that applies the navigation events, so child views really render. */
    private fun showLive(
        facts: AutomationFacts,
        initial: AutomationLocalState = AutomationLocalState(),
        onLoadMore: () -> Unit = {},
        onEdit: (String) -> Unit = {},
    ) {
        compose.setContent {
            var local by remember { mutableStateOf(initial) }
            PdshTheme {
                NativeAutomationPage(
                    state = AutomationScreenState.from(facts, local),
                    onBack = {},
                    onOpenDetail = { id -> local = local.apply(AutomationUiEvent.OpenDetail(id)) },
                    onOpenHistory = { id -> local = local.apply(AutomationUiEvent.OpenHistory(id)) },
                    onBackToCatalog = { local = local.apply(AutomationUiEvent.Back) },
                    onEditSchedule = onEdit,
                    onLoadMoreHistory = onLoadMore,
                )
            }
        }
    }

    // ------------------------------------------------------------------ states

    @Test
    fun `an empty schedule list is the empty state, not the unknown state`() {
        val state = AutomationScreenState.from(
            AutomationFacts(snapshot = AutomationSnapshot(schedules = emptyList())),
        )
        assertEquals(AutomationStatus.EMPTY, state.status)
        assertTrue(state.isEmpty)
        assertEquals(0, state.scheduleCount)
        assertEquals(AutomationRoute.CATALOG, state.route)
        var created = 0
        show(state, onNewSchedule = { created += 1 })

        compose.onNodeWithTag(UiPageTags.AUTOMATION_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EMPTY_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_LIST).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.AUTOMATION_TASK_COUNT.format(0)).assertDoesNotExist()

        compose.onNodeWithTag(UiPageTags.AUTOMATION_NEW).performClick()
        assertEquals(1, created)
    }

    @Test
    fun `a measured catalog renders every schedule and the row opens its detail`() {
        val facts = fullFacts()
        val state = AutomationScreenState.from(facts)
        assertEquals(AutomationStatus.READY, state.status)
        assertEquals(2, state.scheduleCount)
        assertEquals(listOf("daily", "weekly"), state.schedules.map { it.id })
        assertEquals(UiStrings.AUTOMATION_ACTIVE, state.schedules[0].statusText)
        assertEquals(UiStrings.AUTOMATION_STOPPED, state.schedules[1].statusText)
        assertFalse(state.hasUnmeasuredValues)
        var opened: String? = null
        show(state, onOpenDetail = { opened = it })

        compose.onNodeWithTag(UiPageTags.AUTOMATION_ROW_PREFIX + "daily").assertIsDisplayed()
        compose.onNodeWithText("每日构建").assertIsDisplayed()
        compose.onNodeWithText("跑一遍构建").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_ACTIVE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_ROW_PREFIX + "daily").performClick()
        assertEquals("daily", opened)
        compose.onNodeWithTag(UiPageTags.AUTOMATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_ROW_PREFIX + "weekly"))
        compose.onNodeWithText("每周周报").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_STOPPED).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_LIST)
            .performScrollToNode(hasText(UiStrings.AUTOMATION_READ_ONLY))
        compose.onNodeWithText(UiStrings.AUTOMATION_READ_ONLY).assertIsDisplayed()
    }

    @Test
    fun `a failed read wins over stale schedules and offers retry and dismiss`() {
        val state = AutomationScreenState.from(fullFacts().copy(failure = "读取超时"))
        assertEquals(AutomationStatus.FAILED, state.status)
        assertTrue(state.isFailed)
        assertTrue(state.schedules.isEmpty())
        assertNull(state.scheduleCount)
        var retried = 0
        var dismissed = 0
        show(
            state,
            onRetry = { retried += 1 },
            onDismissFailure = { dismissed += 1 },
        )

        compose.onNodeWithTag(UiPageTags.AUTOMATION_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_LOAD_FAILED).assertIsDisplayed()
        compose.onNodeWithText("读取超时").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_LIST).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EMPTY).assertDoesNotExist()
        compose.onNodeWithText("每日构建").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_RETRY).performClick()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_DISMISS).performClick()
        assertEquals(1, retried)
        assertEquals(1, dismissed)
    }

    @Test
    fun `an unreported schedule list is unknown after the region is composed`() {
        val state = AutomationScreenState.from(AutomationFacts())
        assertEquals(AutomationStatus.UNKNOWN, state.status)
        assertTrue(state.isUnknown)
        assertNull(state.scheduleCount)
        show(state)

        compose.onNodeWithTag(UiPageTags.AUTOMATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_UNKNOWN_DETAIL))
        compose.onNodeWithTag(UiPageTags.AUTOMATION_UNKNOWN_DETAIL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_UNKNOWN_STATE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_UNKNOWN_DETAIL).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.AUTOMATION_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.AUTOMATION_TASK_COUNT.format(0)).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.AUTOMATION_ACTIVE).assertDoesNotExist()
    }

    @Test
    fun `an unreported history is unknown, never an empty delivery list`() {
        val facts = fullFacts()
        val snapshot = requireNotNull(facts.snapshot).copy(
            history = AutomationHistory(scheduleId = "daily"),
        )
        val state = AutomationScreenState.from(
            facts.copy(snapshot = snapshot),
            AutomationLocalState(
                route = AutomationRoute.HISTORY,
                selectedScheduleId = "daily",
            ),
        )
        assertEquals(AutomationStatus.READY, state.status)
        assertEquals(AutomationRoute.HISTORY, state.route)
        assertEquals(AutomationHistoryStatus.UNKNOWN, state.historyStatus)
        assertNull(state.historyCount)
        show(state)

        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_HISTORY_UNKNOWN_DETAIL))
        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_UNKNOWN_DETAIL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_HISTORY_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_HISTORY_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.AUTOMATION_HISTORY_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.AUTOMATION_TASK_COUNT.format(0)).assertDoesNotExist()
    }

    @Test
    fun `the catalog opens the detail, hands editing to the host and then shows history`() {
        var edited: String? = null
        showLive(fullFacts(), onEdit = { edited = it })

        compose.onNodeWithTag(UiPageTags.AUTOMATION_ROW_PREFIX + "daily").performClick()
        compose.onNodeWithText(UiStrings.AUTOMATION_DETAIL_TITLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_DETAIL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_NEXT_RUN).assertIsDisplayed()
        compose.onNodeWithText("2026-11-02 09:00").assertIsDisplayed()

        compose.onNodeWithTag(UiPageTags.AUTOMATION_DETAIL)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_EDIT))
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDIT).performClick()
        assertEquals("daily", edited)

        compose.onNodeWithTag(UiPageTags.AUTOMATION_DETAIL)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_HISTORY_OPEN))
        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_OPEN).performClick()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_LIST).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_ROW).assertIsDisplayed()
        compose.onNodeWithText("跑一遍构建").assertIsDisplayed()
    }

    @Test
    fun `the route sequence is a pure function of the script`() {
        val facts = fullFacts()
        val script = listOf(
            AutomationUiEvent.OpenDetail("daily"),
            AutomationUiEvent.OpenHistory("daily"),
            AutomationUiEvent.Back,
            AutomationUiEvent.Back,
            AutomationUiEvent.OpenDetail("missing"),
            AutomationUiEvent.Back,
        )

        fun run(): List<AutomationScreenState> {
            var local = AutomationLocalState()
            return buildList {
                add(AutomationScreenState.from(facts, local))
                script.forEach { event ->
                    local = local.apply(event)
                    add(AutomationScreenState.from(facts, local))
                }
            }
        }

        val states = run()
        assertEquals(
            listOf(
                AutomationRoute.CATALOG,
                AutomationRoute.DETAIL,
                AutomationRoute.HISTORY,
                AutomationRoute.DETAIL,
                AutomationRoute.CATALOG,
                AutomationRoute.DETAIL,
                AutomationRoute.CATALOG,
            ),
            states.map { it.route },
        )
        assertEquals(
            listOf(null, "daily", "daily", "daily", null, null, null),
            states.map { it.selectedScheduleId },
        )
        assertTrue(states[5].detailMissing)
        // Replaying the same script yields exactly the same sequence (purity).
        assertEquals(states.map { it.signature() }, run().map { it.signature() })
    }
}
