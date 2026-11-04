// The Q2 pages' four states and their ScreenState sequence (JVM + Robolectric).
// SPDX-License-Identifier: MIT
//
// Two pages share this file because they are one lane and one delivery:
//   * NativeWorkbenchPage: the turn's written files and the commands it ran;
//   * WorkspaceFoldersPage: the folders, their creation, switch and removal.
//
// The unknown-state tests deliberately locate their region with
// `performScrollToNode` before asserting that an unmeasured value is absent: the
// segment bodies are lazy lists, and a bare `assertDoesNotExist` on an uncomposed
// row would pass for the wrong reason.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.tokenNames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

// ---------------------------------------------------------------------------
// NativeWorkbenchPage
// ---------------------------------------------------------------------------

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class NativeWorkbenchPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val notes = WorkbenchFile(
        id = "f1",
        name = "notes.md",
        path = "notes.md",
        toolName = "write",
        byteCount = 1536,
    )
    private val logo = WorkbenchFile(
        id = "f2",
        name = "logo.png",
        path = "assets/logo.png",
        toolName = "write",
    )
    private val rg = WorkbenchCommand(id = "c1", command = "rg -n TODO src", exitCode = 0)
    private val npm = WorkbenchCommand(id = "c2", command = "npm test", exitCode = 2)

    private fun show(
        state: WorkbenchScreenState,
        onDone: () -> Unit = {},
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                NativeWorkbenchPage(
                    state = state,
                    onSelectSection = {},
                    onOpenFile = {},
                    onClosePreview = {},
                    onDone = onDone,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )
            }
        }
    }

    /** A host that applies the page events, so a tap actually moves the state. */
    private fun showLive(snapshot: WorkbenchSnapshot, initial: WorkbenchLocalState = WorkbenchLocalState()) {
        compose.setContent {
            var local by remember { mutableStateOf(initial) }
            PdshTheme {
                NativeWorkbenchPage(
                    state = WorkbenchScreenState.from(snapshot, local),
                    onSelectSection = { local = local.apply(WorkbenchUiEvent.SelectSection(it)) },
                    onOpenFile = { local = local.apply(WorkbenchUiEvent.OpenFile(it.path)) },
                    onClosePreview = { local = local.apply(WorkbenchUiEvent.ClosePreview) },
                    onDone = {},
                )
            }
        }
    }

    @Test
    fun `a turn without writes shows the empty state and 完成 closes the sheet`() {
        var done = 0
        val state = WorkbenchScreenState.from(WorkbenchSnapshot(files = emptyList(), commands = emptyList()))
        assertEquals(WorkbenchSegmentStatus.EMPTY, state.filesStatus)
        assertEquals(WorkbenchSegmentStatus.EMPTY, state.commandsStatus)
        show(state, onDone = { done += 1 })
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.WORKBENCH_FILES_EMPTY))
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_FILES_EMPTY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithText("0 B").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_DONE).performClick()
        assertEquals(1, done)
    }

    @Test
    fun `written files render their measured size and an unmeasured one is 未知`() {
        val state = WorkbenchScreenState.from(
            WorkbenchSnapshot(files = listOf(notes, logo), commands = emptyList()),
        )
        assertEquals(WorkbenchSegmentStatus.READY, state.filesStatus)
        assertTrue(state.hasUnmeasuredValues)
        show(state)
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_LIST).assertIsDisplayed()
        compose.onNodeWithText("notes.md").assertIsDisplayed()
        compose.onNodeWithText("1.5 KiB").assertIsDisplayed()
        // `logo.png` was written but its size was not measured: the word, not 0.
        compose.onNodeWithText(UiStrings.UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_UNMEASURED_HINT).assertIsDisplayed()
        // Both rows name their writer; neither is a blank line.
        compose.onAllNodesWithText(UiStrings.WORKBENCH_WRITTEN_BY.format("write")).assertCountEquals(2)
    }

    @Test
    fun `a file row opens its preview and the header back closes it`() {
        val read = WorkbenchRead("notes.md", FileContentView.Text("hello workbench"))
        showLive(WorkbenchSnapshot(files = listOf(notes), commands = emptyList(), read = read))
        compose.onNodeWithText("notes.md").performClick()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_PREVIEW).assertIsDisplayed()
        compose.onNodeWithText("hello workbench").assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_PREVIEW).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_LIST).assertIsDisplayed()
    }

    @Test
    fun `a binary read without a measured size says 未知 instead of a number`() {
        val state = WorkbenchScreenState.from(
            WorkbenchSnapshot(
                files = listOf(logo),
                commands = emptyList(),
                read = WorkbenchRead("assets/logo.png", FileContentView.Binary(byteCount = null)),
            ),
            WorkbenchLocalState(previewPath = "assets/logo.png"),
        )
        show(state)
        compose.onNodeWithTag(UiPageTags.WORKBENCH_PREVIEW).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_BINARY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_BINARY_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.UNKNOWN).assertIsDisplayed()
    }

    @Test
    fun `a tapped path that is not listed yet stays pending and opens once it appears`() {
        val pending = WorkbenchScreenState.from(
            WorkbenchSnapshot(files = emptyList(), commands = emptyList()),
            WorkbenchLocalState(previewPath = "later.md"),
        )
        assertTrue(pending.preview is WorkbenchPreview.Pending)
        show(pending)
        compose.onNodeWithTag(UiPageTags.WORKBENCH_PREVIEW_PENDING).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_PREVIEW_PENDING).assertIsDisplayed()

        // The next snapshot lists the file: the same local state now previews it,
        // with no extra event (the write landed while the sheet was open).
        val later = WorkbenchFile(id = "f3", name = "later.md", path = "later.md", toolName = "write")
        val opened = WorkbenchScreenState.from(
            WorkbenchSnapshot(
                files = listOf(later),
                commands = emptyList(),
                read = WorkbenchRead("later.md", FileContentView.Text("late")),
            ),
            WorkbenchLocalState(previewPath = "later.md"),
        )
        assertTrue(opened.preview is WorkbenchPreview.Text)
    }

    @Test
    fun `commands render their argv and a measured or unknown exit code`() {
        val running = WorkbenchCommand(id = "c3", command = "make")
        val state = WorkbenchScreenState.from(
            WorkbenchSnapshot(files = listOf(notes), commands = listOf(rg, npm, running)),
            WorkbenchLocalState(section = WorkbenchSection.COMMANDS),
        )
        show(state)
        compose.onNodeWithTag(UiPageTags.WORKBENCH_COMMANDS_LIST).assertIsDisplayed()
        compose.onNodeWithText("rg -n TODO src").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_EXIT_CODE.format("0")).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_EXIT_CODE.format("2")).assertIsDisplayed()
        // `make` ran but no exit code was measured: the word, not 0.
        compose.onNodeWithText(UiStrings.WORKBENCH_EXIT_CODE.format(UiStrings.UNKNOWN)).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_UNMEASURED_HINT).assertIsDisplayed()
    }

    @Test
    fun `a failed snapshot shows a retryable failure line and no list claim`() {
        var retried = 0
        var dismissed = 0
        val state = WorkbenchScreenState.from(WorkbenchSnapshot(failure = UiStrings.WORKBENCH_FAILED))
        assertEquals(WorkbenchStatus.FAILED, state.status)
        assertTrue(state.files.isEmpty())
        assertTrue(state.commands.isEmpty())
        show(state, onRetry = { retried += 1 }, onDismissFailure = { dismissed += 1 })
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_FAILED).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_LIST).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WORKBENCH_FILES_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
        compose.onNodeWithContentDescription(UiStrings.DISMISS).performClick()
        assertEquals(1, dismissed)
    }

    @Test
    fun `an unreported turn is 未知 in both segments and never an empty list`() {
        val state = WorkbenchScreenState.from(WorkbenchSnapshot(files = null, commands = null))
        assertEquals(WorkbenchStatus.UNKNOWN, state.status)
        assertEquals(WorkbenchSegmentStatus.UNKNOWN, state.filesStatus)
        assertEquals(WorkbenchSegmentStatus.UNKNOWN, state.commandsStatus)
        showLive(WorkbenchSnapshot(files = null, commands = null))

        // Step 1: locate the files region inside its lazy list, then assert. Without
        // this scroll the absence checks below could pass on an uncomposed item.
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.WORKBENCH_FILES_UNKNOWN))
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_FILES_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_FILES_EMPTY).assertDoesNotExist()
        compose.onNodeWithText("0 B").assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WORKBENCH_EXIT_CODE.format("0")).assertDoesNotExist()

        // Step 2: the commands segment is behind the second tab. Navigate there,
        // locate its block, and only then assert what it does not claim.
        compose.onNodeWithTag(UiPageTags.WORKBENCH_COMMANDS_TAB).performClick()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_LIST).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_COMMANDS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.WORKBENCH_COMMANDS_UNKNOWN))
        compose.onNodeWithTag(UiPageTags.WORKBENCH_COMMANDS_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_COMMANDS_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKBENCH_COMMANDS_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WORKBENCH_EXIT_CODE.format("0")).assertDoesNotExist()
    }

    @Test
    fun `the segment and preview sequence is a pure function of the script`() {
        val snapshot = WorkbenchSnapshot(
            files = listOf(notes),
            commands = listOf(rg),
            read = WorkbenchRead("notes.md", FileContentView.Text("hello")),
        )
        fun run(): List<String> {
            var local = WorkbenchLocalState()
            val out = mutableListOf<String>()
            out += WorkbenchScreenState.from(snapshot, local).signature()
            local = local.apply(WorkbenchUiEvent.OpenFile("notes.md"))
            out += WorkbenchScreenState.from(snapshot, local).signature()
            local = local.apply(WorkbenchUiEvent.SelectSection(WorkbenchSection.COMMANDS))
            out += WorkbenchScreenState.from(snapshot, local).signature()
            local = local.apply(WorkbenchUiEvent.ClosePreview)
            out += WorkbenchScreenState.from(snapshot, local).signature()
            local = local.apply(WorkbenchUiEvent.SelectSection(WorkbenchSection.FILES))
            out += WorkbenchScreenState.from(snapshot, local).signature()
            return out
        }

        val expected = listOf(
            "FILES:READY:READY:READY:Hidden",
            "FILES:READY:READY:READY:Text",
            "COMMANDS:READY:READY:READY:Text",
            "COMMANDS:READY:READY:READY:Hidden",
            "FILES:READY:READY:READY:Hidden",
        )
        val states = run()
        assertEquals(expected, states)
        // Replaying the same script yields exactly the same sequence (purity).
        assertEquals(states, run())
    }
}

