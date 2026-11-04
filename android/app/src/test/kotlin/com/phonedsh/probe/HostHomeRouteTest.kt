// The installed launch stack uses the native conversation as its floor.
// SPDX-License-Identifier: MIT
package com.phonedsh.probe

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

        val diagnostic = initialHostNavState(probeFaceOnLaunch = true)
        assertEquals(PdshRoute.Home, diagnostic.current)
        assertTrue(diagnostic.current != PdshRoute.Sessions)
    }
}
