// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.ui.SpecFixtures
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the real Kotlin model/controller with the frozen
 * `spec/ui/v1/bot/fish/golden/trajectory.json` (97 cases, 954 frames).
 *
 * The fixture is read from disk through `pdsh.repo.root` (set by :lib's build
 * script); no vector is copied into this file.
 */
class BotFishTrajectoryGoldenTest {
    private val trajectory: JsonObject by lazy {
        SpecFixtures.repoJson("spec/ui/v1/bot/fish/golden/trajectory.json")
    }

    private val tolerance: Double by lazy {
        trajectory.obj("tolerances").number("params")
    }

    @Test
    fun `clip table matches all 42 frozen rows`() {
        val clips = trajectory.obj("clips")
        assertEquals(42, clips.members.size)
        for (lifecycle in BotFishLifecycle.entries) {
            val expected = clips.obj(lifecycle.wire)
            val actual = BotFishClip.forState(lifecycle)
            assertEquals("${lifecycle.wire}.period", expected.nullableNumber("period"), actual.period)
            assertEquals("${lifecycle.wire}.duration", expected.nullableNumber("duration"), actual.duration)
            assertEquals("${lifecycle.wire}.isStatic", expected.bool("isStatic"), actual.isStatic)
        }
    }

    @Test
    fun `sprite order and geometry match the frozen constants`() {
        val spriteOrder = trajectory.obj("spriteOrder")
        assertEquals(
            (spriteOrder["eyes"] as JsonArray).values.map { (it as JsonString).value },
            BotFishEyeCel.names,
        )
        assertEquals(
            (spriteOrder["mouths"] as JsonArray).values.map { (it as JsonString).value },
            BotFishMouthCel.names,
        )

        val geometry = trajectory.obj("geometry")
        assertEquals(BotFishGeometry.DESIGN_CANVAS, geometry.number("designCanvas"), 0.0)
        assertEquals(BotFishGeometry.PAD, geometry.number("pad"), 0.0)
        assertEquals(BotFishGeometry.DESIGN_SCALE, geometry.number("designScale"), 0.0)
        val crop = geometry.obj("crop")
        assertEquals(BotFishGeometry.CROP_X, (crop["origin"] as JsonArray).values[0].number(), 0.0)
        assertEquals(BotFishGeometry.CROP_Y, (crop["origin"] as JsonArray).values[1].number(), 0.0)
        assertEquals(BotFishGeometry.CROP_SIDE, crop.number("side"), 0.0)
        val crownedCrop = geometry.obj("crownedCrop")
        assertEquals(BotFishGeometry.CROWNED_CROP_X, (crownedCrop["origin"] as JsonArray).values[0].number(), 0.0)
        assertEquals(BotFishGeometry.CROWNED_CROP_Y, (crownedCrop["origin"] as JsonArray).values[1].number(), 0.0)
        assertEquals(BotFishGeometry.CROWNED_CROP_SIDE, crownedCrop.number("side"), 0.0)
        val boost = geometry.obj("motionBoost")
        assertEquals(BotFishGeometry.MOTION_BOOST_SMALL_SIZE, boost.number("smallSize"), 0.0)
        assertEquals(BotFishGeometry.MOTION_BOOST_LARGE_SIZE, boost.number("largeSize"), 0.0)
        assertEquals(BotFishGeometry.MOTION_BOOST_FACTOR, boost.number("factor"), 0.0)
        assertEquals(BotFishGeometry.MOTION_BOOST_MAX_TRANSLATION, boost.number("maxTranslation"), 0.0)
        assertEquals(BotFishGeometry.MOTION_BOOST_MAX_ROLL, boost.number("maxRoll"), 0.0)
        val slicing = geometry.obj("headSlicing")
        assertEquals(BotFishGeometry.HEAD_SLICING_MINIMUM_SIZE, slicing.number("minimumSize"), 0.0)
        assertEquals(BotFishGeometry.LIVELY_HEAD_SLICING_MINIMUM_SIZE, slicing.number("livelyMinimumSize"), 0.0)
        assertEquals(BotFishGeometry.HEAD_SLICE_QUANTUM, slicing.number("quantum"), 0.0)
        assertEquals(BotFishGeometry.LIVELY_HEAD_SLICE_QUANTUM, slicing.number("livelyQuantum"), 0.0)

        val clock = trajectory.obj("frameClock")
        assertEquals(BotFishFrameClock.STANDARD_FPS, clock.int("standardFps"))
        assertEquals(BotFishFrameClock.STANDARD_SMALL_FPS, clock.int("standardSmallFps"))
        assertEquals(BotFishFrameClock.STANDARD_SMALL_MAX_SIZE_PT, clock.number("standardSmallMaxSizePt"), 0.0)
        assertEquals(BotFishFrameClock.LIVELY_FPS, clock.int("livelyFps"))
        assertEquals(BotFishFrameClock.DELTA_CLAMP_MS, clock.number("deltaClampMs"), 0.0)
        assertEquals(BotFishFrameClock.FREEZE_SAMPLE_MS, clock.number("freezeSampleMs"), 0.0)
        assertEquals(BotFishFrameClock.BLINK_DURATION_MS, clock.number("blinkDurationMs"), 0.0)
        assertEquals(BotFishFrameClock.POSE_SPRING_OMEGA, clock.number("poseSpringOmega"), 0.0)
        assertEquals(BotFishFrameClock.POSE_TRANSITION_MS, clock.number("poseTransitionMs"), 0.0)
    }

