// Shared sheet contract, spec/ui/v1/interaction.md §2.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.sheet

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.theme.UiTokens
import com.phonedsh.ui.theme.generated.TokenDetent
import com.phonedsh.ui.theme.generated.TokenDetentSetId
import com.phonedsh.ui.theme.generated.UiTokenData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `spec/ui/v1/golden/sheet-detents.golden.json` is the shared fixture; no row is
 * copied into Kotlin. Every golden row runs through [SheetDetents], and the
 * chrome presets are checked against the generated `interaction.sheet` values.
 */
class UiSheetContractTest {
    private val golden: JsonObject by lazy {
        SpecFixtures.repoJson("spec/ui/v1/golden/sheet-detents.golden.json")
    }

    @Test
    fun `every golden page row maps to its frozen detent set`() {
        golden.array("pages").values.forEach { raw ->
            val page = raw as JsonObject
            val id = page.text("id")
            val expected = page.text("detents")
            assertEquals(
                "$id: pageDetents mapping",
                expected,
                SheetDetents.forPage(id).spec,
            )
            assertEquals(
                "$id: anchor set",
                expectedAnchors(expected),
                SheetDetents.detents(SheetDetents.forPage(id)),
            )
        }
    }

    @Test
    fun `an unknown page uses the golden default detents`() {
        val default = golden.text("defaultDetents")
        assertEquals(default, SheetDetents.forPage("not-a-contract-page").spec)
        assertEquals(default, SheetDetents.forPage(null).spec)
        assertEquals(default, SheetDetents.forPage("").spec)
        assertEquals(default, UiTokenData.sheet.defaultDetents.spec)
    }

    @Test
    fun `every golden detent set row is generated and resolves an anchor`() {
        val generatedIds = UiTokenData.sheet.detentSets.map { it.id.spec }
        golden.array("detentSets").values.forEach { raw ->
            val id = (raw as JsonString).value
            assertTrue("$id must be a generated detent set", id in generatedIds)
            val setId = TokenDetentSetId.entries.single { it.spec == id }
            assertTrue("$id: at least one anchor", SheetDetents.detents(setId).isNotEmpty())
            // Rule 3: the anchor set, not a fraction, decides partial expansion.
            assertEquals(
                "$id: partial expansion follows the medium anchor",
                TokenDetent.MEDIUM in SheetDetents.detents(setId),
                !SheetDetents.skipPartiallyExpanded(setId),
            )
        }
        assertEquals(
            setOf("medium", "mediumLarge"),
            golden.array("detentSets").values
                .map { (it as JsonString).value }
                .filterNot { SheetDetents.skipPartiallyExpanded(id(it)) }
                .toSet(),
        )
    }

    @Test
    fun `medium pages expose only the platform partial anchor`() {
        golden.array("pages").values.forEach { raw ->
            val page = raw as JsonObject
            val anchors = SheetDetents.detents(SheetDetents.forPage(page.text("id")))
            when (page.text("detents")) {
                "medium" -> assertEquals(listOf(TokenDetent.MEDIUM), anchors)
                "mediumLarge" -> assertEquals(listOf(TokenDetent.MEDIUM, TokenDetent.LARGE), anchors)
                "large", "default" -> assertEquals(listOf(TokenDetent.LARGE), anchors)
                else -> error("${page.text("id")}: unknown detent set '${page.text("detents")}'")
            }
        }
    }

    @Test
    fun `system chrome has no explicit grabber background or radius`() {
        val tokens = UiTokens.resolve(dark = false)
        val chrome = SheetChrome()
        assertEquals(SheetGrabber.SYSTEM_DEFAULT, chrome.grabber)
        assertEquals(SheetBackground.SYSTEM_DEFAULT, chrome.background)
        assertEquals(SheetCornerRadius.SYSTEM_DEFAULT, chrome.cornerRadius)
        assertFalse("rule 4: the system default is hidden", chrome.grabberVisible())
        assertNull("rule 5: no explicit fill", chrome.containerColor(tokens))
        assertNull("rule 6: no measured radius guess", chrome.cornerRadiusDp(tokens))
    }

