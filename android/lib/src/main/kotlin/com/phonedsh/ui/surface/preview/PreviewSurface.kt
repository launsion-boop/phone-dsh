// The one preview face: a pushed route, one file, four honest states.
// SPDX-License-Identifier: MIT
//
// Mirror source: `PreviewSurface.swift:230`–`:560` of iOS PR #15 (`8dd17496`),
// `struct PreviewSurface`. PR #15 deleted `FilePreviewPage` + `EmbeddedQuickLook`
// and left **one** preview surface for the whole app; Android had one preview body
// inside `FilesPage` and a second one inside `NativeWorkbenchPage`, both with no
// host data. This file is the single surface the new `PdshRoute.Preview(path)`
// renders, and the four rules its baseline states follow are the four implemented
// below:
//
//   1. **The first frame is 正在读取…**, never 「这个文件已经不在了。」
//      (`:261`; the old Android preview rendered the missing-file card before the
//      read even started — L28 §3 row 13).
//   2. **A path that is not there yet is waited for, in place** — 12 × 500 ms, the
//      baseline's own budget (`:145`–`:161`), decided by [PreviewPolicy].
//   3. **A failure is 无法预览 + the reason + 重试** (`:264`–`:270`); 重试 clears the
//      attempt count and starts over.
//   4. **An unsupported file is the truth plus a way out**: the path, the measured
//      size, why this host cannot draw it, and 分享文件 (`:505`–`:545`).
//
// The body is chosen by [PreviewKind]; six kinds have renderers here — text
// (paged, 512 KiB at a time), Markdown, images, PDF, video and audio. The other five
// state their reason and offer the share sheet, which is the baseline's own answer
// for everything it cannot draw either.
//
// The two media kinds are drawn by `PreviewPlayback.kt`, which owns a `MediaPlayer`
// plus its audio-focus request and releases both in a `DisposableEffect`; the two
// bodies only hand their failures back here, so a corrupt file lands in the same
// 无法预览 + 原因 + 重试 card as every other failure.
//
// Toolbar: PR15 draws 关闭 (modal only), the HTML network menu + reload, and 分享.
// A pushed route's back gesture is 关闭, the HTML menu needs a page source this host
// does not have (`:engine` allows exactly one WebView, L28 §4), and 分享 is wired
// to `PreviewShare` — so the toolbar here is 分享 plus the frame's back.
//
// Token discipline: every length and colour comes from `LocalUiTokens` /
// `LocalUiType`; this file contains no `N.dp`, no `N.sp` and no raw colour constructor
// (`PreviewTokenReferenceTest` fails the build if one appears).
package com.phonedsh.ui.surface.preview

import com.phonedsh.ui.HomeMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.PageFrame
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.page.formatFileSize
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import java.io.IOException
import java.nio.file.Path
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The preview screen for [relativePath].
 *
 * @param relativePath any spelling the app can quote: `./notes.txt`,
 *   `/dsh/workspace/notes.txt`, `file://…`, percent-encoded. The route's argument is
 *   passed through [PreviewPathResolver] before it becomes identity.
 * @param source the host read ([PreviewFileSource]); the page never touches the
 *   filesystem itself.
 * @param onBack the frame's back: one pop, back to the files list or the chat.
 * @param onShare the host's share action, returning false when nothing could
 *   receive the file; the page then says so instead of pretending it shared.
 * @param modifier the route's placement.
 */
