// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Rect
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.ui.SpecFixtures
import java.io.File
import java.io.FileOutputStream
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Renders a fixed set of real lifecycle frames for both motion profiles and
 * both crown states, writes the composites to `android/lib/build/botfish-frames/`
 * (build output, never committed) and checks structural properties that come
 * from the Swift geometry, not from a pixel baseline:
 *
 * * the procedural mouth paints inside the `paintMouth` Bézier bounds
 *   (`BotFishRenderer.swift:843-894`);
 * * tears animate inside the `paintTears` anchors only while `tears > 0.01`
 *   (`:898-924`);
 * * fins paint palette `mid` inside the `paintFin` transformed path bounds
 *   (`:926-964`);
 * * the crown overlay lands in the crowned base and never in the plain one
 *   (`:1143-1167`, `:394-433`.
 *
 * The frames are produced by the real [BotFishEngine]; no fixture is
 * hand-copied. The four assertions are structural: fish.md §1 and §7.4 do not
 * make Core Graphics/Canvas antialiasing part of the contract.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BotFishRasterFramesTest {
    private data class Rendered(
        val profile: BotFishMotionProfile,
        val state: BotFishLifecycle,
        val crowned: Boolean,
        val frame: BotFishFrame,
        // The same frame with `tears = 0`: the only difference is the tear
        // painter, so comparing the two faces isolates the tear pixels without
        // assuming what colour the background has.
        val controlFace: Bitmap,
        val base: Bitmap,
        val face: Bitmap,
    )

    @Test
    fun `fixed lifecycle frames keep the mouth tear fin and crown geometry`() {
        val frames = renderedFrames()
        assertEquals(STATES.size * 2 * 2, frames.size)

        assertFramesWritten(frames)
        assertMouth(frames)
        assertTears(frames)
        assertFins(frames)
        assertCrown(frames)
    }

    // MARK: - Frame matrix

    private fun renderedFrames(): List<Rendered> {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val renderer = BotFishRenderer(context.assets)
        val output = mutableListOf<Rendered>()
        for (profile in PROFILES) {
            for (state in STATES) {
                for (crowned in listOf(false, true)) {
                    val frame = frameAt(profile, state, crowned, 1000.0)
                    val layers = renderer.render(
                        frame = frame,
                        sizePt = SIZE_PT,
                        displayScale = DISPLAY_SCALE,
                        appearance = APPEARANCE,
                        crowned = crowned,
                        profile = profile,
                    )
                    val controlFrame = frame.copy(
                        params = frame.params.copy(tears = 0.0),
                    )
                    val controlLayers = renderer.render(
                        frame = controlFrame,
                        sizePt = SIZE_PT,
                        displayScale = DISPLAY_SCALE,
                        appearance = APPEARANCE,
                        crowned = crowned,
                        profile = profile,
                    )
                    assertNotNull("no layers for ${profile.name}/$state/$crowned", layers)
                    assertNotNull(
                        "no control layers for ${profile.name}/$state/$crowned",
                        controlLayers,
                    )
                    val rendered = Rendered(
                        profile = profile,
                        state = state,
                        crowned = crowned,
                        frame = frame,
                        controlFace = controlLayers!!.face.asAndroidBitmap(),
                        base = layers!!.base.asAndroidBitmap(),
                        face = layers.face.asAndroidBitmap(),
                    )
                    writeComposite(rendered)
                    output += rendered
                }
            }
        }
        return output
    }

    private fun frameAt(
        profile: BotFishMotionProfile,
        state: BotFishLifecycle,
        crowned: Boolean,
        timeMs: Double,
    ): BotFishFrame {
        // A constant random source makes the blink/look schedule deterministic;
        // 0.5 arms the first blink well after the sampled second.
        val engine = BotFishEngine(random = { 0.5 })
        var elapsed = 0.0
        var frame: BotFishFrame? = null
        while (elapsed < timeMs - 1e-9) {
            val step = min(50.0, timeMs - elapsed)
            frame = engine.advanceBy(
                deltaMs = step,
                state = state,
                still = false,
                reducedMotion = false,
                sizePt = SIZE_PT,
                displayScale = DISPLAY_SCALE,
                appearance = APPEARANCE,
                crowned = crowned,
                reaction = null,
                profile = profile,
                workStyle = BotFishWorkStyle.GENERIC,
            )
            elapsed += step
        }
        return requireNotNull(frame) { "engine produced no frame" }
    }

    private fun writeComposite(rendered: Rendered) {
        val directory = SpecFixtures.repoRoot.resolve(FRAME_DIRECTORY).toFile()
        if (!directory.isDirectory) directory.mkdirs()
        val composite = Bitmap.createBitmap(TARGET, TARGET, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(composite)
        canvas.drawBitmap(rendered.base, 0f, 0f, null)
        canvas.drawBitmap(rendered.face, 0f, 0f, null)
        val file = File(directory, frameName(rendered))
        FileOutputStream(file).use { stream ->
            assertTrue(
                "PNG encode failed for ${file.name}",
                composite.compress(Bitmap.CompressFormat.PNG, 100, stream),
            )
        }
    }

    private fun assertFramesWritten(frames: List<Rendered>) {
        val directory = SpecFixtures.repoRoot.resolve(FRAME_DIRECTORY).toFile()
        assertTrue("frame directory is missing: $directory", directory.isDirectory)
        val expected = frames.map { frameName(it) }.toSet()
        val actual = directory.listFiles()
            ?.filter { it.isFile && it.extension == "png" }
            ?.map { it.name }
            ?.toSet()
            ?: emptySet()
        assertTrue(
            "missing generated frames: ${expected - actual}",
            actual.containsAll(expected),
        )
        for (name in expected) {
            assertTrue("empty PNG: $name", File(directory, name).length() > 0L)
        }
        println("BOTFISH_FRAMES ${expected.sorted().joinToString(" ")}")
    }

    private fun frameName(rendered: Rendered): String =
        "${rendered.profile.name.lowercase()}-${rendered.state.wire}-" +
            "${if (rendered.crowned) "crowned" else "plain"}.png"

    // MARK: - Mouth (BotFishRenderer.swift:843-894)

    private fun assertMouth(frames: List<Rendered>) {
        val open = frames.filter {
            it.frame.params.mouthArt == null && it.frame.params.mouth >= 0.045
        }
        assertEquals("unexpected open-mouth frame set", 4, open.size)
        for (rendered in open) {
            val bounds = openMouthBounds(rendered.frame.params, rendered.crowned)
            val count = countOpaque(rendered.face, bounds)
            assertTrue(
                "no mouth fill inside the Bézier bounds for " +
                    "${frameName(rendered)} (${bounds.flattenToString()}): $count",
                count >= 8,
            )
        }

        // The closed-mouth smile curve is the other `paintMouth` branch. The
        // stroke is sub-pixel at 256 px, so one opaque sample is enough to
        // prove the curve was painted where the Swift coordinates put it.
        val closed = frames.filter {
            it.frame.params.mouthArt == null && it.frame.params.mouth < 0.045
        }
        assertTrue("no closed-mouth procedural frame", closed.isNotEmpty())
        for (rendered in closed) {
            val bounds = closedMouthBounds(rendered.frame.params, rendered.crowned)
            val count = countOpaque(rendered.face, bounds)
            assertTrue(
                "no closed-mouth stroke for ${frameName(rendered)}: $count",
                count >= 1,
            )
        }
    }

    private fun openMouthBounds(params: BotFishParams, crowned: Boolean): Rect {
        val w = 34 * params.mouthWidth
        val open = BotFishMath.clamp(params.mouth, 0.0, 1.0)
        val h = 8 + open * 43
        // The two cubic curves are symmetric, so their extremum is 3/4 of the
        // control-point offset from the 0 baseline.
        val top = -0.75 * (7 + params.round * 5)
        val bottom = 0.75 * h * 1.15
        val margin = 4.0
        return designRect(
            512 - w - margin,
            693 + top - margin,
            512 + w + margin,
            693 + bottom + margin,
            crowned,
        )
    }

    private fun closedMouthBounds(params: BotFishParams, crowned: Boolean): Rect {
        val w = 34 * params.mouthWidth
        val curve = 19 * params.smile
        val low = min(-2.0, -2.0 + curve * 0.75)
        val high = max(-2.0, -2.0 + curve * 0.75)
        val margin = 3.0
        return designRect(
            512 - w - margin,
            693 + low - margin,
            512 + w + margin,
            693 + high + margin,
            crowned,
        )
    }

    // MARK: - Tears (BotFishRenderer.swift:898-924)

    private fun assertTears(frames: List<Rendered>) {
        for (rendered in frames) {
            val tears = rendered.frame.params.tears
            val boxes = tearBoxes(rendered.frame.timeMs, rendered.crowned)
            val inside = boxes.sumOf { diffCount(rendered.face, rendered.controlFace, it) }
            val outside = diffCount(rendered.face, rendered.controlFace, fullFace()) -
                inside
            if (tears > 0.01) {
                assertTrue(
                    "no tear pixels inside the tear anchors for " + frameName(rendered),
                    inside > 0,
                )
                assertEquals(
                    "tear painter drew outside its anchors for ${frameName(rendered)}",
                    0,
                    outside,
                )
            } else {
                assertEquals(
                    "tear pixels without tears for ${frameName(rendered)}",
                    0,
                    inside + outside,
                )
            }
        }
    }

    /**
     * The two `paintTears` anchors in design space. The top edge is clamped
     * below the default-eye texture (its content ends around design y 656), so
     * an animated gaze cannot be mistaken for a tear.
     */
    private fun tearBoxes(timeMs: Double, crowned: Boolean): List<Rect> {
        val boxes = mutableListOf<Rect>()
        for ((x, offset) in TEAR_ANCHORS) {
            val q = (timeMs / 1900 + offset) % 1.0
            val y = 658 + q * 75
            val top = max(660.0, y - 11)
            boxes += designRect(x - 15, top, x + 15, y + 17, crowned)
        }
        return boxes
    }

    // MARK: - Fins (BotFishRenderer.swift:926-964)

    private fun assertFins(frames: List<Rendered>) {
        val mid = rgb(BotFishPalette.forColor(APPEARANCE.color).mid)
        for (rendered in frames) {
            val params = rendered.frame.params
            val left = finBounds(
                -1.0, params.finL, params.finWave, params.finFold, rendered.crowned,
            )
            val right = finBounds(
                1.0, params.finR, -params.finWave, params.finFold, rendered.crowned,
            )
            val leftCount = countColor(rendered.face, left, mid)
            val rightCount = countColor(rendered.face, right, mid)
            if (params.finL >= 0.05) {
                assertTrue(
                    "left fin missing at its anchor for ${frameName(rendered)}: $leftCount",
                    leftCount > 0,
                )
            } else {
                assertEquals(
                    "left fin painted without amount for ${frameName(rendered)}",
                    0,
                    leftCount,
                )
            }
            if (params.finR >= 0.05) {
                assertTrue(
                    "right fin missing at its anchor for ${frameName(rendered)}: $rightCount",
                    rightCount > 0,
                )
            } else {
                assertEquals(
                    "right fin painted without amount for ${frameName(rendered)}",
                    0,
                    rightCount,
                )
            }
        }
    }

    private fun finBounds(
        side: Double,
        amount: Double,
        wave: Double,
        fold: Double,
        crowned: Boolean,
    ): Rect {
        if (amount < 0.05) return Rect()
        val angle = -0.42 * amount + wave * 0.45 + fold * 0.7
        val cosA = cos(angle)
        val sinA = sin(angle)
        val originX = (if (side < 0) 111.0 else 401.0) - side * fold * 82
        val originY = 402 - amount * 12
        var minX = Double.POSITIVE_INFINITY
        var minY = Double.POSITIVE_INFINITY
        var maxX = Double.NEGATIVE_INFINITY
        var maxY = Double.NEGATIVE_INFINITY
        // Endpoints and cubic control points: a superset of the curve.
        for ((x, y) in FIN_POINTS) {
            val rx = x * cosA - y * sinA
            val ry = x * sinA + y * cosA
            val sx = originX + side * rx
            val sy = originY + ry
            minX = min(minX, sx)
            maxX = max(maxX, sx)
            minY = min(minY, sy)
            maxY = max(maxY, sy)
        }
        val margin = 4.0
        return sourceRect(minX - margin, minY - margin, maxX + margin, maxY + margin, crowned)
    }

    // MARK: - Crown (BotFishRenderer.swift:394-433, :1143-1167)

    /**
     * Samples the crown asset itself and asks the two real base layers to
     * answer at the projected source points. Points where the plain
     * `body.png`/`fixed.png` are transparent are crown-only: they must be
     * transparent in the plain base and opaque in the crowned base. That is
     * the structural form of "crown pixels only when crowned".
     */
    private fun assertCrown(frames: List<Rendered>) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val crown = decodeAsset(context, "overlays/crown.png")
        val plainBody = decodeAsset(context, "hair/twin-tail/body.png")
        val plainFixed = decodeAsset(context, "hair/twin-tail/fixed.png")
        val plain = frames.first {
            !it.crowned && it.profile == BotFishMotionProfile.STANDARD &&
                it.state == BotFishLifecycle.IDLE
        }
        val crowned = frames.first {
            it.crowned && it.profile == BotFishMotionProfile.STANDARD &&
                it.state == BotFishLifecycle.IDLE
        }
        val crownPixels = pixels(crown)
        val bodyPixels = pixels(plainBody)
        val fixedPixels = pixels(plainFixed)
        val plainBase = pixels(plain.base)
        val crownedBase = pixels(crowned.base)

        // fish.md §8.3 / `BotFishRenderer.swift:1150-1153`: the crown tier is
        // selected by the display size, not by the pixel target.
        val box = when {
            SIZE_PT <= 40 -> 250.0
            SIZE_PT <= 64 -> 244.0
            else -> 240.0
        }
        val baseline = when {
            SIZE_PT <= 40 -> 138.0
            SIZE_PT <= 64 -> 134.0
            else -> 132.0
        }
        val plainScale = TARGET / BotFishGeometry.CROP_SIDE
        val crownedScale = TARGET / BotFishGeometry.CROWNED_CROP_SIDE
        var checked = 0
        for (iy in 0 until crownPixels.height step 2) {
            for (ix in 0 until crownPixels.width step 2) {
                if (alphaAt(crownPixels, ix, iy) < 250) continue
                if (!solid(crownPixels, ix, iy)) continue
                val sx = 256 - box / 2 + ix * box / 512
                val sy = baseline - box * 404 / 512 + iy * box / 512
                if (!transparent(bodyPixels, sx, sy)) continue
                if (!transparent(fixedPixels, sx, sy)) continue

                val plainX = ((sx - BotFishGeometry.CROP_X) * plainScale).toInt()
                val plainY = ((sy - BotFishGeometry.CROP_Y) * plainScale).toInt()
                if (plainX in 0 until TARGET && plainY in 0 until TARGET) {
                    assertEquals(
                        "crown art leaked into the plain base at $sx,$sy",
                        0,
                        alphaAt(plainBase, plainX, plainY),
                    )
                }
                val crownedX = ((sx - BotFishGeometry.CROWNED_CROP_X) * crownedScale).toInt()
                val crownedY = ((sy - BotFishGeometry.CROWNED_CROP_Y) * crownedScale).toInt()
                if (crownedX in 0 until TARGET && crownedY in 0 until TARGET) {
                    assertTrue(
                        "crown art missing from the crowned base at $sx,$sy",
                        alphaAt(crownedBase, crownedX, crownedY) > 0,
                    )
                    checked++
                }
            }
        }
        assertTrue("not enough crown-only samples were checked: $checked", checked > 100)

        // A crowned view uses the 448 px crop and a plain view the 416 px crop,
        // so the whole top of the crown is above the plain artwork.
        val crownedTop = countOpaqueInRows(crowned.base, 0, 14)
        assertTrue("crowned base has no crown rows: $crownedTop", crownedTop > 0)
    }

    private fun decodeAsset(context: Context, path: String): Bitmap {
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inScaled = false
        }
        return context.assets.open("BotFish/$path").use {
            BitmapFactory.decodeStream(it, null, options)
        } ?: error("missing asset BotFish/$path")
    }

    private data class PixelBuffer(val width: Int, val height: Int, val pixels: IntArray)

    private fun pixels(bitmap: Bitmap): PixelBuffer {
        val buffer = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(buffer, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return PixelBuffer(bitmap.width, bitmap.height, buffer)
    }

    private fun alphaAt(buffer: PixelBuffer, x: Int, y: Int): Int {
        if (x < 0 || y < 0 || x >= buffer.width || y >= buffer.height) return 0
        return (buffer.pixels[y * buffer.width + x] ushr 24) and 0xFF
    }

    /** The crown sample is 1 px away from a soft edge. */
    private fun solid(buffer: PixelBuffer, x: Int, y: Int): Boolean {
        for (dy in -1..1) {
            for (dx in -1..1) {
                if (alphaAt(buffer, x + dx, y + dy) < 250) return false
            }
        }
        return true
    }

    /** The plain artwork is transparent in a small neighbourhood of the point. */
    private fun transparent(pixels: PixelBuffer, sx: Double, sy: Double): Boolean {
        val x = sx.toInt()
        val y = sy.toInt()
        for (dy in -2..2) {
            for (dx in -2..2) {
                if (alphaAt(pixels, x + dx, y + dy) != 0) return false
            }
        }
        return true
    }

    // MARK: - Geometry helpers

    private fun designRect(
        left: Double,
        top: Double,
        right: Double,
        bottom: Double,
        crowned: Boolean,
    ): Rect {
        val cropX = if (crowned) BotFishGeometry.CROWNED_CROP_X else BotFishGeometry.CROP_X
        val cropY = if (crowned) BotFishGeometry.CROWNED_CROP_Y else BotFishGeometry.CROP_Y
        val side = if (crowned) BotFishGeometry.CROWNED_CROP_SIDE else BotFishGeometry.CROP_SIDE
        val scale = TARGET / side
        fun x(value: Double): Double =
            (BotFishGeometry.PAD + BotFishGeometry.DESIGN_SCALE * value - cropX) * scale
        fun y(value: Double): Double =
            (BotFishGeometry.PAD + BotFishGeometry.DESIGN_SCALE * value - cropY) * scale
        val rect = Rect(
            floor(x(left)).toInt(),
            floor(y(top)).toInt(),
            ceil(x(right)).toInt(),
            ceil(y(bottom)).toInt(),
        )
        rect.intersect(0, 0, TARGET, TARGET)
        return rect
    }

    private fun sourceRect(
        left: Double,
        top: Double,
        right: Double,
        bottom: Double,
        crowned: Boolean,
    ): Rect {
        val cropX = if (crowned) BotFishGeometry.CROWNED_CROP_X else BotFishGeometry.CROP_X
        val cropY = if (crowned) BotFishGeometry.CROWNED_CROP_Y else BotFishGeometry.CROP_Y
        val side = if (crowned) BotFishGeometry.CROWNED_CROP_SIDE else BotFishGeometry.CROP_SIDE
        val scale = TARGET / side
        val rect = Rect(
            floor((left - cropX) * scale).toInt(),
            floor((top - cropY) * scale).toInt(),
            ceil((right - cropX) * scale).toInt(),
            ceil((bottom - cropY) * scale).toInt(),
        )
        rect.intersect(0, 0, TARGET, TARGET)
        return rect
    }

    private fun countOpaque(bitmap: Bitmap, rect: Rect): Int {
        val buffer = pixels(bitmap)
        var count = 0
        for (y in rect.top until rect.bottom) {
            for (x in rect.left until rect.right) {
                if (alphaAt(buffer, x, y) > 0) count++
            }
        }
        return count
    }

    private fun countColor(bitmap: Bitmap, rect: Rect, color: Int): Int {
        if (rect.isEmpty) return 0
        val buffer = pixels(bitmap)
        val wanted = color and 0xFFFFFF
        var count = 0
        for (y in rect.top until rect.bottom) {
            for (x in rect.left until rect.right) {
                val pixel = buffer.pixels[y * buffer.width + x]
                if (((pixel ushr 24) and 0xFF) == 0) continue
                if ((pixel and 0xFFFFFF) == wanted) count++
            }
        }
        return count
    }

    private fun diffCount(first: Bitmap, second: Bitmap, rect: Rect): Int {
        val a = pixels(first)
        val b = pixels(second)
        var count = 0
        for (y in rect.top until rect.bottom) {
            for (x in rect.left until rect.right) {
                val index = y * a.width + x
                if (a.pixels[index] != b.pixels[index]) count++
            }
        }
        return count
    }

    private fun fullFace(): Rect = Rect(0, 0, TARGET, TARGET)

    private fun countOpaqueInRows(bitmap: Bitmap, top: Int, bottom: Int): Int {
        val buffer = pixels(bitmap)
        var count = 0
        for (y in top until min(bottom, buffer.height)) {
            for (x in 0 until buffer.width) {
                if (alphaAt(buffer, x, y) > 0) count++
            }
        }
        return count
    }

    private fun rgb(rgb: IntArray): Int =
        0xFF000000.toInt() or (rgb[0] shl 16) or (rgb[1] shl 8) or rgb[2]

    private companion object {
        const val SIZE_PT = 128.0
        const val DISPLAY_SCALE = 2.0
        const val TARGET = 256
        const val FRAME_DIRECTORY = "android/lib/build/botfish-frames"
        val APPEARANCE = BotFishAppearance(BotFishColor.SKY, BotFishHairstyle.TWIN_TAIL)
        val PROFILES = listOf(BotFishMotionProfile.STANDARD, BotFishMotionProfile.LIVELY)
        val STATES = listOf(
            BotFishLifecycle.IDLE,
            BotFishLifecycle.THINKING,
            BotFishLifecycle.WORKING,
            BotFishLifecycle.SPEAKING,
            BotFishLifecycle.ALERTING,
            BotFishLifecycle.CELEBRATE,
            BotFishLifecycle.SLEEPING,
            // The decorated state: `love` paints hearts (`fish.md` §5.3).
            BotFishLifecycle.LOVE,
            BotFishLifecycle.CRYING,
        )
        val TEAR_ANCHORS = listOf(345.0 to 0.0, 680.0 to 0.45)
        val FIN_POINTS = listOf(
            -9.0 to 7.0,
            9.0 to -6.0, 17.0 to -22.0, 25.0 to -42.0,
            29.0 to -53.0, 39.0 to -59.0, 43.0 to -55.0,
            48.0 to -52.0, 43.0 to -37.0, 41.0 to -31.0,
            51.0 to -39.0, 57.0 to -34.0, 52.0 to -24.0,
            61.0 to -28.0, 64.0 to -20.0, 55.0 to -11.0,
            35.0 to 7.0, 11.0 to 18.0,
        )
    }
}
