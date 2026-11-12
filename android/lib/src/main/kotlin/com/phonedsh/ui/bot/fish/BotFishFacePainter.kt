// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishHairstyle
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Every face-layer drawing routine of
 * `examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishRenderer.swift`, ported in
 * source-unit space:
 *
 * * blush, eyes and mouth (`BotFishRenderer.swift:485-535`, `:569-681`,
 *   `:798-894`);
 * * tears, fins and decorations (`:898-924`, `:926-964`, `:968-1139`);
 * * the masked brows (`:754-794`).
 *
 * Android `Canvas` already uses a top-left, y-down user space, which is the
 * space the Swift bitmap context establishes with `baseTransform` and
 * `resetCTM` (`BotFishRenderer.swift:313-326`, `:368-374`). `drawUpright`
 * (`:379-390`) is therefore an ordinary `drawBitmap`, and
 * `withDesignSpace`/`withSourceSpace` (`:1260-1277`) are re-implemented with
 * `save`/`translate`/`scale`/`restore`. The graphics-state alpha, line cap and
 * line join are kept as painter state because Core Graphics carries them
 * across `saveGState`/`restoreGState` too (arms, fins and decorations depend on
 * that order: the mouth sets a round cap before the fins are painted).
 */
internal class BotFishFacePainter(private val renderer: BotFishRenderer) {
    private lateinit var canvas: Canvas
    private var target = 0
    private var crop = BotFishCrop()
    private lateinit var palette: BotFishPalette
    private var hairstyle: BotFishHairstyle = BotFishHairstyle.LONG
    private var crowned = false
    private var pixelSide = 0
    private var pixelScale = 1.0

    private val imagePaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val shapePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val maskPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val path = Path()
    private val rect = RectF()

    private var alpha = 255
    private var strokeCap = Paint.Cap.BUTT
    private var strokeJoin = Paint.Join.MITER

    private val cropTag: String get() = if (crowned) "crown" else "plain"

    /** Port of `renderFace` (`BotFishRenderer.swift:485-517`). */
    fun paint(
        canvas: Canvas,
        target: Int,
        crop: BotFishCrop,
        pixelScale: Double,
        appearance: BotFishAppearance,
        crowned: Boolean,
        params: BotFishParams,
        timeMs: Double,
    ) {
        this.canvas = canvas
        this.target = target
        this.crop = crop
        this.pixelScale = pixelScale
        this.palette = BotFishPalette.forColor(appearance.color)
        this.hairstyle = appearance.hairstyle
        this.crowned = crowned
        this.pixelSide = target
        this.alpha = 255
        this.strokeCap = Paint.Cap.BUTT
        this.strokeJoin = Paint.Join.MITER
        imagePaint.alpha = 255
        shapePaint.alpha = 255

        if (params.blush > 0.01) {
            val blush = renderer.bitmap("base/blush.png")
            val layer = blush?.let {
                renderer.croppedLayer(it, "blush:$cropTag@$pixelSide", target, crop)
            }
            if (layer != null) {
                setAlpha((BotFishMath.clamp(params.blush, 0.0, 1.0) * 255).roundToInt())
                drawFull(layer)
                setAlpha(255)
            }
        }

        paintEye(-1.0, params)
        paintEye(1.0, params)
        paintMouthCrossfade(params)
        if (params.tears > 0.01) paintTears(params, timeMs)
        paintFin(-1.0, params.finL, params.finWave, params.finFold)
        paintFin(1.0, params.finR, -params.finWave, params.finFold)
        paintDecorations(params)
        if (params.eyeArt == null) paintBrows(params)
    }

    // MARK: - Eyes (BotFishRenderer.swift:519-750)

    /** Port of `paintEye` (`BotFishRenderer.swift:521-535`). */
    private fun paintEye(side: Double, p: BotFishParams) {
        if (p.artMix < 1 && p.eyeArtPrev != p.eyeArt) {
            setAlpha((BotFishMath.clamp(1 - p.artMix, 0.0, 1.0) * 255).roundToInt())
            paintEyeLayer(side, p, p.eyeArtPrev)
            setAlpha((BotFishMath.clamp(p.artMix, 0.0, 1.0) * 255).roundToInt())
            paintEyeLayer(side, p, p.eyeArt)
            setAlpha(255)
            return
        }
        paintEyeLayer(side, p, p.eyeArt)
    }

    /** Port of `paintEyeLayer` (`BotFishRenderer.swift:537-567`). */
    private fun paintEyeLayer(side: Double, p: BotFishParams, art: String?) {
        val index = BotFishEyeCel.indexOf(art)
        if (index != null) {
            val cel = index * 2 + if (side < 0) 0 else 1
            if (cel < BotFishEyeCel.names.size * 2) {
                val blink = max(0.035, p.blink)
                val sourceX = if (side < 0) 205.0 else 307.0
                val sourceY = 297.0 + if (art == "laughing") 8.0 else 0.0
                val sidePixels = max(1, BotFishMath.roundHalfAway(102 * pixelScale).toInt())
                val image = eyeCelImage(cel, sidePixels)
                val offsetX = (sourceX + p.gazeX * 2 * p.gazeEmphasis - crop.originX) * pixelScale
                val offsetY = (sourceY + p.gazeY * 1.2 * p.gazeEmphasis - crop.originY) * pixelScale
                canvas.save()
                canvas.translate(offsetX.toFloat(), offsetY.toFloat())
                canvas.scale(1f, blink.toFloat())
                if (image != null) {
                    rect.set(
                        -sidePixels / 2f, -sidePixels / 2f,
                        sidePixels / 2f, sidePixels / 2f,
                    )
                    canvas.drawBitmap(image, null, rect, imagePaint)
                }
                canvas.restore()
                return
            }
        }
        paintDesignEye(side, p)
    }

