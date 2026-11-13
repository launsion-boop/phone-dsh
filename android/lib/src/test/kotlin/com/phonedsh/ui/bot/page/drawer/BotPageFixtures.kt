// Shared readers for the Bot-page Compose tests.
// SPDX-License-Identifier: MIT
//
// Every test drives the real page with the shared JSON data read from the
// repository at test time (`pdsh.repo.root`, set by `:lib`). No roster entry,
// info snapshot or vector is copied into this source tree.
package com.phonedsh.ui.bot.page.drawer

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.bot.state.BotInfoModelState
import com.phonedsh.ui.bot.state.BotInfoSnapshot
import com.phonedsh.ui.bot.state.BotRosterEntry
import com.phonedsh.ui.bot.state.BotRosterRuntimeState

/** Reads the `spec/ui/v1/bot/golden` JSON files for the page tests. */
object BotPageFixtures {
    private const val BOT_GOLDEN: String = "spec/ui/v1/bot/golden"

    private val fixturesCache: JsonObject by lazy {
        SpecFixtures.repoJson("$BOT_GOLDEN/fixtures.json")
    }

    private val valueVectorsCache: JsonObject by lazy {
        SpecFixtures.repoJson("$BOT_GOLDEN/value-vectors.json")
    }

    private val uiStateVectorsCache: JsonObject by lazy {
        SpecFixtures.repoJson("$BOT_GOLDEN/ui-state-vectors.json")
    }

    /** The pinned `now` from `fixtures.json`; every relative time uses it. */
    val pinnedNow: Long by lazy { (fixturesCache["pinnedNow"] as JsonNumber).asLongOrNull()!! }

    /** One exported fixture scenario, including its `infoSnapshot`/`appearance`. */
    fun exported(scenario: String): JsonObject {
        val exported = (fixturesCache["exported"] as JsonArray).values
            .map { it as JsonObject }
        return exported.firstOrNull { (it["scenario"] as? JsonString)?.value == scenario }
            ?: error("fixtures.json has no exported scenario '$scenario'")
    }

    /** One `value-vectors.json` case value (roster, runtime, intent, …). */
    fun valueVector(index: Int): JsonObject {
        val case = (valueVectorsCache["cases"] as JsonArray).values[index] as JsonObject
        return case["value"] as JsonObject
    }

    /** The roster entry fixture (`value-vectors[0]`). */
    fun rosterEntry(): BotRosterEntry = BotRosterEntry.fromJson(valueVector(0))

    /** One `ui-state-vectors.json` case. */
    fun uiStateCase(id: String): JsonObject =
        (uiStateVectorsCache["cases"] as JsonArray).values
            .map { it as JsonObject }
            .firstOrNull { (it["id"] as? JsonString)?.value == id }
            ?: error("ui-state-vectors.json has no case '$id'")

    /** The case's pinned `now`. */
    fun uiStateNow(case: JsonObject): Long =
        ((case["input"] as JsonObject)["now"] as JsonNumber).asLongOrNull()!!

    /** The case's `input.drawer` object read into the real roster runtime value. */
    fun drawerRuntime(case: JsonObject): BotRosterRuntimeState {
        val drawer = (case["input"] as JsonObject)["drawer"] as JsonObject
        return BotRosterRuntimeState.fromJson(drawer)
    }

    /** A roster entry whose runtime/last message/unread come from one drawer vector. */
    fun drawerEntry(case: JsonObject): BotRosterEntry {
        val base = rosterEntry()
        val drawer = (case["input"] as JsonObject)["drawer"] as JsonObject
        val lastMessageAt = (drawer["lastMessageAt"] as? JsonNumber)?.asLongOrNull()
        val unread = (drawer["unreadCount"] as? JsonNumber)?.asLongOrNull()?.toInt() ?: 0
        return base.copy(
            lastMessageAt = lastMessageAt,
            unreadCount = unread,
            runtime = drawerRuntime(case),
        )
    }

    /** The pinned info model from one exported scenario (`info`, `infoEmpty`, …). */
    fun infoModel(scenario: String = "info"): BotInfoModelState {
        val snapshot = exported(scenario)["infoSnapshot"] as JsonObject
        return BotInfoModelState.initial(snapshot = BotInfoSnapshot.fromJson(snapshot))
    }

    /** The `infoAppearance` fixture's non-classic appearance. */
    fun fixtureAppearance(scenario: String = "infoAppearance"): BotFishAppearance {
        val members = (exported(scenario)["appearance"] as JsonObject).members
        val color = (members["color"] as JsonString).value
        val hairstyle = (members["hairstyle"] as JsonString).value
        return BotFishAppearance(
            color = requireNotNull(BotFishColor.fromWire(color)) { "unknown colour $color" },
            hairstyle = requireNotNull(BotFishHairstyle.fromWire(hairstyle)) {
                "unknown hairstyle $hairstyle"
            },
            autoColor = (members["autoColor"] as? JsonBool)?.value ?: false,
            autoHairstyle = (members["autoHairstyle"] as? JsonBool)?.value ?: false,
        )
    }
}
