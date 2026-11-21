// SPDX-License-Identifier: MIT
//
// iOS `Bot/BotNextStepsMetrics.swift` parity: which finished turns count, and the
// trailing option-list rule (ported verbatim, including its numbered-item quirk).
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.rows.BotRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BotNextStepsMetricsTest {

    private fun text(id: String, role: String, value: String): BotRow =
        BotUiStateFixtures.rowForBody(
            BotJson.objectOf("type" to JsonString("text"), "text" to JsonString(value)), id,
        ).copy(role = role)

    private fun stepsCard(id: String): BotRow =
        BotUiStateFixtures.rowForBody(
            BotJson.objectOf("type" to JsonString("widget"), "cardType" to JsonString("steps")), id,
        ).copy(role = "assistant")

    private val options = "可以这样继续：\n- 看一下日程\n- 写一封邮件\n- 先休息"

    @Test
    fun `a trailing 2-4 item bullet list counts and anything else does not`() {
        assertTrue(BotNextStepsMetrics.endsWithOptionList(options))
        assertTrue(BotNextStepsMetrics.endsWithOptionList("说明\n* 甲方案\n* 乙方案\n"))
        assertFalse("one item", BotNextStepsMetrics.endsWithOptionList("说明\n- 只有一个"))
        assertFalse("five items", BotNextStepsMetrics.endsWithOptionList("说明\n- 一一\n- 二二\n- 三三\n- 四四\n- 五五"))
        assertFalse("no prose before the list", BotNextStepsMetrics.endsWithOptionList("- 一一\n- 二二"))
        assertFalse("list in the middle", BotNextStepsMetrics.endsWithOptionList("- 一一\n- 二二\n结尾一句话"))
        assertFalse("items need two characters", BotNextStepsMetrics.endsWithOptionList("说明\n- a\n- b"))
    }

    @Test
    fun `numbered items follow the iOS rule exactly`() {
        // iOS takes the first two characters as the number: `10. ` matches, `1. ` does not.
        assertTrue(BotNextStepsMetrics.endsWithOptionList("说明\n10. 第一项\n11. 第二项"))
        assertFalse(BotNextStepsMetrics.endsWithOptionList("说明\n1. 第一项\n2. 第二项"))
    }

    @Test
    fun `only eligible turns are counted, and a steps card marks the turn used`() {
        val metrics = BotNextStepsMetrics(InMemoryBotNextStepsCountStore())
        metrics.recordTurn(listOf(text("u1", "user", "你好"), text("a1", "assistant", "就这样。")))
        assertEquals(BotNextStepsMetrics.Snapshot(0, 0), metrics.snapshot())

        metrics.recordTurn(listOf(text("u2", "user", "然后？"), text("a2", "assistant", options)))
        metrics.recordTurn(listOf(text("u3", "user", "再来"), text("a3", "assistant", options), stepsCard("c3")))
        val snapshot = metrics.snapshot()
        assertEquals(2, snapshot.turnsWithOptions)
        assertEquals(1, snapshot.turnsWithStepsCard)
        assertEquals(0.5, snapshot.usageRate, 1e-9)

        metrics.clear()
        assertEquals(BotNextStepsMetrics.Snapshot(0, 0), metrics.snapshot())
    }

    @Test
    fun `a card on a turn without prose options is not counted`() {
        val metrics = BotNextStepsMetrics(InMemoryBotNextStepsCountStore())
        metrics.recordTurn(listOf(text("u", "user", "?"), text("a", "assistant", "好的。"), stepsCard("c")))
        assertEquals(BotNextStepsMetrics.Snapshot(0, 0), metrics.snapshot())
    }
}
