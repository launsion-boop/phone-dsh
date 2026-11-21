// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.media.ExifInterface
import android.os.ParcelFileDescriptor
import com.phonedsh.bot.attachments.BotAttachmentPolicy
import com.phonedsh.bot.attachments.BotModelAttachmentRequest
import com.phonedsh.bot.attachments.BotModelImage
import com.phonedsh.bot.attachments.BotModelImageError
import com.phonedsh.bot.attachments.BotModelImageException
import com.phonedsh.bot.attachments.BotModelImagePolicy
import com.phonedsh.bot.mcp.BotModelImageReader
import com.phonedsh.ui.surface.preview.PreviewPathResolver
import com.phonedsh.ui.surface.preview.PreviewResolution
import com.phonedsh.ui.surface.preview.PreviewUnresolved
import com.phonedsh.ui.surface.preview.PreviewWorkspace
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** The platform decode/encode seam; tests substitute a deterministic image. */
public fun interface BotModelImageCodec {
    public fun prepare(data: ByteArray, name: String): BotModelImage
}

/** The platform PDF rasterizer seam; tests substitute a deterministic page. */
public fun interface BotModelPdfPageRenderer {
    public fun render(file: Path, page: Int): BotModelImage
}

/**
 * App-side bridge from a materialized `/dsh/workspace` file to model-ready
 * image bytes (`BotWorkspaceModelImage` in the Swift reference).
 *
 * The resolver is the same containment boundary the document preview uses:
 * it normalizes `/dsh/workspace/...`, rejects `..`, requires the resolved
 * regular file to stay under the materialized workspace root (including after
 * symlink resolution) and never reads an absolute path outside it. The reader
 * adds the P26 input bound, the platform decode, the PDF page choice and the
 * 1568 px / 1 MiB output budget.
 *
 * `fileId` (OfficeArtifactStore) and `photoId` (Photos localIdentifier) have
 * no Android backing store yet. They are refused as `unsupported` with a
 * message naming the missing source instead of silently reading a lookalike
 * file; a missing/undecodable workspace file is `image_unavailable`.
 */
public class AppBotModelImageReader(
    private val workspaceRoot: Path?,
    private val codec: BotModelImageCodec = AndroidBotModelImageCodec,
    private val pdfRenderer: BotModelPdfPageRenderer = AndroidBotModelPdfRenderer,
    private val maxInputBytes: Long = BotAttachmentPolicy.MAX_BYTES,
) : BotModelImageReader {

    /** The App composition's single-line construction from its Context. */
    public constructor(context: Context) : this(
        PreviewWorkspace.defaultRoot(context.filesDir),
    )

    override suspend fun read(request: BotModelAttachmentRequest): BotModelImage =
        withContext(Dispatchers.IO) {
            val fileId = request.fileId?.trim().orEmpty()
            if (fileId.isNotEmpty()) {
                throw BotModelImageException(
                    BotModelImageError.UNSUPPORTED,
                    "Android 版暂不支持 fileId 来源（相机产物存储未接入）；请改用工作区 path",
                )
            }
            val photoId = request.photoId?.trim().orEmpty()
            if (photoId.isNotEmpty()) {
                throw BotModelImageException(
                    BotModelImageError.UNSUPPORTED,
                    "Android 版暂不支持 photoId 来源（相册 localIdentifier 不可用）；请改用工作区 path",
                )
            }
            val path = request.path?.trim().orEmpty()
            if (path.isEmpty()) {
                throw BotModelImageException(
                    BotModelImageError.UNSUPPORTED,
                    "没有可读取的工作区图片路径",
                )
            }
            val resolved = when (val resolution = PreviewPathResolver.resolve(workspaceRoot, path)) {
                is PreviewResolution.Resolved -> resolution
                is PreviewResolution.Unresolved -> throw BotModelImageException(
                    BotModelImageError.UNAVAILABLE,
                    unavailableMessage(resolution.reason),
                )
            }
            if (resolved.sizeBytes > maxInputBytes) {
                throw BotModelImageException(
                    BotModelImageError.TOO_LARGE,
                    "图片文件超过 ${maxInputBytes / (1024 * 1024)} MiB 的读取上限",
                )
            }
            val fileName = resolved.file.fileName?.toString().orEmpty()
            if (fileName.lowercase().endsWith(".pdf")) {
                // The tool schema advertises 1..8; a document with fewer pages
                // is refused by the renderer, never padded with a blank image.
                val page = (request.page ?: 1).coerceIn(1, 8)
                return@withContext pdfRenderer.render(resolved.file, page)
            }
            val data = readBounded(resolved.file)
            return@withContext codec.prepare(data, fileName)
        }

    private fun readBounded(file: Path): ByteArray {
        val output = ByteArrayOutputStream()
        try {
            Files.newInputStream(file).use { input ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > maxInputBytes) {
                        throw BotModelImageException(
                            BotModelImageError.TOO_LARGE,
                            "图片文件超过 ${maxInputBytes / (1024 * 1024)} MiB 的读取上限",
                        )
                    }
                    output.write(buffer, 0, read)
                }
            }
        } catch (error: BotModelImageException) {
            throw error
        } catch (error: IOException) {
            throw BotModelImageException(
                BotModelImageError.UNAVAILABLE,
                "图片读取失败：${error.message ?: error.javaClass.simpleName}",
            )
        }
        return output.toByteArray()
    }

    private fun unavailableMessage(reason: PreviewUnresolved): String = when (reason) {
        PreviewUnresolved.NO_WORKSPACE -> "工作区还没有就绪"
        PreviewUnresolved.MISSING -> "工作区里没有这个文件"
        PreviewUnresolved.NOT_A_FILE -> "这个路径不是普通文件"
        PreviewUnresolved.REJECTED -> "路径不在 Bot 的工作区内"
    }
}

