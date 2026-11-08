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
import com.phonedsh.ui.page.SettingsFacts
import com.phonedsh.ui.page.SettingsScreenState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PdshSettingsRouteTest {
    @Test
    fun `the four hosted settings rows target real existing destinations`() {
        assertEquals(PdshRoute.AgentPresets, PdshSettingsRows.targetOf(PdshSettingsRows.HostRow.AGENT_PRESETS))
        assertEquals(PdshRoute.PhonePermissions, PdshSettingsRows.targetOf(PdshSettingsRows.HostRow.PHONE_PERMISSIONS))
        assertEquals(PdshRoute.PluginInventory, PdshSettingsRows.targetOf(PdshSettingsRows.HostRow.PLUGINS_TOOLS))
        assertEquals(PdshRoute.WorkspaceFolders, PdshSettingsRows.targetOf(PdshSettingsRows.HostRow.FOLDERS))
    }

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
     * The four destinations this host does not route — each is a surface the
     * settings sheet draws itself:
     * 新会话默认权限, 关于 and 开发者工具 are the sheet's own child pages (a local page
     * swap), and 开源许可 has no Android page — its row is a disabled explanation.
     */
    @Test
    fun `the four unrouted destinations stay null`() {
        assertNull(PdshSettingsRows.targetOf(SettingsDestination.PERMISSION_DEFAULTS))
        assertNull(PdshSettingsRows.targetOf(SettingsDestination.LICENSES))
        assertNull(PdshSettingsRows.targetOf(SettingsDestination.ABOUT))
        assertNull(PdshSettingsRows.targetOf(SettingsDestination.DEV_TOOLS))
    }

    /**
     * L55: the two Android-only entries. 版本 → 关于 and the appendix's 开发者工具 row
     * are the only ways to reach the seven pages whose iOS baseline has no entry, so
     * their destinations are pinned here — a rename that drops one would leave those
     * pages unreachable again while every other test stayed green.
     */
    @Test
    fun `the settings rows expose the about page and the developer tools index`() {
        val state = SettingsScreenState.from(SettingsFacts())
        assertEquals(
            SettingsDestination.ABOUT,
            state.row(SettingsScreenState.VERSION_ROW_ID)?.destination,
        )
        assertEquals(
            SettingsDestination.DEV_TOOLS,
            state.row(SettingsScreenState.DEV_TOOLS_ROW_ID)?.destination,
        )
    }

    /** Every destination the page can name is covered by one of the two tests above. */
    @Test
    fun `no destination is forgotten`() {
        val routed = SettingsDestination.entries.filter { PdshSettingsRows.targetOf(it) != null }
        assertEquals(
            listOf(
                SettingsDestination.MODEL_PROVIDER,
                SettingsDestination.MCP,
                SettingsDestination.SSH, // PdshRoute.Ssh
                SettingsDestination.BLUETOOTH, // PdshRoute.Bluetooth
                SettingsDestination.WEB_SEARCH,
                SettingsDestination.EGRESS,
                SettingsDestination.PLUGIN_CONFIGURATION,
                SettingsDestination.COMMAND, // PdshRoute.Tools
                SettingsDestination.RUNTIME_DETAILS, // PdshRoute.Runtime
                SettingsDestination.EXPORT_DIAGNOSTICS, // PdshRoute.Export
                SettingsDestination.SHORTCUTS, // PdshRoute.Shortcuts
                // PERMISSION_DEFAULTS, LICENSES, ABOUT and DEV_TOOLS are the four
                // the settings sheet draws itself (a local page swap, no route).
                SettingsDestination.LICENSES,
                SettingsDestination.PERMISSION_DEFAULTS,
                SettingsDestination.ABOUT,
                SettingsDestination.DEV_TOOLS,
            ).sorted(),
            SettingsDestination.entries.sorted(),
        )
        assertEquals(SettingsDestination.entries.size - 4, routed.size)
    }
}
