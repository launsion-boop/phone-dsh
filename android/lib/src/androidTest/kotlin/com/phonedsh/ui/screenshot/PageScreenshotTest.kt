// One baseline per assembled page (3 pages).
// SPDX-License-Identifier: MIT
//
// The surface baselines prove a component did not move; these prove the page
// composition (header + list + slot + dock) did not move. The frame is the whole
// 1080x2400 display at the fixed conditions, so both the top and the bottom of
// the page are covered.
//
// Scope note: `ChatPage`, `SessionsPage` and `SettingsPage` exist today. The five
// new pages another lane is landing (and the app navigation that hosts them) are
// deliberately NOT captured here: a baseline taken mid-flight would freeze a
// half-written screen. They get baselines after they land.
package com.phonedsh.ui.screenshot

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.page.ChatPage
import com.phonedsh.ui.page.SessionsPage
import com.phonedsh.ui.page.SettingsPage
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PageScreenshotTest : ScreenshotTestBase() {

    @Test
    fun chatPage() {
        setCapturedContent {
            ChatPage(
                state = ScreenshotSamples.chatState(),
                onDraftChange = {},
                onSend = {},
                onStop = {},
                onToggleRow = {},
                onApprove = {},
                onDeny = {},
                onDismissBanner = {},
                onRetry = {},
                onOpenSessions = {},
                title = "像素基线复盘",
            )
        }
        // The two chat baselines must not be able to pass while rendering the same
        // frame: this one is the no-banner state, so the banner node has to be absent.
        compose.onNodeWithTag(UiTags.FAIL_LOUD_BANNER).assertDoesNotExist()
        capture("page-chat")
    }

    @Test
    fun chatPageWithFailLoudBanner() {
        setCapturedContent {
            ChatPage(
                state = ScreenshotSamples.chatStateWithBanner(),
                onDraftChange = {},
                onSend = {},
                onStop = {},
                onToggleRow = {},
                onApprove = {},
                onDeny = {},
                onDismissBanner = {},
                onRetry = {},
                onOpenSessions = {},
                title = "像素基线复盘",
            )
        }
        // Guard against the false green this baseline shipped with: the state must
        // actually put the fail-loud banner on screen, otherwise the capture is just
        // `page-chat` under another name.
        compose.onNodeWithTag(UiTags.FAIL_LOUD_BANNER).assertIsDisplayed()
        capture("page-chat-banner")
    }

    @Test
    fun sessionsPage() {
        setCapturedContent {
            SessionsPage(
                state = ScreenshotSamples.sessionsState(),
                onSelect = {},
                onQueryChange = {},
                onRenameStart = {},
                onRenameDraftChange = {},
                onRenameCommit = {},
                onRenameCancel = {},
                onDeleteRequest = {},
                onDeleteConfirm = {},
                onDeleteCancel = {},
                onNewSession = {},
                onBack = {},
            )
        }
        capture("page-sessions")
    }

    @Test
    fun settingsPage() {
        setCapturedContent {
            SettingsPage(
                state = ScreenshotSamples.settingsState(),
                onNavigate = {},
                onToggleBackgroundKeepAlive = {},
                onSelectBusyEnterMode = {},
                onBack = {},
            )
        }
        capture("page-settings")
    }
}
