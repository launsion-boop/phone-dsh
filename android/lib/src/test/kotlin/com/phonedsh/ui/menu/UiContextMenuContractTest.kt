// Shared context-menu golden, read from the repository at test time.
// SPDX-License-Identifier: MIT
//
// Every surface and every item in
// `spec/ui/v1/golden/context-menu-items.golden.json` runs through the same
// [ContextMenuModel] the renderer uses. The golden fixes order/label/role/kind;
// the generated table supplies the `when`/`dividerBefore` values the golden
// deliberately omits. No case is copied into Kotlin.
package com.phonedsh.ui.menu

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.theme.generated.TokenContextMenuWhen
import com.phonedsh.ui.theme.generated.UiTokenData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Contract test for `interaction.contextMenu` (spec/ui/v1/interaction.md §3). */
class UiContextMenuContractTest {
    private val golden: JsonObject by lazy {
        SpecFixtures.repoJson("spec/ui/v1/golden/context-menu-items.golden.json")
    }

    private val generated = UiTokenData.contextMenu.surfaces

    @Test
    fun `the golden surfaces are the generated surfaces in contract order`() {
        assertEquals(golden.text("preview"), UiTokenData.contextMenu.preview.spec)
        assertEquals(
            goldenSurfaces().map { it.text("id") },
            ContextMenuModel.surfaces.map { it.id },
        )
        assertEquals(ContextMenuModel.surfaces.map { it.id }, generated.map { it.id })
    }

    @Test
    fun `every golden item is visible in the all-conditions-true row`() {
        val state = allTrueState()
        goldenSurfaces().forEach { goldenSurface ->
            val surfaceId = goldenSurface.text("id")
            val expected = goldenItems(goldenSurface).map {
                Triple(it.text("label"), it.text("role"), it.text("kind"))
            }
            val actual = ContextMenuModel.items(surfaceId, state)
            assertEquals(
                "$surfaceId: visible labels/roles/kinds",
                expected,
                actual.map { Triple(it.label, it.role.spec, it.kind.spec) },
            )
            // The golden intentionally omits these two columns; the generated
            // table is their one authority, and the renderer must receive them.
            val surface = ContextMenuModel.surface(surfaceId)
            assertEquals(
                "$surfaceId: every visible item keeps its token position",
                surface.items.indices.toList(),
                actual.map { it.order },
            )
            assertEquals(
                "$surfaceId: dividerBefore is carried from the token row",
                surface.items.map { it.dividerBefore },
                actual.map { it.dividerBefore },
            )
        }
    }

    @Test
    fun `every when combination of every surface matches the golden rows`() {
        generated.forEach { surface ->
            val goldenItems = goldenItems(goldenSurface(surface.id))
            val conditions = surface.items.map { it.whenCondition }.distinct()
            val combinations = 1 shl conditions.size
            for (mask in 0 until combinations) {
                val predicates = conditions.withIndex().associate { indexed ->
                    indexed.value to (((mask shr indexed.index) and 1) == 1)
                }
                val state = ContextMenuRowState(predicates)
                val expected = surface.items.withIndex()
                    .filter { (_, token) -> state.shows(token.whenCondition) }
                val actual = ContextMenuModel.items(surface.id, state)
                val where = "${surface.id} mask=$mask predicates=$predicates"
                assertEquals(
                    "$where: labels/roles/kinds",
                    expected.map { (index, _) ->
                        Triple(
                            goldenItems[index].text("label"),
                            goldenItems[index].text("role"),
                            goldenItems[index].text("kind"),
                        )
                    },
                    actual.map { Triple(it.label, it.role.spec, it.kind.spec) },
                )
                assertEquals("$where: orders", expected.map { it.index }, actual.map { it.order })
                assertEquals(
                    "$where: dividers",
                    expected.map { it.value.dividerBefore },
                    actual.map { it.dividerBefore },
                )
            }
        }
    }

