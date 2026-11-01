// ScreenState acceptance for the session pages: same input -> same output.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/README.md` §3.1 rule ③ says ScreenState is a pure function of
// (UiState, local UI events), which is what makes a JVM replay possible. These
// tests replay a script of local events over a fixed UiState and assert the
// resulting state sequences — never a screenshot, never a font measurement.
package com.phonedsh.ui.page

import com.phonedsh.agentcore.HarnessGoal
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.projection.UiStateSurface
import com.phonedsh.ui.state.ChatRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

class SessionPagesStateTest {
    private val zone: ZoneId = ZoneId.of("Asia/Shanghai")
    private val now: Long = 1_700_000_000_000L

    // ------------------------------------------------------------------ sessions

    @Test
    fun `a waiting sessions page shows no rows and no empty reason`() {
        val state = SessionsScreenState.from(sessions(), nowMs = now, zone = zone, waiting = true)
        assertTrue(state.waiting)
        assertTrue(state.rows.isEmpty())
        assertEquals(SessionsEmpty.NONE, state.empty)
        assertNull(state.failure)
    }

    @Test
    fun `a session row shows its title, relative time and run status`() {
        val state = SessionsScreenState.from(
            sessions = listOf(
                SessionListing("s1", "项目讨论", updatedAtMs = now - 5 * MINUTE, status = SessionRunStatus.RUNNING),
                SessionListing("s2", "release", updatedAtMs = now - 3 * HOUR, status = SessionRunStatus.FAILED),
            ),
            nowMs = now,
            zone = zone,
        )
        assertEquals(listOf("项目讨论", "release"), state.rows.map { it.title })
        assertEquals(
            listOf(UiStrings.MINUTES_AGO.format(5), UiStrings.HOURS_AGO.format(3)),
            state.rows.map { it.timeLabel },
        )
        assertEquals(listOf(SessionRunStatus.RUNNING, SessionRunStatus.FAILED), state.rows.map { it.status })
        assertEquals(UiStrings.RUNNING, state.rows[0].status.label)
        assertEquals(UiStrings.FAILED_STATUS, state.rows[1].status.label)
        assertEquals(SessionsEmpty.NONE, state.empty)
    }

    @Test
    fun `a session without a reported time shows no time instead of just now`() {
        val state = SessionsScreenState.from(sessions(SessionListing("s1", "no clock")), nowMs = now, zone = zone)
        assertNull(state.rows.single().timeLabel)
    }

    @Test
    fun `relative time crosses just now, minutes, hours and the date fallback`() {
        assertEquals(UiStrings.JUST_NOW, relativeTime(now - 30_000, now, zone))
        assertEquals(UiStrings.MINUTES_AGO.format(1), relativeTime(now - MINUTE, now, zone))
        assertEquals(UiStrings.HOURS_AGO.format(2), relativeTime(now - 2 * HOUR, now, zone))
        // 1_700_000_000_000 is 2023-11-15 06:13:20 in Asia/Shanghai; two days
        // earlier is 2023-11-13 06:13:20 in the same zone.
        assertEquals(
            UiStrings.MONTH_DAY.format(11, 13),
            relativeTime(1_700_000_000_000 - 2 * DAY, 1_700_000_000_000, zone),
        )
        // A clock that runs backwards is "just now", not a negative quantity.
        assertEquals(UiStrings.JUST_NOW, relativeTime(now + 5 * MINUTE, now, zone))
    }

    @Test
    fun `a completely empty drawer is the big empty state`() {
        val state = SessionsScreenState.from(
            sessions = sessions(),
            workspaces = emptyList(),
            archivedSessions = emptyList(),
            nowMs = now,
            zone = zone,
        )
        assertTrue(state.completelyEmpty)
        assertEquals(SessionsEmpty.NO_SESSIONS, state.empty)
        assertEquals(SessionWorkspaceStatus.EMPTY, state.workspaceStatus)
        assertEquals(ArchivedStatus.COLLAPSED, state.archived.status)
    }

