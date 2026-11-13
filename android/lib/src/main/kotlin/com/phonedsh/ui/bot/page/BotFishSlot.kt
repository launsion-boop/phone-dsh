// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance

/**
 * How a Bot page draws a fish avatar (header, empty state, roster row, info header).
 *
 * The pages take this slot instead of calling the renderer directly, so the page
 * lanes and the BotFish renderer lane (`com.phonedsh.ui.bot.fish`) build
 * independently. The host passes `BotFishView`; tests pass a tagged box.
 * `paused` is true when the Bot tab is not the active page (iOS `botFishPaused`).
 */
public typealias BotFishSlot = @Composable (
    lifecycle: BotFishLifecycle,
    appearance: BotFishAppearance,
    crowned: Boolean,
    size: Dp,
    paused: Boolean,
    modifier: Modifier,
) -> Unit