    /** Port of `paintDesignEye` (`BotFishRenderer.swift:569-681`). */
    private fun paintDesignEye(side: Double, p: BotFishParams) {
        val designX = if (side < 0) 399.0 else 624.0
        val designY = 603.0
        val open = BotFishMath.clamp((if (side < 0) p.eyeL else p.eyeR) * p.blink, 0.0, 1.2)
        val happy = BotFishMath.clamp(p.joy, 0.0, 1.0)
        val centerX = designX(designX)
        val centerY = designY(designY)
        val designToPixel = BotFishGeometry.DESIGN_SCALE * pixelScale
        // The eye texture and its clip move together by `gaze * 2` / `* 1.2`
        // design units; the iris gets an additional clamped `* 8` / `* 6`
        // (`BotFishRenderer.swift:578-586`).
        val irisX = BotFishMath.clamp(p.gazeX, -1.0, 1.0) * 8 * p.gazeEmphasis
        val irisY = BotFishMath.clamp(p.gazeY, -1.0, 1.0) * 6 * p.gazeEmphasis
        val moving = abs(irisX) + abs(irisY) > 0.05
        val centerShiftX = p.gazeX * 2 * p.gazeEmphasis * designToPixel
        val centerShiftY = p.gazeY * 1.2 * p.gazeEmphasis * designToPixel

        canvas.save()
        canvas.translate(
            (centerX + centerShiftX).toFloat(),
            (centerY + centerShiftY).toFloat(),
        )
        canvas.scale(designToPixel.toFloat(), designToPixel.toFloat())
        if (open > 1) {
            val expansion = 1 + (open - 1) * 0.55
            canvas.scale(expansion.toFloat(), expansion.toFloat())
        }
        if (open < 0.14) {
            canvas.translate(0f, BotFishMath.lerp(29.0, 3.0, happy).toFloat())
            strokeCap = Paint.Cap.ROUND
            strokeStyle(6.5, BotFishPaint.DESIGN_INK)
            path.reset()
            path.moveTo(-58f, 8f)
            path.quadTo(0f, if (happy > 0.35) -18f else 13f, 58f, 8f)
            canvas.drawPath(path, shapePaint)
            strokeStyle(3.3, BotFishPaint.DESIGN_INK)
            path.reset()
            path.moveTo((side * 49).toFloat(), 4f)
            path.lineTo((side * 62).toFloat(), -2f)
            canvas.drawPath(path, shapePaint)
            canvas.restore()
            return
        }

        val h = 64 * open
        val w = 76.0
        val tilt = p.anger * (-side) * 13 + p.sorrow * side * 6
        val descent = (1 - min(open, 1.0)) * BotFishMath.lerp(52.0, 22.0, happy)
        val lid = open < 0.96 || p.anger > 0.1 || p.sorrow > 0.1

        canvas.save()
        canvas.clipRect(-102f, -96f, 102f, 94f)
        if (lid) {
            canvas.translate(0f, descent.toFloat())
            eyePath(w, h, tilt)
            canvas.clipPath(path)
            canvas.translate(0f, (-descent).toFloat())
        }
        // Back to pixel units; the clip above lives in device space, exactly
        // like the Core Graphics clip (`BotFishRenderer.swift:626-629`).
        canvas.scale((1 / designToPixel).toFloat(), (1 / designToPixel).toFloat())
        val eyeCrop = eyeCropRect(side)
        val eyeOriginX = (eyeCrop.left - crop.originX) * pixelScale
        val eyeOriginY = (eyeCrop.top - crop.originY) * pixelScale
        // Both the upstream clip and the eye texture translate together, so
        // the cropped texture can stay at a fixed offset from the eye centre.
        val localX = eyeOriginX - centerX
        val localY = eyeOriginY - centerY
        val eye = eyeBaseImage(side, moving)
        if (eye != null) {
            rect.set(
                localX.toFloat(), localY.toFloat(),
                (localX + eye.width).toFloat(), (localY + eye.height).toFloat(),
            )
            canvas.drawBitmap(eye, null, rect, imagePaint)
        }
        if (moving) {
            val irisSource = renderer.bitmap(
                if (side < 0) "base/iris-left.png" else "base/iris-right.png",
            )
            val iris = irisSource?.let { eyeBaseImage(it, side, "iris") }
            if (iris != null) {
                canvas.save()
                canvas.translate(
                    (irisX * designToPixel).toFloat(),
                    (irisY * designToPixel).toFloat(),
                )
                rect.set(
                    localX.toFloat(), localY.toFloat(),
                    (localX + iris.width).toFloat(), (localY + iris.height).toFloat(),
                )
                canvas.drawBitmap(iris, null, rect, imagePaint)
                canvas.restore()
            }
        }
        if (p.love > 0.05) {
            canvas.save()
            val heartX = if (side < 0) 410.5 else 625.5
            canvas.translate(((heartX - designX) * designToPixel).toFloat(), 0f)
            canvas.scale(designToPixel.toFloat(), designToPixel.toFloat())
            heart(0.0, 0.0, 24.0, BotFishPaint.EYE_HEART, p.love)
            canvas.restore()
        }
        canvas.restore()

        if (lid) {
            canvas.save()
            canvas.translate(0f, descent.toFloat())
            strokeCap = Paint.Cap.ROUND
            strokeStyle(7.0, BotFishPaint.DESIGN_INK)
            lidPath(w, h, tilt)
            canvas.drawPath(path, shapePaint)
            canvas.restore()
        }
        canvas.restore()
    }

