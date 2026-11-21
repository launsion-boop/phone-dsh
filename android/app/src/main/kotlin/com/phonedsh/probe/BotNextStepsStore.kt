// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.content.Context
import com.phonedsh.ui.bot.state.BotNextStepsCountStore

/**
 * The two next-steps usage counters on this phone (iOS keeps them in
 * `UserDefaults` under `dev.phone-dsh.bot.next-steps-usage.v1`). Local only.
 */
internal class SharedPreferencesBotNextStepsCountStore(context: Context) : BotNextStepsCountStore {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun read(): Map<String, Int> =
        prefs.all.mapNotNull { (key, value) -> (value as? Int)?.let { key to it } }.toMap()

    override fun write(counts: Map<String, Int>) {
        val edit = prefs.edit().clear()
        counts.forEach { (key, value) -> edit.putInt(key, value) }
        edit.apply()
    }

    override fun clear() {
        prefs.edit().clear().apply()
    }

    private companion object {
        const val FILE = "phone-dsh-bot-next-steps-usage"
    }
}
