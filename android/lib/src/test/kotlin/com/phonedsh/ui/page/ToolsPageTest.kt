// Commands (PDSHShellPage): the device card, the run form and their state sequence.
// SPDX-License-Identifier: MIT
//
// The mirror source is `PDSHShellPage.swift`; the assertions below are the
// sections, rows, conditions and strings that file renders.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class ToolsPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val snapshot = ShellSnapshot(
        commands = listOf("rg", "jaq"),
        environment = "android-arm64",
        mounts = 2,
        limits = ShellLimits(
            timeoutMilliseconds = 30_000,
            maxOutputBytes = 1024,
            maxFiles = 12,
            maxFileBytes = 2048,
        ),
    )

    /** Scrolls the page's one list to a section that is below the fold. */
    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.SHELL_LIST).performScrollToNode(hasTestTag(tag))
    }

    private fun show(
        state: ToolsScreenState,
        onSelectCommand: (String) -> Unit = {},
        onWorkingDirectoryChange: (String) -> Unit = {},
        onArgumentsChange: (String) -> Unit = {},
        onRun: () -> Unit = {},
        onCancel: () -> Unit = {},
        onBack: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                ToolsPage(
                    state = state,
                    onSelectCommand = onSelectCommand,
                    onWorkingDirectoryChange = onWorkingDirectoryChange,
                    onArgumentsChange = onArgumentsChange,
                    onRun = onRun,
                    onCancel = onCancel,
                    onBack = onBack,
                )
            }
        }
    }

    // ---------------------------------------------------------------- sections

    @Test
    fun `the device card is always there with the three rows and the footnote`() {
        show(ToolsScreenState.from(snapshot))
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_DEVICE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHELL_STATUS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_STATUS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_NETWORK).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_NETWORK_UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_WORKSPACE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_WORKSPACE_FOLDERS.format(2)).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_READ_ONLY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHELL_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `no linked command replaces the form with the 还没接上命令 body`() {
        val state = ToolsScreenState.from(ShellSnapshot(commands = emptyList(), mounts = 0))
        assertTrue(state.isEmpty)
        assertEquals(UiStrings.SHELL_STATUS_UNLINKED, state.statusLabel)
        assertEquals(UiStrings.SHELL_WORKSPACE_UNSET, state.workspaceLabel)
        show(state)
        compose.onNodeWithTag(UiPageTags.SHELL_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_EMPTY_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_RUN).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_OUTPUT).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_LIMITS).assertDoesNotExist()
    }

    @Test
    fun `an unreported mount count is 未知, a measured zero is 未设置`() {
        assertEquals(
            UiStrings.UNKNOWN,
            ToolsScreenState.from(snapshot.copy(mounts = null)).workspaceLabel,
        )
        assertEquals(
            UiStrings.SHELL_WORKSPACE_UNSET,
            ToolsScreenState.from(snapshot.copy(mounts = 0)).workspaceLabel,
        )
    }

    @Test
    fun `the run section lists the linked commands and preselects the first`() {
        val state = ToolsScreenState.from(snapshot)
        assertEquals("rg", state.selectedCommand)
        show(state)
        for (tag in listOf(
            UiPageTags.SHELL_SECTION_RUN,
            UiPageTags.SHELL_COMMAND,
            UiPageTags.SHELL_COMMAND_ROW_PREFIX + "rg",
            UiPageTags.SHELL_COMMAND_ROW_PREFIX + "jaq",
            UiPageTags.SHELL_WORKING_DIR,
            UiPageTags.SHELL_ARGUMENTS,
            UiPageTags.SHELL_RUN,
        )) {
            compose.onNodeWithTag(tag).assertIsDisplayed()
        }
        compose.onNodeWithText("/dsh/workspace").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_ARGUMENTS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_ARGUMENTS_PLACEHOLDER).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHELL_NEEDS_APP).assertDoesNotExist()
    }

    @Test
    fun `a command row reports the choice the user made`() {
        var picked: String? = null
        show(ToolsScreenState.from(snapshot), onSelectCommand = { picked = it })
        compose.onNodeWithTag(UiPageTags.SHELL_COMMAND_ROW_PREFIX + "jaq").performClick()
        assertEquals("jaq", picked)
    }

    @Test
    fun `a command that needs the app is called out and cannot run`() {
        val state = ToolsScreenState.from(snapshot, ShellLocalState(command = "phone"))
        assertTrue(state.needsApp)
        assertFalse(state.canRun)
        show(state)
        compose.onNodeWithTag(UiPageTags.SHELL_NEEDS_APP).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_NEEDS_APP).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHELL_RUN).assertIsNotEnabled()
    }

    @Test
    fun `run is enabled for a linked command and reports the tap`() {
        var runs = 0
        show(ToolsScreenState.from(snapshot), onRun = { runs += 1 })
        compose.onNodeWithTag(UiPageTags.SHELL_RUN).assertIsEnabled()
        compose.onNodeWithTag(UiPageTags.SHELL_RUN).performClick()
        assertEquals(1, runs)
    }

    @Test
    fun `a run in flight offers 取消, disables 运行 and reports the cancel`() {
        var cancels = 0
        val state = ToolsScreenState.from(
            snapshot.copy(run = ShellRun(runningExecId = "exec-1")),
        )
        assertTrue(state.running)
        assertFalse(state.canRun)
        show(state, onCancel = { cancels += 1 })
        compose.onNodeWithTag(UiPageTags.SHELL_RUN).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.SHELL_CANCEL).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHELL_CANCEL).performClick()
        assertEquals(1, cancels)
    }

    @Test
    fun `the output section shows the empty sentence, then the run's text`() {
        show(ToolsScreenState.from(snapshot))
        scrollTo(UiPageTags.SHELL_SECTION_OUTPUT)
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_OUTPUT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_OUTPUT_EMPTY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHELL_ERROR).assertDoesNotExist()
    }

    @Test
    fun `the output section shows the run's error above its text`() {
        val state = ToolsScreenState.from(
            snapshot.copy(run = ShellRun(output = "12 tests passed", error = "退出码 1")),
        )
        show(state)
        scrollTo(UiPageTags.SHELL_ERROR)
        compose.onNodeWithTag(UiPageTags.SHELL_ERROR).assertIsDisplayed()
        compose.onNodeWithText("退出码 1").assertIsDisplayed()
        scrollTo(UiPageTags.SHELL_OUTPUT)
        compose.onNodeWithText("12 tests passed").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_OUTPUT_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `the limits section renders every bound, and 未知 for an unmeasured one`() {
        show(ToolsScreenState.from(snapshot))
        scrollTo(UiPageTags.SHELL_SECTION_LIMITS)
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_LIMITS).assertIsDisplayed()
        assertEquals(
            listOf(
                UiStrings.SHELL_LIMIT_TIMEOUT to UiStrings.SHELL_LIMIT_TIMEOUT_VALUE.format(30),
                UiStrings.SHELL_LIMIT_OUTPUT to "1 KB",
                UiStrings.SHELL_LIMIT_FILES to "12",
                UiStrings.SHELL_LIMIT_FILE to "2 KB",
            ),
            ToolsScreenState.from(snapshot).limits.map { it.label to it.value },
        )
        compose.onNodeWithTag(UiPageTags.SHELL_LIMIT_PREFIX + UiStrings.SHELL_LIMIT_TIMEOUT)
            .assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHELL_LIMIT_PREFIX + UiStrings.SHELL_LIMIT_OUTPUT)
            .assertIsDisplayed()
    }

    @Test
    fun `unmeasured limits are 未知, never zero`() {
        val state = ToolsScreenState.from(snapshot.copy(limits = null))
        assertEquals(4, state.limits.size)
        assertTrue(state.limits.all { it.value == UiStrings.UNKNOWN })
        show(state)
        scrollTo(UiPageTags.SHELL_SECTION_LIMITS)
        compose.onNodeWithTag(UiPageTags.SHELL_LIMIT_PREFIX + UiStrings.SHELL_LIMIT_TIMEOUT)
            .assertIsDisplayed()
    }

    // --------------------------------------------------------------- pure facts

    @Test
    fun `the selected command falls back to the first one like onAppear`() {
        assertEquals("rg", ToolsScreenState.from(snapshot).selectedCommand)
        assertEquals("jaq", ToolsScreenState.from(snapshot, ShellLocalState(command = "jaq")).selectedCommand)
        assertEquals("", ToolsScreenState.from(ShellSnapshot(commands = emptyList())).selectedCommand)
        assertEquals(
            UiStrings.UNKNOWN,
            ToolsScreenState.from(snapshot.copy(environment = null)).statusLabel,
        )
    }

    @Test
    fun `the run gate is running, empty or phone-ctx`() {
        assertTrue(ToolsScreenState.from(snapshot).canRun)
        assertFalse(
            ToolsScreenState.from(snapshot.copy(run = ShellRun(runningExecId = "e"))).canRun,
        )
        assertFalse(ToolsScreenState.from(snapshot, ShellLocalState(command = "ctx")).canRun)
        assertFalse(
            ToolsScreenState.from(ShellSnapshot(commands = emptyList(), limits = null)).canRun,
        )
    }

    @Test
    fun `a local event is the only thing the form changes`() {
        var local = ShellLocalState()
        local = local.apply(ShellUiEvent.SelectCommand("jaq"))
        local = local.apply(ShellUiEvent.SetWorkingDirectory("/dsh/home"))
        local = local.apply(ShellUiEvent.SetArguments("--help\nnotes.md"))
        assertEquals(
            ShellLocalState("jaq", "/dsh/home", "--help\nnotes.md"),
            local,
        )
        val before = ToolsScreenState.from(snapshot)
        val after = ToolsScreenState.from(snapshot, local)
        assertEquals(before.statusLabel, after.statusLabel)
        assertEquals(before.limits, after.limits)
        assertEquals(listOf("jaq", "/dsh/home", "--help\nnotes.md"), listOf(
            after.selectedCommand,
            after.workingDirectory,
            after.arguments,
        ))
    }

    @Test
    fun `the same snapshot and script always yield the same state`() {
        fun run(): List<ToolsScreenState> {
            var local = ShellLocalState()
            val out = mutableListOf<ToolsScreenState>()
            out += ToolsScreenState.from(snapshot, local)
            local = local.apply(ShellUiEvent.SelectCommand("jaq"))
            out += ToolsScreenState.from(snapshot, local)
            local = local.apply(ShellUiEvent.SetArguments("--help"))
            out += ToolsScreenState.from(snapshot, local)
            return out
        }
        assertEquals(run(), run())
        assertEquals(listOf("rg", "jaq", "jaq"), run().map { it.selectedCommand })
        assertEquals(listOf("", "", "--help"), run().map { it.arguments })
    }
}