    @Test
    fun `a folder list the host did not report is unknown, not empty`() {
        val state = SessionsScreenState.from(
            sessions = sessions(),
            workspaces = null,
            archivedSessions = emptyList(),
            nowMs = now,
            zone = zone,
        )
        assertEquals(SessionWorkspaceStatus.UNKNOWN, state.workspaceStatus)
        assertFalse("an unreported list can never prove the drawer is empty", state.completelyEmpty)
        assertEquals(SessionsEmpty.NONE, state.empty)
    }

    @Test
    fun `workspace sections keep the host order and the membership order`() {
        val state = SessionsScreenState.from(
            sessions = listOf(
                SessionListing("s1", "项目讨论"),
                SessionListing("s2", "release notes"),
                SessionListing("s3", "ungrouped"),
            ),
            workspaces = listOf(
                SessionWorkspace("w1", "workspace", listOf("s2", "s1")),
                SessionWorkspace("w2", "工作文件夹", emptyList()),
            ),
            workspaceOrder = listOf("w2", "w1"),
            archivedSessions = emptyList(),
            nowMs = now,
            zone = zone,
        )
        assertEquals(listOf("w2", "w1"), state.workspaces.map { it.id })
        // Default names are numbered by their position among the folders.
        assertEquals(listOf("工作文件夹", "工作文件夹 2"), state.workspaces.map { it.title })
        // A folder's rows follow the host's membership list, not the session list.
        assertEquals(listOf("s2", "s1"), state.workspaces[1].sessions.map { it.id })
        assertEquals(2L, state.workspaces[1].sessionCount)
        assertEquals(listOf("s3"), state.rows.map { it.id })
        assertTrue(state.workspaces[0].empty)
    }

    @Test
    fun `a folder count follows the query filter the baseline shows`() {
        val listed = listOf(
            SessionListing("s1", "项目讨论"),
            SessionListing("s2", "release notes"),
        )
        val folders = listOf(SessionWorkspace("w1", "项目", listOf("s1", "s2")))
        val filtered = SessionsScreenState.from(
            sessions = listed,
            workspaces = folders,
            archivedSessions = emptyList(),
            local = SessionsLocalState(query = "release"),
            nowMs = now,
            zone = zone,
        )
        assertEquals(listOf("s2"), filtered.workspaces.single().sessions.map { it.id })
        assertEquals(1L, filtered.workspaces.single().sessionCount)

        val none = SessionsScreenState.from(
            sessions = listed,
            workspaces = folders,
            archivedSessions = emptyList(),
            local = SessionsLocalState(query = "zzz"),
            nowMs = now,
            zone = zone,
        )
        assertEquals(0L, none.workspaces.single().sessionCount)
        assertTrue("the expanded folder says it has no rows", none.workspaces.single().empty)
        assertEquals(SessionsEmpty.NO_MATCHES, none.empty)
    }

    @Test
    fun `pinned sessions come first inside their own group`() {
        val state = SessionsScreenState.from(
            sessions = listOf(
                SessionListing("s1", "one"),
                SessionListing("s2", "two"),
                SessionListing("u1", "three"),
                SessionListing("u2", "four"),
            ),
            workspaces = listOf(SessionWorkspace("w1", "项目", listOf("s1", "s2"))),
            archivedSessions = emptyList(),
            pinnedSessionIDs = listOf("s2", "u2"),
            nowMs = now,
            zone = zone,
        )
        assertEquals(listOf("s2", "s1"), state.workspaces.single().sessions.map { it.id })
        assertEquals(listOf("u2", "u1"), state.rows.map { it.id })
    }

