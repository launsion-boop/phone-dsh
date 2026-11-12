// BotInfoPage: the three load states, the fixture-backed sub-pages, the
// presence/disturbance sections and the emitted `BotInfoIntent` /
// `BotAppearanceIntent` values.
// SPDX-License-Identifier: MIT
//
// The page is rendered with the pinned `info`/`infoEmpty` snapshots from
// `spec/ui/v1/bot/golden/fixtures.json`, read from disk at test time.
package com.phonedsh.ui.bot.page.info

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.bot.page.BotFishSlot
import com.phonedsh.ui.bot.page.appearance.BotAppearanceTags
import com.phonedsh.ui.bot.page.drawer.BotPageFixtures
import com.phonedsh.ui.bot.state.BotAppearanceIntent
import com.phonedsh.ui.bot.state.BotInfoIntent
import com.phonedsh.ui.bot.state.BotInfoModelState
import com.phonedsh.ui.bot.state.BotInfoSection
import com.phonedsh.ui.bot.state.BotReconciliationDecision
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h900dp")
class BotInfoPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val intents = mutableListOf<BotInfoIntent>()
    private val appearanceIntents = mutableListOf<BotAppearanceIntent>()
    private var backs = 0
    private var deletes = 0

    private val fish: BotFishSlot = { _, _, crowned, size, _, modifier ->
        Box(
            modifier.size(size).testTag(if (crowned) FISH_CROWNED else FISH_PLAIN),
        )
    }

    private fun show(
        state: BotInfoModelState,
        initialSection: BotInfoSection? = null,
        highlight: String? = null,
        onDelete: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                BotInfoPage(
                    state = state,
                    appearance = BotPageFixtures.fixtureAppearance(),
                    isMainBot = true,
                    onIntent = { intents += it },
                    fish = fish,
                    onAppearanceIntent = { appearanceIntents += it },
                    initialSection = initialSection,
                    highlightRoutineID = highlight,
                    onBack = { backs += 1 },
                    onDelete = onDelete,
                )
            }
        }
    }

    private fun scrollRootTo(tag: String) {
        compose.onNodeWithTag(BotInfoTags.LIST).performScrollToNode(hasTestTag(tag))
        compose.onNodeWithTag(tag).assertExists()
    }

    private fun openRootSection(sectionTag: String) {
        scrollRootTo(sectionTag)
        compose.onNodeWithTag(sectionTag).performClick()
    }

    private fun scrollIn(listTag: String, tag: String) {
        compose.onNodeWithTag(listTag).performScrollToNode(hasTestTag(tag))
        compose.onNodeWithTag(tag, useUnmergedTree = true).assertExists()
    }

    private fun textShown(text: String): Boolean =
        compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()

    // ------------------------------------------------------------------- root

    @Test
    fun `loaded fixture renders the header, the data counts, presence and disturbance`() {
        show(BotPageFixtures.infoModel())

        compose.onNodeWithText("大肥鱼").assertIsDisplayed()
        compose.onNodeWithText(BotInfoCopy.DEFAULT_DESCRIPTION).assertIsDisplayed()
        compose.onNodeWithTag(FISH_CROWNED).assertIsDisplayed()

        scrollRootTo(BotInfoTags.PRESENCE)
        compose.onNodeWithText(BotInfoCopy.PRESENCE_LEVEL_SCHEDULED).assertIsDisplayed()
        compose.onNodeWithText(BotInfoCopy.PRESENCE_NOTIFICATIONS).assertIsDisplayed()
        compose.onNodeWithText("1 条").assertIsDisplayed()
        scrollIn(BotInfoTags.LIST, BotInfoTags.presenceDeferred("routine-1"))
        compose.onNodeWithText("晨间简报").assertIsDisplayed()

        scrollRootTo(BotInfoTags.DND)
        compose.onNodeWithText(BotInfoCopy.DND).assertIsDisplayed()
        compose.onNodeWithTag(BotInfoTags.QUIET_START, useUnmergedTree = true).assertExists()
        compose.onNodeWithTag(BotInfoTags.QUIET_END, useUnmergedTree = true).assertExists()

        scrollRootTo(BotInfoTags.DATA_MEMORY)
        compose.onNodeWithContentDescription("记忆，2 个").assertIsDisplayed()
        compose.onNodeWithContentDescription("例行任务，2 个").assertIsDisplayed()
        compose.onNodeWithContentDescription("审批记录，7 个").assertIsDisplayed()
        compose.onNodeWithContentDescription("常设授权，3 个").assertIsDisplayed()
    }

    @Test
    fun `loading state marks every data entry and the memory sub-page`() {
        show(BotInfoModelState.initial(hasDriver = true))

        scrollRootTo(BotInfoTags.DATA_MEMORY)
        compose.onNodeWithTag(
            BotInfoTags.entryState("memory", "loading"),
            useUnmergedTree = true,
        ).assertExists()
        compose.onNodeWithTag(BotInfoTags.DATA_MEMORY).performClick()

        compose.onNodeWithTag(BotInfoTags.MEMORY_LOADING).assertExists()
    }

    @Test
    fun `failed state keeps the reason and offers the retry intent`() {
        show(BotInfoModelState.initial(fixtureError = "引擎未连接"))

        scrollRootTo(BotInfoTags.DATA_MEMORY)
        compose.onNodeWithTag(
            BotInfoTags.entryState("memory", "failed"),
            useUnmergedTree = true,
        ).assertExists()
        compose.onNodeWithTag(BotInfoTags.DATA_MEMORY).performClick()

        val message = BotUiStrings.format(
            "info.memory.readFailed",
            "error" to "引擎未连接",
        )
        compose.onNodeWithText(message).assertIsDisplayed()
        compose.onAllNodesWithText(UiStrings.RETRY).onFirst().performClick()
        assertTrue(intents.contains(BotInfoIntent.Load))
    }

    @Test
    fun `an empty loaded snapshot shows empty sections, not read failures`() {
        show(BotPageFixtures.infoModel("infoEmpty"))

        openRootSection(BotInfoTags.DATA_MEMORY)
        compose.onNodeWithText(BotInfoCopy.MEMORY_EMPTY).assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()

        openRootSection(BotInfoTags.DATA_ROUTINES)
        compose.onNodeWithText(BotInfoCopy.ROUTINES_EMPTY).assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()

        openRootSection(BotInfoTags.DATA_APPROVALS)
        compose.onNodeWithText(BotInfoCopy.APPROVALS_EMPTY).assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()

        openRootSection(BotInfoTags.DATA_GRANTS)
        compose.onNodeWithText(BotInfoCopy.GRANTS_EMPTY).assertIsDisplayed()
    }

    // ---------------------------------------------------------------- memory

    @Test
    fun `memory sub-page renders the fixture documents and the maintenance batch`() {
        show(BotPageFixtures.infoModel())
        openRootSection(BotInfoTags.DATA_MEMORY)

        compose.onNodeWithText(BotInfoCopy.MAINTENANCE_SWITCH).assertIsDisplayed()
        scrollIn(BotInfoTags.MEMORY_LIST, BotInfoTags.memoryDocument("agent/profile.md"))
        scrollIn(BotInfoTags.MEMORY_LIST, BotInfoTags.memoryDocument("user/profile.md"))

        scrollIn(BotInfoTags.MEMORY_LIST, BotInfoTags.MAINTENANCE_BATCH)
        compose.onNodeWithText(BotInfoCopy.MAINTENANCE_STATUS_COMMITTED).assertIsDisplayed()
        compose.onNodeWithText(
            BotInfoCopy.format(
                BotInfoCopy.MAINTENANCE_CHANGED,
                "count" to 2,
                "result" to BotInfoCopy.MAINTENANCE_CHECKED,
            ),
        ).assertIsDisplayed()
        compose.onNodeWithText("共享索引 INDEX.md：第 3 版 → 第 4 版").assertIsDisplayed()
        compose.onNodeWithText("本 Bot 资料 profile.md：第 2 版 → 第 3 版").assertIsDisplayed()
        compose.onNodeWithTag(BotInfoTags.MAINTENANCE_ROLLBACK).assertIsDisplayed()

        compose.onNodeWithTag(BotInfoTags.MAINTENANCE_ROLLBACK).performClick()
        compose.onNodeWithText(BotInfoCopy.MAINTENANCE_ROLLBACK_BODY).assertIsDisplayed()
    }

    @Test
    fun `memory document detail shows content, evidence and every version`() {
        show(BotPageFixtures.infoModel())
        openRootSection(BotInfoTags.DATA_MEMORY)

        scrollIn(BotInfoTags.MEMORY_LIST, BotInfoTags.memoryDocument("agent/profile.md"))
        compose.onNodeWithTag(BotInfoTags.memoryDocument("agent/profile.md")).performClick()

        compose.onNodeWithTag(BotInfoTags.MEMORY_DOCUMENT_CONTENT).assertIsDisplayed()
        compose.onNodeWithText("对话来源 1 条").assertIsDisplayed()
        compose.onNodeWithTag(BotInfoTags.MEMORY_DOCUMENT_VERSIONS).assertExists()
        compose.onAllNodesWithText("第 2 版").onFirst().assertExists()
        compose.onAllNodesWithText("第 1 版").onFirst().assertExists()
        compose.onNodeWithTag(BotInfoTags.MEMORY_DOCUMENT_FORGET).assertIsDisplayed()
        compose.onNodeWithTag(BotInfoTags.MEMORY_DOCUMENT_ERASE).assertIsDisplayed()
    }

    @Test
    fun `forget emits the document path and its live version`() {
        show(BotPageFixtures.infoModel())
        openRootSection(BotInfoTags.DATA_MEMORY)

        scrollIn(BotInfoTags.MEMORY_LIST, "bot.memory.forget.agent/profile.md")
        compose.onNodeWithTag("bot.memory.forget.agent/profile.md", useUnmergedTree = true)
            .performClick()
        compose.onNodeWithTag(BotInfoTags.MEMORY_FORGET_CONFIRM).performClick()

        assertEquals(
            BotInfoIntent.Forget("agent/profile.md", 2),
            intents.filterIsInstance<BotInfoIntent.Forget>().single(),
        )
    }

    // -------------------------------------------------------------- routines

    @Test
    fun `routines sub-page renders human fields and both reconciliation actions`() {
        show(BotPageFixtures.infoModel())
        openRootSection(BotInfoTags.DATA_ROUTINES)

        scrollIn(BotInfoTags.ROUTINES_LIST, BotInfoTags.routineRow("routine-1"))
        assertTrue(textShown("晨间简报"))
        assertTrue(textShown("上海时间（UTC+8）"))
        assertTrue(textShown("下次聊天时送达"))

        scrollIn(BotInfoTags.ROUTINES_LIST, BotInfoTags.routineRow("routine-2"))
        assertTrue(textShown("发布窗口检查"))
        assertTrue(textShown("立即提醒"))
        assertTrue(textShown(BotInfoCopy.ROUTINE_RECONCILIATION_TITLE))
        assertTrue(textShown("已尝试发送提醒，送达结果未确认。"))
        assertTrue(textShown("原因：连接在确认前中断。"))
        compose.onNodeWithTag(BotInfoTags.routineAck("routine-2")).performClick()
        compose.onNodeWithTag(BotInfoTags.routineRetry("routine-2")).performClick()

        assertEquals(
            listOf(
                BotInfoIntent.ResolveReconciliation(
                    "routine-2",
                    BotReconciliationDecision.ACKNOWLEDGE,
                ),
                BotInfoIntent.ResolveReconciliation(
                    "routine-2",
                    BotReconciliationDecision.RETRY,
                ),
            ),
            intents.filterIsInstance<BotInfoIntent.ResolveReconciliation>(),
        )
    }

    @Test
    fun `routine toggle and cancel emit the frozen intents`() {
        show(BotPageFixtures.infoModel())
        openRootSection(BotInfoTags.DATA_ROUTINES)

        scrollIn(BotInfoTags.ROUTINES_LIST, BotInfoTags.routineToggle("routine-2"))
        compose.onNodeWithTag(BotInfoTags.routineToggle("routine-2")).performClick()
        assertEquals(
            BotInfoIntent.SetRoutineEnabled("routine-2", true),
            intents.filterIsInstance<BotInfoIntent.SetRoutineEnabled>().last(),
        )

        scrollIn(BotInfoTags.ROUTINES_LIST, BotInfoTags.routineCancel("routine-1"))
        compose.onNodeWithTag(BotInfoTags.routineCancel("routine-1")).performClick()
        compose.onNodeWithText(BotInfoCopy.ROUTINE_CANCEL_BODY).assertIsDisplayed()
        compose.onNodeWithTag(BotInfoTags.ROUTINE_CANCEL_CONFIRM).performClick()
        assertEquals(
            BotInfoIntent.CancelRoutine("routine-1"),
            intents.filterIsInstance<BotInfoIntent.CancelRoutine>().single(),
        )
    }

    @Test
    fun `routine detail keeps the raw ids out of the main row`() {
        show(BotPageFixtures.infoModel())
        openRootSection(BotInfoTags.DATA_ROUTINES)

        assertTrue("the raw run id must not appear before 详情", !textShown("run-fixture-1"))
        scrollIn(BotInfoTags.ROUTINES_LIST, BotInfoTags.routineDetail("routine-1"))
        compose.onNodeWithTag(BotInfoTags.routineDetail("routine-1")).performClick()
        assertTrue(textShown(BotInfoCopy.ROUTINE_DETAIL_ID))
        assertTrue(textShown("run-fixture-1"))
    }

    @Test
    fun `a deep link opens the routine section and marks the routine row`() {
        show(
            BotPageFixtures.infoModel(),
            initialSection = BotInfoSection.ROUTINES,
            highlight = "routine-2",
        )

        compose.waitForIdle()
        compose.onNodeWithTag(BotInfoTags.routineRow("routine-2")).assertExists()
        compose.onNodeWithText("发布窗口检查").assertIsDisplayed()
    }

    // ------------------------------------------------------ approvals/grants

    @Test
    fun `approvals sub-page renders every fixture summary and decision`() {
        show(BotPageFixtures.infoModel())
        openRootSection(BotInfoTags.DATA_APPROVALS)

        assertTrue(textShown("删除文件 · 旧验收报告"))
        assertTrue(textShown("写入文件 · 本周发布报告"))
        scrollIn(BotInfoTags.APPROVALS_LIST, "bot.approval.row.record-7")
        assertTrue(textShown("执行命令 · 构建检查"))
        assertTrue(textShown("拒绝"))
        assertTrue(textShown("允许一次"))
    }

    @Test
    fun `grants sub-page renders standing grants and revoke emits its intent`() {
        show(BotPageFixtures.infoModel())
        openRootSection(BotInfoTags.DATA_GRANTS)

        scrollIn(BotInfoTags.GRANTS_LIST, "bot.grant.row.grant-1")
        assertTrue(textShown("写入文件"))
        assertTrue(textShown("长期有效"))
        scrollIn(BotInfoTags.GRANTS_LIST, "bot.grant.row.grant-2")
        assertTrue(textShown("访问网络"))
        assertTrue(textShown("本次会话"))
        scrollIn(BotInfoTags.GRANTS_LIST, "bot.grant.row.grant-3")
        assertTrue(textShown("丢弃改动"))

        scrollIn(BotInfoTags.GRANTS_LIST, BotInfoTags.grantRevoke("grant-1"))
        compose.onNodeWithTag(BotInfoTags.grantRevoke("grant-1")).performClick()

        assertEquals(
            BotInfoIntent.RevokeGrant("grant-1"),
            intents.filterIsInstance<BotInfoIntent.RevokeGrant>().single(),
        )
        assertTrue("the page never removes a grant before the host re-reads it", textShown("写入文件"))
    }

    // -------------------------------------------------------------- wiring

    @Test
    fun `the info appearance picker emits the appearance selection`() {
        show(BotPageFixtures.infoModel())
        scrollRootTo(BotInfoTags.APPEARANCE)

        compose.onNodeWithTag(
            BotAppearanceTags.color(BotAppearanceTags.INFO_PREFIX, "purple"),
        ).performClick()
        compose.onNodeWithTag(
            BotAppearanceTags.hair(
                BotAppearanceTags.INFO_PREFIX,
                BotFishHairstyle.BOB.wire,
            ),
        ).performClick()

        assertEquals(
            listOf(
                BotAppearanceIntent.SelectColor(
                    com.phonedsh.bot.profile.BotFishColor.PURPLE,
                ),
                BotAppearanceIntent.SelectHairstyle(BotFishHairstyle.BOB),
            ),
            appearanceIntents,
        )
    }

    @Test
    fun `the delete section is offered only when the host supplies the cascade`() {
        show(BotPageFixtures.infoModel(), onDelete = { deletes += 1 })
        scrollRootTo(BotInfoTags.DELETE)
        compose.onNodeWithTag(BotInfoTags.DELETE).performClick()
        compose.onNodeWithTag(BotInfoTags.DELETE_MESSAGE).assertExists()
        compose.onNodeWithText(BotUiStrings.DRAWER_DELETE_CONFIRM).assertIsDisplayed()
        compose.onNodeWithTag(BotInfoTags.DELETE_CONFIRM).performClick()
        assertEquals(1, deletes)
    }

    @Test
    fun `the root back action is reported`() {
        show(BotPageFixtures.infoModel())
        compose.onNodeWithTag(BotInfoTags.ROOT).assertExists()
        compose.onNodeWithText(BotInfoCopy.DONE).performClick()
        assertEquals(1, backs)
    }

    private companion object {
        private const val FISH_CROWNED = "test.info.fish.crowned"
        private const val FISH_PLAIN = "test.info.fish.plain"
    }
}
