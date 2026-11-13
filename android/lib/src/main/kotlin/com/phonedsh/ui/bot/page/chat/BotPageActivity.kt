// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import androidx.compose.runtime.staticCompositionLocalOf

/**
 * True while the Bot page is the selected tab and the app scene is active
 * (`BotPageActivity.swift:5-21`, `NativeShell.swift:379-382`). The page uses it
 * to freeze the activity-line animation; the runtime never reads it.
 */
public val LocalBotPageActive: androidx.compose.runtime.ProvidableCompositionLocal<Boolean> =
    staticCompositionLocalOf { true }
