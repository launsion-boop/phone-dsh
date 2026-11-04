// Which preview body a workspace path takes: the eleven kinds of the baseline.
// SPDX-License-Identifier: MIT
//
// Mirror source: `PreviewSurface.swift:68`–`:105` of iOS PR #15 (`8dd17496`),
// `enum PreviewKind` + `URL.previewKind`. The baseline routes a path by its
// lower-cased extension alone, and the order of the cases below is the order of
// its `switch`, which matters for exactly one path family: `md` is also a text
// extension on Android's side and must stay Markdown.
//
// Android has a *second*, older classifier — `FilesPage.classifyFileKind` — with
// four kinds (HTML / MARKDOWN / TEXT / EXTERNAL). It is left untouched: the files
// list still asks "which preview slot would this row open", while this file
// answers "which renderer does the preview face use". The two agree on the four
// shared kinds and `PreviewKindTest` pins that agreement, so a future merge of the
// two surfaces cannot silently disagree about a path.
//
// Two baseline facts are kept verbatim because they are decisions, not accidents:
//
//   * `.svg` is **not** an image and **not** text — it falls through to
//     [PreviewKind.UNSUPPORTED] (`:83`), even though the iOS page scheme has a
//     static CSP for SVG. L28 §9 Q6 records the inconsistency; Android follows the
//     preview surface (the user-visible one) and reports it as unsupported.
//   * a path with **no extension**, or an unknown one, is not classified here at
//     all: the baseline  (`:187`, `looksLikeText`) sniffs the first 4 KiB and, if
//     they decode as text, previews them as text. That sniff lives in
//     [PreviewSniff] and is applied by the preview state, never by this function,
//     because it needs bytes and this function must stay pure.
package com.phonedsh.ui.surface.preview

/**
 * The eleven preview bodies of the baseline (`PreviewSurface.swift:68`).
 *
 * Six of them are rendered on this host today ([TEXT], [MARKDOWN], [IMAGE], [PDF],
 * [VIDEO], [AUDIO]); the rest are *honestly* unsupported with a reason and a share
 * action ([PreviewKind.isRendered] records which is which, so a page cannot claim a
 * body it does not draw).
 */
public enum class PreviewKind {
    /** Monospaced, paged, selectable text (`NativePagedTextView`). */
    TEXT,

    /** Rendered Markdown (`NativeMarkdownBody`). */
    MARKDOWN,

    /** A page on the workspace scheme (`PDSHPageView` + `pdsh-page://`). */
    HTML,

    /** A decoded bitmap (`UIImage(contentsOfFile:)`). */
    IMAGE,

    /** A `PDFKit` document. */
    PDF,

    /** Office documents, through embedded Quick Look. */
    OFFICE,

    /** A video player. */
    VIDEO,

    /** An audio player (the same player branch as video). */
    AUDIO,

    /** glTF/GLB, through the three.js viewer page. */
    MODEL,

    /** GIF as an `<img>`, WebM/OGV as a `<video>` — both through a library page. */
    WEB_MEDIA,

    /** Everything else, including `.svg` and archives. */
    UNSUPPORTED,
    ;

    /**
     * True when this host draws a body for the kind.
     *
     * The other kinds render [PreviewKind.UNSUPPORTED]'s honest card — path, size,
     * the per-kind reason and 分享文件 — instead of an empty frame. This property is
     * the *single* place that decides, so the toolbar's 分享 and the card cannot
     * disagree about whether a renderer exists.
     *
     * [VIDEO] and [AUDIO] were added by the L32 lane, which is the pair L29 §10 Q4
     * left open: both are drawn by the same `MediaPlayer` session
     * (`PreviewPlayback.kt`), which is why they arrive together rather than one at a
     * time.
     *
     * PR15 routes `gif`/`webm`/`ogv` through its WebView page, but this host reads the
     * file itself, and the platform decodes two of the three: `gif` through
     * `BitmapFactory` (first frame only, and the "动图只显示第一帧" notice says so) and
     * `webm` through the same `MediaPlayer` as `mp4` (VP8/VP9 are in the minSdk 26
     * decoder set). Saying "this video format is not connected to a player" while the
     * decoder is right there would be a false statement, so both move to the renderers
     * that can actually draw them. `ogv` stays: this host has no Theora decoder, and
     * that card tells the truth.
     */
    public val isRendered: Boolean
        get() = this == TEXT || this == MARKDOWN || this == IMAGE || this == PDF ||
            this == VIDEO || this == AUDIO
}

