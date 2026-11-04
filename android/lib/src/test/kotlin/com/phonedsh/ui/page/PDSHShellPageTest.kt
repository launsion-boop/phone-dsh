// Commands (`PDSHShellPage`): the section captions, the picker menu and the run form.
// SPDX-License-Identifier: MIT
//
// The mirror source is `PDSHShellPage.swift`; the app draws this page
// (`PdshNavHost`'s 命令 route), while `ToolsPageTest` keeps the older `ToolsPage`
// view that renders the same reducer. The assertions below are the parts the
// page-structure contract names: the four section captions and the `命令` picker.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PDSHShellPageTest {
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

    private fun show(
        state: ToolsScreenState,
        onSelectCommand: (String) -> Unit = {},
        onRunArgv: ((List<String>, String) -> Unit)? = null,
        onRun: () -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme {
                PDSHShellPage(
                    state = state,
                    onSelectCommand = onSelectCommand,
                    onWorkingDirectoryChange = {},
                    onArgumentsChange = {},
                    onRun = onRun,
                    onCancel = {},
                    onBack = {},
                    onRunArgv = onRunArgv,
                )
            }
        }
    }

    @Test
    fun `the four section captions are all rendered`() {
        // PDSHShellPage.swift: `Section("这台手机")`, `Section("运行命令")`,
        // `Section("输出")`, `Section("限制")`.
        show(ToolsScreenState.from(snapshot))
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_DEVICE).assertExists()
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_RUN).assertExists()
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_OUTPUT).assertExists()
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_LIMITS).assertExists()
    }

    @Test
    fun `the command row is the picker and it opens the choices`() {
        // PDSHShellPage.swift:40 `Picker("命令", selection: $command)` — a menu.
        var selected: String? = null
        show(ToolsScreenState.from(snapshot), onSelectCommand = { selected = it })
        // The closed row shows the label and the current choice (the first command).
        compose.onNodeWithTag(UiPageTags.SHELL_COMMAND).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHELL_COMMAND).performClick()
        compose.onNodeWithText("jaq").assertIsDisplayed()
        compose.onNodeWithText("jaq").performClick()
        assertEquals("jaq", selected)
    }

    @Test
    fun `no linked command keeps the device card and drops the run form`() {
        show(ToolsScreenState.from(ShellSnapshot(mounts = 2)))
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_DEVICE).assertExists()
        compose.onNodeWithTag(UiPageTags.SHELL_EMPTY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHELL_SECTION_RUN).assertDoesNotExist()
    }

    @Test
    fun `run callback receives argv only from the selected capability`() {
        var argv: List<String>? = null
        var workingDirectory: String? = null
        val state = ToolsScreenState.from(
            snapshot,
            ShellLocalState(
                command = "jaq",
                workingDirectory = "/dsh/workspace/src",
                arguments = "--filter\n\nname == 'Ada'\r\n",
            ),
        )
        show(state, onRunArgv = { values, cwd -> argv = values; workingDirectory = cwd })
        compose.onNodeWithTag(UiPageTags.SHELL_RUN).performClick()
        assertEquals(listOf("jaq", "--filter", "name == 'Ada'"), argv)
        assertEquals("/dsh/workspace/src", workingDirectory)
    }

    @Test
    fun `in-flight command uses the source stop-running label`() {
        show(ToolsScreenState.from(snapshot.copy(run = ShellRun(runningExecId = "exec-1"))))

        compose.onNodeWithTag(UiPageTags.SHELL_CANCEL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_STOP_RUNNING).assertIsDisplayed()
        compose.onAllNodesWithText(UiStrings.CANCEL).assertCountEquals(0)
    }

    @Test
    fun `real result and error remain visible from the host snapshot`() {
        val reported = ToolsScreenState.from(
            snapshot.copy(run = ShellRun(output = "record one", error = "exit 2")),
        )
        compose.setContent {
            PdshTheme { ShellOutputSection(reported) }
        }
        compose.onNodeWithTag(UiPageTags.SHELL_ERROR).assertExists()
        compose.onNodeWithText("exit 2").assertExists()
        compose.onNodeWithTag(UiPageTags.SHELL_OUTPUT).assertExists()
        compose.onNodeWithText("record one").assertExists()
    }
}
