// The six frozen interaction groups equal spec/ui/v1/tokens.json, and the
// pure-projection goldens are recomputed from the generated values.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.theme

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.theme.generated.Measured
import com.phonedsh.ui.theme.generated.TokenColor
import com.phonedsh.ui.theme.generated.TokenContextMenuItem
import com.phonedsh.ui.theme.generated.TokenContextMenuKind
import com.phonedsh.ui.theme.generated.TokenContextMenuRole
import com.phonedsh.ui.theme.generated.TokenContextMenuSurface
import com.phonedsh.ui.theme.generated.TokenContextMenuWhen
import com.phonedsh.ui.theme.generated.TokenDetent
import com.phonedsh.ui.theme.generated.TokenDetentSet
import com.phonedsh.ui.theme.generated.TokenDetentSetId
import com.phonedsh.ui.theme.generated.TokenGeometry
import com.phonedsh.ui.theme.generated.TokenMotion
import com.phonedsh.ui.theme.generated.TokenSheetPageDetent
import com.phonedsh.ui.theme.generated.UiTokenData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InteractionTokensTest {
    private val tokens: JsonObject = SpecFixtures.tokens
    private val interaction: JsonObject = tokens["interaction"] as JsonObject

    @Test
    fun `all six frozen interaction groups are required and generated`() {
        listOf("sheet", "contextMenu", "push", "composerSend", "pressed", "disclosure").forEach { name ->
            assertTrue("interaction.$name must exist in tokens.json", name in interaction.members)
        }
        val resolved = UiTokens.resolve(dark = false)
        assertEquals(UiTokenData.sheet, resolved.sheet)
        assertEquals(UiTokenData.contextMenu, resolved.contextMenu)
        assertEquals(UiTokenData.push, resolved.push)
        assertEquals(UiTokenData.composerSend, resolved.composerSend)
        assertEquals(UiTokenData.pressed, resolved.pressed)
        assertEquals(UiTokenData.disclosure, resolved.disclosure)
    }

    @Test
    fun `sheet group equals tokens json`() {
        val json = group("sheet")
        assertEquals(json.paramText("defaultDetents"), UiTokenData.sheet.defaultDetents.spec)
        assertMeasured(json.obj("mediumFraction"), UiTokenData.sheet.mediumFraction)

        val detentSets = json.array("detentSets").values.map { raw ->
            val row = raw as JsonObject
            TokenDetentSet(
                id = TokenDetentSetId.entries.single { it.spec == row.text("id") },
                detents = TokenDetent.entries.single { it.spec == row.text("detents") },
            )
        }
        assertEquals(detentSets, UiTokenData.sheet.detentSets)

        val pageDetents = json.array("pageDetents").values.map { raw ->
            val row = raw as JsonObject
            TokenSheetPageDetent(
                id = row.text("id"),
                detents = TokenDetentSetId.entries.single { it.spec == row.text("detents") },
            )
        }
        assertEquals(pageDetents, UiTokenData.sheet.pageDetents)

        assertEquals(json.paramText("grabberVisible"), UiTokenData.sheet.grabberVisible.spec)
        assertEquals(json.paramText("grabberHidden"), UiTokenData.sheet.grabberHidden.spec)
        assertColorRef(json.obj("background"), UiTokenData.sheet.background)
        assertEquals(json.paramText("backgroundClear"), UiTokenData.sheet.backgroundClear.spec)
        assertMeasured(json.obj("cornerRadiusDefault"), UiTokenData.sheet.cornerRadiusDefault)
        assertEquals(json.paramNumber("cornerRadiusConnector"), UiTokenData.sheet.cornerRadiusConnector.value, 0f)
        assertEquals(json.paramNumber("cornerRadiusCatalog"), UiTokenData.sheet.cornerRadiusCatalog.value, 0f)
        assertMeasured(json.obj("presentMotion"), UiTokenData.sheet.presentMotion)
        assertMeasured(json.obj("dismissMotion"), UiTokenData.sheet.dismissMotion)
    }

    @Test
    fun `context menu group equals tokens json`() {
        val json = group("contextMenu")
        assertEquals(json.paramText("preview"), UiTokenData.contextMenu.preview.spec)
        val surfaces = json.array("surfaces").values.map { raw ->
            val row = raw as JsonObject
            TokenContextMenuSurface(
                id = row.text("id"),
                items = row.array("items").values.map { itemRaw ->
                    val item = itemRaw as JsonObject
                    TokenContextMenuItem(
                        label = item.text("label"),
                        altLabel = item.textOrNull("altLabel"),
                        role = TokenContextMenuRole.entries.single { it.spec == item.text("role") },
                        kind = TokenContextMenuKind.entries.single { it.spec == item.text("kind") },
                        whenCondition = TokenContextMenuWhen.entries.single { it.spec == item.text("when") },
                        dividerBefore = (item["dividerBefore"] as? JsonBool)?.value ?: false,
                    )
                },
            )
        }
        assertEquals(surfaces, UiTokenData.contextMenu.surfaces)
    }

    @Test
    fun `push group equals tokens json`() {
        val json = group("push")
        assertEquals(json.paramText("stackScope"), UiTokenData.push.stackScope.spec)
        assertEquals(json.paramText("rootBack"), UiTokenData.push.rootBack.spec)
        assertEquals(
            json.paramText("backOrder").split(",").map { it.trim() },
            UiTokenData.push.backOrder.map { it.spec },
        )
        assertEquals(json.paramBool("barVisibleAtRoot"), UiTokenData.push.barVisibleAtRoot)
        assertEquals(json.paramBool("barHiddenWhenPushed"), UiTokenData.push.barHiddenWhenPushed)
        assertEquals(json.paramText("predictiveBack"), UiTokenData.push.predictiveBack.spec)
        assertMeasured(json.obj("systemMotion"), UiTokenData.push.systemMotion)
    }

    @Test
    fun `composer send group equals tokens json`() {
        val json = group("composerSend")
        assertMotionRef(json.obj("motion"), UiTokenData.composerSend.motion)
        assertEquals(json.paramNumber("transitionScale"), UiTokenData.composerSend.transitionScale, 0f)
        assertEquals(json.paramNumber("transitionOpacity"), UiTokenData.composerSend.transitionOpacity, 0f)
        assertGeometryRef(json.obj("buttonSize"), UiTokenData.composerSend.buttonSize)
        assertColorRef(json.obj("enabledFill"), UiTokenData.composerSend.enabledFill)
        assertColorRef(json.obj("disabledFill"), UiTokenData.composerSend.disabledFill)
        assertColorRef(json.obj("enabledInk"), UiTokenData.composerSend.enabledInk)
        assertColorRef(json.obj("disabledInk"), UiTokenData.composerSend.disabledInk)
        assertEquals(json.paramText("disabledRule"), UiTokenData.composerSend.disabledRule.spec)
        assertEquals(json.paramText("stopRule"), UiTokenData.composerSend.stopRule.spec)
    }

    @Test
    fun `pressed group equals tokens json`() {
        val json = group("pressed")
        assertMotionRef(json.obj("motion"), UiTokenData.pressed.motion)
        assertEquals(json.paramNumber("pillOverlay"), UiTokenData.pressed.pillOverlay, 0f)
        assertEquals(json.paramText("pillOverlayColor"), UiTokenData.pressed.pillOverlayColor.spec)
        assertColorRef(json.obj("rowFill"), UiTokenData.pressed.rowFill)
        assertEquals(json.paramNumber("rowFillOpacity"), UiTokenData.pressed.rowFillOpacity, 0f)
        assertEquals(json.paramNumber("primaryPressedOpacity"), UiTokenData.pressed.primaryPressedOpacity, 0f)
        assertEquals(json.paramNumber("primaryDisabledOpacity"), UiTokenData.pressed.primaryDisabledOpacity, 0f)
        assertEquals(json.paramNumber("scale"), UiTokenData.pressed.scale, 0f)
    }

    @Test
    fun `disclosure group equals tokens json`() {
        val json = group("disclosure")
        assertMotionRef(json.obj("bodyMotion"), UiTokenData.disclosure.bodyMotion)
        assertMotionRef(json.obj("folderMotion"), UiTokenData.disclosure.folderMotion)
        assertMotionRef(json.obj("chevronMotion"), UiTokenData.disclosure.chevronMotion)
        assertEquals(json.paramText("reducedMotion"), UiTokenData.disclosure.reducedMotion.spec)
    }

    @Test
    fun `new motion tokens flow through the generated and resolved motion path`() {
        val specMotion = tokens["motion"] as JsonObject
        for (name in listOf("pressed", "folderCollapse", "chevron")) {
            val entry = specMotion[name] as JsonObject
            val generated = UiTokenData.motion.getValue("motion.$name")
            assertEquals("motion.$name duration", entry.number("durationMs").toInt(), generated.durationMs)
            assertEquals("motion.$name curve", entry.text("curve"), generated.curve)
            assertEquals("motion.$name repeat", entry.text("repeat"), generated.repeat)
        }
        val motion = UiTokens.resolve(dark = false).motion
        assertEquals(UiTokenData.motionPressed.durationMs, motion.pressedMs)
        assertEquals(UiTokenData.motionPressed.curve, motion.pressedCurve)
        assertEquals(UiTokenData.motionFolderCollapse.durationMs, motion.folderCollapseMs)
        assertEquals(UiTokenData.motionFolderCollapse.curve, motion.folderCollapseCurve)
        assertEquals(UiTokenData.motionChevron.durationMs, motion.chevronMs)
        assertEquals(UiTokenData.motionChevron.curve, motion.chevronCurve)
        // Every new curve name is one of the three the theme knows, and every
        // motion token in the spec resolves through the same path.
        listOf(motion.pressedEasing, motion.folderCollapseEasing, motion.chevronEasing).forEach { easing ->
            assertTrue(easing is androidx.compose.animation.core.CubicBezierEasing)
        }
        specMotion.members.values.forEach { raw ->
            motion.easing((raw as JsonObject).text("curve"))
        }
    }

    @Test
    fun `sheet detents golden is recomputed from the generated table`() {
        val golden = SpecFixtures.repoJson("spec/ui/v1/golden/sheet-detents.golden.json")
        assertEquals(golden.text("defaultDetents"), UiTokenData.sheet.defaultDetents.spec)
        assertEquals(
            golden.array("detentSets").values.map { (it as JsonString).value }.sorted(),
            UiTokenData.sheet.detentSets.map { it.id.spec }.sorted(),
        )
        val expectedPages = golden.array("pages").values.map { raw ->
            val page = raw as JsonObject
            page.text("id") to page.text("detents")
        }
        val actualPages = UiTokenData.sheet.pageDetents.map { it.id to it.detents.spec }
        assertEquals(expectedPages, actualPages)
    }

    @Test
    fun `context menu golden is recomputed from the generated table`() {
        val golden = SpecFixtures.repoJson("spec/ui/v1/golden/context-menu-items.golden.json")
        assertEquals(golden.text("preview"), UiTokenData.contextMenu.preview.spec)
        val expected = golden.array("surfaces").values.map { raw ->
            val surface = raw as JsonObject
            surface.text("id") to surface.array("items").values.map { itemRaw ->
                val item = itemRaw as JsonObject
                Triple(item.text("label"), item.text("role"), item.text("kind"))
            }
        }
        val actual = UiTokenData.contextMenu.surfaces.map { surface ->
            surface.id to surface.items.map { Triple(it.label, it.role.spec, it.kind.spec) }
        }
        assertEquals(expected, actual)
    }

    @Test
    fun `disclosure motion golden is recomputed from the generated table`() {
        val golden = SpecFixtures.repoJson("spec/ui/v1/golden/disclosure-motion.golden.json")
        assertEquals(golden.text("reducedMotion"), UiTokenData.disclosure.reducedMotion.spec)
        golden.array("rows").values.forEach { raw ->
            val row = raw as JsonObject
            val generated = when (row.text("id")) {
                "body" -> UiTokenData.disclosure.bodyMotion
                "folder" -> UiTokenData.disclosure.folderMotion
                "chevron" -> UiTokenData.disclosure.chevronMotion
                else -> error("unknown disclosure-motion row '${row.text("id")}'")
            }
            assertEquals(row.text("motion"), generated.name)
            assertEquals(row.number("durationMs").toInt(), generated.durationMs)
            assertEquals(row.text("curve"), generated.curve)
        }
    }

    @Test
    fun `pressed states golden is recomputed from the generated table`() {
        val golden = SpecFixtures.repoJson("spec/ui/v1/golden/pressed-states.golden.json")
        val pressed = UiTokenData.pressed
        golden.array("rows").values.forEach { raw ->
            val row = raw as JsonObject
            val (rest, pressedValue, disabled) = when (row.text("id")) {
                "drawerPill" -> Triple(0f, pressed.pillOverlay, null)
                "drawerRow" -> Triple(0f, pressed.rowFillOpacity, null)
                "primaryButton" -> Triple(1f, pressed.primaryPressedOpacity, pressed.primaryDisabledOpacity)
                else -> error("unknown pressed-states row '${row.text("id")}'")
            }
            assertEquals(row.text("id"), row.number("rest"), rest, 0f)
            assertEquals(row.text("id"), row.number("pressed"), pressedValue, 0f)
            val expectedDisabled = (row["disabled"] as? JsonNumber)?.raw?.toFloat()
            if (expectedDisabled == null) {
                assertNull(row.text("id"), disabled)
            } else {
                assertEquals(row.text("id"), expectedDisabled, disabled!!, 0f)
            }
            assertEquals(row.text("id"), row.number("scale"), pressed.scale, 0f)
        }
    }

    @Test
    fun `push back golden inputs exist in the generated push group`() {
        val golden = SpecFixtures.repoJson("spec/ui/v1/golden/push-back.golden.json")
        val push = UiTokenData.push
        assertEquals(listOf("sheet", "drawer", "stack", "root"), push.backOrder.map { it.spec })
        assertEquals("perTab", push.stackScope.spec)
        assertEquals("exit", push.rootBack.spec)
        assertEquals("allowed", push.predictiveBack.spec)
        assertTrue(push.barVisibleAtRoot)
        assertTrue(push.barHiddenWhenPushed)
        assertMeasured(group("push").obj("systemMotion"), push.systemMotion)
        val goldenLayers = golden.array("cases").values.flatMap { raw ->
            val overlay = (raw as JsonObject).text("overlay")
            overlay.split(",").map { it.trim() }.filter { it != "none" }
        }.toSet()
        assertTrue("every golden overlay layer must be in backOrder", goldenLayers.all { it in push.backOrder.map { layer -> layer.spec } })
    }

    @Test
    fun `composer send golden inputs exist in the generated composerSend group`() {
        val golden = SpecFixtures.repoJson("spec/ui/v1/golden/composer-send.golden.json")
        val composer = UiTokenData.composerSend
        assertEquals(golden.number("transitionScale"), composer.transitionScale, 0f)
        assertEquals(golden.number("transitionOpacityFrom"), composer.transitionOpacity, 0f)
        assertEquals(golden.number("buttonSize"), composer.buttonSize.value, 0f)
        assertEquals("motion.composerSend", composer.motion.name)
        assertEquals("canSubmit", composer.disabledRule.spec)
        assertEquals("!canSubmit && model.turnRunning", composer.stopRule.spec)
        assertEquals("colors.primaryButton", composer.enabledFill.name)
        assertEquals("colors.primaryButtonInk", composer.enabledInk.name)
        assertEquals("colors.userBubble", composer.disabledFill.name)
        assertEquals("colors.iconMuted", composer.disabledInk.name)
        assertTrue("golden must carry canSubmit cases", (golden["cases"] as JsonArray).values.isNotEmpty())
    }

    private fun group(name: String): JsonObject = interaction[name] as JsonObject

    private fun assertColorRef(entry: JsonObject, generated: TokenColor) {
        val name = entry.text("token")
        assertEquals(name, generated.name)
        assertEquals(UiTokenData.colors.getValue(name), generated)
    }

    private fun assertGeometryRef(entry: JsonObject, generated: TokenGeometry) {
        val name = entry.text("token")
        assertEquals(name, generated.name)
        assertEquals(UiTokenData.geometry.getValue(name), generated)
    }

    private fun assertMotionRef(entry: JsonObject, generated: TokenMotion) {
        val name = entry.text("token")
        assertEquals(name, generated.name)
        assertEquals(UiTokenData.motion.getValue(name), generated)
    }

    private fun assertMeasured(entry: JsonObject, measured: Measured<*>) {
        assertTrue("${entry.members.keys} must set needsDeviceMeasure", entry.bool("needsDeviceMeasure"))
        assertNull(entry["value"])
        val unmeasured = measured as Measured.Unmeasured
        assertEquals(entry.text("unit"), unmeasured.unit)
        assertEquals(entry.textOrNull("note"), unmeasured.note)
    }

    private fun JsonObject.paramText(key: String): String = obj(key).text("value")
    private fun JsonObject.paramNumber(key: String): Float = obj(key).number("value")
    private fun JsonObject.paramBool(key: String): Boolean = obj(key).bool("value")
    private fun JsonObject.obj(key: String): JsonObject = this[key] as JsonObject
    private fun JsonObject.array(key: String): JsonArray = this[key] as JsonArray
    private fun JsonObject.text(key: String): String = (this[key] as JsonString).value
    private fun JsonObject.textOrNull(key: String): String? = (this[key] as? JsonString)?.value
    private fun JsonObject.number(key: String): Float = (this[key] as JsonNumber).raw.toFloat()
    private fun JsonObject.bool(key: String): Boolean = (this[key] as JsonBool).value
}