    @Test
    fun `all fifteen palettes reproduce the frozen LUT and ink colours`() {
        val palettes = (trajectory["palettes"] as JsonArray).values.map { it as JsonObject }
        assertEquals(15, palettes.size)
        for (entry in palettes) {
            val id = entry.str("id")
            val color = requireNotNull(BotFishColor.fromWire(id)) { "unknown colour $id" }
            val palette = BotFishPalette.forColor(color)
            assertEquals(entry.str("hex"), palette.hex)
            assertArrayEquals(
                "LUT for $id",
                (entry["lut"] as JsonArray).values.map { it.number().toInt() }.toIntArray(),
                palette.lut,
            )
            assertArrayEquals(
                "ink for $id",
                (entry["ink"] as JsonArray).values.map { it.number().toInt() }.toIntArray(),
                palette.ink,
            )
            assertArrayEquals(
                "mid for $id",
                (entry["mid"] as JsonArray).values.map { it.number().toInt() }.toIntArray(),
                palette.mid,
            )
            assertArrayEquals(
                "light for $id",
                (entry["light"] as JsonArray).values.map { it.number().toInt() }.toIntArray(),
                palette.light,
            )
        }
    }

    @Test
    fun `all 97 cases and 954 frames match within the frozen tolerance`() {
        val cases = (trajectory["cases"] as JsonArray).values.map { it as JsonObject }
        assertEquals(EXPECTED_CASE_NAMES, cases.map { it.str("name") }.toSet())
        assertEquals(97, cases.size)
        assertEquals(954, cases.sumOf { (it["frames"] as JsonArray).values.size })

        var framesChecked = 0
        for (case in cases) {
            framesChecked += runCase(case)
        }
        assertEquals(954, framesChecked)
    }

