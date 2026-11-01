// The diagnostic export package: the report facts, the written file, its preview.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row ExportPage (导出诊断包; entry: 设置 →
// 探针工具（仅 DEBUG）; exit: push / sheet; P5 `later`), §3.1 rule 3 (a page with
// no harness event anchor projects the host's read-only snapshot), §5 (`insets`,
// and the `share-sheet` row: the share action is a page action, never a deep link
// or an external share target).
//
// This is a line-for-line port of the iOS baseline's `ExportPage.swift`:
//
//   报告     Status / Environment / Device / Format version / File, the path
//            note, the prominent 写报告 action and — only once a file exists —
//            分享文件; the write error is red
//   预览     the host's report text in the monospaced face, cut at 80 lines with
//            the baseline's "… 还有 N 行" tail
//
// The baseline writes on `.onAppear` (and refreshes the Lockdown observation
// there). This page does the same: `onOpen` runs once when the page enters the
// composition (it defaults to `onWrite`, so a caller that only wires the button
// still gets the baseline's open-writes behaviour), and the visible 写报告
// button remains the "write again" action. Nothing writes itself inside the
// page: `onWrite` asks the host, and the file name arrives as a host fact.
//
// The page never reads the clock (the host names the file), never opens the file
// and never formats the report: `preview` is the host's text. A report the host
// did not measure renders 未知, never an empty report.
//
// Geometry: the page margin, the mono preview style and the two action colors
// are the only token reads in this file; the standard `Button` / `OutlinedButton`
// take their palette from `ProbeControlsTheme` and the shared `InfoRow` reads its
// own.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The host's read-only export snapshot.
 *
 * @param reportStatus the report's own status label.
 * @param environment the environment the report was produced in.
 * @param device the host-formatted device model.
 * @param formatVersion the report format version the host wrote.
 * @param written whether a file was written; [FactState.UNKNOWN] while unreported.
 * @param fileName the written file's name (not a path: the host names the file).
 * @param preview the report text the host would export; `null` when unreported.
 * @param writeError the last write error; non-null renders a fail-loud line.
 */
@Immutable
public data class ExportSnapshot(
    public val reportStatus: String? = null,
    public val environment: String? = null,
    public val device: String? = null,
    public val formatVersion: String? = null,
    public val written: FactState = FactState.UNKNOWN,
    public val fileName: String? = null,
    public val preview: String? = null,
    public val writeError: String? = null,
) {
    /** True when the host measured at least one fact of this page. */
    internal val hasMeasurement: Boolean
        get() = reportStatus != null || environment != null || device != null ||
            formatVersion != null || written != FactState.UNKNOWN ||
            fileName != null || preview != null || writeError != null
}

/**
 * The page's read-only input.
 *
 * @param snapshot the host's snapshot; `null` means the host did not report one.
 * @param failure the host's read failure; non-null renders the fail-loud line.
 */