    @Test
    fun `archived sessions leave the active groups and list under the fold`() {
        val listed = listOf(
            SessionListing("s1", "active"),
            SessionListing("s2", "new conversation"),
        )
        val collapsed = SessionsScreenState.from(
            sessions = listed,
            workspaces = emptyList(),
            archivedSessions = listOf(listed[1]),
            nowMs = now,
            zone = zone,
        )
        assertEquals(listOf("s1"), collapsed.rows.map { it.id })
        assertEquals(ArchivedStatus.COLLAPSED, collapsed.archived.status)
        assertEquals(1L, collapsed.archived.count)

        val expanded = SessionsScreenState.from(
            sessions = listed,
            workspaces = emptyList(),
            archivedSessions = listOf(listed[1]),
            local = SessionsLocalState(showArchived = true),
            nowMs = now,
            zone = zone,
        )
        assertEquals(ArchivedStatus.READY, expanded.archived.status)
        assertEquals(listOf("s2"), expanded.archived.rows.map { it.id })
        // An archived default title is numbered against the active ordering.
        assertEquals(UiStrings.NEW_SESSION, expanded.archived.rows.single().title)
    }

    @Test
    fun `an unreported archived list has an unknown count`() {
        val state = SessionsScreenState.from(
            sessions = sessions(SessionListing("s1", "项目讨论")),
            workspaces = emptyList(),
            archivedSessions = null,
            local = SessionsLocalState(showArchived = true),
            nowMs = now,
            zone = zone,
        )
        assertEquals(ArchivedStatus.UNKNOWN, state.archived.status)
        assertNull(state.archived.count)
    }

    @Test
    fun `the archived section is collapsed until the fold opens`() {
        val emptyFold = SessionsScreenState.from(
            sessions = sessions(),
            workspaces = emptyList(),
            archivedSessions = emptyList(),
            nowMs = now,
            zone = zone,
        )
        assertEquals(ArchivedStatus.COLLAPSED, emptyFold.archived.status)
        assertFalse(emptyFold.archivedExpanded)

        val open = SessionsScreenState.from(
            sessions = sessions(),
            workspaces = emptyList(),
            archivedSessions = emptyList(),
            local = SessionsLocalState(showArchived = true),
            nowMs = now,
            zone = zone,
        )
        assertEquals(ArchivedStatus.EMPTY, open.archived.status)
        assertTrue(open.archivedExpanded)
    }

    @Test
    fun `default session titles are numbered by occurrence not by position`() {
        val state = SessionsScreenState.from(
            sessions = sessions(
                SessionListing("s1", "keep me"),
                SessionListing("s2", "new conversation"),
                SessionListing("s3", "untitled"),
            ),
            workspaces = emptyList(),
            archivedSessions = emptyList(),
            nowMs = now,
            zone = zone,
        )
        assertEquals(
            listOf("keep me", UiStrings.NEW_SESSION, UiStrings.NEW_SESSION_INDEXED.format(2)),
            state.rows.map { it.title },
        )
    }

    @Test
    fun `default and path-like workspace names follow the baseline`() {
        assertEquals(UiStrings.SESSIONS_WORKSPACE_DEFAULT, workspaceTitle("workspace", 1))
        assertEquals(UiStrings.SESSIONS_WORKSPACE_INDEXED.format(2), workspaceTitle("工作文件夹", 2))
        assertEquals("项目A", workspaceTitle("/dsh/workspace/项目A", 1))
        assertEquals("b", workspaceTitle("a/b/", 1))
        assertEquals(UiStrings.SESSIONS_WORKSPACE_UNNAMED, workspaceTitle("/", 1))
        assertEquals(UiStrings.SESSIONS_WORKSPACE_UNNAMED, workspaceTitle("~", 1))
    }

    @Test
    fun `middle truncation keeps five head and six tail characters`() {
        assertEquals("abcde…ijklmn", middleTruncate("abcdefghijklmn", 12))
        assertEquals("short", middleTruncate("short", 12))
    }

    @Test
    fun `new session carries the baseline's blocked reason`() {
        val running = SessionsScreenState.from(
            sessions = sessions(),
            nowMs = now,
            zone = zone,
            newSessionBlock = NewSessionBlock.TURN_RUNNING,
        )
        assertEquals(NewSessionBlock.TURN_RUNNING, running.newSessionBlock)
        assertEquals(UiStrings.SESSIONS_NEW_BLOCKED_TURN, requireNotNull(running.newSessionBlock).reason)

        val stopped = SessionsScreenState.from(
            sessions = sessions(),
            nowMs = now,
            zone = zone,
            newSessionBlock = NewSessionBlock.ENGINE_NOT_STARTED,
        )
        assertEquals(UiStrings.SESSIONS_NEW_BLOCKED_ENGINE, requireNotNull(stopped.newSessionBlock).reason)
        assertNull(
            "a creatable page has no block at all",
            SessionsScreenState.from(sessions(), nowMs = now, zone = zone).newSessionBlock,
        )
    }