    /** The source-space crop around one default eye (`:686-696`). */
    private fun eyeCropRect(side: Double): Rect {
        val designX = if (side < 0) 399.0 else 624.0
        val designY = 603.0
        val centerX = BotFishGeometry.PAD + BotFishGeometry.DESIGN_SCALE * designX
        val centerY = BotFishGeometry.PAD + BotFishGeometry.DESIGN_SCALE * designY
        val margin = 18.0
        val halfWidth = 102 * BotFishGeometry.DESIGN_SCALE + margin
        val halfHeight = 96 * BotFishGeometry.DESIGN_SCALE + margin
        // CGRect.integral: floor the origin, ceil the far edge.
        return Rect(
            floor(centerX - halfWidth).toInt(),
            floor(centerY - halfHeight).toInt(),
            ceil(centerX + halfWidth).toInt(),
            ceil(centerY + halfHeight).toInt(),
        )
    }

    /** Port of `eyeBaseImage(side:moving:)` (`BotFishRenderer.swift:698-703`). */
    private fun eyeBaseImage(side: Double, moving: Boolean): Bitmap? {
        val source = renderer.bitmap(
            if (moving) "base/eyes-white.png" else "base/eyes-open.png",
        ) ?: return null
        return eyeBaseImage(source, side, if (moving) "eyes-white" else "eyes-open")
    }

    /** Port of `eyeBaseImage(image:side:key:)` (`BotFishRenderer.swift:705-714`). */
    private fun eyeBaseImage(source: Bitmap, side: Double, key: String): Bitmap? {
        val cropRect = eyeCropRect(side)
        val width = max(1, BotFishMath.roundHalfAway(cropRect.width() * pixelScale).toInt())
        val height = max(1, BotFishMath.roundHalfAway(cropRect.height() * pixelScale).toInt())
        return renderer.croppedPart(
            source,
            cropRect,
            "$key:${if (side < 0) "l" else "r"}:$cropTag@$pixelSide",
            width,
            height,
        )
    }

    /** Port of `eyeCelImage` (`BotFishRenderer.swift:716-723`). */
    private fun eyeCelImage(cel: Int, sidePixels: Int): Bitmap? {
        val source = renderer.bitmap("expressive/eyes.png") ?: return null
        val name = cel / 2
        val half = cel % 2
        val x = (name % 3) * 256 + half * 128
        val y = (name / 3) * 128
        return renderer.scaledPart(
            source,
            Rect(x, y, x + 128, y + 128),
            "eye-cel:$cel:$cropTag@$pixelSide:$sidePixels",
            sidePixels,
            sidePixels,
        )
    }

    /** Port of `eyePath` (`BotFishRenderer.swift:725-738`). */
    private fun eyePath(w: Double, h: Double, tilt: Double) {
        path.reset()
        path.moveTo((-w).toFloat(), 3f)
        path.cubicTo(
            (-w * 0.88).toFloat(), (-h * 0.76 - tilt).toFloat(),
            (-w * 0.22).toFloat(), (-h * 1.12).toFloat(),
            (w * 0.43).toFloat(), (-h * 0.82 + tilt).toFloat(),
        )
        path.cubicTo(
            (w * 0.88).toFloat(), (-h * 0.63 + tilt).toFloat(),
            (w * 1.08).toFloat(), (-h * 0.05).toFloat(),
            w.toFloat(), (h * 0.27).toFloat(),
        )
        path.lineTo(104f, 100f)
        path.lineTo(-104f, 100f)
        path.close()
    }

    /** Port of `lidPath` (`BotFishRenderer.swift:740-750`). */
    private fun lidPath(w: Double, h: Double, tilt: Double) {
        path.reset()
        path.moveTo((-w).toFloat(), 3f)
        path.cubicTo(
            (-w * 0.88).toFloat(), (-h * 0.76 - tilt).toFloat(),
            (-w * 0.22).toFloat(), (-h * 1.12).toFloat(),
            (w * 0.43).toFloat(), (-h * 0.82 + tilt).toFloat(),
        )
        path.cubicTo(
            (w * 0.72).toFloat(), (-h * 0.68 + tilt).toFloat(),
            (w * 0.91).toFloat(), (-h * 0.39).toFloat(),
            (w * 0.98).toFloat(), (-h * 0.12).toFloat(),
        )
    }

    // MARK: - Brows (BotFishRenderer.swift:752-794)