/**
 * Android `BitmapFactory` decode/orient/scale plus the JPEG quality ladder.
 *
 * The source is sampled before allocation and the longest edge is capped at
 * [BotModelImagePolicy.MAX_DIMENSION]; the encoded bytes are kept at or below
 * [BotModelImagePolicy.MAX_ENCODED_BYTES]. Decode failures never fabricate an
 * image: they raise [BotModelImageException].
 */
public object AndroidBotModelImageCodec : BotModelImageCodec {

    override fun prepare(data: ByteArray, name: String): BotModelImage {
        if (data.isEmpty()) {
            throw BotModelImageException(BotModelImageError.EMPTY, "图片是空的")
        }
        return try {
            decode(data, name)
        } catch (error: BotModelImageException) {
            throw error
        } catch (error: OutOfMemoryError) {
            throw BotModelImageException(
                BotModelImageError.UNAVAILABLE,
                "图片太大，内存不足",
            )
        } catch (error: Throwable) {
            throw BotModelImageException(
                BotModelImageError.UNAVAILABLE,
                "图片解码失败：${error.message ?: error.javaClass.simpleName}",
            )
        }
    }

    private fun decode(data: ByteArray, name: String): BotModelImage {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw BotModelImageException(
                BotModelImageError.UNAVAILABLE,
                "不是可解码的图片",
            )
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize(
                bounds.outWidth,
                bounds.outHeight,
                BotModelImagePolicy.MAX_DIMENSION,
            )
        }
        val decoded = BitmapFactory.decodeByteArray(data, 0, data.size, options)
            ?: throw BotModelImageException(
                BotModelImageError.UNAVAILABLE,
                "图片解码失败",
            )
        var oriented: Bitmap = decoded
        try {
            oriented = orient(decoded, data)
            val scaled = scaleToFit(oriented, BotModelImagePolicy.MAX_DIMENSION)
            try {
                return encode(scaled, safeImageName(name))
            } finally {
                if (scaled !== oriented) scaled.recycle()
            }
        } finally {
            if (oriented !== decoded) oriented.recycle()
            decoded.recycle()
        }
    }

    private fun sampleSize(width: Int, height: Int, maxDimension: Int): Int {
        var sample = 1
        while (width / (sample * 2) >= maxDimension && height / (sample * 2) >= maxDimension) {
            sample *= 2
        }
        while (width / sample > maxDimension || height / sample > maxDimension) {
            sample *= 2
        }
        return sample
    }

    private fun orient(bitmap: Bitmap, data: ByteArray): Bitmap {
        val orientation = try {
            ExifInterface(ByteArrayInputStream(data)).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (_: Throwable) {
            ExifInterface.ORIENTATION_NORMAL
        }
        if (orientation == ExifInterface.ORIENTATION_NORMAL ||
            orientation == ExifInterface.ORIENTATION_UNDEFINED
        ) {
            return bitmap
        }
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(-90f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(
            bitmap,
            0,
            0,
            bitmap.width,
            bitmap.height,
            matrix,
            true,
        )
    }

    private fun scaleToFit(bitmap: Bitmap, maxDimension: Int): Bitmap {
        val longest = max(bitmap.width, bitmap.height)
        if (longest <= maxDimension) return bitmap
        val scale = maxDimension.toFloat() / longest
        val width = max(1, (bitmap.width * scale).roundToInt())
        val height = max(1, (bitmap.height * scale).roundToInt())
        return Bitmap.createScaledBitmap(bitmap, width, height, true)
    }

    internal fun encode(bitmap: Bitmap, safeName: String): BotModelImage {
        var quality = 82
        var encoded: ByteArray? = null
        while (quality >= 24) {
            val output = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output)) {
                throw BotModelImageException(
                    BotModelImageError.UNAVAILABLE,
                    "图片编码失败",
                )
            }
            encoded = output.toByteArray()
            if (encoded.size <= BotModelImagePolicy.MAX_ENCODED_BYTES) break
            quality -= 18
        }
        val bytes = encoded
        if (bytes == null || bytes.size > BotModelImagePolicy.MAX_ENCODED_BYTES) {
            throw BotModelImageException(
                BotModelImageError.TOO_LARGE,
                "压缩后仍超过 1 MiB 的图片上限",
            )
        }
        return BotModelImage(
            data = bytes,
            name = safeName,
            pixelWidth = bitmap.width,
            pixelHeight = bitmap.height,
        )
    }

    private fun safeImageName(name: String): String {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return "image.jpg"
        return if (trimmed.length <= 120) trimmed else trimmed.substring(0, 120)
    }
}

