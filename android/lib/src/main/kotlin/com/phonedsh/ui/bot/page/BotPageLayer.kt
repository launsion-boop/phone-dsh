// The Bot tab's page layer: the chat page plus its drawer, info and appearance
// overlays.
// SPDX-License-Identifier: MIT
//
// K5a's `BotChatPage` only names the two open gestures (`onOpenDrawer`,
// `onOpenInfo`); K5b's drawer/info/appearance surfaces are separate composables.
// This file is the missing connection between them, kept inside `:lib` so a host
// that passes neither override still gets the three surfaces. A host that does
// pass `onOpenBotDrawer` / `onOpenBotInfo` keeps the pre-K5c behaviour exactly:
// its callback is invoked and no library overlay is opened.
package com.phonedsh.ui.bot.page

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.ui.bot.page.appearance.BotAppearancePicker
import com.phonedsh.ui.bot.page.drawer.BotDrawer
import com.phonedsh.ui.bot.page.info.BotInfoCopy
import com.phonedsh.ui.bot.page.info.BotInfoPage
import com.phonedsh.ui.bot.state.BotAppearanceIntent
import com.phonedsh.ui.bot.state.BotDrawerIntent
import com.phonedsh.ui.bot.state.BotInfoIntent
import com.phonedsh.ui.bot.state.BotInfoModelState
import com.phonedsh.ui.bot.state.BotRosterEntry
import com.phonedsh.ui.bot.state.BotUiContext
import com.phonedsh.ui.page.PageFrame

/** Test ids for the surfaces this layer owns rather than a K5b page. */
public object BotPageLayerTags {
    /** The standalone appearance editor opened from the drawer's 外观 action. */
    public const val APPEARANCE: String = "bot.appearance.overlay"
}

/**
 * Which of the Bot tab's surfaces is above the chat page.
 *
 * The values are exclusive, matching the baseline's one-drawer/one-page model:
 * opening one surface closes the previous one instead of stacking them.
 */
private enum class BotPageOverlay { NONE, DRAWER, INFO, APPEARANCE }

/**
 * The Bot tab's one composed page: [content] (the chat page) with the Bot
 * drawer, the Bot info page and the appearance editor layered over it.
 *
 * Precedence: [hostOnOpenDrawer] and [hostOnOpenInfo] are the pre-K5c host
 * overrides. A non-null override is invoked and no internal overlay opens; a
 * null one opens the corresponding library surface. The drawer's
 * [BotDrawerIntent.Close] closes it, its [BotDrawerIntent.Appearance] closes the
 * drawer and opens the appearance editor, and every other drawer intent is
 * forwarded unchanged to [onBotDrawerIntent]. The info page's back action and
 * the appearance editor's back action return to the chat page.
 *
 * The overlays never survive the Bot page: when [active] turns false (the Bot
 * tab was left or its driver went away) the current overlay is reset. A host
 * that keeps this layer composed across tabs therefore cannot leave a stale
 * drawer over another tab.
 *
 * @param active whether the Bot tab is selected and its driver is live.
 * @param botRoster the roster the drawer lists.
 * @param botContext the selected Bot (the drawer's selection).
 * @param botInfoState the info page's load result.
 * @param botAppearance the selected Bot's appearance, used by the info page and
 *   the appearance editor.
 * @param botIsMainBot whether the selected Bot is the main Bot (crown).
 * @param botDescription the info page's profile description.
 * @param fish the host's fish renderer, shared by every surface.
 * @param onBotDrawerIntent a drawer intent other than close/appearance.
 * @param onBotInfoIntent one info-page write.
 * @param onBotAppearanceIntent one appearance selection.
 * @param modifier the layer's modifier.
 * @param hostOnOpenDrawer the host's drawer override; non-null wins.
 * @param hostOnOpenInfo the host's info override; non-null wins.
 * @param content the chat page, receiving the two open gestures it must wire to
 *   its header controls.
 */
@Composable
public fun BotPageLayer(
    active: Boolean,
    botRoster: List<BotRosterEntry>,
    botContext: BotUiContext,
    botInfoState: BotInfoModelState,
    botAppearance: BotFishAppearance,
    botIsMainBot: Boolean,
    botDescription: String,
    fish: BotFishSlot,
    onBotDrawerIntent: (BotDrawerIntent) -> Unit,
    onBotInfoIntent: (BotInfoIntent) -> Unit,
    onBotAppearanceIntent: (BotAppearanceIntent) -> Unit,
    modifier: Modifier = Modifier,
    hostOnOpenDrawer: (() -> Unit)? = null,
    hostOnOpenInfo: (() -> Unit)? = null,
    content: @Composable (
        onOpenDrawer: () -> Unit,
        onOpenInfo: () -> Unit,
    ) -> Unit,
) {
    var overlay by remember { mutableStateOf(BotPageOverlay.NONE) }

    // The Bot tab owns these surfaces: leaving the tab or losing the driver
    // closes whatever was open instead of leaving it over the next route.
    LaunchedEffect(active) {
        if (!active) overlay = BotPageOverlay.NONE
    }

    val openDrawer: () -> Unit = {
        if (active) {
            val host = hostOnOpenDrawer
            if (host != null) host() else overlay = BotPageOverlay.DRAWER
        }
    }
    val openInfo: () -> Unit = {
        if (active) {
            val host = hostOnOpenInfo
            if (host != null) host() else overlay = BotPageOverlay.INFO
        }
    }

    Box(modifier.fillMaxSize()) {
        content(openDrawer, openInfo)

        when (overlay) {
            BotPageOverlay.NONE -> Unit
            BotPageOverlay.DRAWER -> BotDrawer(
                entries = botRoster,
                selection = botContext.botID,
                onIntent = { intent ->
                    when (intent) {
                        BotDrawerIntent.Close -> overlay = BotPageOverlay.NONE
                        is BotDrawerIntent.Appearance -> overlay = BotPageOverlay.APPEARANCE
                        else -> onBotDrawerIntent(intent)
                    }
                },
                fish = fish,
                isOpen = true,
            )
            BotPageOverlay.INFO -> BotInfoPage(
                state = botInfoState,
                appearance = botAppearance,
                isMainBot = botIsMainBot,
                onIntent = onBotInfoIntent,
                fish = fish,
                onAppearanceIntent = onBotAppearanceIntent,
                botDescription = botDescription,
                onBack = { overlay = BotPageOverlay.NONE },
            )
            BotPageOverlay.APPEARANCE -> AppearanceOverlay(
                appearance = botAppearance,
                isMainBot = botIsMainBot,
                fish = fish,
                onIntent = onBotAppearanceIntent,
                onClose = { overlay = BotPageOverlay.NONE },
            )
        }
    }
}

/**
 * The standalone appearance editor: the drawer's 外观 action opens this instead
 * of navigating away from the Bot page. It keeps the info page's picker and
 * writes through the same [BotAppearanceIntent] vocabulary.
 */
@Composable
private fun AppearanceOverlay(
    appearance: BotFishAppearance,
    isMainBot: Boolean,
    fish: BotFishSlot,
    onIntent: (BotAppearanceIntent) -> Unit,
    onClose: () -> Unit,
) {
    PageFrame(
        title = BotInfoCopy.APPEARANCE_SECTION,
        onBack = onClose,
        rootTag = BotPageLayerTags.APPEARANCE,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
        ) {
            BotAppearancePicker(
                appearance = appearance,
                onIntent = onIntent,
                fish = fish,
                isMainBot = isMainBot,
            )
        }
    }
}
