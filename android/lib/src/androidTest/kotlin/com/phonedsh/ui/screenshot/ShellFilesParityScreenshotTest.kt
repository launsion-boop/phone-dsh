// The Shell/Files lane's three states, captured with the shared parity harness.
// SPDX-License-Identifier: MIT
//
// This class owns no frame and no capture code: it derives from
// [ScreenshotTestBase] and is allowed only in the `ios-parity` profile
// (1206 x 2622 px @ 480 dpi = 402 x 874 pt @ 3x, the iOS baseline frame). The
// capture names come from [ParityState], so the comparison host finds the PNGs:
//
//   ios-shell.png              -> page-shell
//   ios-files.png              -> page-files
//   ios-workspace-folders.png  -> page-workspace-folders
//
// The states are the baselines' own states, not convenient ones:
//   * shell — no linked accelerator (状态 未链接或未配置), 2 hello mounts
//     (工作区 2 个文件夹), the 还没接上命令 card;
//   * files — an empty workspace (还没有文件 / 智能体做的文件会出现在这里。);
//   * workspace — no folders (还没有工作文件夹 + 添加工作文件夹).
//
// `ios-environment-home.png` is a springboard, not an app page: its registered
// capture name (`env-home`, owned by the L0 capture) is an `adb screencap`, which
// this Compose harness cannot produce.
package com.phonedsh.ui.screenshot

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.FilesLocalState
import com.phonedsh.ui.page.FilesPage
import com.phonedsh.ui.page.FilesScreenState
import com.phonedsh.ui.page.FilesSource
import com.phonedsh.ui.page.PDSHShellPage
import com.phonedsh.ui.page.ShellLocalState
import com.phonedsh.ui.page.ShellSnapshot
import com.phonedsh.ui.page.ToolsScreenState
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.page.WorkspaceFoldersLocalState
import com.phonedsh.ui.page.WorkspaceFoldersPage
import com.phonedsh.ui.page.WorkspaceFoldersScreenState
import com.phonedsh.ui.page.WorkspaceFoldersSnapshot
import androidx.compose.ui.test.onNodeWithTag
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ShellFilesParityScreenshotTest : ScreenshotTestBase() {

    /** The parity frame is the whole point of this suite. */
    override val allowedProfiles: Set<ScreenshotProfile> = setOf(ScreenshotProfile.IOS_PARITY)

    /**
     * Publishes the registry next to the PNGs, so a single-class run still leaves
     * the host a complete mapping to verify (the same contract [ParityScreenshotTest]
     * writes for the whole suite).
     */
    @Before
    fun publishRegistry() {
        ScreenshotStore.writeRegistry(
            activity = compose.activity,
            profile = profile,
            lines = captureRegistryLines(),
        )
    }

    /**
     * `ios-shell.png`: the accelerator registry with no linked commands.
     *
     * `mounts = 2` is the baseline's own measured value (its 工作区 row reads
     * 「2 个文件夹」 while 状态 stays 未链接或未配置), so the sample keeps the two
     * facts apart exactly like the screenshot.
     */
    @Test
    fun pageShell() {
        setCapturedContent {
            PDSHShellPage(
                state = ToolsScreenState.from(
                    ShellSnapshot(mounts = 2),
                    ShellLocalState(),
                ),
                onSelectCommand = {},
                onWorkingDirectoryChange = {},
                onArgumentsChange = {},
                onRun = {},
                onCancel = {},
                onBack = {},
            )
        }
        compose.onNodeWithTag(UiPageTags.SHELL_ROOT).assertIsDisplayed()
        compose.onNodeWithText("这台手机").assertIsDisplayed()
        compose.onNodeWithText("未链接或未配置").assertIsDisplayed()
        compose.onNodeWithText("2 个文件夹").assertIsDisplayed()
        compose.onNodeWithText("还没接上命令").assertIsDisplayed()
        capture(ParityState.PAGE_SHELL.androidName)
    }

    /** `ios-files.png`: an empty workspace (the two-line card, not a section). */
    @Test
    fun pageFiles() {
        setCapturedContent {
            FilesPage(
                state = FilesScreenState.from(
                    FilesSource(files = emptyList()),
                    FilesLocalState(),
                ),
                onOpenFolder = {},
                onOpenFile = {},
                onQueryChange = {},
                onNavigateUp = {},
                onBack = {},
            )
        }
        compose.onNodeWithText("手机工作区").assertIsDisplayed()
        compose.onNodeWithText("搜索文件").assertIsDisplayed()
        compose.onNodeWithText("还没有文件").assertIsDisplayed()
        capture(ParityState.PAGE_FILES.androidName)
    }

    /** `ios-workspace-folders.png`: the empty list with the accent CTA. */
    @Test
    fun pageWorkspaceFolders() {
        setCapturedContent {
            WorkspaceFoldersPage(
                state = WorkspaceFoldersScreenState.from(
                    WorkspaceFoldersSnapshot(folders = emptyList(), writable = FactState.YES),
                    WorkspaceFoldersLocalState(),
                ),
                onBack = {},
                onOpenFiles = {},
                onSwitch = {},
                onBeginCreate = {},
                onDraftChange = {},
                onCancelCreate = {},
                onCreate = {},
                onDeleteRequest = {},
                onDeleteConfirm = {},
                onDeleteCancel = {},
            )
        }
        compose.onNodeWithText("工作文件夹").assertIsDisplayed()
        compose.onNodeWithText("还没有工作文件夹").assertIsDisplayed()
        compose.onNodeWithText("添加工作文件夹").assertIsDisplayed()
        capture(ParityState.PAGE_WORKSPACE_FOLDERS.androidName)
    }
}
