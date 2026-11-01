// ScreenState acceptance: same input -> same row sequence (never a screenshot).
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/README.md` §6 rule ③ says ScreenState must be a pure function of
// (UiState + local UI events) so it can be replayed in a JVM test. These tests
// replay the golden projections and assert the *sequence* of visible rows, the
// pending-answer slot, the fail-loud banners and the composer state.
package com.phonedsh.ui.state

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.projection.UiStateSurface
import com.phonedsh.ui.state.ChatAttachment
import com.phonedsh.ui.state.ChatEmpty
import com.phonedsh.ui.state.ChatHostFacts
import com.phonedsh.ui.state.ChatLocalState
import com.phonedsh.ui.state.ComposerCommand
import com.phonedsh.ui.state.EnterMode
import com.phonedsh.ui.state.RunStatus
import com.phonedsh.ui.state.SlashMenu
import com.phonedsh.ui.surface.ComposerMode
import com.phonedsh.ui.surface.ToolRowState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatScreenStateTest {
    @Test
    fun `chat-basic folds its rows and closes the turn`() {
        val state = stateOf("chat-basic")
        assertEquals(
            listOf(ChatRow.User::class, ChatRow.ToolRun::class, ChatRow.Assistant::class),
            state.rows.map { it::class },
        )
        assertEquals("Summarize /dsh/workspace/notes/a.md", (state.rows[0] as ChatRow.User).text)
        val run = state.rows[1] as ChatRow.ToolRun
        assertEquals("read", run.title)
        // The fixture has no tool_result, and the turn closed, so the row cannot
        // still be running: it settles to "stopped" rather than shimmering forever.
        assertEquals(ToolRowState.STOPPED, run.state)
        assertEquals(UiStrings.TOOL_STOPPED, run.summary)
        assertEquals("Done.", (state.rows[2] as ChatRow.Assistant).text)
        assertEquals(ChatPhase.IDLE, state.phase)
        assertTrue(state.pending.isEmpty)
        assertTrue(state.banners.isEmpty())
        assertTrue("a closed turn leaves the composer usable", state.composer.enabled)
        assertEquals(ComposerMode.SEND, state.composer.mode)
        // The completed turn-end node exists in UiState but is not a visible row.
        val nodes = SpecFixtures.projectCase("chat-basic")
        assertTrue(nodes.any { it.kind == UiStateKind.STATUS && it.text == "completed" })
        assertTrue(state.rows.none { it is ChatRow.SystemEvent })
    }

    @Test
    fun `permission-flow locks the composer behind one card`() {
        val state = stateOf("permission-flow")
        val primary = requireNotNull(state.pending.primary)
        assertEquals("perm-1", primary.requestId)
        assertEquals("permission", primary.kind)
        assertEquals(UiStrings.WAITING_AUTHORIZATION, primary.title)
        assertTrue("the card shows the request text", primary.subtitle.startsWith("allow exec?"))
        assertEquals(1, state.pending.count)
        assertTrue("a pending ask disables the dock", !state.composer.enabled)
        assertEquals(ChatPhase.IDLE, state.phase)
        assertEquals(1, state.rows.count { it is ChatRow.ToolRun })
        val run = state.rows.single { it is ChatRow.ToolRun } as ChatRow.ToolRun
        assertEquals(ToolRowState.OK, run.state)
        assertEquals("uid=1000", run.summary)
    }

    @Test
    fun `answering a request removes its card and re-enables the dock`() {
        val nodes = SpecFixtures.projectCase("permission-flow")
        val answered = ChatScreenState.from(
            nodes,
            local = ChatLocalState(answeredRequestIds = setOf("perm-1")),
        )
        assertTrue(answered.pending.isEmpty)
        assertTrue(answered.composer.enabled)
    }

    @Test
    fun `turn-error raises one fail-loud banner and a failed phase`() {
        val state = stateOf("turn-error-vs-complete")
        assertEquals(ChatPhase.FAILED, state.phase)
        val banner = state.banners.single()
        assertEquals("permission denied", banner.message)
        assertEquals("error", banner.reason)
        assertTrue(banner.retryable)
        assertTrue(banner.dismissible)
        // A turn's tool activity is one run per contiguous block (an approval cards
        // splits it here), and the turn end is a system-event row.
        assertEquals(ChatRow.User::class, state.rows.first()::class)
        assertEquals(ChatRow.SystemEvent::class, state.rows.last()::class)
        assertTrue(state.rows.drop(1).dropLast(1).all { it is ChatRow.ToolRun })
        // The host's wire word is not copy: the row carries the translated title
        // (the cause text lives in the fail-loud banner above the list).
        val event = state.rows.last() as ChatRow.SystemEvent
        assertEquals(UiStrings.SYSTEM_EVENT_TURN_FAILED, event.title)
        assertTrue(event.isError)
        assertEquals("", event.text)
    }

    @Test
    fun `dismissing a banner keeps the failure state but clears the row`() {
        val nodes = SpecFixtures.projectCase("turn-error-vs-complete")
        val bannerId = nodes.single { it.kind == UiStateKind.FAIL_LOUD_BANNER }.nodeID
        val dismissed = ChatScreenState.from(nodes, local = ChatLocalState(dismissedBannerIds = setOf(bannerId)))
        assertTrue(dismissed.banners.isEmpty())
        assertEquals("the turn is still a failed turn", ChatPhase.FAILED, dismissed.phase)
    }

    @Test
    fun `an unconnected engine shows the waiting state, never fabricated rows`() {
        val state = ChatScreenState.from(emptyList())
        assertEquals(ChatPhase.WAITING, state.phase)
        assertTrue(state.rows.isEmpty())
        assertTrue(state.pending.isEmpty)
        assertTrue(state.banners.isEmpty())
        assertFalse(state.composer.enabled)
        assertEquals("", state.sessionID)
    }

    @Test
    fun `two pending asks share the slot with the permission card on top`() {
        val nodes = structural() + listOf(
            approval(slot = "question-request", requestId = "q-1", kind = "question", text = "pick one"),
            approval(slot = "permission-request", requestId = "p-1", kind = "permission", text = "allow exec?"),
        )
        val state = ChatScreenState.from(nodes)
        assertEquals(2, state.pending.count)
        assertEquals("p-1", state.pending.primary?.requestId)
        assertEquals(listOf("q-1"), state.pending.folded.map { it.requestId })
        assertTrue(!state.composer.enabled)
    }

    @Test
    fun `a local badge lands on the row it belongs to`() {
        val nodes = SpecFixtures.projectCase("reorder-window")
        val userId = nodes.first { it.kind == UiStateKind.BUBBLE }.nodeID
        val state = ChatScreenState.from(
            nodes,
            local = ChatLocalState(badges = mapOf(userId to UiStrings.QUEUED_TAG)),
        )
        assertEquals(UiStrings.QUEUED_TAG, (state.rows.first() as ChatRow.User).badge)
    }

    @Test
    fun `the projection is a pure function of its inputs`() {
        SpecFixtures.trajectoryCases().forEach { case ->
            val nodes = SpecFixtures.projectCase(case)
            assertEquals(
                "$case: same input, same state",
                ChatScreenState.from(nodes),
                ChatScreenState.from(nodes),
            )
        }
    }

    @Test
    fun `a running turn shows the stop key`() {
        val nodes = listOf(
            turnNode(),
            node(
                kind = UiStateKind.TOOL_ROW,
                slot = "tool-call",
                surface = UiStateSurface.TOOL_ROW,
                text = "exec",
                props = mapOf(
                    "callId" to JsonString("c1"),
                    "name" to JsonString("exec"),
                    "phase" to JsonString("call"),
                    "state" to JsonString("running"),
                ),
            ),
        )
        val state = ChatScreenState.from(nodes)
        assertEquals(ChatPhase.RUNNING, state.phase)
        assertEquals(ComposerMode.STOP, state.composer.mode)
        assertEquals(ToolRowState.RUNNING, (state.rows.single() as ChatRow.ToolRun).state)
    }

    @Test
    fun `the goal bar is data the screen supplies, not an event`() {
        val nodes = SpecFixtures.projectCase("chat-basic")
        assertTrue(ChatScreenState.from(nodes).goal is GoalBarState.Hidden)
        val visible = ChatScreenState.from(
            nodes,
            goal = GoalBarState.Visible(phase = "active", objective = "ship F6"),
            stats = "1.2k tokens",
        )
        assertEquals(GoalBarState.Visible("active", "ship F6"), visible.goal)
        assertEquals("1.2k tokens", visible.stats)
        assertNull(visible.rows.firstOrNull { it is ChatRow.SystemEvent })
    }

    @Test
    fun `the answer slot caps at two cards and counts what it cannot show`() {
        val nodes = structural() + listOf(
            approval(slot = "permission-1", requestId = "p-1", kind = "permission", text = "allow exec?"),
            approval(slot = "question-1", requestId = "q-1", kind = "question", text = "pick one"),
            approval(slot = "question-2", requestId = "q-2", kind = "question", text = "pick two"),
        )
        val state = ChatScreenState.from(nodes)
        // §2: the slot shows at most two asks; the third is counted, not dropped.
        assertEquals(2, state.pending.displayedCount)
        assertEquals(1, state.pending.hidden)
        assertEquals(3, state.pending.count)
        assertEquals("p-1", state.pending.primary?.requestId)
        assertEquals(listOf("q-2"), state.pending.folded.map { it.requestId })
        assertEquals(ComposerLock.PENDING_ANSWER, state.composerLock)
        assertFalse(state.composer.enabled)
    }

    @Test
    fun `the keyboard folds the answer slot unless the user expanded it`() {
        val nodes = SpecFixtures.projectCase("permission-flow")
        assertEquals(
            PendingFold.FOLDED,
            ChatScreenState.from(nodes, local = ChatLocalState(imeVisible = true)).pendingFold,
        )
        assertEquals(
            PendingFold.EXPANDED,
            ChatScreenState.from(
                nodes,
                local = ChatLocalState(imeVisible = true, pendingSlotExpanded = true),
            ).pendingFold,
        )
        assertEquals(PendingFold.EXPANDED, ChatScreenState.from(nodes).pendingFold)
        // No ask on screen: the keyboard has nothing to fold.
        assertEquals(
            PendingFold.EXPANDED,
            ChatScreenState.from(
                SpecFixtures.projectCase("chat-basic"),
                local = ChatLocalState(imeVisible = true),
            ).pendingFold,
        )
    }

    @Test
    fun `the composer lock names why the dock is unusable`() {
        assertEquals(ComposerLock.WAITING_ENGINE, ChatScreenState.from(emptyList()).composerLock)
        assertEquals(
            ComposerLock.PENDING_ANSWER,
            ChatScreenState.from(SpecFixtures.projectCase("permission-flow")).composerLock,
        )
        val idle = ChatScreenState.from(SpecFixtures.projectCase("chat-basic"))
        assertEquals(ComposerLock.NONE, idle.composerLock)
        assertTrue(idle.composer.enabled)
        val answered = ChatScreenState.from(
            SpecFixtures.projectCase("permission-flow"),
            local = ChatLocalState(answeredRequestIds = setOf("perm-1")),
        )
        assertEquals("answering re-opens the dock", ComposerLock.NONE, answered.composerLock)
    }

    @Test
    fun `the empty state follows the host facts, not the row count`() {
        // ChatPage.swift `emptyTimeline`: A engine, B provider, C ready.
        assertEquals(ChatEmpty.ENGINE_NOT_STARTED, ChatScreenState.from(emptyList()).empty)
        assertEquals(
            ChatEmpty.PROVIDER_SETUP,
            ChatScreenState.from(
                emptyList(),
                host = ChatHostFacts(engineStarted = true, providerNeedsKey = true),
            ).empty,
        )
        assertEquals(
            ChatEmpty.READY,
            ChatScreenState.from(emptyList(), host = ChatHostFacts(engineStarted = true)).empty,
        )
        assertEquals(RunStatus.STOPPED, ChatScreenState.from(emptyList()).runStatus)
        assertEquals(
            RunStatus.PARKED,
            ChatScreenState.from(emptyList(), host = ChatHostFacts(engineStarted = true, parked = true)).runStatus,
        )
    }

    @Test
    fun `the composer placeholder and send label follow the running turn`() {
        // ChatPage.swift `composerPlaceholder` + `sendButtonLabel`.
        val idle = ChatScreenState.from(SpecFixtures.projectCase("chat-basic"))
        assertEquals(UiStrings.COMPOSER_PLACEHOLDER_IDLE, idle.composer.placeholder)
        assertEquals(UiStrings.COMPOSER_SEND_LABEL, idle.composer.sendLabel)

        val open = SpecFixtures.projectCase("chat-basic")
            .filterNot { it.kind == UiStateKind.STATUS }
        val queue = ChatScreenState.from(
            open,
            local = ChatLocalState(draft = "下一句"),
            host = ChatHostFacts(engineStarted = true, canSend = true),
        )
        assertEquals(ChatPhase.RUNNING, queue.phase)
        assertEquals(UiStrings.COMPOSER_PLACEHOLDER_QUEUE, queue.composer.placeholder)
        assertEquals(UiStrings.COMPOSER_SEND_LABEL_QUEUE, queue.composer.sendLabel)
        // A running turn with a submittable draft keeps the send key.
        assertEquals(ComposerMode.SEND, queue.composer.mode)
        assertTrue(queue.composer.canSubmit)

        val steer = ChatScreenState.from(
            open,
            local = ChatLocalState(
                draft = "补充",
                attachments = listOf(ChatAttachment(name = "a.png", image = true)),
            ),
            host = ChatHostFacts(engineStarted = true, canSteer = true, enterMode = EnterMode.STEER),
        )
        assertEquals(UiStrings.COMPOSER_PLACEHOLDER_STEER, steer.composer.placeholder)
        // Steering cannot carry an image, so the draft is not submittable and the
        // main key becomes the stop key (iOS `canSubmit`).
        assertFalse(steer.composer.canSubmit)
        assertEquals(ComposerMode.STOP, steer.composer.mode)
    }

    @Test
    fun `queued messages are the rows the badge marks`() {
        // ChatPage.swift `queuedMessages`: rows whose queueLabel is 已排队.
        val nodes = SpecFixtures.projectCase("chat-basic")
        val userId = nodes.first { it.kind == UiStateKind.BUBBLE }.nodeID
        val state = ChatScreenState.from(
            nodes,
            local = ChatLocalState(badges = mapOf(userId to UiStrings.QUEUED_TAG)),
        )
        assertEquals(1, state.composer.queuedCount)
        assertEquals("Summarize /dsh/workspace/notes/a.md", state.composer.queued.single())
    }

    @Test
    fun `a failed row id turns the banner into a per-row failure line`() {
        // ChatPage.swift `failedItemID` + `userFacingError`.
        val nodes = SpecFixtures.projectCase("turn-error-vs-complete")
        val state = ChatScreenState.from(nodes, host = ChatHostFacts(failedItemID = "row-7"))
        assertEquals("row-7", state.failedItemID)
        assertEquals("permission denied", state.userFacingError)
    }

    @Test
    fun `the slash menu opens only for a bare leading token`() {
        // ChatPage.swift `slashToken`: a leading `/` with no whitespace after it.
        val host = ChatHostFacts(
            commands = listOf(
                ComposerCommand("goal", "目标"),
                ComposerCommand("compact", "整理上下文"),
            ),
        )
        assertNull(ChatScreenState.from(emptyList(), local = ChatLocalState(draft = "hi /go"), host = host).composer.slash)
        assertNull(ChatScreenState.from(emptyList(), local = ChatLocalState(draft = "/go 目标"), host = host).composer.slash)
        val menu = ChatScreenState.from(emptyList(), local = ChatLocalState(draft = "/go"), host = host).composer.slash
        assertEquals(listOf("goal"), (menu as SlashMenu.Matches).commands.map { it.name })
        val empty = ChatScreenState.from(emptyList(), local = ChatLocalState(draft = "/zz"), host = host).composer.slash
        assertEquals(SlashMenu.Empty, empty)
        val loading = ChatScreenState.from(
            emptyList(),
            local = ChatLocalState(draft = "/"),
            host = ChatHostFacts(commandsLoading = true),
        ).composer.slash
        assertEquals(SlashMenu.Loading, loading)
    }

    @Test
    fun `the reference menu lists matching files and sessions`() {
        // ChatPage.swift `referenceToken` + `referenceFiles` + `referenceSessions`.
        val host = ChatHostFacts(
            files = listOf("notes/a.md", "src/b.kt"),
            sessionTitles = listOf("像素基线复盘"),
        )
        val menu = ChatScreenState.from(emptyList(), local = ChatLocalState(draft = "@note"), host = host)
            .composer.reference
        assertEquals(listOf("notes/a.md"), menu?.files)
        val bySession = ChatScreenState.from(emptyList(), local = ChatLocalState(draft = "@像素"), host = host)
            .composer.reference
        assertEquals(listOf("像素基线复盘"), bySession?.sessions)
        // A bare `@` lists files but never sessions (iOS returns [] for an empty token).
        val bare = ChatScreenState.from(emptyList(), local = ChatLocalState(draft = "@"), host = host).composer.reference
        assertEquals(listOf("notes/a.md", "src/b.kt"), bare?.files)
        assertTrue(bare!!.sessions.isEmpty())
    }

    @Test
    fun `the two composer menus are disabled while a turn runs or an ask pends`() {
        // ChatPage.swift: `.disabled(!canSend || turnRunning || pending…)` on both.
        val host = ChatHostFacts(engineStarted = true)
        val idle = ChatScreenState.from(SpecFixtures.projectCase("chat-basic"), host = host)
        assertTrue(idle.accessModeMenu.enabled)
        assertTrue(idle.modelMenu.enabled)
        val running = ChatScreenState.from(
            SpecFixtures.projectCase("chat-basic").filterNot { it.kind == UiStateKind.STATUS },
            host = host,
        )
        assertFalse(running.accessModeMenu.enabled)
        assertFalse(running.modelMenu.enabled)
        val pending = ChatScreenState.from(SpecFixtures.projectCase("permission-flow"), host = host)
        assertFalse(pending.accessModeMenu.enabled)
        assertFalse(pending.modelMenu.enabled)
    }

    @Test
    fun `a turn-closing assistant row is the one that carries the actions`() {
        // ChatPage.swift `isTurnClosingAssistant`.
        val nodes = SpecFixtures.projectCase("chat-basic")
        val state = ChatScreenState.from(nodes)
        val assistant = state.rows.filterIsInstance<ChatRow.Assistant>()
        assertEquals(1, assistant.size)
        assertTrue(assistant.single().closing)
        // The same turn, still open, has no closing row.
        val open = ChatScreenState.from(nodes.filterNot { it.kind == UiStateKind.STATUS })
        assertTrue(open.rows.filterIsInstance<ChatRow.Assistant>().none { it.closing })
    }

    @Test
    fun `a tool run keeps one entry per call and settles it with the turn`() {
        // NativeMessageRows/`ToolRunRow`: one disclosure line per call/result.
        val entries = ChatScreenState.from(SpecFixtures.projectCase("permission-flow"))
            .rows.filterIsInstance<ChatRow.ToolRun>().flatMap { it.entries }
        assertEquals(1, entries.size)
        assertEquals("exec", entries.single().title)
        assertEquals("uid=1000", entries.single().body)
    }

    private fun stateOf(case: String): ChatScreenState = ChatScreenState.from(SpecFixtures.projectCase(case))

    /** The three structural nodes every session has, in pre-order. */
    private fun structural(): List<UiStateNode> = listOf(
        base(UiStateKind.ROOT, "root", "root", "-"),
        base(UiStateKind.SESSION, "session/s1", "root", "-"),
        base(UiStateKind.TURN, "session/s1/turn/turn-0001", "session/s1", "turn-0001"),
    )

    private fun base(kind: UiStateKind, nodeID: String, parentID: String, turnID: String): UiStateNode =
        UiStateNode(
            kind = kind,
            nodeID = nodeID,
            parentID = parentID,
            sessionID = "s1",
            turnID = turnID,
            seq = 0,
        )

    private fun turnNode(): UiStateNode = structural().last()

    private fun approval(slot: String, requestId: String, kind: String, text: String): UiStateNode = node(
        kind = UiStateKind.APPROVAL_CARD,
        slot = slot,
        surface = UiStateSurface.APPROVAL_CARD,
        text = text,
        props = mapOf("kind" to JsonString(kind), "requestId" to JsonString(requestId)),
    )

    private fun node(
        kind: UiStateKind,
        slot: String,
        surface: UiStateSurface,
        text: String?,
        props: Map<String, com.phonedsh.agentcore.JsonValue>,
    ): UiStateNode = UiStateNode(
        kind = kind,
        nodeID = "session/s1/turn/turn-0001/event/1/$slot",
        parentID = "session/s1/turn/turn-0001",
        sessionID = "s1",
        turnID = "turn-0001",
        seq = 1,
        surface = surface,
        text = text,
        props = JsonObject(props.toSortedMap()),
    )
}