    @Test
    fun `a failed read keeps the previous rows and reports failure`() {
        val state = SessionsScreenState.from(
            sessions = sessions(SessionListing("s1", "项目讨论")),
            nowMs = now,
            zone = zone,
            failure = UiStrings.SESSION_LOAD_FAILED,
        )
        assertEquals(SessionListStatus.FAILED, state.status)
        assertEquals(UiStrings.SESSION_LOAD_FAILED, state.failure)
        assertEquals(1, state.rows.size)
        assertEquals("a failed read is not the empty state", SessionsEmpty.NONE, state.empty)
        assertFalse("a failed read can never claim the drawer is empty", state.completelyEmpty)
    }

    @Test
    fun `the rename editor and the delete target only resolve for listed sessions`() {
        val listed = sessions(SessionListing("s1", "项目讨论"))
        val open = SessionsScreenState.from(
            sessions = listed,
            local = SessionsLocalState(renameTargetID = "s1", renameDraft = "新名字", deleteTargetID = "s1"),
            nowMs = now,
            zone = zone,
        )
        assertEquals(RenameEditor("s1", "新名字"), open.rename)
        assertEquals("s1", open.deleteTargetID)
        assertTrue(open.rows.single().renaming)
        assertTrue(open.rows.single().deleting)

        val stale = SessionsScreenState.from(
            sessions = listed,
            local = SessionsLocalState(renameTargetID = "gone", renameDraft = "x", deleteTargetID = "gone"),
            nowMs = now,
            zone = zone,
        )
        assertNull("a stale local target must not open an editor", stale.rename)
        assertNull(stale.deleteTargetID)
        assertFalse(stale.rows.single().renaming)
    }

    @Test
    fun `the workspace editors only resolve for listed folders`() {
        val folders = listOf(SessionWorkspace("w1", "项目", listOf("s1")))
        val local = SessionsLocalState(
            workspaceMenuID = "w1",
            renameWorkspaceTargetID = "w1",
            renameWorkspaceDraft = "新名字",
            deleteWorkspaceTargetID = "w1",
        )
        val state = SessionsScreenState.from(
            sessions = sessions(SessionListing("s1", "项目讨论")),
            workspaces = folders,
            archivedSessions = emptyList(),
            local = local,
            nowMs = now,
            zone = zone,
        )
        assertTrue(state.workspaces.single().menuOpen)
        assertEquals(WorkspaceRenameEditor("w1", "新名字"), state.renameWorkspace)
        assertEquals("w1", state.deleteWorkspaceTargetID)

        val stale = SessionsScreenState.from(
            sessions = sessions(),
            workspaces = emptyList(),
            archivedSessions = emptyList(),
            local = local,
            nowMs = now,
            zone = zone,
        )
        assertNull(stale.renameWorkspace)
        assertNull(stale.deleteWorkspaceTargetID)
    }

    @Test
    fun `the sessions state is a pure function of its inputs`() {
        val listed = sessions(SessionListing("s1", "项目讨论", updatedAtMs = now - MINUTE))
        val folders = listOf(SessionWorkspace("w1", "项目", listOf("s1")))
        val script = listOf(
            SessionsLocalState(),
            SessionsLocalState(query = "项目"),
            SessionsLocalState(query = "项目", selectedID = "s1"),
            SessionsLocalState(renameTargetID = "s1", renameDraft = "改名"),
            SessionsLocalState(showArchived = true, collapsedWorkspaceIDs = setOf("w1")),
        )
        fun replay(): List<SessionsScreenState> = script.map {
            SessionsScreenState.from(
                sessions = listed,
                workspaces = folders,
                archivedSessions = emptyList(),
                local = it,
                nowMs = now,
                zone = zone,
            )
        }
        val first = replay()
        assertEquals("same input, same state sequence", first, replay())
        assertTrue(first.last().workspaces.single().expanded.not())
        assertTrue(first[2].workspaces.single().sessions.single().selected)
    }