// ---------------------------------------------------------------------------
// WorkspaceFoldersPage
// ---------------------------------------------------------------------------

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class WorkspaceFoldersPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val builtIn = WorkspaceFolder(id = "w1", name = "workspace", sessionCount = 2)
    private val project = WorkspaceFolder(id = "w2", name = "Project A")
    private val snapshot = WorkspaceFoldersSnapshot(
        folders = listOf(builtIn, project),
        selectedID = "w1",
    )

    /** A host that applies the page events, so typing and confirming move the state. */
    private fun showLive(
        snapshot: WorkspaceFoldersSnapshot,
        onOpenFiles: (WorkspaceFolderView) -> Unit = {},
        onSwitch: (WorkspaceFolderView) -> Unit = {},
        onDeleteConfirm: (WorkspaceFolderView) -> Unit = {},
        onCreate: () -> Unit = {},
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
    ) {
        compose.setContent {
            var local by remember { mutableStateOf(WorkspaceFoldersLocalState()) }
            PdshTheme {
                WorkspaceFoldersPage(
                    state = WorkspaceFoldersScreenState.from(snapshot, local),
                    onBack = {},
                    onOpenFiles = onOpenFiles,
                    onSwitch = onSwitch,
                    onBeginCreate = { local = local.apply(WorkspaceFoldersUiEvent.BeginCreate) },
                    onDraftChange = { local = local.apply(WorkspaceFoldersUiEvent.DraftChange(it)) },
                    onCancelCreate = { local = local.apply(WorkspaceFoldersUiEvent.CancelCreate) },
                    onCreate = {
                        onCreate()
                        local = local.apply(WorkspaceFoldersUiEvent.CancelCreate)
                    },
                    onDeleteRequest = { local = local.apply(WorkspaceFoldersUiEvent.RequestDelete(it.id)) },
                    onDeleteConfirm = onDeleteConfirm,
                    onDeleteCancel = { local = local.apply(WorkspaceFoldersUiEvent.CancelDelete) },
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )
            }
        }
    }

    @Test
    fun `name validation rejects blank, separators, control characters and long names`() {
        assertNull(validateWorkspaceName("Project A"))
        assertEquals(WorkspaceNameError.EMPTY, validateWorkspaceName("   "))
        assertEquals(WorkspaceNameError.SEPARATOR, validateWorkspaceName("a/b"))
        // A backslash is legal in the workspace path and the baseline accepts it.
        assertNull(validateWorkspaceName("a\\b"))
        assertEquals(WorkspaceNameError.CONTROL, validateWorkspaceName("a\nb"))
        assertEquals(
            WorkspaceNameError.TOO_LONG,
            validateWorkspaceName("x".repeat(WORKSPACE_NAME_MAX_LENGTH + 1)),
        )
        assertNull(validateWorkspaceName("x".repeat(WORKSPACE_NAME_MAX_LENGTH)))
    }

    @Test
    fun `an empty snapshot shows the empty state, not the unknown one`() {
        val state = WorkspaceFoldersScreenState.from(WorkspaceFoldersSnapshot(folders = emptyList()))
        assertTrue(state.isEmpty)
        showLive(WorkspaceFoldersSnapshot(folders = emptyList()))
        compose.onNodeWithTag(UiPageTags.WORKSPACE_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.WORKSPACE_EMPTY))
        compose.onNodeWithTag(UiPageTags.WORKSPACE_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKSPACE_EMPTY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_UNKNOWN).assertDoesNotExist()
    }

    @Test
    fun `the empty state can open the validated creation script`() {
        val started = WorkspaceFoldersLocalState().apply(WorkspaceFoldersUiEvent.BeginCreate)
        val empty = WorkspaceFoldersScreenState.from(
            WorkspaceFoldersSnapshot(folders = emptyList()),
            started,
        )
        assertTrue(empty.isEmpty)
        assertTrue(empty.creating)
        assertEquals(WorkspaceNameError.EMPTY, empty.nameError)
        val typed = started.apply(WorkspaceFoldersUiEvent.DraftChange("Project"))
        val ready = WorkspaceFoldersScreenState.from(WorkspaceFoldersSnapshot(folders = emptyList()), typed)
        assertNull(ready.nameError)
        assertTrue(ready.canCreate)
    }

    @Test
    fun `the toolbar verb is the baseline's 添加`() {
        showLive(snapshot)
        // `NativeShell.swift:376`: the toolbar carries the short verb.
        compose.onNodeWithTag(UiPageTags.WORKSPACE_NEW).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKSPACE_ADD).assertIsDisplayed()
    }

    @Test
    fun `folders match the iOS navigation row and open their Files page`() {
        var opened: WorkspaceFolderView? = null
        showLive(snapshot, onOpenFiles = { opened = it })
        compose.onNodeWithTag(UiPageTags.WORKSPACE_LIST).assertIsDisplayed()
        // The built-in `workspace` folder is reworded for display.
        compose.onNodeWithText(UiStrings.DRAWER_DEFAULT_FOLDER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKSPACE_SESSION_COUNT.format(2)).assertIsDisplayed()
        // The second folder's count was not measured: 未知 plus one explanation line.
        compose.onNodeWithText(UiStrings.UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKSPACE_UNMEASURED_HINT).assertIsDisplayed()
        // The iOS row has only the NavigationLink to FilesPage; switching/deleting
        // folders are not actions in WorkspaceFoldersPage.swift.
        compose.onNodeWithTag(UiPageTags.WORKSPACE_SWITCH).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_DELETE).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.DRAWER_DEFAULT_FOLDER).performClick()
        assertEquals("w1", opened?.id)
    }

    @Test
    fun `workspace rows do not expose Android-only switch and delete actions`() {
        showLive(snapshot)
        compose.onAllNodesWithTag(UiPageTags.WORKSPACE_ROW).assertCountEquals(2)
        compose.onAllNodesWithTag(UiPageTags.WORKSPACE_ROW)[0]
            .assertIsDisplayed()
            .assertHeightIsAtLeast(HomeMetrics.defaultMinListRowHeight)
        compose.onNodeWithTag(UiPageTags.WORKSPACE_SWITCH).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_DELETE).assertDoesNotExist()
    }

    @Test
    fun `a failed folder read shows the failure line and no list claim`() {
        var retried = 0
        val failed = WorkspaceFoldersSnapshot(
            folders = null,
            failure = UiStrings.WORKSPACE_LOAD_FAILED,
        )
        assertEquals(WorkspaceFoldersStatus.FAILED, WorkspaceFoldersScreenState.from(failed).status)
        showLive(failed, onRetry = { retried += 1 })
        compose.onNodeWithTag(UiPageTags.WORKSPACE_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKSPACE_LOAD_FAILED).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_LIST).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WORKSPACE_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
    }

    @Test
    fun `an unreported folder list is 未知, not empty`() {
        val state = WorkspaceFoldersScreenState.from(WorkspaceFoldersSnapshot(folders = null))
        assertTrue(state.isUnknown)
        showLive(WorkspaceFoldersSnapshot(folders = null))

        // Locate the unknown block inside the lazy list first; only then assert that
        // the empty copy and a zero count are absent. A bare `assertDoesNotExist`
        // here would not prove the block was ever composed.
        compose.onNodeWithTag(UiPageTags.WORKSPACE_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.WORKSPACE_UNKNOWN))
        compose.onNodeWithTag(UiPageTags.WORKSPACE_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKSPACE_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WORKSPACE_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WORKSPACE_SESSION_COUNT.format(0)).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WORKSPACE_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `the create and delete script is a pure function of the snapshot and the events`() {
        fun run(): List<String> {
            var local = WorkspaceFoldersLocalState()
            val out = mutableListOf<String>()
            fun record() {
                out += WorkspaceFoldersScreenState.from(snapshot, local).signature()
            }
            record()
            local = local.apply(WorkspaceFoldersUiEvent.BeginCreate)
            record()
            local = local.apply(WorkspaceFoldersUiEvent.DraftChange("a/b"))
            record()
            local = local.apply(WorkspaceFoldersUiEvent.DraftChange("Project B"))
            record()
            local = local.apply(WorkspaceFoldersUiEvent.CancelCreate)
            record()
            // The current folder's delete request is refused by the projection.
            local = local.apply(WorkspaceFoldersUiEvent.RequestDelete("w1"))
            record()
            local = local.apply(WorkspaceFoldersUiEvent.RequestDelete("w2"))
            record()
            local = local.apply(WorkspaceFoldersUiEvent.CancelDelete)
            record()
            return out
        }

        val expected = listOf(
            "READY|false|null|false|null|[w1, w2]",
            "READY|true|EMPTY|false|null|[w1, w2]",
            "READY|true|SEPARATOR|false|null|[w1, w2]",
            "READY|true|null|true|null|[w1, w2]",
            "READY|false|null|false|null|[w1, w2]",
            "READY|false|null|false|null|[w1, w2]",
            "READY|false|null|false|w2|[w1, w2]",
            "READY|false|null|false|null|[w1, w2]",
        )
        val states = run()
        assertEquals(expected, states)
        // Replaying the same script yields exactly the same sequence (purity).
        assertEquals(states, run())
    }
}