@Immutable
public data class ExportFacts(
    public val snapshot: ExportSnapshot? = null,
    public val failure: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The four outcomes the page distinguishes. */
public enum class ExportStatus {
    /** The host reported at least one measured fact. */
    READY,

    /** The host reported a snapshot but no fact in it was measured. */
    EMPTY,

    /** The last host read failed. */
    FAILED,

    /** The host did not report a snapshot: the page says 未知, never an empty report. */
    UNKNOWN,
}

/**
 * The complete export screen state.
 *
 * @param status the four-state outcome; a failure wins because a failed read
 *   proves nothing about the report.
 * @param reportStatus the report's status label, `null` when unmeasured.
 * @param environment the environment, `null` when unmeasured.
 * @param device the device model, `null` when unmeasured.
 * @param formatVersion the format version, `null` when unmeasured.
 * @param written whether a file exists.
 * @param fileName the written file's name, `null` when there is none.
 * @param previewLines the preview lines after truncation, empty when unreported.
 * @param hiddenLines how many lines the truncation left out; 0 when none.
 * @param previewReported whether the host reported any preview text.
 * @param writeError the last write error, `null` when the last write succeeded.
 * @param failure the read failure, `null` unless FAILED.
 */
@Immutable
public data class ExportScreenState(
    public val status: ExportStatus,
    public val reportStatus: String?,
    public val environment: String?,
    public val device: String?,
    public val formatVersion: String?,
    public val written: FactState,
    public val fileName: String?,
    public val previewLines: List<String>,
    public val hiddenLines: Int,
    public val previewReported: Boolean,
    public val writeError: String?,
    public val failure: String?,
) {
    /** True when the host reported an empty snapshot. */
    public val isEmpty: Boolean get() = status == ExportStatus.EMPTY

    /** True when the host reported no snapshot. */
    public val isUnknown: Boolean get() = status == ExportStatus.UNKNOWN

    /** True when the last read failed. */
    public val isFailed: Boolean get() = status == ExportStatus.FAILED

    /** True when the host reported a file the user may share. */
    public val canShare: Boolean
        get() = written == FactState.YES && fileName != null

    /** True when at least one rendered value is 未知 inside a measured report. */
    public val hasUnmeasuredValues: Boolean
        get() = status == ExportStatus.READY && (
            reportStatus == null || environment == null || device == null ||
                formatVersion == null || written == FactState.UNKNOWN ||
                (written == FactState.YES && fileName == null)
            )

    /**
     * A display-free signature of the sequence-relevant state.
     *
     * The preview length is included, the preview text is not: a replay compares
     * the shape without depending on host copy.
     */
    public fun signature(): String = buildString {
        append(status.name).append('|').append(written.name)
        append("|file=").append(fileName != null)
        append("|preview=").append(previewLines.size).append('+').append(hiddenLines)
        append("|reported=").append(previewReported)
        if (writeError != null) append("|writeError")
        if (failure != null) append("|failure")
    }

    public companion object {
        /** The most preview lines the page shows; the rest become one "还有 N 行" line. */
        public const val PREVIEW_LINE_LIMIT: Int = 80

        /**
         * Projects (facts) into the screen state.
         *
         * Pure: no file read, no write and no clock. The host owns the file, so
         * the same facts always yield the same state and the same truncation.
         */
        public fun from(facts: ExportFacts): ExportScreenState {
            val snapshot = facts.snapshot
            val failure = facts.failure
            val status = when {
                failure != null -> ExportStatus.FAILED
                snapshot == null -> ExportStatus.UNKNOWN
                !snapshot.hasMeasurement -> ExportStatus.EMPTY
                else -> ExportStatus.READY
            }
            val measured = snapshot.takeIf { status == ExportStatus.READY }
            val reportedPreview = measured?.preview?.takeIf { it.isNotBlank() }
            val allLines = reportedPreview?.lines().orEmpty()
            val shown = allLines.take(PREVIEW_LINE_LIMIT)
            return ExportScreenState(
                status = status,
                reportStatus = measured?.reportStatus?.takeUnless { it.isBlank() },
                environment = measured?.environment?.takeUnless { it.isBlank() },
                device = measured?.device?.takeUnless { it.isBlank() },
                formatVersion = measured?.formatVersion?.takeUnless { it.isBlank() },
                written = measured?.written ?: FactState.UNKNOWN,
                fileName = measured?.fileName?.takeUnless { it.isBlank() },
                previewLines = shown,
                hiddenLines = (allLines.size - shown.size).coerceAtLeast(0),
                previewReported = reportedPreview != null,
                writeError = measured?.writeError?.takeUnless { it.isBlank() },
                failure = failure,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The export page.
 *
 * @param state the pure screen state (`ExportScreenState.from`).
 * @param onBack leave the page (push or a sheet's close, per §1).
 * @param onWrite ask the host to write the report; also the "write again" action.
 * @param modifier the caller's modifier.
 * @param onOpen the baseline's `.onAppear` side effect (refresh the Lockdown
 *   observation and write); it defaults to [onWrite] so the open-writes
 *   behaviour survives a caller that only wires the button.
 * @param onShare share the written file through the platform share sheet; `null`
 *   hides the action (`share-sheet` in §5 keeps it a page action).
 * @param onRetry retry the host read; `null` hides the retry.
 * @param onDismissFailure dismiss the failure line; `null` hides it.
 */
@Composable
public fun ExportPage(
    state: ExportScreenState,
    onBack: () -> Unit,
    onWrite: () -> Unit,
    modifier: Modifier = Modifier,
    onOpen: (() -> Unit)? = onWrite,
    onShare: (() -> Unit)? = null,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
) {
    // The baseline writes on appear; `LaunchedEffect(Unit)` runs it once per
    // composition, not on every recomposition.
    LaunchedEffect(Unit) {
        onOpen?.invoke()
    }
    PageFrame(
        title = UiStrings.EXPORT_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.EXPORT_ROOT,
        modifier = modifier,
    ) {
        ProbeControlsTheme {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(UiPageTags.EXPORT_LIST),
                verticalArrangement = Arrangement.spacedBy(pageListGap),
            ) {
                state.failure?.let { failure ->
                    item(key = "export.failure") {
                        SessionFailureLine(
                            message = failure,
                            tag = UiPageTags.EXPORT_FAILURE,
                            retryLabel = if (onRetry != null) UiStrings.RETRY else null,
                            onRetry = onRetry,
                            onDismiss = onDismissFailure,
                        )
                    }
                }
                reportBlock(state, onWrite, onShare)
                previewBlock(state)
            }
        }
    }
}

/** The report facts, the write action and the share action. */
private fun LazyListScope.reportBlock(
    state: ExportScreenState,
    onWrite: () -> Unit,
    onShare: (() -> Unit)?,
) {
    item(key = "export.report.label") {
        SessionSectionLabel(UiStrings.EXPORT_SECTION_REPORT)
    }
    reportRow("export.status", UiPageTags.EXPORT_STATUS, UiStrings.EXPORT_STATUS, state.reportStatus)
    reportRow(
        "export.environment",
        UiPageTags.EXPORT_ENVIRONMENT,
        UiStrings.EXPORT_ENVIRONMENT,
        state.environment,
    )
    reportRow("export.device", UiPageTags.EXPORT_DEVICE, UiStrings.EXPORT_DEVICE, state.device)
    reportRow(
        "export.format",
        UiPageTags.EXPORT_FORMAT_VERSION,
        UiStrings.EXPORT_FORMAT_VERSION,
        state.formatVersion,
    )
    item(key = "export.file") {
        InfoRow(
            title = UiStrings.EXPORT_FILE,
            value = fileText(state.written, state.fileName),
            subtitle = UiStrings.EXPORT_PREVIEW_NOTE,
            tone = if (state.written == FactState.UNKNOWN) PageTone.UNKNOWN else PageTone.NORMAL,
            modifier = Modifier.testTag(UiPageTags.EXPORT_FILE),
        )
    }
    item(key = "export.actions") {
        val tokens = LocalUiTokens.current
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                ),
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Button(
                onClick = onWrite,
                modifier = Modifier.testTag(UiPageTags.EXPORT_WRITE),
            ) {
                Text(
                    text = UiStrings.EXPORT_WRITE,
                    style = LocalUiType.current.secondary,
                )
            }
            if (onShare != null && state.canShare) {
                OutlinedButton(
                    onClick = onShare,
                    modifier = Modifier.testTag(UiPageTags.EXPORT_SHARE),
                ) {
                    Text(
                        text = UiStrings.EXPORT_SHARE,
                        style = LocalUiType.current.secondary,
                    )
                }
            }
        }
    }
    state.writeError?.let { error ->
        item(key = "export.write.failed") {
            ProbeNote(
                text = error,
                ink = ProbeInk.DANGER,
                modifier = Modifier
                    .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                    .testTag(UiPageTags.EXPORT_WRITE_FAILED),
            )
        }
    }
}

/** One report fact; an unmeasured value renders 未知, never a blank. */
private fun LazyListScope.reportRow(
    key: String,
    tag: String,
    title: String,
    value: String?,
) {
    item(key = key) {
        InfoRow(
            title = title,
            value = value ?: UiStrings.UNKNOWN,
            tone = if (value == null) PageTone.UNKNOWN else PageTone.NORMAL,
            modifier = Modifier.testTag(tag),
        )
    }
}

/** The preview: the host's text in the mono face, cut at 80 lines. */
private fun LazyListScope.previewBlock(state: ExportScreenState) {
    item(key = "export.preview.label") {
        SessionSectionLabel(UiStrings.EXPORT_SECTION_PREVIEW)
    }
    if (!state.previewReported) {
        item(key = "export.preview.unknown") {
            ProbeNote(
                text = UiStrings.UNKNOWN,
                ink = ProbeInk.TERTIARY,
                modifier = Modifier
                    .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                    .testTag(UiPageTags.EXPORT_PREVIEW),
            )
        }
        return
    }
    item(key = "export.preview.text") {
        PreviewBlock(lines = state.previewLines, hiddenLines = state.hiddenLines)
    }
}

/**
 * The preview text: the host's JSON lines in the declared mono face. The
 * baseline is a plain `.caption2.monospaced()` Text; there is no code-block
 * chrome here.
 */
@Composable
private fun PreviewBlock(lines: List<String>, hiddenLines: Int) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            .testTag(UiPageTags.EXPORT_PREVIEW_TEXT),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        SelectionContainer {
            Column(verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV)) {
                BasicText(
                    text = lines.joinToString("\n"),
                    style = type.code.copy(color = tokens.colors.secondary),
                )
                if (hiddenLines > 0) {
                    BasicText(
                        text = UiStrings.EXPORT_PREVIEW_MORE.format(hiddenLines),
                        style = type.caption.copy(color = tokens.colors.tertiary),
                        modifier = Modifier.testTag(UiPageTags.EXPORT_PREVIEW_MORE),
                    )
                }
            }
        }
    }
}

/** The file's value: a measured "not written" is a fact, an unmeasured one is 未知. */
private fun fileText(written: FactState, fileName: String?): String = when {
    written == FactState.NO -> UiStrings.EXPORT_FILE_NOT_WRITTEN
    fileName != null -> fileName
    else -> UiStrings.UNKNOWN
}

/** Every token this file reads; kept equal to the source by `PageTokenReferenceTest`. */
internal object ExportPageTokens {
    val refs: List<String> = listOf(
        "colors.secondary",
        "colors.tertiary",
        "geometry.pageOuterMarginH",
        "spacing.badgeInsetV",
        "spacing.iconText",
        "typography.caption",
        "typography.code",
        "typography.secondary",
    )
}
