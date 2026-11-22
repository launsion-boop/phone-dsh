// The installed launch stack uses the native conversation as its floor.
// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.io.File
import com.phonedsh.ui.nav.PdshRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HostHomeRouteTest {
    @Test
    fun normalLaunchUsesChatAsTheRootAndLeavesTheProbeExplicit() {
        val product = initialHostNavState(probeFaceOnLaunch = false)
        assertEquals(PdshRoute.Chat, product.current)
        assertFalse(product.canGoBack)
        val fixture = File(System.getProperty("pdsh.repo.root"), "spec/ui/v1/fixtures/mobile-entry.json")
        val cases = JsonValue.parse(fixture.readText()) as JsonObject
        fun tab(key: String) = ((cases[key] as JsonObject)["selectedTab"] as JsonString).value
        assertEquals(tab("product"), product.selectedTab.name)
        assertTrue(product.selectedTab.name != tab("invalidProduct"))
        assertEquals(product.selectedTab, HostBackChain(product).pushBack.selectedTab)

        val diagnostic = initialHostNavState(probeFaceOnLaunch = true)
        assertEquals(tab("diagnostics"), diagnostic.selectedTab.name)
        assertEquals(PdshRoute.Home, diagnostic.current)
        assertTrue(diagnostic.current != PdshRoute.Sessions)
    }
}
