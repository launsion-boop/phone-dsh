// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

// Compose UI tests for every P0 card and the header/empty states. The rows come
// from the shared fixture export (`spec/ui/v1/bot/golden/fixtures.json`) through
// the real model and K3 derivations; no test builds a look-alike card.
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotApprovalDecision
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotUserActionKind
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.bot.driver.BotChatModel
import com.phonedsh.ui.bot.driver.FixtureBotChatDriver
import com.phonedsh.ui.bot.page.BotFishSlot
import com.phonedsh.ui.bot.state.BotUiContext
import com.phonedsh.ui.theme.PdshTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class BotChatPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val fixtures = SpecFixtures.repoJson("spec/ui/v1/bot/golden/fixtures.json")
    private val now = 1_760_000_000_000L

    private val fish: BotFishSlot = { _, _, crowned, size, _, modifier ->
        Box(
            modifier
                .size(size)
                .testTag(if (crowned) "test.fish.crowned" else "test.fish"),
        )
    }

    private class Harness(
        val model: BotChatModel,
        val driver: FixtureBotChatDriver,
        val documents: MutableList<BotRow>,
        val paths: MutableList<String>,
        val urls: MutableList<String>,
    )

    private fun harness(
        scenario: String,
        results: List<BotActionResult> = emptyList(),
        approvalScope: String? = null,
    ): Harness {
        val driver = FixtureBotChatDriver.fromJson(
            fixtures = approvalScope?.let(::fixturesWithApprovalScope) ?: fixtures,
            scenario = scenario,
            actionResults = results,
        )
        val model = BotChatModel(
            context = BotUiContext(botID = "main", botName = "主 Bot"),
            driver = driver,
            clock = { now },
            scope = CoroutineScope(Dispatchers.Unconfined),
            isMainBot = true,
        )
        model.start()
        return Harness(model, driver, mutableListOf(), mutableListOf(), mutableListOf())
    }

    private fun fixturesWithApprovalScope(scope: String): JsonObject {
        val exported = fixtures.members["exported"] as JsonArray
        val rows = exported.values.map { scenarioValue ->
            val scenario = scenarioValue as JsonObject
            if (scenario.members["scenario"] != JsonString("approval")) return@map scenarioValue
            val scenarioMembers = LinkedHashMap(scenario.members)
            val rowValues = (scenario.members["rows"] as JsonArray).values.map { rowValue ->
                val row = rowValue as JsonObject
                val rowMembers = LinkedHashMap(row.members)
                val body = row.members["body"] as JsonObject
                rowMembers["body"] = JsonObject(LinkedHashMap(body.members).apply {
                    this["alwaysScope"] = JsonString(scope)
                })
                JsonObject(rowMembers)
            }
            scenarioMembers["rows"] = JsonArray(rowValues)
            JsonObject(scenarioMembers)
        }
        return JsonObject(LinkedHashMap(fixtures.members).apply { this["exported"] = JsonArray(rows) })
    }

    private fun fixturesWithDocumentFallback(): JsonObject {
        val exported = fixtures.members["exported"] as JsonArray
        val rows = exported.values.map { scenarioValue ->
            val scenario = scenarioValue as JsonObject
            if (scenario.members["scenario"] != JsonString("document")) return@map scenarioValue
            val scenarioMembers = LinkedHashMap(scenario.members)
            val rowValues = (scenario.members["rows"] as JsonArray).values.map { rowValue ->
                val row = rowValue as JsonObject
                val rowMembers = LinkedHashMap(row.members)
                val body = row.members["body"] as JsonObject
                rowMembers["body"] = JsonObject(LinkedHashMap(body.members).apply {
                    remove("content")
                    remove("summary")
                    remove("toc")
                    remove("docTypeLabel")
                    this["docKind"] = JsonString("unknown")
                    this["fileName"] = JsonString("unknown-format.bin")
                })
                JsonObject(rowMembers)
            }
            scenarioMembers["rows"] = JsonArray(rowValues)
            JsonObject(scenarioMembers)
        }
        return JsonObject(LinkedHashMap(fixtures.members).apply { this["exported"] = JsonArray(rows) })
    }

    private fun show(
        harness: Harness,
        onDrawer: () -> Unit = {},
        onInfo: () -> Unit = {},
    ) {
        val model = harness.model
        compose.setContent {
            PdshTheme(darkTheme = false) {
                WithBotPageActive(true) {
                    val state by model.state.collectAsState()
                    BotChatPage(
                        state = state,
                        fish = fish,
                        onDraftChange = model::setDraft,
                        onSend = model::send,
                        onStop = model::stop,
                        onAnswer = model::answer,
                        onDismiss = model::dismiss,
                        onApproval = model::decide,
                        onChecklistProgress = model::noteChecklistProgress,
                        onChecklistSend = model::sendChecklist,
                        onLoadHistory = model::loadHistory,
                        onTick = { model.tick() },
                        onInteraction = model::noteInteraction,
                        onOpenInfo = onInfo,
                        onConnectDevice = {},
                        onAttach = {},
                        onRemoveAttachment = model::removeDraftAttachment,
                        onDismissAttachmentNotice = model::dismissAttachmentNotice,
                        onOpenDrawer = onDrawer,
                        onOpenDocument = { harness.documents.add(it) },
                        onOpenPath = { harness.paths.add(it) },
                        onOpenUrl = { harness.urls.add(it) },
                    )
                }
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `question card renders and an answer emits cardAnswer`() {
        val harness = harness("question")
        show(harness)
        compose.onNodeWithText("要把这份整理好的内容保存到哪里？").assertIsDisplayed()
        compose.onNodeWithText("建议").assertIsDisplayed()
        compose.onNodeWithTag(BotChatTags.choiceOption("library")).performClick()
        compose.waitForIdle()
        val action = harness.driver.performed.single()
        assertEquals(BotUserActionKind.CARD_ANSWER, action.kind)
        assertEquals("library", action.optionID)
        compose.onNodeWithTag(BotChatTags.CARD_SETTLED).assertIsDisplayed()
        compose.onAllNodes(hasTestTag(BotChatTags.choiceOption("library"))).assertCountEquals(0)
    }

    @Test
    fun `steps card has no dismiss control`() {
        val harness = harness("steps")
        show(harness)
        compose.onNodeWithText("查看验收结果").assertIsDisplayed()
        compose.onAllNodes(hasTestTag(BotChatTags.CHOICE_DISMISS)).assertCountEquals(0)
        compose.onNodeWithTag(BotChatTags.choiceOption("pr")).performClick()
        compose.waitForIdle()
        assertEquals("pr", harness.driver.performed.single().optionID)
    }

    @Test
    fun `question dismiss emits cardDismiss`() {
        val harness = harness("question")
        show(harness)
        compose.onNodeWithTag(BotChatTags.CHOICE_DISMISS).performClick()
        compose.waitForIdle()
        assertEquals(BotUserActionKind.CARD_DISMISS, harness.driver.performed.single().kind)
        compose.onNodeWithTag(BotChatTags.CARD_SETTLED).assertIsDisplayed()
        compose.onNodeWithText("已关闭", substring = true).assertExists()
    }

    @Test
    fun `task card renders its running tag and folds its steps`() {
        val harness = harness("task")
        show(harness)
        compose.onNodeWithText("整理并验证发布材料").assertIsDisplayed()
        compose.onNodeWithText("进行中").assertIsDisplayed()
        compose.onAllNodes(hasTestTag(BotChatTags.TASK_VERIFICATION)).assertCountEquals(0)
        compose.onNodeWithTag(BotChatTags.TASK_TOGGLE).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(BotChatTags.TASK_STEPS).assertIsDisplayed()
        compose.onNodeWithText("运行验证").assertIsDisplayed()
    }

    @Test
    fun `attachment card opens its path`() {
        val harness = harness("attachment")
        show(harness)
        compose.onNodeWithText("phone-dsh-report.pdf").assertIsDisplayed()
        compose.onNodeWithText("暂无内容预览").assertIsDisplayed()
        compose.onNodeWithText("PDF").assertIsDisplayed()
        compose.onNodeWithTag(BotChatTags.ATTACHMENT_OPEN).performClick()
        compose.waitForIdle()
        assertEquals(listOf("/tmp/phone-dsh-report.pdf"), harness.paths)
    }

    @Test
    fun `document card opens the row and lists its contents`() {
        val harness = harness("document")
        show(harness)
        compose.onNodeWithText("phoneDSH Bot 验收报告").assertIsDisplayed()
        compose.onNodeWithText("Markdown").assertIsDisplayed()
        compose.onNodeWithText("18 kB").assertIsDisplayed()
        compose.onNodeWithText("Steering", substring = true).assertIsDisplayed()
        compose.onNodeWithTag(BotChatTags.DOCUMENT_OPEN).performClick()
        compose.waitForIdle()
        assertEquals(listOf("card-document"), harness.documents.map { it.id })
    }

    @Test
    fun `document fallback uses truthful missing content and unknown type labels`() {
        val driver = FixtureBotChatDriver.fromJson(fixturesWithDocumentFallback(), scenario = "document")
        val model = BotChatModel(
            context = BotUiContext(botID = "main", botName = "主 Bot"),
            driver = driver,
            clock = { now },
            scope = CoroutineScope(Dispatchers.Unconfined),
            isMainBot = true,
        )
        model.start()
        val harness = Harness(model, driver, mutableListOf(), mutableListOf(), mutableListOf())
        show(harness)
        compose.onNodeWithText("暂无内容预览").assertIsDisplayed()
        compose.onNodeWithText("unknown-format.bin").assertIsDisplayed()
        compose.onNodeWithText("文档").assertIsDisplayed()
        compose.onNodeWithTag(BotChatTags.DOCUMENT_OPEN).performClick()
        compose.waitForIdle()
        assertEquals(listOf("card-document"), harness.documents.map { it.id })
    }

    @Test
    fun `progress card shows its percent and expands past four steps`() {
        val harness = harness("progress")
        show(harness)
        compose.onNodeWithText("42%").assertIsDisplayed()
        compose.onNodeWithTag(BotChatTags.PROGRESS_MORE).performClick()
        compose.waitForIdle()
        compose.onNodeWithText("创建 PR").assertIsDisplayed()
    }

    @Test
    fun `checklist toggles and sends its result as a chat action`() {
        val harness = harness("checklist")
        show(harness)
        compose.onNodeWithTag(BotChatTags.checklistItem("c2")).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(BotChatTags.CHECKLIST_SEND).performClick()
        compose.waitForIdle()
        val action = harness.driver.performed.single()
        assertEquals(BotUserActionKind.CHAT, action.kind)
        assertTrue(action.text.orEmpty().contains("发布前检查"))
        compose.onNodeWithTag(BotChatTags.CARD_SETTLED).assertIsDisplayed()
    }

    @Test
    fun `link card opens only the link's url`() {
        val harness = harness("link")
        show(harness)
        compose.onNodeWithTag(BotChatTags.linkOpen("docs")).performClick()
        compose.waitForIdle()
        assertEquals(listOf("https://example.test/docs/cards"), harness.urls)
    }

    @Test
    fun `approval card emits allow once with the digest`() {
        val harness = harness("approval")
        show(harness)
        compose.onNodeWithText("rm -f /tmp/phone-dsh-old-report.pdf").assertIsDisplayed()
        compose.onNodeWithTag(BotChatTags.APPROVAL_ONCE).performClick()
        compose.waitForIdle()
        val action = harness.driver.performed.single()
        assertEquals(BotUserActionKind.APPROVAL, action.kind)
        assertEquals("approval-fixture", action.approvalID)
        assertEquals("sha256:fixture", action.digest)
    }

    @Test
    fun `session approval labels its scope and emits the existing always decision`() {
        val harness = harness("approval", approvalScope = "session")
        show(harness)
        compose.onNodeWithText("始终允许仅对本次对话有效。").assertIsDisplayed()
        compose.onNodeWithTag(BotChatTags.APPROVAL_ALWAYS).performClick()
        compose.waitForIdle()
        assertEquals(BotApprovalDecision.ALWAYS, harness.driver.performed.single().decision)
    }

    @Test
    fun `none approval disables continuous authorization`() {
        val harness = harness("approval", approvalScope = "none")
        show(harness)
        compose.onNodeWithText("此操作不支持持续授权，仅可允许一次或拒绝。").assertIsDisplayed()
        compose.onNodeWithTag(BotChatTags.APPROVAL_ALWAYS).assertIsNotEnabled().performClick()
        compose.waitForIdle()
        assertTrue(harness.driver.performed.isEmpty())
    }

    @Test
    fun `automation routine run card renders its schedule and result`() {
        val harness = harness("automation")
        show(harness)
        compose.onNodeWithTag(BotChatTags.CARD_AUTOMATION).assertIsDisplayed()
        compose.onNodeWithText("晨间简报").assertIsDisplayed()
        compose.onNodeWithText("已完成").assertIsDisplayed()
        compose.onNodeWithText("上海时间（UTC+8）", substring = true).assertIsDisplayed()
        compose.onNodeWithText("已整理 3 项需要你处理的工作。").assertIsDisplayed()
    }

    @Test
    fun `error and denial notices never enter the transcript`() {
        val error = harness("error")
        show(error)
        compose.onNodeWithTag(BotChatTags.EMPTY).assertIsDisplayed()
        compose.onAllNodes(hasTestTag(BotChatTags.CARD_NOTICE)).assertCountEquals(0)
    }

    @Test
    fun `empty state names the Bot and draws the fish`() {
        val harness = harness("empty")
        show(harness)
        compose.onNodeWithTag(BotChatTags.EMPTY).assertIsDisplayed()
        compose.onNodeWithText("嗨，我是 主 Bot").assertIsDisplayed()
        compose.onAllNodesWithTag("test.fish.crowned", useUnmergedTree = true).assertCountEquals(2)
    }

    @Test
    fun `a pending approval holds the header on waiting for you`() {
        val harness = harness("approval")
        show(harness)
        compose.onNodeWithTag(BotChatTags.ACTIVITY_LINE).assertIsDisplayed()
        compose.onNodeWithText("等你确认").assertIsDisplayed()
    }

    @Test
    fun `a problem and then a running turn drive the activity line`() {
        val harness = harness("chat")
        show(harness)
        compose.onAllNodes(hasTestTag(BotChatTags.ACTIVITY_LINE)).assertCountEquals(0)
        harness.model.beginTurn("turn-1")
        compose.waitForIdle()
        compose.onNodeWithText("思考中…").assertIsDisplayed()
        harness.model.showProblem("实时更新失败：断线")
        harness.model.tick(now + com.phonedsh.ui.bot.state.BotTimers.ACTIVITY_MIN_VISIBLE)
        compose.waitForIdle()
        compose.onNodeWithText("实时更新失败：断线").assertIsDisplayed()
    }

    @Test
    fun `composer sends the draft and draws the local echo`() {
        val harness = harness("empty")
        show(harness)
        harness.model.setDraft("你好")
        compose.waitForIdle()
        compose.onNodeWithTag(BotChatTags.COMPOSER_SEND).performClick()
        compose.waitForIdle()
        val action = harness.driver.performed.single()
        assertEquals(BotUserActionKind.CHAT, action.kind)
        assertEquals("你好", action.text)
        compose.onNodeWithText("你好").assertIsDisplayed()
    }

    @Test
    fun `running with an empty draft turns the send key into stop`() {
        val harness = harness("chat")
        show(harness)
        harness.model.beginTurn("turn-1")
        compose.waitForIdle()
        compose.onNodeWithTag(BotChatTags.COMPOSER_STOP).performClick()
        compose.waitForIdle()
        assertEquals(listOf("turn-1"), harness.driver.stopCalls)
    }

    @Test
    fun `user attachments render their compact cards`() {
        val harness = harness("composerAttachments")
        show(harness)
        compose.onAllNodesWithTag(BotChatTags.MESSAGE_ATTACHMENT, useUnmergedTree = true).assertCountEquals(2)
        compose.onNodeWithText("周报.pdf").assertIsDisplayed()
    }

    @Test
    fun `agent comm rows collapse to one line with the peer identity`() {
        val harness = harness("agentComm")
        show(harness)
        compose.onAllNodesWithTag(BotChatTags.AGENT_COMM_ROW).assertCountEquals(2)
        compose.onNodeWithText("小海 回复").assertIsDisplayed()
        compose.onNodeWithText("已传消息给 小海").assertIsDisplayed()
    }

    @Test
    fun `header controls call the drawer and info callbacks`() {
        var drawer = 0
        var info = 0
        val harness = harness("empty")
        show(harness, onDrawer = { drawer++ }, onInfo = { info++ })
        compose.onNodeWithTag(BotChatTags.DRAWER_OPEN).performClick()
        compose.onNodeWithTag(BotChatTags.INFO_OPEN).performClick()
        compose.runOnIdle {
            assertEquals(1, drawer)
            assertEquals(1, info)
        }
    }

    @Test
    fun `the header menu carries the following and attention summary`() {
        val harness = harness("question")
        show(harness)
        compose.onNodeWithTag(BotChatTags.HEADER_MENU).performClick()
        compose.waitForIdle()
        compose.onNodeWithText("跟进中 0 · 需要你处理 1").assertIsDisplayed()
    }
}