@Composable
public fun PreviewPage(
    relativePath: String,
    source: PreviewFileSource,
    onBack: () -> Unit,
    onShare: (Path) -> Boolean,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val tokens = LocalUiTokens.current
    var state by remember(relativePath, source) { mutableStateOf(PreviewState(relativePath)) }
    // 重试 is a fresh start: a new key restarts the LaunchedEffect below, which is
    // the same thing the baseline's `retry()` does by clearing `retryCount` (`:172`).
    var attemptFromZero by remember(relativePath, source) { mutableStateOf(0) }
    var shareFailed by remember(relativePath, source) { mutableStateOf(false) }

    LaunchedEffect(relativePath, source, attemptFromZero) {
        state = PreviewState(relativePath)
        shareFailed = false
        var attempts = 0
        while (true) {
            attempts += 1
            when (val resolution = source.resolve(relativePath)) {
                is PreviewResolution.Resolved -> {
                    state = resolved(relativePath, resolution, source)
                    return@LaunchedEffect
                }

                is PreviewResolution.Unresolved -> {
                    when (val step = PreviewPolicy.next(resolution.reason, attempts)) {
                        is PreviewPolicy.Step.Wait -> {
                            // Rule 2: keep the spinner, do not claim the file is gone.
                            state = state.copy(attempts = attempts)
                            delay(step.delayMs)
                        }

                        is PreviewPolicy.Step.Fail -> {
                            state = state.failed(step.message, attempts)
                            return@LaunchedEffect
                        }
                    }
                }
            }
        }
    }

    val fileName = state.normalizedPath.substringAfterLast('/').ifEmpty { state.normalizedPath }
    val folder = state.normalizedPath.trimEnd('/').substringBeforeLast('/', missingDelimiterValue = "")

    PageFrame(
        title = fileName.ifEmpty { UiStrings.PREVIEW_UNAVAILABLE },
        modifier = modifier.testTag(UiPageTags.PREVIEW_ROOT),
        subtitle = if (state.isFailed || state.isUnsupported) null else folder.ifEmpty { null },
        onBack = onBack,
        actions = {
            if (state.canShare) {
                PreviewHeaderAction(
                    label = UiStrings.FILES_PREVIEW_SHARE,
                    tag = UiPageTags.PREVIEW_SHARE,
                    onClick = {
                        val file = state.file
                        if (file != null) shareFailed = !onShare(file)
                    },
                )
            }
        },
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                when {
                    // Rule 1. No sentence about the file until there is a fact.
                    state.isFirstFrame -> ReadingBody()
                    state.isFailed -> FailureBody(
                        reason = state.error ?: UiStrings.FILES_PREVIEW_GONE_HINT,
                        onRetry = { attemptFromZero += 1 },
                    )

                    state.isUnsupported -> UnsupportedBody(
                        state = state,
                        onShareFile = {
                            val file = state.file
                            if (file != null) shareFailed = !onShare(file)
                        },
                    )

                    state.kind == PreviewKind.TEXT -> PagedTextBody(text = state.text)
                    state.kind == PreviewKind.MARKDOWN -> MarkdownBody(text = state.text)
                    state.kind == PreviewKind.IMAGE -> ImageBody(file = state.file)
                    state.kind == PreviewKind.PDF -> PdfBody(file = state.file)
                    state.kind == PreviewKind.VIDEO -> VideoBody(
                        file = state.file,
                        onFailure = { reason -> state = state.failed(reason) },
                    )
                    state.kind == PreviewKind.AUDIO -> AudioBody(
                        file = state.file,
                        fileName = fileName,
                        onFailure = { reason -> state = state.failed(reason) },
                    )
                    // Unreachable: [PreviewKind.isRendered] is the same six kinds.
                    else -> UnsupportedBody(state = state, onShareFile = {})
                }
            }
            val paging = state.isPaged && state.status == PreviewStatus.READY
            when {
                paging && state.readingMore -> FooterLine(
                    text = UiStrings.PREVIEW_LOADING_MORE,
                    tag = UiPageTags.PREVIEW_LOADING_MORE,
                )

                paging && state.canLoadMore -> LoadMoreFooter(
                    label = UiStrings.PREVIEW_LOAD_MORE,
                    progress = progressText(state),
                    onClick = {
                        val file = state.file ?: return@LoadMoreFooter
                        scope.launch {
                            state = state.readingPage()
                            state = try {
                                state.appended(source.readPage(file, state.loadedBytes))
                            } catch (error: IOException) {
                                state.failed(
                                    UiStrings.FILES_PREVIEW_READ_FAILED.format(
                                        error.message ?: error.javaClass.simpleName,
                                    ),
                                )
                            }
                        }
                    },
                )

                shareFailed -> FooterLine(
                    text = UiStrings.PREVIEW_SHARE_FAILED,
                    tag = UiPageTags.PREVIEW_NOTICE,
                )

                state.notice != null -> FooterLine(
                    text = state.notice.orEmpty(),
                    tag = UiPageTags.PREVIEW_NOTICE,
                )

                // Paged bodies that reached the end still say how much was read:
                // "the file is longer than this screen" is a fact worth keeping.
                paging && state.totalBytes != null -> FooterLine(
                    text = progressText(state) ?: "",
                    tag = UiPageTags.PREVIEW_PROGRESS,
                )
            }
        }
    }
}