/**
 * The baseline's extension table, transcribed case for case (`:75`–`:103`).
 *
 * The sets are private: a caller asks [previewKindOf], never "is `md` markdown",
 * so the table has exactly one reader and a test can pin the whole of it by
 * enumerating [PreviewKind] over a representative path.
 */
private val MARKDOWN_EXTENSIONS: Set<String> = setOf("md", "markdown")
private val HTML_EXTENSIONS: Set<String> = setOf("html", "htm")
private val MODEL_EXTENSIONS: Set<String> = setOf("glb", "gltf")
private val WEB_MEDIA_EXTENSIONS: Set<String> = setOf("ogv")
private val IMAGE_EXTENSIONS: Set<String> =
    setOf("png", "jpg", "jpeg", "webp", "heic", "heif", "bmp", "tiff", "gif")
private val PDF_EXTENSIONS: Set<String> = setOf("pdf")
private val OFFICE_EXTENSIONS: Set<String> = setOf(
    "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "epub",
)
private val VIDEO_EXTENSIONS: Set<String> = setOf("mp4", "mov", "m4v", "webm")
private val AUDIO_EXTENSIONS: Set<String> = setOf("mp3", "m4a", "wav", "aac", "flac")

/**
 * The baseline's 60+ text and source extensions (`:100`).
 *
 * Kept verbatim: the earlier Android page carried a *different* list (12 entries
 * plus the four Kotlin/Gradle ones), which meant a `.ts`, `.rs` or `.sql` file fell
 * to the binary card. Every extension here is one the baseline previews as text,
 * so the two hosts now open the same files the same way.
 */
private val TEXT_EXTENSIONS: Set<String> = setOf(
    "txt", "log", "json", "jsonl", "yaml", "yml", "xml", "toml", "ini", "csv", "tsv",
    "mdx", "swift", "m", "mm", "c", "h", "cpp", "hpp", "go", "rs", "py", "js", "jsx",
    "ts", "tsx", "java", "kt", "kts", "gradle", "sh", "zsh", "bash", "fish", "zshrc",
    "css", "scss", "less", "sql", "patch", "diff", "plist", "entitlements", "pbxproj",
    "makefile", "dockerfile", "gitignore", "lock", "conf", "config",
)

/**
 * The kind a path takes by extension (`URL.previewKind`).
 *
 * Pure and locale-free: the extension is lower-cased with [String.lowercase], the
 * same mapping `URL.pathExtension.lowercased()` performs. A leading-dot file
 * (`.env`, `.gitignore` as a *name*) has no extension here, exactly as in
 * Foundation, so it reaches the sniff and — being ASCII — previews as text.
 */
public fun previewKindOf(relativePath: String): PreviewKind {
    val name = relativePath.substringAfterLast('/')
    val dot = name.lastIndexOf('.')
    val extension = if (dot <= 0 || dot == name.lastIndex) "" else name.substring(dot + 1).lowercase()
    return when (extension) {
        in MARKDOWN_EXTENSIONS -> PreviewKind.MARKDOWN
        in HTML_EXTENSIONS -> PreviewKind.HTML
        in MODEL_EXTENSIONS -> PreviewKind.MODEL
        in WEB_MEDIA_EXTENSIONS -> PreviewKind.WEB_MEDIA
        in IMAGE_EXTENSIONS -> PreviewKind.IMAGE
        in PDF_EXTENSIONS -> PreviewKind.PDF
        in OFFICE_EXTENSIONS -> PreviewKind.OFFICE
        in VIDEO_EXTENSIONS -> PreviewKind.VIDEO
        in AUDIO_EXTENSIONS -> PreviewKind.AUDIO
        in TEXT_EXTENSIONS -> PreviewKind.TEXT
        else -> PreviewKind.UNSUPPORTED
    }
}

/**
 * The kind after the baseline's UTF-8 sniff has had its say (`:120`–`:123`).
 *
 * Only an [PreviewKind.UNSUPPORTED] classification is reconsidered: an `.md` file
 * whose bytes are actually binary stays Markdown (the baseline does the same — it
 * sniffs only in the unsupported branch), and the text body then reports the
 * decode failure instead of silently re-labelling the file.
 */
public fun previewKindOf(relativePath: String, sniffedAsText: Boolean): PreviewKind {
    val classified = previewKindOf(relativePath)
    return if (classified == PreviewKind.UNSUPPORTED && sniffedAsText) PreviewKind.TEXT else classified
}
