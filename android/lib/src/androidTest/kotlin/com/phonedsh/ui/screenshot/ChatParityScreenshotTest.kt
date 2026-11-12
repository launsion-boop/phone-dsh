// The Chat family's parity captures, in L0's shared 402 x 874 @3 harness.
// SPDX-License-Identifier: MIT
//
// Scope: this class captures only the Chat states that `ParityState` still marks
// `PENDING` and that no other suite owns — `page-chat-assistant`,
// `page-chat-official`, `page-chat-queued`, `page-chat-permission` and
// `surface-code-block`. The four `CAPTURED` chat states (`-default`, `-failed`,
// `-long`, `-draft`) are captured by `ParityScreenshotTest`; re-capturing them
// here would write the same file twice.
//
// The capture names are read off `ParityState` ([androidName]), never typed here,
// so a rename in the registry renames the PNG and the host's registry check keeps
// working. The frame, the metrics receipt and the output directory come from
// [ScreenshotTestBase] / [ScreenshotProfile.IOS_PARITY] / [ScreenshotStore].
//
// What a parity capture proves: the page composition in the iOS frame. It never
// proves cross-platform glyph raster equality (Minikin/HarfBuzz vs CoreText).
//
// The page is drawn inside [ChatParityFrame]: the iOS baseline is a device
// screenshot whose page lives in the 62/42 pt safe area, while this harness hides
// the Android bars, so the band has to come from the capture frame (see the KDoc
// there). Without it the whole page is offset by 62 pt against the panel it is
// compared to, which is a capture artefact and not a layout difference.
package com.phonedsh.ui.screenshot

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiMetrics
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.ChatPage
import com.phonedsh.ui.surface.ApprovalCard
import com.phonedsh.ui.surface.CodeBlock
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ChatParityScreenshotTest : ScreenshotTestBase() {

    /** These captures only mean anything in the iOS frame. */
    override val allowedProfiles = setOf(ScreenshotProfile.IOS_PARITY)

    // ------------------------------------------------------------------ states

    @Test
    fun pageChatAssistant() {
        val state = ParityState.PAGE_CHAT_ASSISTANT
        setCapturedContent { ChatParityFrame { chatPage(ChatParitySamples.chatAssistant()) } }
        capture(state.androidName)
    }

    @Test
    fun pageChatOfficial() {
        val state = ParityState.PAGE_CHAT_OFFICIAL
        setCapturedContent { ChatParityFrame { chatPage(ChatParitySamples.chatOfficial()) } }
        capture(state.androidName)
    }

    @Test
    fun pageChatQueued() {
        val state = ParityState.PAGE_CHAT_QUEUED
        setCapturedContent { ChatParityFrame { chatPage(ChatParitySamples.chatQueued()) } }
        capture(state.androidName)
    }

    /**
     * `ios-chat-permission.png` is **not a page**: `NativeShell.swift:848-861`
     * renders `-uiPreview chat.permission` as two `PermissionCardView`s inside a
     * `VStack { Color.white; card; card; Color.white }` — no header, no composer,
     * the two cards centred in the safe area. The full `ChatPage` cannot be laid
     * beside that shot (its header and dock are 100% of the iOS panel's missing
     * chrome), so this capture photographs the subject the baseline photographs:
     * the card pair, at the same width and vertical centre. The page-level
     * rendering of the same state stays covered by the page's own tests.
     */
    @Test
    fun pageChatPermission() {
        val state = ParityState.PAGE_CHAT_PERMISSION
        setCapturedContent { ChatParityFrame { permissionCardPair() } }
        capture(state.androidName)
    }

    /** The two pending cards, centred, exactly as the iOS `chat.permission` preview draws them. */
    @Composable
    private fun permissionCardPair() {
        val pending = ChatParitySamples.chatPermission().pending
        val asks = listOfNotNull(pending.primary) + pending.folded
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(modifier = Modifier.fillMaxWidth()) {
                asks.forEach { ask ->
                    ApprovalCard(
                        title = ask.title,
                        subtitle = ask.subtitle,
                        primaryLabel = UiStrings.ALLOW_ONCE,
                        onPrimary = {},
                        secondaryLabel = UiStrings.DENY,
                        onSecondary = {},
                    )
                }
            }
        }
    }

    /**
     * `ios-code-block.png` is a component swatch, not a page: the iOS shot has no
     * header and no composer, only the card at y = 104 pt in the 402 pt frame.
     *
     * That 104 is the preview route's own layout, not the component's: iOS is
     * `NativeShell.swift:864-868` — `ScrollView { DSSCodeBlock(…).padding(.horizontal,
     * 16).padding(.top, 40) }` — inside a frame whose status bar is 62 pt, plus
     * `DSSCodeBlock`'s own `.padding(.vertical, 2)` (`Components.swift:224`):
     * 62 + 40 + 2 = 104. The Android harness hides the system bars, so the same
     * card origin has to be typed into the sample; the component must not grow a
     * 104 pt top margin for a page that does not have one. Card body and chrome
     * are compared from that common origin.
     */
    @Test
    fun surfaceCodeBlock() {
        val state = ParityState.SURFACE_CODE_BLOCK
        setCapturedContent(
            widthDp = UiMetrics.BASELINE_WIDTH_PT,
            heightDp = UiMetrics.BASELINE_HEIGHT_PT,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        start = PAGE_MARGIN_PT.dp,
                        // 102 so the component's own 2 pt outer inset lands the
                        // card surface at 104 — the iOS frame coordinate.
                        top = CODE_SWATCH_TOP_PT.dp,
                        end = PAGE_MARGIN_PT.dp,
                    )
                    .testTag(CODE_SWATCH_TAG),
            ) {
                CodeBlock(
                    language = ChatParitySamples.CODE_BLOCK_LANGUAGE,
                    body = ChatParitySamples.CODE_BLOCK_BODY,
                )
            }
        }
        capture(state.androidName)
    }

    // ----------------------------------------------------------------- routing

    /**
     * The routing receipt: the page is rendered by [PdshNavHost] from
     * [PdshRoute.Chat], i.e. the same path the app takes, not a direct `ChatPage`
     * call. If the route fell back to `Unit` in the router's `when`, this frame
     * would be blank and the capture would be the only evidence needed.
     *
     * The name is deliberately outside `ParityState`: there is no iOS counterpart
     * for "the router resolved the route", so it is not a parity baseline.
     */
    @Test
    fun chatRouteThroughNavHost() {
        setCapturedContent {
            PdshNavHost(
                nav = PdshNavState(stack = listOf(PdshRoute.Home, PdshRoute.Chat)),
                facts = PdshNavFacts(),
                onNavigate = {},
                onBack = {},
                onHome = {},
                onHostAction = {},
                home = {},
                webSurface = {},
            )
        }
        capture(ROUTE_CAPTURE_NAME)
    }

    @Composable
    private fun chatPage(state: com.phonedsh.ui.state.ChatScreenState) {
        ChatPage(
            state = state,
            onDraftChange = {},
            onSend = {},
            onStop = {},
            onToggleRow = {},
            onApprove = {},
            onDeny = {},
            onDismissBanner = {},
            onRetry = {},
            onOpenSessions = {},
            title = ChatParitySamples.TITLE,
        )
    }

    private companion object {
        /** The page margin both baselines use for the transcript column (16 pt). */
        val PAGE_MARGIN_PT: Int = UiMetrics.COMPOSER_OUTER_MARGIN_PT

        /** The swatch frame's tag (the capture reads it back). */
        const val CODE_SWATCH_TAG: String = "pdsh.chat-parity.code-swatch"

        /**
         * `ios-code-block.png` card origin: 62 pt status bar + 40 pt preview top
         * padding, minus the 2 pt outer inset [CodeBlock] applies itself.
         */
        const val CODE_SWATCH_TOP_PT: Int = 102

        /** The routing receipt's PNG name; not a parity baseline. */
        const val ROUTE_CAPTURE_NAME: String = "page-chat-route"
    }
}