    @Test
    fun `home chrome uses the visible grabber and page background only`() {
        val tokens = UiTokens.resolve(dark = false)
        val chrome = SheetChrome.HomeSheet
        assertTrue(chrome.grabberVisible())
        assertEquals(SheetBackground.PAGE, chrome.background)
        assertEquals(tokens.colors.page, chrome.containerColor(tokens))
        assertEquals(SheetBackground.PAGE, chrome.background)
        assertNull("rule 6: homeSheetChrome does not override the radius", chrome.cornerRadiusDp(tokens))
    }

    @Test
    fun `connector chrome uses page background and the connector radius token`() {
        val tokens = UiTokens.resolve(dark = false)
        val chrome = SheetChrome.Connectors
        assertTrue(chrome.grabberVisible())
        assertEquals(tokens.colors.page, chrome.containerColor(tokens))
        assertEquals(tokens.sheet.cornerRadiusConnector, chrome.cornerRadiusDp(tokens))
    }

    @Test
    fun `catalog chrome hides the grabber clears the background and uses the catalog radius`() {
        val tokens = UiTokens.resolve(dark = true)
        val chrome = SheetChrome.SubagentCatalog
        assertFalse(chrome.grabberVisible())
        assertEquals(androidx.compose.ui.graphics.Color.Transparent, chrome.containerColor(tokens))
        assertEquals(tokens.sheet.cornerRadiusCatalog, chrome.cornerRadiusDp(tokens))
    }

    @Test
    fun `back dispatch acts on the top sheet and never a lower one`() {
        val host = SheetBackHost()
        var lowerDismissals = 0
        var topDismissals = 0
        val lower = SheetBackHost.Entry({ false }, { lowerDismissals++ })
        val top = SheetBackHost.Entry({ false }, { topDismissals++ })

        host.register(lower)
        host.register(top)
        assertTrue(host.hasSheet)
        assertTrue("the top sheet consumes the gesture", host.dispatch())
        assertEquals(1, topDismissals)
        assertEquals(0, lowerDismissals)

        // A second back while the top sheet is still leaving is still the same
        // level, so it cannot close the lower sheet.
        assertTrue(host.dispatch())
        assertEquals(1, topDismissals)
        assertEquals(0, lowerDismissals)

        host.unregister(top)
        assertTrue(host.dispatch())
        assertEquals(1, lowerDismissals)
        host.unregister(lower)
        assertFalse("no sheet owns the layer", host.dispatch())
        assertFalse(host.hasSheet)
    }

    @Test
    fun `an inner navigation stack pops before the sheet dismisses`() {
        val host = SheetBackHost()
        var pops = 0
        var dismissals = 0
        val entry = SheetBackHost.Entry(
            popInner = {
                pops += 1
                pops == 1
            },
            dismiss = { dismissals++ },
        )
        host.register(entry)

        assertTrue(host.dispatch())
        assertEquals("the inner stack receives the first step", 1, pops)
        assertEquals("the sheet stays open at the inner root", 0, dismissals)

        assertTrue(host.dispatch())
        assertEquals("the root step dismisses the sheet", 2, pops)
        assertEquals(1, dismissals)
    }

    private fun id(spec: String): TokenDetentSetId =
        TokenDetentSetId.entries.single { it.spec == spec }

    /** Rule 2's four sets translated to their platform anchors. */
    private fun expectedAnchors(spec: String): List<TokenDetent> = when (spec) {
        "default", "large" -> listOf(TokenDetent.LARGE)
        "medium" -> listOf(TokenDetent.MEDIUM)
        "mediumLarge" -> listOf(TokenDetent.MEDIUM, TokenDetent.LARGE)
        else -> error("unknown detent set '$spec'")
    }

    private fun JsonObject.text(key: String): String = (this[key] as JsonString).value

    private fun JsonObject.array(key: String): JsonArray = this[key] as JsonArray
}
