// Session pages (JVM + Robolectric): the four pages bind state and never fake it.
// SPDX-License-Identifier: MIT
//
// Each page is asserted on semantics (the visible copy, the stable tags and the
// callbacks), with one exact fixed-height assertion for the source-owned standalone
// session row floor. Text bounds remain platform-dependent under Robolectric.
package com.phonedsh.ui.page

import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHeightIsAtLeast
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
import com.phonedsh.ui.SessionsMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.disclosure.DisclosureKind
import com.phonedsh.ui.disclosure.DisclosureMotion
import com.phonedsh.ui.disclosure.PdshDisclosureTags
import com.phonedsh.ui.menu.ContextMenuModel
import com.phonedsh.ui.menu.ContextMenuRowState
import com.phonedsh.ui.menu.ContextMenuTags
import com.phonedsh.ui.state.GoalBarState
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.PdshThemeValues
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
        compose.onAllNodesWithTag(UiPageTags.SESSION_ROW)[0].assertHeightIsAtLeast(SessionsMetrics.STANDALONE_SESSION_ROW_HEIGHT_PT.dp)
        compose.onAllNodesWithTag(UiPageTags.SESSION_ROW)[0].performClick()
        assertEquals("s1", selected)
    }

    @Test
    fun `search filters host sessions and an unmatched query shows honest no-results copy`() {
        val matching = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论"), SessionListing("s2", "周报草稿")),
            local = SessionsLocalState(query = "项目"),
        )
        val state = mutableStateOf(matching)
        compose.setContent { PdshTheme { Drawer(state = state.value) } }
        compose.onNodeWithTag(UiPageTags.SESSIONS_SEARCH).assertIsDisplayed()
        compose.onNodeWithText("项目讨论").assertIsDisplayed()
        compose.onNodeWithText("周报草稿").assertDoesNotExist()

        val noMatch = drawer(
            sessions = listOf(SessionListing("s1", "项目讨论")),
            local = SessionsLocalState(query = "不存在的词"),
        )
        compose.runOnIdle { state.value = noMatch }
        compose.onNodeWithTag(UiPageTags.SESSIONS_LIST)
            .performScrollToNode(hasTestTag(SESSION_SEARCH_NO_RESULTS_TAG))
        compose.onNodeWithTag(SESSION_SEARCH_NO_RESULTS_TAG).assertIsDisplayed()
        compose.onNodeWithText("没有结果").assertIsDisplayed()
        compose.onNodeWithText("没有找到与“不存在的词”匹配的会话。").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_SECTION_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `daily grouping and unassigned sessions remain visible with unknown folder facts`() {
        val state = mutableStateOf(drawer(
            sessions = listOf(
                SessionListing("daily-1", "日常里的会话"),
                SessionListing("loose-1", "未归属的会话"),
            ),
            workspaces = listOf(SessionWorkspace("daily", "workspace", listOf("daily-1"))),
        ))
        compose.setContent { PdshTheme { Drawer(state = state.value) } }
        compose.onNodeWithText(UiStrings.DRAWER_DEFAULT_FOLDER).assertIsDisplayed()
        compose.onNodeWithText("日常里的会话").assertIsDisplayed()
        compose.onNodeWithText("未归属的会话").assertIsDisplayed()

        val unknown = drawer(
            sessions = listOf(SessionListing("loose-1", "未归属的会话")),
            workspaces = null,
        )
        compose.runOnIdle { state.value = unknown }
        compose.onNodeWithText("未归属的会话").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_WORKSPACE_UNKNOWN_HINT).assertIsDisplayed()
    }

    @Test
    fun `session mutation success and context loss require a host receipt`() {
        val base = drawer(sessions = listOf(SessionListing("s1", "当前会话")))
        val state = mutableStateOf(base)
        compose.setContent { PdshTheme { Drawer(state = state.value) } }
        compose.onNodeWithTag(PAGE_MUTATION_RECEIPT_TAG).assertDoesNotExist()

        val confirmed = base.copy(
            mutationReceipt = PageMutationReceipt(
                operation = PageMutationOperation.SESSION_ARCHIVE,
                outcome = PageMutationOutcome.SUCCEEDED,
                subject = "当前会话",
                contextLost = true,
            ),
        )
        compose.runOnIdle { state.value = confirmed }
        compose.onNodeWithTag(PAGE_MUTATION_RECEIPT_TAG).assertIsDisplayed()
        compose.onNodeWithText("当前会话已归档；当前上下文已离开。").assertIsDisplayed()
    }

    @Test
    fun `archive callback alone never displays a success receipt`() {
        val base = drawer(sessions = listOf(SessionListing("s1", "待归档会话")))
        val state = mutableStateOf(base)
        var dispatched = 0
        compose.setContent {
            PdshTheme {
                Drawer(
                    state = state.value,
                    onArchiveSession = { dispatched += 1 },
                )
            }
        }
        val items = ContextMenuModel.items("sessionsRow", ContextMenuRowState.unconditional)
        compose.onAllNodesWithTag(UiPageTags.SESSION_ROW)[0].performTouchInput { longClick() }
        compose.onNodeWithText(items[1].label).performClick()
        compose.waitForIdle()
        assertEquals(1, dispatched)
        compose.onNodeWithTag(PAGE_MUTATION_RECEIPT_TAG).assertDoesNotExist()

        compose.runOnIdle {
            state.value = base.copy(
                mutationReceipt = PageMutationReceipt(
                    operation = PageMutationOperation.SESSION_ARCHIVE,
                    outcome = PageMutationOutcome.SUCCEEDED,
                    subject = "待归档会话",
                ),
            )
        }
        compose.onNodeWithText("待归档会话已归档，可在已归档会话中恢复").assertIsDisplayed()
    }

    @Test
    fun `workspace delete receipt confirms sessions remain unfiled`() {
        val base = drawer(
            sessions = listOf(SessionListing("s1", "保留的会话")),
            workspaces = listOf(SessionWorkspace("w1", "Project A", listOf("s1"))),
        )
        val state = mutableStateOf(base)
        compose.setContent { PdshTheme { Drawer(state = state.value) } }
        compose.onNodeWithTag(PAGE_MUTATION_RECEIPT_TAG).assertDoesNotExist()

        compose.runOnIdle {
            state.value = base.copy(
                mutationReceipt = PageMutationReceipt(
                    operation = PageMutationOperation.WORKSPACE_DELETE,
                    outcome = PageMutationOutcome.SUCCEEDED,
                    subject = "Project A",
                ),
            )
        }
        compose.onNodeWithText("Project A已删除；其中的会话已保留").assertIsDisplayed()
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
    fun `the failure line is the baseline's message plus 重试 and has no dismiss glyph`() {
        // `SessionsPage.swift:176-197`: the row is Text(errorText) + Button("重试").
        // Android used to add a ✕ that the baseline never draws, so a reader could
        // hide a failure the baseline keeps until the read succeeds.
        val state = drawer(failure = UiStrings.SESSION_LOAD_FAILED)
        compose.setContent { PdshTheme { Drawer(state = state, onRetry = {}) } }
        compose.onNodeWithTag(UiPageTags.SESSIONS_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DISMISS).assertDoesNotExist()
        compose.onNodeWithContentDescription(UiStrings.DISMISS).assertDoesNotExist()
    }

    @Test
    fun `the bar band belongs to the page whether or not the host routes it`() {
        // `SessionsPage.swift:137-322` draws an empty navigation bar and the search
        // field below it; the back control is Android's addition for a routed page.
        // So the search field must not move when the host passes (or omits) onBack —
        // only the glyph appears — and `null` must draw no back control at all
        // (`ios-sessions-*.png` shows none).
        val state = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        var back = 0
        val onBack = mutableStateOf<(() -> Unit)?>(null)
        // The reserved band is a token, not a measurement: Robolectric's font
        // metrics are fake, so the row's exact height is not an oracle here — that
        // the band exists at all is.
        var reserved = 0.dp
        compose.setContent {
            PdshTheme {
                reserved = PdshThemeValues.tokens.geometry.pageHeaderMinHeight +
                    PdshThemeValues.tokens.geometry.cardOuterMarginV
                Drawer(state = state, onBack = onBack.value)
            }
        }
        val withoutBack = compose.onNodeWithTag(UiPageTags.SESSIONS_SEARCH)
            .getUnclippedBoundsInRoot()
        assertTrue(
            "no back control must still leave the baseline's empty bar above the search " +
                "(top=${withoutBack.top})",
            withoutBack.top >= reserved,
        )
        compose.onNodeWithContentDescription(UiStrings.BACK).assertDoesNotExist()

        compose.runOnIdle { onBack.value = { back += 1 } }
        val withBack = compose.onNodeWithTag(UiPageTags.SESSIONS_SEARCH)
            .getUnclippedBoundsInRoot()
        assertTrue(
            "the routed page must not lose the band it already had " +
                "(${withoutBack.top} -> ${withBack.top})",
            withBack.top >= withoutBack.top,
        )
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()
        assertEquals(1, back)
    }

    @Test
    fun `the drawer action occupies the existing navigation band without adding a page header`() {
        var opened = 0
        val state = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        compose.setContent {
            PdshTheme {
                Drawer(state = state, onOpenDrawer = { opened += 1 })
            }
        }
        compose.onNodeWithTag("sessions.drawer").assertIsDisplayed().performClick()
        assertEquals(1, opened)
        compose.onNodeWithText(UiStrings.SESSIONS).assertDoesNotExist()
    }

    @Test
    fun `a fixed single-root host hides workspace mutations it cannot perform`() {
        val state = drawer(
            sessions = listOf(SessionListing("chat-1", "项目讨论")),
            workspaces = listOf(SessionWorkspace("/dsh/workspace", "/dsh/workspace", listOf("chat-1"))),
            local = SessionsLocalState(workspaceMenuID = "/dsh/workspace"),
        )
        compose.setContent {
            PdshTheme {
                Drawer(state = state, workspaceActionsAvailable = false)
            }
        }
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_ROW, useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_MENU).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.SESSIONS_ADD_WORKSPACE).assertDoesNotExist()
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
    fun `the 已归档 header is the baseline's fold header, and the drawer has no invented title`() {
        val state = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        compose.setContent { PdshTheme { Drawer(state = state) } }
        compose.onNodeWithTag(UiPageTags.SESSIONS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SESSIONS_ARCHIVED_SECTION))
        // `SessionsPage.swift:303`–`:317`: a Button in the Section header, so the
        // title is the fold's own label and the count sits at its trailing edge.
        compose.onNodeWithText(UiStrings.SESSIONS_ARCHIVED).assertIsDisplayed()
        // The baseline's group at `:139` is untitled; only the page's name (会话列表)
        // says otherwise, and the drawer must not draw it.
        compose.onNodeWithText(UiStrings.SESSIONS).assertDoesNotExist()
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
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_ROW, useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("项目").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_WORKSPACE_COUNT.format(1)).assertIsDisplayed()
        compose.onNodeWithText("项目讨论").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SESSIONS_WORKSPACE_ROW, useUnmergedTree = true).performClick()
        assertEquals("w1", toggled)
    }

    @Test
    fun `the folder row is the shared folder disclosure and animates its body`() {
        val local = mutableStateOf(SessionsLocalState(collapsedWorkspaceIDs = setOf("w1")))
        compose.setContent {
            PdshTheme {
                Drawer(
                    state = drawer(
                        sessions = listOf(SessionListing("s1", "项目讨论")),
                        workspaces = listOf(SessionWorkspace("w1", "项目", listOf("s1"))),
                        local = local.value,
                    ),
                    onToggleWorkspace = { workspace ->
                        val collapsed = local.value.collapsedWorkspaceIDs
                        local.value = local.value.copy(
                            collapsedWorkspaceIDs = if (workspace.id in collapsed) {
                                collapsed - workspace.id
                            } else {
                                collapsed + workspace.id
                            },
                        )
                    },
                )
            }
        }
        val disclosure = sessionsWorkspaceDisclosureTag("w1")
        compose.onNodeWithTag(sessionsWorkspaceChevronTag("w1"), useUnmergedTree = true)
            .assertIsDisplayed()
        compose.onNodeWithTag(PdshDisclosureTags.body(disclosure)).assertDoesNotExist()

        compose.mainClock.autoAdvance = false
        compose.onNodeWithTag(PdshDisclosureTags.header(disclosure)).performClick()
        compose.mainClock.advanceTimeByFrame()
        val folderMs = DisclosureMotion.specFor(DisclosureKind.FOLDER, reducedMotion = false).durationMs
        compose.mainClock.advanceTimeBy(folderMs / 2L)
        val mid = compose.onNodeWithTag(PdshDisclosureTags.body(disclosure))
            .fetchSemanticsNode().boundsInRoot.height
        assertTrue("the folder body is mid-transition (height=$mid)", mid > 0f)

        compose.mainClock.advanceTimeBy(folderMs + 40L)
        compose.mainClock.advanceTimeByFrame()
        val settled = compose.onNodeWithTag(PdshDisclosureTags.body(disclosure))
            .fetchSemanticsNode().boundsInRoot.height
        assertTrue("the folder body settles below the half sample ($mid -> $settled)", settled > mid)
        compose.onNodeWithText("项目讨论").assertIsDisplayed()
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
    fun `long pressing a session opens exactly the sessionsRow surface`() {
        val state = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        compose.setContent { PdshTheme { Drawer(state = state) } }
        compose.onAllNodesWithTag(UiPageTags.SESSION_ROW)[0].performTouchInput { longClick() }
        val expected = ContextMenuModel.items("sessionsRow", ContextMenuRowState.unconditional)
        assertEquals(2, expected.size)
        expected.forEach { item ->
            compose.onNodeWithText(item.label).assertIsDisplayed()
        }
        compose.onNodeWithTag(ContextMenuTags.MENU).assertIsDisplayed()
    }

    @Test
    fun `the session menu renames and archives and closes before each action`() {
        val state = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
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
        val items = ContextMenuModel.items("sessionsRow", ContextMenuRowState.unconditional)
        compose.onAllNodesWithTag(UiPageTags.SESSION_ROW)[0].performTouchInput { longClick() }
        compose.onNodeWithText(items[0].label).performClick()
        compose.waitForIdle()
        assertEquals("s1", renamed)
        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()

        compose.onAllNodesWithTag(UiPageTags.SESSION_ROW)[0].performTouchInput { longClick() }
        compose.onNodeWithText(items[1].label).performClick()
        compose.waitForIdle()
        assertEquals("s1", archived)
        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()
    }

    @Test
    fun `a tap on a session still selects it and never opens the menu`() {
        val state = drawer(sessions = listOf(SessionListing("s1", "项目讨论")))
        var selected: String? = null
        compose.setContent {
            PdshTheme { Drawer(state = state, onSelect = { selected = it.id }) }
        }
        compose.onAllNodesWithTag(UiPageTags.SESSION_ROW)[0].performClick()
        compose.waitForIdle()
        assertEquals("s1", selected)
        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()
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

    // ----------------------------------------------------------------- helpers

    /** The drawer with every local callback defaulted; a test passes only what it asserts. */
    @Composable
    private fun Drawer(
        state: SessionsScreenState,
        onBack: (() -> Unit)? = null,
        onOpenDrawer: (() -> Unit)? = null,
        workspaceActionsAvailable: Boolean = true,
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
            onBack = onBack,
            onOpenDrawer = onOpenDrawer,
            workspaceActionsAvailable = workspaceActionsAvailable,
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
}
