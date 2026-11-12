// Shared composer-send golden, read from the repository at test time.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/golden/composer-send.golden.json` is the shared fixture; no case
// is copied into Kotlin. Every row runs through the same pure §5 rule object the
// composables use.
package com.phonedsh.ui.composer

import androidx.compose.ui.unit.dp
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.UiTokens
import com.phonedsh.ui.theme.generated.UiTokenData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `interaction.md` §5's truth table, labels, transition values and fill roles.
 *
 * The golden's `showsStop` is the slot flag: true only when the stop key
 * replaces the send key. Rule 1's third state (`BOTH`) is asserted separately:
 * while a turn runs and the draft can be submitted, both keys are visible.
 */
class UiComposerSendContractTest {
    private val golden: JsonObject by lazy {
        SpecFixtures.repoJson("spec/ui/v1/golden/composer-send.golden.json")
    }

    @Test
    fun `golden header matches the generated composerSend token group`() {
        assertEquals("composer-send", golden.text("kind"))
        assertEquals(1, golden.number("version").toInt())
        val tokens = UiTokenData.composerSend
        assertEquals(tokens.transitionScale.toDouble(), golden.number("transitionScale"), 1e-6)
        assertEquals(tokens.transitionOpacity.toDouble(), golden.number("transitionOpacityFrom"), 1e-6)
        assertEquals(tokens.buttonSize.value.toDouble(), golden.number("buttonSize"), 1e-6)
        assertEquals("buttonSize is geometry.sendButton", UiTokenData.geometrySendButton, tokens.buttonSize)
        assertEquals("motion is motion.composerSend", UiTokenData.motionComposerSend, tokens.motion)
    }

    @Test
    fun `every golden case matches canSubmit and layout`() {
        val seen = mutableSetOf<String>()
        cases().forEach { case ->
            val id = case.text("id")
            assertTrue("duplicate golden case '$id'", seen.add(id))
            val turnRunning = case.bool("turnRunning")
            val canSubmit = ComposerSendRule.canSubmit(
                composerEnabled = case.bool("composerEnabled"),
                steer = case.bool("steer"),
                hasText = case.bool("hasText"),
                hasAttachments = case.bool("hasAttachments"),
                turnRunning = turnRunning,
            )
            assertEquals("$id: canSubmit", case.bool("canSubmit"), canSubmit)

            val layout = ComposerSendRule.layout(turnRunning = turnRunning, canSubmit = canSubmit)
            assertEquals("$id: showsSend", case.bool("showsSend"), layout.sendVisible)
            assertEquals(
                "$id: showsStop is the stop-replaces-send slot",
                case.bool("showsStop"),
                layout.stopOnly,
            )
            assertEquals("$id: stop visible whenever a turn runs", turnRunning, layout.stopVisible)
            assertEquals(
                "$id: both only while running and submittable",
                turnRunning && canSubmit,
                layout == ComposerSendLayout.BOTH,
            )
        }
        assertEquals("every golden row ran", cases().size, seen.size)
    }

    @Test
    fun `layout names rule 1's three states`() {
        assertEquals(ComposerSendLayout.SEND, ComposerSendRule.layout(turnRunning = false, canSubmit = false))
        assertEquals(ComposerSendLayout.SEND, ComposerSendRule.layout(turnRunning = false, canSubmit = true))
        assertEquals(ComposerSendLayout.STOP, ComposerSendRule.layout(turnRunning = true, canSubmit = false))
        assertEquals(ComposerSendLayout.BOTH, ComposerSendRule.layout(turnRunning = true, canSubmit = true))
        assertTrue(ComposerSendLayout.BOTH.stopVisible)
        assertTrue(ComposerSendLayout.BOTH.sendVisible)
        assertFalse(ComposerSendLayout.SEND.stopVisible)
        assertFalse(ComposerSendLayout.STOP.sendVisible)
    }

