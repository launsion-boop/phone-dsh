// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBodyType
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * Every exported scenario in `golden/fixtures.json` is decoded by the real
 * row/card/info codecs. `failClosed` proves the fail-closed rule (including the
 * deliberately schema-invalid unknown cardType), and the info scenarios pin the
 * real [BotInfoSnapshot] defaults.
 */
@RunWith(Parameterized::class)
class BotFixturesTest(
    private val scenario: JsonObject,
    private val scenarioName: String,
) {
    @Test
    fun decodesFixtureScenario() {
        val fixture = BotUiStateFixtures.golden("fixtures.json")
        val pinnedNow = fixture.pinnedNow("pinnedNow")
        val rowValues = (scenario["rows"] as JsonArray).values
        val rows = mutableListOf<BotRow>()
        val rejectedIDs = mutableListOf<String>()
        for (raw in rowValues) {
            try {
                rows.add(BotUIRowCodec.fromJson(raw))
            } catch (_: Exception) {
                rejectedIDs.add(
                    ((raw as JsonObject)["id"] as JsonString).value)
            }
        }

        if (scenarioName == "failClosed") {
            assertTrue(
                "failClosed must reject the deliberately unknown cardType",
                rejectedIDs == listOf("unknown"),
            )
            assertTrue("failClosed must render no row", rows.none { BotUIRendering.isRenderable(it) })
            val state = derive(rows, pinnedNow)
            assertTrue("failClosed visible rows must be empty", state.visibleRowIDs.isEmpty())
        } else {
            assertTrue("scenario $scenarioName rejected rows $rejectedIDs", rejectedIDs.isEmpty())
        }

        val state = derive(rows, pinnedNow)
        for (row in rows) {
            val expectedVisible = row.body.type != BotRowBodyType.NOTICE &&
                BotUIRendering.isRenderable(row)
            assertEquals(
                "visibility of ${row.id} in $scenarioName",
                expectedVisible,
                row.id in state.visibleRowIDs,
            )
        }

        scenario["infoSnapshot"]?.let { infoValue ->
            if (infoValue is JsonNull) return@let
            val info = BotInfoSnapshot.fromJson(infoValue)
            when (scenarioName) {
                "info" -> {
                    assertEquals("大肥鱼", info.botName)
                    assertEquals(2, info.memories.size)
                    assertEquals(2, info.routines.size)
                    assertEquals(7, info.approvals.size)
                    assertEquals(3, info.grants.size)
                    assertNotNull(info.maintenance)
                    assertTrue(info.maintenanceEnabled)
                    assertEquals(96_000L, info.maintenanceDailyBudget)
                    assertEquals(12, info.maintenanceDailyBudgetPercent)
                    assertTrue(info.routines.first { it.id == "routine-1" }.canCancelRun)
                    assertTrue(info.routines.first { it.id == "routine-2" }.needsReconciliation)
                    assertEquals(3, BotGrantInfo.standing(info.grants).size)
                    assertEquals(1, info.presence.deferred.size)
                }
                "infoEmpty" -> {
                    assertTrue(info.memories.isEmpty())
                    assertTrue(info.routines.isEmpty())
                    assertTrue(info.approvals.isEmpty())
                    assertTrue(info.grants.isEmpty())
                    assertTrue(info.reconciliations.isEmpty())
                    assertEquals(RoutinePresenceLevel.FOREGROUND, info.presence.level)
                    assertEquals(ProactiveMode.ON, info.proactiveSettings.mode)
                    assertNull(info.maintenance)
                    assertEquals(0L, info.maintenanceDailyBudget)
                    assertNull(info.maintenanceDailyBudgetPercent)
                }
                "infoAppearance" -> {
                    val appearance = JsonSupport.objectMembers(
                        scenario["appearance"]!!, "appearance")
                    assertEquals(
                        BotFishColor.PURPLE,
                        BotFishColor.fromWire(JsonSupport.requiredString(appearance, "color")),
                    )
                    assertEquals(
                        BotFishHairstyle.TWIN_TAIL,
                        BotFishHairstyle.fromWire(
                            JsonSupport.requiredString(appearance, "hairstyle")),
                    )
                    assertEquals(2, info.memories.size)
                }
            }
        }

        if (scenarioName == "composerAttachments") {
            val userRow = rows.first { it.id == "attachments-user" }
            assertTrue(BotUIRendering.isRenderable(userRow))
            assertEquals(
                2,
                BotUIAttachmentParser.parseList(userRow.body["attachments"]).size,
            )
        }
        if (scenarioName == "composerLongDraft") {
            assertEquals(
                "draft must be present",
                true,
                (scenario["draft"] as? JsonString)?.value?.isNotEmpty(),
            )
        }
    }

    @Test
    fun skippedScenariosAreRecorded() {
        val fixture = BotUiStateFixtures.golden("fixtures.json")
        val skipped = (fixture["skipped"] as JsonArray).values
        assertTrue("fixtures.skipped must not be dropped", skipped.size >= 20)
        for (raw in skipped) {
            val entry = raw as JsonObject
            assertFalse((entry["scenario"] as JsonString).value.isEmpty())
            assertFalse((entry["reason"] as JsonString).value.isEmpty())
        }
    }

    private fun derive(rows: List<BotRow>, now: Long): BotUiState =
        BotUiStateDerivation.derive(
            BotUiStateInput(
                context = BotUiContext(botID = "main", botName = "大肥鱼"),
                rows = rows,
                now = now,
            ),
        )

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{1}")
        fun scenarios(): List<Array<Any>> {
            val fixture = BotUiStateFixtures.golden("fixtures.json")
            return (fixture["exported"] as JsonArray).values.map { raw ->
                val scenario = raw as JsonObject
                arrayOf<Any>(scenario, (scenario["scenario"] as JsonString).value)
            }
        }
    }
}

private fun JsonObject.pinnedNow(key: String): Long =
    (this[key] as com.phonedsh.agentcore.JsonNumber).asLongOrNull()
        ?: throw com.phonedsh.bot.BotJsonException("$key must be an integer")