    @Test
    fun `queue lanes show the baseline labels and keep the host order`() {
        assertEquals(QueueLane.NEXT_TURN, queueLaneOf("next-turn"))
        assertEquals(QueueLane.CURRENT_STEP, queueLaneOf("next-step"))
        assertEquals(QueueLane.CURRENT_STEP, queueLaneOf("anything-else"))

        val state = SessionQueueScreenState.from(
            sessionID = "s1",
            items = listOf(
                SessionQueueItem("q1", QueueLane.NEXT_TURN, "first"),
                SessionQueueItem("q2", QueueLane.CURRENT_STEP, ""),
            ),
            queueSessionID = "s1",
        )
        assertEquals(QueueStatus.READY, state.status)
        assertEquals(
            listOf(UiStrings.SESSIONS_QUEUE_NEXT_TURN, UiStrings.SESSIONS_QUEUE_CURRENT_STEP),
            state.rows.map { it.laneLabel },
        )
        assertEquals(listOf("first", ""), state.rows.map { it.text })
    }

    @Test
    fun `the queue stays loading until the host read this session's queue`() {
        val unread = SessionQueueScreenState.from(sessionID = "s1", items = null, queueSessionID = "s1")
        assertEquals(QueueStatus.LOADING, unread.status)
        assertTrue(unread.rows.isEmpty())

        val otherSession = SessionQueueScreenState.from(
            sessionID = "s1",
            items = listOf(SessionQueueItem("q1", QueueLane.NEXT_TURN, "text")),
            queueSessionID = "s2",
        )
        assertEquals("another session's read does not answer this one", QueueStatus.LOADING, otherSession.status)
    }

    @Test
    fun `an empty queue and a failed read are different states`() {
        val empty = SessionQueueScreenState.from(sessionID = "s1", items = emptyList(), queueSessionID = "s1")
        assertEquals(QueueStatus.EMPTY, empty.status)
        assertNull(empty.failure)

        val failed = SessionQueueScreenState.from(
            sessionID = "s1",
            items = null,
            queueSessionID = "s1",
            failure = UiStrings.SESSION_LOAD_FAILED,
        )
        assertEquals(QueueStatus.LOADING, failed.status)
        assertEquals(UiStrings.SESSION_LOAD_FAILED, failed.failure)
    }

    @Test
    fun `the queue editor only opens for a listed message`() {
        val items = listOf(SessionQueueItem("q1", QueueLane.NEXT_TURN, "text"))
        val open = SessionQueueScreenState.from(
            sessionID = "s1",
            items = items,
            queueSessionID = "s1",
            local = SessionQueueLocalState(editingID = "q1", editDraft = "replacement"),
        )
        assertTrue(open.rows.single().editing)
        assertEquals("replacement", open.editDraft)

        val stale = SessionQueueScreenState.from(
            sessionID = "s1",
            items = items,
            queueSessionID = "s1",
            local = SessionQueueLocalState(editingID = "gone", editDraft = "x"),
        )
        assertFalse("a stale editor id opens nothing", stale.rows.single().editing)
    }

    // ------------------------------------------------------------------- history

    @Test
    fun `a waiting history page has no turns and no empty reason`() {
        val state = SessionHistoryScreenState.from(emptyList(), waiting = true)
        assertEquals(HistoryStatus.WAITING, state.status)
        assertTrue(state.turns.isEmpty())
        assertNull(state.detail)
        assertEquals(HistoryEmpty.NONE, state.empty)
    }

    @Test
    fun `an empty history reports no turns`() {
        val state = SessionHistoryScreenState.from(emptyList())
        assertEquals(HistoryStatus.READY, state.status)
        assertEquals(HistoryEmpty.NO_TURNS, state.empty)
    }

