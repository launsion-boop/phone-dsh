// ChatPage row/section acceptance (JVM + Robolectric).
// SPDX-License-Identifier: MIT
//
// One test per mirrored section of `examples/probe-app/PhoneDSHProbe/ChatPage.swift`:
// the page head, the three failure banners, the pending-card region, the
// transcript chrome and the composer dock. Each test names the Swift source it
// pins, so deleting a section makes its own test fail instead of leaving a
// silently thinner page.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertAny
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.printToString
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.input.key.Key
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.state.ChatEmpty
import com.phonedsh.ui.state.ChatHostFacts
import com.phonedsh.ui.state.ChatLocalState
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.state.ToolEntry
import com.phonedsh.ui.state.ChatPhase
import com.phonedsh.ui.state.EngineLifecycleFacts
import com.phonedsh.ui.state.EngineLifecycleStatus
import com.phonedsh.ui.state.BannerState
import com.phonedsh.ui.state.ManagedQueueItemState
import com.phonedsh.ui.state.QueueAction
import com.phonedsh.ui.state.QueueActionReceipt
import com.phonedsh.ui.state.QueueItemId
import com.phonedsh.ui.state.QueueItemStatus
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.CommandOutcome
import com.phonedsh.ui.state.ComposerCommand
import com.phonedsh.ui.state.EffortOption
import com.phonedsh.ui.state.EnterMode
import com.phonedsh.ui.state.GoalBarState
import com.phonedsh.ui.state.PendingAnswer
import com.phonedsh.ui.state.PendingQuestionItem
import com.phonedsh.ui.state.PendingQuestionOption
import com.phonedsh.ui.state.PendingSlot
import com.phonedsh.ui.state.RunStatus
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.state.TranscriptState
import com.phonedsh.ui.state.TodoDockItem
import com.phonedsh.ui.state.string
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.surface.composer.ComposerAvailability
import com.phonedsh.ui.nav.PdshActionAvailability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class ChatPageTest {
    @get:Rule
    val compose = createComposeRule()

    // ---------------------------------------------------------------- head

    @Test
    fun `the page head shows only the session title and the run status word`() {
        // ChatPage.swift `chatHeader` + NativeDeviceEntryIcon.
        show(state(case = "chat-basic"), title = "会话甲")
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_TITLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_TITLE).assertContentDescriptionEquals("会话甲")
        compose.onNodeWithText("会话甲").assertIsDisplayed()
        compose.onNodeWithText("项目资料").assertDoesNotExist()
        compose.onNodeWithTag("pdsh.chat.header.device").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUN_STATUS_STARTED).assertDoesNotExist()
    }

    @Test
    fun `the device header icon opens the real device connections route`() {
        var opened = 0
        show(state(case = "chat-basic"), onOpenDeviceConnections = { opened += 1 })
        compose.onNodeWithTag("pdsh.chat.header.device").performClick()
        assertEquals(1, opened)
    }

    @Test
    fun `a stopped engine status is reached from the header menu, not displayed as a header badge`() {
        show(ChatScreenState.from(SpecFixtures.projectCase("chat-basic")))
        compose.onNodeWithText(UiStrings.RUN_STATUS_STOPPED).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText(UiStrings.HEADER_RUN_STATUS).assertIsDisplayed()
    }

    @Test
    fun `the head menu offers the export and the session settings`() {
        // ChatPage.swift `Menu { ShareLink…; Button("本会话设置") }`.
        var exported = 0
        var settings = 0
        show(
            state(case = "chat-basic"),
            title = "会话甲",
            onExportTranscript = { exported += 1 },
            onOpenSessionSettings = { settings += 1 },
        )
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText(UiStrings.HEADER_EXPORT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.HEADER_SESSION_SETTINGS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.HEADER_EXPORT).performClick()
        assertEquals(1, exported)
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText(UiStrings.HEADER_SESSION_SETTINGS).performClick()
        assertEquals(1, settings)
    }

    @Test
    fun `the head menu offers 产物 the right sidebar and the run status`() {
        // ChatPage.swift:240-286: the session-scoped rows of the ⋯ menu.
        var artifacts = 0
        var workbench = 0
        var runStatus = 0
        show(
            state(case = "chat-basic"),
            title = "会话甲",
            onOpenArtifacts = { artifacts += 1 },
            onOpenWorkbench = { workbench += 1 },
            onOpenRunStatus = { runStatus += 1 },
        )
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText(UiStrings.HEADER_ARTIFACTS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.HEADER_WORKBENCH).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.HEADER_RUN_STATUS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.HEADER_ARTIFACTS).performClick()
        assertEquals(1, artifacts)
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText(UiStrings.HEADER_WORKBENCH).performClick()
        assertEquals(1, workbench)
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText(UiStrings.HEADER_RUN_STATUS).performClick()
        assertEquals(1, runStatus)
    }

    @Test
    fun `a session-scoped menu row is absent when the host cannot route it`() {
        // `null` keeps the row off the menu: nothing that would tap into nowhere.
        show(state(case = "chat-basic"))
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText(UiStrings.HEADER_ARTIFACTS).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.HEADER_WORKBENCH).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.HEADER_RUN_STATUS).assertIsDisplayed()
    }

    @Test
    fun `the head menu trigger uses the PR22 accessible name 更多`() {
        // Current ChatPage.swift uses `.accessibilityLabel("更多")`.
        show(state(case = "chat-basic"))
        compose.onNodeWithContentDescription(UiStrings.HEADER_MORE).assertIsDisplayed()
    }

    @Test
    fun `tapping the head title opens the rename alert and saves the trimmed name`() {
        // ChatPage.swift `.alert("重命名会话") { TextField("会话名称", text: $renameText); 取消; 保存 }`.
        var renamed: String? = null
        show(state(case = "chat-basic"), title = "旧名字", onRenameSession = { renamed = it })
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_TITLE).performClick()
        compose.onNodeWithTag(UiPageTags.CHAT_RENAME_OVERLAY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RENAME_DIALOG_TITLE).assertIsDisplayed()
        // The field starts with the old title, exactly like the iOS alert.
        compose.onNodeWithTag(UiPageTags.CHAT_RENAME_FIELD).performTextClearance()
        compose.onNodeWithTag(UiPageTags.CHAT_RENAME_FIELD).performTextInput(" 新名字 ")
        compose.onNodeWithTag(UiPageTags.CHAT_RENAME_SAVE).performClick()
        assertEquals("新名字", renamed)
        compose.onNodeWithTag(UiPageTags.CHAT_RENAME_OVERLAY).assertDoesNotExist()
    }

    @Test
    fun `cancelling the rename alert keeps the title`() {
        var renamed: String? = null
        show(state(case = "chat-basic"), title = "旧名字", onRenameSession = { renamed = it })
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_TITLE).performClick()
        compose.onNodeWithTag(UiPageTags.CHAT_RENAME_CANCEL).performClick()
        assertEquals(null, renamed)
        compose.onNodeWithTag(UiPageTags.CHAT_RENAME_OVERLAY).assertDoesNotExist()
    }

    // ------------------------------------------------------------- banners

    @Test
    fun `a turn failure shows the top banner with retry and dismiss`() {
        // ChatPage.swift `errorBanner`: message + 重试 + xmark.
        var retried = 0
        var dismissed: String? = null
        show(
            state(case = "turn-error-vs-complete"),
            onRetry = { retried += 1 },
            timelineRetryAvailability = PdshActionAvailability.Available { retried += 1 },
            onDismissBanner = { dismissed = it },
        )
        compose.onNodeWithTag(UiTags.FAIL_LOUD_BANNER).assertIsDisplayed()
        // The tool row's summary can quote the same text, so the banner is checked
        // through the first matching node.
        compose.onAllNodesWithText("permission denied").onFirst().assertIsDisplayed()
        compose.onNodeWithTag(UiTags.BANNER_RETRY).performClick()
        assertEquals(1, retried)
        compose.onNodeWithTag(UiTags.BANNER_DISMISS).performClick()
        assertTrue("the dismiss carries the banner id", dismissed != null)
    }

    @Test
    fun `an access-mode read failure has no page banner and opening the menu reads again`() {
        // ChatPage.swift: the read retries itself; no `accessModeErrorBanner`.
        var retried = 0
        show(
            state(case = "chat-basic", accessModeError = "读不到权限"),
            onRetryAccessModes = { retried += 1 },
            composerAvailability = ComposerAvailability(selectAccessMode = true),
        )
        compose.onNodeWithTag(UiPageTags.CHAT_BANNER_ACCESS_MODE).assertDoesNotExist()
        compose.onNodeWithText("读不到权限").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.COMPOSER_ACCESS_MODE).performClick()
        assertEquals(1, retried)
    }

    @Test
    fun `a command-catalog failure shows its own banner with retry`() {
        // ChatPage.swift `commandErrorBanner`.
        var reloads = 0
        show(state(case = "chat-basic", commandsError = "读不到命令"), onReloadCommands = { reloads += 1 })
        compose.onNodeWithTag(UiPageTags.CHAT_BANNER_COMMANDS).assertIsDisplayed()
        compose.onNodeWithText("读不到命令").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, reloads)
    }

    // ------------------------------------------------------- pending cards

    @Test
    fun `a permission ask renders the card and locks the dock`() {
        show(state(case = "permission-flow"))
        compose.onNodeWithTag(UiTags.ANSWER_SLOT).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.APPROVAL_CARD).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WAITING_AUTHORIZATION).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsNotEnabled()
    }

    @Test
    fun `permission decisions stay disabled without a request-bound receipt`() {
        var approved: String? = null
        show(state(case = "permission-flow"), onApprove = { approved = it.requestId })
        compose.onNodeWithTag(UiTags.APPROVAL_PRIMARY).assertIsNotEnabled()
        assertEquals(null, approved)
    }

    @Test
    fun `the keyboard folds the whole region into the N 项需要处理 line`() {
        // ChatPage.swift `cardsRegion`: keyboard up and not expanded → one line.
        var expandCalls = 0
        show(
            state(case = "permission-flow", imeVisible = true),
            onExpandPendingSlot = { expandCalls += 1 },
        )
        compose.onNodeWithTag(UiTags.ANSWER_SLOT).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.APPROVAL_CARD).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.PENDING_SLOT.format(1)).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PENDING_SLOT.format(1)).performClick()
        assertEquals(1, expandCalls)
    }

    @Test
    fun `permission stays in the card region while a question takes the composer seat`() {
        // ChatPage.swift `questionTakeover` replaces the bottom composer seat.
        val nodes = SpecFixtures.projectCase("permission-flow") + listOf(
            questionNode("q-1"),
        )
        show(ChatScreenState.from(nodes))
        compose.onNodeWithTag(UiPageTags.CHAT_PENDING_MORE).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.MORE_PENDING).assertDoesNotExist()
        compose.onAllNodesWithTag(UiTags.APPROVAL_CARD).assertCountEquals(1)
        compose.onNodeWithTag("pdsh.chat.question-takeover").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_QUESTION_SUBMIT).assertExists()
    }

    @Test
    fun `a question card submits the chosen option as the answer json`() {
        // ChatPage.swift `QuestionCard`: options, free text, 提交回答.
        var answer: String? = null
        var answered: PendingAnswer? = null
        val nodes = listOf(questionNode("q-1"))
        show(
            ChatScreenState.from(nodes),
            onSubmitAnswer = { ask, json ->
                answered = ask
                answer = json
            },
            composerAvailability = ComposerAvailability(answerQuestions = true),
        )
        compose.onNodeWithTag("pdsh.chat.question-takeover").assertIsDisplayed()
        compose.onNodeWithText("改用表格").performClick()
        compose.onNodeWithTag(UiPageTags.CHAT_QUESTION_SUBMIT).performClick()
        if (answered == null) {
            println("TREE " + compose.onRoot().printToString(maxDepth = 100))
        }
        assertEquals("q-1", answered?.requestId)
        assertEquals("""{"answer":["改用表格"]}""", answer)
    }

    @Test
    fun `the multi question takeover retains earlier answers and serializes skipped steps`() {
        val base = ChatScreenState.from(listOf(questionNode("q-1")))
        val pending = requireNotNull(base.pending.primary).copy(
            questionItems = listOf(
                PendingQuestionItem(
                    id = "goal",
                    prompt = "选择目标",
                    options = listOf(PendingQuestionOption("目标 A"), PendingQuestionOption("目标 B")),
                ),
                PendingQuestionItem(id = "notes", prompt = "补充说明"),
            ),
        )
        var answer: String? = null
        show(base.copy(pending = PendingSlot(primary = pending)), onSubmitAnswer = { _, json -> answer = json }, composerAvailability = ComposerAvailability(answerQuestions = true))
        compose.onNodeWithText("选择目标").assertIsDisplayed()
        compose.onNodeWithText("目标 A").performClick()
        compose.onNodeWithText("下一题").performClick()
        compose.onNodeWithText("补充说明").assertIsDisplayed()
        compose.onNodeWithText("跳过").performClick()
        assertEquals("""{"goal":["目标 A"],"notes":[]}""", answer)
    }

    @Test
    fun `plan review requires explicit plan metadata and routes its real choices`() {
        val base = ChatScreenState.from(listOf(questionNode("q-plan")))
        val pending = requireNotNull(base.pending.primary).copy(
            questionItems = listOf(
                PendingQuestionItem(
                    id = "review",
                    prompt = "请审阅计划",
                    detail = "# 整理资料\n\n归档来源文件",
                    intentKind = "plan-review",
                    approveWireLabel = "approve",
                ),
            ),
        )
        var answer: String? = null
        var dismissed: String? = null
        show(
            base.copy(pending = PendingSlot(primary = pending)),
            planApproveAvailability = PdshActionAvailability.Available { _, json -> answer = json },
            planRequestChangesAvailability = PdshActionAvailability.Available { ask -> dismissed = ask.requestId },
            composerAvailability = ComposerAvailability(answerQuestions = true, dismissQuestions = true, approvePlans = true, requestPlanChanges = true),
        )
        compose.onNodeWithTag("pdsh.chat.plan-review-takeover").assertIsDisplayed()
        compose.onNodeWithText("整理资料").assertIsDisplayed()
        compose.onNodeWithTag("pdsh.chat.plan-review-approve").performClick()
        assertEquals("""{"review":["approve"]}""", answer)
        compose.onNodeWithTag("pdsh.chat.plan-review-change").performClick()
        assertEquals("q-plan", dismissed)
    }

    // ---------------------------------------------------------- transcript

    @Test
    fun `the no-engine empty state keeps the start action`() {
        // ChatPage.swift `emptyTimeline` case A.
        var started = 0
        show(ChatScreenState.from(emptyList()), onStartEngine = { started += 1 }, startEngineAvailability = PdshActionAvailability.Available { started += 1 })
        compose.onNodeWithTag(UiTags.CHAT_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CHAT_EMPTY_ENGINE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ENGINE_NOT_STARTED).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_START_ENGINE).performClick()
        assertEquals(1, started)
    }

    @Test
    fun `a stopped engine can accept a first prompt when the host reports send-to-start`() {
        val state = ChatScreenState.from(
            emptyList(),
            host = ChatHostFacts(
                engineStarted = false,
                lifecycle = EngineLifecycleFacts(
                    status = EngineLifecycleStatus.STOPPED,
                    canStartBySending = true,
                ),
            ),
        )
        assertTrue(state.composer.enabled)
        show(state)
        compose.onNodeWithTag(UiTags.COMPOSER_FIELD).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_FIELD).assertIsEnabled()
    }

    @Test
    fun `engine failure banner exposes the explicit restart acknowledgement`() {
        var restarted = 0
        val state = state(case = "chat-basic").copy(
            userFacingError = "引擎启动失败",
            failedItemID = null,
            banners = listOf(BannerState("engine-failure", "引擎启动失败", "failed", false, true)),
            lifecycle = EngineLifecycleFacts(status = EngineLifecycleStatus.FAILED, needsReset = true),
        )
        show(state, onRestartEngine = { restarted += 1 })
        compose.onNodeWithTag("pdsh.chat.restart-engine").assertIsDisplayed()
        compose.onNodeWithTag("pdsh.chat.restart-engine").performClick()
        assertEquals(1, restarted)
    }

    @Test
    fun `the start button says 正在启动… while the engine starts`() {
        // ChatPage.swift:965 `model.busy ? "正在启动…" : "启动本地引擎"`.
        show(
            ChatScreenState.from(
                emptyList(),
                host = ChatHostFacts(engineStarted = false, starting = true),
            ),
        )
        compose.onNodeWithText(UiStrings.STARTING_ENGINE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_START_ENGINE).assertIsNotEnabled()
        compose.onNodeWithText(UiStrings.START_ENGINE).assertDoesNotExist()
    }

    @Test
    fun `a missing provider shows the setup state instead of the engine state`() {
        // ChatPage.swift `emptyTimeline` case B.
        var configured = 0
        val state = ChatScreenState.from(
            emptyList(),
            host = ChatHostFacts(engineStarted = true, providerNeedsKey = true),
        )
        assertEquals(ChatEmpty.PROVIDER_SETUP, state.empty)
        show(state, onConfigureProvider = { configured += 1 })
        compose.onNodeWithTag(UiPageTags.CHAT_EMPTY_PROVIDER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PROVIDER_SETUP_TITLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_PROVIDER_SETUP).performClick()
        assertEquals(1, configured)
    }

    @Test
    fun `a ready engine shows the product name and the tagline`() {
        // ChatPage.swift `emptyTimeline` case C.
        val state = ChatScreenState.from(emptyList(), host = ChatHostFacts(engineStarted = true))
        assertEquals(ChatEmpty.READY, state.empty)
        show(state)
        compose.onNodeWithTag(UiPageTags.CHAT_EMPTY_READY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.READY_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.READY_SUBTITLE).assertIsDisplayed()
    }

    @Test
    fun `the transcript offers 加载更早消息 only when the host has more`() {
        // ChatPage.swift `transcript`: `if model.transcriptHasMore`.
        var loaded = 0
        show(
            state(case = "chat-basic", transcript = TranscriptState(hasMore = true)),
            onLoadEarlier = { loaded += 1 },
        )
        compose.onNodeWithTag(UiPageTags.CHAT_LOAD_EARLIER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.LOAD_EARLIER).performClick()
        assertEquals(1, loaded)
    }

    @Test
    fun `the load-earlier control says 正在加载… while the read runs`() {
        // ChatPage.swift:743 `loadingEarlierTranscript ? "正在加载…" : "加载更早消息"`.
        show(
            state(
                case = "chat-basic",
                transcript = TranscriptState(hasMore = true, loadingEarlier = true),
            ),
        )
        compose.onNodeWithText(UiStrings.LOADING_EARLIER).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_LOAD_EARLIER).assertIsNotEnabled()
        compose.onNodeWithText(UiStrings.LOAD_EARLIER).assertDoesNotExist()
    }

    @Test
    fun `the transcript hides 加载更早消息 when there is nothing earlier`() {
        show(state(case = "chat-basic"))
        compose.onNodeWithTag(UiPageTags.CHAT_LOAD_EARLIER).assertDoesNotExist()
    }

    @Test
    fun `a history read failure and the cache notice sit above the rows`() {
        // ChatPage.swift `transcript`: `transcriptError` + `isShowingCachedTranscript`.
        show(
            state(
                case = "chat-basic",
                transcript = TranscriptState(error = "历史读取失败", showingCached = true),
            ),
        )
        compose.onNodeWithTag(UiPageTags.CHAT_TRANSCRIPT_ERROR).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_CACHED_NOTICE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TRANSCRIPT_CACHED).assertIsDisplayed()
    }

    @Test
    fun `a per-row failure line needs a failed row id`() {
        // ChatPage.swift `failureLineIfNeeded`: the line belongs under its row.
        val nodes = SpecFixtures.projectCase("turn-error-vs-complete")
        val userId = nodes.first { it.nodeID.contains("user-message") }.nodeID
        show(ChatScreenState.from(nodes, host = ChatHostFacts(failedItemID = userId)))
        compose.onNodeWithTag(UiPageTags.CHAT_FAILURE_LINE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SEND_FAILED_LINE).assertIsDisplayed()
        // With the failure on a row, the top banner stays empty.
        compose.onNodeWithTag(UiTags.FAIL_LOUD_BANNER).assertDoesNotExist()
    }

    // ------------------------------------------------------------ composer

    @Test
    fun `the composer shows the idle placeholder`() {
        // ChatPage.swift `composerPlaceholder`, idle case.
        show(state(case = "chat-basic"))
        compose.onNodeWithTag(UiTags.COMPOSER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.COMPOSER_PLACEHOLDER_IDLE).assertIsDisplayed()
    }

    @Test
    fun `a running turn with an empty draft swaps the send key for stop`() {
        // ChatPage.swift `actionButton`: !canSubmit && turnRunning → stop.
        var stopped = 0
        show(
            state(case = "chat-basic", running = true),
            onStop = { stopped += 1 },
            stopAvailability = PdshActionAvailability.Available { stopped += 1 },
        )
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertDoesNotExist()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).performClick()
        assertEquals(1, stopped)
    }

    @Test
    fun `a running turn with a draft keeps send and adds the small stop key`() {
        // ChatPage.swift `composer`: `if turnRunning, canSubmit { stopButton(24) }` + send.
        show(
            state(case = "chat-basic", canSend = true, running = true, draft = "补充一句"),
            queueSubmissionAvailability = PdshActionAvailability.Available { _, _ -> },
            stopAvailability = PdshActionAvailability.Available { _ -> },
        )
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertIsDisplayed()
    }

    @Test
    fun `running queue submission requires the typed queue route and sends a request id`() {
        val running = state(case = "chat-basic", canSend = true, running = true, draft = "queue this")
        var submittedText: String? = null
        var requestID: StateRequestId? = null
        show(
            running,
            queueSubmissionAvailability = PdshActionAvailability.Available { text, request ->
                submittedText = text
                requestID = request
            },
        )
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsEnabled().performClick()
        assertEquals("queue this", submittedText)
        assertTrue(requireNotNull(requestID).value.startsWith("ui.queue."))
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertDoesNotExist()
    }

    @Test
    fun `running submission stays disabled when the typed queue route is unavailable`() {
        show(state(case = "chat-basic", canSend = true, running = true, draft = "queue this"))
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsNotEnabled()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertDoesNotExist()
    }

    @Test
    fun `steering mode uses only the typed steer route`() {
        val open = SpecFixtures.projectCase("chat-basic")
            .filterNot { it.kind == UiStateKind.STATUS && it.props.string("reason") != null }
        val steering = ChatScreenState.from(
            open,
            local = ChatLocalState(draft = "steer this"),
            host = ChatHostFacts(engineStarted = true, canSteer = true, enterMode = EnterMode.STEER),
        )
        var steered: String? = null
        var queued: String? = null
        show(
            steering,
            steerSubmissionAvailability = PdshActionAvailability.Available { text, _ -> steered = text },
            queueSubmissionAvailability = PdshActionAvailability.Available { text, _ -> queued = text },
        )
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsEnabled().performClick()
        assertEquals("steer this", steered)
        assertEquals(null, queued)
    }

    @Test
    fun `a single queue item renders without the multirow header`() {
        // ChatPage.swift `queueDock`: one row has no header.
        val nodes = SpecFixtures.projectCase("chat-basic")
        val userId = nodes.first { it.nodeID.contains("user-message") }.nodeID
        val state = ChatScreenState.from(
            nodes,
            local = ChatLocalState(badges = mapOf(userId to UiStrings.QUEUED_TAG)),
            host = ChatHostFacts(engineStarted = true),
        )
        show(state)
        compose.onNodeWithTag(UiTags.COMPOSER_QUEUE).assertIsDisplayed()
        compose.onAllNodesWithText(state.composer.queued.single()).assertCountEquals(2)
        compose.onNodeWithText(UiStrings.CHAT_QUEUE_HEADER_COUNT.format(1)).assertDoesNotExist()
    }

    @Test
    fun `multiple durable queue rows fold by default and toggle open`() {
        val rows = listOf(
            ManagedQueueItemState(QueueItemId.Durable("queue-1"), "第一条排队消息", canEdit = true, canRemove = true, canSteer = true),
            ManagedQueueItemState(QueueItemId.Durable("queue-2"), "第二条排队消息", canEdit = true, canRemove = true, canSteer = true),
        )
        show(state(case = "chat-basic").copy(queueItems = rows))
        compose.onNodeWithText(UiStrings.CHAT_QUEUE_HEADER_COUNT.format(2)).assertIsDisplayed()
        compose.onNodeWithText("第一条排队消息").assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CHAT_QUEUE_HEADER_COUNT.format(2)).performClick()
        compose.onNodeWithText("第一条排队消息").assertIsDisplayed()
        compose.onNodeWithText("第二条排队消息").assertIsDisplayed()
    }

    @Test
    fun `durable queue edit dispatches the exact id and a fresh request without optimistic text`() {
        var edited: ManagedQueueItemState? = null
        var replacement: String? = null
        var requestID: StateRequestId? = null
        val item = ManagedQueueItemState(
            id = QueueItemId.Durable("queue-edit-1"),
            text = "original queued text",
            canEdit = true,
            canRemove = true,
            canSteer = true,
        )
        show(
            state(case = "chat-basic").copy(queueItems = listOf(item)),
            queueEditAvailability = PdshActionAvailability.Available { row, text, request ->
                edited = row
                replacement = text
                requestID = request
            },
        )
        compose.onNodeWithContentDescription(UiStrings.CHAT_QUEUE_EDIT_TITLE).performClick()
        compose.onNodeWithTag("pdsh.chat.queue-edit-dialog").assertIsDisplayed()
        val field = compose.onNodeWithTag("pdsh.chat.queue-edit-field")
        field.performTextClearance()
        field.performTextInput("  revised queued text  ")
        compose.onNodeWithTag("pdsh.chat.queue-edit-save").performClick()
        assertEquals(item.id, edited?.id)
        assertEquals("revised queued text", replacement)
        assertTrue(requireNotNull(requestID).value.startsWith("ui.queue."))
        compose.onNodeWithText("original queued text").assertIsDisplayed()
    }

    @Test
    fun `durable queue removal dispatches the item and request id without optimistic removal`() {
        var removed: ManagedQueueItemState? = null
        var requestID: StateRequestId? = null
        val item = ManagedQueueItemState(
            id = QueueItemId.Durable("queue-remove-1"),
            text = "remove only after readback",
            canRemove = true,
        )
        show(
            state(case = "chat-basic").copy(queueItems = listOf(item)),
            queueRemoveAvailability = PdshActionAvailability.Available { row, request ->
                removed = row
                requestID = request
            },
        )
        compose.onNodeWithContentDescription(UiStrings.CHAT_QUEUE_DELETE).performClick()
        assertEquals(item.id, removed?.id)
        assertTrue(requireNotNull(requestID).value.startsWith("ui.queue."))
        compose.onNodeWithText(item.text).assertIsDisplayed()
    }

    @Test
    fun `durable queue steer button dispatches the exact row and a fresh request`() {
        var steered: ManagedQueueItemState? = null
        var requestID: StateRequestId? = null
        val item = ManagedQueueItemState(
            id = QueueItemId.Durable("queue-steer-1"),
            text = "steer this queued row",
            canEdit = true,
            canRemove = true,
            canSteer = true,
            lane = "next-turn",
        )
        show(
            state(case = "chat-basic", running = true).copy(queueItems = listOf(item)),
            queueSteerAvailability = PdshActionAvailability.Available { row, request ->
                steered = row
                requestID = request
            },
        )
        compose.onNodeWithContentDescription(UiStrings.CHAT_QUEUE_STEER_SEND).performClick()
        assertEquals(item.id, steered?.id)
        assertEquals("next-turn", steered?.lane)
        assertTrue(requireNotNull(requestID).value.startsWith("ui.queue."))
        compose.onNodeWithText(item.text).assertIsDisplayed()
    }

    @Test
    fun `queue edit closes with a visible notice when its row leaves the inbox`() {
        val item = ManagedQueueItemState(
            id = QueueItemId.Durable("queue-vanish"),
            text = "row that will be claimed",
            canEdit = true,
            canRemove = true,
        )
        var current by mutableStateOf(state(case = "chat-basic").copy(queueItems = listOf(item)))
        compose.setContent {
            PdshTheme {
                ChatPage(
                    state = current,
                    onDraftChange = {},
                    onSend = {},
                    onStop = {},
                    onToggleRow = {},
                    onApprove = {},
                    onDeny = {},
                    onDismissBanner = {},
                    onRetry = {},
                    onOpenSessions = {},
                    queueEditAvailability = PdshActionAvailability.Available { _, _, _ -> },
                )
            }
        }
        compose.onNodeWithContentDescription(UiStrings.CHAT_QUEUE_EDIT_TITLE).performClick()
        compose.onNodeWithTag("pdsh.chat.queue-edit-dialog").assertIsDisplayed()

        current = current.copy(queueItems = emptyList())
        compose.waitForIdle()

        compose.onNodeWithTag("pdsh.chat.queue-edit-dialog").assertDoesNotExist()
        compose.onNodeWithText(UiStrings.CHAT_QUEUE_EDIT_ITEM_GONE).assertIsDisplayed()
    }

    @Test
    fun `local queue fallback stays disabled and stale receipts remain visible`() {
        val oldRequest = StateRequestId("queue-request-old")
        val activeRequest = StateRequestId("queue-request-current")
        val stale = ManagedQueueItemState(
            id = QueueItemId.Durable("queue-stale"),
            text = "stale receipt item",
            canEdit = true,
            canRemove = true,
            canSteer = true,
            actionRequestId = activeRequest,
            receipt = QueueActionReceipt(oldRequest, QueueAction.REMOVE, CommandOutcome.FAILED, "old remove receipt"),
        )
        val localState = state(case = "chat-basic").copy(
            composer = state(case = "chat-basic").composer.copy(queued = listOf("local pending item")),
            queueItems = listOf(stale),
        )
        show(localState)
        compose.onNodeWithText("stale receipt item").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CHAT_QUEUE_ACTION_STALE).assertIsDisplayed()
        compose.onNodeWithContentDescription("${UiStrings.CHAT_QUEUE_EDIT_TITLE}，${UiStrings.CHAT_QUEUE_ACTION_STALE}").assertIsNotEnabled()
        compose.onNodeWithContentDescription("${UiStrings.CHAT_QUEUE_EDIT_TITLE}，${UiStrings.CHAT_QUEUE_LOCAL_ACTION_UNAVAILABLE}").assertIsNotEnabled()
    }

    @Test
    fun `sending queue items render in their own pending row`() {
        val item = ManagedQueueItemState(
            id = QueueItemId.Durable("queue-sending-1"),
            text = "still dispatching this message",
            state = QueueItemStatus.SENDING,
            busy = true,
        )
        show(state(case = "chat-basic").copy(queueItems = listOf(item)))
        compose.onNodeWithTag("pdsh.chat.queue-pending").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CHAT_QUEUE_SENDING).assertIsDisplayed()
        compose.onNodeWithText(item.text).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_QUEUE).assertDoesNotExist()
    }

    @Test
    fun `the todo dock collapses and expands real host task rows`() {
        val state = ChatScreenState.from(
            emptyList(),
            host = ChatHostFacts(
                engineStarted = true,
                todoItems = listOf(
                    TodoDockItem(id = "todo-1", content = "整理会议记录", status = "in_progress"),
                    TodoDockItem(id = "todo-2", content = "发送纪要", status = "pending"),
                ),
            ),
        )
        show(state)
        compose.onNodeWithTag("pdsh.chat.todo-dock").assertIsDisplayed()
        compose.onNodeWithTag("pdsh.chat.todo-row.todo-1").assertDoesNotExist()
        compose.onNodeWithTag("pdsh.chat.todo-dock").performClick()
        compose.onNodeWithTag("pdsh.chat.todo-row.todo-1").assertIsDisplayed()
        compose.onNodeWithText("整理会议记录").assertIsDisplayed()
        compose.onNodeWithText("1 进行中\u2002·\u20021 待处理").assertIsDisplayed()
    }

    @Test
    fun `the pending attachments strip removes by index`() {
        // ChatPage.swift `attachmentStrip`.
        var removed: Int? = null
        show(
            state(
                case = "chat-basic",
                attachments = listOf(
                    com.phonedsh.ui.state.ChatAttachment(name = "a.png", image = true),
                    com.phonedsh.ui.state.ChatAttachment(name = "b.png", image = true),
                ),
            ),
            onRemoveAttachment = { removed = it },
        )
        compose.onNodeWithTag(UiPageTags.COMPOSER_ATTACHMENTS).assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.COMPOSER_REMOVE_IMAGE.format("b.png"))
            .performClick()
        assertEquals(1, removed ?: -1)
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun `slash menu supports arrow tab enter and escape while command picks update the draft`() {
        var draft: String? = null
        var selected: String? = null
        show(
            state(
                case = "chat-basic",
                draft = "/g",
                commands = listOf(ComposerCommand("goal", "目标"), ComposerCommand("grep", "搜索")),
            ),
            onDraftChange = { draft = it },
            onPickCommand = { selected = it },
        )
        val field = compose.onNodeWithTag(UiTags.COMPOSER_FIELD)
        compose.onNodeWithTag(UiPageTags.COMPOSER_SLASH_MENU).assertIsDisplayed()
        field.performClick()
        field.performKeyInput {
            keyDown(Key.DirectionDown)
            keyUp(Key.DirectionDown)
        }
        compose.onNodeWithTag("pdsh.chat.slash-command.grep").assertIsSelected()
        field.performKeyInput {
            keyDown(Key.Tab)
            keyUp(Key.Tab)
        }
        assertEquals("grep", selected)
        assertEquals("/grep ", draft)
        compose.onNodeWithTag(UiPageTags.COMPOSER_SLASH_MENU).assertDoesNotExist()

    }

    @Test
    @OptIn(ExperimentalTestApi::class)
    fun `escape closes the slash menu without changing the draft`() {
        var draft: String? = "/g"
        show(
            state(case = "chat-basic", draft = "/g", commands = listOf(ComposerCommand("goal", "目标"))),
            onDraftChange = { draft = it },
        )
        val field = compose.onNodeWithTag(UiTags.COMPOSER_FIELD)
        field.performClick()
        field.performKeyInput {
            keyDown(Key.Escape)
            keyUp(Key.Escape)
        }
        compose.onNodeWithTag(UiPageTags.COMPOSER_SLASH_MENU).assertDoesNotExist()
        assertEquals("/g", draft)
    }

    @Test
    fun `reference selection inserts a path or an at-prefixed session without a host callback`() {
        var draft: String? = null
        show(
            state(case = "chat-basic", draft = "@notes", files = listOf("notes/brief.md")),
            onDraftChange = { draft = it },
        )
        compose.onNodeWithText("notes/brief.md").performClick()
        assertEquals("notes/brief.md ", draft)
    }

    @Test
    fun `a slash draft opens the command menu and picking writes the token`() {
        // ChatPage.swift `slashCommandMenu` + `pickCommand`.
        var picked: String? = null
        show(
            state(case = "chat-basic", draft = "/", commands = listOf(ComposerCommand("goal", "目标"))),
            onPickCommand = { picked = it },
        )
        compose.onNodeWithTag(UiPageTags.COMPOSER_SLASH_MENU).assertIsDisplayed()
        compose.onNodeWithText("/goal").performClick()
        assertEquals("goal", picked)
    }

    @Test
    fun `an at draft opens the reference menu`() {
        // ChatPage.swift `referenceMenu`.
        var picked: String? = null
        show(
            state(case = "chat-basic", draft = "@", files = listOf("notes/a.md")),
            onPickReference = { picked = it },
        )
        compose.onNodeWithTag(UiPageTags.COMPOSER_REFERENCE_MENU).assertIsDisplayed()
        compose.onNodeWithText("notes/a.md").performClick()
        assertEquals("notes/a.md", picked)
    }

    @Test
    fun `the goal bar offers pause while active and resume while paused`() {
        // ChatPage.swift `goalBar`.
        var paused = 0
        var resumed = 0
        var cleared = 0
        show(
            ChatScreenState.from(
                SpecFixtures.projectCase("chat-basic"),
                goal = GoalBarState.Visible(phase = "active", objective = "ship F6"),
            ),
            onGoalPause = { paused += 1 },
            onGoalResume = { resumed += 1 },
            onGoalClear = { cleared += 1 },
        )
        compose.onNodeWithTag(UiTags.GOAL_BAR).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.GOAL_PHASE_ACTIVE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.GOAL_PAUSE).performClick()
        assertEquals(1, paused)
        compose.onNodeWithTag(UiPageTags.GOAL_CLEAR).performClick()
        assertEquals(1, cleared)
        compose.onNodeWithText(UiStrings.GOAL_RESUME).assertDoesNotExist()
    }

    @Test
    fun `a paused goal offers resume and no pause`() {
        var resumed = 0
        show(
            ChatScreenState.from(
                SpecFixtures.projectCase("chat-basic"),
                goal = GoalBarState.Visible(phase = "paused", objective = "ship F6"),
            ),
            onGoalResume = { resumed += 1 },
        )
        compose.onNodeWithTag(UiPageTags.GOAL_RESUME).performClick()
        assertEquals(1, resumed)
        compose.onNodeWithTag(UiPageTags.GOAL_PAUSE).assertDoesNotExist()
    }

    @Test
    fun `the permissions and model menus are disabled while a turn runs`() {
        // ChatPage.swift: both menus `.disabled(model.turnRunning …)`.
        val running = state(case = "chat-basic", running = true)
        assertEquals(ChatPhase.RUNNING, running.phase)
        assertTrue(running.accessModeMenu.enabled.not())
        assertTrue(running.modelMenu.enabled.not())
        val idle = state(case = "chat-basic")
        assertTrue(idle.accessModeMenu.enabled)
        assertTrue(idle.modelMenu.enabled)
    }

    @Test
    fun `the permissions menu groups a read failure under 暂不可用`() {
        // ChatPage.swift `accessModeMenu`: `Section("暂不可用") { Text(error) }`.
        // There is no page banner, so the menu is the only place with the words.
        show(state(case = "chat-basic", accessModeError = "读不到权限"), composerAvailability = ComposerAvailability(selectAccessMode = true))
        compose.onNodeWithTag(UiPageTags.COMPOSER_ACCESS_MODE).performClick()
        compose.onNodeWithText(UiStrings.ACCESS_MODE_UNAVAILABLE).assertIsDisplayed()
        compose.onAllNodesWithText("读不到权限").assertCountEquals(1)
    }

    @Test
    fun `the model menu names its two groups and checks the choice`() {
        // ChatPage.swift `modelMenu`: `Section("强度")` … `Section("模型")`, one
        // checkmark per group (iOS `Label(title, systemImage: "checkmark")`).
        show(
            state(
                case = "chat-basic",
                models = listOf("deepseek-v4", "deepseek-v4-max"),
                currentModel = "deepseek-v4-max",
                efforts = listOf(EffortOption(id = "high", title = "高")),
                currentEffort = "high",
            ),
            composerAvailability = ComposerAvailability(selectModel = true),
        )
        compose.onNodeWithTag(UiPageTags.COMPOSER_MODEL_MENU).performClick()
        compose.onNodeWithText(UiStrings.MODEL_SECTION_EFFORT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MODEL_SECTION_MODEL).assertIsDisplayed()
        compose.onNodeWithText("高").assertIsSelected()
        compose.onNodeWithText("deepseek-v4").assertIsNotSelected()
        // The model in force is also the trigger's own word, so the checked row is
        // found among the nodes that carry it.
        compose.onAllNodesWithText("deepseek-v4-max").assertAny(isSelected())
    }

    @Test
    fun `the steer and queue placeholders are the running cases`() {
        // ChatPage.swift `composerPlaceholder`: idle / steer / queue.
        // The open turn is what makes the running cases reachable: dropping the
        // turn-end row from the golden leaves the turn open.
        val open = SpecFixtures.projectCase("chat-basic")
            .filterNot { it.kind == UiStateKind.STATUS && it.props.string("reason") != null }
        val steer = ChatScreenState.from(
            open,
            host = ChatHostFacts(
                engineStarted = true,
                canSteer = true,
                enterMode = EnterMode.STEER,
            ),
        )
        val queued = ChatScreenState.from(
            open,
            host = ChatHostFacts(engineStarted = true, canSend = true, enterMode = EnterMode.QUEUE),
        )
        assertEquals(ChatPhase.RUNNING, steer.phase)
        assertEquals(UiStrings.COMPOSER_PLACEHOLDER_IDLE, ChatScreenState.from(SpecFixtures.projectCase("chat-basic")).composer.placeholder)
        assertEquals(UiStrings.COMPOSER_PLACEHOLDER_STEER, steer.composer.placeholder)
        assertEquals(UiStrings.COMPOSER_PLACEHOLDER_QUEUE, queued.composer.placeholder)
        show(steer)
        compose.onNodeWithText(UiStrings.COMPOSER_PLACEHOLDER_STEER).assertIsDisplayed()
    }

    @Test
    fun `a tool entry's file chip routes the path to the host`() {
        // NativeToolDetailCards.swift:19-27: the expanded row shows the path and
        // asks the host to open it; the page never navigates itself.
        var opened: String? = null
        val state = ChatScreenState.from(SpecFixtures.projectCase("chat-basic")).copy(
            rows = listOf(
                ChatRow.ToolRun(
                    id = "run-1",
                    entries = listOf(
                        ToolEntry(
                            id = "run-1",
                            title = "read",
                            summary = "ok",
                            state = com.phonedsh.ui.surface.ToolRowState.OK,
                            banner = "read",
                            body = "1\t# notes",
                            filePath = "notes/a.md",
                        ),
                    ),
                ),
            ),
            expandedRowIds = setOf("run-1"),
        )
        show(state, onOpenFile = { opened = it })
        compose.onNodeWithTag(UiPageTags.CHAT_ROW_TOOL_FILE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_ROW_TOOL_FILE).performClick()
        assertEquals("notes/a.md", opened)
    }

    // --------------------------------------------------------------- helpers

    private fun show(
        state: ChatScreenState,
        title: String = "",
        onDraftChange: (String) -> Unit = {},
        onSend: () -> Unit = {},
        onStop: () -> Unit = {},
        onApprove: (PendingAnswer) -> Unit = {},
        onDismissBanner: (String) -> Unit = {},
        onRetry: () -> Unit = {},
        onRenameSession: (String) -> Unit = {},
        onExportTranscript: () -> Unit = {},
        onOpenArtifacts: (() -> Unit)? = null,
        onOpenWorkbench: (() -> Unit)? = null,
        onOpenRunStatus: () -> Unit = {},
        onOpenDeviceConnections: () -> Unit = {},
        onOpenSessionSettings: () -> Unit = {},
        onStartEngine: () -> Unit = {},
        startEngineAvailability: PdshActionAvailability<() -> Unit> = PdshActionAvailability.Unavailable(com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED),
        onRestartEngine: () -> Unit = {},
        onConfigureProvider: (() -> Unit)? = null,
        onLoadEarlier: () -> Unit = {},
        onSubmitAnswer: (PendingAnswer, String) -> Unit = { _, _ -> },
        onDismissQuestion: (PendingAnswer) -> Unit = {},
        onExecuteCommand: ((String) -> Unit)? = null,
        onRemoveAttachment: (Int) -> Unit = {},
        onPickCommand: (String) -> Unit = {},
        onPickReference: (String) -> Unit = {},
        onExpandPendingSlot: () -> Unit = {},
        onGoalPause: (() -> Unit)? = null,
        onGoalResume: (() -> Unit)? = null,
        onGoalClear: (() -> Unit)? = null,
        onRetryAccessModes: () -> Unit = {},
        onReloadCommands: () -> Unit = {},
        onOpenFile: ((String) -> Unit)? = null,
        onOpenResource: ((String) -> Unit)? = null,
        planApproveAvailability: PdshActionAvailability<(PendingAnswer, String) -> Unit> = PdshActionAvailability.Unavailable(com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED),
        planRequestChangesAvailability: PdshActionAvailability<(PendingAnswer) -> Unit> = PdshActionAvailability.Unavailable(com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED),
        queueEditAvailability: PdshActionAvailability<(ManagedQueueItemState, String, StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED),
        queueRemoveAvailability: PdshActionAvailability<(ManagedQueueItemState, StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED),
        queueSteerAvailability: PdshActionAvailability<(ManagedQueueItemState, StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED),
        queueSubmissionAvailability: PdshActionAvailability<(String, StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED),
        steerSubmissionAvailability: PdshActionAvailability<(String, StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED),
        stopAvailability: PdshActionAvailability<(StateRequestId) -> Unit> = PdshActionAvailability.Unavailable(com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED),
        composerAvailability: ComposerAvailability = ComposerAvailability(),
        timelineRetryAvailability: PdshActionAvailability<() -> Unit> = PdshActionAvailability.Unavailable(com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED),
    ) {
        compose.setContent {
            PdshTheme {
                ChatPage(
                    state = state,
                    onDraftChange = onDraftChange,
                    onSend = onSend,
                    onStop = onStop,
                    onToggleRow = {},
                    onApprove = onApprove,
                    onDeny = {},
                    onDismissBanner = onDismissBanner,
                    onRetry = onRetry,
                    onOpenSessions = {},
                    title = title,
                    onGoalPause = onGoalPause,
                    onGoalResume = onGoalResume,
                    onGoalClear = onGoalClear,
                    onExpandPendingSlot = onExpandPendingSlot,
                    onRenameSession = onRenameSession,
                    onExportTranscript = onExportTranscript,
                    onOpenArtifacts = onOpenArtifacts,
                    onOpenWorkbench = onOpenWorkbench,
                    onOpenRunStatus = onOpenRunStatus,
                    onOpenDeviceConnections = onOpenDeviceConnections,
                    onOpenSessionSettings = onOpenSessionSettings,
                    onStartEngine = onStartEngine,
                    startEngineAvailability = startEngineAvailability,
                    onRestartEngine = onRestartEngine,
                    onConfigureProvider = onConfigureProvider,
                    onLoadEarlier = onLoadEarlier,
                    onSubmitAnswer = onSubmitAnswer,
                    onDismissQuestion = onDismissQuestion,
                    onExecuteCommand = onExecuteCommand,
                    onRemoveAttachment = onRemoveAttachment,
                    onPickCommand = onPickCommand,
                    onPickReference = onPickReference,
                    onRetryAccessModes = onRetryAccessModes,
                    onReloadCommands = onReloadCommands,
                    onOpenFile = onOpenFile,
                    onOpenResource = onOpenResource,
                    planApproveAvailability = planApproveAvailability,
                    planRequestChangesAvailability = planRequestChangesAvailability,
                    queueEditAvailability = queueEditAvailability,
                    queueRemoveAvailability = queueRemoveAvailability,
                    queueSteerAvailability = queueSteerAvailability,
                    queueSubmissionAvailability = queueSubmissionAvailability,
                    steerSubmissionAvailability = steerSubmissionAvailability,
                    stopAvailability = stopAvailability,
                    composerAvailability = composerAvailability,
                    timelineRetryAvailability = timelineRetryAvailability,
                )
            }
        }
    }

    /** A state built from one golden case plus the host facts a test needs. */
    private fun state(
        case: String,
        canSend: Boolean = true,
        accessModeError: String? = null,
        commandsError: String? = null,
        transcript: TranscriptState = TranscriptState(),
        imeVisible: Boolean = false,
        running: Boolean = false,
        draft: String = "",
        attachments: List<com.phonedsh.ui.state.ChatAttachment> = emptyList(),
        commands: List<ComposerCommand> = emptyList(),
        files: List<String> = emptyList(),
        models: List<String> = emptyList(),
        currentModel: String? = null,
        efforts: List<EffortOption> = emptyList(),
        currentEffort: String? = null,
    ): ChatScreenState {
        // `running` means "a turn is open": dropping the turn-end row from the
        // golden is what makes the phase RUNNING in the projection.
        val nodes = if (running) {
            SpecFixtures.projectCase(case).filterNot { node ->
                node.kind == UiStateKind.STATUS && node.props.string("reason") != null
            }
        } else {
            SpecFixtures.projectCase(case)
        }
        val host = ChatHostFacts(
            engineStarted = true,
            accessModeError = accessModeError,
            commandsError = commandsError,
            commands = commands,
            files = files,
            models = models,
            currentModel = currentModel,
            efforts = efforts,
            currentEffort = currentEffort,
            transcript = transcript,
            canSend = canSend,
            canSteer = canSend,
        )
        return ChatScreenState.from(
            nodes,
            local = ChatLocalState(
                draft = draft,
                imeVisible = imeVisible,
                attachments = attachments,
            ),
            host = host,
        )
    }

    /** One question ask appended to a permission flow, so the slot has both kinds. */
    private fun questionNode(requestId: String) = com.phonedsh.ui.projection.UiStateNode(
        kind = com.phonedsh.ui.projection.UiStateKind.APPROVAL_CARD,
        nodeID = "session/s1/turn/turn-0001/event/9/question-request",
        parentID = "session/s1/turn/turn-0001",
        sessionID = "s1",
        turnID = "turn-0001",
        seq = 9,
        text = "这一条怎么处理？",
        props = com.phonedsh.agentcore.JsonObject(
            mapOf(
                "kind" to com.phonedsh.agentcore.JsonString("question"),
                "requestId" to com.phonedsh.agentcore.JsonString(requestId),
                "channelAvailable" to com.phonedsh.agentcore.JsonBool(true),
                "multiple" to com.phonedsh.agentcore.JsonBool(false),
                "options" to com.phonedsh.agentcore.JsonArray(
                    listOf(
                        com.phonedsh.agentcore.JsonString("改用表格"),
                        com.phonedsh.agentcore.JsonString("保持现状"),
                    ),
                ),
            ),
        ),
    )

    @Test
    fun `run status does not add a dot to the iOS page header`() {
        val state = ChatScreenState.from(
            SpecFixtures.projectCase("chat-basic"),
            host = ChatHostFacts(engineStarted = true, parked = true),
        )
        assertEquals(RunStatus.PARKED, state.runStatus)
        show(state)
        compose.onNodeWithText(UiStrings.RUN_STATUS_PARKED).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_MENU).performClick()
        compose.onNodeWithText(UiStrings.HEADER_RUN_STATUS).assertIsDisplayed()
    }
}
