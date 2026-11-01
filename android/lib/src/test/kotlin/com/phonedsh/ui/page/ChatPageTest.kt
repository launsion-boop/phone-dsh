// ChatPage row/section acceptance (JVM + Robolectric).
// SPDX-License-Identifier: MIT
//
// One test per mirrored section of `examples/probe-app/PhoneDSHProbe/ChatPage.swift`:
// the page head, the three failure banners, the pending-card region, the
// transcript chrome and the composer dock. Each test names the Swift source it
// pins, so deleting a section makes its own test fail instead of leaving a
// silently thinner page.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertAny
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.createComposeRule
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
import com.phonedsh.ui.state.ComposerCommand
import com.phonedsh.ui.state.EffortOption
import com.phonedsh.ui.state.EnterMode
import com.phonedsh.ui.state.GoalBarState
import com.phonedsh.ui.state.PendingAnswer
import com.phonedsh.ui.state.RunStatus
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.state.TranscriptState
import com.phonedsh.ui.state.string
import com.phonedsh.ui.theme.PdshTheme
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
    fun `the page head shows the session title and the run status word`() {
        // ChatPage.swift `chatHeader` + NativeShell.swift `RunStatusDot`.
        show(state(case = "chat-basic"), title = "会话甲")
        compose.onNodeWithTag(UiPageTags.CHAT_HEADER_TITLE).assertIsDisplayed()
        compose.onNodeWithText("会话甲").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUN_STATUS_STARTED).assertIsDisplayed()
    }

    @Test
    fun `a stopped engine reads 未启动 in the head`() {
        show(ChatScreenState.from(SpecFixtures.projectCase("chat-basic")))
        compose.onNodeWithText(UiStrings.RUN_STATUS_STOPPED).assertIsDisplayed()
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
    fun `the head menu trigger is named 更多操作`() {
        // ChatPage.swift:163 `.accessibilityLabel("更多操作")`.
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
    fun `an access-mode read failure shows its own banner with retry`() {
        // ChatPage.swift `accessModeErrorBanner`.
        var retried = 0
        show(state(case = "chat-basic", accessModeError = "读不到权限"), onRetryAccessModes = { retried += 1 })
        compose.onNodeWithTag(UiPageTags.CHAT_BANNER_ACCESS_MODE).assertIsDisplayed()
        compose.onNodeWithText("读不到权限").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
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
    fun `approving calls back with the request id`() {
        var approved: String? = null
        show(state(case = "permission-flow"), onApprove = { approved = it.requestId })
        compose.onNodeWithTag(UiTags.APPROVAL_PRIMARY).performClick()
        assertEquals("perm-1", approved)
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
    fun `two asks fold the second into 还有 1 个待确认`() {
        // ChatPage.swift `cardsRegion`: permission wins, the question folds.
        val nodes = SpecFixtures.projectCase("permission-flow") + listOf(
            questionNode("q-1"),
        )
        show(ChatScreenState.from(nodes))
        compose.onNodeWithTag(UiPageTags.CHAT_PENDING_MORE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MORE_PENDING).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.APPROVAL_CARD).assertIsDisplayed()
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
        )
        compose.onNodeWithTag(UiTags.APPROVAL_CARD).assertIsDisplayed()
        compose.onNodeWithText("改用表格").performClick()
        compose.onNodeWithTag(UiPageTags.CHAT_QUESTION_SUBMIT).performClick()
        if (answered == null) {
            println("TREE " + compose.onRoot().printToString(maxDepth = 100))
        }
        assertEquals("q-1", answered?.requestId)
        assertEquals("""{"answer":"改用表格"}""", answer)
    }

    // ---------------------------------------------------------- transcript

    @Test
    fun `the no-engine empty state keeps the start action`() {
        // ChatPage.swift `emptyTimeline` case A.
        var started = 0
        show(ChatScreenState.from(emptyList()), onStartEngine = { started += 1 })
        compose.onNodeWithTag(UiTags.CHAT_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CHAT_EMPTY_ENGINE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ENGINE_NOT_STARTED).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_START_ENGINE).performClick()
        assertEquals(1, started)
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
        )
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertDoesNotExist()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).performClick()
        assertEquals(1, stopped)
    }

    @Test
    fun `a running turn with a draft keeps send and adds the small stop key`() {
        // ChatPage.swift `composer`: `if turnRunning, canSubmit { stopButton(24) }` + send.
        show(state(case = "chat-basic", canSend = true, running = true, draft = "补充一句"))
        compose.onNodeWithTag(UiTags.COMPOSER_SEND).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.COMPOSER_STOP).assertIsDisplayed()
    }

    @Test
    fun `the queue strip lists the queued messages`() {
        // ChatPage.swift `queuedStrip`: 排队中 N 条 + one line per message.
        val nodes = SpecFixtures.projectCase("chat-basic")
        val userId = nodes.first { it.nodeID.contains("user-message") }.nodeID
        val state = ChatScreenState.from(
            nodes,
            local = ChatLocalState(badges = mapOf(userId to UiStrings.QUEUED_TAG)),
            host = ChatHostFacts(engineStarted = true),
        )
        show(state)
        compose.onNodeWithTag(UiTags.COMPOSER_QUEUE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.QUEUED_COUNT.format(1)).assertIsDisplayed()
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
        // ChatPage.swift `accessModeMenu`: `Section("暂不可用") { Text(error) }`; the
        // retry stays the page banner's, not a menu row.
        show(state(case = "chat-basic", accessModeError = "读不到权限"))
        compose.onNodeWithTag(UiPageTags.COMPOSER_ACCESS_MODE).performClick()
        compose.onNodeWithText(UiStrings.ACCESS_MODE_UNAVAILABLE).assertIsDisplayed()
        // The banner and the menu each carry the failure's own words.
        compose.onAllNodesWithText("读不到权限").assertCountEquals(2)
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
        onSend: () -> Unit = {},
        onStop: () -> Unit = {},
        onApprove: (PendingAnswer) -> Unit = {},
        onDismissBanner: (String) -> Unit = {},
        onRetry: () -> Unit = {},
        onRenameSession: (String) -> Unit = {},
        onExportTranscript: () -> Unit = {},
        onOpenSessionSettings: () -> Unit = {},
        onStartEngine: () -> Unit = {},
        onConfigureProvider: () -> Unit = {},
        onLoadEarlier: () -> Unit = {},
        onSubmitAnswer: (PendingAnswer, String) -> Unit = { _, _ -> },
        onRemoveAttachment: (Int) -> Unit = {},
        onPickCommand: (String) -> Unit = {},
        onPickReference: (String) -> Unit = {},
        onExpandPendingSlot: () -> Unit = {},
        onGoalPause: (() -> Unit)? = null,
        onGoalResume: (() -> Unit)? = null,
        onGoalClear: (() -> Unit)? = null,
        onRetryAccessModes: () -> Unit = {},
        onReloadCommands: () -> Unit = {},
        onOpenFile: (String) -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme {
                ChatPage(
                    state = state,
                    onDraftChange = {},
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
                    onOpenSessionSettings = onOpenSessionSettings,
                    onStartEngine = onStartEngine,
                    onConfigureProvider = onConfigureProvider,
                    onLoadEarlier = onLoadEarlier,
                    onSubmitAnswer = onSubmitAnswer,
                    onRemoveAttachment = onRemoveAttachment,
                    onPickCommand = onPickCommand,
                    onPickReference = onPickReference,
                    onRetryAccessModes = onRetryAccessModes,
                    onReloadCommands = onReloadCommands,
                    onOpenFile = onOpenFile,
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
    fun `the run status dot announces its word`() {
        val state = ChatScreenState.from(
            SpecFixtures.projectCase("chat-basic"),
            host = ChatHostFacts(engineStarted = true, parked = true),
        )
        assertEquals(RunStatus.PARKED, state.runStatus)
        show(state)
        compose.onNodeWithText(UiStrings.RUN_STATUS_PARKED).assertIsDisplayed()
    }
}
