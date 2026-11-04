// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.nav.PdshActionAvailability
import com.phonedsh.ui.nav.PdshUnavailableReason
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.ManagedQueueItemState
import com.phonedsh.ui.state.QueueItemId
import com.phonedsh.ui.state.QueueItemStatus
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.state.ChatLocalState
import com.phonedsh.ui.state.ChatHostFacts
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.state.EngineLifecycleFacts
import com.phonedsh.ui.state.PendingQuestionItem
import com.phonedsh.ui.state.PendingQuestionOption
import com.phonedsh.ui.state.PendingSlot
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.state.string
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiType
import com.phonedsh.ui.surface.composer.ComposerAvailability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w430dp-h932dp")
class ChatComposerIntegrationTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun `composer is shown while routes with default no-op callbacks stay unavailable`() {
        show()
        compose.onNodeWithTag(UiTags.COMPOSER).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.COMPOSER_ADD).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.COMPOSER_ACCESS_MODE).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.COMPOSER_MODEL_MENU).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.COMPOSER_ADD).performClick()
        compose.onNodeWithText(UiStrings.COMPOSER_ADD_COMMAND).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.COMPOSER_ADD_REFERENCE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.COMPOSER_ADD_IMAGE).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.COMPOSER_ADD_FILE).assertDoesNotExist()
        compose.onNodeWithText("朗读最近回复").assertDoesNotExist()
    }

    @Test
    fun `host explicitly enables image import and receives the selected action`() {
        var images = 0
        var spoken = 0
        show(
            availability = ComposerAvailability(addImages = true, speakRecentReply = true),
            onAddImages = { images += 1 },
            onSpeakRecentReply = { spoken += 1 },
        )
        compose.onNodeWithTag(UiPageTags.COMPOSER_ADD).performClick()
        compose.onNodeWithText(UiStrings.COMPOSER_ADD_IMAGE).assertIsDisplayed().performClick()
        assertEquals(1, images)
        compose.onNodeWithTag(UiPageTags.COMPOSER_ADD).performClick()
        compose.onNodeWithText("朗读最近回复").assertIsDisplayed().performClick()
        assertEquals(1, spoken)
    }

    @Test
    fun `multi question answers remain through paging and submit as one batch when host route is available`() {
        val base = ChatScreenState.from(listOf(questionNode("q-multi", available = true)))
        val pending = requireNotNull(base.pending.primary).copy(
            questionItems = listOf(
                PendingQuestionItem("goal", prompt = "选择目标", options = listOf(PendingQuestionOption("目标 A"))),
                PendingQuestionItem("notes", prompt = "补充说明"),
            ),
        )
        var answer: String? = null
        show(
            state = base.copy(pending = PendingSlot(primary = pending)),
            availability = ComposerAvailability(answerQuestions = true, dismissQuestions = true),
            onSubmitAnswer = { _, json -> answer = json },
        )
        compose.onNodeWithText("目标 A").performClick()
        compose.onNodeWithText("下一题").performClick()
        compose.onNodeWithText("跳过").performClick()
        assertEquals("""{"goal":["目标 A"],"notes":[]}""", answer)
    }

    @Test
    fun `plan review routes require explicit plan capabilities`() {
        val base = ChatScreenState.from(listOf(questionNode("q-plan", available = true)))
        val pending = requireNotNull(base.pending.primary).copy(
            questionItems = listOf(
                PendingQuestionItem(
                    id = "review",
                    prompt = "审阅计划",
                    detail = "# 整理资料\n\n归档来源文件",
                    intentKind = "plan-review",
                    approveWireLabel = "approve",
                ),
            ),
        )
        var answer: String? = null
        show(
            state = base.copy(pending = PendingSlot(primary = pending)),
            availability = ComposerAvailability(approvePlans = true, requestPlanChanges = true),
            onSubmitAnswer = { _, json -> answer = json },
        )
        compose.onNodeWithTag("pdsh.chat.plan-review-approve").performClick()
        assertEquals("""{"review":["approve"]}""", answer)
    }

    @Test
    fun `an active turn can stop while queue send is unavailable and preserves its draft`() {
        val nodes = SpecFixtures.projectCase("chat-basic").filterNot { node ->
            node.kind == UiStateKind.STATUS && node.props.string("reason") != null
        }
        val state = ChatScreenState.from(
            nodes,
            local = ChatLocalState(draft = "retry this"),
            host = ChatHostFacts(engineStarted = true),
        )
        var stopped = 0
        show(state = state, onStop = { stopped += 1 })
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).performClick()
        assertEquals(1, stopped)
        compose.onNodeWithTag(UiTags.COMPOSER_FIELD).assertTextEquals("retry this")
    }

    @Test
    fun `queued messages retain their visible count and retry invokes the host`() {
        val nodes = SpecFixtures.projectCase("chat-basic")
        val queued = ChatScreenState.from(
            nodes,
            host = ChatHostFacts(
                engineStarted = true,
                queueItems = listOf(
                    ManagedQueueItemState(QueueItemId.Durable("queue-one"), "first queued message", QueueItemStatus.QUEUED),
                    ManagedQueueItemState(QueueItemId.Durable("queue-two"), "second queued message", QueueItemStatus.QUEUED),
                ),
            ),
        )
        show(state = queued)
        compose.onNodeWithTag(UiTags.COMPOSER_QUEUE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CHAT_QUEUE_HEADER_COUNT.format(2)).assertIsDisplayed().performClick()
        compose.onNodeWithText("first queued message").assertIsDisplayed()
        compose.onNodeWithText("second queued message").assertIsDisplayed()
    }

    @Test
    fun `failure banner retry invokes the host route`() {
        var retried = 0
        val failed = ChatScreenState.from(SpecFixtures.projectCase("turn-error-vs-complete"))
        show(state = failed, onRetry = { retried += 1 })
        compose.onNodeWithTag(UiTags.BANNER_RETRY).performClick()
        assertEquals(1, retried)
    }

    @Test
    @OptIn(ExperimentalTestApi::class)
    fun `long model label stays clear of both running action buttons at 430pt`() {
        val model = "deepseek-very-long-custom-model-name-with-reasoning-profile"
        val nodes = SpecFixtures.projectCase("chat-basic").filterNot { node ->
            node.kind == UiStateKind.STATUS && node.props.string("reason") != null
        }
        val state = ChatScreenState.from(
            nodes,
            local = ChatLocalState(draft = "continue"),
            host = ChatHostFacts(
                engineStarted = true,
                canSend = true,
                canSteer = true,
                models = listOf(model),
                currentModel = model,
            ),
        )
        show(state = state, availability = ComposerAvailability(selectModel = true), onStop = {})
        val modelBounds = compose.onNodeWithTag(UiPageTags.COMPOSER_MODEL_MENU).getUnclippedBoundsInRoot()
        val stopBounds = compose.onNodeWithTag("pdsh.composer.stop-circle", useUnmergedTree = true).getUnclippedBoundsInRoot()
        val sendBounds = compose.onNodeWithTag("pdsh.composer.send-circle", useUnmergedTree = true).getUnclippedBoundsInRoot()
        val cardBounds = compose.onNodeWithTag("pdsh.composer.card").getUnclippedBoundsInRoot()
        assertEquals("model to painted stop circle", 8f, (stopBounds.left - modelBounds.right).value, 0.1f)
        assertEquals("painted action circles", 8f, (sendBounds.left - stopBounds.right).value, 0.1f)
        assertEquals("painted send to card edge", 8f, (cardBounds.right - sendBounds.right).value, 0.1f)
    }

    @Test
    fun `composer and model use fixed body typography despite larger message preference role`() {
        val sourceType = UiType.fromSpec()
        val preferredMessageType = sourceType.copy(
            homeBody = sourceType.homeBody.copy(fontSize = 22.sp, lineHeight = 28.sp),
        )
        val model = "deepseek-v4"
        val state = ChatScreenState.from(
            emptyList(),
            local = ChatLocalState(draft = "compose"),
            host = ChatHostFacts(
                engineStarted = true,
                models = listOf(model),
                currentModel = model,
                lifecycle = EngineLifecycleFacts(canStartBySending = true),
            ),
        )
        show(
            state = state,
            availability = ComposerAvailability(selectModel = true),
            uiType = preferredMessageType,
        )
        val composerStyle = textStyle(UiTags.COMPOSER_FIELD)
        val modelStyle = textStyle("pdsh.composer.model-label")
        assertEquals(16f, composerStyle.fontSize.value, 0f)
        assertEquals(24f, composerStyle.lineHeight.value, 0f)
        assertEquals(16f, modelStyle.fontSize.value, 0f)
        assertEquals(24f, modelStyle.lineHeight.value, 0f)
    }

    private fun show(
        state: ChatScreenState = ChatScreenState.from(emptyList(), host = ChatHostFacts(engineStarted = true, lifecycle = EngineLifecycleFacts(canStartBySending = true))),
        availability: ComposerAvailability = ComposerAvailability(),
        onAddImages: () -> Unit = {},
        onSpeakRecentReply: (() -> Unit)? = null,
        uiType: UiType? = null,
        onSubmitAnswer: (com.phonedsh.ui.state.PendingAnswer, String) -> Unit = { _, _ -> },
        onStop: (() -> Unit)? = null,
        onRetry: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                val page: @Composable () -> Unit = { ChatPage(
                    state = state,
                    onDraftChange = {},
                    onSend = {},
                    onStop = onStop ?: {},
                    onToggleRow = {},
                    onApprove = {},
                    onDeny = {},
                    onDismissBanner = {},
                    onRetry = onRetry ?: {},
                    stopAvailability = onStop?.let { stop ->
                        PdshActionAvailability.Available { _: StateRequestId -> stop() }
                    } ?: PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
                    timelineRetryAvailability = onRetry?.let { retry ->
                        PdshActionAvailability.Available { retry() }
                    } ?: PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
                    planApproveAvailability = if (availability.approvePlans) {
                        PdshActionAvailability.Available { ask, json -> onSubmitAnswer(ask, json) }
                    } else PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED),
                    onOpenSessions = {},
                    onAddImages = onAddImages,
                    onSpeakRecentReply = onSpeakRecentReply,
                    onSubmitAnswer = onSubmitAnswer,
                    composerAvailability = availability,
                ) }
                if (uiType == null) page() else CompositionLocalProvider(LocalUiType provides uiType) { page() }
            }
        }
    }

    private fun textStyle(tag: String): androidx.compose.ui.text.TextStyle {
        val layouts = mutableListOf<TextLayoutResult>()
        val node = compose.onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode()
        node.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(layouts)
        require(layouts.size == 1) { "Expected one laid-out text for $tag, got ${layouts.size}" }
        return layouts.single().layoutInput.style
    }

    private fun questionNode(requestId: String, available: Boolean): UiStateNode = UiStateNode(
        kind = UiStateKind.APPROVAL_CARD,
        nodeID = "session/s1/turn/t1/question-$requestId",
        parentID = "session/s1/turn/t1",
        sessionID = "s1",
        turnID = "t1",
        seq = 1,
        text = "回答问题",
        props = JsonObject(
            mapOf(
                "kind" to JsonString("question"),
                "requestId" to JsonString(requestId),
                "channelAvailable" to JsonBool(available),
                "options" to JsonArray(listOf(JsonString("选项 A"))),
            ),
        ),
    )
}
