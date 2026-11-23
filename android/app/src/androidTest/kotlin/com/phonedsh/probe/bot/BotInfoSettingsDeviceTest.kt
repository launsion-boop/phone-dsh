// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import android.app.Application
import android.content.Context
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.bot.memory.BotMemoryMaintenanceSettings
import com.phonedsh.probe.MainActivity
import com.phonedsh.probe.ProbeEngineViewModel
import com.phonedsh.ui.bot.state.BotInfoIntent
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BotInfoSettingsDeviceTest {
    @Test fun settingsReloadFromTheRuntimeStores() = runBlocking {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        ActivityScenario.launch(MainActivity::class.java).use {
            val engine = ProbeEngineViewModel.sharedHost(app)
            val config = withTimeout(30000) { engine.botPlatformConfig.filterNotNull().first() }
            val id = config.context.botID
            val original = engine.botInfo(id, BotInfoIntent.Load)
            val preferences = app.getSharedPreferences("phone-dsh-bot", Context.MODE_PRIVATE)
            val quiet = original.proactiveSettings.copy(dnd = !original.proactiveSettings.dnd, quietStart = "21:15", quietEnd = "07:30")
            try {
                engine.botInfo(id, BotInfoIntent.SaveProactiveSettings(quiet))
                engine.botInfo(id, BotInfoIntent.SetMaintenanceEnabled(!original.maintenanceEnabled))
                val reread = engine.botInfo(id, BotInfoIntent.Load)
                assertEquals(quiet, reread.proactiveSettings)
                assertEquals(quiet.dnd, SharedPreferencesProactiveSettingsStore(preferences).load().dnd)
                val blob = JSONObject(preferences.getString(BotMemoryMaintenanceSettings.DEFAULTS_KEY, null)!!)
                assertEquals(!original.maintenanceEnabled, blob.getBoolean("enabled"))
                assertEquals(reread.maintenanceEnabled, blob.getBoolean("enabled"))
                assertEquals(original.maintenanceDailyBudget, blob.getLong("dailyTokenBudget"))
            } finally {
                engine.botInfo(id, BotInfoIntent.SaveProactiveSettings(original.proactiveSettings))
                engine.botInfo(id, BotInfoIntent.SetMaintenanceEnabled(original.maintenanceEnabled))
            }
        }
        Unit
    }
}
