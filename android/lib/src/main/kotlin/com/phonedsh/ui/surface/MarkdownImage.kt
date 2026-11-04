// Standalone Markdown image loader and viewer.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.surface.preview.PreviewFileSource
import com.phonedsh.ui.surface.preview.PreviewResolution
import com.phonedsh.ui.surface.preview.PreviewUnresolved
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.file.Path
import kotlin.math.max
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Host-provided safe workspace roots for local Markdown image sources. */
public data class MarkdownImageSource(
    /** The workspace visible to the current chat/host, or null when none was reported. */
    public val workspaceFiles: PreviewFileSource? = null,
    /** Session-scoped roots keyed by the exact session id in `dsh-resource://file/session/<id>/…`. */
    public val sessionFilesById: Map<String, PreviewFileSource> = emptyMap(),
)

internal const val MARKDOWN_IMAGE_TAG: String = "pdsh.surface.markdown.image"
internal const val MARKDOWN_IMAGE_LOADING_TAG: String = "pdsh.surface.markdown.image.loading"
internal const val MARKDOWN_IMAGE_VIEWER_TAG: String = "pdsh.surface.markdown.image.viewer"

/** Small loader seam for tests; production uses bounded HTTP and BitmapFactory. */
internal fun interface MarkdownRemoteImageLoader {
    public suspend fun load(uri: URI): Bitmap?
}

internal data class MarkdownLocalImageRequest(
    val files: PreviewFileSource,
    val relativePath: String,
)

internal val LocalMarkdownRemoteImageLoader = androidx.compose.runtime.compositionLocalOf<MarkdownRemoteImageLoader> {
    BoundedMarkdownRemoteImageLoader
}

/** Loads one image from a safe local workspace root or an explicit HTTP(S) URL. */
internal suspend fun loadMarkdownImage(
    source: String,
    imageSource: MarkdownImageSource?,
    remoteLoader: MarkdownRemoteImageLoader,
): Bitmap? {
    val trimmed = source.trim()
    val uri = runCatching { URI(trimmed) }.getOrNull()
    val scheme = uri?.scheme?.lowercase()
    if (scheme == "http" || scheme == "https") {
        if (uri.host.isNullOrBlank() || uri.rawUserInfo != null) return null
        return try {
            remoteLoader.load(uri)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }
    val local = resolveMarkdownLocalImageRequest(trimmed, imageSource) ?: return null
    return try {
        when (val resolution = local.files.resolve(local.relativePath)) {
            is PreviewResolution.Resolved -> withContext(Dispatchers.IO) {
                decodeLocalImage(resolution.file)
            }
            is PreviewResolution.Unresolved -> when (resolution.reason) {
                PreviewUnresolved.MISSING,
                PreviewUnresolved.NO_WORKSPACE,
                PreviewUnresolved.REJECTED,
                PreviewUnresolved.NOT_A_FILE -> null
            }
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }
}

internal fun resolveMarkdownLocalImageRequest(
    raw: String,
    imageSource: MarkdownImageSource?,
): MarkdownLocalImageRequest? {
    val trimmed = raw.trim()
    val target = markdownLinkTarget(trimmed)
    return when (target) {
        is MarkdownLinkTarget.WorkspacePath -> imageSource?.workspaceFiles?.let {
            MarkdownLocalImageRequest(it, target.value)
        }
        is MarkdownLinkTarget.ResourceUri -> localResourceSource(trimmed, target, imageSource)
        is MarkdownLinkTarget.Uri -> null
        null -> {
            // The iOS image view accepts the explicit workspace mount path. Normalize it through
            // the resolver instead of treating arbitrary leading-slash paths as local files.
            if (trimmed.startsWith("/dsh/workspace/")) {
                imageSource?.workspaceFiles?.let { MarkdownLocalImageRequest(it, trimmed) }
            } else {
                null
            }
        }
    }
}

private fun localResourceSource(
    raw: String,
    target: MarkdownLinkTarget.ResourceUri,
    imageSource: MarkdownImageSource?,
): MarkdownLocalImageRequest? {
    val uri = runCatching { URI(target.value) }.getOrNull() ?: return null
    return when (uri.scheme?.lowercase()) {
        "file" -> {
            if (!uri.path.orEmpty().startsWith("/dsh/workspace/")) return null
            imageSource?.workspaceFiles?.let { MarkdownLocalImageRequest(it, raw) }
        }
        "sandbox" -> imageSource?.workspaceFiles?.let { MarkdownLocalImageRequest(it, raw) }
        "dsh-resource" -> {
            if (uri.host?.lowercase() != "file") return null
            val segments = uri.path.orEmpty().split('/').filter(String::isNotEmpty)
            if (segments.firstOrNull() != "session" || segments.size < 3) return null
            val sessionId = segments[1]
            val pathSegments = segments.drop(2)
            val relative = if (pathSegments.firstOrNull() == "dsh" && pathSegments.getOrNull(1) == "workspace") {
                pathSegments.drop(2).joinToString("/")
            } else {
                pathSegments.joinToString("/")
            }
            if (relative.isBlank()) return null
            // Session identity selects the resolver. Never strip the session prefix and resolve
            // against the current workspace, which could display a different user's/session's file.
            imageSource?.sessionFilesById?.get(sessionId)?.let { MarkdownLocalImageRequest(it, relative) }
        }
        else -> null
    }
}

private fun decodeLocalImage(path: Path): Bitmap? {
    return try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path.toString(), bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            null
        } else {
            val options = BitmapFactory.Options().apply {
                inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, MAX_DECODED_IMAGE_DIMENSION)
            }
            BitmapFactory.decodeFile(path.toString(), options)
        }
    } catch (_: OutOfMemoryError) {
        null
    } catch (_: RuntimeException) {
        null
    }
}

