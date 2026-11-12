// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import android.content.res.AssetManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishHairstyle
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** The two display-sized layers [BotFishView] composes with Canvas. */
public data class BotFishLayers(
    public val base: ImageBitmap,
    public val face: ImageBitmap,
)

/**
 * Android rasterisation of the layer contract in
 * `spec/ui/v1/bot/fish/fish.md` §7.4/§8. It deliberately does not claim pixel
 * parity: the contract freezes the model, layer choice, tint LUT and head-slice
 * quanta, not Core Graphics/Canvas antialiasing.
 *
 * The body tint cache keys are the iOS renderer's keys
 * (`BotFishRenderer.swift:282-287`, `BotFishAssets.swift:240-260`).
 */
public class BotFishRenderer(private val assets: AssetManager) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val sourceCache = LruCache<String, Bitmap>(64)
    private val tintCache = LruCache<String, Bitmap>(24)
    private val baseCache = LruCache<String, ImageBitmap>(24)
    private val faceCache = LruCache<String, ImageBitmap>(16)
    private val sliceCache = LruCache<String, ImageBitmap>(24)

    public fun render(
        frame: BotFishFrame,
        sizePt: Double,
        displayScale: Double,
        appearance: BotFishAppearance = BotFishAppearance.CLASSIC,
        crowned: Boolean = false,
        profile: BotFishMotionProfile = BotFishMotionProfile.STANDARD,
    ): BotFishLayers? {
        val target = frame.pixelSide
        if (target <= 0) return null
        val crop = cropFor(crowned)
        val baseKey = baseKey(appearance, crowned, target)
        val base = baseCache.get(baseKey) ?: buildBase(
            appearance = appearance,
            crowned = crowned,
            sizePt = sizePt,
            target = target,
            crop = crop,
        )?.also { baseCache.put(baseKey, it) } ?: return null
        val faceKey = faceKey(frame.params, target, crowned)
        val face = faceCache.get(faceKey) ?: buildFace(
            params = frame.params,
            target = target,
            crop = crop,
        )?.also { faceCache.put(faceKey, it) } ?: return null

        val quantum = BotFishGeometry.headSliceQuantum(profile)
        val enabled = BotFishGeometry.headSlicingEnabled(profile, sizePt)
        val signature = BotFishHeadSlicing.signature(frame.params, enabled, quantum)
        if (signature.isIdentity) return BotFishLayers(base, face)

        val quantumTag = (quantum * 1000).roundToInt()
        val head = "$signature@$quantumTag"
        val slicedBaseKey = "$baseKey:$head"
        val slicedFaceKey = "$faceKey:$head"
        val slicedBase = sliceCache.get(slicedBaseKey) ?: slice(
            base, signature, quantum, crop, target,
        )?.also { sliceCache.put(slicedBaseKey, it) } ?: return BotFishLayers(base, face)
        val slicedFace = sliceCache.get(slicedFaceKey) ?: slice(
            face, signature, quantum, crop, target,
        )?.also { sliceCache.put(slicedFaceKey, it) } ?: return BotFishLayers(base, face)
        return BotFishLayers(slicedBase, slicedFace)
    }

    private data class Crop(val originX: Double, val originY: Double, val side: Double)

    private fun cropFor(crowned: Boolean): Crop = if (crowned) {
        Crop(BotFishGeometry.CROWNED_CROP_X, BotFishGeometry.CROWNED_CROP_Y,
            BotFishGeometry.CROWNED_CROP_SIDE)
    } else {
        Crop(BotFishGeometry.CROP_X, BotFishGeometry.CROP_Y, BotFishGeometry.CROP_SIDE)
    }

    private fun baseKey(appearance: BotFishAppearance, crowned: Boolean, target: Int): String =
        "${appearance.hairstyle.wire}:${appearance.color.wire}:" +
            "${if (crowned) "crowned" else "plain"}@$target"

    private fun folderFor(hairstyle: BotFishHairstyle, crowned: Boolean): String = when {
        hairstyle == BotFishHairstyle.LONG && !crowned -> "base"
        hairstyle == BotFishHairstyle.LONG -> "crowned/long"
        !crowned -> "hair/${hairstyle.wire}"
        else -> "crowned/${hairstyle.wire}"
    }

    private fun bitmap(path: String): Bitmap? {
        sourceCache.get(path)?.let { return it }
        val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }
        val decoded = assets.open("BotFish/$path").use { stream ->
            BitmapFactory.decodeStream(stream, null, options)
        } ?: return null
        sourceCache.put(path, decoded)
        return decoded
    }

    private fun buildBase(
        appearance: BotFishAppearance,
        crowned: Boolean,
        sizePt: Double,
        target: Int,
        crop: Crop,
    ): ImageBitmap? {
        val folder = folderFor(appearance.hairstyle, crowned)
        val body = tintedBody(appearance, crowned, target, crop, folder) ?: return null
        val fixed = bitmap("$folder/fixed.png") ?: return null
        val output = Bitmap.createBitmap(target, target, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val scale = target / crop.side
        canvas.save()
        canvas.scale(scale.toFloat(), scale.toFloat())
        canvas.translate(-crop.originX.toFloat(), -crop.originY.toFloat())
        paint.alpha = 255
        canvas.drawBitmap(body, null, RectF(0f, 0f, 512f, 512f), paint)
        canvas.drawBitmap(fixed, null, RectF(0f, 0f, 512f, 512f), paint)
        if (crowned) {
            bitmap("overlays/crown.png")?.let { crown ->
                drawCrown(canvas, crown, sizePt)
            }
        }
        canvas.restore()
        return output.asImageBitmap()
    }

    private fun drawCrown(canvas: Canvas, crown: Bitmap, sizePt: Double) {
        val small = sizePt <= 40
        val medium = sizePt <= 64
        val box = if (small) 250f else if (medium) 244f else 240f
        val baseline = if (small) 138f else if (medium) 134f else 132f
        canvas.save()
        canvas.translate(256f, baseline)
        canvas.drawBitmap(
            crown,
            null,
            RectF(-box / 2, -box * 404f / 512f, box / 2, -box * 404f / 512f + box),
            paint,
        )
        canvas.restore()
    }

    private fun tintedBody(
        appearance: BotFishAppearance,
        crowned: Boolean,
        target: Int,
        crop: Crop,
        folder: String,
    ): Bitmap? {
        val source = bitmap("$folder/body.png") ?: return null
        val fullSourceSide = max(1.0, target * BotFishGeometry.DESIGN_CANVAS / crop.side)
        val bucket = sizeBucket(ceil(fullSourceSide).toInt())
        val crownTag = if (crowned) "crowned" else "plain"
        val key = "${appearance.hairstyle.wire}:$crownTag:${appearance.color.wire}@$bucket"
        tintCache.get(key)?.let { return it }

        val scaled = if (source.width == bucket) {
            source.copy(Bitmap.Config.ARGB_8888, true)
        } else {
            Bitmap.createScaledBitmap(source, bucket, bucket, true)
                .copy(Bitmap.Config.ARGB_8888, true)
        }
        val palette = BotFishPalette.forColor(appearance.color)
        val pixels = IntArray(bucket * bucket)
        scaled.getPixels(pixels, 0, bucket, 0, 0, bucket, bucket)
        for (index in pixels.indices) {
            val pixel = pixels[index]
            val alpha = (pixel ushr 24) and 0xFF
            if (alpha == 0) {
                pixels[index] = 0
                continue
            }
            // Android decodes straight ARGB, so the RGB channel is already the
            // straight luma the LUT wants (iOS recovers the same value from its
            // premultiplied bitmap, fish.md §8.2).
            val luma = min(255, (pixel ushr 16) and 0xFF)
            val lutIndex = luma * 3
            val r = palette.lut[lutIndex] * alpha / 255
            val g = palette.lut[lutIndex + 1] * alpha / 255
            val b = palette.lut[lutIndex + 2] * alpha / 255
            pixels[index] = (alpha shl 24) or (r shl 16) or (g shl 8) or b
        }
        val output = Bitmap.createBitmap(bucket, bucket, Bitmap.Config.ARGB_8888)
        output.setPixels(pixels, 0, bucket, 0, 0, bucket, bucket)
        tintCache.put(key, output)
        return output
    }

    private fun sizeBucket(pixelSide: Int): Int =
        SIZE_BUCKETS.firstOrNull { it >= pixelSide } ?: SIZE_BUCKETS.last()

    private fun faceKey(params: BotFishParams, target: Int, crowned: Boolean): String {
        fun q(value: Double, step: Double = 1.0 / 64.0): Int =
            BotFishMath.roundHalfAway(value / step).toInt()
        return listOf(
            q(params.eyeL), q(params.eyeR), q(params.joy), q(params.browL),
            q(params.browR), q(params.anger), q(params.sorrow), q(params.smile),
            q(params.mouth), q(params.mouthWidth, 0.02), q(params.round),
            q(params.blush), q(params.tears), q(params.love), q(params.gazeX, 0.05),
            q(params.gazeY, 0.05), q(params.blink), q(params.artMix, 1.0 / 16.0),
            q(params.finL), q(params.finR), q(params.finWave, 1.0 / 32.0),
            q(params.finFold), q(params.puff), q(params.breath),
            q(params.gazeEmphasis, 0.05), q(params.dotLift, 0.1),
            q(params.dotScale, 0.01), q(params.dotStagger, 0.001),
            params.eyeArt, params.mouthArt, params.eyeArtPrev,
            params.mouthArtPrev, params.decoration, target, crowned,
        ).joinToString(":")
    }

    private fun buildFace(params: BotFishParams, target: Int, crop: Crop): ImageBitmap? {
        val output = Bitmap.createBitmap(target, target, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val scale = target / crop.side
        canvas.save()
        canvas.scale(scale.toFloat(), scale.toFloat())
        canvas.translate(-crop.originX.toFloat(), -crop.originY.toFloat())

        if (params.blush > 0.01) {
            bitmap("base/blush.png")?.let {
                paint.alpha = (BotFishMath.clamp(params.blush, 0.0, 1.0) * 255).roundToInt()
                canvas.drawBitmap(it, null, RectF(0f, 0f, 512f, 512f), paint)
            }
        }
        paint.alpha = 255
        drawEyes(canvas, params)
        paint.alpha = 255
        drawMouth(canvas, params)
        canvas.restore()
        return output.asImageBitmap()
    }

    private fun drawEyes(canvas: Canvas, params: BotFishParams) {
        if (params.artMix < 1 && params.eyeArtPrev != params.eyeArt) {
            drawEyeLayer(canvas, params, params.eyeArtPrev, 1 - params.artMix)
            drawEyeLayer(canvas, params, params.eyeArt, params.artMix)
            return
        }
        drawEyeLayer(canvas, params, params.eyeArt, 1.0)
    }

    private fun drawEyeLayer(
        canvas: Canvas,
        params: BotFishParams,
        art: String?,
        opacity: Double,
    ) {
        paint.alpha = (BotFishMath.clamp(opacity, 0.0, 1.0) * 255).roundToInt()
        val index = BotFishEyeCel.indexOf(art)
        if (index != null) {
            val sheet = bitmap("expressive/eyes.png") ?: return
            for (side in listOf(-1.0, 1.0)) {
                val sourceX = (index % 3) * 256 + (if (side < 0) 0 else 128)
                val sourceY = (index / 3) * 128
                val source = Rect(sourceX, sourceY, sourceX + 128, sourceY + 128)
                val drawX = if (side < 0) 205.0 else 307.0
                val drawY = 297.0 + if (art == "laughing") 8.0 else 0.0
                canvas.save()
                canvas.translate(
                    (drawX + params.gazeX * 2 * params.gazeEmphasis).toFloat(),
                    (drawY + params.gazeY * 1.2 * params.gazeEmphasis).toFloat(),
                )
                canvas.scale(1f, max(0.035, params.blink).toFloat())
                canvas.drawBitmap(sheet, source, RectF(-51f, -51f, 51f, 51f), paint)
                canvas.restore()
            }
            return
        }
        // Procedural fallback uses the real eye base layers; the numeric
        // contract does not gate their Bézier detail.
        val moving = abs(params.gazeX) + abs(params.gazeY) > 0.05
        val base = bitmap(if (moving) "base/eyes-white.png" else "base/eyes-open.png")
        base?.let { canvas.drawBitmap(it, null, RectF(0f, 0f, 512f, 512f), paint) }
        if (moving) {
            for ((name, side) in listOf("base/iris-left.png" to -1.0, "base/iris-right.png" to 1.0)) {
                val iris = bitmap(name) ?: continue
                canvas.save()
                canvas.translate(
                    (256 + side * 51 + params.gazeX * 16 * params.gazeEmphasis).toFloat(),
                    (297 + params.gazeY * 12 * params.gazeEmphasis).toFloat(),
                )
                canvas.drawBitmap(iris, null, RectF(-51f, -51f, 51f, 51f), paint)
                canvas.restore()
            }
        }
    }

    private fun drawMouth(canvas: Canvas, params: BotFishParams) {
        val index = BotFishMouthCel.indexOf(params.mouthArt)
        if (index != null) {
            val sheet = bitmap("expressive/mouths.png") ?: return
            val sourceX = (index % 3) * 256
            val sourceY = (index / 3) * 128
            val source = Rect(sourceX, sourceY, sourceX + 256, sourceY + 128)
            val width = 90 * params.mouthWidth
            canvas.drawBitmap(
                sheet,
                source,
                RectF(
                    (256 - width / 2).toFloat(),
                    (335 - width / 4).toFloat(),
                    (256 + width / 2).toFloat(),
                    (335 + width / 4).toFloat(),
                ),
                paint,
            )
            return
        }
        // Minimal procedural mouth for the states without a cel.
        val mouthPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF742C44.toInt()
            style = if (params.mouth < 0.045) Paint.Style.STROKE else Paint.Style.FILL
            strokeWidth = 6f
        }
        val w = (34 * params.mouthWidth).toFloat()
        if (params.mouth < 0.045) {
            canvas.drawLine(256f - w, 338f, 256f + w, 338f, mouthPaint)
        } else {
            val h = (8 + params.mouth * 43).toFloat()
            canvas.drawOval(RectF(256f - w, 338f - h / 2, 256f + w, 338f + h / 2), mouthPaint)
        }
    }

    private fun slice(
        source: ImageBitmap,
        signature: BotFishHeadSlicing.Signature,
        quantum: Double,
        crop: Crop,
        target: Int,
    ): ImageBitmap? {
        val bitmap = source.asAndroidBitmap()
        val output = Bitmap.createBitmap(target, target, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val scale = target / crop.side
        val slicePaint = Paint(Paint.FILTER_BITMAP_FLAG)
        var y = 0.0
        while (y < BotFishGeometry.DESIGN_CANVAS) {
            val (top, bottom) = BotFishHeadSlicing.outputRow(y, crop.originY, scale, target)
            if (bottom > top) {
                val (dx, dy) = BotFishHeadSlicing.displacement(y, signature, quantum)
                canvas.save()
                canvas.translate((dx * scale).toFloat(), (dy * scale).toFloat())
                canvas.clipRect(0f, top.toFloat(), target.toFloat(), bottom.toFloat())
                canvas.drawBitmap(bitmap, 0f, 0f, slicePaint)
                canvas.restore()
            }
            y += BotFishGeometry.HEAD_SLICE_SOURCE_SIZE
        }
        return output.asImageBitmap()
    }

    private companion object {
        val SIZE_BUCKETS = intArrayOf(
            32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048,
        )
    }
}
