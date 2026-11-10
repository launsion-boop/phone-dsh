// NativeAutomationPage: three content states, the failure section beside them and the route sequence.
// SPDX-License-Identifier: MIT
//
// The page is aligned to `NativeAutomationPage.swift`, so the tests assert the
// iOS structure rather than the pre-alignment one: a failed read ADDS the 需要处理
// section and must not subtract the empty block, the CTA or a reported row (the
// iOS model keeps `scheduleRecords` and sets `error` in the same read). The
// `AUTOMATION_*` tags of this test are the same ones the pixel capture uses.
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
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performScrollTo
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

    /** The host sentence the iOS baseline prints verbatim (a real baseline defect). */
    private val hostFailure = "The operation couldn't be completed. (ProbeKit.ProbeHostError error 3.)"

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
        onRefresh: (() -> Unit)? = null,
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
                    onRefresh = onRefresh,
                )
            }
        }
    }

    /** A host that applies the navigation events, so child views really render. */
    private fun showLive(
        facts: AutomationFacts,
        initial: AutomationLocalState = AutomationLocalState(),
        onLoadMore: (String, String?) -> Unit = { _, _ -> },
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
            AutomationFacts(
                snapshot = AutomationSnapshot(schedules = emptyList()),
                currentSessionID = "worker-session-1",
            ),
        )
        assertEquals(AutomationStatus.EMPTY, state.status)
        assertTrue(state.isEmpty)
        assertFalse(state.hasFailure)
        assertEquals(0, state.scheduleCount)
        assertEquals(AutomationRoute.CATALOG, state.route)
        var created = 0
        show(state, onNewSchedule = { created += 1 })

        compose.onNodeWithTag(UiPageTags.AUTOMATION_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EMPTY_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.AUTOMATION_TASK_COUNT.format(0)).assertDoesNotExist()
        // The failure section is absent when the host reported no error.
        compose.onNodeWithTag(UiPageTags.AUTOMATION_ATTENTION).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_FAILURE).assertDoesNotExist()

        compose.onNodeWithTag(UiPageTags.AUTOMATION_CTA).performClick()
        assertEquals(1, created)
    }

    /**
     * The state the iOS baseline captures: an empty catalog AND a failed read.
     *
     * iOS prints both (`NativeAutomationPage.swift:18-44` then `:69-71`), so the
     * page must show the empty block, the CTA and the red 需要处理 section at once.
     * The pre-alignment Android page showed only the failure, which is why
     * `page-sessions-schedules` did not match.
     */
    @Test
    fun `a failed read adds the section and keeps the empty block and the CTA`() {
        val state = AutomationScreenState.from(
            AutomationFacts(
                snapshot = AutomationSnapshot(schedules = emptyList()),
                failure = hostFailure,
            ),
        )
        assertEquals(AutomationStatus.EMPTY, state.status)
        assertTrue(state.hasFailure)
        assertEquals(hostFailure, state.failure)
        var created = 0
        show(state, onNewSchedule = { created += 1 })

        compose.onNodeWithTag(UiPageTags.AUTOMATION_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EMPTY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_CTA).assertIsDisplayed()
        // `需要处理` is the section's header, the host's own sentence is its row.
        compose.onNodeWithTag(UiPageTags.AUTOMATION_ATTENTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_ATTENTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(hostFailure).assertIsDisplayed()

        compose.onNodeWithTag(UiPageTags.AUTOMATION_CTA).performClick()
        assertEquals(1, created)
    }

    /**
     * A failure beside a reported catalog keeps the catalog: a failed read
     * disproves nothing about rows the host already sent (iOS keeps them).
     */
    @Test
    fun `a failed read never drops a schedule the host still reports`() {
        val state = AutomationScreenState.from(fullFacts().copy(failure = "读取超时"))
        assertEquals(AutomationStatus.READY, state.status)
        assertTrue(state.hasFailure)
        assertEquals(2, state.scheduleCount)
        assertEquals(listOf("daily", "weekly"), state.schedules.map { it.id })
        show(state)

        compose.onNodeWithTag(UiPageTags.AUTOMATION_ROW_PREFIX + "daily").assertIsDisplayed()
        compose.onNodeWithText("每日构建").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_FAILURE))
        compose.onNodeWithText("读取超时").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_ATTENTION).assertIsDisplayed()
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
        // The row's one line is 会话 · 规则 · 下次计划, the three facts iOS prints.
        compose.onNodeWithText(
            UiStrings.AUTOMATION_META_FORMAT.format(
                "发布会话",
                UiStrings.AUTOMATION_META_FORMAT.format("cron 0 9 * * 1-5", "2026-11-02 09:00"),
            ),
        ).assertIsDisplayed()
    }

    /** The bar of the iOS page: 刷新 and 新建 leading, 完成 trailing, plus the large title. */
    @Test
    fun `the catalog draws the iOS bar and the large title`() {
        val state = AutomationScreenState.from(
            AutomationFacts(
                snapshot = AutomationSnapshot(schedules = emptyList()),
                currentSessionID = "worker-session-1",
            ),
        )
        var refreshed = 0
        var created = 0
        show(state, onNewSchedule = { created += 1 }, onRefresh = { refreshed += 1 })

        compose.onNodeWithText(UiStrings.AUTOMATION_TITLE).assertIsDisplayed()
        // 新建 (the bar item) and 新建任务 (the CTA) are two different labels.
        compose.onNodeWithTag(UiPageTags.AUTOMATION_NEW).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_NEW_SHORT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_REFRESH).performClick()
        assertEquals(1, refreshed)
        compose.onNodeWithTag(UiPageTags.AUTOMATION_NEW).performClick()
        assertEquals(1, created)
        compose.onNodeWithTag(UiPageTags.AUTOMATION_BACK).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_DONE).assertIsDisplayed()
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
        // 未知 is not 失败: an unreported list has nothing to handle yet.
        compose.onNodeWithTag(UiPageTags.AUTOMATION_ATTENTION).assertDoesNotExist()
    }

    /** An unread list that ALSO failed says both: 未知 content, 需要处理 section. */
    @Test
    fun `an unreported list with a failure says unknown and shows the section`() {
        val state = AutomationScreenState.from(AutomationFacts(failure = "连接被拒绝"))
        assertEquals(AutomationStatus.UNKNOWN, state.status)
        assertTrue(state.hasFailure)
        show(state)

        compose.onNodeWithText(UiStrings.AUTOMATION_UNKNOWN_STATE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_FAILURE))
        compose.onNodeWithText("连接被拒绝").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_ATTENTION).assertIsDisplayed()
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
    fun `history paging passes the selected schedule and the host cursor`() {
        var requested: Pair<String, String?>? = null
        val facts = fullFacts().copy(
            snapshot = requireNotNull(fullFacts().snapshot).copy(
                history = AutomationHistory(
                    scheduleId = "daily",
                    deliveries = listOf(
                        AutomationDelivery("delivery-1", "10:00", "09:00"),
                    ),
                    hasMore = true,
                    before = "opaque-cursor",
                ),
            ),
        )
        showLive(
            facts = facts,
            initial = AutomationLocalState(
                route = AutomationRoute.HISTORY,
                selectedScheduleId = "daily",
            ),
            onLoadMore = { id, before -> requested = id to before },
        )

        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_HISTORY_MORE))
        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_MORE).performClick()
        assertEquals("daily" to "opaque-cursor", requested)
    }

    @Test
    fun `the catalog opens the detail, hands editing to the host and then shows history`() {
        var edited: String? = null
        showLive(fullFacts(), onEdit = { edited = it })

        compose.onNodeWithTag(UiPageTags.AUTOMATION_ROW_PREFIX + "daily").performClick()
        // The child page's bar keeps the iOS inline title (定时任务), not a new one.
        compose.onNodeWithText(UiStrings.AUTOMATION_TITLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_DETAIL).assertIsDisplayed()
        // `Section("提醒")` (`NativeAutomationPage.swift:129`): 名称 / 规则 / 下次计划
        // / 状态, then the prompt. L82 added the group's header and its 名称 row.
        compose.onNodeWithText(UiStrings.AUTOMATION_SECTION_REMINDER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_NAME).assertIsDisplayed()
        compose.onNodeWithText("每日构建").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_NEXT_RUN).assertIsDisplayed()
        compose.onNodeWithText("2026-11-02 09:00").assertIsDisplayed()
        // `Section("投递记录")` (`:136`): the route plus the baseline's own
        // `最近投递：…` sentence (`:142`–`:145`).
        compose.onNodeWithTag(UiPageTags.AUTOMATION_DETAIL)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_HISTORY_OPEN))
        compose.onNodeWithText(UiStrings.AUTOMATION_SECTION_HISTORY).assertIsDisplayed()
        compose.onNodeWithText(
            UiStrings.AUTOMATION_LATEST_DELIVERY_FORMAT.format("2026-10-31 09:00"),
        ).assertIsDisplayed()

        compose.onNodeWithTag("automation.detail.menu").performClick()
        compose.onNodeWithTag("automation.detail.menu.edit").performClick()
        assertEquals("daily", edited)

        compose.onNodeWithTag(UiPageTags.AUTOMATION_DETAIL)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_HISTORY_OPEN))
        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_OPEN).performClick()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_LIST).assertIsDisplayed()
        // The history page's bar title is 投递记录, as on iOS (:205). The list also
        // carries the host's retention notice under the same word, so the bar's
        // copy is the first of the two.
        compose.onAllNodesWithText(UiStrings.AUTOMATION_HISTORY_TITLE).onFirst().assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_HISTORY_ROW).assertIsDisplayed()
        compose.onNodeWithText("跑一遍构建").assertIsDisplayed()
    }

    @Test
    fun `the detail offers 编辑 and 删除 and the delete asks first`() {
        var edited = 0
        var confirmed = 0
        var cancelled = 0
        compose.setContent {
            var local by remember { mutableStateOf(AutomationLocalState()) }
            PdshTheme {
                NativeAutomationPage(
                    state = AutomationScreenState.from(fullFacts(), local),
                    onBack = {},
                    onOpenDetail = { id -> local = local.apply(AutomationUiEvent.OpenDetail(id)) },
                    onOpenHistory = { id -> local = local.apply(AutomationUiEvent.OpenHistory(id)) },
                    onBackToCatalog = { local = local.apply(AutomationUiEvent.Back) },
                    onEditSchedule = { edited += 1 },
                    onRequestDelete = { id -> local = local.apply(AutomationUiEvent.RequestDelete(id)) },
                    onConfirmDelete = { confirmed += 1 },
                    onCancelDelete = {
                        cancelled += 1
                        local = local.apply(AutomationUiEvent.CancelDelete)
                    },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.AUTOMATION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.AUTOMATION_ROW_PREFIX + "daily"))
        compose.onNodeWithTag(UiPageTags.AUTOMATION_ROW_PREFIX + "daily").performClick()
        // Edit and delete live in the iOS detail page's trailing toolbar Menu.
        compose.onNodeWithTag("automation.detail.menu").performClick()
        compose.onNodeWithText(UiStrings.AUTOMATION_EDIT_SHORT).assertIsDisplayed()
        compose.onNodeWithTag("automation.detail.menu.edit").performClick()
        assertEquals(1, edited)

        compose.onNodeWithTag("automation.detail.menu").performClick()
        compose.onNodeWithText(UiStrings.AUTOMATION_DELETE).assertIsDisplayed()
        compose.onNodeWithTag("automation.detail.menu.delete").performClick()
        // `NativeAutomationPage.swift:102`–`:109`: the destructive verb and a cancel.
        compose.onNode(isDialog()).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_CONFIRM_DELETE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_CONFIRM_DELETE_MESSAGE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_DELETE_CONFIRM).performClick()
        assertEquals(1, confirmed)
        compose.onNodeWithTag(UiPageTags.AUTOMATION_DELETE_CANCEL).performClick()
        assertEquals(1, cancelled)
        compose.onNodeWithText(UiStrings.AUTOMATION_DELETE_TASK).assertDoesNotExist()
    }

    @Test
    fun `weekly weekdays field accepts its comma separated iOS format`() {
        val draft = AutomationScheduleDraft(
            rule = AutomationRule.WEEKLY,
            timeZone = "Etc/UTC",
            weekdays = "",
        )
        val local = AutomationLocalState().apply(AutomationUiEvent.OpenEditor(draft))
        compose.setContent {
            var state by remember { mutableStateOf(local) }
            PdshTheme {
                NativeAutomationPage(
                    state = AutomationScreenState.from(
                        AutomationFacts(snapshot = AutomationSnapshot(schedules = emptyList())),
                        state,
                    ),
                    onBack = {},
                    onOpenDetail = {},
                    onOpenHistory = {},
                    onBackToCatalog = {},
                    onDraftChange = { next ->
                        state = state.apply(AutomationUiEvent.EditDraft(next))
                    },
                )
            }
        }

        val weekdaysTag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + "weekdays"
        compose.onNodeWithTag(weekdaysTag).performScrollTo().performTextInput("1,2,3,4,5")
        // A number-only keyboard rejects or makes punctuation unreachable on
        // common Android IMEs; the iOS baseline explicitly uses
        // numbersAndPunctuation for this comma-separated value.
        compose.onNodeWithTag(weekdaysTag).assertTextEquals("1,2,3,4,5")
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
        // The failure flag is part of the signature, so a sequence that only
        // changes the error still differs.
        assertTrue(
            states.map { it.signature() } !=
                run().map { it.signature() }.map { it.replace(":clear:", ":failure:") },
        )
    }
}