    @Test
    fun `rule 7 labels are the verbatim interaction strings`() {
        assertEquals("发送消息", ComposerSendRule.sendLabel(turnRunning = false, steer = false))
        assertEquals("发送消息", ComposerSendRule.sendLabel(turnRunning = false, steer = true))
        assertEquals("补充当前任务", ComposerSendRule.sendLabel(turnRunning = true, steer = true))
        assertEquals("排入下一轮", ComposerSendRule.sendLabel(turnRunning = true, steer = false))
        assertEquals("停止执行", ComposerSendRule.stopLabel(stopping = false))
        assertEquals("正在停止", ComposerSendRule.stopLabel(stopping = true))

        // The component reuses the existing UiStrings resources, not copies.
        assertEquals(UiStrings.COMPOSER_SEND_LABEL, ComposerSendRule.sendLabel(false, false))
        assertEquals(UiStrings.COMPOSER_SEND_LABEL_STEER, ComposerSendRule.sendLabel(true, true))
        assertEquals(UiStrings.COMPOSER_SEND_LABEL_QUEUE, ComposerSendRule.sendLabel(true, false))
        assertEquals(UiStrings.COMPOSER_STOP_LABEL, ComposerSendRule.stopLabel(false))
        assertEquals(UiStrings.COMPOSER_STOPPING, ComposerSendRule.stopLabel(true))
    }

    @Test
    fun `rule 1 gap has no token member and reuses the reviewed Android metric`() {
        val interaction = SpecFixtures.tokens["interaction"] as JsonObject
        val composer = interaction["composerSend"] as JsonObject
        assertFalse(
            "interaction.composerSend has no gap member; a token would replace the metric reuse",
            "stopGap" in composer.members,
        )
        assertEquals(ChatMetrics.COMPOSER_ACTION_GAP_PT.dp, ComposerSendRule.STOP_SEND_GAP)
        assertEquals(8f, ComposerSendRule.STOP_SEND_GAP.value, 0f)
    }

    @Test
    fun `rule 4 scale and opacity start at the token transition values and settle at one`() {
        val tokens = UiTokenData.composerSend
        assertEquals(tokens.transitionScale, ComposerSendRule.transitionScale(0f), 0f)
        assertEquals(tokens.transitionOpacity, ComposerSendRule.transitionAlpha(0f), 0f)
        assertEquals(1f, ComposerSendRule.transitionScale(1f), 0f)
        assertEquals(1f, ComposerSendRule.transitionAlpha(1f), 0f)
        assertEquals(0.8f, tokens.transitionScale, 0f)
        assertEquals(0f, tokens.transitionOpacity, 0f)
        // Out-of-range progress must not overshoot the two frozen appearances.
        assertEquals(tokens.transitionScale, ComposerSendRule.transitionScale(-1f), 0f)
        assertEquals(1f, ComposerSendRule.transitionAlpha(2f), 0f)
    }

    @Test
    fun `rule 3 fill and ink references resolve from the generated group`() {
        val composer = UiTokenData.composerSend
        assertEquals(UiTokenData.colorPrimaryButton, composer.enabledFill)
        assertEquals(UiTokenData.colorPrimaryButtonInk, composer.enabledInk)
        assertEquals(UiTokenData.colorUserBubble, composer.disabledFill)
        assertEquals(UiTokenData.colorIconMuted, composer.disabledInk)

        listOf(false, true).forEach { dark ->
            val colors = UiTokens.resolve(dark).colors
            val palette = composerSendPalette(composer, dark)
            assertEquals("enabledFill (dark=$dark)", colors.primaryButton, palette.enabledFill)
            assertEquals("enabledInk (dark=$dark)", colors.primaryButtonInk, palette.enabledInk)
            assertEquals("disabledFill (dark=$dark)", colors.userBubble, palette.disabledFill)
            assertEquals("disabledInk (dark=$dark)", colors.iconMuted, palette.disabledInk)
        }
    }

    private fun cases(): List<JsonObject> =
        (golden["cases"] as JsonArray).values.map { it as JsonObject }

    private fun JsonObject.text(key: String): String = (this[key] as JsonString).value

    private fun JsonObject.number(key: String): Double = (this[key] as JsonNumber).raw.toDouble()

    private fun JsonObject.bool(key: String): Boolean = (this[key] as JsonBool).value
}