internal fun sampleMarkdownImageSize(width: Int, height: Int, maxDimension: Int = MAX_DECODED_IMAGE_DIMENSION): Int {
    if (width <= 0 || height <= 0 || maxDimension <= 0) return 1
    var sample = 1
    while (width / (sample * 2) >= maxDimension && height / (sample * 2) >= maxDimension) sample *= 2
    while (width / sample > maxDimension || height / sample > maxDimension) sample *= 2
    return max(sample, 1)
}

private fun sampleSize(width: Int, height: Int, maxDimension: Int): Int =
    sampleMarkdownImageSize(width, height, maxDimension)

internal object BoundedMarkdownRemoteImageLoader : MarkdownRemoteImageLoader {
    override suspend fun load(uri: URI): Bitmap? = withContext(Dispatchers.IO) {
        fetchRemoteImage(uri)
    }
}

private fun fetchRemoteImage(initialUri: URI): Bitmap? {
    var uri = initialUri
    repeat(MAX_REDIRECTS + 1) { redirectCount ->
        if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.host.isNullOrBlank() || uri.rawUserInfo != null) return null
        val connection = runCatching { URL(uri.toString()).openConnection() as? HttpURLConnection }.getOrNull() ?: return null
        try {
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.requestMethod = "GET"
            connection.setRequestProperty("Accept", "image/*")
            connection.connect()
            val status = connection.responseCode
            if (status in 300..399) {
                if (redirectCount >= MAX_REDIRECTS) return null
                val location = connection.getHeaderField("Location") ?: return null
                uri = runCatching { uri.resolve(location) }.getOrNull() ?: return null
                return@repeat
            }
            if (status !in 200..299) return null
            val declaredSize = connection.contentLengthLong
            if (declaredSize > MAX_REMOTE_IMAGE_BYTES) return null
            val bytes = connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(COPY_BUFFER_SIZE)
                var total = 0
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > MAX_REMOTE_IMAGE_BYTES) return null
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            return decodeRemoteImage(bytes)
        } catch (_: IOException) {
            return null
        } catch (_: OutOfMemoryError) {
            return null
        } finally {
            connection.disconnect()
        }
    }
    return null
}

