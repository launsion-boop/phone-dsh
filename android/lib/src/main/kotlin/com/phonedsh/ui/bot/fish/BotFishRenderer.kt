// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import android.content.res.AssetManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffColorFilter
import android.graphics.Rect
import android.graphics.RectF
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishHairstyle
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** The two display-sized layers [BotFishView] composes with Canvas. */
public data class BotFishLayers(
    public val base: ImageBitmap,
    public val face: ImageBitmap,
)

/** One source-space circle crop: origin and side in 512-space units. */
internal data class BotFishCrop(
    val originX: Double = BotFishGeometry.CROP_X,
    val originY: Double = BotFishGeometry.CROP_Y,
    val side: Double = BotFishGeometry.CROP_SIDE,
) {
    val tag: String get() = if (side == BotFishGeometry.CROWNED_CROP_SIDE) "crown" else "plain"
}

/**
 * Android rasterisation of `examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishRenderer.swift`
 * (P09, `spec/ui/v1/bot/fish/fish.md` §7–§8).
 *
 * The class is a line-for-line port of the Swift drawing routines: the same
 * 512/1024 design coordinates, Bézier control points, colours, line widths,
 * clip order and blend/alpha, composed in the same order
 * (`BotFishRenderer.swift:485-517`, `:394-433`). Android `Canvas` is a
 * top-left, y-down space; every Swift `CGContext` here is created with a
 * `baseTransform` flip (`BotFishRenderer.swift:313-326`), so the port needs no
 * flip of its own. `drawUpright` (`:379-390`) becomes a normal
 * `Canvas.drawBitmap` for the same reason, and `withDesignSpace`/`withSourceSpace`
 * (`:1260-1277`) are re-implemented with save/translate/scale/restore.
 *
 * Pixel parity with Core Graphics is deliberately not claimed: the contract
 * freezes the model, layer choice, tint LUT and head-slice quanta, not the
 * rasteriser's antialiasing (`fish.md` §1, §7.4).
 *
 * Cache keys follow the iOS renderer: `body:<style>:<crop>:<palette>@<target>`,
 * `fixed:...`, `mouth-cel:<index>:<bucket>:<crop>@<target>:<w>x<h>` and the
 * tint bucket key `<style>:<crown>:<colour>@<bucket>`
 * (`BotFishRenderer.swift:394-433`, `:834-841`, `BotFishAssets.swift:229-260`).
 */
public class BotFishRenderer(private val assets: AssetManager) {
    private val imagePaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val layerPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val slicePaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

    private val sourceCache = LruCache<String, Bitmap>(64)
    private val tintCache = LruCache<String, Bitmap>(24)
    private val layerCache = LruCache<String, Bitmap>(64)
    private val baseCache = LruCache<String, ImageBitmap>(24)
    private val faceCache = LruCache<String, ImageBitmap>(16)
    private val sliceCache = LruCache<String, ImageBitmap>(24)

    private val facePainter = BotFishFacePainter(this)
    private val layerRect = RectF()
    private val sourceRect = Rect()

    private var browBitmap: Bitmap? = null
    private var browCanvas: Canvas? = null
    private var browTarget = 0

    /** Port of `prepare` (`BotFishRenderer.swift:219-285`). */
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
        val baseKey = baseKey(appearance, crowned, target, sizePt)
        val base = baseCache.get(baseKey) ?: buildBase(
            appearance = appearance,
            crowned = crowned,
            sizePt = sizePt,
            target = target,
            crop = crop,
        )?.also { baseCache.put(baseKey, it) } ?: return null
        // iOS hands the renderer the amplified params object
        // (`BotFishEngine.swift:571-573`): `motionScale` is the effective
        // boost, and the decorations read it. `BotFishFrame.params` stays
        // pre-amplification for the trajectory golden (fish.md §7.1), so the
        // effective value comes from `viewMotionScale`.
        val renderParams = if (frame.params.motionScale == frame.viewMotionScale) {
            frame.params
        } else {
            frame.params.copy(motionScale = frame.viewMotionScale)
        }
        val faceKey = faceKey(appearance, crowned, target, renderParams, frame.timeMs)
        val face = faceCache.get(faceKey) ?: buildFace(
            params = renderParams,
            timeMs = frame.timeMs,
            target = target,
            crop = crop,
            appearance = appearance,
            crowned = crowned,
        )?.also { faceCache.put(faceKey, it) } ?: return null

