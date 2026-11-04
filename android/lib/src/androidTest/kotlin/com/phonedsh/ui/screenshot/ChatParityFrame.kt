// The iOS page content box for the Chat parity captures.
// SPDX-License-Identifier: MIT
//
// Why this exists: the iOS baselines are *device* screenshots (1206x2622 px at
// 402x874 pt), so the app's page is laid out inside the iOS safe area — 62 pt of
// status bar above `ios-chat-*.png`'s header (its 50 pt bar occupies y 62..112)
// and 42 pt below the composer (its bottom edge is y 831.7, not 874). The Compose
// harness hides the Android system bars (a capture condition, see
// [ScreenshotTestBase]), so `statusBarsPadding()` / `navigationBarsPadding()`
// inside the pages collapse to 0 and the Android page is laid out in the full
// 402x874 frame instead of the 402x770 content box: the header sits 62 pt higher,
// the bottom-anchored composer 42 pt lower, and every row in between is offset.
//
// That is a *whole-block* offset, not a page bug, and the sheets put both panels
// at the same absolute y — so the capture reserves the same band here, exactly
// like the Settings lane's [ParityScreenshotTest.parityFrame]. It is not a page
// inset: on a device that shows the bars the page already gets the band from the
// platform, and a page-level inset would double it.
//
// The numbers are measured, not nominal:
//   * top 62: the iOS header's 50 pt bar is centred on the title ink
//     y 77.7..96 pt (`ios-chat-assistant.png` band 233..288 px) → 62..112.
//   * bottom 42: the composer card's bottom border is y 2495 px = 831.7 pt on
//     every `ios-chat-*.png`; 874 - 831.7 = 42.3.
package com.phonedsh.ui.screenshot

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** The iOS status-bar band above the app's page, in pt (`ios-chat-*.png`). */
internal const val IOS_CHAT_SAFE_AREA_TOP_PT: Int = 62

/** The iOS home-indicator band below the composer, in pt (`ios-chat-*.png`). */
internal const val IOS_CHAT_SAFE_AREA_BOTTOM_PT: Int = 42

/**
 * Lays [content] inside the iOS page content box (402 x 770 pt) of the same
 * absolute frame as the iOS baseline.
 *
 * @param content the chat page, drawn in the iOS content box.
 */
@Composable
internal fun ChatParityFrame(content: @Composable () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(
                top = IOS_CHAT_SAFE_AREA_TOP_PT.dp,
                bottom = IOS_CHAT_SAFE_AREA_BOTTOM_PT.dp,
            ),
    ) {
        content()
    }
}
