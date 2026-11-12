// One baseline per signature surface (6/6).
// SPDX-License-Identifier: MIT
//
// Each surface is rendered alone in a fixed frame, because that is where a
// spacing/radius/ink regression is attributable: a page diff cannot say which
// component moved. Frames are fixed dp sizes (not wrap-content) so the captured
// pixel grid never changes shape; content that grows instead of moving the frame
// shows up as a pixel diff, which is the signal we want.
package com.phonedsh.ui.screenshot

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.ApprovalCard
import com.phonedsh.ui.surface.BubbleRole
import com.phonedsh.ui.surface.ChatBubble
import com.phonedsh.ui.surface.Composer
import com.phonedsh.ui.surface.FailLoudBanner
import com.phonedsh.ui.surface.FailLoudKind
import com.phonedsh.ui.surface.ThinkingPill
import com.phonedsh.ui.surface.ToolDetailCard
import com.phonedsh.ui.surface.ToolRow
import com.phonedsh.ui.surface.ToolRowState
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SignatureSurfaceScreenshotTest : ScreenshotTestBase() {

    @Test
    fun bubbleSurface() {
        setCapturedContent(widthDp = 360, heightDp = 224) {
            Box(modifier = Modifier.fillMaxSize().padding(16.dp)) {
                ChatBubble(role = BubbleRole.USER, text = ScreenshotSamples.USER_TEXT)
            }
        }
        capture("surface-bubble")
    }

    @Test
    fun toolRowSurface() {
        setCapturedContent(widthDp = 360, heightDp = 360) {
            Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
                ToolRow(
                    title = ScreenshotSamples.TOOL_TITLE,
                    summary = ScreenshotSamples.TOOL_SUMMARY,
                    state = ToolRowState.OK,
                    expanded = true,
                    onToggle = {},
                    detail = {
                        ToolDetailCard(
                            banner = ScreenshotSamples.TOOL_BANNER,
                            body = ScreenshotSamples.TOOL_BODY,
                        )
                    },
                )
            }
        }
        capture("surface-tool-row")
    }

    @Test
    fun thinkingPillSurface() {
        setCapturedContent(widthDp = 360, heightDp = 120) {
            Box(modifier = Modifier.fillMaxSize().padding(16.dp)) {
                ThinkingPill(
                    summary = ScreenshotSamples.THINKING_SUMMARY,
                    streaming = false,
                    expanded = false,
                    onToggle = {},
                )
            }
        }
        capture("surface-thinking-pill")
    }

    @Test
    fun approvalCardSurface() {
        setCapturedContent(widthDp = 360, heightDp = 288) {
            ApprovalCard(
                title = UiStrings.APPROVAL_TITLE,
                subtitle = ScreenshotSamples.APPROVAL_SUBTITLE,
                primaryLabel = ScreenshotSamples.APPROVAL_PRIMARY,
                onPrimary = {},
                secondaryLabel = ScreenshotSamples.APPROVAL_SECONDARY,
                onSecondary = {},
            )
        }
        capture("surface-approval-card")
    }

    @Test
    fun composerSurface() {
        setCapturedContent(widthDp = 360, heightDp = 160) {
            Composer(
                text = ScreenshotSamples.COMPOSER_DRAFT,
                onTextChange = {},
                // The idle placeholder is the one the baseline pins: the three
                // running cases are separate states (ChatPage.swift).
                placeholder = com.phonedsh.ui.UiStrings.COMPOSER_PLACEHOLDER_IDLE,
                enabled = true,
                canSubmit = true,
                running = false,
                steer = false,
                onSend = {},
                onStop = {},
                stat = ScreenshotSamples.COMPOSER_STAT,
            )
        }
        capture("surface-composer")
    }

    @Test
    fun failLoudBannerSurface() {
        setCapturedContent(widthDp = 360, heightDp = 160) {
            FailLoudBanner(
                kind = FailLoudKind.TURN,
                message = ScreenshotSamples.BANNER_MESSAGE,
                onRetry = {},
                onDismiss = {},
            )
        }
        capture("surface-fail-loud-banner")
    }
}
