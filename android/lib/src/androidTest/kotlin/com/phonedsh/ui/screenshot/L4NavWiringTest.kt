// Route wiring for the Shell/Files lane, asserted on a device.
// SPDX-License-Identifier: MIT
//
// A page that compiles is not a page that is reachable. These tests mount the real
// [PdshNavHost] — not the page composables directly — and assert the three edges
// this lane owns:
//
//   1. `设置 → 命令` resolves to `PdshRoute.Tools`, and that route renders the new
//      inset-grouped `PDSHShellPage` body (the 还没接上命令 card);
//   2. `PdshRoute.Files` resolves to `FilesPage` (the 手机工作区 header);
//   3. a 工作文件夹 row pushes `PdshRoute.Files(folderId)` instead of handing an
//      unstoppable host action to the composition root.
//
// The assertions are semantics, not pixels; the pixels are pinned separately by
// [ShellFilesParityScreenshotTest].
package com.phonedsh.ui.screenshot

import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.page.WorkspaceFolder
import com.phonedsh.ui.page.WorkspaceFoldersSnapshot
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class L4NavWiringTest {

    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun commandsRouteRendersTheShellPage() {
        mount(nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Tools)))
        compose.onNodeWithText(UiStrings.TOOLS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_DEVICE_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_STATUS_UNLINKED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHELL_EMPTY_HINT).assertIsDisplayed()
    }

    @Test
    fun filesRouteRendersTheFilesPage() {
        mount(nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Files("w1"))))
        compose.onNodeWithText(UiStrings.FILES_WORKSPACE).assertIsDisplayed()
        // The host reports no listing yet, so the page must say it is waiting and
        // must not claim the workspace is empty (`FilesPage.swift:102`).
        compose.onNodeWithText(UiStrings.WAITING_ENGINE).assertIsDisplayed()
    }

    @Test
    fun aWorkspaceRowPushesTheFilesRoute() {
        var pushed: PdshRoute? = null
        mount(
            nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.WorkspaceFolders)),
            facts = PdshNavFacts(
                workspaceFolders = WorkspaceFoldersSnapshot(
                    folders = listOf(
                        WorkspaceFolder(id = "w1", name = "工作区 A", sessionCount = 2),
                    ),
                    writable = FactState.YES,
                ),
            ),
            onNavigate = { route -> pushed = route },
        )
        compose.onNodeWithTag(UiPageTags.WORKSPACE_ROW).performClick()
        compose.runOnIdle {
            assertEquals(PdshRoute.Files("w1"), pushed)
        }
    }

    // ------------------------------------------------------------------ harness

    private fun mount(
        nav: PdshNavState,
        facts: PdshNavFacts = PdshNavFacts(),
        onNavigate: (PdshRoute) -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = nav,
                    facts = facts,
                    onNavigate = onNavigate,
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = {
                        BasicText(text = "home")
                    },
                    webSurface = {},
                )
            }
        }
        compose.waitForIdle()
    }
}
