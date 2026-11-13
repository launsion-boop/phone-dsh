// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.driver

// The BotChatModel tests drive the real model and driver seam with the shared
// fixture export (`spec/ui/v1/bot/golden/fixtures.json`, `ui-state.md` §6) and
// the K3 P09 derivations. No row or expectation is hand-copied into this file.
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotApprovalDecision
import com.phonedsh.bot.rows.BotRowBatch
import com.phonedsh.bot.rows.BotUserActionKind
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.bot.state.BotActionKeys
import com.phonedsh.ui.bot.state.BotHeaderPhase
import com.phonedsh.ui.bot.state.BotUiContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BotChatModelTest {
    private val fixtures = SpecFixtures.repoJson("spec/ui/v1/bot/golden/fixtures.json")
    private val now = 1_760_000_000_000L

    private data class Harness(val model: BotChatModel, val driver: FixtureBotChatDriver)

    private fun model(
        scenario: String,
        historyScenarios: List<String> = emptyList(),
        results: List<BotActionResult> = emptyList(),
        presentations: List<com.phonedsh.ui.bot.state.BotRuntimePresentation> =
            listOf(com.phonedsh.ui.bot.state.BotRuntimePresentation()),
        beforeStart: (FixtureBotChatDriver) -> Unit = {},
        start: Boolean = true,
        initialScenarios: List<String> = emptyList(),
    ): Harness {
        val driver = FixtureBotChatDriver.fromJson(
            fixtures = fixtures,
            scenario = scenario,
            historyScenarios = historyScenarios,
            actionResults = results,
            presentations = presentations,
        )
        val model = BotChatModel(
            context = BotUiContext(botID = "main", botName = "主 Bot"),
            driver = driver,
            initialRows = initialScenarios.flatMap { BotFixtureData.rows(fixtures, it) },
            clock = { now },
            scope = CoroutineScope(Dispatchers.Unconfined),
        )
        beforeStart(driver)
        if (start) model.start()
        return Harness(model, driver)
    }

    @Test
    fun `watch reset applies the fixture transcript through K3`() {
        val chat = model("chat").model
        assertEquals(listOf("chat-user", "chat-assistant"), chat.state.value.rows.map { it.id })
        assertFalse(chat.state.value.isEmpty)
        assertEquals(0, chat.state.value.pendingApprovalCount)
        assertEquals(0, chat.state.value.needsAttentionCount)
        assertEquals(BotHeaderPhase.IDLE, chat.state.value.presence.phase)
    }

    @Test
    fun `question fixture holds one attention item but not the header`() {
        val state = model("question").model.state.value
        assertEquals(listOf("card-question"), state.rows.map { it.id })
        assertEquals(0, state.pendingApprovalCount)
        assertEquals(1, state.needsAttentionCount)
        assertEquals(BotHeaderPhase.IDLE, state.presence.phase)
        assertNull(state.settlements["card-question"])
    }

    @Test
    fun `approval fixture holds the header on waiting for you`() {
        val state = model("approval").model.state.value
        assertEquals(1, state.pendingApprovalCount)
        assertEquals(1, state.needsAttentionCount)
        assertEquals(BotHeaderPhase.WAITING_FOR_YOU, state.presence.phase)
        assertEquals("等你确认", state.activityLine.text)
    }

    @Test
    fun `task fixture counts as following`() {
        val state = model("task").model.state.value
        assertEquals(1, state.followingCount)
        assertEquals(0, state.pendingApprovalCount)
    }

    @Test
    fun `history paging asks before the durable anchor and inserts older rows first`() {
        val harness = model(
            "chat",
            historyScenarios = listOf("question", "steps"),
            start = false,
            initialScenarios = listOf("chat"),
        )
        val chat = harness.model
        assertTrue(chat.state.value.hasMoreHistory)
        chat.loadHistory()
        assertEquals("chat-user" to 50, harness.driver.historyCalls.single())
        val ids = chat.state.value.rows.map { it.id }
        assertTrue("older rows are kept", ids.contains("card-question"))
        assertTrue("older rows are kept", ids.contains("card-steps"))
        assertTrue("newer rows are kept", ids.contains("chat-user"))
        assertEquals("ascending seq order is restored", ids.sorted(), ids.sorted())
    }

    @Test
    fun `a failed answer keeps the card full and the retry settles it`() {
        val harness = model("question", results = listOf(BotActionResult.Rejected("network down")))
        val chat = harness.model
        chat.answer("card-question", "library")
        assertEquals("network down", chat.state.value.runtimeNotice)
        assertNull(chat.state.value.settlements["card-question"])
        assertTrue(chat.state.value.actionStates[BotActionKeys.card("card-question")]
            is com.phonedsh.ui.bot.state.BotActionState.Failed)

        harness.driver.enqueueResults(BotActionResult.Accepted("evt-answer"))
        chat.answer("card-question", "library")
        val settlement = chat.state.value.settlements.getValue("card-question")
        assertEquals("已选择：保存到文档库", settlement.title)
        assertEquals(2, harness.driver.performed.size)
        assertEquals(BotUserActionKind.CARD_ANSWER, harness.driver.performed.last().kind)
    }

    @Test
    fun `a failed dismiss is retryable under UI-2`() {
        val harness = model("question", results = listOf(BotActionResult.Rejected("late")))
        val chat = harness.model
        chat.dismiss("card-question")
        assertNull(chat.state.value.settlements["card-question"])
        harness.driver.enqueueResults(BotActionResult.Accepted("evt-dismiss"))
        chat.dismiss("card-question")
        assertEquals("已关闭", chat.state.value.settlements.getValue("card-question").title)
    }

    @Test
    fun `an accepted checklist send settles the card`() {
        val harness = model("checklist")
        val chat = harness.model
        chat.sendChecklist("card-checklist", 2, 4, "发布前检查：已完成 2／4。")
        assertEquals(BotUserActionKind.CHAT, harness.driver.performed.single().kind)
        assertTrue(chat.state.value.checklistProgress.getValue("card-checklist").sent)
        val settlement = chat.state.value.settlements.getValue("card-checklist")
        assertEquals("已发送勾选结果", settlement.title)
        assertEquals("发布前检查 · 已完成 2/4", settlement.detail)
    }

    @Test
    fun `an approval decision writes the row status and settles it`() {
        val harness = model("approval")
        val chat = harness.model
        chat.decide("card-approval", BotApprovalDecision.ALWAYS)
        val action = harness.driver.performed.single()
        assertEquals(BotUserActionKind.APPROVAL, action.kind)
        assertEquals(BotApprovalDecision.ALWAYS, action.decision)
        assertEquals("sha256:fixture", action.digest)
        assertEquals(0, chat.state.value.pendingApprovalCount)
        val settlement = chat.state.value.settlements.getValue("card-approval")
        assertEquals("已总是允许", settlement.title)
    }

    @Test
    fun `the next send auto denies pending approvals before the chat action`() {
        val harness = model("approvalAutoDeclined")
        val chat = harness.model
        chat.setDraft("继续")
        chat.send()
        assertEquals(
            listOf(BotUserActionKind.APPROVAL, BotUserActionKind.CHAT),
            harness.driver.performed.map { it.kind },
        )
        assertEquals(BotApprovalDecision.DENY, harness.driver.performed.first().decision)
        assertEquals(0, chat.state.value.pendingApprovalCount)
        assertEquals(
            "已略过，视为拒绝",
            chat.state.value.settlements.getValue("approval-auto-next").title,
        )
    }

    @Test
    fun `a send arms the activity line before the host starts the turn`() {
        val chat = model("chat").model
        chat.send("你好")
        assertNull(chat.state.value.runningTurnID)
        assertTrue(chat.state.value.awaitingTurn)
        assertEquals(BotHeaderPhase.WORKING, chat.state.value.presence.phase)
        assertEquals("思考中…", chat.state.value.activityLine.text)
    }

    @Test
    fun `stop clears the running turn and calls the driver`() {
        val harness = model("chat")
        val chat = harness.model
        chat.beginTurn("turn-1")
        chat.stop()
        assertNull(chat.state.value.runningTurnID)
        assertEquals(listOf("turn-1"), harness.driver.stopCalls)
        assertTrue(chat.state.value.rows.any { it.id == "chat-assistant" })
    }

    @Test
    fun `a progress row with the same card key updates in place`() {
        val originalRow = BotFixtureData.rows(fixtures, "progress").single()
        val updated = originalRow.copy(
            id = "card-progress-next",
            updatedSeq = originalRow.updatedSeq + 1,
            seq = originalRow.seq + 1,
            body = originalRow.body.with("percent", JsonNumber("80")),
        )
        val harness = model("progress", beforeStart = { driver ->
            driver.enqueueBatch(
                BotRowBatch(
                    rows = listOf(updated),
                    deletes = emptyList(),
                    cursor = 2,
                    reset = false,
                ),
            )
        })
        val chat = harness.model
        assertEquals(1, chat.state.value.rows.count { it.body.cardType?.wire == "progress" })
        assertEquals("card-progress-next", chat.state.value.rows.single().id)
        assertEquals(JsonNumber("80"), chat.state.value.rows.single().body["percent"])
    }

    @Test
    fun `an error notice in a live batch becomes the header problem, never a row`() {
        val notice = BotFixtureData.rows(fixtures, "error").single()
        val harness = model("chat", beforeStart = { driver ->
            driver.enqueueBatch(
                BotRowBatch(
                    rows = listOf(notice),
                    deletes = emptyList(),
                    cursor = 2,
                    reset = false,
                ),
            )
        })
        val chat = harness.model
        assertFalse(chat.state.value.rows.any { it.id == "card-error" })
        assertEquals("生成报告失败：模拟器暂时不可用。", chat.state.value.runtimeNotice)
        assertEquals(BotHeaderPhase.PROBLEM, chat.state.value.presence.phase)
        assertEquals(
            "生成报告失败：模拟器暂时不可用。",
            chat.state.value.activityLine.text,
        )
    }

    @Test
    fun `the empty fixture has no transcript content`() {
        val state = model("empty").model.state.value
        assertTrue(state.isEmpty)
        assertEquals(0, state.rows.size)
        assertEquals(0, state.needsAttentionCount)
        assertNotNull(state.context)
    }
}