    /**
     * Brows are stroked in design space, then masked with the hairstyle
     * `face-mask.png` using the Core Graphics `destinationIn` blend. The Swift
     * routine asks `assets.layers(for: hairstyle)` without `crowned:` and takes
     * the default 416 px crop (`BotFishAssets.swift:150-179`,
     * `BotFishImageCache.swift:63-86`), so the plain mask and plain crop are
     * reproduced here even for a crowned avatar.
     */
    private fun paintBrows(p: BotFishParams) {
        if (abs(p.browL) + abs(p.browR) + p.anger + p.sorrow < 0.02) return
        val maskSource = renderer.bitmap("${plainFolder()}/face-mask.png") ?: return
        val scratch = renderer.browScratch(target)
        val browCanvas = scratch.second
        browCanvas.save()
        browCanvas.translate(
            ((BotFishGeometry.PAD - crop.originX) * pixelScale).toFloat(),
            ((BotFishGeometry.PAD - crop.originY) * pixelScale).toFloat(),
        )
        val designScale = (BotFishGeometry.DESIGN_SCALE * pixelScale).toFloat()
        browCanvas.scale(designScale, designScale)
        val browPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        browPaint.style = Paint.Style.STROKE
        browPaint.strokeWidth = 2.7f
        browPaint.color = BotFishPaint.BROW
        browPaint.strokeCap = Paint.Cap.ROUND
        val browPath = Path()
        val rows = listOf(
            Triple(399.0, p.browL, -1.0),
            Triple(624.0, p.browR, 1.0),
        )
        for ((cx, value, sideSign) in rows) {
            browCanvas.save()
            browCanvas.translate(cx.toFloat(), (527 - value * 8).toFloat())
            browCanvas.rotate(
                Math.toDegrees(-sideSign * p.anger * 0.22 + sideSign * p.sorrow * 0.20)
                    .toFloat(),
            )
            browPath.reset()
            browPath.moveTo(-26f, 0f)
            browPath.quadTo(0f, -5f, 26f, 0f)
            browCanvas.drawPath(browPath, browPaint)
            browCanvas.restore()
        }
        browCanvas.restore()

        val mask = renderer.croppedLayer(
            maskSource,
            "face-mask:${hairstyle.wire}:$cropTag@$pixelSide",
            target,
        ) ?: return
        maskPaint.xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN)
        browCanvas.drawBitmap(mask, 0f, 0f, maskPaint)
        maskPaint.xfermode = null