/**
 * The read that turns one resolved path into a body.
 *
 * Suspending and side-effect free with respect to the composition: it returns the
 * next [PreviewState], so the effect above owns every mutation.
 */
private suspend fun resolved(
    requested: String,
    resolution: PreviewResolution.Resolved,
    source: PreviewFileSource,
): PreviewState {
    val classified = previewKindOf(resolution.relativePath)
    // `PreviewSurface.swift:120`–`:123`: only an *unclassified* path is sniffed, and
    // a path that looks like text is then previewed as text.
    val kind = if (classified == PreviewKind.UNSUPPORTED && source.looksLikeText(resolution.file)) {
        PreviewKind.TEXT
    } else {
        classified
    }
    val base = PreviewState(requested).textBody(resolution.file, resolution.sizeBytes, kind)
    if (!kind.isRendered) {
        return PreviewState(requested).unsupported(resolution.file, resolution.sizeBytes, kind)
    }
    if (kind != PreviewKind.TEXT && kind != PreviewKind.MARKDOWN) {
        // A bitmap or a PDF needs no text page; the body decodes it itself.
        return base.copy(notice = noticeFor(resolution.relativePath, kind))
    }
    val firstPage = try {
        source.readPage(resolution.file, 0)
    } catch (error: IOException) {
        return PreviewState(requested).failed(
            UiStrings.FILES_PREVIEW_READ_FAILED.format(
                error.message ?: error.javaClass.simpleName,
            ),
        )
    }
    return base.appended(firstPage).copy(notice = noticeFor(resolution.relativePath, kind))
}

/** The one-line caveat a kind's body carries before it is drawn. */
private fun noticeFor(relativePath: String, kind: PreviewKind): String? {
    if (kind != PreviewKind.IMAGE) return null
    val name = relativePath.substringAfterLast('/').lowercase()
    return if (name.endsWith(".gif")) UiStrings.PREVIEW_NOTICE_GIF else null
}

/** `已读 <read> / 共 <size>`; `null` when the size was never measured. */
private fun progressText(state: PreviewState): String? {
    val total = state.totalBytes ?: return null
    return UiStrings.PREVIEW_PROGRESS.format(formatFileSize(state.loadedBytes), formatFileSize(total))
}

// ---------------------------------------------------------------------- states

/** Rule 1's body: the spinner and the baseline's one word (`:261`). */
@Composable
private fun ReadingBody() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.PREVIEW_LOADING),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(
            tokens.spacing.iconText,
            Alignment.CenterHorizontally,
        ),
    ) {
        CircularProgressIndicator(
            color = tokens.colors.textTertiary,
            strokeWidth = tokens.stroke.hairline,
            modifier = Modifier.size(tokens.geometry.composerControlSize),
        )
        BasicText(
            text = UiStrings.FILES_PREVIEW_LOADING,
            style = type.listItem.copy(color = tokens.colors.textSecondary),
        )
    }
}

