// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.fish.BotFishOneShot
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The round-2 owner decisions and the pure timing/name/lifecycle sub-rules
 * that the shared vectors do not reach directly: UI-1 (one fish projection),
 * UI-2 (a failed dismiss is retryable), the 800 ms activity hold, the 60-unit
 * name cap, the info load states and the deep-link router.
 */
class BotUiStateRulesTest {
    // ---- UI-1: one shared fish-lifecycle projection -------------------------

    @Test
    fun fishPendingApprovalBeatsEverything() {
        assertEquals(
            BotFishLifecycle.ALERTING,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    pendingApprovalCount = 1,
                    running = true,
                    idleSleeping = true,
                    livePresentation = presentation(
                        BotFishLifecycle.HAPPY, oneShot = celebrate(now = NOW)),
                    durablePresentation = presentation(BotFishLifecycle.WORKING),
                    liveTurn = true,
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishUnexpiredOneShotWins() {
        assertEquals(
            BotFishLifecycle.CELEBRATE,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    running = false,
                    livePresentation = presentation(
                        BotFishLifecycle.IDLE, oneShot = celebrate(now = NOW)),
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishExpiredOneShotIsIgnored() {
        assertEquals(
            BotFishLifecycle.WORKING,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    running = false,
                    durablePresentation = presentation(
                        BotFishLifecycle.WORKING,
                        oneShot = BotFishOneShot(
                            state = BotFishLifecycle.CELEBRATE,
                            priority = 70,
                            startedAt = NOW - 5_000,
                            endsAt = NOW - 1,
                        ),
                    ),
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishLivePresentationWinsWhileALiveTurnExists() {
        assertEquals(
            BotFishLifecycle.STREAMING,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    livePresentation = presentation(BotFishLifecycle.STREAMING),
                    durablePresentation = presentation(BotFishLifecycle.WORKING),
                    liveTurn = true,
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishDurablePresentationWinsWithoutALiveTurn() {
        assertEquals(
            BotFishLifecycle.WORKING,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    livePresentation = presentation(BotFishLifecycle.STREAMING),
                    durablePresentation = presentation(BotFishLifecycle.WORKING),
                    liveTurn = false,
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishLiveOneShotIsCheckedBeforeTheDurableOneShot() {
        val liveShot = BotFishOneShot(
            state = BotFishLifecycle.HAPPY, priority = 60,
            startedAt = NOW - 100, endsAt = NOW + 1_000)
        val durableShot = BotFishOneShot(
            state = BotFishLifecycle.CELEBRATE, priority = 60,
            startedAt = NOW - 100, endsAt = NOW + 1_000)
        assertEquals(
            BotFishLifecycle.HAPPY,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    livePresentation = BotRuntimePresentation(
                        fishState = BotFishLifecycle.SPEAKING, oneShot = liveShot),
                    durablePresentation = BotRuntimePresentation(
                        fishState = BotFishLifecycle.THINKING, oneShot = durableShot),
                    liveTurn = true,
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishLiveTurnWithoutALivePresentationUsesTheDurableBase() {
        assertEquals(
            BotFishLifecycle.THINKING,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    livePresentation = null,
                    durablePresentation = presentation(BotFishLifecycle.THINKING),
                    liveTurn = true,
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishRunningCoercesIdleToWorking() {
        assertEquals(
            BotFishLifecycle.WORKING,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    running = true,
                    durablePresentation = presentation(BotFishLifecycle.IDLE),
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishRunningKeepsANonIdleState() {
        assertEquals(
            BotFishLifecycle.THINKING,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    running = true,
                    durablePresentation = presentation(BotFishLifecycle.THINKING),
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishIdleSleepingBecomesSleepingWhenNotRunning() {
        assertEquals(
            BotFishLifecycle.SLEEPING,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    idleSleeping = true,
                    durablePresentation = presentation(BotFishLifecycle.IDLE),
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishIdleSleepingDoesNotOverrideRunning() {
        assertEquals(
            BotFishLifecycle.WORKING,
            BotFishProjection.resolve(
                BotFishProjectionInput(
                    running = true,
                    idleSleeping = true,
                    durablePresentation = presentation(BotFishLifecycle.IDLE),
                    now = NOW,
                ),
            ),
        )
    }

    @Test
    fun fishWithNoPresentationIsIdle() {
        assertEquals(
            BotFishLifecycle.IDLE,
            BotFishProjection.resolve(
                BotFishProjectionInput(running = false, now = NOW),
            ),
        )
    }

    // ---- UI-2: failed action retry policy -----------------------------------

    @Test
    fun failedDismissIsRetryable() {
        val row = questionRow()
        var machine = BotActionStateMachine().beginDismiss(row)!!
        machine = machine.finish(BotActionKeys.dismiss(row.id), BotActionResult.Rejected("offline"))
        assertTrue(machine.state(BotActionKeys.dismiss(row.id)) is BotActionState.Failed)
        assertNotNull("failed dismiss must be retryable (UI-2)", machine.beginDismiss(row))
        assertFalse("a failed dismiss must not settle", row.id in machine.dismissedCardIDs)
    }

    @Test
    fun pendingAndAcceptedTapsAreIgnored() {
        val row = questionRow()
        val pending = BotActionStateMachine().beginDismiss(row)!!
        assertNull("second tap while pending", pending.beginDismiss(row))
        val accepted = pending.finish(
            BotActionKeys.dismiss(row.id), BotActionResult.Accepted("event-1"))
        assertNull("tap while accepted", accepted.beginDismiss(row))
        assertTrue("accepted dismiss settles", row.id in accepted.dismissedCardIDs)
    }

    @Test
    fun failedAnswerAndApprovalAndChatAreRetryable() {
        val question = questionRow()
        var machine = BotActionStateMachine().beginAnswer(question, "library")!!
        machine = machine.finish(BotActionKeys.card(question.id), BotActionResult.Rejected("x"))
        assertNotNull(machine.beginAnswer(question, "library"))

        val approval = approvalRow()
        var approvalMachine = BotActionStateMachine().beginApproval(approval)!!
        approvalMachine = approvalMachine.finish(
            BotActionKeys.approval(approval.id), BotActionResult.Stale("digest_mismatch"))
        assertNotNull(approvalMachine.beginApproval(approval))

        val chat = BotActionStateMachine().beginChat("local-1")!!
        val failedChat = chat.finish(
            BotActionKeys.chat("local-1"), BotActionResult.Rejected("offline"))
        assertNotNull(failedChat.beginChat("local-1"))
    }

    @Test
    fun stepsDismissIsRejected() {
        val steps = row(
            "steps",
            BotJson.objectOf(
                "type" to JsonString("widget"),
                "cardType" to JsonString("steps"),
                "steps" to JsonArray(listOf(
                    BotJson.objectOf("label" to JsonString("继续"))))),
        )
        assertNull(BotActionStateMachine().beginDismiss(steps))
        assertNotNull(BotActionStateMachine().beginAnswer(steps, "step-0"))
    }

    @Test
    fun mutedOrBlankAnswerIsRejected() {
        val row = questionRow()
        assertNull(BotActionStateMachine().beginAnswer(row, "library", listOf(row.id)))
        assertNull(BotActionStateMachine().beginAnswer(row, ""))
    }

    @Test
    fun autoDeclineMarksPendingThenRecordsAccepted() {
        val approval = approvalRow()
        val machine = BotActionStateMachine().markAwaitingApprovalsPending(listOf(approval))
        assertTrue(machine.state(BotActionKeys.approval(approval.id)) is BotActionState.Pending)
        val accepted = machine.finishAutoDecline(
            approval.id, BotActionResult.Accepted("event-deny"))
        assertTrue(approval.id in accepted.autoDeclinedApprovalIDs)
        val rejected = machine.finishAutoDecline(
            approval.id, BotActionResult.Rejected("offline"))
        assertFalse(approval.id in rejected.autoDeclinedApprovalIDs)
    }

    // ---- activity-line timing ----------------------------------------------

    @Test
    fun activityHoldsForMinimumVisibleWindow() {
        val state = BotActivityLineState()
        val first = BotActivity(BotActivityStatus.THINKING, "", BotActivityCategory.GENERIC, 0)
        val second = BotActivity(BotActivityStatus.THINKING, "", BotActivityCategory.READING, 0)
        state.receive(first, 0)
        assertEquals("处理中…", state.text)
        assertEquals(2_400L, state.nextDeadline)
        state.receive(second, 500)
        assertEquals("a different activity inside 800 ms is held", "处理中…", state.text)
        assertEquals(800L, state.nextDeadline)
        state.tick(800)
        assertEquals("在翻文件", state.text)
    }

    @Test
    fun activityRotatesEvery2400ms() {
        val state = BotActivityLineState()
        state.receive(BotActivity(BotActivityStatus.THINKING, "", BotActivityCategory.THINKING, 0), 0)
        assertEquals("思考中…", state.text)
        assertEquals(2_400L, state.nextDeadline)
        state.tick(2_400)
        assertEquals("整理思绪…", state.text)
        assertEquals(4_800L, state.nextDeadline)
    }

    @Test
    fun activityMinuteSuffixAndDeadline() {
        val startedAt = NOW - 61_000
        val state = BotActivityLineState()
        state.receive(
            BotActivity(BotActivityStatus.THINKING, "", BotActivityCategory.THINKING, startedAt),
            NOW,
        )
        assertEquals("思考中… · 1 分钟", state.text)
        assertEquals(NOW + 2_400, state.nextDeadline)
    }

    @Test
    fun nilActivityHidesImmediately() {
        val state = BotActivityLineState()
        state.receive(BotActivity(BotActivityStatus.THINKING, "", BotActivityCategory.GENERIC, 0), 0)
        state.receive(null, 100)
        assertEquals("", state.text)
        assertNull(state.nextDeadline)
        assertNull(state.activity)
    }

    // ---- row/batch seam -----------------------------------------------------

    @Test
    fun batchDeletesStoredRowsBeforeApplyingIncoming() {
        val first = textRow("first", "a")
        val second = textRow("second", "b")
        val third = textRow("third", "c")
        val state = BotTranscriptState(rows = listOf(first, second)).apply(
            BotRowBatch(rows = listOf(third), deletes = listOf("first"), cursor = 7, reset = false),
        )
        assertEquals(listOf("second", "third"), state.rows.map { it.id })
        assertEquals(7L, state.watchCursor)
    }

    @Test
    fun resetKeepsLocalRowsAndAdoptsTheLastFifty() {
        val local = textRow("local-1", "draft")
        val old = textRow("old", "old")
        val incoming = (0 until 60).map { textRow("r$it", "t$it") }
        val state = BotTranscriptState(rows = listOf(old, local)).apply(
            BotRowBatch(rows = incoming, deletes = emptyList(), cursor = 99, reset = true),
        )
        assertEquals(51, state.rows.size)
        assertEquals("local-1", state.rows.first().id)
        assertEquals("r10", state.rows[1].id)
        assertEquals("r10", state.historyCursor)
        assertTrue(state.hasMoreHistory)
    }

    @Test
    fun largerUpdatedSeqReplacesAndSmallerDoesNot() {
        val stored = textRow("row", "stored").copy(updatedSeq = 5)
        val smaller = textRow("row", "smaller").copy(updatedSeq = 4)
        val larger = textRow("row", "larger").copy(updatedSeq = 6)
        var state = BotTranscriptState(rows = listOf(stored))
        state = state.apply(BotRowBatch(listOf(smaller), emptyList(), 1, false))
        assertEquals("stored", JsonSupport.string(state.rows.single().body["text"]))
        state = state.apply(BotRowBatch(listOf(larger), emptyList(), 2, false))
        assertEquals("larger", JsonSupport.string(state.rows.single().body["text"]))
    }

    @Test
    fun progressCardKeyUpdatesInPlaceAndDeletedBodyRemoves() {
        val progress = row(
            "p-old",
            BotJson.objectOf(
                "type" to JsonString("widget"),
                "cardType" to JsonString("progress"),
                "cardKey" to JsonString("k"),
                "title" to JsonString("生成中"),
            ),
        )
        val replacement = progress.copy(
            id = "p-new",
            updatedSeq = 2,
            body = progress.body.with("title", JsonString("完成")),
        )
        var state = BotTranscriptState(rows = listOf(progress))
            .apply(BotRowBatch(listOf(replacement), emptyList(), 1, false))
        assertEquals(listOf("p-new"), state.rows.map { it.id })
        val deleted = textRow("p-new", "x").copy(
            updatedSeq = 3,
            body = com.phonedsh.bot.rows.BotRowBody(
                type = com.phonedsh.bot.rows.BotRowBodyType.DELETED),
        )
        state = state.apply(BotRowBatch(listOf(deleted), emptyList(), 2, false))
        assertTrue(state.rows.isEmpty())
    }

    @Test
    fun errorNoticeArmsOnlyInANonResetBatch() {
        val notice = row(
            "notice",
            BotJson.objectOf(
                "type" to JsonString("notice"),
                "tone" to JsonString("error"),
                "text" to JsonString("生成报告失败。"),
            ),
        )
        val armed = BotTranscriptState().apply(
            BotRowBatch(listOf(notice), emptyList(), 1, false))
        assertEquals("生成报告失败。", armed.runtimeNotice)
        assertTrue("a notice is not a transcript row", armed.visibleRows().isEmpty())
        val replay = BotTranscriptState(rows = listOf(notice)).apply(
            BotRowBatch(listOf(notice), emptyList(), 2, true))
        assertNull("a reset batch never replays a notice", replay.runtimeNotice)
        assertNull(armed.clearRuntimeNotice().runtimeNotice)
    }

    // ---- name cap -----------------------------------------------------------

    @Test
    fun nameValidationAndCap() {
        assertNotNull(BotNameValidation.problem("   \n"))
        assertEquals(
            "名称最多 60 个字符，当前 61 个。",
            BotNameValidation.problem("a".repeat(61)),
        )
        assertNull(BotNameValidation.problem("a".repeat(60)))
        assertEquals(60, BotNameValidation.capped("a".repeat(61)).length)
        assertEquals("a".repeat(60), BotNameValidation.normalized("  ${"a".repeat(60)}  "))
        // A grapheme cluster is never split: 59 ASCII units + a family emoji
        // (11 UTF-16 units) cannot fit, so the emoji is dropped whole.
        val family = "\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67\u200D\uD83D\uDC66"
        val capped = BotNameValidation.capped("a".repeat(59) + family)
        assertEquals("a".repeat(59), capped)
        // A combining sequence is one cluster and is not split either.
        val combining = "a".repeat(60) + "e\u0301"
        assertEquals("a".repeat(60), BotNameValidation.capped(combining))
        // 31 emoji are 62 UTF-16 units; the cap keeps 30 whole emoji.
        val emoji = "\uD83D\uDE00"
        assertEquals(emoji.repeat(30), BotNameValidation.capped(emoji.repeat(31)))
    }

    // ---- info load states ---------------------------------------------------

    @Test
    fun infoStartsLoadingForADriverWithoutSnapshot() {
        val state = BotInfoModelState.initial(hasDriver = true)
        assertEquals(BotInfoLoadState.Loading, state.memoryState)
        assertEquals(BotInfoLoadState.Loading, state.routinesState)
        assertEquals(BotInfoLoadState.Loading, state.approvalsState)
    }

    @Test
    fun infoInjectedSnapshotIsLoaded() {
        val snapshot = BotInfoSnapshot.fromJson(infoFixture())
        val state = BotInfoModelState.initial(snapshot = snapshot)
        assertEquals(BotInfoLoadState.Loaded, state.memoryState)
        assertEquals(BotInfoLoadState.Loaded, state.routinesState)
        assertEquals(BotInfoLoadState.Loaded, state.approvalsState)
        assertEquals(2, state.snapshot!!.memories.size)
    }

    @Test
    fun infoFailureKeepsThePreviousSnapshotAndSetsAllThreeFailed() {
        val snapshot = BotInfoSnapshot.fromJson(infoFixture())
        val previous = BotInfoModelState.loaded(snapshot)
        val failed = BotInfoModelState.failed(previous, "offline")
        assertEquals(BotInfoLoadState.Failed("offline"), failed.memoryState)
        assertEquals(BotInfoLoadState.Failed("offline"), failed.routinesState)
        assertEquals(BotInfoLoadState.Failed("offline"), failed.approvalsState)
        assertEquals(snapshot, failed.snapshot)
    }

    // ---- deep-link router ---------------------------------------------------

    @Test
    fun deepLinkRouting() {
        assertEquals(
            BotDeepLinkOutcome.ScrollToRow("row-1"),
            BotDeepLinkResolution.resolve(
                "phonedsh://bot/main/row/row-1", "main-bot", listOf("row-1"), "main-bot"),
        )
        assertEquals(
            BotDeepLinkOutcome.Unavailable,
            BotDeepLinkResolution.resolve(
                "phonedsh://bot/other/row/row-1", "main-bot", listOf("row-1"), "main-bot"),
        )
        assertEquals(
            BotDeepLinkOutcome.Unavailable,
            BotDeepLinkResolution.resolve(
                "phonedsh://bot/main-bot/row/missing", "main-bot", listOf("row-1"), "main-bot"),
        )
        assertEquals(
            BotDeepLinkOutcome.OpenRoutine("main-bot", "routine-1"),
            BotDeepLinkResolution.resolve(
                "phonedsh://bot/main/routine/routine-1", "main-bot", emptyList(), "main-bot",
                setOf("routine-1")),
        )
        assertEquals(
            BotDeepLinkOutcome.Unavailable,
            BotDeepLinkResolution.resolve(
                "phonedsh://bot/main/routine/gone", "main-bot", emptyList(), "main-bot",
                setOf("routine-1")),
        )
        assertEquals(
            BotDeepLinkOutcome.Invalid,
            BotDeepLinkResolution.resolve(
                "https://bot/main/row/row-1", "main-bot", listOf("row-1"), "main-bot"),
        )
    }

    // ---- timers and appearance ---------------------------------------------

    @Test
    fun timerValuesAreTheFrozenOnes() {
        assertEquals(120_000L, BotTimers.AWAITING_TURN)
        assertEquals(6_000L, BotTimers.RUNTIME_NOTICE)
        assertEquals(60_000L, BotTimers.IDLE_SLEEP)
        assertEquals(100L, BotTimers.STREAM_COALESCE)
        assertEquals(80L, BotTimers.LIVE_TEXT_FLUSH)
        assertEquals(800L, BotTimers.WATCH_POLL)
        assertEquals(800L, BotTimers.ACTIVITY_MIN_VISIBLE)
        assertEquals(2_400L, BotTimers.ACTIVITY_ROTATION)
        assertEquals(60_000L, BotTimers.MINUTE)
    }

    @Test
    fun appearanceSelectionClearsAutoAndNamesTheChangedField() {
        val appearance = BotFishAppearance(
            color = BotFishColor.BLUE,
            hairstyle = BotFishHairstyle.LONG,
            autoColor = true,
            autoHairstyle = true,
        )
        val color = BotAppearanceSelection.apply(
            appearance, BotAppearanceIntent.SelectColor(BotFishColor.PURPLE))!!
        assertEquals(BotFishColor.PURPLE, color.appearance.color)
        assertFalse(color.appearance.autoColor)
        assertTrue(color.appearance.autoHairstyle)
        assertEquals(BotAppearanceField.COLOR, color.changedField)
        val style = BotAppearanceSelection.apply(
            appearance, BotAppearanceIntent.SelectHairstyle(BotFishHairstyle.BOB))!!
        assertEquals(BotAppearanceField.HAIRSTYLE, style.changedField)
        assertNull(BotAppearanceSelection.apply(
            appearance, BotAppearanceIntent.Rename("新名字")))
    }

    @Test
    fun runtimeStateFailedRequiresAMessageAndShowsTheBanner() {
        val failed = BotRuntimeState.fromJson(
            BotJson.objectOf(
                "kind" to JsonString("failed"),
                "message" to JsonString("Worker exited"),
            ))
        assertEquals(BotRuntimeState.Failed("Worker exited"), failed)
        assertTrue(failed.requiresDisconnectBanner)
        assertTrue(BotRuntimeState.Recovering.requiresDisconnectBanner)
        assertFalse(BotRuntimeState.Ready.requiresDisconnectBanner)
    }

    private fun presentation(
        fishState: BotFishLifecycle,
        oneShot: BotFishOneShot? = null,
    ): BotRuntimePresentation = BotRuntimePresentation(fishState = fishState, oneShot = oneShot)

    private fun celebrate(now: Long): BotFishOneShot = BotFishOneShot(
        state = BotFishLifecycle.CELEBRATE,
        priority = 70,
        startedAt = now,
        endsAt = now + 2_200,
    )

    private fun textRow(id: String, text: String): BotRow = row(
        id,
        BotJson.objectOf("type" to JsonString("text"), "text" to JsonString(text)),
    )

    private fun questionRow(): BotRow = row(
        "question",
        BotJson.objectOf(
            "type" to JsonString("widget"),
            "cardType" to JsonString("question"),
            "question" to JsonString("保存到哪里？"),
            "options" to JsonArray(listOf(
                BotJson.objectOf(
                    "id" to JsonString("library"),
                    "label" to JsonString("保存到文档库"),
                ),
            )),
        ),
    )

    private fun approvalRow(): BotRow = row(
        "approval",
        BotJson.objectOf(
            "type" to JsonString("approval"),
            "approvalID" to JsonString("approval-1"),
            "digest" to JsonString("sha256:x"),
            "status" to JsonString("pending"),
            "action" to JsonString("删除旧报告"),
        ),
    )

    private fun row(id: String, body: JsonObject): BotRow =
        BotUiStateFixtures.rowForBody(body, id)

    private fun infoFixture(): com.phonedsh.agentcore.JsonValue {
        val fixture = BotUiStateFixtures.golden("fixtures.json")
        val exported = (fixture["exported"] as JsonArray).values
            .map { it as JsonObject }
            .first { ((it["scenario"] as JsonString).value) == "info" }
        return exported["infoSnapshot"]!!
    }

    private companion object {
        const val NOW: Long = 1_760_000_000_000
    }
}
