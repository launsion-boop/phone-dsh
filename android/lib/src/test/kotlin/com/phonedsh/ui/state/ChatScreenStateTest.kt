// ScreenState acceptance: same input -> same row sequence (never a screenshot).
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/README.md` §6 rule ③ says ScreenState must be a pure function of
// (UiState + local UI events) so it can be replayed in a JVM test. These tests
// replay the golden projections and assert the *sequence* of visible rows, the
// pending-answer slot, the fail-loud banners and the composer state.
package com.phonedsh.ui.state

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.HarnessEvent
import com.phonedsh.agentcore.HarnessKind
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.projection.UiStateProjector
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
    fun `stale async success cannot settle a later request or another session`() {
        val active = StateRequestId("new-form")
        val old = StateRequest(StateRequestId("old-form"), "s1", StateRevision(4), "old success")
        assertFalse(old.isCurrent(active, "s1", StateRevision(5)))
        assertFalse(old.isCurrent(active, "s2", StateRevision(4)))
        val current = StateRequest(active, "s1", StateRevision(5), "current success")
        assertTrue(current.isCurrent(active, "s1", StateRevision(5)))
    }

    @Test
    fun `older and wrong-session snapshots cannot replace restored newer state`() {
        val restored = RevisionedSnapshot("s1", StateRevision(12), listOf("restored"))
        val old = acceptSnapshot(restored, "s1", RevisionedSnapshot("s1", StateRevision(10), listOf("old")))
        assertEquals(SnapshotUpdate.IgnoredOlder(restored), old)
        val switched = acceptSnapshot(restored, "s2", RevisionedSnapshot("s1", StateRevision(13), listOf("wrong session")))
        assertEquals(SnapshotUpdate.WrongSession<String>("s2", "s1"), switched)
        val fresh = RevisionedSnapshot("s2", StateRevision(1), listOf("new session"))
        assertEquals(SnapshotUpdate.Applied(fresh), acceptSnapshot(restored, "s2", fresh))
        assertEquals(
            SnapshotUpdate.Applied(RevisionedSnapshot("s1", StateRevision(1), listOf("cold restore"))),
            acceptSnapshot(null, "s1", RevisionedSnapshot("s1", StateRevision(1), listOf("cold restore"))),
        )
        assertEquals(
            SessionBindingResult.Retained("s1", "s2"),
            bindSession("s1", "s2", SessionChangeCause.INCIDENTAL_RESPONSE),
        )
        assertEquals(
            SessionBindingResult.Bound("s2"),
            bindSession("s1", "s2", SessionChangeCause.SESSION_NOT_FOUND),
        )
    }

    @Test
    fun `session switch clears scoped forms without dropping the user's draft`() {
        val state = ChatScreenState.from(
            structural(),
            local = ChatLocalState(
                draft = "keep this input",
                sessionID = "old-session",
                answeredRequestIds = setOf("old-request"),
                attachments = listOf(ChatAttachment("photo.png", image = true)),
            ),
        )
        assertEquals("keep this input", state.composer.draft)
        assertTrue(state.pending.isEmpty)
        assertTrue(state.composer.attachments.isEmpty())
    }

    @Test
    fun `multi-answer question form retains selections custom input and validates every step`() {
        val form = QuestionFormState(
            index = 1,
            questionIds = listOf("features", "other"),
            answers = mapOf("features" to listOf("voice", "camera")),
        )
        assertEquals("other", form.currentQuestionId)
        assertTrue(form.canGoBack)
        assertFalse(form.canGoForward)
        assertEquals(listOf("other"), form.missingRequiredQuestionIds)
        assertFalse(form.complete)
        val completed = form.copy(customAnswers = mapOf("other" to "something else"))
        assertTrue(completed.complete)
        assertEquals(listOf("voice", "camera"), completed.answers["features"])
    }

    @Test
    fun `queue reconciliation preserves actionable durable IDs beside duplicate local echoes`() {
        val durable = listOf(
            ManagedQueueItemState(QueueItemId.Durable("d1"), "same text", QueueItemStatus.QUEUED),
            ManagedQueueItemState(QueueItemId.Durable("d2"), "same text", QueueItemStatus.QUEUED),
        )
        val local = listOf(
            ManagedQueueItemState(QueueItemId.Local("l1"), "same text", QueueItemStatus.QUEUED),
            ManagedQueueItemState(QueueItemId.Local("l2"), "same text", QueueItemStatus.SENDING),
        )
        val merged = reconcileQueueRows(durable, local)
        assertEquals(4, merged.size)
        assertEquals(
            listOf(QueueItemId.Durable("d1"), QueueItemId.Durable("d2"), QueueItemId.Local("l1"), QueueItemId.Local("l2")),
            merged.map { it.id },
        )
        assertEquals(QueueItemStatus.SENDING, merged.last().state)
        assertTrue(merged.take(2).all { (it.id as? QueueItemId.Durable) != null })
    }

    @Test
    fun `retiring one confirmed local prompt preserves durable and identical unrelated rows`() {
        val prompt = StateRequestId("prompt-one")
        val otherPrompt = StateRequestId("prompt-two")
        val durable = listOf(
            ManagedQueueItemState(QueueItemId.Durable("d1"), "same text", QueueItemStatus.QUEUED),
            ManagedQueueItemState(QueueItemId.Durable("d2"), "same text", QueueItemStatus.QUEUED),
        )
        val local = listOf(
            ManagedQueueItemState(
                id = QueueItemId.Local("local-one"), text = "same text", state = QueueItemStatus.QUEUED,
                promptRequestId = prompt,
            ),
            ManagedQueueItemState(
                id = QueueItemId.Local("local-two"), text = "same text", state = QueueItemStatus.QUEUED,
                promptRequestId = otherPrompt,
            ),
        )

        val afterOneAck = reconcileQueueRows(durable, retireAcceptedQueuePrompt(local, prompt))
        assertEquals(listOf(QueueItemId.Durable("d1"), QueueItemId.Durable("d2"), QueueItemId.Local("local-two")), afterOneAck.map { it.id })
        assertEquals(otherPrompt, afterOneAck.last().promptRequestId)
    }

    @Test
    fun `durable row with the same source rpc id replaces its local sending echo`() {
        val prompt = StateRequestId("prompt-accepted")
        val durable = ManagedQueueItemState(
            id = QueueItemId.Durable("q-accepted"),
            text = "accepted text",
            state = QueueItemStatus.QUEUED,
            promptRequestId = prompt,
        )
        val local = ManagedQueueItemState(
            id = QueueItemId.Local("local-echo"),
            text = "accepted text",
            state = QueueItemStatus.SENDING,
            promptRequestId = prompt,
        )

        val merged = reconcileQueueRows(listOf(durable), listOf(local))

        assertEquals(listOf(QueueItemId.Durable("q-accepted")), merged.map { it.id })
        assertEquals(QueueItemStatus.SENDING, local.state)
    }

    @Test
    fun `an observed durable prompt retires its local echo before it can reappear`() {
        val prompt = StateRequestId("prompt-observed")
        val durable = listOf(
            ManagedQueueItemState(
                id = QueueItemId.Durable("q-observed"),
                text = "accepted text",
                promptRequestId = prompt,
            ),
        )
        val local = listOf(
            ManagedQueueItemState(
                id = QueueItemId.Local("local-echo"),
                text = "accepted text",
                state = QueueItemStatus.SENDING,
                promptRequestId = prompt,
            ),
            ManagedQueueItemState(
                id = QueueItemId.Local("unrelated"),
                text = "not accepted yet",
                state = QueueItemStatus.SENDING,
                promptRequestId = StateRequestId("prompt-other"),
            ),
        )

        val remaining = retireQueuePromptsPresentIn(local, durable)

        assertEquals(listOf(QueueItemId.Local("unrelated")), remaining.map { it.id })
    }

    @Test
    fun `host receipts and scopes remain explicit and unknown facts stay null`() {
        val host = ChatHostFacts(
            plan = PlanApprovalState(StateRequestId("plan"), "# Plan", PlanApprovalStatus.PENDING),
            commandReceipts = listOf(
                CommandExecutionReceipt(StateRequestId("cmd"), "clear", outcome = CommandOutcome.FAILED, message = "offline"),
                CommandExecutionReceipt(StateRequestId("cmd-2"), "pause", outcome = CommandOutcome.SUCCEEDED),
            ),
            artifacts = listOf(ArtifactReference("a", "result.txt", scope = ArtifactScope.UNKNOWN)),
            contextLost = ContextLostReceipt(StateRequestId("lost"), "s1", "Session context expired"),
            snapshotRevision = StateRevision(7),
        )
        val state = ChatScreenState.from(structural(), host = host)
        assertEquals(PlanApprovalStatus.PENDING, state.plan?.status)
        assertEquals(listOf(CommandOutcome.FAILED, CommandOutcome.SUCCEEDED), state.commandReceipts?.map { it.outcome })
        assertEquals(ArtifactScope.UNKNOWN, state.artifacts?.single()?.scope)
        assertTrue(state.contextLost != null)
        assertNull(state.modelMenu.currentEffort)
    }

    @Test
    fun `tool run preview is one line and expanded entry keeps full result`() {
        val call = node(
            kind = UiStateKind.TOOL_ROW,
            slot = "tool-call",
            surface = UiStateSurface.TOOL_ROW,
            text = "bash",
            props = mapOf("callId" to JsonString("c1"), "name" to JsonString("bash"), "phase" to JsonString("call")),
        )
        val body = "a,b\n1,2"
        val result = node(
            kind = UiStateKind.TOOL_ROW,
            slot = "tool-result",
            surface = UiStateSurface.TOOL_ROW,
            text = body,
            props = mapOf("callId" to JsonString("c1"), "name" to JsonString("bash"), "phase" to JsonString("result"), "body" to JsonString(body)),
        )
        val run = visibleRows(ChatScreenState.from(structural() + call + result).rows)
            .filterIsInstance<ChatRow.ToolRun>().single()
        assertEquals("a,b", run.summary)
        assertEquals(body, run.entries.single().body)
    }

    @Test
    fun `thinking keeps collapsed summary separate from full disclosure text`() {
        val full = "First reasoning paragraph.\n\nSecond reasoning paragraph."
        val thinking = node(
            kind = UiStateKind.THINKING_PILL,
            slot = "thinking",
            surface = UiStateSurface.THINKING_PILL,
            text = "Second reasoning paragraph.",
            props = mapOf("streaming" to com.phonedsh.agentcore.JsonBool(false), "fullReasoning" to JsonString(full)),
        )
        val row = ChatScreenState.from(structural() + thinking).rows
            .flatMap { visibleRows(listOf(it)) }
            .filterIsInstance<ChatRow.Thinking>().single()
        assertEquals("Second reasoning paragraph.", row.summary)
        assertEquals(full, row.fullReasoning)
        assertNull(row.fullReasoningTruncated)
    }

    @Test
    fun `reasoning event through UiState into screen keeps markdown body and settled summary`() {
        val full = "Inspect the inputs.\n\n**Plan**: compare each option.\nKeep the full markdown body."
        val events = listOf(
            HarnessEvent("s1", 0L, 1L, HarnessKind.TurnStarted("1")),
            HarnessEvent("s1", 1L, null, HarnessKind.ReasoningDelta(full)),
            HarnessEvent("s1", 2L, 2L, HarnessKind.AssistantMessage("Done")),
        )
        val nodes = UiStateProjector.project(events)
        val pill = nodes.single { it.kind == UiStateKind.THINKING_PILL }
        assertEquals("Plan: compare each option.", pill.text)
        assertEquals(full, (pill.props["fullReasoning"] as JsonString).value)
        val row = visibleRows(ChatScreenState.from(nodes).rows).filterIsInstance<ChatRow.Thinking>().single()
        assertEquals("Plan: compare each option.", row.summary)
        assertEquals(full, row.fullReasoning)
        assertEquals(false, row.fullReasoningTruncated)
    }

    @Test
    fun `todo dock rows pass through only from host facts`() {
        val todo = TodoDockItem(id = "t1", content = "Review changes", status = "in_progress")
        assertEquals(listOf(todo), ChatScreenState.from(emptyList(), host = ChatHostFacts(todoItems = listOf(todo))).todoItems)
        assertTrue(ChatScreenState.from(emptyList()).todoItems.isEmpty())
    }

    @Test
    fun `question items retain host fields and leave unreported metadata unknown`() {
        val item = JsonObject(
            mapOf(
                "id" to JsonString("color"),
                "header" to JsonString("Preference"),
                "prompt" to JsonString("Choose a color"),
                "detail" to JsonString("Pick one."),
                "options" to JsonArray(
                    listOf(
                        JsonObject(mapOf("label" to JsonString("blue (recommended)"), "description" to JsonString("Cool"))),
                        JsonObject(mapOf("label" to JsonString("green"))),
                    ),
                ),
                "multiple" to com.phonedsh.agentcore.JsonBool(false),
                "intentKind" to JsonString("plan-review"),
                "approveWireLabel" to JsonString("approve"),
                "recommendedWireLabel" to JsonString("blue (recommended)"),
            ),
        )
        val ask = approval("question-request", "q-1", "question", "Choose a color").copy(
            props = JsonObject(
                mapOf(
                    "kind" to JsonString("question"),
                    "requestId" to JsonString("q-1"),
                    "multiple" to com.phonedsh.agentcore.JsonBool(false),
                    "questionItems" to JsonArray(listOf(item)),
                    "channelAvailable" to com.phonedsh.agentcore.JsonBool(true),
                    "submitting" to com.phonedsh.agentcore.JsonBool(false),
                    "submissionError" to JsonString("try again"),
                    "initialProgress" to JsonObject(
                        mapOf(
                            "index" to com.phonedsh.agentcore.JsonNumber("0"),
                            "drafts" to JsonObject(mapOf("color" to JsonArray(listOf(JsonString("blue (recommended)"))))),
                        ),
                    ),
                ),
            ),
        )
        val question = requireNotNull(
            ChatScreenState.from(
                structural() + ask,
                local = ChatLocalState(
                    pendingAnswerActions = mapOf(
                        StateRequestId("q-1") to PendingAnswerActionState(
                            StateRequestId("q-1"), PendingAnswerAction.SUBMIT, PendingAnswerActionStatus.FAILED, "retry me",
                        ),
                    ),
                ),
            ).pending.primary,
        )
        assertEquals("color", question.questionItems.single().id)
        assertEquals("Choose a color", question.questionItems.single().prompt)
        val typed = question.questionItems.single()
        assertEquals(listOf("blue (recommended)", "green"), typed.options.map { it.label })
        assertEquals("Cool", typed.options.first().description)
        assertEquals("Preference", typed.header)
        assertEquals("Pick one.", typed.detail)
        assertEquals("plan-review", typed.intentKind)
        assertEquals("approve", typed.approveWireLabel)
        assertEquals("blue (recommended)", typed.recommendedWireLabel)
        assertEquals(true, question.channelAvailable)
        assertEquals(false, question.submitting)
        assertEquals("try again", question.submissionError)
        assertEquals(0, question.initialProgress?.index)
        assertEquals(listOf("blue (recommended)"), question.initialProgress?.drafts?.get("color"))
        assertEquals("color", question.form?.currentQuestionId)
        assertEquals(listOf("blue (recommended)"), question.form?.answers?.get("color"))
        assertEquals(PendingAnswerActionStatus.FAILED, question.actionState?.status)
        assertEquals("retry me", question.actionState?.error)
    }

    @Test
    fun `chat-basic folds its rows and closes the turn`() {
        val state = stateOf("chat-basic")
        val rows = visibleRows(state.rows)
        assertEquals(
            listOf(ChatRow.User::class, ChatRow.Assistant::class),
            rows.map { it::class },
        )
        assertEquals("Summarize /dsh/workspace/notes/a.md", (rows[0] as ChatRow.User).text)
        val process = state.rows.filterIsInstance<ChatRow.TurnProcess>().single()
        assertTrue("completed turns fold their process by default", !process.expanded && process.foldable)
        val run = visibleRows(process.entries).filterIsInstance<ChatRow.ToolRun>().single()
        assertEquals("read", run.title)
        // The fixture has no tool_result, and the turn closed, so the row cannot
        // still be running: it settles to "stopped" rather than shimmering forever.
        assertEquals(ToolRowState.STOPPED, run.state)
        assertEquals(UiStrings.TOOL_STOPPED, run.summary)
        assertEquals("Done.", (rows[1] as ChatRow.Assistant).text)
        assertEquals(ChatPhase.IDLE, state.phase)
        assertTrue(state.pending.isEmpty)
        assertTrue(state.banners.isEmpty())
        assertTrue("a closed turn leaves the composer usable", state.composer.enabled)
        assertEquals(ComposerMode.SEND, state.composer.mode)
        // The completed turn-end node exists in UiState but is not a visible row.
        val nodes = SpecFixtures.projectCase("chat-basic")
        assertTrue(nodes.any { it.kind == UiStateKind.STATUS && it.text == "completed" })
        assertTrue(rows.none { it is ChatRow.SystemEvent })
    }

    @Test
    fun `a closed turn carries its process fold and tail actions separately`() {
        val state = stateOf("chat-basic")
        val process = state.rows.filterIsInstance<ChatRow.TurnProcess>().single()
        assertEquals(ChatTurnState.COMPLETED, process.outcome)
        assertTrue(process.foldable)
        assertFalse(process.expanded)
        assertEquals("Done.", process.closingAssistant?.text)
        val group = process.entries.filterIsInstance<ChatRow.ProcessGroup>().single()
        assertEquals("已读取文件", group.title)
        assertFalse(group.running)
        assertFalse(group.showsHeader)
        val tail = state.rows.filterIsInstance<ChatRow.TurnTail>().single()
        assertEquals("Done.", tail.assistantText)
        assertNull(tail.timeMillis)
        assertNull(tail.usage)
        assertFalse(tail.feedbackAvailable)
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
        val rows = visibleRows(state.rows)
        assertEquals(1, rows.count { it is ChatRow.ToolRun })
        val run = rows.single { it is ChatRow.ToolRun } as ChatRow.ToolRun
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
        val rows = visibleRows(state.rows)
        assertEquals(ChatRow.User::class, rows.first()::class)
        assertEquals(ChatRow.SystemEvent::class, rows.last()::class)
        assertTrue(rows.drop(1).dropLast(1).all { it is ChatRow.ToolRun || it is ChatRow.Assistant })
        // The host's wire word is not copy: the row carries the translated title
        // (the cause text lives in the fail-loud banner above the list).
        val event = rows.last() as ChatRow.SystemEvent
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
        assertEquals(ToolRowState.RUNNING, (visibleRows(state.rows).single() as ChatRow.ToolRun).state)
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
        assertEquals(GoalPhase.ACTIVE, GoalBarState.Visible("active", "ship F6", phaseKind = GoalPhase.ACTIVE).phaseKind)
        assertEquals("1.2k tokens", visible.stats)
        assertNull(visibleRows(visible.rows).firstOrNull { it is ChatRow.SystemEvent })
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
        val assistant = visibleRows(state.rows).filterIsInstance<ChatRow.Assistant>()
        assertEquals(1, assistant.size)
        assertTrue(assistant.single().closing)
        // The same turn, still open, has no closing row.
        val open = ChatScreenState.from(nodes.filterNot { it.kind == UiStateKind.STATUS })
        assertTrue(visibleRows(open.rows).filterIsInstance<ChatRow.Assistant>().none { it.closing })
    }

    @Test
    fun `a tool run keeps one entry per call and settles it with the turn`() {
        // NativeMessageRows/`ToolRunRow`: one disclosure line per call/result.
        val entries = visibleRows(ChatScreenState.from(SpecFixtures.projectCase("permission-flow")).rows)
            .filterIsInstance<ChatRow.ToolRun>().flatMap { it.entries }
        assertEquals(1, entries.size)
        assertEquals("exec", entries.single().title)
        assertEquals("uid=1000", entries.single().body)
    }

    @Test
    fun `tool detail carrier preserves call arguments result body metadata and file path`() {
        val args = JsonObject(
            mapOf(
                "file_path" to JsonString("src/main.kt"),
                "old_string" to JsonString("before"),
                "new_string" to JsonString("after"),
            ),
        )
        val call = node(
            kind = UiStateKind.TOOL_ROW,
            slot = "tool-call",
            surface = UiStateSurface.TOOL_ROW,
            text = "edit",
            props = mapOf(
                "callId" to JsonString("edit-1"),
                "name" to JsonString("edit"),
                "phase" to JsonString("call"),
                "state" to JsonString("running"),
                "arguments" to args,
            ),
        )
        val body = "changed one line\nwith details"
        val meta = JsonObject(mapOf("durationMs" to com.phonedsh.agentcore.JsonNumber("25")))
        val result = node(
            kind = UiStateKind.TOOL_ROW,
            slot = "tool-result",
            surface = UiStateSurface.TOOL_ROW,
            text = "changed one line",
            props = mapOf(
                "callId" to JsonString("edit-1"),
                "phase" to JsonString("result"),
                "state" to JsonString("ok"),
                "body" to JsonString(body),
                "meta" to meta,
            ),
        )
        val entry = visibleRows(ChatScreenState.from(structural() + call + result).rows)
            .filterIsInstance<ChatRow.ToolRun>().single().entries.single()
        assertEquals("src/main.kt", entry.filePath)
        assertEquals(ToolVariant.EDIT, entry.variant)
        assertEquals(args, entry.arguments)
        assertEquals(body, entry.body)
        assertEquals(meta, entry.metadata)
        assertEquals("after", entry.arguments?.string("new_string"))
    }

    private fun stateOf(case: String): ChatScreenState = ChatScreenState.from(SpecFixtures.projectCase(case))

    private fun visibleRows(rows: List<ChatRow>): List<ChatRow> = rows.flatMap { row ->
        when (row) {
            is ChatRow.ProcessGroup -> visibleRows(row.entries)
            is ChatRow.TurnProcess -> if (row.expanded) visibleRows(row.entries) else listOfNotNull(row.closingAssistant)
            is ChatRow.TurnTail -> emptyList()
            else -> listOf(row)
        }
    }

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