        setAlpha(255)
        canvas.drawBitmap(scratch.first, 0f, 0f, imagePaint)
    }

    private fun plainFolder(): String =
        if (hairstyle == BotFishHairstyle.LONG) "base" else "hair/${hairstyle.wire}"

    // MARK: - Mouth (BotFishRenderer.swift:796-894)

    /** Port of `paintMouthCrossfade` (`BotFishRenderer.swift:798-812`). */
    private fun paintMouthCrossfade(p: BotFishParams) {
        if (p.artMix < 1 && p.mouthArtPrev != p.mouthArt) {
            setAlpha((BotFishMath.clamp(1 - p.artMix, 0.0, 1.0) * 255).roundToInt())
            paintMouthLayer(p, p.mouthArtPrev)
            setAlpha((BotFishMath.clamp(p.artMix, 0.0, 1.0) * 255).roundToInt())
            paintMouthLayer(p, p.mouthArt)
            setAlpha(255)
            return
        }
        paintMouthLayer(p, p.mouthArt)
    }

    /** Port of `paintMouthLayer` (`BotFishRenderer.swift:814-832`). */
    private fun paintMouthLayer(p: BotFishParams, art: String?) {
        val index = BotFishMouthCel.indexOf(art)
        if (index != null) {
            val w = 90 * p.mouthWidth
            val width = max(1, BotFishMath.roundHalfAway(w * pixelScale).toInt())
            val height = max(1, BotFishMath.roundHalfAway(w / 2 * pixelScale).toInt())
            val bucket = BotFishMath.roundHalfAway(p.mouthWidth / 0.02).toInt()
            val image = mouthCelImage(index, bucket, width, height)
            if (image != null) {
                val x = (256 - w / 2 - crop.originX) * pixelScale
                val y = (335 - w / 4 - crop.originY) * pixelScale
                rect.set(x.toFloat(), y.toFloat(), (x + width).toFloat(), (y + height).toFloat())
                canvas.drawBitmap(image, null, rect, imagePaint)
            }
            return
        }
        paintMouth(p)
    }

    /** Port of `mouthCelImage` (`BotFishRenderer.swift:834-841`). */
    private fun mouthCelImage(
        index: Int,
        bucket: Int,
        width: Int,
        height: Int,
    ): Bitmap? {
        val source = renderer.bitmap("expressive/mouths.png") ?: return null
        val x = (index % 3) * 256
        val y = (index / 3) * 128
        return renderer.scaledPart(
            source,
            Rect(x, y, x + 256, y + 128),
            "mouth-cel:$index:$bucket:$cropTag@$pixelSide:${width}x$height",
            width,
            height,
        )
    }

    /** Port of `paintMouth` (`BotFishRenderer.swift:843-894`). */
    private fun paintMouth(p: BotFishParams) {
        withDesignSpace {
            canvas.translate(512f, 693f)
            val w = 34 * p.mouthWidth
            val open = BotFishMath.clamp(p.mouth, 0.0, 1.0)
            strokeCap = Paint.Cap.ROUND
            if (open < 0.045) {
                path.reset()
                path.moveTo((-w).toFloat(), -2f)
                path.cubicTo(
                    (-w * 0.45).toFloat(), (19 * p.smile).toFloat(),
                    (w * 0.45).toFloat(), (19 * p.smile).toFloat(),
                    w.toFloat(), -2f,
                )
                strokeStyle(3.4, BotFishPaint.MOUTH_SMILE)
                canvas.drawPath(path, shapePaint)
            } else {
                val h = 8 + open * 43
                val round = p.round
                path.reset()
                path.moveTo((-w).toFloat(), 0f)
                path.cubicTo(
                    (-w * 0.7).toFloat(), (-7 - round * 5).toFloat(),
                    (w * 0.7).toFloat(), (-7 - round * 5).toFloat(),
                    w.toFloat(), 0f,
                )
                path.cubicTo(
                    (w * 0.94).toFloat(), (h * 1.15).toFloat(),
                    (-w * 0.94).toFloat(), (h * 1.15).toFloat(),
                    (-w).toFloat(), 0f,
                )
                path.close()
                fillStyle(BotFishPaint.MOUTH_FILL)
                canvas.drawPath(path, shapePaint)
                strokeStyle(2.8, BotFishPaint.MOUTH_STROKE)
                canvas.drawPath(path, shapePaint)
                canvas.save()
                canvas.clipPath(path)
                fillStyle(BotFishPaint.MOUTH_TONGUE)
                rect.set(
                    (2 - w * 0.66).toFloat(), (h * 0.94 - h * 0.36).toFloat(),
                    (2 - w * 0.66 + w * 1.32).toFloat(), (h * 0.94 - h * 0.36 + h * 0.72).toFloat(),
                )
                canvas.drawOval(rect, shapePaint)
                if (p.joy > 0.7) {
                    fillStyle(BotFishPaint.MOUTH_TEETH)
                    rect.set((-w).toFloat(), -6f, w.toFloat(), 4f)
                    canvas.drawRect(rect, shapePaint)
                }
                canvas.restore()
            }
        }
    }

    // MARK: - Tears (BotFishRenderer.swift:896-924)

    /** Port of `paintTears` (`BotFishRenderer.swift:898-924`). */
    private fun paintTears(p: BotFishParams, timeMs: Double) {
        withDesignSpace {
            for ((x, offset) in TEAR_ANCHORS) {
                val q = (timeMs / 1900 + offset) % 1.0
                val y = 658 + q * 75
                setAlpha(
                    (BotFishMath.clamp(p.tears * sin(q * PI), 0.0, 1.0) * 255)
                        .roundToInt(),
                )
                path.reset()
                path.moveTo(x.toFloat(), (y - 9).toFloat())
                path.cubicTo(
                    (x - 13).toFloat(), (y + 14).toFloat(),
                    (x + 13).toFloat(), (y + 14).toFloat(),
                    x.toFloat(), (y - 9).toFloat(),
                )
                fillStyle(BotFishPaint.TEAR_FILL)
                canvas.drawPath(path, shapePaint)
                strokeStyle(1.5, BotFishPaint.TEAR_STROKE)
                canvas.drawPath(path, shapePaint)
            }
            setAlpha(255)
        }
    }

    // MARK: - Fins (BotFishRenderer.swift:926-964)

    /** Port of `paintFin` (`BotFishRenderer.swift:926-964`). */
    private fun paintFin(side: Double, amount: Double, wave: Double, fold: Double) {
        if (amount < 0.05) return
        withSourceSpace {
            setAlpha(
                (BotFishMath.clamp((amount - 0.05) / 0.35, 0.0, 1.0) * 255).roundToInt(),
            )
            canvas.save()
            canvas.translate(
                ((if (side < 0) 111.0 else 401.0) - side * fold * 82).toFloat(),
                (402 - amount * 12).toFloat(),
            )
            canvas.scale(side.toFloat(), 1f)
            canvas.rotate(
                Math.toDegrees(-0.42 * amount + wave * 0.45 + fold * 0.7).toFloat(),
            )
            path.reset()
            path.moveTo(-9f, 7f)
            path.cubicTo(9f, -6f, 17f, -22f, 25f, -42f)
            path.cubicTo(29f, -53f, 39f, -59f, 43f, -55f)
            path.cubicTo(48f, -52f, 43f, -37f, 41f, -31f)
            path.cubicTo(51f, -39f, 57f, -34f, 52f, -24f)
            path.cubicTo(61f, -28f, 64f, -20f, 55f, -11f)
            path.cubicTo(35f, 7f, 11f, 18f, -9f, 7f)
            path.close()
            fillStyle(rgb(palette.mid))
            canvas.drawPath(path, shapePaint)
            strokeStyle(2.2, rgb(palette.ink))
            canvas.drawPath(path, shapePaint)
            fillStyle(rgb(palette.light))
            path.reset()
            path.moveTo(4f, 5f)
            path.quadTo(30f, -16f, 44f, -24f)
            path.quadTo(31f, 2f, 4f, 5f)
            canvas.drawPath(path, shapePaint)
            canvas.restore()
            setAlpha(255)
        }
    }

    // MARK: - Decorations (BotFishRenderer.swift:966-1139)

    /** Port of `paintDecorations` (`BotFishRenderer.swift:968-1139`). */
    private fun paintDecorations(p: BotFishParams) {
        val decoration = p.decoration
        if (decoration.isEmpty()) return
        val phase = p.phase
        val motion = p.motionScale
        withSourceSpace {
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            when (decoration) {
                "dots", "waiting" -> {
                    val x = if (decoration == "dots") 353.0 else 78.0
                    val y = if (decoration == "dots") 64.0 else 369.0
                    val radius = 3.6 * p.dotScale
                    val spacing = 13.0 * p.dotScale
                    for (index in 0..2) {
                        var lift = 0.0
                        val dotAlpha: Double
                        if (p.dotLift > 0.01) {
                            // Lively: the three dots hop in turn (0.12 s apart)
                            // instead of only fading.
                            val local = phase - index * p.dotStagger
                            val wave = max(0.0, sin(local * TAU))
                            lift = p.dotLift * wave
                            dotAlpha = 0.45 + 0.55 * wave
                        } else {
                            dotAlpha = 0.35 + 0.65 *
                                (0.5 + 0.5 * sin(phase * TAU - index * 0.7))
                        }
                        setAlpha((BotFishMath.clamp(dotAlpha, 0.0, 1.0) * 255).roundToInt())
                        fillStyle(rgb(palette.ink))
                        rect.set(
                            (x + index * spacing - radius).toFloat(),
                            (y - radius - lift).toFloat(),
                            (x + index * spacing + radius).toFloat(),
                            (y - radius - lift + radius * 2).toFloat(),
                        )
                        canvas.drawOval(rect, shapePaint)
                    }
                }
                "alert" -> {
                    strokeStyle(5.0, BotFishPaint.ALERT)
                    path.reset()
                    path.moveTo(418f, 75f)
                    path.lineTo(418f, 95f)
                    canvas.drawPath(path, shapePaint)
                    fillStyle(BotFishPaint.ALERT)
                    rect.set(415f, 102f, 421f, 108f)
                    canvas.drawOval(rect, shapePaint)
                }
                "question" -> {
                    strokeStyle(4.2, BotFishPaint.QUESTION)
                    path.reset()
                    path.moveTo(402f, 83f)
                    path.cubicTo(400f, 65f, 426f, 63f, 429f, 79f)
                    path.cubicTo(430f, 90f, 415f, 89f, 416f, 101f)
                    canvas.drawPath(path, shapePaint)
                    fillStyle(BotFishPaint.QUESTION)
                    rect.set(413.5f, 108.5f, 418.5f, 113.5f)
                    canvas.drawOval(rect, shapePaint)
                }
                "sleep" -> {
                    val r = 10 + 3 * motion * sin(phase * TAU)
                    strokeStyle(1.4, BotFishPaint.SLEEP_STROKE)
                    fillStyle(BotFishPaint.SLEEP_FILL)
                    rect.set(
                        (407 - r).toFloat(), (177 - r).toFloat(),
                        (407 + r).toFloat(), (177 + r).toFloat(),
                    )
                    canvas.drawOval(rect, shapePaint)
                    strokeStyle(1.4, BotFishPaint.SLEEP_STROKE)
                    canvas.drawOval(rect, shapePaint)
                    drawZ(420.0, 132.0, 24.0, BotFishPaint.SLEEP_Z)
                    drawZ(441.0, 116.0, 16.0, BotFishPaint.SLEEP_Z)
                }
                "listen" -> {
                    strokeStyle(1.7, BotFishPaint.LISTEN)
                    for (side in listOf(-1.0, 1.0)) {
                        for (index in 0..1) {
                            setAlpha(
                                (BotFishMath.clamp(
                                    0.35 + 0.4 * (0.5 + 0.5 * sin(phase * TAU - index)),
                                    0.0,
                                    1.0,
                                ) * 255).roundToInt(),
                            )
                            val x = if (side < 0) 35.0 else 477.0
                            val radius = 10 + index * 8
                            rect.set(
                                (x - radius).toFloat(), (248 - radius).toFloat(),
                                (x + radius).toFloat(), (248 + radius).toFloat(),
                            )
                            val start = if (side < 0) 2.3 else -0.8
                            val end = if (side < 0) 4.0 else 0.8
                            canvas.drawArc(
                                rect,
                                Math.toDegrees(start).toFloat(),
                                Math.toDegrees(end - start).toFloat(),
                                false,
                                shapePaint,
                            )
                        }
                    }
                }
                "hearts" -> {
                    heart(
                        78.0, 140 - 8 * motion * sin(phase * TAU), 10.0,
                        BotFishPaint.HEART, 0.75,
                    )
                    heart(
                        420.0, 86 - 6 * motion * sin(phase * TAU + 1), 12.0,
                        BotFishPaint.HEART, 0.8,
                    )
                    heart(448.0, 122.0, 6.0, BotFishPaint.HEART_LIGHT, 0.7)
                }
                "spark" -> {
                    strokeStyle(2.0, BotFishPaint.SPARK)
                    for ((x, y, r) in SPARKS) {
                        path.reset()
                        path.moveTo((x - r).toFloat(), y.toFloat())
                        path.lineTo((x + r).toFloat(), y.toFloat())
                        path.moveTo(x.toFloat(), (y - r).toFloat())
                        path.lineTo(x.toFloat(), (y + r).toFloat())
                        canvas.drawPath(path, shapePaint)
                    }
                }
                "anger" -> {
                    strokeStyle(2.4, BotFishPaint.ANGER)
                    path.reset()
                    path.moveTo(376f, 180f)
                    path.lineTo(381f, 183f)
                    path.lineTo(386f, 179f)
                    path.moveTo(380f, 187f)
                    path.lineTo(383f, 191f)
                    canvas.drawPath(path, shapePaint)
                }
                "confetti" -> {
                    for (index in 0..11) {
                        val x = 44.0 + ((index * 83) % 420)
                        val travel = (phase * 125 * motion).toInt() + index * 31
                        val y = 35.0 + (travel % 154)
                        canvas.save()
                        canvas.translate(x.toFloat(), y.toFloat())
                        canvas.rotate(
                            Math.toDegrees(index + phase * TAU).toFloat(),
                        )
                        fillStyle(CONFETTI[index % 4])
                        rect.set(-2f, -4f, 2f, 4f)
                        canvas.drawRect(rect, shapePaint)
                        canvas.restore()
                    }
                }
                "loading" -> {
                    for (index in 0..7) {
                        val a = index * TAU / 8 + phase * TAU
                        setAlpha(
                            (BotFishMath.clamp(0.25 + 0.75 * index / 8, 0.0, 1.0) * 255)
                                .roundToInt(),
                        )
                        fillStyle(rgb(palette.ink))
                        rect.set(
                            (418 + cos(a) * 18 - 2.5).toFloat(),
                            (96 + sin(a) * 18 - 2.5).toFloat(),
                            (418 + cos(a) * 18 + 2.5).toFloat(),
                            (96 + sin(a) * 18 + 2.5).toFloat(),
                        )
                        canvas.drawOval(rect, shapePaint)
                    }
                }
                "check" -> {
                    strokeStyle(4.0, BotFishPaint.CHECK)
                    path.reset()
                    path.moveTo(401f, 92f)
                    path.lineTo(412f, 103f)
                    path.lineTo(433f, 79f)
                    canvas.drawPath(path, shapePaint)
                }
                "music" -> {
                    for ((x, y) in MUSIC) {
                        strokeStyle(2.8, BotFishPaint.MUSIC)
                        path.reset()
                        path.moveTo(x.toFloat(), y.toFloat())
                        path.lineTo(x.toFloat(), (y - 22).toFloat())
                        path.lineTo((x + 13).toFloat(), (y - 26).toFloat())
                        canvas.drawPath(path, shapePaint)
                        fillStyle(BotFishPaint.MUSIC)
                        rect.set(
                            (x - 9).toFloat(), (y - 3).toFloat(),
                            (x + 1).toFloat(), (y + 3).toFloat(),
                        )
                        canvas.drawOval(rect, shapePaint)
                    }
                }
            }
            setAlpha(255)
        }
    }

    /** Port of `drawZ` (`BotFishRenderer.swift:1169-1179`). */
    private fun drawZ(x: Double, y: Double, size: Double, color: Int) {
        canvas.save()
        strokeStyle(max(1.0, size * 0.09), color)
        path.reset()
        path.moveTo(x.toFloat(), y.toFloat())
        path.lineTo((x + size * 0.62).toFloat(), y.toFloat())
        path.lineTo(x.toFloat(), (y + size * 0.7).toFloat())
        path.lineTo((x + size * 0.68).toFloat(), (y + size * 0.7).toFloat())
        canvas.drawPath(path, shapePaint)
        canvas.restore()
    }

    /** `heart` from `BotFishRenderer.swift:1181-1198`. */
    private fun heart(x: Double, y: Double, r: Double, color: Int, alpha: Double = 1.0) {
        val previous = this.alpha
        canvas.save()
        if (alpha < 1) setAlpha((BotFishMath.clamp(alpha, 0.0, 1.0) * 255).roundToInt())
        fillStyle(color)
        canvas.translate(x.toFloat(), y.toFloat())
        path.reset()
        path.moveTo(0f, (r * 0.8).toFloat())
        path.cubicTo(
            (-r * 1.5).toFloat(), (-r * 0.1).toFloat(),
            (-r * 0.8).toFloat(), (-r * 1.1).toFloat(),
            0f, (-r * 0.35).toFloat(),
        )
        path.cubicTo(
            (r * 0.8).toFloat(), (-r * 1.1).toFloat(),
            (r * 1.5).toFloat(), (-r * 0.1).toFloat(),
            0f, (r * 0.8).toFloat(),
        )
        canvas.drawPath(path, shapePaint)
        canvas.restore()
        setAlpha(previous)
    }

    // MARK: - Paint state

    private fun setAlpha(value: Int) {
        alpha = value.coerceIn(0, 255)
        imagePaint.alpha = alpha
        shapePaint.alpha = alpha
    }

    private fun fillStyle(color: Int) {
        shapePaint.style = Paint.Style.FILL
        shapePaint.color = color
    }

    private fun strokeStyle(width: Double, color: Int) {
        shapePaint.style = Paint.Style.STROKE
        shapePaint.color = color
        shapePaint.strokeWidth = width.toFloat()
        shapePaint.strokeCap = strokeCap
        shapePaint.strokeJoin = strokeJoin
    }

    private fun drawFull(bitmap: Bitmap) {
        rect.set(0f, 0f, target.toFloat(), target.toFloat())
        canvas.drawBitmap(bitmap, null, rect, imagePaint)
    }

    /** Port of `designPoint` x (`BotFishRenderer.swift:1253-1258`). */
    private fun designX(value: Double): Double =
        (BotFishGeometry.PAD + BotFishGeometry.DESIGN_SCALE * value - crop.originX) * pixelScale

    /** Port of `designPoint` y (`BotFishRenderer.swift:1253-1258`). */
    private fun designY(value: Double): Double =
        (BotFishGeometry.PAD + BotFishGeometry.DESIGN_SCALE * value - crop.originY) * pixelScale

    /** `withDesignSpace` (`BotFishRenderer.swift:1260-1268`). */
    private inline fun withDesignSpace(body: () -> Unit) {
        canvas.save()
        canvas.translate(
            ((BotFishGeometry.PAD - crop.originX) * pixelScale).toFloat(),
            ((BotFishGeometry.PAD - crop.originY) * pixelScale).toFloat(),
        )
        canvas.scale(
            (BotFishGeometry.DESIGN_SCALE * pixelScale).toFloat(),
            (BotFishGeometry.DESIGN_SCALE * pixelScale).toFloat(),
        )
        body()
        canvas.restore()
    }

    /** `withSourceSpace` (`BotFishRenderer.swift:1270-1277`). */
    private inline fun withSourceSpace(body: () -> Unit) {
        canvas.save()
        canvas.translate(
            (-crop.originX * pixelScale).toFloat(),
            (-crop.originY * pixelScale).toFloat(),
        )
        canvas.scale(pixelScale.toFloat(), pixelScale.toFloat())
        body()
        canvas.restore()
    }

    private companion object {
        const val TAU: Double = PI * 2
        val TEAR_ANCHORS = listOf(345.0 to 0.0, 680.0 to 0.45)
        val SPARKS = listOf(Triple(80.0, 140.0, 8.0), Triple(425.0, 89.0, 9.0))
        val MUSIC = listOf(77.0 to 133.0, 427.0 to 112.0)

        fun rgb(rgb: IntArray): Int =
            0xFF000000.toInt() or (rgb[0].coerceIn(0, 255) shl 16) or
                (rgb[1].coerceIn(0, 255) shl 8) or rgb[2].coerceIn(0, 255)

        val CONFETTI = intArrayOf(
            0xFFD77C90.toInt(),
            0xFFD4AD57.toInt(),
            0xFF6DAEA5.toInt(),
            0xFF9B83C0.toInt(),
        )
    }
}

