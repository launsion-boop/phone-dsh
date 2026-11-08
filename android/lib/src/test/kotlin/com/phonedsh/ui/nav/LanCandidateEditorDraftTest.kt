// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.MCPEditorFacts
import com.phonedsh.ui.page.MCPEditorScreenState
import com.phonedsh.ui.page.MCPTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A selected LAN candidate pre-fills the editor; it does not save, grant or invent persistence. */
class LanCandidateEditorDraftTest {
    @Test
    fun candidateUrlPrefillsAValidHttpDraftWithAnEmptyCredentialRow() {
        val facts = MCPEditorFacts(writable = FactState.NO)
        val state = MCPEditorScreenState.from(facts, discoveredDraft("https://lamp.local:8443/mcp"))
        assertTrue(state.isNew)
        assertEquals(MCPTransport.HTTP, state.draft.transport)
        assertEquals("https://lamp.local:8443/mcp", state.draft.url)
        assertTrue(Regex("device_[0-9a-f]{12}").matches(state.draft.name))
        assertEquals(listOf("Authorization"), state.draft.headers.map { it.name })
        assertEquals("", state.draft.headers.single().value)
        assertEquals(emptyList<Any>(), state.errors)
        // The host still says it cannot persist: the editor keeps its handoff note.
        assertFalse(state.canPersist)
    }

    @Test
    fun noCandidateIsTheOrdinaryBlankForm() {
        assertNull(discoveredDraft(null).draft)
        assertNotEquals(discoveredDraft("https://a.example/mcp").draft?.name, discoveredDraft("https://a.example/mcp").draft?.name)
    }

    @Test
    fun routeEqualityKeepsTheCandidateUrl() {
        assertNotEquals(PdshRoute.McpEditor(null), PdshRoute.McpEditor(null, discoveredUrl = "https://a.example/mcp"))
    }
}