/**
 * Rasterizes one PDF page with the platform `PdfRenderer` (`PDFKit` on iOS).
 *
 * A scanned document has no reliable text layer, so a page image is more
 * honest than OCR guesswork. The page is painted on white, bounded to
 * [BotModelImagePolicy.MAX_DIMENSION] and then encoded by the same JPEG path
 * as a photo.
 */
public object AndroidBotModelPdfRenderer : BotModelPdfPageRenderer {

    override fun render(file: Path, page: Int): BotModelImage {
        if (page !in 1..8) {
            throw BotModelImageException(
                BotModelImageError.UNAVAILABLE,
                "PDF 页码必须在 1 到 8 之间",
            )
        }
        try {
            ParcelFileDescriptor.open(
                file.toFile(),
                ParcelFileDescriptor.MODE_READ_ONLY,
            ).use { descriptor ->
                PdfRenderer(descriptor).use { renderer ->
                    if (page > renderer.pageCount) {
                        throw BotModelImageException(
                            BotModelImageError.UNAVAILABLE,
                            "PDF 没有第 $page 页",
                        )
                    }
                    renderer.openPage(page - 1).use { pdfPage ->
                        if (pdfPage.width <= 0 || pdfPage.height <= 0) {
                            throw BotModelImageException(
                                BotModelImageError.UNAVAILABLE,
                                "PDF 页面尺寸无效",
                            )
                        }
                        val longest = max(pdfPage.width, pdfPage.height)
                        val scale = min(
                            1f,
                            BotModelImagePolicy.MAX_DIMENSION.toFloat() / longest,
                        )
                        val width = max(1, (pdfPage.width * scale).roundToInt())
                        val height = max(1, (pdfPage.height * scale).roundToInt())
                        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                        try {
                            bitmap.eraseColor(Color.WHITE)
                            pdfPage.render(
                                bitmap,
                                null,
                                null,
                                PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY,
                            )
                            val stem = file.fileName?.toString()
                                ?.substringBeforeLast('.', "")
                                ?.trim()
                                .orEmpty()
                                .ifEmpty { "document" }
                            return AndroidBotModelImageCodec.encode(
                                bitmap,
                                "$stem-p$page.jpg",
                            )
                        } finally {
                            bitmap.recycle()
                        }
                    }
                }
            }
        } catch (error: BotModelImageException) {
            throw error
        } catch (error: IOException) {
            throw BotModelImageException(
                BotModelImageError.UNAVAILABLE,
                "PDF 读取失败：${error.message ?: error.javaClass.simpleName}",
            )
        } catch (error: IllegalStateException) {
            // PdfRenderer throws this for a malformed or password-protected
            // document.
            throw BotModelImageException(
                BotModelImageError.UNAVAILABLE,
                "这个 PDF 无法渲染",
            )
        }
    }
}
