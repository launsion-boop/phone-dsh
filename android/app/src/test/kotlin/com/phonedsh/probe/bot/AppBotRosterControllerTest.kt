// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.ui.bot.state.BotDrawerIntent
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class AppBotRosterControllerTest {
    @get:Rule val directory = TemporaryFolder()

    @Test
    fun createdBotHasItsOwnDriverAndSurvivesReopeningTheRoster() {
        val app = ApplicationProvider.getApplicationContext<Context>()
        val prefs = app.getSharedPreferences("bot-test", Context.MODE_PRIVATE)
        val root = directory.newFolder()
        val database = File(root, "bot.sqlite")
        BotDomainStore(JdbcBotSqlDriver.open(database)).use { store ->
            fun open() = AppBotRosterController(AppBotProfileStore(root) { 1L }, { 1L }, prefs) { id ->
                AppBotChatDriver(store, LocalBotSessionTransport(), botId = id)
            }
            val newId = open().use { roster ->
                val mainDriver = roster.state.value.driver
                roster.apply(BotDrawerIntent.Create("  QA Bot  ", BotFishColor.TEAL, BotFishHairstyle.BOB))
                val created = roster.state.value
                assertEquals("QA Bot", created.context.botName)
                assertEquals(2, created.roster.size)
                assertEquals(BotFishColor.TEAL, created.appearance.color)
                assertNotSame(mainDriver, created.driver)
                created.context.botID
            }
            open().use { reopened ->
                assertEquals(newId, reopened.state.value.context.botID)
                assertEquals("QA Bot", reopened.state.value.context.botName)
                assertEquals(2, reopened.state.value.roster.size)
            }
        }
    }
}