    @Test
    fun `a false when removes exactly that item instead of disabling it`() {
        generated.forEach { surface ->
            surface.items.forEachIndexed { index, token ->
                val state = ContextMenuRowState(
                    TokenContextMenuWhen.entries.associateWith { it != token.whenCondition },
                )
                val actual = ContextMenuModel.items(surface.id, state)
                val hidden = actual.any { it.order == index }
                assertFalse(
                    "${surface.id}[$index] '${token.label}' must be absent when " +
                        "${token.whenCondition.spec} is false",
                    hidden,
                )
                assertEquals(
                    "${surface.id}[$index]: only the matching rows disappear",
                    surface.items.count { it.whenCondition != token.whenCondition },
                    actual.size,
                )
                // A hidden row is not a disabled row: the projection only ever
                // contains visible rows, and [ContextMenuItem] has no enabled flag.
            }
        }
    }

    @Test
    fun `botRow resolves altLabel from the hidden row state`() {
        val surface = ContextMenuModel.surface("botRow")
        val token = surface.items.single { it.altLabel != null }
        val order = surface.items.indexOf(token)
        val visible = ContextMenuModel.items("botRow", allTrueState(botHidden = false))
        assertEquals(token.label, visible.single { it.order == order }.label)
        val hidden = ContextMenuModel.items("botRow", allTrueState(botHidden = true))
        assertEquals(token.altLabel, hidden.single { it.order == order }.label)
        // Only the row with an altLabel changes.
        assertEquals(
            visible.filterNot { it.order == order }.map { it.label },
            hidden.filterNot { it.order == order }.map { it.label },
        )
    }

    @Test
    fun `unconditional rows keep always items and hide the rest`() {
        val items = ContextMenuModel.items("drawerFolder", ContextMenuRowState.unconditional)
        assertEquals(
            ContextMenuModel.surface("drawerFolder").items
                .filter { it.whenCondition == TokenContextMenuWhen.ALWAYS }
                .map { it.label },
            items.map { it.label },
        )
    }

    @Test
    fun `rule 7 session closes before returning an action and permits one per open`() {
        val item = ContextMenuModel.items("drawerSession", allTrueState()).first()
        val session = ContextMenuSession()
        assertFalse("a fresh session is closed", session.isOpen)
        assertNull("no action is owed before opening", session.select(item))

        assertTrue(session.open())
        assertFalse("the same open cannot be started twice", session.open())
        assertTrue(session.isOpen)
        assertEquals("the selected row is returned after closing", item, session.select(item))
        assertFalse("selection closes the session first", session.isOpen)
        assertNull("a second tap cannot run another action for this open", session.select(item))

        assertTrue("reopening starts a new session", session.open())
        assertEquals(item, session.select(item))
        assertTrue(session.open())
        session.dismiss()
        assertFalse(session.isOpen)
        assertNull(session.select(item))
    }

    @Test
    fun `an unknown surface fails loud`() {
        try {
            ContextMenuModel.items("notASurface", allTrueState())
            fail("an unknown surface id must not silently produce an empty menu")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message.orEmpty().contains("notASurface"))
        }
    }

    private fun allTrueState(botHidden: Boolean = false): ContextMenuRowState =
        ContextMenuRowState(
            TokenContextMenuWhen.entries.associateWith { true },
            botHidden = botHidden,
        )

    private fun goldenSurfaces(): List<JsonObject> =
        golden.array("surfaces").values.map { it as JsonObject }

    private fun goldenSurface(surfaceId: String): JsonObject =
        goldenSurfaces().single { it.text("id") == surfaceId }

    private fun goldenItems(surface: JsonObject): List<JsonObject> =
        surface.array("items").values.map { it as JsonObject }

    private fun JsonObject.text(key: String): String = (this[key] as JsonString).value

    private fun JsonObject.array(key: String): JsonArray = this[key] as JsonArray
}
