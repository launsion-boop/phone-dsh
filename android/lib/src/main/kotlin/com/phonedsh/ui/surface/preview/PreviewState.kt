// The preview's four honest states, and the bounded wait that separates them.
// SPDX-License-Identifier: MIT
//
// Mirror source: `PreviewSurface.swift:97`–`:228` (`PreviewModel`) of iOS PR #15,
// reduced to the part that is a *value*: the screen state and the policy that
// decides when "not yet" becomes "not ever". The Compose surface in
// `PreviewSurface.kt` owns the coroutine that reads; everything that can be
// asserted without a device is here:
//
//   rule 1  the first frame is loading, never "this file is gone"
//           (`:261` `ProgressView("正在读取…")`)
//   rule 2  a path that is not there yet is *retried in place* 12 × 500 ms
//           (`:145`–`:161`), then reported as 还在写入；a path that can never
//           resolve is reported at once (see `PreviewUnresolved.isRetryable`)
//   rule 3  a failure is 无法预览 + the reason + 重试 (`:264`–`:270`), and 重试
//           clears the attempt count (`:172`)
//   rule 4  an unsupported file states path + size + 分享 (`:505`–`:545`)
//
// Why the policy is its own object instead of an `if` inside the loader: the
// numbers are the contract (six seconds of patience) and a JVM test can drive the
// whole 13-attempt ladder without a clock, a file or a device.
package com.phonedsh.ui.surface.preview

import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.WorkspaceFile
import java.nio.file.Path

/** What the preview body is doing (`PreviewStatus` has no baseline analogue: iOS infers it). */
public enum class PreviewStatus {
    /** Reading, waiting for the bytes, or waiting for the next page. */
    LOADING,

    /** The file resolved; the body for [PreviewState.kind] is on screen. */
    READY,

    /** 无法预览 + a reason: the file cannot be read or the path was refused. */
    FAILED,

    /** 暂时不能预览: the file is fine, this host has no renderer for it. */
    UNSUPPORTED,
}

/**
 * Everything the preview face draws, as one immutable value.
 *
 * @param relativePath the path as requested (the route's argument).
 * @param normalizedPath [PreviewPathResolver.normalize] of the same path; this is
 *   the identity the state carries, so two spellings of one file share a state.
 * @param kind the renderer the path takes ([PreviewKind.UNSUPPORTED] until the
 *   sniff has run, which is why [status] and not [kind] says "not known yet").
 * @param file the resolved regular file; `null` until resolution succeeded.
 * @param totalBytes the measured size of [file], or `null` when not measured.
 * @param text the text read so far (TEXT / MARKDOWN only).
 * @param loadedBytes how many bytes of the file [text] covers; the progress line.
 * @param eof whether the last page reached the end of the file.
 * @param readingMore a page read is in flight on top of existing text.
 * @param attempts how many resolution attempts have failed; 重试 resets it.
 * @param error the failure reason for [PreviewStatus.FAILED].
 * @param notice one line of truth under the body (a truncated page, a first frame
 *   of an animated image, …); `null` when there is nothing to add.
 */
