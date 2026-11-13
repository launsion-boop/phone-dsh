// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotRoster
import com.phonedsh.bot.profile.BotRosterRules
import com.phonedsh.ui.bot.driver.BotChatDriver
import com.phonedsh.ui.bot.state.BotRosterEntry
import com.phonedsh.ui.bot.state.BotRosterOrdering
import com.phonedsh.ui.bot.state.BotRosterRuntimeState
import com.phonedsh.ui.bot.state.BotUiContext

/**
 * The App's roster snapshot for the Bot tab and drawer.
 *
 * The pure mapping keeps the UI library's rules: a repaired main pointer wins,
 * the main row is first, hidden rows stay in the list, and the appearance is
 * resolved from the profile (explicit fields first, then the deterministic
 * seed). An empty profile set produces the one honest main row the App knows;
 * it never invents a second Bot.
 */
object AppBotRoster {
    const val DEFAULT_BOT_ID: String = "main"
    const val DEFAULT_BOT_NAME: String = "Bot"

    fun profile(
        id: String = DEFAULT_BOT_ID,
        name: String = DEFAULT_BOT_NAME,
        description: String = "",
    ): BotProfile = BotProfile(id = id, name = name, description = description)

    fun roster(
        profiles: List<BotProfile> = listOf(profile()),
        storedMainBotId: String? = null,
    ): BotRoster {
        val bots = profiles.ifEmpty { listOf(profile()) }
        val main = BotRosterRules.repairMainBotID(bots.map { it.id }, storedMainBotId)
        return BotRoster(bots = bots, mainBotID = main)
    }

    fun entries(
        roster: BotRoster,
        runtime: Map<String, BotRosterRuntimeState> = emptyMap(),
    ): List<BotRosterEntry> = BotRosterOrdering.ordered(
        roster.bots.map { profile ->
            BotRosterEntry(
                id = profile.id,
                name = profile.name,
                description = profile.description,
                appearance = BotFishAppearance.resolve(profile),
                isMainBot = profile.id == roster.mainBotID,
                isHidden = profile.hiddenByUser,
                unreadCount = profile.unreadCount,
                lastMessageAt = profile.lastMessageAt,
                runtime = runtime[profile.id] ?: BotRosterRuntimeState(),
            )
        },
    )

    fun context(roster: BotRoster, selectedBotId: String? = null): BotUiContext {
        val selected = selectedBotId?.takeIf { id -> roster.bots.any { it.id == id } }
            ?: roster.mainBotID
            ?: roster.bots.firstOrNull()?.id
            ?: DEFAULT_BOT_ID
        val profile = roster.bots.firstOrNull { it.id == selected }
            ?: profile(selected)
        return BotUiContext(botID = profile.id, botName = profile.name)
    }
}

/**
 * The one App-owned Bot seam passed to `PdshNavHost`.
 *
 * `:app` is the composition root; `:lib` receives only the driver and plain
 * values, never a store, a Worker channel or an Android type.
 */
data class BotPlatformConfig(
    val driver: BotChatDriver,
    val context: BotUiContext,
    val appearance: BotFishAppearance,
    val roster: List<BotRosterEntry>,
    val isMainBot: Boolean = true,
    val description: String = "",
    val close: () -> Unit = {},
)
