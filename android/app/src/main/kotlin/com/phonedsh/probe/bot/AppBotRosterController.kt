// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import android.content.SharedPreferences
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotRosterDeleteOutcome
import com.phonedsh.bot.profile.BotRosterRules
import com.phonedsh.ui.bot.state.BotDrawerIntent
import com.phonedsh.ui.bot.state.BotNameValidation
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal class AppBotRosterController(
    private val store: AppBotProfileStore,
    private val clock: () -> Long,
    private val preferences: SharedPreferences,
    private val newDriver: (String) -> AppBotChatDriver,
) : AutoCloseable {
    private var roster = store.read()
    private var selected = AppBotRoster.context(roster, preferences.getString(SELECTED_BOT_KEY, null)).botID
    private val drivers = mutableMapOf<String, AppBotChatDriver>()
    private val current = MutableStateFlow(platform())
    val state = current.asStateFlow()

    @Synchronized
    fun apply(intent: BotDrawerIntent) {
        when (intent) {
            is BotDrawerIntent.Create -> {
                val name = checkedName(intent.name)
                val now = clock()
                val profile = BotProfile(
                    id = UUID.randomUUID().toString(),
                    name = name,
                    fishColor = intent.color,
                    fishHairstyle = intent.hairstyle,
                    nameExplicit = true,
                    createdAt = now,
                    updatedAt = now,
                )
                val next = roster.copy(bots = roster.bots + profile)
                store.write(next)
                roster = next
                selected = profile.id
            }
            is BotDrawerIntent.Select -> {
                if (roster.bots.none { it.id == intent.botID }) return
                selected = intent.botID
            }
            is BotDrawerIntent.Rename -> {
                val name = checkedName(intent.name)
                val next = roster.copy(bots = roster.bots.map {
                    if (it.id == intent.botID) it.copy(name = name, nameExplicit = true, updatedAt = clock()) else it
                })
                store.write(next)
                roster = next
            }
            is BotDrawerIntent.SetHidden -> {
                val next = roster.copy(bots = roster.bots.map {
                    if (it.id == intent.botID) it.copy(hiddenByUser = intent.hidden, updatedAt = clock()) else it
                })
                store.write(next)
                roster = next
            }
            is BotDrawerIntent.SetMain -> {
                if (roster.bots.none { it.id == intent.botID }) return
                val next = roster.copy(
                    mainBotID = intent.botID,
                    bots = roster.bots.map { if (it.id == intent.botID) it.copy(pinned = true) else it },
                )
                store.write(next)
                store.setMain(intent.botID)
                roster = next
            }
            is BotDrawerIntent.Delete -> {
                val outcome = BotRosterRules.delete(roster.bots.map { it.id }, roster.mainBotID, intent.botID)
                if (outcome !is BotRosterDeleteOutcome.Deleted) return
                val next = roster.copy(mainBotID = outcome.mainBotID, bots = roster.bots.filter { it.id != intent.botID })
                store.write(next)
                roster = next
                if (selected == intent.botID) selected = checkNotNull(next.mainBotID)
                drivers.remove(intent.botID)?.close()
            }
            BotDrawerIntent.Retry -> roster = store.read()
            else -> return
        }
        preferences.edit().putString(SELECTED_BOT_KEY, selected).apply()
        current.value = platform()
    }

    @Synchronized
    fun domainChanged(botId: String?) {
        drivers[botId]?.domainChanged()
    }

    private fun checkedName(raw: String): String = raw.trim().also {
        require(BotNameValidation.isValid(it)) { "Bot 名称无效" }
    }

    private fun platform(): BotPlatformConfig {
        val context = AppBotRoster.context(roster, selected)
        val profile = roster.bots.first { it.id == context.botID }
        return BotPlatformConfig(
            driver = drivers.getOrPut(profile.id) { newDriver(profile.id) },
            context = context,
            appearance = BotFishAppearance.resolve(profile),
            roster = AppBotRoster.entries(roster),
            isMainBot = profile.id == roster.mainBotID,
            description = profile.description,
        )
    }

    private companion object {
        const val SELECTED_BOT_KEY = "phoneDSH.bot.selectedBotID"
    }

    @Synchronized
    override fun close() {
        drivers.values.forEach(AppBotChatDriver::close)
        drivers.clear()
    }
}