    @Test
    fun `the turn list keeps projection order and counts real nodes`() {
        val state = SessionHistoryScreenState.from(twoTurns())
        assertEquals(
            listOf(UiStrings.TURN_LABEL.format(1), UiStrings.TURN_LABEL.format(2)),
            state.turns.map { it.label },
        )
        assertEquals(
            listOf(UiStrings.TURN_COMPLETED, UiStrings.FAILED_STATUS),
            state.turns.map { it.outcomeLabel },
        )
        assertEquals(UiStrings.TURN_COUNTS.format(1, 1), state.turns[0].summary)
        assertEquals(UiStrings.TURN_COUNTS.format(1, 0), state.turns[1].summary)
        assertNull("no selection means the list, not a guessed detail", state.detail)
    }

    @Test
    fun `selecting a turn shows only that turn's rows`() {
        val state = SessionHistoryScreenState.from(
            twoTurns(),
            local = SessionHistoryLocalState(selectedTurnID = "t2"),
        )
        val detail = requireNotNull(state.detail)
        assertEquals("t2", detail.turnID)
        assertEquals(UiStrings.TURN_LABEL.format(2), detail.label)
        assertEquals(listOf(ChatRow.User::class, ChatRow.SystemEvent::class), detail.rows.map { it::class })
        assertEquals("the failed turn carries its banner", 1, detail.banners.size)
        assertEquals(0, detail.pendingCount)
    }

    @Test
    fun `a selected turn counts its unanswered ask without offering an answer`() {
        val state = SessionHistoryScreenState.from(
            twoTurns(questionInFirstTurn = true),
            local = SessionHistoryLocalState(selectedTurnID = "t1"),
        )
        assertEquals(1, requireNotNull(state.detail).pendingCount)
    }

    @Test
    fun `a stale selection falls back to the list instead of inventing a turn`() {
        val state = SessionHistoryScreenState.from(
            twoTurns(),
            local = SessionHistoryLocalState(selectedTurnID = "turn-9999"),
        )
        assertNull(state.detail)
        assertNull(state.selectedTurnID)
        assertEquals(HistoryEmpty.NONE, state.empty)
    }

    @Test
    fun `a failed history read keeps the turns it already had`() {
        val state = SessionHistoryScreenState.from(
            twoTurns(),
            failure = UiStrings.HISTORY_LOAD_FAILED,
        )
        assertEquals(HistoryStatus.FAILED, state.status)
        assertEquals(2, state.turns.size)
        assertEquals(HistoryEmpty.NONE, state.empty)
    }

    @Test
    fun `the history state replays the same sequence for the same script`() {
        val nodes = twoTurns()
        val script = listOf(
            SessionHistoryLocalState(),
            SessionHistoryLocalState(selectedTurnID = "t1"),
            SessionHistoryLocalState(selectedTurnID = "t1", expandedRowIds = setOf("row-1")),
            SessionHistoryLocalState(selectedTurnID = null),
        )
        val first = script.map { SessionHistoryScreenState.from(nodes, local = it) }
        val second = script.map { SessionHistoryScreenState.from(nodes, local = it) }
        assertEquals(first, second)
        assertEquals(setOf("row-1"), first[2].expandedRowIds)
    }

    // ---------------------------------------------------------------------- goal

    @Test
    fun `a waiting goal page has no goal`() {
        val state = GoalDetailScreenState.from(null, waiting = true)
        assertEquals(GoalStatus.WAITING, state.status)
        assertFalse(state.hasGoal)
        assertTrue(state.actions.isEmpty())
    }

    @Test
    fun `a session without a goal renders the empty state`() {
        val state = GoalDetailScreenState.from(null)
        assertEquals(GoalStatus.READY, state.status)
        assertFalse(state.hasGoal)
        assertNull(state.failure)
    }

