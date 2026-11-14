// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotRoster
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The catalog is data-driven: the sixteen upstream P0 entries and the five
 * phone content-card replacements are compared byte-for-byte with the
 * vectors; nothing in Kotlin may re-type those descriptions.
 */
class BotToolCatalogGoldenTest {
    private val upstream: JsonObject = GoldenFixture.rawObject("tool-catalog")
    private val phone: JsonObject = GoldenFixture.rawObject("tool-catalog.phone")
    private val roster = BotRoster(
        bots = listOf(
            BotProfile(id = "bot-a", name = "Alpha"),
            BotProfile(id = "bot-b", name = "Bee"),
            BotProfile(id = "bot-x", name = "Xray"),
        ),
        mainBotID = "bot-a",
    )
    private val catalog = BotToolCatalog.fromGolden(upstream, phone, roster)

    @Test
    fun p0OrderIsTheFrozenSeventeen() {
        assertEquals(BotToolCatalog.P0_NAMES, catalog.p0.map { it.name })
        assertEquals(17, catalog.p0.size)
        assertTrue(catalog.p0.any { it.name == "ReadMemory" })
        assertEquals(
            "ReadMemory",
            catalog.p0[catalog.p0.indexOfFirst { it.name == "UpdateMemory" } + 1].name,
        )
    }

    @Test
    fun upstreamDefinitionsAreReadFromTheGolden() {
        val upstreamP0 = ((upstream.members["valid"] as JsonObject).members["p0"] as JsonArray).values
            .map { it as JsonObject }
        val overridden = ((phone.members["valid"] as JsonObject).members["p0"] as JsonArray).values
            .map { ((it as JsonObject).members["name"] as JsonString).value }
            .toSet()
        for (entry in upstreamP0) {
            val name = (entry.members["name"] as JsonString).value
            if (name in overridden) continue
            val definition = catalog.p0.first { it.name == name }
            assertEquals(name, (entry.members["description"] as JsonString).value, definition.description)
            assertEquals(
                "$name inputSchema",
                BotJson.canonical(entry.members["inputSchema"]!!),
                BotJson.canonical(definition.inputSchema),
            )
        }
    }

    @Test
    fun phoneContentCardsReplaceTheirUpstreamNames() {
        val phoneP0 = ((phone.members["valid"] as JsonObject).members["p0"] as JsonArray).values
            .map { it as JsonObject }
        assertEquals(5, phoneP0.size)
        for (entry in phoneP0) {
            val name = (entry.members["name"] as JsonString).value
            val definition = catalog.p0.first { it.name == name }
            assertEquals(name, (entry.members["description"] as JsonString).value, definition.description)
            assertEquals(
                "$name schema",
                BotJson.canonical(entry.members["inputSchema"]!!),
                BotJson.canonical(definition.inputSchema),
            )
            val final = (entry.members["inputSchema"] as JsonObject).members["properties"]
            assertNotNull("$name must advertise final", (final as JsonObject).members["final"])
        }
    }

    @Test
    fun p1TargetsAreNeverAdvertised() {
        assertEquals(BotToolCatalog.P1_TARGET_NAMES, catalog.p1.map { it.name })
        val advertised = catalog.definitions(null).map { it.name }.toSet()
        for (name in BotToolCatalog.P1_TARGET_NAMES) {
            assertFalse("$name is target and must not be advertised", advertised.contains(name))
            assertTrue(catalog.isP1(name))
        }
    }

    @Test
    fun staticCatalogIsTheFrozenTwentyTwoWithTeamTools() {
        val names = catalog.definitions(null).map { it.name }
        assertEquals(
            listOf(
                "ask_user", "show_next_steps", "show_attachment", "show_document", "show_progress",
                "show_checklist", "show_link", "UpdateMemory", "ReadMemory", "RecallMemory",
                "Task", "AwaitTask", "StopSubagent", "UpdateRoutine", "ListRoutines",
                "RequestApproval", "SendToUser", "FishAction", "BotVolatileContext",
                "attach_to_model", "SendToAgent", "CreateTeammate",
            ),
            names,
        )
    }

