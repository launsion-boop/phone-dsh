// Agent presets and the plugin inventory: the two roster-shaped B-group pages.
// SPDX-License-Identifier: MIT
//
// Same rule as the permission matrix: these assertions are about what the pages
// may *say*. A roster the host did not report is 未知, never an empty list; an
// inventory's 启用 is 是 / 否 / 未知, never a green dot on a guess; the default
// badge follows the host's `isDefault`, not the first row.
package com.phonedsh.ui.page

import com.phonedsh.ui.UiStrings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeAgentPresetsPageStateTest {

    private fun state(
        facts: NativeAgentPresetsFacts = NativeAgentPresetsFacts(),
        local: NativeAgentPresetsLocalState = NativeAgentPresetsLocalState(),
    ): NativeAgentPresetsScreenState = NativeAgentPresetsScreenState.from(facts, local)

    @Test
    fun `an unreported roster is unknown, not empty`() {
        val state = state()
        assertNull(state.presets)
        assertFalse(state.loading)
        assertNull(state.error)
        assertEquals(emptyList<AgentPresetRowView>(), state(NativeAgentPresetsFacts(presets = emptyList())).presets)
    }

    @Test
    fun `loading shows only while there is nothing to list`() {
        assertTrue(state(NativeAgentPresetsFacts(isLoading = true)).loading)
        assertFalse(
            state(
                NativeAgentPresetsFacts(
                    isLoading = true,
                    presets = listOf(NativeAgentPreset(id = "cordis", title = "Cordis")),
                ),
            ).loading,
        )
    }

    @Test
    fun `a preset row carries the baseline's five facts`() {
        val state = state(
            NativeAgentPresetsFacts(
                presets = listOf(
                    NativeAgentPreset(
                        id = "cordis",
                        title = "Cordis",
                        detail = "",
                        isDefault = true,
                        broken = null,
                        custom = true,
                    ),
                ),
            ),
        )
        val row = state.presets!!.single()
        assertEquals("Cordis", row.title)
        assertNull("an empty description prints no line", row.detail)
        assertTrue(row.isDefault)
        assertTrue(row.custom)
        assertTrue(row.canUse)
    }

    @Test
    fun `a broken preset cannot be used`() {
        val row = state(
            NativeAgentPresetsFacts(
                presets = listOf(
                    NativeAgentPreset(id = "bad", title = "Bad", broken = "manifest missing"),
                ),
            ),
        ).presets!!.single()
        assertEquals("manifest missing", row.broken)
        assertFalse(row.canUse)
    }

    @Test
    fun `the document panel folds open and closed`() {
        var local = NativeAgentPresetsLocalState()
        val document = AgentPresetDocument(presetId = "cordis", title = "Cordis", yaml = "name: cordis")
        local = local.apply(NativeAgentPresetsUiEvent.OpenDocument(document))
        assertEquals(document, state(local = local).document)
        local = local.apply(NativeAgentPresetsUiEvent.CloseDocument)
        assertNull(state(local = local).document)
    }
}

class NativePluginInventoryPageStateTest {

    private val plugins = listOf(
        ConfigurationPlugin(id = "plugin-web", module = "dsh-web", enabled = FactState.YES, phase = "active"),
        ConfigurationPlugin(id = "plugin-fs", module = "dsh-fs", enabled = FactState.NO, phase = "loaded"),
        ConfigurationPlugin(id = "plugin-x", module = "dsh-x", enabled = FactState.UNKNOWN, phase = null),
    )

    private fun state(
        facts: PluginInventoryFacts = PluginInventoryFacts(),
        local: PluginInventoryLocalState = PluginInventoryLocalState(),
    ): PluginInventoryScreenState = PluginInventoryScreenState.from(facts, local)

    @Test
    fun `an unreported inventory is unknown, not empty`() {
        val state = state()
        assertNull(state.rows)
        assertFalse(state.empty)
        assertFalse(state.loading)
        assertEquals(UiStrings.PLUGIN_INVENTORY_MANAGEMENT_NOTICE, state.notice)
    }

    @Test
    fun `an empty reading is empty, and a filtered reading is empty too`() {
        assertTrue(state(PluginInventoryFacts(plugins = emptyList())).empty)
        val filtered = state(
            PluginInventoryFacts(plugins = plugins),
            PluginInventoryLocalState(query = "nothing-matches"),
        )
        assertTrue(filtered.empty)
        assertEquals(emptyList<PluginInventoryRowView>(), filtered.rows)
    }

    @Test
    fun `the filter matches module and id, case-insensitively`() {
        val byModule = state(
            PluginInventoryFacts(plugins = plugins),
            PluginInventoryLocalState(query = "DSH-FS"),
        )
        assertEquals(listOf("plugin-fs"), byModule.rows!!.map { it.id })
        val byId = state(
            PluginInventoryFacts(plugins = plugins),
            PluginInventoryLocalState(query = "plugin-web"),
        )
        assertEquals(listOf("plugin-web"), byId.rows!!.map { it.id })
    }

    @Test
    fun `enabled is three-valued and the dot is green only for active`() {
        val rows = state(PluginInventoryFacts(plugins = plugins)).rows!!
        val active = rows.first { it.id == "plugin-web" }
        assertTrue(active.active)
        assertEquals("是", active.enabledLabel)

        val disabled = rows.first { it.id == "plugin-fs" }
        assertFalse("enabled but not active is not green", disabled.active)
        assertEquals("否", disabled.enabledLabel)

        val unknown = rows.first { it.id == "plugin-x" }
        assertFalse("an unread switch is never green", unknown.active)
        assertEquals("未知", unknown.enabledLabel)
        assertNull(unknown.phase)
    }

    @Test
    fun `the host may override the platform management notice`() {
        val state = state(
            PluginInventoryFacts(plugins = plugins, managementNotice = "托管方自己的说明"),
        )
        assertEquals("托管方自己的说明", state.notice)
    }

    @Test
    fun `loading wins over the empty state`() {
        val state = state(PluginInventoryFacts(isLoading = true))
        assertTrue(state.loading)
        assertNull(state.rows)
    }

    @Test
    fun `a row folds open and closed`() {
        var local = PluginInventoryLocalState()
        local = local.apply(PluginInventoryUiEvent.SetQuery("web"))
        assertEquals("web", local.query)
        local = local.apply(PluginInventoryUiEvent.ToggleRow("plugin-web"))
        assertTrue(local.isExpanded("plugin-web"))
        assertTrue(state(PluginInventoryFacts(plugins = plugins), local).rows!!.single().expanded)
        local = local.apply(PluginInventoryUiEvent.ToggleRow("plugin-web"))
        assertFalse(local.isExpanded("plugin-web"))
    }
}
