// The honest "why this file has no body" answers, and what the architecture owes.
// SPDX-License-Identifier: MIT
//
// ---- what this file is for ------------------------------------------------
// The unsupported card (`PreviewSurface.kt`, rule 4) has to name the missing
// capability *per file*, because three different things hide behind one enum
// case, and only one of them is an architecture question:
//
//   * [PreviewKind.HTML] and [PreviewKind.MODEL] need an **HTML/JS renderer** — a
//     second page container this App does not have. That is the single decision
//     the L33 lane took: the one-WebView invariant (`WebViewEngine.kt:4-10`,
//     plan §6.3-5) stays, so these two kinds are honestly unsupported.
//     The invariant now has a home in this tree — `docs/design/
//     android-single-webview-invariant-2026-11-01.md` states why it exists, what
//     it protects in practice (the app-level cookie jar), the order to change it
//     in, and the four tests a second renderer would have to carry.
//     [needsWebPreview] *is* the set the invariant gates, and a JVM test pins it,
//     so a future lane that opens a preview renderer knows exactly which kinds
//     change answer.
//   * [PreviewKind.WEB_MEDIA] is three formats on three different paths — an
//     animated GIF needs an animated decoder, WebM/OGV need a player route, and
//     OGV (`Theora`) has no platform decoder at all. Only PR15's choice to route
//     all three through one library page made them look like a single gap.
//   * [PreviewKind.OFFICE] is a platform fact: Android has no system-level
//     Quick Look to embed.
//
// ---- the rule these sentences follow -------------------------------------
// Name the capability the person is missing, in words they can act on, and never
// the implementation they cannot: a person cannot "get a second WebView", but
// they can share the file to another app. `PreviewUnsupportedTest` fails the
// build if implementation vocabulary (`WebView`, 「只允许一个」, 「第二个」) comes
// back into any of these strings.
//
// Keeping the mapping in one pure function is also what lets the whole card be
// asserted on the JVM: [unsupportedReasonFor] takes a kind and a path, and
// returns the sentence, with no file, device or composition involved.
package com.phonedsh.ui.surface.preview

import com.phonedsh.ui.UiStrings

/**
 * True for the kinds whose only missing piece is an HTML/JS preview surface.
 *
 * [PreviewKind.HTML] runs the file's own scripts; [PreviewKind.MODEL] (glb/gltf)
 * needs the packaged three.js page to render a scene. Both are blocked by the App
 * having exactly one WebView and by nothing else, which is why the honest card is
 * the answer instead of a renderer.
 *
 * The WebM/OGV half of [PreviewKind.WEB_MEDIA] is deliberately **not** here: the
 * platform's decoder set covers WebM/VP8/VP9 (unlike OGV/Theora), so that gap is a
 * missing player route, not an architecture edit — see [previewExtensionOf].
 */
public val PreviewKind.needsWebPreview: Boolean
    get() = this == PreviewKind.HTML || this == PreviewKind.MODEL

/**
 * The sentence the unsupported card prints for [relativePath], or `null` when the
 * kind needs no excuse: it has a renderer ([PreviewKind.isRendered]), or it is a
 * file nothing can classify ([PreviewKind.UNSUPPORTED]).
 */
public fun unsupportedReasonFor(kind: PreviewKind, relativePath: String): String? = when (kind) {
    PreviewKind.OFFICE -> UiStrings.PREVIEW_REASON_OFFICE
    PreviewKind.HTML -> UiStrings.PREVIEW_REASON_HTML_PAGE
    PreviewKind.MODEL -> UiStrings.PREVIEW_REASON_MODEL_VIEWER
    PreviewKind.WEB_MEDIA -> webMediaReason(relativePath)
    PreviewKind.TEXT,
    PreviewKind.MARKDOWN,
    PreviewKind.IMAGE,
    PreviewKind.PDF,
    PreviewKind.VIDEO,
    PreviewKind.AUDIO,
    PreviewKind.UNSUPPORTED,
    -> null
}

/** `WEB_MEDIA` is three formats; the card says which one this file is. */
private fun webMediaReason(relativePath: String): String = when (previewExtensionOf(relativePath)) {
    "ogv" -> UiStrings.PREVIEW_REASON_WEB_MEDIA_OGV
    else -> UiStrings.PREVIEW_REASON_WEB_MEDIA_VIDEO
}

/**
 * The lower-cased extension `previewKindOf` routed on.
 *
 * Deliberately a copy of `PreviewKind.kt`'s rule instead of a call to it: that
 * function answers with a *kind*, and the kind is exactly what cannot tell GIF
 * from WebM. `PreviewUnsupportedTest` pins the two rules together — every path
 * `previewKindOf` classifies as `WEB_MEDIA` must be one of the three extensions
 * below, so the copy cannot drift into a silent `else`.
 *
 * A leading-dot name (`.env`) has no extension, the same answer Foundation's
 * `pathExtension` gives and the same one `previewKindOf` uses.
 */
public fun previewExtensionOf(relativePath: String): String {
    val name = relativePath.substringAfterLast('/')
    val dot = name.lastIndexOf('.')
    return if (dot <= 0 || dot == name.lastIndex) "" else name.substring(dot + 1).lowercase()
}