/**
 * The fixed colours of the Swift painting code. Each entry cites the
 * `BotFishRenderer.swift` line range that creates it, so a palette drift in
 * the Swift source is visible here without opening the app.
 */
internal object BotFishPaint {
    /** `designInk` (`BotFishRenderer.swift:97-98`). */
    const val DESIGN_INK: Int = 0xFF21192D.toInt()

    /** Brows: 52,37,58 @ 0.58 (`BotFishRenderer.swift:773-774`). */
    const val BROW: Int = 0x9434253A.toInt()

    /** Closed-mouth stroke: 198,96,88 (`:854-856`). */
    const val MOUTH_SMILE: Int = 0xFFC66058.toInt()

    /** Open-mouth fill: 116,44,68 (`:870-871`). */
    const val MOUTH_FILL: Int = 0xFF742C44.toInt()

    /** Open-mouth stroke: 185,91,97 (`:874-875`). */
    const val MOUTH_STROKE: Int = 0xFFB95B61.toInt()

    /** Tongue: 242,141,156 (`:882-883`). */
    const val MOUTH_TONGUE: Int = 0xFFF28D9C.toInt()

    /** Teeth: 255,250,247 (`:887-888`). */
    const val MOUTH_TEETH: Int = 0xFFFFFAF7.toInt()

