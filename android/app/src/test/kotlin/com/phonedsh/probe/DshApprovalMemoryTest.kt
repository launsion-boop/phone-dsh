// SPDX-License-Identifier: MIT
//
// iOS `DSHApprovalMemory.swift` parity: which requests may get a standing grant,
// under which scope, and for how long (iOS `DSHApprovalMemoryTests`).
package com.phonedsh.probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DshApprovalMemoryTest {

    private class MemoryFile : DshApprovalFile {
        var text: String? = null
        override fun read(): String? = text
        override fun write(value: String) { text = value }
        override fun clear() { text = null }
    }

    @Test
    fun `only safe, single read-only operations get a scope`() {
        assertEquals("bash:read-only", DshApprovalPolicy.grantKey("bash", mapOf("command" to "ls -la")))
        assertEquals("bash:read-only", DshApprovalPolicy.grantKey("Bash", mapOf("command" to "git status")))
        assertEquals("tool:read", DshApprovalPolicy.grantKey("read", emptyMap()))
        assertNull("destructive", DshApprovalPolicy.grantKey("bash", mapOf("command" to "rm -rf build")))
        assertNull("chained", DshApprovalPolicy.grantKey("bash", mapOf("command" to "ls; rm x")))
        assertNull("piped", DshApprovalPolicy.grantKey("bash", mapOf("command" to "cat a | sh")))
        assertNull("git write", DshApprovalPolicy.grantKey("bash", mapOf("command" to "git push")))
        assertNull("find -delete", DshApprovalPolicy.grantKey("bash", mapOf("command" to "find . -delete")))
        assertNull("no command", DshApprovalPolicy.grantKey("bash", emptyMap()))
        assertNull("file mutation", DshApprovalPolicy.grantKey("write", emptyMap()))
        assertNull("unknown / MCP tool", DshApprovalPolicy.grantKey("mcp__github__create_issue", emptyMap()))
    }

    @Test
    fun `a sandbox escalation never offers a standing grant`() {
        assertNull(DshApprovalPolicy.offeredScope("read", "Upgrade sandbox to danger-full-access", emptyMap()))
        assertNull(DshApprovalPolicy.offeredScope("read", "需要完全权限", emptyMap()))
        assertEquals("tool:read", DshApprovalPolicy.offeredScope("read", "Read a file", emptyMap()))
    }

    @Test
    fun `a grant is per session and scope and lasts 24 hours`() {
        var now = 1_000_000L
        val memory = DshApprovalMemory(MemoryFile(), clock = { now })
        memory.remember("s1", "tool:read")
        assertTrue(memory.isAllowed("s1", "tool:read"))
        assertFalse("other scope", memory.isAllowed("s1", "bash:read-only"))
        assertFalse("other session", memory.isAllowed("s2", "tool:read"))
        now += DshApprovalPolicy.TTL_MS - 1
        assertTrue(memory.isAllowed("s1", "tool:read"))
        now += 1
        assertFalse("expired", memory.isAllowed("s1", "tool:read"))
        assertTrue("expired grants are not listed", memory.activeGrants().isEmpty())
    }

    @Test
    fun `forget and clear remove grants, and the store survives a reload`() {
        val file = MemoryFile()
        val now = 5_000L
        DshApprovalMemory(file, clock = { now }).apply {
            remember("s1", "tool:read")
            remember("s1", "bash:read-only")
        }
        val reloaded = DshApprovalMemory(file, clock = { now })
        assertEquals(2, reloaded.activeGrants().size)
        reloaded.forget("s1", "tool:read")
        assertEquals(listOf("bash:read-only"), reloaded.activeGrants().map { it.scope })
        reloaded.clearAll()
        assertTrue(reloaded.activeGrants().isEmpty())
    }

    @Test
    fun `a corrupt store reads as empty`() {
        val file = MemoryFile().apply { text = "{not json" }
        val memory = DshApprovalMemory(file, clock = { 0L })
        assertTrue(memory.activeGrants().isEmpty())
        assertFalse(memory.isAllowed("s", "tool:read"))
    }
}