    @Test
    fun createTeammateIsHiddenFromANonMainCaller() {
        val main = catalog.definitions("bot-a").map { it.name }
        val teammate = catalog.definitions("bot-b").map { it.name }
        assertTrue(main.contains("CreateTeammate"))
        assertFalse(teammate.contains("CreateTeammate"))
        assertTrue(teammate.contains("SendToAgent"))
        assertTrue(teammate.contains("FishAction"))
        assertTrue(teammate.contains("BotVolatileContext"))
    }

    @Test
    fun teamDescriptionsCarryTheLiveRosterLine() {
        val expected = phone.members["team"] as JsonObject
        val lines = expected.members["rosterLine"] as JsonObject
        val mainDescription = catalog.definitions("bot-a")
            .first { it.name == "SendToAgent" }.description
        assertTrue(
            mainDescription.contains((lines.members["mainCaller"] as JsonString).value),
        )
        val teammateDescription = catalog.definitions("bot-b")
            .first { it.name == "SendToAgent" }.description
        assertTrue(
            teammateDescription.contains((lines.members["teammateCaller"] as JsonString).value),
        )
    }

    @Test
    fun fishAndVolatileMetadataComeFromThePhoneDelta() {
        val fish = phone.members["fish"] as JsonObject
        val description = catalog.fishAction.description
        for (value in (fish.members["descriptionContains"] as JsonArray).values) {
            assertTrue(
                "FishAction missing ${(value as JsonString).value}",
                description.contains(value.value),
            )
        }
        val properties = (catalog.fishAction.inputSchema as JsonObject).members["properties"] as JsonObject
        val action = properties.members["action"] as JsonObject
        val actions = (action.members["enum"] as JsonArray).values.map { (it as JsonString).value }
        for (value in (fish.members["actions"] as JsonArray).values) {
            assertTrue(actions.contains((value as JsonString).value))
        }
        assertEquals(
            BotToolCatalog.VOLATILE_CONTEXT_NAME,
            catalog.volatileContext.name,
        )
        val session = ((catalog.volatileContext.inputSchema as JsonObject)
            .members["properties"] as JsonObject).members["sessionId"] as JsonObject
        assertEquals(
            JsonNumber("1"),
            session.members["minLength"],
        )
        assertEquals(
            JsonNumber("200"),
            session.members["maxLength"],
        )
    }

    @Test
    fun readMemoryUsesThePhoneMemoryPropertySet() {
        val memory = phone.members["memory"] as JsonObject
        val metadata = memory.members["readMemory"] as JsonObject
        val definition = catalog.p0.first { it.name == "ReadMemory" }
        val schema = definition.inputSchema as JsonObject
        val properties = (schema.members["properties"] as JsonObject).members.keys
        val expected = (metadata.members["properties"] as JsonArray).values
            .map { (it as JsonString).value }.toSet()
        assertEquals(expected, properties)
        val required = (schema.members["required"] as JsonArray).values
            .map { (it as JsonString).value }.toSet()
        assertEquals(
            (metadata.members["required"] as JsonArray).values
                .map { (it as JsonString).value }.toSet(),
            required,
        )
    }

    @Test
    fun isRegisteredIncludesTheVolatileToolAndExcludesTeamAndP1() {
        assertTrue(BotToolCatalog.isRegistered("ask_user"))
        assertTrue(BotToolCatalog.isRegistered("ReadMemory"))
        assertTrue(BotToolCatalog.isRegistered(BotToolCatalog.VOLATILE_CONTEXT_NAME))
        assertFalse(BotToolCatalog.isRegistered("FishAction"))
        assertFalse(BotToolCatalog.isRegistered("SendToAgent"))
        assertFalse(BotToolCatalog.isRegistered("show_table"))
        assertNull(catalog.p0.firstOrNull { it.name == "show_table" })
    }
}