    @Test
    fun `an active goal offers pause and clear`() {
        val state = GoalDetailScreenState.from(goal(HarnessGoal.Phase.ACTIVE, rounds = 2, max = 5))
        assertTrue(state.hasGoal)
        assertEquals("ship the port", state.objective)
        assertEquals(UiStrings.GOAL_ACTIVE, state.phaseLabel)
        assertEquals("2 / 5 轮", state.roundsLabel)
        assertEquals(listOf(GoalAction.PAUSE, GoalAction.CLEAR), state.actions.map { it.action })
        assertEquals(listOf(UiStrings.GOAL_PAUSE, UiStrings.GOAL_CLEAR), state.actions.map { it.label })
        assertNull(state.statusLine)
    }

    @Test
    fun `paused and blocked goals offer resume`() {
        val paused = GoalDetailScreenState.from(goal(HarnessGoal.Phase.PAUSED))
        assertEquals(listOf(GoalAction.RESUME, GoalAction.CLEAR), paused.actions.map { it.action })
        assertEquals(UiStrings.GOAL_PAUSED, paused.phaseLabel)

        val blocked = GoalDetailScreenState.from(
            goal(HarnessGoal.Phase.BLOCKED).copy(blockedReason = "protocol not frozen"),
        )
        assertEquals(listOf(GoalAction.RESUME, GoalAction.CLEAR), blocked.actions.map { it.action })
        assertEquals(UiStrings.GOAL_BLOCKED, blocked.phaseLabel)
        assertEquals("protocol not frozen", blocked.blockedReason)
    }

    @Test
    fun `a complete goal only offers clear`() {
        val state = GoalDetailScreenState.from(goal(HarnessGoal.Phase.COMPLETE))
        assertEquals(listOf(GoalAction.CLEAR), state.actions.map { it.action })
        assertEquals(UiStrings.GOAL_COMPLETE, state.phaseLabel)
    }

    @Test
    fun `a failed re-read is fail-quiet and keeps the previous goal`() {
        val state = GoalDetailScreenState.from(
            goal(HarnessGoal.Phase.ACTIVE),
            failure = UiStrings.GOAL_LOAD_FAILED,
        )
        assertEquals(GoalStatus.READY, state.status)
        assertNull("fail-quiet: no banner replaces the goal", state.failure)
        assertEquals(UiStrings.GOAL_READ_FAILED, state.statusLine)
        assertTrue(state.hasGoal)
        assertEquals(2, state.actions.size)
    }

    @Test
    fun `a failed first read has no goal to keep and reports failure`() {
        val state = GoalDetailScreenState.from(null, failure = UiStrings.GOAL_LOAD_FAILED)
        assertEquals(GoalStatus.FAILED, state.status)
        assertEquals(UiStrings.GOAL_LOAD_FAILED, state.failure)
        assertFalse(state.hasGoal)
    }

    @Test
    fun `the goal state replays the same sequence for the same projections`() {
        val script = listOf(
            null to true,
            goal(HarnessGoal.Phase.ACTIVE) to false,
            goal(HarnessGoal.Phase.ACTIVE) to false,
            goal(HarnessGoal.Phase.BLOCKED).copy(blockedReason = "why") to false,
        )
        val first = script.map { (goal, waiting) -> GoalDetailScreenState.from(goal, waiting = waiting) }
        val second = script.map { (goal, waiting) -> GoalDetailScreenState.from(goal, waiting = waiting) }
        assertEquals(first, second)
        assertEquals(script.size, first.size)
    }

    // -------------------------------------------------------------------- helpers

    private fun sessions(vararg listings: SessionListing): List<SessionListing> = listings.toList()

    private fun goal(
        phase: HarnessGoal.Phase,
        rounds: Long = 0,
        max: Long = 3,
    ): HarnessGoal = HarnessGoal(
        objective = "ship the port",
        phase = phase,
        roundsStarted = rounds,
        maxGoalRounds = max,
        // `harness-goal.schema.json`: the reason is required exactly when blocked.
        blockedReason = if (phase == HarnessGoal.Phase.BLOCKED) "blocked by policy" else null,
    )

