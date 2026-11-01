// The settings index's destinations and the routes they open.
// SPDX-License-Identifier: MIT
//
// The mirrored settings page names destinations instead of host-built row ids
// (N4 lane), so `PdshSettingsRows.targetOf` is the only place a tapped row becomes
// a route. These assertions are what keeps a row from being visible and dead: every
// destination the page can emit either has a route here or is handled by the
// settings sheet itself.
package com.phonedsh.ui.nav

import com.phonedsh.ui.page.SettingsDestination
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PdshSettingsRouteTest {
    @Test
    fun `every navigating row has a route`() {
        assertEquals(PdshRoute.ModelProvider, PdshSettingsRows.targetOf(SettingsDestination.MODEL_PROVIDER))
        assertEquals(PdshRoute.WebSearch, PdshSettingsRows.targetOf(SettingsDestination.WEB_SEARCH))
        assertEquals(PdshRoute.Mcp, PdshSettingsRows.targetOf(SettingsDestination.MCP))
        assertEquals(PdshRoute.Egress, PdshSettingsRows.targetOf(SettingsDestination.EGRESS))
        assertEquals(PdshRoute.Configuration, PdshSettingsRows.targetOf(SettingsDestination.PLUGIN_CONFIGURATION))
        // 命令 and 导出诊断 used to be visible rows with no destination at all.
        assertEquals(PdshRoute.Tools, PdshSettingsRows.targetOf(SettingsDestination.COMMAND))
        assertEquals(PdshRoute.Export, PdshSettingsRows.targetOf(SettingsDestination.EXPORT_DIAGNOSTICS))
        // §1's RuntimeDetailsPage is reachable from the page header and from a
        // settings row; the row exists here, so the route must too.
        assertEquals(PdshRoute.Runtime, PdshSettingsRows.targetOf(SettingsDestination.RUNTIME_DETAILS))
    }

    /**
     * The two destinations this host does not route:
     * 新会话默认权限 is the settings sheet's own child page (a local page swap, not a
     * route), and 开源许可 has no Android page — its row is a disabled explanation,
     * so it never emits a destination.
     */
    @Test
    fun `the two unrouted destinations stay null`() {
        assertNull(PdshSettingsRows.targetOf(SettingsDestination.PERMISSION_DEFAULTS))
        assertNull(PdshSettingsRows.targetOf(SettingsDestination.LICENSES))
    }

    /** Every destination the page can name is covered by one of the two tests above. */
    @Test
    fun `no destination is forgotten`() {
        val routed = SettingsDestination.entries.filter { PdshSettingsRows.targetOf(it) != null }
        assertEquals(
            listOf(
                SettingsDestination.MODEL_PROVIDER,
                SettingsDestination.MCP,
                SettingsDestination.WEB_SEARCH,
                SettingsDestination.EGRESS,
                SettingsDestination.PLUGIN_CONFIGURATION,
                SettingsDestination.COMMAND, // PdshRoute.Tools
                SettingsDestination.RUNTIME_DETAILS, // PdshRoute.Runtime
                SettingsDestination.EXPORT_DIAGNOSTICS, // PdshRoute.Export
                // PERMISSION_DEFAULTS and LICENSES are the two null ones.
                SettingsDestination.LICENSES,
                SettingsDestination.PERMISSION_DEFAULTS,
            ).sorted(),
            SettingsDestination.entries.sorted(),
        )
        assertEquals(SettingsDestination.entries.size - 2, routed.size)
    }
}