/**
 * Rule 3's body: 无法预览, the reason, 重试 (`:264`–`:270`).
 *
 * The retry action is a text action, not a `Button`: the page layer draws every
 * verb as text (`UiStrings.RETRY` is the app's one 重试 spelling).
 */
@Composable
private fun FailureBody(reason: String, onRetry: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val shape = RoundedCornerShape(tokens.radius.card)
    Column(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.PREVIEW_FAILED)
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.cardInset,
            )
            .semantics(mergeDescendants = false) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.PREVIEW_UNAVAILABLE,
            style = type.pageTitle.copy(color = tokens.colors.textPrimary, textAlign = TextAlign.Center),
        )
        BasicText(
            text = reason,
            style = type.listItem.copy(color = tokens.colors.textSecondary, textAlign = TextAlign.Center),
        )
        BasicText(
            text = UiStrings.RETRY,
            style = type.listItem.copy(color = tokens.colors.pageAccent),
            modifier = Modifier
                .testTag(UiPageTags.PREVIEW_RETRY)
                .clip(shape)
                .background(tokens.colors.surface)
                .clickable(role = Role.Button, onClick = onRetry)
                .defaultMinSize(minHeight = tokens.geometry.secondaryButtonHeight)
                .padding(
                    horizontal = tokens.spacing.cardInset,
                    vertical = tokens.spacing.badgeInsetV,
                )
                .semantics { contentDescription = UiStrings.RETRY },
        )
    }
}

/**
 * Rule 4's body: the truth about the file, why this host cannot draw it, and the
 * way out (`:505`–`:545`).
 *
 * The card is the *only* place a preview claims a limitation, and it always states
 * three facts the app actually measured: the path, the size, and the missing
 * capability. A kind with no renderer and no reason would be an empty promise, so
 * [PreviewState.unsupportedReason] answers for five of the six unsupported kinds and
 * the sixth (an unclassifiable file) needs none.
 */
@Composable
private fun UnsupportedBody(state: PreviewState, onShareFile: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.PREVIEW_UNSUPPORTED)
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.cardInset,
            ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.PREVIEW_UNSUPPORTED_TITLE,
            style = type.pageTitle.copy(color = tokens.colors.textPrimary, textAlign = TextAlign.Center),
        )
        BasicText(
            text = UiStrings.PREVIEW_UNSUPPORTED_HINT,
            style = type.listItem.copy(color = tokens.colors.textSecondary, textAlign = TextAlign.Center),
        )
        state.unsupportedReason?.let { reason ->
            BasicText(
                text = reason,
                style = type.listItem.copy(color = tokens.colors.textSecondary, textAlign = TextAlign.Center),
            )
        }
        BasicText(
            text = state.normalizedPath,
            style = type.listItem.copy(color = tokens.colors.textTertiary, textAlign = TextAlign.Center),
        )
        state.totalBytes?.let { size ->
            BasicText(
                text = formatFileSize(size),
                style = type.listItem.copy(color = tokens.colors.textTertiary),
            )
        }
        if (state.canShare) {
            BasicText(
                text = UiStrings.PREVIEW_SHARE_FILE,
                style = type.listItem.copy(color = tokens.colors.primaryButtonInk),
                modifier = Modifier
                    .testTag(UiPageTags.PREVIEW_SHARE_FILE)
                    .clip(RoundedCornerShape(tokens.radius.card))
                    .background(tokens.colors.pageAccent)
                    .clickable(role = Role.Button, onClick = onShareFile)
                    .defaultMinSize(minHeight = tokens.geometry.primaryButtonHeight)
                    .padding(
                        horizontal = tokens.spacing.cardInset,
                        vertical = tokens.spacing.badgeInsetV,
                    )
                    .semantics { contentDescription = UiStrings.PREVIEW_SHARE_FILE },
            )
        }
    }
}

// ---------------------------------------------------------------------- bodies