// ---------------------------------------------------------------------------
// Token inventories
// ---------------------------------------------------------------------------

/**
 * The two pages declare the tokens they read; this guard catches a typo before the
 * day `PageTokenReferenceTest`'s page map starts listing them.
 */
class WorkbenchFoldersTokenInventoryTest {
    @Test
    fun `every declared page token is a real tokens json leaf`() {
        val known = SpecFixtures.tokenNames()
        NativeWorkbenchPageTokens.refs.forEach { token ->
            assertTrue("NativeWorkbenchPage declares '$token', which is not in tokens.json", token in known)
        }
        WorkspaceFoldersPageTokens.refs.forEach { token ->
            assertTrue("WorkspaceFoldersPage declares '$token', which is not in tokens.json", token in known)
        }
    }
}

// ---------------------------------------------------------------------------
// Sequence signatures
// ---------------------------------------------------------------------------

private fun WorkbenchScreenState.signature(): String =
    "$section:$status:$filesStatus:$commandsStatus:${previewKind(preview)}"

private fun previewKind(preview: WorkbenchPreview): String = when (preview) {
    WorkbenchPreview.Hidden -> "Hidden"
    is WorkbenchPreview.Pending -> "Pending"
    is WorkbenchPreview.Loading -> "Loading"
    is WorkbenchPreview.Text -> "Text"
    is WorkbenchPreview.Binary -> "Binary"
    is WorkbenchPreview.Unreadable -> "Unreadable"
}

private fun WorkspaceFoldersScreenState.signature(): String =
    "$status|$creating|$nameError|$canCreate|$deleteTargetID|${folders.map { it.id }}"
