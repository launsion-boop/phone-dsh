// Sharing a previewed file: the honest way out of a kind this host cannot draw.
// SPDX-License-Identifier: MIT
//
// Mirror source: `PreviewSurface.swift:317`–`:322` and `:505`–`:545` of iOS PR #15
// — the toolbar's 分享 (`UIActivityViewController` in a sheet) and the unsupported
// card's 分享文件 (`ShareLink`). PR15's research document recommends share-first for
// exactly the kinds Android has no renderer for (`04-ux-android.md` §7), so this is
// not a fallback bolted on: it is the designed answer for Office, audio, video, 3D,
// archives and `.svg`.
//
// Android has no `ShareLink`, so the equivalent is a `FileProvider` URI plus an
// `ACTION_SEND` chooser:
//
//   * the provider is declared by this module's own manifest and serves **only**
//     `files/xl/materialized/workspace/` — the same tree the preview is allowed to
//     read. A `content://` URI handed to another app can therefore never name a
//     file the resolver would have refused.
//   * the chooser carries `FLAG_GRANT_READ_URI_PERMISSION`, so the receiving app
//     reads the bytes through the provider and the workspace stays app-private
//     (`filesDir` is not world-readable).
//   * nothing here builds a `file://` URI: `FileUriExposedException` on API 24+ is
//     the platform agreeing with that rule.
//
// The MIME table is deliberately independent of [previewKindOf]: a `.docx` must be
// offered as a Word document (so Word can claim it) even though this host previews
// it as nothing at all.
package com.phonedsh.ui.surface.preview

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.phonedsh.ui.UiStrings
import java.nio.file.Path

/** The bytes behind a `分享` tap, and the `content://` address they are shared at. */
public object PreviewShare {
    /**
     * The provider authority suffix, appended to the host's `packageName`.
     *
     * The manifest declares `${applicationId}.pdsh.preview`, which is the same
     * string at runtime because a library's manifest is merged into the consuming
     * app (and into the androidTest APK) with that app's `applicationId`.
     */
    public const val AUTHORITY_SUFFIX: String = ".pdsh.preview"

    /** The provider authority this process can use. */
    public fun authority(context: Context): String = context.packageName + AUTHORITY_SUFFIX

    /**
     * The `content://` URI for [file], or `null` when the provider will not serve
     * it (a file outside the declared root, or a provider that failed to merge).
     *
     * A `null` answer is reported to the user as 「无法分享这个文件」; it is never
     * turned into a `file://` fallback.
     */
    public fun uriFor(context: Context, file: Path): Uri? = try {
        FileProvider.getUriForFile(context, authority(context), file.toFile())
    } catch (_: IllegalArgumentException) {
        null
    }

    /**
     * The chooser this host starts for [file].
     *
     * Kept separate from [share] so a test can assert the intent (action, type,
     * grant flag, the nested `EXTRA_STREAM`) without an activity transition.
     */
    public fun intentFor(uri: Uri, mime: String, title: String): Intent {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return Intent.createChooser(send, title).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    /**
     * Shares [file], returning false when the platform refused.
     *
     * Two failures are possible and both are honest answers rather than crashes: no
     * app can handle the type (`ActivityNotFoundException`), and the provider
     * refused the path ([uriFor] returned `null`).
     */
    public fun share(context: Context, file: Path): Boolean {
        val uri = uriFor(context, file) ?: return false
        val mime = mimeOf(file.fileName?.toString().orEmpty())
        return start(context, intentFor(uri, mime, UiStrings.FILES_PREVIEW_SHARE))
    }

    /** Starts [intent] from whatever context the composition handed us. */
    public fun start(context: Context, intent: Intent): Boolean = try {
        val activity = context.findActivity()
        if (activity != null) {
            activity.startActivity(intent)
        } else {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }

    /**
     * The MIME type another app should see for this path.
     *
     * Unknown extensions are `application/octet-stream`, which is the truth: this
     * host does not know what they are either.
     */
    public fun mimeOf(fileName: String): String {
        val name = fileName.substringAfterLast('/')
        val dot = name.lastIndexOf('.')
        val extension = if (dot <= 0 || dot == name.lastIndex) "" else name.substring(dot + 1).lowercase()
        return MIME_TYPES[extension] ?: DEFAULT_MIME
    }

    private const val DEFAULT_MIME: String = "application/octet-stream"

    /** Extension-keyed MIME types for every kind the preview route can meet. */
    private val MIME_TYPES: Map<String, String> = buildMap {
        // Named `claim` rather than `put`: a local `put` would shadow the map's own
        // and recurse into itself (which it did, until `PreviewShareTest` caught it).
        fun claim(mime: String, vararg extensions: String) {
            extensions.forEach { extension -> this[extension] = mime }
        }
        claim("text/plain", "txt", "log", "conf", "config", "lock", "makefile", "dockerfile", "gitignore", "zshrc")
        claim("text/markdown", "md", "markdown", "mdx")
        claim("text/html", "html", "htm")
        claim("text/css", "css", "scss", "less")
        claim("text/csv", "csv")
        claim("text/tab-separated-values", "tsv")
        claim("application/json", "json", "jsonl")
        claim("application/x-yaml", "yaml", "yml")
        claim("application/xml", "xml", "plist", "entitlements")
        claim("application/toml", "toml")
        claim("application/x-httpd-php", "ini")
        claim("application/sql", "sql")
        claim("text/x-diff", "diff", "patch")
        claim("text/x-kotlin", "kt", "kts")
        claim("text/x-java", "java")
        claim("text/x-python", "py")
        claim("text/javascript", "js", "jsx")
        claim("text/x-typescript", "ts", "tsx")
        claim("text/x-c", "c", "h")
        claim("text/x-c++", "cpp", "hpp", "mm", "m")
        claim("text/x-go", "go")
        claim("text/x-rust", "rs")
        claim("text/x-swift", "swift")
        claim("text/x-shellscript", "sh", "zsh", "bash", "fish")
        claim("application/pdf", "pdf")
        claim("image/png", "png")
        claim("image/jpeg", "jpg", "jpeg")
        claim("image/webp", "webp")
        claim("image/heic", "heic", "heif")
        claim("image/bmp", "bmp")
        claim("image/tiff", "tiff")
        claim("image/gif", "gif")
        claim("video/mp4", "mp4", "m4v")
        claim("video/quicktime", "mov")
        claim("video/webm", "webm")
        claim("video/ogg", "ogv")
        claim("audio/mpeg", "mp3")
        claim("audio/mp4", "m4a")
        claim("audio/wav", "wav")
        claim("audio/aac", "aac")
        claim("audio/flac", "flac")
        claim("model/gltf-binary", "glb")
        claim("model/gltf+json", "gltf")
        claim("application/rtf", "rtf")
        claim("application/epub+zip", "epub")
        claim("application/msword", "doc")
        claim("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx")
        claim("application/vnd.ms-excel", "xls")
        claim("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx")
        claim("application/vnd.ms-powerpoint", "ppt")
        claim("application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx")
        claim("application/vnd.apple.pages", "pages")
        claim("application/vnd.apple.numbers", "numbers")
        claim("application/vnd.apple.keynote", "key")
        claim("application/zip", "zip")
        claim("image/svg+xml", "svg")
    }
}

/**
 * The [Activity] a context belongs to, or `null` for an application context.
 *
 * A chooser started from an application context needs `FLAG_ACTIVITY_NEW_TASK`, and
 * starting an activity from the page's own activity is what a share sheet should
 * look like; this walk is the smallest way to tell the two apart.
 */
internal fun Context.findActivity(): Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}