/**
 * The text body: monospaced, one lazy row per chunk of lines.
 *
 * The baseline puts one `UITextView` on screen; a 512 KiB page as a single Compose
 * `BasicText` would measure half a million characters in one layout pass, which is
 * a freeze, not a preview. The page is therefore split on lines into
 * [TEXT_CHUNK_LINES]-line chunks and laid out lazily, so the layout cost follows the
 * screen and not the file. Selection works inside a chunk (`SelectionContainer`);
 * a selection that spans chunks is the one parity item this trades away, and it is
 * recorded in the lane's receipt rather than hidden.
 */
@Composable
private fun PagedTextBody(text: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val chunks = remember(text) {
        text.split('\n').chunked(TEXT_CHUNK_LINES).map { lines -> lines.joinToString("\n") }
    }
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.PREVIEW_TEXT)
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.badgeInsetV,
            ),
    ) {
        items(items = chunks) { chunk ->
            SelectionContainer {
                BasicText(
                    text = chunk,
                    style = type.code.copy(color = tokens.colors.textPrimary),
                )
            }
        }
    }
}

/** The Markdown body: a scroll view over the parsed blocks (`NativeMarkdownBody`). */
@Composable
private fun MarkdownBody(text: String) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.PREVIEW_MARKDOWN)
            .verticalScroll(rememberScrollState()),
    ) {
        PreviewMarkdown(text = text, modifier = Modifier.padding(bottom = tokens.spacing.cardInset))
    }
}

/**
 * One centered line of status, used by the two binary bodies while they decode.
 *
 * The tag is the *body's* tag, not a fifth state: "the image body is still
 * decoding" is the image body, not a new kind of preview.
 */
@Composable
internal fun PreviewCenteredLine(text: String, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxSize()
            .testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(
            tokens.spacing.iconText,
            Alignment.CenterHorizontally,
        ),
    ) {
        CircularProgressIndicator(
            color = tokens.colors.textTertiary,
            strokeWidth = tokens.stroke.hairline,
            modifier = Modifier.size(tokens.geometry.composerControlSize),
        )
        BasicText(
            text = text,
            style = type.listItem.copy(color = tokens.colors.textSecondary),
        )
    }
}

// --------------------------------------------------------------------- footers

/** One line of footer truth on the chrome fill. */
@Composable
private fun FooterLine(text: String, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.listItem.copy(color = tokens.colors.textSecondary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .background(tokens.colors.surface)
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/**
 * 加载更多 + the progress line (`:283`–`:292`).
 *
 * The baseline's button is 40 pt tall with a divider on top; the page row floor is
 * the smallest published height that holds a tap target, so the footer borrows it
 * and says so here instead of typing a length the token table does not have.
 */
@Composable
private fun LoadMoreFooter(label: String, progress: String?, onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(tokens.colors.surface)
            .clickable(role = Role.Button, onClick = onClick)
            .testTag(UiPageTags.PREVIEW_LOAD_MORE)
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics(mergeDescendants = true) { contentDescription = label },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        BasicText(
            text = label,
            style = type.listItem.copy(color = tokens.colors.pageAccent),
        )
        if (progress != null) {
            BasicText(
                text = progress,
                style = type.listItem.copy(color = tokens.colors.textTertiary),
            )
        }
    }
}

/** One header text action; the page never draws a bar button it cannot label. */
@Composable
internal fun PreviewHeaderAction(
    label: String,
    tag: String,
    onClick: () -> Unit,
    description: String = label,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = label,
        style = type.listItem.copy(color = tokens.colors.pageAccent),
        maxLines = 1,
        modifier = Modifier
            .testTag(tag)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .padding(tokens.spacing.iconText),
    )
}

/**
 * Lines per lazy chunk of the text body.
 *
 * 120 lines is roughly two screens of a phone-width monospaced body: big enough that
 * the lazy list holds few items for a long file, small enough that one chunk's
 * layout stays well inside a frame.
 */
private const val TEXT_CHUNK_LINES: Int = 120
