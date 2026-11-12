// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The `grant-directory` suite of `mcp-egress.phone` drives the real file
 * effect classifier. The decisions/grants belong to the Worker/host egress
 * engine; this lane owns the effect shape and directory key.
 */
class BotEgressEffectsTest {
    @Test
    fun fileEffectsUseTheDirectoryKeyAndFailClosedWhenThePathIsMissing() {
        val fixture = GoldenFixture.rawObject("mcp-egress.phone")
        val cases = GoldenFixture.objects(fixture, "valid")
            .filter { GoldenFixture.string(it, "suite") == "grant-directory" } +
            GoldenFixture.objects(fixture, "invalid")
                .filter { GoldenFixture.string(it, "suite") == "grant-directory" }
        assertTrue(cases.isNotEmpty())
        var checked = 0
        for (case in cases) {
            val label = GoldenFixture.requireString(case, "name")
            val request = GoldenFixture.objectValue(case, "request")
            val tool = GoldenFixture.requireString(request, "tool")
            val path = GoldenFixture.string(request, "path") ?: ""
            val workspace = GoldenFixture.requireString(request, "workspace")
            val expected = GoldenFixture.objectValue(case, "expect")
            val expectedPolicy = GoldenFixture.requireString(expected, "policy")
            val effects = BotEgressEffects.fileEffects(
                tool,
                jsonObject("file_path" to com.phonedsh.agentcore.JsonString(path)),
                workspace,
            )
            if (expectedPolicy == "auto") {
                assertTrue("$label must not ask", effects.isEmpty())
            } else {
                val effect = effects.singleOrNull() ?: error("$label must ask exactly once")
                assertEquals("$label policy", BotToolPolicy.ASK, effect.policy)
                val expectedResource = GoldenFixture.string(expected, "resource")
                if (expectedResource != null && expectedResource != "unclassified") {
                    assertEquals("$label resource", expectedResource, effect.resource)
                }
                if (path.isEmpty()) {
                    assertFalse("$label missing path is unknown", effect.known)
                    assertEquals("tool.unclassified", effect.operation)
                }
            }
            checked++
        }
        assertEquals(cases.size, checked)
    }

    @Test
    fun networkWriteEffectsAreHostAndMethodScoped() {
        val effect = BotEgressEffects.egressEffect(
            method = "POST",
            host = "API.Example.Test",
            target = "https://api.example.test/upload",
        )
        assertEquals(BotEgressEffects.TOOL_NAME, effect.tool)
        assertEquals("egress.post", effect.operation)
        assertEquals("host=api.example.test", effect.resource)
        assertEquals(BotToolMutability.EXTERNAL_SEND, effect.mutability)
        assertEquals(BotToolPolicy.ASK, effect.policy)
        assertTrue(effect.known)
        assertEquals("egress.get", BotEgressEffects.egressOperation("GET"))
        assertEquals("host=api.example.test", BotEgressEffects.egressResource(" API.EXAMPLE.TEST "))
    }

    @Test
    fun workspaceContainmentIsDecidedAfterNormalization() {
        val root = "/dsh/workspace/.dshbot/agents/main"
        assertTrue(BotEgressEffects.isInsideWorkspace("$root/notes/a.txt", root))
        assertTrue(BotEgressEffects.isInsideWorkspace("$root/notes/../a.txt", root))
        assertFalse(BotEgressEffects.isInsideWorkspace("$root/../other/a.txt", root))
        assertEquals(
            "dir=/dsh/workspace/.dshbot/agents",
            BotEgressEffects.directoryResource("$root/../outside.txt"),
        )
    }
}