        val quantum = BotFishGeometry.headSliceQuantum(profile)
        val enabled = BotFishGeometry.headSlicingEnabled(profile, sizePt)
        val signature = BotFishHeadSlicing.signature(frame.params, enabled, quantum)
        if (signature.isIdentity) return BotFishLayers(base, face)

        // FISH-1: the cache key carries the quantum that produced the levels,
        // exactly like the Swift `SliceKey.quantum` (`BotFishRenderer.swift:177-184`).
        val quantumTag = (quantum * 1000).roundToInt()
        val head = "$signature@$quantumTag"
        val slicedBaseKey = "$baseKey:slice:$head"
        val slicedFaceKey = "$faceKey:slice:$head"
        val slicedBase = sliceCache.get(slicedBaseKey) ?: slice(
            base, signature, quantum, crop, target,
        )?.also { sliceCache.put(slicedBaseKey, it) }
        val slicedFace = sliceCache.get(slicedFaceKey) ?: slice(
            face, signature, quantum, crop, target,
        )?.also { sliceCache.put(slicedFaceKey, it) }
        // A failed slice falls back to the unsliced layers, like `prepare`
        // returning the base/face pair when the slice contexts are absent.
        if (slicedBase == null || slicedFace == null) return BotFishLayers(base, face)
        return BotFishLayers(slicedBase, slicedFace)
    }

    /** Port of `Crop.forCrowned` (`BotFishRenderer.swift:109-120`). */
    private fun cropFor(crowned: Boolean): BotFishCrop = if (crowned) {
        BotFishCrop(
            BotFishGeometry.CROWNED_CROP_X,
            BotFishGeometry.CROWNED_CROP_Y,
            BotFishGeometry.CROWNED_CROP_SIDE,
        )
    } else {
        BotFishCrop()
    }

    /** Port of `baseKey` (`BotFishRenderer.swift:287-291`). */
    private fun baseKey(
        appearance: BotFishAppearance,
        crowned: Boolean,
        target: Int,
        sizePt: Double,
    ): String {
        // The crown box/baseline tier is chosen by displaySize, not by the
        // pixel target (`BotFishRenderer.swift:1150-1153`), so the tier is part
        // of the key: 96pt@2x and 128pt@1.5x share a target but not a crown.
        val tier = when {
            sizePt <= 40 -> "s"
            sizePt <= 64 -> "m"
            else -> "l"
        }
        return "${appearance.hairstyle.wire}:${appearance.color.wire}:" +
            "${if (crowned) "crowned" else "plain"}@$target:$tier"
    }

    /**
     * Port of `BotFishFaceSignature` (`BotFishRenderer.swift:44-79`, `:444-483`).
     * The quantised buckets are the repaint gate, so tears read the clock only
     * while they are visible and decorations use the 1/24 (or lively 1/64)
     * phase bucket. `puff`/`breath` are deliberately absent: the Swift
     * signature does not include them because they never reach a painter.
     */
    private fun faceKey(
        appearance: BotFishAppearance,
        crowned: Boolean,
        target: Int,
        params: BotFishParams,
        timeMs: Double,
    ): String {
        fun q(value: Double, step: Double = 1.0 / 64.0): Int =
            BotFishMath.roundHalfAway(value / step).toInt()
        val animatedPhase = if (params.decoration in ANIMATED_DECORATIONS) {
            params.phase
        } else {
            0.0
        }
        val decorationStep = if (params.dotLift > 0.01) 1.0 / 64.0 else 1.0 / 24.0
        val tearsTime = if (params.tears > 0.01) q(timeMs / 40.0, 1.0) else 0
        val signature = listOf(
            q(params.eyeL), q(params.eyeR), q(params.joy),
            q(params.browL), q(params.browR),
            q(params.anger), q(params.sorrow),
            q(params.smile), q(params.mouth),
            q(params.mouthWidth, 0.02), q(params.round),
            q(params.blush), q(params.tears), q(params.love),
            q(params.gazeX, 0.05), q(params.gazeY, 0.05),
            q(params.blink), q(params.artMix, 1.0 / 16.0),
            q(params.finL), q(params.finR),
            q(params.finWave, 1.0 / 32.0), q(params.finFold),
            q(animatedPhase, decorationStep),
            tearsTime,
            q(params.motionScale, 0.05),
            q(params.gazeEmphasis, 0.05),
            q(params.dotLift, 0.1),
            q(params.dotScale, 0.01),
            q(params.dotStagger, 0.001),
            params.eyeArt, params.mouthArt,
            params.eyeArtPrev, params.mouthArtPrev,
            params.decoration,
        ).joinToString(":")
        // The Swift face image is invalidated when the base is rebuilt
        // (`appearanceKey`, `BotFishRenderer.swift:236-249`); the string key
        // makes that dependency explicit because fins use the palette ink/mid
        // and brows use the hairstyle face mask.
        return "${appearance.hairstyle.wire}:${appearance.color.wire}:" +
            "${if (crowned) "crowned" else "plain"}@$target:$signature"
    }

    /** Port of `BotFishAssets.layers(for:crowned:)` (`BotFishAssets.swift:150-179`). */
    private fun folderFor(hairstyle: BotFishHairstyle, crowned: Boolean): String = when {
        hairstyle == BotFishHairstyle.LONG && !crowned -> "base"
        hairstyle == BotFishHairstyle.LONG -> "crowned/long"
        !crowned -> "hair/${hairstyle.wire}"
        else -> "crowned/${hairstyle.wire}"
    }

    /** Port of `BotFishAssets.image` (`BotFishAssets.swift:198-202`). */
    internal fun bitmap(path: String): Bitmap? {
        sourceCache.get(path)?.let { return it }
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inScaled = false
        }
        val decoded = runCatching {
            assets.open("BotFish/$path").use { stream ->
                BitmapFactory.decodeStream(stream, null, options)
            }
        }.getOrNull() ?: return null
        sourceCache.put(path, decoded)
        return decoded
    }

    // MARK: - Static layers (BotFishRenderer.swift:394-433)

    private fun buildBase(
        appearance: BotFishAppearance,
        crowned: Boolean,
        sizePt: Double,
        target: Int,
        crop: BotFishCrop,
    ): ImageBitmap? {
        val folder = folderFor(appearance.hairstyle, crowned)
        val palette = BotFishPalette.forColor(appearance.color)
        val body = tintedBody(appearance, crowned, target, crop, folder) ?: return null
        val fixedSource = bitmap("$folder/fixed.png") ?: return null
        val bodyLayer = croppedLayer(
            body,
            "body:${appearance.hairstyle.wire}:${crop.tag}:${palette.id}@$target",
            target, crop,
        ) ?: return null
        val fixedLayer = croppedLayer(
            fixedSource,
            "fixed:${appearance.hairstyle.wire}:${crop.tag}@$target",
            target, crop,
        ) ?: return null
        val output = Bitmap.createBitmap(target, target, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        layerPaint.alpha = 255
        canvas.drawBitmap(bodyLayer, 0f, 0f, layerPaint)
        canvas.drawBitmap(fixedLayer, 0f, 0f, layerPaint)
        if (crowned) {
            // Upstream paints the crown at the end of the flat static layer
            // (`BotFishRenderer.swift:420-430`); it is baked into the cached
            // base, so a crown change costs one blit, never a per-frame pass.
            val crown = bitmap("overlays/crown.png")
            if (crown != null) {
                val pixelScale = target / crop.side
                canvas.save()
                canvas.translate(
                    (-crop.originX * pixelScale).toFloat(),
                    (-crop.originY * pixelScale).toFloat(),
                )
                canvas.scale(pixelScale.toFloat(), pixelScale.toFloat())
                paintCrown(canvas, crown, sizePt, pixelScale)
                canvas.restore()
            }
        }
        return output.asImageBitmap()
    }

    /**
     * Port of `paintCrown` (`BotFishRenderer.swift:1143-1167`). The
     * box/baseline buckets are the display-size tiers from fish.md §8.3.
     * Core Graphics `setShadow(offset:blur:color:)` has no Canvas equivalent;
     * the port draws the same blurred, shadow-coloured silhouette first,
     * offset by the frozen `(0, -1)` in source space (the bitmap canvas is
     * already flipped to top-left, which is why the Swift offset is `-1`).
     */
    private fun paintCrown(
        canvas: Canvas,
        crown: Bitmap,
        displaySize: Double,
        pixelScale: Double,
    ) {
        val small = displaySize <= 40
        val medium = displaySize <= 64
        val box = if (small) 250f else if (medium) 244f else 240f
        val baseline = if (small) 138f else if (medium) 134f else 132f
        layerRect.set(-box / 2f, -box * 404f / 512f, box / 2f, -box * 404f / 512f + box)
        canvas.save()
        canvas.translate(256f, baseline)
        shadowPaint.reset()
        shadowPaint.isAntiAlias = true
        shadowPaint.isFilterBitmap = true
        shadowPaint.colorFilter = PorterDuffColorFilter(
            BotFishPaint.CROWN_SHADOW,
            PorterDuff.Mode.SRC_IN,
        )
        shadowPaint.alpha = 61 // 27,31,55 @ 0.24 (fish.md §8.3)
        shadowPaint.maskFilter = BlurMaskFilter(
            max(0.1f, (2.0 * pixelScale).toFloat()),
            BlurMaskFilter.Blur.NORMAL,
        )
        canvas.save()
        canvas.translate(0f, -1f)
        canvas.drawBitmap(crown, null, layerRect, shadowPaint)
        canvas.restore()
        layerPaint.alpha = 255
        canvas.drawBitmap(crown, null, layerRect, layerPaint)
        canvas.restore()
    }

    // MARK: - Layer cache (BotFishImageCache.swift equivalents)

    /** Port of `BotFishImageCache.croppedLayer` (`BotFishImageCache.swift:63-86`). */
    internal fun croppedLayer(
        source: Bitmap,
        key: String,
        pixelSide: Int,
        crop: BotFishCrop = BotFishCrop(),
    ): Bitmap? {
        if (pixelSide <= 0 || crop.side <= 0) return null
        layerCache.get(key)?.let { return it }
        val output = Bitmap.createBitmap(pixelSide, pixelSide, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val scale = pixelSide / crop.side
        canvas.scale(scale.toFloat(), scale.toFloat())
        canvas.translate((-crop.originX).toFloat(), (-crop.originY).toFloat())
        layerRect.set(
            0f, 0f,
            BotFishGeometry.DESIGN_CANVAS.toFloat(),
            BotFishGeometry.DESIGN_CANVAS.toFloat(),
        )
        layerPaint.alpha = 255
        canvas.drawBitmap(source, null, layerRect, layerPaint)
        layerCache.put(key, output)
        return output
    }

    /** Port of `BotFishImageCache.croppedPart` (`BotFishImageCache.swift:88-107`). */
    internal fun croppedPart(
        source: Bitmap,
        sourceRect: Rect,
        key: String,
        width: Int,
        height: Int,
    ): Bitmap? {
        if (width <= 0 || height <= 0) return null
        layerCache.get(key)?.let { return it }
        this.sourceRect.set(sourceRect)
        if (!this.sourceRect.intersect(0, 0, source.width, source.height)) return null
        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        layerRect.set(0f, 0f, width.toFloat(), height.toFloat())
        layerPaint.alpha = 255
        canvas.drawBitmap(source, this.sourceRect, layerRect, layerPaint)
        layerCache.put(key, output)
        return output
    }

    /** Port of `BotFishImageCache.scaledSheet` (`BotFishImageCache.swift:109-125`). */
    internal fun scaledPart(
        source: Bitmap,
        sourceRect: Rect,
        key: String,
        width: Int,
        height: Int,
    ): Bitmap? = croppedPart(source, sourceRect, key, width, height)

    /** Port of the reusable `browContext` (`BotFishRenderer.swift:164-169`, `:754-794`). */
    internal fun browScratch(target: Int): Pair<Bitmap, Canvas> {
        var bitmap = browBitmap
        if (bitmap == null || browTarget != target) {
            bitmap = Bitmap.createBitmap(target, target, Bitmap.Config.ARGB_8888)
            browBitmap = bitmap
            browCanvas = Canvas(bitmap)
            browTarget = target
        }
        bitmap.eraseColor(0)
        return bitmap to browCanvas!!
    }

    // MARK: - Tinting (fish.md §8.2, BotFishAssets.swift:229-288)

    /** Port of `BotFishAssets.tintBody` (`BotFishAssets.swift:261-288`, fish.md §8.2). */
    private fun tintedBody(
        appearance: BotFishAppearance,
        crowned: Boolean,
        target: Int,
        crop: BotFishCrop,
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
            // The decoded/sampled bitmap is premultiplied but `getPixels`
            // reports straight channels, so the red channel is the luma the
            // LUT wants; iOS recovers the same value from its premultiplied
            // bitmap (fish.md §8.2).
            val luma = min(255, (pixel ushr 16) and 0xFF)
            val lutIndex = luma * 3
            val r = palette.lut[lutIndex] * alpha / 255
            val g = palette.lut[lutIndex + 1] * alpha / 255
            val b = palette.lut[lutIndex + 2] * alpha / 255
            pixels[index] = (alpha shl 24) or (r shl 16) or (g shl 8) or b
        }
        // The LUT values are stored premultiplied, like the iOS bitmap.
        val output = Bitmap.createBitmap(bucket, bucket, Bitmap.Config.ARGB_8888)
        output.setPremultiplied(true)
        output.setPixels(pixels, 0, bucket, 0, 0, bucket, bucket)
        tintCache.put(key, output)
        return output
    }

    /** Port of `BotFishAssets.sizeBucket` (`BotFishAssets.swift:220-227`). */
    private fun sizeBucket(pixelSide: Int): Int =
        SIZE_BUCKETS.firstOrNull { it >= pixelSide } ?: SIZE_BUCKETS.last()

    // MARK: - Face layer (BotFishRenderer.swift:485-517)

    /** Port of the face-context clear + `renderFace` (`BotFishRenderer.swift:251-259`, `:485-517`). */
    private fun buildFace(
        params: BotFishParams,
        timeMs: Double,
        target: Int,
        crop: BotFishCrop,
        appearance: BotFishAppearance,
        crowned: Boolean,
    ): ImageBitmap? {
        val output = Bitmap.createBitmap(target, target, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        facePainter.paint(
            canvas = canvas,
            target = target,
            crop = crop,
            pixelScale = target / crop.side,
            appearance = appearance,
            crowned = crowned,
            params = params,
            timeMs = timeMs,
        )
        return output.asImageBitmap()
    }

    // MARK: - Head slices (BotFishRenderer.swift:1202-1249)

    private fun slice(
        source: ImageBitmap,
        signature: BotFishHeadSlicing.Signature,
        quantum: Double,
        crop: BotFishCrop,
        target: Int,
    ): ImageBitmap? {
        val bitmap = source.asAndroidBitmap()
        val output = Bitmap.createBitmap(target, target, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val scale = target / crop.side
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
        val ANIMATED_DECORATIONS = setOf(
            "dots", "waiting", "sleep", "listen", "hearts", "confetti", "loading",
        )
    }
}