    /** Tears fill/stroke: 142,214,240 / 104,170,203 (`:904-907`). */
    const val TEAR_FILL: Int = 0xFF8ED6F0.toInt()
    const val TEAR_STROKE: Int = 0xFF68AACB.toInt()

    /** Love heart in the eye: 223,77,136 (`:662-665`). */
    const val EYE_HEART: Int = 0xFFDF4D88.toInt()

    /** `alert`: 206,94,73 (`:1005-1012`). */
    const val ALERT: Int = 0xFFCE5E49.toInt()

    /** `question`: 116,96,152 (`:1015-1025`). */
    const val QUESTION: Int = 0xFF746098.toInt()

    /** `sleep`: stroke 138,172,192; fill 175,214,232 @ .3 (`:1029-1032`). */
    const val SLEEP_STROKE: Int = 0xFF8AACC0.toInt()
    const val SLEEP_FILL: Int = 0x4DAFD6E8.toInt()

    /** Sleep `Z`: 126,149,175 (`:1037-1041`). */
    const val SLEEP_Z: Int = 0xFF7E95AF.toInt()

    /** `listen`: 105,166,181 (`:1043-1044`). */
    const val LISTEN: Int = 0xFF69A6B5.toInt()

    /** Decorations hearts: 230,109,159 and 241,160,188 (`:1057-1065`). */
    const val HEART: Int = 0xFFE66D9F.toInt()
    const val HEART_LIGHT: Int = 0xFFF1A0BC.toInt()

    /** `spark`: 225,172,86 (`:1067-1068`). */
    const val SPARK: Int = 0xFFE1AC56.toInt()

    /** `anger`: 190,104,109 (`:1078-1079`). */
    const val ANGER: Int = 0xFFBE686D.toInt()

    /** `check`: 66,152,121 (`:1114-1115`). */
    const val CHECK: Int = 0xFF429879.toInt()

    /** `music`: 151,128,183 (`:1122-1125`). */
    const val MUSIC: Int = 0xFF9780B7.toInt()

    /** Crown shadow: 27,31,55 @ 0.24 (`:1159-1161`). */
    const val CROWN_SHADOW: Int = 0x3D1B1F37.toInt()
}
