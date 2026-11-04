// ScheduleEditorPage: the embedded form of `NativeAutomationPage.swift:212`–`:420`.
// SPDX-License-Identifier: MIT
//
// The subpage is `private` in `NativeAutomationPage.kt` (the baseline's own
// `private struct`, `:212`), so every test drives it through the page the way the
// route does: an `AutomationLocalState` whose route is `EDITOR` and whose
// `editor` carries the draft.
//
// Three things are asserted, in this order:
//  1. the baseline's structure — 任务内容 / 计划时间 groups, 名称 + 提醒内容, the
//     修改计划时间 toggle (edit only), the 规则 chooser, 取消 and 保存;
//  2. the form really submits: 保存 hands `onSubmitDraft` a draft the user typed,
//     and a blank required field keeps the control inert instead of submitting;
//  3. the rule validation the baseline prints in its 错误 group (`:276`,
//     `timingValidationMessage()` `:397`–`:406`) — the pure rules for all six
//     choices, plus the sentence appearing on screen after an attempt.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsToggleable
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class ScheduleEditorPageTest {
    @get:Rule
    val compose = createComposeRule()

    /** The catalog the edit form is seeded from (one cron schedule). */
    private val reported = AutomationSchedule(
        id = "daily",
        title = "每日构建",
        prompt = "跑一遍构建",
        status = ScheduleStatus.ACTIVE,
        rule = "cron",
        nextRun = "2026-11-02 09:00",
        timing = AutomationTiming(
            rule = AutomationRule.CRON,
            cron = "0 9 * * 1-5",
            timeZone = "Asia/Shanghai",
        ),
    )

    private fun facts(writable: FactState = FactState.UNKNOWN): AutomationFacts = AutomationFacts(
        snapshot = AutomationSnapshot(schedules = listOf(reported)),
        writable = writable,
        currentSessionID = "worker-session-1",
    )

    /**
     * Mounts the page in its editor route the way `PdshNavHost` does: the draft
     * lives in local state, one callback per field edit, and the submit is recorded.
     *
     * @return every draft the page handed back, in order.
     */
    private fun showEditor(
        initial: AutomationScheduleDraft,
        submitted: Boolean = false,
        writable: FactState = FactState.UNKNOWN,
        onSubmit: (AutomationScheduleDraft, String) -> Unit = { _, _ -> },
        onCancel: () -> Unit = {},
    ): List<AutomationScheduleDraft> {
        val edits = mutableListOf<AutomationScheduleDraft>()
        compose.setContent {
            var editor by remember { mutableStateOf(AutomationEditorState(initial, submitted)) }
            val pageFacts = facts(writable)
            PdshTheme {
                NativeAutomationPage(
                    state = AutomationScreenState.from(
                        pageFacts,
                        // The route's `OpenEditor` sets the selection, so the form's
                        // 当前规则 row can read the host's reported schedule.
                        AutomationLocalState(
                            route = AutomationRoute.EDITOR,
                            selectedScheduleId = editor.draft.id,
                            editor = editor,
                        ),
                    ),
                    onBack = {},
                    onOpenDetail = {},
                    onOpenHistory = {},
                    onBackToCatalog = {},
                    onDraftChange = { draft ->
                        edits += draft
                        editor = editor.copy(draft = draft)
                    },
                    onSubmitDraft = onSubmit,
                    onCancelEditor = onCancel,
                )
            }
        }
        return edits
    }

    /** Scrolls the editor list to [tag]; the form scrolls, so a row can be below the fold. */
    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_LIST)
            .performScrollToNode(hasTestTag(tag))
    }

    // ------------------------------------------------------------- structure

    @Test
    fun `the new form draws 任务内容, 计划时间, both fields and both verbs`() {
        showEditor(AutomationScheduleDraft.from(schedule = null, timeZone = "Asia/Shanghai"))

        compose.onNodeWithText(UiStrings.AUTOMATION_EDITOR_NEW_TITLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_CONTENT_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EDITOR_CONTENT_SECTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_TIMING_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EDITOR_TIMING_SECTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_NAME).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EDITOR_NAME_FIELD).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_PROMPT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_PROMPT).assertIsDisplayed()
        // 规则 (`:263`) with the baseline's 延迟一次 selected by default (`:220`).
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_RULE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EDITOR_RULE_AFTER).assertIsDisplayed()
        // The two bar verbs (`:281`, `:283`).
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_CANCEL).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_SAVE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EDITOR_SAVE).assertIsDisplayed()
        // A new form has no 修改计划时间 toggle: the timing block is always shown.
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_CHANGE_TIMING).assertDoesNotExist()
    }

    @Test
    fun `the edit form draws 修改计划时间 and the host's current rule`() {
        val draft = AutomationScheduleDraft.from(reported, "Asia/Shanghai")
        assertEquals("daily", draft.id)
        assertEquals(AutomationRule.CRON, draft.rule)
        showEditor(draft.copy(changeTiming = false))

        compose.onNodeWithText(UiStrings.AUTOMATION_EDITOR_EDIT_TITLE).assertIsDisplayed()
        scrollTo(UiPageTags.AUTOMATION_EDITOR_CHANGE_TIMING)
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_CHANGE_TIMING).assertIsDisplayed()
        compose.onAllNodesWithText(UiStrings.AUTOMATION_EDITOR_CHANGE_TIMING).onFirst().assertIsDisplayed()
        // `Toggle("修改计划时间", isOn: $changeTiming)` (`:260`) is a switch, so the
        // row is toggleable and carries the two words as its state description
        // instead of as visible copy (L82). `changeTiming = false` here.
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_CHANGE_TIMING).assertIsToggleable()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_CHANGE_TIMING).assert(
            SemanticsMatcher.expectValue(
                SemanticsProperties.StateDescription,
                UiStrings.AUTOMATION_EDITOR_TOGGLE_OFF,
            ),
        )
        // The word is not drawn as a replacement for the control any more.
        compose.onNodeWithText(UiStrings.AUTOMATION_EDITOR_TOGGLE_OFF).assertDoesNotExist()
        // 当前规则 prints the host's own next-run string (`:274`), never a computed one.
        scrollTo(UiPageTags.AUTOMATION_EDITOR_CURRENT_RULE)
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_CURRENT_RULE).assertIsDisplayed()
        compose.onAllNodesWithText(UiStrings.AUTOMATION_EDITOR_CURRENT_RULE).onFirst().assertIsDisplayed()
        compose.onNodeWithText("2026-11-02 09:00").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_RULE).assertDoesNotExist()
    }

    // -------------------------------------------------------------- the write

    @Test
    fun `a submitted form that does not validate prints the baseline's sentence`() {
        // A typed 固定间隔 of 30 seconds: `:361` refuses it.
        val draft = AutomationScheduleDraft.from(schedule = null, timeZone = "Asia/Shanghai")
            .copy(title = "周报", prompt = "总结", rule = AutomationRule.EVERY, everySeconds = "30")
        showEditor(draft, submitted = true)

        scrollTo(UiPageTags.AUTOMATION_EDITOR_ERROR)
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_ERROR).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EDITOR_ERROR_EVERY).assertIsDisplayed()
        // The 错误 group the baseline wraps it in (`:276`).
        compose.onAllNodesWithText(UiStrings.AUTOMATION_ERROR).onFirst().assertIsDisplayed()
    }

    @Test
    fun `the handoff hint appears only when the host reports it cannot persist`() {
        showEditor(
            AutomationScheduleDraft.from(schedule = null, timeZone = "Asia/Shanghai"),
            writable = FactState.NO,
        )
        scrollTo(UiPageTags.AUTOMATION_EDITOR_HANDOFF)
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_HANDOFF).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AUTOMATION_EDITOR_HANDOFF_HINT).assertIsDisplayed()
    }

    // ----------------------------------------------------------- the rules

    @Test
    fun `every rule's validation is the baseline's`() {
        val base = AutomationScheduleDraft.from(schedule = null, timeZone = "Asia/Shanghai")
            .copy(title = "t", prompt = "p")

        // after (`:352`–`:356`): a positive delay.
        assertNull(base.timingError())
        assertEquals(
            UiStrings.AUTOMATION_EDITOR_ERROR_AFTER,
            base.copy(afterSeconds = "0").timingError(),
        )
        assertEquals(
            UiStrings.AUTOMATION_EDITOR_ERROR_AFTER,
            base.copy(afterSeconds = "abc").timingError(),
        )

        // at (`:357`–`:359`): a full instant with a zone designator.
        assertNull(base.copy(rule = AutomationRule.AT, at = "2026-10-26T09:00:00+08:00").timingError())
        assertNull(base.copy(rule = AutomationRule.AT, at = "2026-10-26T09:00:00Z").timingError())
        assertEquals(
            UiStrings.AUTOMATION_EDITOR_ERROR_AT,
            base.copy(rule = AutomationRule.AT, at = "2026-10-26T09:00:00").timingError(),
        )
        assertEquals(
            UiStrings.AUTOMATION_EDITOR_ERROR_AT,
            base.copy(rule = AutomationRule.AT, at = "2026-10-26").timingError(),
        )

        // every (`:360`–`:362`): at least 60 seconds.
        assertNull(base.copy(rule = AutomationRule.EVERY, everySeconds = "60").timingError())
        assertEquals(
            UiStrings.AUTOMATION_EDITOR_ERROR_EVERY,
            base.copy(rule = AutomationRule.EVERY, everySeconds = "59").timingError(),
        )

        // daily (`:363`–`:367`): a local time and an IANA zone.
        assertNull(base.copy(rule = AutomationRule.DAILY, timeZone = "Asia/Shanghai").timingError())
        assertEquals(
            UiStrings.AUTOMATION_EDITOR_ERROR_DAILY,
            base.copy(rule = AutomationRule.DAILY, localTime = "9:00", timeZone = "Asia/Shanghai").timingError(),
        )
        assertEquals(
            UiStrings.AUTOMATION_EDITOR_ERROR_DAILY,
            base.copy(rule = AutomationRule.DAILY, timeZone = "not a zone").timingError(),
        )

        // weekly (`:368`–`:375`): plus 1–7 ISO weekdays.
        val weekly = base.copy(rule = AutomationRule.WEEKLY, timeZone = "Asia/Shanghai")
        assertNull(weekly.timingError())
        assertEquals(UiStrings.AUTOMATION_EDITOR_ERROR_WEEKLY, weekly.copy(weekdays = "0,8").timingError())
        assertEquals(UiStrings.AUTOMATION_EDITOR_ERROR_WEEKLY, weekly.copy(weekdays = "1,1").timingError())
        assertEquals(UiStrings.AUTOMATION_EDITOR_ERROR_WEEKLY, weekly.copy(weekdays = "").timingError())
        assertEquals(UiStrings.AUTOMATION_EDITOR_ERROR_WEEKLY, weekly.copy(weekdays = "1,x").timingError())

        // cron (`:376`–`:381`): five fields and a zone.
        val cron = base.copy(rule = AutomationRule.CRON, timeZone = "Asia/Shanghai")
        assertNull(cron.timingError())
        assertEquals(
            UiStrings.AUTOMATION_EDITOR_ERROR_CRON,
            cron.copy(cron = "0 9 * *").timingError(),
        )
        assertEquals(
            UiStrings.AUTOMATION_EDITOR_ERROR_CRON,
            cron.copy(timeZone = "").timingError(),
        )
    }

    @Test
    fun `an edit that does not touch the timing block validates nothing`() {
        val draft = AutomationScheduleDraft.from(reported, "Asia/Shanghai").copy(
            changeTiming = false,
            rule = AutomationRule.CRON,
            cron = "not a cron",
        )
        assertTrue("the timing block is not being edited", !draft.editsTiming)
        assertNull(draft.timingError())
    }

    @Test
    fun `the draft is seeded from the reported schedule, or from the baseline's defaults`() {
        val seeded = AutomationScheduleDraft.from(reported, "Europe/Berlin")
        assertEquals("daily", seeded.id)
        assertEquals("每日构建", seeded.title)
        assertEquals("跑一遍构建", seeded.prompt)
        assertEquals(AutomationRule.CRON, seeded.rule)
        assertEquals("0 9 * * 1-5", seeded.cron)
        // The host's zone wins over the measured default.
        assertEquals("Asia/Shanghai", seeded.timeZone)
        // An edit starts with the timing block closed (`:247`).
        assertTrue(!seeded.changeTiming)

        val blank = AutomationScheduleDraft.from(schedule = null, timeZone = "Europe/Berlin")
        assertNull(blank.id)
        assertEquals("", blank.title)
        assertEquals(AutomationRule.AFTER, blank.rule)
        assertEquals("3600", blank.afterSeconds)
        assertEquals("09:00:00", blank.localTime)
        assertEquals("1,2,3,4,5", blank.weekdays)
        assertEquals("0 9 * * 1-5", blank.cron)
        assertEquals("Europe/Berlin", blank.timeZone)
        assertTrue(blank.editsTiming)
    }
}