private fun decodeRemoteImage(bytes: ByteArray): Bitmap? {
    if (bytes.isEmpty()) return null
    return try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, MAX_DECODED_IMAGE_DIMENSION)
        }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    } catch (_: OutOfMemoryError) {
        null
    } catch (_: RuntimeException) {
        null
    }
}

private sealed interface MarkdownImageState {
    data object Loading : MarkdownImageState
    data class Loaded(val bitmap: Bitmap) : MarkdownImageState
    data object Failed : MarkdownImageState
}

@Composable
internal fun MarkdownImageBlock(
    source: String,
    alt: String,
    title: String,
    imageSource: MarkdownImageSource?,
    variant: MarkdownVariant,
) {
    val tokens = LocalUiTokens.current
    val loader = LocalMarkdownRemoteImageLoader.current
    val state by produceState<MarkdownImageState>(MarkdownImageState.Loading, source, imageSource, loader) {
        value = loadMarkdownImage(source, imageSource, loader)?.let(MarkdownImageState::Loaded)
            ?: MarkdownImageState.Failed
    }
    val loadedBitmap = (state as? MarkdownImageState.Loaded)?.bitmap
    DisposableEffect(loadedBitmap) {
        onDispose { if (loadedBitmap != null && !loadedBitmap.isRecycled) loadedBitmap.recycle() }
    }
    when (val image = state) {
        MarkdownImageState.Loading -> Box(
            modifier = Modifier.fillMaxWidth().heightIn(min = IMAGE_LOADING_MIN_HEIGHT.dp)
                .testTag(MARKDOWN_IMAGE_LOADING_TAG),
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator(
                color = tokens.colors.secondary,
            )
        }
        is MarkdownImageState.Loaded -> MarkdownImageThumbnail(bitmap = image.bitmap, alt = alt, title = title)
        MarkdownImageState.Failed -> BasicText(
            text = alt,
            style = markdownBodyStyle(variant).copy(color = tokens.colors.tertiary, fontStyle = androidx.compose.ui.text.font.FontStyle.Italic),
            modifier = Modifier.testTag(MARKDOWN_IMAGE_TAG),
        )
    }
}

@Composable
private fun MarkdownImageThumbnail(bitmap: Bitmap, alt: String, title: String) {
    var viewerOpen by remember(bitmap) { mutableStateOf(false) }
    val shape = RoundedCornerShape(MARKDOWN_IMAGE_RADIUS_DP.dp)
    Image(
        bitmap = bitmap.asImageBitmap(),
        contentDescription = alt.ifBlank { title },
        contentScale = ContentScale.Fit,
        modifier = Modifier
            .sizeIn(maxWidth = MARKDOWN_IMAGE_MAX_WIDTH_DP.dp, maxHeight = MARKDOWN_IMAGE_MAX_HEIGHT_DP.dp)
            .clip(shape)
            .clickable(role = Role.Button) { viewerOpen = true }
            .semantics { contentDescription = alt.ifBlank { title } }
            .testTag(MARKDOWN_IMAGE_TAG),
    )
    if (viewerOpen) {
        Dialog(
            onDismissRequest = { viewerOpen = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Box(
                modifier = Modifier.fillMaxSize().background(Color.Black).testTag(MARKDOWN_IMAGE_VIEWER_TAG),
                contentAlignment = Alignment.Center,
            ) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = alt.ifBlank { title },
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
    }
}

private const val CONNECT_TIMEOUT_MS: Int = 5_000
private const val READ_TIMEOUT_MS: Int = 8_000
private const val MAX_REDIRECTS: Int = 3
private const val MAX_REMOTE_IMAGE_BYTES: Int = 8 * 1024 * 1024
private const val MAX_DECODED_IMAGE_DIMENSION: Int = 2_048
private const val COPY_BUFFER_SIZE: Int = 16 * 1024
private const val IMAGE_LOADING_MIN_HEIGHT: Int = 80
private const val MARKDOWN_IMAGE_MAX_WIDTH_DP: Int = 640
private const val MARKDOWN_IMAGE_MAX_HEIGHT_DP: Int = 360
private const val MARKDOWN_IMAGE_RADIUS_DP: Int = 8