    private fun runCase(case: JsonObject): Int {
        val name = case.str("name")
        val state = requireNotNull(BotFishLifecycle.fromWire(case.str("state")))
        val appearanceJson = case.obj("appearance")
        val appearance = BotFishAppearance(
            color = requireNotNull(BotFishColor.fromWire(appearanceJson.str("color"))),
            hairstyle = requireNotNull(BotFishHairstyle.fromWire(appearanceJson.str("hairstyle"))),
        )
        val crowned = case.bool("crowned")
        val still = case.bool("still")
        val reduced = case.bool("reduced")
        val profile = when (case.str("motionProfile")) {
            "standard" -> BotFishMotionProfile.STANDARD
            "lively" -> BotFishMotionProfile.LIVELY
            else -> error("unknown motion profile")
        }
        val workStyle = when (case.str("workStyle")) {
            "generic" -> BotFishWorkStyle.GENERIC
            "reading" -> BotFishWorkStyle.READING
            "searching" -> BotFishWorkStyle.SEARCHING
            "running" -> BotFishWorkStyle.RUNNING
            "writing" -> BotFishWorkStyle.WRITING
            else -> error("unknown work style")
        }
        val viewport = case.obj("viewport")
        val sizePt = viewport.number("sizePt")
        val displayScale = viewport.number("displayScale")
        val pixelSide = viewport.int("pixelSide")
        val dtMs = case.number("dtMs")
        val steps = case.int("steps")
        val pokeAtStep = (case["pokeAtStep"] as? JsonNumber)?.asLongOrNull()?.toInt()

        val randomValues = (case["randomValues"] as JsonArray).values.map { it.number() }
        var randomIndex = 0
        val engine = BotFishEngine(random = {
            check(randomIndex < randomValues.size) {
                "$name consumed more random values than the frozen prefix"
            }
            randomValues[randomIndex++]
        })

        val reactionJson = case["reaction"] as? JsonObject
        val reactionStartStep = reactionJson?.int("startStep") ?: Int.MAX_VALUE
        val reaction = reactionJson?.let {
            val reactionName = it.str("name")
            BotFishReaction(
                id = "trajectory-$name",
                kind = when (it.str("kind")) {
                    "action" -> BotFishReactionKind.ACTION
                    "expression" -> BotFishReactionKind.EXPRESSION
                    else -> error("unknown reaction kind")
                },
                name = reactionName,
                durationMs = it.int("durationMs").toLong(),
            )
        }

        val sampleSteps = (case["sampleSteps"] as? JsonArray)
            ?.values
            ?.map { (it as JsonNumber).asLongOrNull()!!.toInt() }
            ?.toSet()
        val expectedFrames = (case["frames"] as JsonArray).values
            .map { it as JsonObject }
            .associateBy { it.int("step") }

        // The harness drives absolute timestamps (`base + step * dt`) and
        // derives each delta from the previous one. Reproducing that
        // subtraction matters at TTL edges such as 1 500/1 600 ms, where the
        // accumulated sum can land a few 1e-8 ms on either side.
        val defaultDt = 1000.0 / 60.0
        val gridDt = if (abs(dtMs - defaultDt) < 1e-9) defaultDt else dtMs
        val baseTimestamp = 1_000_000.0
        var previousTimestamp: Double? = null

        var checked = 0
        for (step in 0..steps) {
            val timestamp = baseTimestamp + step * gridDt / 1000.0
            val deltaMs = previousTimestamp?.let { previous ->
                min(100.0, max(0.0, (timestamp - previous) * 1000.0))
            } ?: 0.0
            previousTimestamp = timestamp
            if (pokeAtStep == step) engine.poke()
            val activeReaction = if (
                reaction != null && step >= reactionStartStep
            ) {
                reaction
            } else {
                null
            }
            val frame = engine.advanceBy(
                deltaMs = deltaMs,
                state = state,
                still = still,
                reducedMotion = reduced,
                sizePt = sizePt,
                displayScale = displayScale,
                appearance = appearance,
                crowned = crowned,
                reaction = activeReaction,
                profile = profile,
                workStyle = workStyle,
            )
            if (sampleSteps == null || step in sampleSteps) {
                val expected = expectedFrames[step]
                assertNotNull("$name missing expected frame $step", expected)
                expected!!
                checkFrame(name, step, expected, frame, engine, pixelSide, still || reduced)
                checked++
            }
        }

        assertEquals("$name random prefix", randomValues.size, randomIndex)
        assertEquals(
            "$name needsAnimationAtEnd",
            case.bool("needsAnimationAtEnd"),
            engine.needsAnimation,
        )
        assertEquals("$name expected frame count", expectedFrames.size, checked)
        return checked
    }

    private fun checkFrame(
        caseName: String,
        step: Int,
        expected: JsonObject,
        frame: BotFishFrame,
        engine: BotFishEngine,
        pixelSide: Int,
        static: Boolean,
    ) {
        val where = "$caseName@$step"
        assertEquals("$where timeMs", expected.number("timeMs"), frame.timeMs, tolerance)
        checkParams("$where params", expected.obj("params"), frame.params)
        val expectedPose = expected.obj("pose")
        assertEquals("$where offsetX", expectedPose.number("offsetX"), frame.pose.offsetX, tolerance)
        assertEquals("$where offsetY", expectedPose.number("offsetY"), frame.pose.offsetY, tolerance)
        assertEquals("$where roll", expectedPose.number("roll"), frame.pose.roll, tolerance)
        assertEquals("$where scaleX", expectedPose.number("scaleX"), frame.pose.scaleX, tolerance)
        assertEquals("$where scaleY", expectedPose.number("scaleY"), frame.pose.scaleY, tolerance)
        assertEquals("$where alpha", expected.number("alpha"), frame.alpha, tolerance)
        assertEquals("$where needsAnimation", expected.bool("needsAnimation"), frame.needsAnimation)
        assertEquals("$where static", expected.bool("static"), static)
        val view = expected.obj("view")
        assertEquals("$where motionScale", view.number("motionScale"), frame.viewMotionScale, tolerance)
        assertEquals("$where pixelSide", view.int("pixelSide"), pixelSide)
        assertEquals("$where frame pixelSide", pixelSide, frame.pixelSide)
        val reactionActive = (expected["reactionActive"] as? JsonBool)?.value
        if (reactionActive != null) {
            assertEquals("$where reactionActive", reactionActive, engine.machine.hasActiveReaction)
        }
    }

    private fun checkParams(where: String, expected: JsonObject, actual: BotFishParams) {
        val actualValues = paramsMap(actual)
        assertEquals("$where keys", expected.members.keys, actualValues.keys)
        for ((key, value) in expected.members) {
            val actualValue = actualValues[key]
            when (value) {
                is JsonNumber -> assertEquals(
                    "$where $key",
                    value.raw.toDouble(),
                    actualValue as Double,
                    tolerance,
                )
                is JsonString -> assertEquals("$where $key", value.value, actualValue as String)
                is JsonNull -> assertEquals("$where $key", null, actualValue)
                is JsonBool -> assertEquals("$where $key", value.value, actualValue as Boolean)
                else -> error("$where unsupported param value $value")
            }
        }
    }