    /**
     * Two turns of one session: t1 completes with a message and a tool call; t2
     * fails with a message.
     */
    private fun twoTurns(questionInFirstTurn: Boolean = false): List<UiStateNode> = listOf(
        node(UiStateKind.ROOT, "root", "root", "-", seq = 0),
        node(UiStateKind.SESSION, "session/s1", "root", "-", seq = 0),
        node(UiStateKind.TURN, "session/s1/turn/t1", "session/s1", "t1", seq = 0),
        node(
            UiStateKind.BUBBLE,
            "session/s1/turn/t1/event/1/bubble",
            "session/s1/turn/t1",
            "t1",
            text = "first question",
            props = props("role" to "user"),
        ),
        node(
            UiStateKind.TOOL_ROW,
            "session/s1/turn/t1/event/2/tool-call",
            "session/s1/turn/t1",
            "t1",
            seq = 2,
            surface = UiStateSurface.TOOL_ROW,
            text = "read",
            props = props("callId" to "c1", "name" to "read", "phase" to "call"),
        ),
        node(
            UiStateKind.TOOL_ROW,
            "session/s1/turn/t1/event/3/tool-result",
            "session/s1/turn/t1",
            "t1",
            seq = 3,
            surface = UiStateSurface.TOOL_ROW,
            text = "file body",
            props = props("callId" to "c1", "phase" to "result", "state" to "ok"),
        ),
        if (questionInFirstTurn) {
            node(
                UiStateKind.APPROVAL_CARD,
                "session/s1/turn/t1/event/4/question-request",
                "session/s1/turn/t1",
                "t1",
                seq = 4,
                surface = UiStateSurface.APPROVAL_CARD,
                text = "pick one",
                props = props("kind" to "question", "requestId" to "q-1"),
            )
        } else {
            node(
                UiStateKind.STATUS,
                "session/s1/turn/t1/event/4/turn-end",
                "session/s1/turn/t1",
                "t1",
                seq = 4,
                text = "completed",
                props = props("reason" to "completed"),
            )
        },
        node(UiStateKind.TURN, "session/s1/turn/t2", "session/s1", "t2", seq = 0),
        node(
            UiStateKind.BUBBLE,
            "session/s1/turn/t2/event/1/bubble",
            "session/s1/turn/t2",
            "t2",
            text = "second question",
            props = props("role" to "user"),
        ),
        node(
            UiStateKind.STATUS,
            "session/s1/turn/t2/event/2/turn-end",
            "session/s1/turn/t2",
            "t2",
            seq = 2,
            text = "error",
            props = props("reason" to "error"),
        ),
        node(
            UiStateKind.FAIL_LOUD_BANNER,
            "session/s1/turn/t2/event/2/fail-loud-banner",
            "session/s1/turn/t2",
            "t2",
            seq = 2,
            surface = UiStateSurface.FAIL_LOUD_BANNER,
            text = "boom",
            props = props("reason" to "error", "retryable" to true, "dismissible" to true),
        ),
    )

    private fun node(
        kind: UiStateKind,
        nodeID: String,
        parentID: String,
        turnID: String,
        seq: Int = 1,
        surface: UiStateSurface = UiStateSurface.NONE,
        text: String? = null,
        props: JsonObject = UiStateNode.EMPTY_PROPS,
    ): UiStateNode = UiStateNode(
        kind = kind,
        nodeID = nodeID,
        parentID = parentID,
        sessionID = "s1",
        turnID = turnID,
        seq = seq,
        surface = surface,
        text = text,
        props = props,
    )

    private fun props(vararg pairs: Pair<String, Any>): JsonObject = JsonObject(
        pairs.associate { (key, value) ->
            key to when (value) {
                is String -> JsonString(value)
                is Boolean -> com.phonedsh.agentcore.JsonBool(value)
                else -> error("unsupported prop type for $key")
            }
        }.toSortedMap<String, JsonValue>(),
    )

    private val MINUTE: Long = 60_000
    private val HOUR: Long = 3_600_000
    private val DAY: Long = 86_400_000
}