public data class PreviewState(
    public val relativePath: String,
    public val normalizedPath: String = PreviewPathResolver.normalize(relativePath),
    public val status: PreviewStatus = PreviewStatus.LOADING,
    public val kind: PreviewKind = PreviewKind.UNSUPPORTED,
    public val file: Path? = null,
    public val totalBytes: Long? = null,
    public val text: String = "",
    public val loadedBytes: Long = 0,
    public val eof: Boolean = true,
    public val readingMore: Boolean = false,
    public val attempts: Int = 0,
    public val error: String? = null,
    public val notice: String? = null,
) {
    /**
     * Rule 1: the first frame says 正在读取…, and does not say anything about the
     * file's existence.
     */
    public val isFirstFrame: Boolean
        get() = status == PreviewStatus.LOADING && text.isEmpty()

    /** The kind has a page window, so 加载更多 applies (`:97`–`:100`). */
    public val isPaged: Boolean
        get() = kind == PreviewKind.TEXT || kind == PreviewKind.MARKDOWN

    /**
     * `加载更多` is offered only when it would do something: a text body that has
     * not reached the end and is not already reading (`:281`).
     */
    public val canLoadMore: Boolean
        get() = status == PreviewStatus.READY && isPaged && !eof && !readingMore

    /** Rule 4 + the toolbar: 分享 exists exactly when there is a real file. */
    public val canShare: Boolean
        get() = file != null

    /** The body currently on screen is the honest unsupported card. */
    public val isUnsupported: Boolean
        get() = status == PreviewStatus.UNSUPPORTED

    /** The failure card is on screen. */
    public val isFailed: Boolean
        get() = status == PreviewStatus.FAILED

    /**
     * The reason the unsupported card prints, per kind.
     *
     * The baseline never has to explain itself (Quick Look or a library page covers
     * every kind); this host must, because "temporarily cannot preview" without a
     * reason is the same lie as "the file is gone". Each sentence names the missing
     * capability, and none of them promises a renderer that does not exist.
     *
     * [PreviewKind.VIDEO] and [PreviewKind.AUDIO] answer `null` since the L32 lane
     * drew them: a rendered body has no missing capability to explain, and the two
     * `PREVIEW_REASON_VIDEO` / `PREVIEW_REASON_AUDIO` sentences stay in `UiStrings`
     * (that object is append-only for this lane) but are no longer reachable.
     *
     * The mapping itself lives in [unsupportedReasonFor] since the L33 lane, for one
     * reason: it is **per file**, not per kind. `WEB_MEDIA` is a GIF, a WebM and an
     * OGV, and those three are missing three different things, so one sentence per
     * kind could only be vague or wrong. Keeping the sentences in a pure function
     * also lets a JVM test pin every one of them, including the rule that none names
     * an implementation the reader cannot act on.
     */
    public val unsupportedReason: String?
        get() = unsupportedReasonFor(kind, normalizedPath)

    /** Applies one more page to the text body (`:214`–`:219`). */
    public fun appended(page: PreviewTextPage): PreviewState = copy(
        text = text + page.text,
        loadedBytes = page.nextOffset,
        eof = page.eof,
        readingMore = false,
        // A page that is not UTF-8 stops being text: say so once, and stay put.
        notice = if (page.stalled) UiStrings.PREVIEW_NOTICE_BINARY else notice,
        status = PreviewStatus.READY,
    )

    /** Marks a page read in flight (`:206` `isLoading = true`). */
    public fun readingPage(): PreviewState = copy(readingMore = true)

    /** Rule 3: 无法预览 + reason; the retry action is the caller's. */
    public fun failed(reason: String, attempts: Int = this.attempts): PreviewState = copy(
        status = PreviewStatus.FAILED,
        error = reason,
        attempts = attempts,
        readingMore = false,
        text = "",
        loadedBytes = 0,
    )

    /** Rule 4: the file is fine, this host has no renderer for it. */
    public fun unsupported(file: Path, sizeBytes: Long, kind: PreviewKind): PreviewState = copy(
        status = PreviewStatus.UNSUPPORTED,
        kind = kind,
        file = file,
        totalBytes = sizeBytes,
        readingMore = false,
    )

    /** The resolved text body, ready for its first page. */
    public fun textBody(file: Path, sizeBytes: Long, kind: PreviewKind): PreviewState = copy(
        status = PreviewStatus.READY,
        kind = kind,
        file = file,
        totalBytes = sizeBytes,
        error = null,
    )
}

/**
 * The classifies-and-reads seam the preview face needs from its host.
 *
 * Deliberately four operations and no more: a listing for the files page, one path
 * resolution through [PreviewPathResolver], one page read through [PreviewPager],
 * and one sniff. A host that cannot answer returns the *absence* (`null`,
 * [PreviewResolution.Unresolved]) instead of an invented answer.
 */
public interface PreviewFileSource {
    /**
     * The workspace's files as the host can see them, or `null` when the host has
     * no workspace read at all (the files page's waiting state, never "empty").
     */
    public suspend fun files(): List<WorkspaceFile>?

    /** Resolves one path against the workspace root, symlinks and all. */
    public suspend fun resolve(relativePath: String): PreviewResolution

    /** Reads one page of a resolved file. */
    public suspend fun readPage(file: Path, offset: Long): PreviewTextPage

    /** The baseline's 4 KiB sniff, for a path with an unknown extension. */
    public suspend fun looksLikeText(file: Path): Boolean
}

/**
 * The bounded wait of rule 2, as a pure decision.
 *
 * The iOS numbers are kept exactly (`:145`–`:161`: `retryCount <= 12`, 500 ms
 * apart, so ≈6 s) because they are a parity fact, not a tuning knob. The one
 * difference is *which* failures wait: iOS waits for every `nil`, including a path
 * that escaped the root; here a refusal is final and a missing candidate waits
 * ([PreviewUnresolved.isRetryable]).
 */
public object PreviewPolicy {
    /** `:148`: `retryCount <= 12`. */
    public const val RETRY_LIMIT: Int = 12

    /** `:150`: `Task.sleep(for: .milliseconds(500))`. */
    public const val RETRY_DELAY_MS: Long = 500

    /** What the loader does after one unresolved attempt. */
    public sealed interface Step {
        /** Keep the spinner and try again after [delayMs]. */
        public data class Wait(public val delayMs: Long) : Step

        /** Stop, and show [message] as 无法预览's reason. */
        public data class Fail(public val message: String) : Step
    }

    /**
     * @param reason why the last attempt did not resolve.
     * @param attempts how many attempts have failed, counting this one (1-based).
     */
    public fun next(reason: PreviewUnresolved, attempts: Int): Step = when {
        // Final at once: a refused path can never become valid by waiting.
        reason == PreviewUnresolved.REJECTED -> Step.Fail(UiStrings.FILES_PREVIEW_UNSAFE)
        reason == PreviewUnresolved.NOT_A_FILE -> Step.Fail(UiStrings.PREVIEW_NOT_A_FILE)
        // `:148`: the last allowed wait is the twelfth attempt; the thirteenth is
        // the answer. `<=` keeps the total at 12 waits (≈6 s), like the baseline.
        attempts <= RETRY_LIMIT -> Step.Wait(RETRY_DELAY_MS)
        else -> Step.Fail(UiStrings.PREVIEW_STILL_WRITING)
    }
}