    private fun paramsMap(p: BotFishParams): Map<String, Any?> = linkedMapOf(
        "eyeL" to p.eyeL, "eyeR" to p.eyeR, "joy" to p.joy,
        "browL" to p.browL, "browR" to p.browR, "anger" to p.anger,
        "sorrow" to p.sorrow, "smile" to p.smile, "mouth" to p.mouth,
        "mouthWidth" to p.mouthWidth, "round" to p.round, "blush" to p.blush,
        "tears" to p.tears, "love" to p.love, "gazeX" to p.gazeX,
        "gazeY" to p.gazeY, "roll" to p.roll, "y" to p.y, "x" to p.x,
        "sx" to p.sx, "sy" to p.sy, "alpha" to p.alpha, "finL" to p.finL,
        "finR" to p.finR, "finWave" to p.finWave, "decoration" to p.decoration,
        "progress" to p.progress, "phase" to p.phase, "eyeArt" to p.eyeArt,
        "mouthArt" to p.mouthArt, "finFold" to p.finFold,
        "hairSway" to p.hairSway, "earFlutter" to p.earFlutter,
        "puff" to p.puff, "breath" to p.breath, "headX" to p.headX,
        "headY" to p.headY, "bodyX" to p.bodyX, "bodyY" to p.bodyY,
        "blink" to p.blink, "morphX" to p.morphX, "morphY" to p.morphY,
        "artMix" to p.artMix, "eyeArtPrev" to p.eyeArtPrev,
        "mouthArtPrev" to p.mouthArtPrev, "motionScale" to p.motionScale,
        "gazeEmphasis" to p.gazeEmphasis, "dotLift" to p.dotLift,
        "dotScale" to p.dotScale, "dotStagger" to p.dotStagger,
        "isLivelyMotion" to p.isLivelyMotion,
    )

    private fun JsonObject.obj(key: String): JsonObject =
        this[key] as? JsonObject ?: error("missing object $key")

    private fun JsonObject.number(key: String): Double =
        (this[key] as? JsonNumber)?.raw?.toDouble() ?: error("missing number $key")

    private fun JsonObject.nullableNumber(key: String): Double? =
        when (val value = this[key]) {
            is JsonNumber -> value.raw.toDouble()
            null, is JsonNull -> null
            else -> error("$key is not a nullable number")
        }

    private fun JsonObject.int(key: String): Int =
        (this[key] as? JsonNumber)?.asLongOrNull()?.toInt() ?: error("missing integer $key")

    private fun JsonObject.bool(key: String): Boolean =
        (this[key] as? JsonBool)?.value ?: error("missing boolean $key")

    private fun JsonObject.str(key: String): String =
        (this[key] as? JsonString)?.value ?: error("missing string $key")

    private fun com.phonedsh.agentcore.JsonValue.number(): Double =
        (this as JsonNumber).raw.toDouble()

    private companion object {
        private val COLORS = BotFishColor.entries.map { it.wire }
        private val HAIRSTYLES = BotFishHairstyle.entries.map { it.wire }
        private val WORK_STYLES = BotFishWorkStyle.entries.map {
            when (it) {
                BotFishWorkStyle.GENERIC -> "generic"
                BotFishWorkStyle.READING -> "reading"
                BotFishWorkStyle.SEARCHING -> "searching"
                BotFishWorkStyle.RUNNING -> "running"
                BotFishWorkStyle.WRITING -> "writing"
            }
        }

        val EXPECTED_CASE_NAMES: Set<String> = buildSet {
            for (state in listOf(
                "idle", "thinking", "streaming", "working", "sleeping",
                "alerting", "listening", "speaking", "happy", "sad",
            )) {
                add("p0-$state")
            }
            addAll(
                listOf(
                    "sample-idle-32", "sample-alerting-32", "sample-idle-crowned",
                    "sample-alerting-crowned", "sample-standby",
                    "one-shot-poke", "one-shot-celebrate-reaction",
                    "one-shot-waving-reaction", "one-shot-bowing-reaction",
                    "one-shot-happy-expression",
                    "still-idle", "still-reaction-bowing", "reduced-thinking",
                    "reduced-reaction-celebrate",
                ),
            )
            for (color in COLORS) {
                for (hair in HAIRSTYLES) add("appearance-$color-$hair")
            }
            for (style in WORK_STYLES) add("lively-working-$style")
            for (state in listOf("streaming", "speaking", "celebrate", "done")) {
                add("lively-$state")
            }
            add("lively-celebrate-after-clip")
            addAll(
                listOf(
                    "replay-standard-poke-celebrate",
                    "replay-lively-idle-blink",
                    "replay-lively-thinking-reading",
                ),
            )
        }
    }
}
