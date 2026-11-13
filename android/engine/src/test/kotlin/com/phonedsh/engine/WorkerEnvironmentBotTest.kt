// phone-dsh — :engine tests: the P16 Bot MCP environment keys.
// SPDX-License-Identifier: MIT
//
// `spec/bot/v1/mcp-endpoint.md` §1/§1.1: the Worker sees the Bot listener URL,
// a non-secret bearer placeholder and the per-host-start egress credential. The
// real Bot bearer never enters `?env=`.

package com.phonedsh.engine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkerEnvironmentBotTest {
    private val launchToken = "11".repeat(32)
    private val egressToken = "22".repeat(32)
    private val botUrl = "http://127.0.0.1:4242/mcp"

    @Test
    fun `the Bot environment variable names are the frozen P16 names`() {
        assertEquals("PDSH_PHONE_MCP_URL", WorkerEnvironment.PHONE_MCP_URL)
        assertEquals("PDSH_PHONE_MCP_TOKEN", WorkerEnvironment.PHONE_MCP_TOKEN)
        assertEquals("PDSH_MCP_EGRESS_TOKEN", WorkerEnvironment.MCP_EGRESS_TOKEN)
        assertEquals("phone-host-injects-bot-mcp-token", WorkerEnvironment.BOT_MCP_TOKEN_PLACEHOLDER)
    }

    @Test
    fun `a Bot endpoint publishes the URL the placeholder and the egress token`() {
        val parsed = JSONObject(
            WorkerEnvironment.pageParam(
                launchToken = launchToken,
                botMcpUrl = botUrl,
                mcpEgressToken = egressToken,
            ),
        )
        assertEquals(botUrl, parsed.getString(WorkerEnvironment.PHONE_MCP_URL))
        assertEquals(
            "the Worker never receives the real Bot bearer",
            WorkerEnvironment.BOT_MCP_TOKEN_PLACEHOLDER,
            parsed.getString(WorkerEnvironment.PHONE_MCP_TOKEN),
        )
        assertEquals(egressToken, parsed.getString(WorkerEnvironment.MCP_EGRESS_TOKEN))
        assertEquals(launchToken, parsed.getString(WorkerEnvironment.LAUNCH_TOKEN))
        assertNotEquals(
            "the Bot bearer placeholder is not the launch token",
            parsed.getString(WorkerEnvironment.PHONE_MCP_TOKEN),
            parsed.getString(WorkerEnvironment.LAUNCH_TOKEN),
        )
        assertNotEquals(
            "the egress credential is not the launch token",
            parsed.getString(WorkerEnvironment.MCP_EGRESS_TOKEN),
            parsed.getString(WorkerEnvironment.LAUNCH_TOKEN),
        )
    }

    @Test
    fun `the Bot endpoint wins over a legacy native endpoint on the same start`() {
        val parsed = JSONObject(
            WorkerEnvironment.pageParam(
                launchToken = launchToken,
                phoneMcpUrl = "http://127.0.0.1:4242/mcp/native",
                botMcpUrl = botUrl,
                mcpEgressToken = egressToken,
            ),
        )
        assertEquals(botUrl, parsed.getString(WorkerEnvironment.PHONE_MCP_URL))
        assertEquals(
            WorkerEnvironment.BOT_MCP_TOKEN_PLACEHOLDER,
            parsed.getString(WorkerEnvironment.PHONE_MCP_TOKEN),
        )
    }

    @Test
    fun `a native only start keeps the legacy loopback token spelling`() {
        val parsed = JSONObject(
            WorkerEnvironment.pageParam(
                launchToken = launchToken,
                phoneMcpUrl = "http://127.0.0.1:4242/mcp/native",
            ),
        )
        assertEquals(
            "http://127.0.0.1:4242/mcp/native",
            parsed.getString(WorkerEnvironment.PHONE_MCP_URL),
        )
        assertEquals(launchToken, parsed.getString(WorkerEnvironment.PHONE_MCP_TOKEN))
        assertFalse(parsed.has(WorkerEnvironment.MCP_EGRESS_TOKEN))
    }

    @Test
    fun `a host supplied environment cannot forge or stale the egress token`() {
        val stale = """{"PDSH_MCP_EGRESS_TOKEN":"${"33".repeat(32)}"}"""
        val refreshed = JSONObject(
            WorkerEnvironment.pageParam(
                launchToken = launchToken,
                hostSupplied = stale,
                botMcpUrl = botUrl,
                mcpEgressToken = egressToken,
            ),
        )
        assertEquals(egressToken, refreshed.getString(WorkerEnvironment.MCP_EGRESS_TOKEN))

        val removed = JSONObject(
            WorkerEnvironment.pageParam(
                launchToken = launchToken,
                hostSupplied = stale,
                botMcpUrl = botUrl,
            ),
        )
        assertFalse(
            "an old host-start token must not survive a start without one",
            removed.has(WorkerEnvironment.MCP_EGRESS_TOKEN),
        )
    }

    @Test
    fun `a host supplied Bot URL cannot override the host owned one`() {
        val parsed = JSONObject(
            WorkerEnvironment.pageParam(
                launchToken = launchToken,
                hostSupplied = """{"PDSH_PHONE_MCP_URL":"http://stale.invalid/mcp","PDSH_PHONE_MCP_TOKEN":"stale"}""",
                botMcpUrl = botUrl,
                mcpEgressToken = egressToken,
            ),
        )
        assertEquals(botUrl, parsed.getString(WorkerEnvironment.PHONE_MCP_URL))
        assertEquals(
            WorkerEnvironment.BOT_MCP_TOKEN_PLACEHOLDER,
            parsed.getString(WorkerEnvironment.PHONE_MCP_TOKEN),
        )
    }

    @Test
    fun `the egress token can be delivered without a mounted Bot endpoint`() {
        val parsed = JSONObject(
            WorkerEnvironment.pageParam(
                launchToken = launchToken,
                mcpEgressToken = egressToken,
            ),
        )
        assertEquals(egressToken, parsed.getString(WorkerEnvironment.MCP_EGRESS_TOKEN))
        assertFalse(parsed.has(WorkerEnvironment.PHONE_MCP_URL))
    }

    @Test
    fun `the Bot environment is JSON object of strings for boot js`() {
        val json = WorkerEnvironment.pageParam(
            launchToken = launchToken,
            botMcpUrl = botUrl,
            mcpEgressToken = egressToken,
        )
        val parsed = JSONObject(json)
        val names = parsed.keys().asSequence().toList()
        assertTrue(WorkerEnvironment.LAUNCH_TOKEN in names)
        assertTrue(WorkerEnvironment.PHONE_MCP_URL in names)
        assertTrue(WorkerEnvironment.PHONE_MCP_TOKEN in names)
        assertTrue(WorkerEnvironment.MCP_EGRESS_TOKEN in names)
    }
}
