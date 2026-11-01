// Session pages (JVM + Robolectric): the four pages bind state and never fake it.
// SPDX-License-Identifier: MIT
//
// Each page is asserted on semantics (the visible copy, the stable tags and the
// callbacks), never on a screenshot or a font measurement: Robolectric's font
// metrics are not the device's, so a geometry assertion would be a fake oracle.
package com.phonedsh.ui.page

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.agentcore.HarnessGoal
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.state.GoalBarState
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.time.ZoneId

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class SessionPagesTest {
    @get:Rule
    val compose = createComposeRule()

    private val zone: ZoneId = ZoneId.of("Asia/Shanghai")
    private val now: Long = 1_700_000_000_000L

    // ------------------------------------------------------------------ sessions

    @Test
    fun `section one renders the new-session row and the ungrouped sessions`() {
        val state = drawer(
            sessions = listOf(
                SessionListing("s1", "项目讨论", updatedAtMs = now - 60_000, status = SessionRunStatus.RUNNING),
            ),
        )
        var selected: String? = null
        var created = 0
        compose.setContent {
            PdshTheme {
                Drawer(
                    state = state,
                    onSelect = { selected = it.id },
                    onNewSession = { created += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_SESSION_ROW).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSION_NEW).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_SESSION_ROW).performClick()
        assertEquals(1, created)
        compose.onNodeWithText("项目讨论").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MINUTES_AGO.format(1)).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNNING).assertIsDisplayed()
        compose.onAllNodesWithTag(UiPageTags.SESSION_ROW)[0].performClick()
        assertEquals("s1", selected)
    }

    @Test
    fun `a blocked new-session row is disabled and explains why`() {
        val state = drawer(newSessionBlock = NewSessionBlock.TURN_RUNNING)
        var created = 0
        compose.setContent {
            PdshTheme { Drawer(state = state, onNewSession = { created += 1 }) }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_SESSION_ROW).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_SESSION_BLOCKED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_NEW_BLOCKED_TURN).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_SESSION_ROW).performClick()
        assertEquals("a disabled row must not create", 0, created)
    }

    @Test
    fun `a failed read shows a retryable failure line inside section one`() {
        val state = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            failure = UiStrings.SESSION_LOAD_FAILED,
        )
        var retried = 0
        compose.setContent {
            PdshTheme { Drawer(state = state, onRetry = { retried += 1 }) }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSION_LOAD_FAILED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
        compose.onNodeWithText("项目讨论").assertIsDisplayed()
    }

    @Test
    fun `section two shows the big empty block only when the drawer is completely empty`() {
        val empty = drawer()
        var added = 0
        compose.setContent {
            PdshTheme { Drawer(state = empty, onAddWorkspace = { added += 1 }) }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_SECTION_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKSPACE_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_EMPTY_WORKSPACE_HINT).assertIsDisplayed()
        // Section 4 and Section 5 are hidden while the empty block owns the entry point.
        compose.onNodeWithTag(UiPageTags.SESSIONS_ADD_WORKSPACE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.SESSIONS_ARCHIVED_SECTION).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_WORKSPACE).performClick()
        assertEquals(1, added)
    }

    @Test
    fun `the big empty block disappears as soon as one ungrouped session exists`() {
        val state = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        compose.setContent { PdshTheme { Drawer(state = state) } }
        compose.onNodeWithTag(UiPageTags.SESSIONS_SECTION_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.SESSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SESSIONS_ADD_WORKSPACE))
        compose.onNodeWithTag(UiPageTags.SESSIONS_ADD_WORKSPACE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SESSIONS_ARCHIVED_SECTION))
        compose.onNodeWithTag(UiPageTags.SESSIONS_ARCHIVED_SECTION).assertIsDisplayed()
    }

    @Test
    fun `pull to refresh reports the gesture`() {
        val state = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        var refreshed = 0
        compose.setContent {
            PdshTheme { Drawer(state = state, onRefresh = { refreshed += 1 }) }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_REFRESH).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_LIST).performTouchInput { swipeDown() }
        compose.waitForIdle()
        assertEquals(1, refreshed)
    }

    @Test
    fun `section three renders a folder row, its filtered count and its sessions`() {
        val state = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            workspaces = listOf(SessionWorkspace("w1", "项目", listOf("s1"))),
        )
        var toggled: String? = null
        compose.setContent {
            PdshTheme { Drawer(state = state, onToggleWorkspace = { toggled = it.id }) }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_ROW).assertIsDisplayed()
        compose.onNodeWithText("项目").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_WORKSPACE_COUNT.format(1)).assertIsDisplayed()
        compose.onNodeWithText("项目讨论").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_ROW).performClick()
        assertEquals("w1", toggled)
    }

    @Test
    fun `a collapsed folder hides its rows and shows no empty copy`() {
        val state = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            workspaces = listOf(SessionWorkspace("w1", "项目", listOf("s1"))),
            local = SessionsLocalState(collapsedWorkspaceIDs = setOf("w1")),
        )
        compose.setContent { PdshTheme { Drawer(state = state) } }
        compose.onNodeWithText("项目").assertIsDisplayed()
        compose.onNodeWithText("项目讨论").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_SESSIONS_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `an expanded folder with no row shows the baseline folder empty copy`() {
        val state = drawer(workspaces = listOf(SessionWorkspace("w1", "项目")))
        compose.setContent { PdshTheme { Drawer(state = state) } }
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_SESSIONS_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_WORKSPACE_SESSIONS_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_WORKSPACE_SESSIONS_EMPTY_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_WORKSPACE_COUNT.format(0)).assertDoesNotExist()
    }

    @Test
    fun `the folder menu lists the baseline actions in order and calls each`() {
        val state = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            workspaces = listOf(SessionWorkspace("w1", "项目", listOf("s1"))),
            local = SessionsLocalState(workspaceMenuID = "w1"),
        )
        var newSession = 0
        var renamed = 0
        var deleted = 0
        compose.setContent {
            PdshTheme {
                Drawer(
                    state = state,
                    onNewSessionInWorkspace = { newSession += 1 },
                    onRenameWorkspaceStart = { renamed += 1 },
                    onDeleteWorkspaceRequest = { deleted += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_MENU_ACTIONS).assertIsDisplayed()
        val newTop = compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_NEW_SESSION)
            .getUnclippedBoundsInRoot().top
        val renameTop = compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_RENAME)
            .getUnclippedBoundsInRoot().top
        val deleteTop = compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_DELETE)
            .getUnclippedBoundsInRoot().top
        assertTrue("new session must come first", newTop < renameTop)
        assertTrue("rename must come before delete", renameTop < deleteTop)
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_NEW_SESSION).performClick()
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_RENAME).performClick()
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_DELETE).performClick()
        assertEquals(1, newSession)
        assertEquals(1, renamed)
        assertEquals(1, deleted)
    }

    @Test
    fun `the folder delete dialog confirms and calls back`() {
        val state = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            workspaces = listOf(SessionWorkspace("w1", "项目", listOf("s1"))),
            local = SessionsLocalState(deleteWorkspaceTargetID = "w1"),
        )
        var confirmed = 0
        var cancelled = 0
        compose.setContent {
            PdshTheme {
                Drawer(
                    state = state,
                    onDeleteWorkspaceConfirm = { confirmed += 1 },
                    onDeleteWorkspaceCancel = { cancelled += 1 },
                )
            }
        }
        compose.onNodeWithText(UiStrings.SESSIONS_WORKSPACE_DELETE_DETAIL).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_DELETE_YES).performClick()
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_DELETE_NO).performClick()
        assertEquals(1, confirmed)
        assertEquals(1, cancelled)
    }

    @Test
    fun `section four opens the workspace editor and creates`() {
        val closed = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        var opened = 0
        compose.setContent {
            PdshTheme { Drawer(state = closed, onAddWorkspace = { opened += 1 }) }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SESSIONS_ADD_WORKSPACE))
        compose.onNodeWithTag(UiPageTags.SESSIONS_ADD_WORKSPACE).performClick()
        assertEquals(1, opened)
    }

    @Test
    fun `the new-workspace dialog shows the baseline copy and creates or cancels`() {
        val state = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            local = SessionsLocalState(creatingWorkspace = true, newWorkspaceDraft = "新文件夹"),
        )
        var created = 0
        var cancelled = 0
        var draft: String? = null
        compose.setContent {
            PdshTheme {
                Drawer(
                    state = state,
                    onWorkspaceDraftChange = { draft = it },
                    onCreateWorkspace = { created += 1 },
                    onCancelCreateWorkspace = { cancelled += 1 },
                )
            }
        }
        compose.onNodeWithText(UiStrings.SESSIONS_WORKSPACE_CREATE_DETAIL).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_WORKSPACE_FIELD).assertIsDisplayed()
        compose.onNodeWithText("新文件夹").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_WORKSPACE_FIELD).performTextInput("A")
        assertEquals("A新文件夹", draft)
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_WORKSPACE_CREATE).performClick()
        compose.onNodeWithTag(UiPageTags.SESSIONS_NEW_WORKSPACE_CANCEL).performClick()
        assertEquals(1, created)
        assertEquals(1, cancelled)
    }

    @Test
    fun `section five toggles the archived fold and restores a row`() {
        val state = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            archived = listOf(SessionListing("a1", "旧会话", updatedAtMs = now - 2 * 60_000)),
            local = SessionsLocalState(showArchived = true),
        )
        var toggled = 0
        var restored: String? = null
        compose.setContent {
            PdshTheme {
                Drawer(
                    state = state,
                    onToggleArchived = { toggled += 1 },
                    onRestoreArchived = { restored = it.id },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SESSIONS_ARCHIVED_SECTION))
        compose.onNodeWithTag(UiPageTags.SESSIONS_ARCHIVED_SECTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SESSIONS_ARCHIVED_ROW))
        compose.onNodeWithTag(UiPageTags.SESSIONS_ARCHIVED_ROW).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_RESTORE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_ARCHIVED_RESTORE).performClick()
        assertEquals("a1", restored)
        compose.onNodeWithTag(UiPageTags.SESSIONS_ARCHIVED_SECTION).performClick()
        assertEquals(1, toggled)
    }

    @Test
    fun `the archived empty copy needs the fold open`() {
        val closed = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        compose.setContent { PdshTheme { Drawer(state = closed) } }
        compose.onNodeWithTag(UiPageTags.SESSIONS_ARCHIVED_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `an open archived fold with no archived session shows the baseline copy`() {
        val open = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            local = SessionsLocalState(showArchived = true),
        )
        compose.setContent { PdshTheme { Drawer(state = open) } }
        compose.onNodeWithTag(UiPageTags.SESSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SESSIONS_ARCHIVED_EMPTY))
        compose.onNodeWithTag(UiPageTags.SESSIONS_ARCHIVED_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_ARCHIVED_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_ARCHIVED_EMPTY_HINT).assertIsDisplayed()
    }

    @Test
    fun `unreported lists say unknown instead of claiming empty`() {
        val state = drawer(
            workspaces = null,
            archived = null,
            local = SessionsLocalState(showArchived = true),
        )
        compose.setContent { PdshTheme { Drawer(state = state) } }
        compose.onNodeWithTag(UiPageTags.SESSIONS_SECTION_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_WORKSPACE_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SESSIONS_ARCHIVED_UNKNOWN))
        compose.onNodeWithTag(UiPageTags.SESSIONS_ARCHIVED_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_ARCHIVED_UNKNOWN_HINT).assertIsDisplayed()
    }

    @Test
    fun `long pressing a session opens its two baseline actions`() {
        val state = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        var menu: String? = null
        compose.setContent {
            PdshTheme { Drawer(state = state, onSessionMenuToggle = { menu = it.id }) }
        }
        compose.onAllNodesWithTag(UiPageTags.SESSION_ROW)[0].performTouchInput { longClick() }
        assertEquals("s1", menu)
        compose.onNodeWithTag(UiPageTags.SESSIONS_SESSION_MENU).assertDoesNotExist()
    }

    @Test
    fun `the session menu renames and archives`() {
        val state = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            local = SessionsLocalState(sessionMenuID = "s1"),
        )
        var renamed: String? = null
        var archived: String? = null
        compose.setContent {
            PdshTheme {
                Drawer(
                    state = state,
                    onRenameStart = { renamed = it.id },
                    onArchiveSession = { archived = it.id },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_SESSION_MENU).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_SESSION_RENAME).performClick()
        compose.onNodeWithTag(UiPageTags.SESSIONS_SESSION_ARCHIVE).performClick()
        assertEquals("s1", renamed)
        assertEquals("s1", archived)
    }

    @Test
    fun `the current session wears the baseline check mark`() {
        val current = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            currentSessionID = "s1",
        )
        compose.setContent { PdshTheme { Drawer(state = current) } }
        compose.onNodeWithTag(UiPageTags.SESSIONS_SESSION_CURRENT, useUnmergedTree = true)
            .assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.SESSIONS_CURRENT).assertIsDisplayed()
    }

    @Test
    fun `a session that is not current has no check mark`() {
        val none = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        compose.setContent { PdshTheme { Drawer(state = none) } }
        compose.onNodeWithTag(UiPageTags.SESSIONS_SESSION_CURRENT, useUnmergedTree = true)
            .assertDoesNotExist()
    }

    @Test
    fun `the session rename dialog saves and cancels`() {
        val state = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            local = SessionsLocalState(renameTargetID = "s1", renameDraft = "新名字"),
        )
        var saved: String? = null
        var cancelled = 0
        compose.setContent {
            PdshTheme {
                Drawer(
                    state = state,
                    onRenameCommit = { saved = it.id },
                    onRenameCancel = { cancelled += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.SESSION_RENAME_FIELD).assertIsDisplayed()
        compose.onNodeWithText("新名字").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSION_RENAME_SAVE).performClick()
        compose.onNodeWithTag(UiPageTags.SESSION_RENAME_CANCEL).performClick()
        assertEquals("s1", saved)
        assertEquals(1, cancelled)
        // The baseline has no session delete: the old confirmation never renders.
        compose.onNodeWithTag(UiPageTags.SESSION_DELETE_YES).assertDoesNotExist()
    }

    @Test
    fun `a session without a reported time shows no time label instead of just now`() {
        val state = drawer(
            sessions = listOf(
                SessionListing("s1", "项目讨论", updatedAtMs = null, status = SessionRunStatus.RUNNING),
            ),
        )
        compose.setContent { PdshTheme { Drawer(state = state) } }
        compose.onNodeWithText("项目讨论").assertIsDisplayed()
        // The time was never measured: it is absent, not rendered as "just now".
        compose.onNodeWithText(UiStrings.JUST_NOW).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.MINUTES_AGO.format(1)).assertDoesNotExist()
        // A fact that *was* measured still renders.
        compose.onNodeWithText(UiStrings.RUNNING).assertIsDisplayed()
    }

    // --------------------------------------------------------------- sessions queue

    @Test
    fun `the queue page shows the loading line until the host reads it`() {
        val state = SessionQueueScreenState.from(sessionID = "s1")
        compose.setContent { PdshTheme { SessionQueuePage(state = state) } }
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_LOADING).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_QUEUE_LOADING).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `an empty queue shows the baseline empty copy`() {
        val state = SessionQueueScreenState.from(
            sessionID = "s1",
            items = emptyList(),
            queueSessionID = "s1",
        )
        compose.setContent { PdshTheme { SessionQueuePage(state = state) } }
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_QUEUE_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_QUEUE_EMPTY_HINT).assertIsDisplayed()
    }

    @Test
    fun `the queue lists both lanes with their three actions`() {
        val state = SessionQueueScreenState.from(
            sessionID = "s1",
            items = listOf(
                SessionQueueItem("q1", QueueLane.NEXT_TURN, "first"),
                SessionQueueItem("q2", QueueLane.CURRENT_STEP, ""),
            ),
            queueSessionID = "s1",
        )
        var edited: String? = null
        var steered: String? = null
        var removed: String? = null
        compose.setContent {
            PdshTheme {
                SessionQueuePage(
                    state = state,
                    onEdit = { edited = it.id },
                    onSteer = { steered = it.id },
                    onRemove = { removed = it.id },
                )
            }
        }
        compose.onAllNodesWithTag(UiPageTags.SESSION_QUEUE_SECTION).assertCountEquals(2)
        compose.onNodeWithText(UiStrings.SESSIONS_QUEUE_NEXT_TURN).assertIsDisplayed()
        compose.onNodeWithText("first").assertIsDisplayed()
        compose.onAllNodesWithTag(UiPageTags.SESSION_QUEUE_EDIT)[0].performClick()
        compose.onAllNodesWithTag(UiPageTags.SESSION_QUEUE_STEER)[0].performClick()
        compose.onAllNodesWithTag(UiPageTags.SESSION_QUEUE_REMOVE)[0].performClick()
        assertEquals("q1", edited)
        assertEquals("q1", steered)
        assertEquals("q1", removed)
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SESSION_QUEUE_ROW))
        compose.onNodeWithText(UiStrings.SESSIONS_QUEUE_CURRENT_STEP).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_QUEUE_NO_TEXT).assertIsDisplayed()
    }

    @Test
    fun `editing a queued message shows the editor and saves`() {
        val state = SessionQueueScreenState.from(
            sessionID = "s1",
            items = listOf(SessionQueueItem("q1", QueueLane.NEXT_TURN, "text")),
            queueSessionID = "s1",
            local = SessionQueueLocalState(editingID = "q1", editDraft = "replacement"),
        )
        var saved: String? = null
        var cancelled = 0
        var draft: String? = null
        compose.setContent {
            PdshTheme {
                SessionQueuePage(
                    state = state,
                    onEditDraftChange = { draft = it },
                    onEditSave = { saved = it.id },
                    onEditCancel = { cancelled += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_EDIT_FIELD).assertIsDisplayed()
        compose.onNodeWithText("replacement").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_EDIT_FIELD).performTextInput("!")
        assertEquals("!replacement", draft)
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_SAVE).performClick()
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_CANCEL).performClick()
        assertEquals("q1", saved)
        assertEquals(1, cancelled)
    }

    @Test
    fun `the queue page exposes pull to refresh`() {
        val state = SessionQueueScreenState.from(
            sessionID = "s1",
            items = listOf(SessionQueueItem("q1", QueueLane.NEXT_TURN, "text")),
            queueSessionID = "s1",
        )
        var refreshed = 0
        compose.setContent {
            PdshTheme { SessionQueuePage(state = state, onRefresh = { refreshed += 1 }) }
        }
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_REFRESH).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_LIST).performTouchInput { swipeDown() }
        compose.waitForIdle()
        assertEquals(1, refreshed)
    }

    @Test
    fun `a failed queue read is its own error section`() {
        val state = SessionQueueScreenState.from(
            sessionID = "s1",
            items = null,
            queueSessionID = "s1",
            failure = UiStrings.SESSION_LOAD_FAILED,
        )
        var retried = 0
        compose.setContent {
            PdshTheme { SessionQueuePage(state = state, onRetry = { retried += 1 }) }
        }
        compose.onNodeWithTag(UiPageTags.SESSION_QUEUE_ERROR).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSION_LOAD_FAILED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
    }

    // ----------------------------------------------------------------- helpers

    /** The drawer with every local callback defaulted; a test passes only what it asserts. */
    @Composable
    private fun Drawer(
        state: SessionsScreenState,
        onSelect: (SessionRowView) -> Unit = {},
        onQueryChange: (String) -> Unit = {},
        onNewSession: () -> Unit = {},
        onRetry: (() -> Unit)? = null,
        onRenameStart: (SessionRowView) -> Unit = {},
        onRenameDraftChange: (String) -> Unit = {},
        onRenameCommit: (SessionRowView) -> Unit = {},
        onRenameCancel: () -> Unit = {},
        onToggleWorkspace: (SessionWorkspaceView) -> Unit = {},
        onWorkspaceMenuToggle: (SessionWorkspaceView) -> Unit = {},
        onNewSessionInWorkspace: (SessionWorkspaceView) -> Unit = {},
        onRenameWorkspaceStart: (SessionWorkspaceView) -> Unit = {},
        onDeleteWorkspaceRequest: (SessionWorkspaceView) -> Unit = {},
        onDeleteWorkspaceConfirm: (SessionWorkspaceView) -> Unit = {},
        onDeleteWorkspaceCancel: () -> Unit = {},
        onAddWorkspace: () -> Unit = {},
        onWorkspaceDraftChange: (String) -> Unit = {},
        onCreateWorkspace: () -> Unit = {},
        onCancelCreateWorkspace: () -> Unit = {},
        onToggleArchived: () -> Unit = {},
        onRestoreArchived: (ArchivedRowView) -> Unit = {},
        onSessionMenuToggle: (SessionRowView) -> Unit = {},
        onArchiveSession: (SessionRowView) -> Unit = {},
        onRefresh: (() -> Unit)? = null,
    ) {
        SessionsPage(
            state = state,
            onSelect = onSelect,
            onQueryChange = onQueryChange,
            onRenameStart = onRenameStart,
            onRenameDraftChange = onRenameDraftChange,
            onRenameCommit = onRenameCommit,
            onRenameCancel = onRenameCancel,
            onNewSession = onNewSession,
            onRetry = onRetry,
            onToggleWorkspace = onToggleWorkspace,
            onWorkspaceMenuToggle = onWorkspaceMenuToggle,
            onNewSessionInWorkspace = onNewSessionInWorkspace,
            onRenameWorkspaceStart = onRenameWorkspaceStart,
            onDeleteWorkspaceRequest = onDeleteWorkspaceRequest,
            onDeleteWorkspaceConfirm = onDeleteWorkspaceConfirm,
            onDeleteWorkspaceCancel = onDeleteWorkspaceCancel,
            onAddWorkspace = onAddWorkspace,
            onWorkspaceDraftChange = onWorkspaceDraftChange,
            onCreateWorkspace = onCreateWorkspace,
            onCancelCreateWorkspace = onCancelCreateWorkspace,
            onToggleArchived = onToggleArchived,
            onRestoreArchived = onRestoreArchived,
            onSessionMenuToggle = onSessionMenuToggle,
            onArchiveSession = onArchiveSession,
            onRefresh = onRefresh,
        )
    }

    /** The drawer's host facts; defaults are a host that reported every list as empty. */
    private fun drawer(
        sessions: List<SessionListing> = emptyList(),
        workspaces: List<SessionWorkspace>? = emptyList(),
        archived: List<SessionListing>? = emptyList(),
        local: SessionsLocalState = SessionsLocalState(),
        currentSessionID: String? = null,
        newSessionBlock: NewSessionBlock? = null,
        failure: String? = null,
    ): SessionsScreenState = SessionsScreenState.from(
        sessions = sessions,
        local = local,
        nowMs = now,
        zone = zone,
        failure = failure,
        workspaces = workspaces,
        archivedSessions = archived,
        currentSessionID = currentSessionID,
        newSessionBlock = newSessionBlock,
    )

    // ------------------------------------------------------------------- history

    @Test
    fun `a waiting history page shows the waiting copy`() {
        compose.setContent {
            PdshTheme {
                SessionHistoryPage(
                    state = SessionHistoryScreenState.from(emptyList(), waiting = true),
                    onSelectTurn = {},
                    onToggleRow = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.HISTORY_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WAITING_ENGINE).assertIsDisplayed()
    }

    @Test
    fun `an empty history page shows the empty copy`() {
        compose.setContent {
            PdshTheme {
                SessionHistoryPage(
                    state = SessionHistoryScreenState.from(emptyList()),
                    onSelectTurn = {},
                    onToggleRow = {},
                )
            }
        }
        compose.onNodeWithText(UiStrings.HISTORY_EMPTY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.HISTORY_LIST).assertDoesNotExist()
    }

    @Test
    fun `the turn list renders and opens a turn`() {
        val state = SessionHistoryScreenState.from(SpecFixtures.projectCase("chat-basic"))
        var selected: String? = null
        compose.setContent {
            PdshTheme {
                SessionHistoryPage(
                    state = state,
                    onSelectTurn = { selected = it },
                    onToggleRow = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.HISTORY_LIST).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TURN_LABEL.format(1)).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.HISTORY_TURN).performClick()
        assertEquals("turn-0001", selected)
    }

    @Test
    fun `a selected turn renders its own rows and its own banner`() {
        val nodes = SpecFixtures.projectCase("turn-error-vs-complete")
        val state = SessionHistoryScreenState.from(
            nodes,
            local = SessionHistoryLocalState(selectedTurnID = "turn-0001"),
        )
        compose.setContent {
            PdshTheme {
                SessionHistoryPage(state = state, onSelectTurn = {}, onToggleRow = {})
            }
        }
        compose.onNodeWithTag(UiPageTags.HISTORY_DETAIL).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.HISTORY_ROWS).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.FAIL_LOUD_BANNER).assertIsDisplayed()
        // The banner's label distinguishes it from the tool row that carries the
        // same failure text.
        compose.onNodeWithText(UiStrings.TURN_FAILED).assertIsDisplayed()
    }

    @Test
    fun `a turn with no rows shows the detail empty state`() {
        // A turn node with no events is a real turn whose detail has nothing to show.
        val nodes = SpecFixtures.projectCase("chat-basic")
        val turnOnly = nodes.filter { it.kind == com.phonedsh.ui.projection.UiStateKind.TURN } +
            nodes.filter { it.kind == com.phonedsh.ui.projection.UiStateKind.ROOT } +
            nodes.filter { it.kind == com.phonedsh.ui.projection.UiStateKind.SESSION }
        val state = SessionHistoryScreenState.from(
            turnOnly,
            local = SessionHistoryLocalState(selectedTurnID = "turn-0001"),
        )
        compose.setContent {
            PdshTheme {
                SessionHistoryPage(state = state, onSelectTurn = {}, onToggleRow = {})
            }
        }
        compose.onNodeWithTag(UiPageTags.HISTORY_DETAIL_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.HISTORY_DETAIL_EMPTY).assertIsDisplayed()
    }

    @Test
    fun `a failed history read shows a retryable failure line`() {
        var retried = 0
        compose.setContent {
            PdshTheme {
                SessionHistoryPage(
                    state = SessionHistoryScreenState.from(
                        SpecFixtures.projectCase("chat-basic"),
                        failure = UiStrings.HISTORY_LOAD_FAILED,
                    ),
                    onSelectTurn = {},
                    onToggleRow = {},
                    onRetry = { retried += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.HISTORY_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
    }

    // ---------------------------------------------------------------------- goal

    @Test
    fun `a goal detail page without a goal shows the empty state`() {
        compose.setContent {
            PdshTheme {
                GoalDetailPage(
                    state = GoalDetailScreenState.from(null),
                    onPause = {},
                    onResume = {},
                    onClear = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.GOAL_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.GOAL_EMPTY).assertIsDisplayed()
    }

    @Test
    fun `a waiting goal detail page shows the waiting copy`() {
        compose.setContent {
            PdshTheme {
                GoalDetailPage(
                    state = GoalDetailScreenState.from(null, waiting = true),
                    onPause = {},
                    onResume = {},
                    onClear = {},
                )
            }
        }
        compose.onNodeWithText(UiStrings.WAITING_ENGINE).assertIsDisplayed()
    }

    @Test
    fun `an active goal renders its objective and pauses`() {
        var paused = 0
        compose.setContent {
            PdshTheme {
                GoalDetailPage(
                    state = GoalDetailScreenState.from(activeGoal()),
                    onPause = { paused += 1 },
                    onResume = {},
                    onClear = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.GOAL_OBJECTIVE).assertIsDisplayed()
        compose.onNodeWithText("ship the port").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.GOAL_ACTIVE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.GOAL_PAUSE).performClick()
        assertEquals(1, paused)
        compose.onNodeWithTag(UiPageTags.GOAL_CLEAR).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.GOAL_RESUME).assertDoesNotExist()
        // A blocked reason exists only for a blocked goal: an active goal has no
        // such fact, so the row is absent rather than empty or "无".
        compose.onNodeWithTag(UiPageTags.GOAL_REASON).assertDoesNotExist()
    }

    @Test
    fun `a blocked goal renders its reason and resumes`() {
        var resumed = 0
        val blocked = HarnessGoal(
            objective = "ship the port",
            phase = HarnessGoal.Phase.BLOCKED,
            roundsStarted = 1,
            maxGoalRounds = 4,
            blockedReason = "the protocol is not frozen",
        )
        compose.setContent {
            PdshTheme {
                GoalDetailPage(
                    state = GoalDetailScreenState.from(blocked),
                    onPause = {},
                    onResume = { resumed += 1 },
                    onClear = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.GOAL_REASON).assertIsDisplayed()
        compose.onNodeWithText("the protocol is not frozen").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.GOAL_RESUME).performClick()
        assertEquals(1, resumed)
    }

    @Test
    fun `a failed goal read with no goal offers a retry`() {
        var retried = 0
        compose.setContent {
            PdshTheme {
                GoalDetailPage(
                    state = GoalDetailScreenState.from(null, failure = UiStrings.GOAL_LOAD_FAILED),
                    onPause = {},
                    onResume = {},
                    onClear = {},
                    onRetry = { retried += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.GOAL_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
    }

    @Test
    fun `the goal bar is hidden without a goal and pauses an active one`() {
        compose.setContent {
            PdshTheme { GoalBar(goal = GoalBarState.Hidden) }
        }
        compose.onNodeWithTag(UiTags.GOAL_BAR).assertDoesNotExist()
    }

    @Test
    fun `the goal bar opens the detail sheet`() {
        var opened = false
        compose.setContent {
            PdshTheme {
                GoalBar(
                    goal = GoalBarState.Visible(phase = "active", objective = "ship the port"),
                    onPause = {},
                    onClear = {},
                    onOpenDetail = { opened = true },
                )
            }
        }
        compose.onNodeWithTag(UiTags.GOAL_BAR).assertIsDisplayed()
        compose.onNodeWithText("ship the port").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.GOAL_BAR_DETAIL).performClick()
        assertEquals(true, opened)
    }

    @Test
    fun `the goal bar shows resume for a paused goal`() {
        var resumed = 0
        compose.setContent {
            PdshTheme {
                GoalBar(
                    goal = GoalBarState.Visible(phase = "paused", objective = "ship the port"),
                    onResume = { resumed += 1 },
                )
            }
        }
        compose.onNodeWithText(UiStrings.GOAL_RESUME).performClick()
        assertEquals(1, resumed)
    }

    private fun activeGoal(): HarnessGoal = HarnessGoal(
        objective = "ship the port",
        phase = HarnessGoal.Phase.ACTIVE,
        roundsStarted = 2,
        maxGoalRounds = 5,
    )
}
