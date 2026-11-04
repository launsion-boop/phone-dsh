// The in-session workbench: the turn's written files and the commands it ran.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (`NativeWorkbenchPage`: 会话内工作面板（文件 / 命令
// 两段）; entry: 对话里点工具写出的文件路径（含待预览路径补开）; exit: sheet, `完成`
// 关闭), §3.1 (the ScreenState layer) and §5 (`insets`, `back-gesture`).
//
// This page has no harness event anchor: the files a turn's tools wrote and the
// commands it executed are facts only the host can read, so §3.1 rule 3 makes the
// host's read-only snapshot the UiState-side input. `WorkbenchScreenState.from` is a
// pure function of (snapshot, local script): no clock, no engine, no I/O, so the
// segment and preview sequence is replayable on the JVM.
//
// Nothing is fabricated. A list the host did not report is 未知 with an explanation,
// never an empty list and never a zero; a file whose size or writing tool was not
// measured renders 未知; a tapped path the snapshot does not list yet stays pending
// (the host may still be materializing the write) and opens once it appears.
//
// Geometry: the page margin and the two row floors are the page-level tokens that
// `spec/ui/v1/tokens.json` declares. The preview card reuses the tool row's card
// inset and vertical breathing room; both reuses are marked `unverified geometry`
// where they are used, and no length is invented here.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiColors

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/** Which of the workbench's two segments is on top. */
public enum class WorkbenchSection {
    FILES,
    COMMANDS,
}

/** What one segment's body shows. */
public enum class WorkbenchSegmentStatus {
    /** The host reported a list and it is empty. */
    EMPTY,

    /** The host reported at least one row. */
    READY,

    /** The host did not report the list at all; the page says 未知 instead of "none". */
    UNKNOWN,
}

/** The page-level outcome of the snapshot read. */
public enum class WorkbenchStatus {
    READY,

    /** The last host read failed; no list claim survives it. */
    FAILED,

    /** Neither list was reported: the page is unknown, not empty. */
    UNKNOWN,
}

/**
 * One file a tool wrote during the current turn, as the host measured it.
 *
 * @param id the host's stable id for the row.
 * @param name the display name the host reported; a blank name renders 未知.
 * @param path the workspace-relative path: the key a preview read answers with.
 * @param toolName the tool that wrote it; `null` when the host did not report it.
 * @param byteCount the measured size; `null` when the host did not measure it.
 */
@Immutable
public data class WorkbenchFile(
    public val id: String,
    public val name: String,
    public val path: String,
    public val toolName: String? = null,
    public val byteCount: Long? = null,
)

/**
 * One command the current turn executed.
 *
 * @param exitCode the host's exit code; `null` while it runs or when the host did
 *   not report one. It is never defaulted to 0: "did not measure" is not "succeeded".
 */
@Immutable
public data class WorkbenchCommand(
    public val id: String,
    public val command: String,
    public val exitCode: Int? = null,
)

/** The host's answer to one preview read: which path it read, and what it saw. */
@Immutable
public data class WorkbenchRead(
    public val path: String,
    public val content: FileContentView,
)

/**
 * The host's read-only snapshot of the current turn.
 *
 * @param files the files this turn's tools wrote; `null` means the host did not
 *   report the list (未知), while `emptyList()` means it reported "none".
 * @param commands the same shape for the executed commands.
 * @param read the preview read the host performed for the local preview path.
 * @param failure the host's read failure; non-null when the last read failed.
 */
@Immutable
public data class WorkbenchSnapshot(
    public val files: List<WorkbenchFile>? = null,
    public val commands: List<WorkbenchCommand>? = null,
    public val read: WorkbenchRead? = null,
    public val failure: String? = null,
    /**
     * Whether the host can perform the sheet's file read. `NO` disables every file
     * row (a preview cannot be opened) and prints [UiStrings.HOST_READ_ONLY_HINT];
     * 完成 stays enabled because closing the sheet is not a host write.
     *
     * `UNKNOWN` is not `NO`: a host that did not report writability has not said
     * the page is read-only, and disabling on `UNKNOWN` would assert a negative
     * we do not know. Only an explicit `NO` disables — the same rule the page
     * follows when it renders 未知 instead of 0.
     */
    public val writable: FactState = FactState.UNKNOWN,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** What the preview slot shows. */
public sealed interface WorkbenchPreview {
    /** No preview: the segment body is on top. */
    public data object Hidden : WorkbenchPreview

    /** The tapped path is not in the snapshot yet; the write may still be in flight. */
    public data class Pending(public val name: String) : WorkbenchPreview

    /** The file is listed and the host has not answered the read yet. */
    public data class Loading(public val name: String) : WorkbenchPreview

    /** A decodable text file. */
    public data class Text(
        public val name: String,
        public val content: String,
        public val truncated: Boolean,
    ) : WorkbenchPreview

    /** A binary file: the degradation card, never a garbled body. */
    public data class Binary(public val name: String, public val byteCount: Long?) : WorkbenchPreview

    /** The read failed; [reason] is the host's own reason, or `null` when it gave none. */
    public data class Unreadable(public val name: String, public val reason: String?) : WorkbenchPreview
}

/** One file row. */
@Immutable
public data class WorkbenchFileView(
    public val id: String,
    public val name: String,
    public val path: String,
    /** Measured size; `null` renders 未知, never 0. */
    public val byteCount: Long?,
    /** Writing tool; `null` renders 未知, never an empty string. */
    public val toolName: String?,
)

/** One command row. */
@Immutable
public data class WorkbenchCommandView(
    public val id: String,
    public val command: String,
    /** Measured exit code; `null` renders 未知. */
    public val exitCode: Int?,
)

/**
 * The complete workbench screen state.
 *
 * @param section the visible segment.
 * @param status the page outcome; [WorkbenchStatus.FAILED] wins, because a failed
 *   read proves neither an empty nor a populated list.
 * @param filesStatus what the files segment proves.
 * @param commandsStatus what the commands segment proves.
 * @param files the file rows; empty whenever [status] is not [WorkbenchStatus.READY].
 * @param commands the command rows; empty whenever [status] is not READY.
 * @param preview the preview slot.
 * @param failure the host's failure message, re-shown by the page.
 * @param hasUnmeasuredValues true when the visible segment has a 未知 value, so the
 *   page can explain the word once instead of per row.
 */
@Immutable
public data class WorkbenchScreenState(
    public val section: WorkbenchSection,
    public val status: WorkbenchStatus,
    public val filesStatus: WorkbenchSegmentStatus,
    public val commandsStatus: WorkbenchSegmentStatus,
    public val files: List<WorkbenchFileView>,
    public val commands: List<WorkbenchCommandView>,
    public val preview: WorkbenchPreview,
    public val failure: String?,
    public val hasUnmeasuredValues: Boolean,
    /**
     * False when the host reported that it cannot read a file here: the file rows
     * are disabled and the read-only line explains why before the tap.
     */
    public val canWrite: Boolean = true,
) {
    /** True while the preview sub-page is on top of the segments. */
    public val isPreviewing: Boolean get() = preview != WorkbenchPreview.Hidden

    public companion object {
        /**
         * Projects (snapshot, local preview/segment script) into the screen state.
         *
         * Pure: the same snapshot and the same script always yield the same state,
         * so the two segments and the preview degradation sequence replay in a JVM
         * test (§3.1).
         */
        public fun from(
            snapshot: WorkbenchSnapshot,
            local: WorkbenchLocalState = WorkbenchLocalState(),
        ): WorkbenchScreenState {
            val failed = snapshot.failure != null
            val filesStatus = segmentStatus(snapshot.files, failed)
            val commandsStatus = segmentStatus(snapshot.commands, failed)
            val status = when {
                failed -> WorkbenchStatus.FAILED
                snapshot.files == null && snapshot.commands == null -> WorkbenchStatus.UNKNOWN
                else -> WorkbenchStatus.READY
            }
            // A failed read clears the rows: keeping a stale list next to "read failed"
            // would claim the list is current when it is not.
            val files = if (status == WorkbenchStatus.READY) {
                snapshot.files.orEmpty().map { file ->
                    WorkbenchFileView(
                        id = file.id,
                        name = displayOrUnknown(file.name),
                        path = file.path,
                        byteCount = file.byteCount,
                        toolName = file.toolName,
                    )
                }
            } else {
                emptyList()
            }
            val commands = if (status == WorkbenchStatus.READY) {
                snapshot.commands.orEmpty().map { command ->
                    WorkbenchCommandView(
                        id = command.id,
                        command = displayOrUnknown(command.command),
                        exitCode = command.exitCode,
                    )
                }
            } else {
                emptyList()
            }
            val section = local.section
            val hasUnmeasured = when (section) {
                WorkbenchSection.FILES -> files.any { it.byteCount == null || it.toolName == null }
                WorkbenchSection.COMMANDS -> commands.any { it.exitCode == null }
            }
            return WorkbenchScreenState(
                section = section,
                status = status,
                filesStatus = filesStatus,
                commandsStatus = commandsStatus,
                files = files,
                commands = commands,
                preview = previewOf(snapshot, local.previewPath),
                failure = snapshot.failure,
                hasUnmeasuredValues = hasUnmeasured,
                canWrite = snapshot.writable != FactState.NO,
            )
        }

        private fun segmentStatus(
            rows: List<*>?,
            failed: Boolean,
        ): WorkbenchSegmentStatus = when {
            failed -> WorkbenchSegmentStatus.UNKNOWN
            rows == null -> WorkbenchSegmentStatus.UNKNOWN
            rows.isEmpty() -> WorkbenchSegmentStatus.EMPTY
            else -> WorkbenchSegmentStatus.READY
        }

        private fun previewOf(snapshot: WorkbenchSnapshot, path: String?): WorkbenchPreview {
            if (path == null) return WorkbenchPreview.Hidden
            val file = snapshot.files?.firstOrNull { it.path == path }
            // The chat page can open a path before the write is materialized; the
            // pending preview re-resolves on the next snapshot without a new event.
            if (file == null) return WorkbenchPreview.Pending(displayName(path))
            // The read is keyed by path so a late answer for another file is not
            // shown under this one.
            val content = snapshot.read?.takeIf { it.path == path }?.content
            return when (content) {
                null -> WorkbenchPreview.Loading(file.name)
                is FileContentView.Text -> WorkbenchPreview.Text(file.name, content.content, content.truncated)
                is FileContentView.Binary -> WorkbenchPreview.Binary(file.name, content.byteCount)
                is FileContentView.Unreadable -> WorkbenchPreview.Unreadable(file.name, content.reason)
            }
        }

        /** A blank host string is 未知, never an empty line the reader has to interpret. */
        private fun displayOrUnknown(raw: String): String =
            raw.trim().ifEmpty { UiStrings.UNKNOWN }

        /** The last path segment, for a pending preview that has no listed name yet. */
        private fun displayName(path: String): String {
            val trimmed = path.trimEnd(PATH_SEPARATOR)
            return trimmed.substringAfterLast(PATH_SEPARATOR).ifEmpty { displayOrUnknown(path) }
        }
    }
}

/** The local UI events of the workbench. */
public sealed interface WorkbenchUiEvent {
    /** Switch the visible segment. */
    public data class SelectSection(public val section: WorkbenchSection) : WorkbenchUiEvent

    /**
     * Open a file path: a row tap, or the path the chat page was asked to preview.
     *
     * The event records the intent only. The snapshot decides whether the file is
     * listed and whether its bytes were read, so a path that arrives before the
     * write is materialized re-resolves on the next snapshot.
     */
    public data class OpenFile(public val path: String) : WorkbenchUiEvent

    /** Close the preview and return to the segment. */
    public data object ClosePreview : WorkbenchUiEvent
}

/** The local script; [apply] is pure, so a test drives it like a reducer. */
@Immutable
public data class WorkbenchLocalState(
    public val section: WorkbenchSection = WorkbenchSection.FILES,
    /** The path the person asked to preview; `null` when no preview is on top. */
    public val previewPath: String? = null,
) {
    /** Applies one local event. */
    public fun apply(event: WorkbenchUiEvent): WorkbenchLocalState = when (event) {
        is WorkbenchUiEvent.SelectSection -> copy(section = event.section)
        is WorkbenchUiEvent.OpenFile -> copy(previewPath = event.path)
        WorkbenchUiEvent.ClosePreview -> copy(previewPath = null)
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The workbench sheet (`NativeWorkbenchPage`).
 *
 * @param state the pure screen state ([WorkbenchScreenState.from]).
 * @param onSelectSection switch the visible segment.
 * @param onOpenFile open a file row for preview; the host applies
 *   `WorkbenchUiEvent.OpenFile` and reads the bytes.
 * @param onClosePreview close the preview sub-page.
 * @param onDone dismiss the sheet (the baseline's `完成`).
 * @param onRetry retry a failed snapshot read.
 * @param onRefreshPending request a fresh host snapshot while a requested path is
 *   not listed yet; `null` keeps the page honest and says the host cannot refresh.
 * @param onDismissFailure dismiss the failure line.
 */
@Composable
public fun NativeWorkbenchPage(
    state: WorkbenchScreenState,
    onSelectSection: (WorkbenchSection) -> Unit,
    onOpenFile: (WorkbenchFileView) -> Unit,
    onClosePreview: () -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
    onRefreshPending: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    // back-gesture (§5): the preview is one level deeper than the segments, so the
    // header's back closes it first. The state decides, not a private flag.
    val onHeaderBack = if (state.isPreviewing) onClosePreview else null
    PageFrame(
        title = previewTitle(state.preview) ?: UiStrings.WORKBENCH_TITLE,
        onBack = onHeaderBack,
        rootTag = UiPageTags.WORKBENCH_ROOT,
        modifier = modifier,
        actions = {
            BasicText(
                text = UiStrings.WORKBENCH_DONE,
                style = type.listItem.copy(color = tokens.colors.pageAccent),
                modifier = Modifier
                    .testTag(UiPageTags.WORKBENCH_DONE)
                    .clickable(role = Role.Button, onClick = onDone)
                    .semantics { contentDescription = UiStrings.WORKBENCH_DONE }
                    .padding(tokens.spacing.iconText),
            )
        },
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            if (state.failure != null) {
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.WORKBENCH_FAILURE,
                    retryLabel = UiStrings.RETRY,
                    onRetry = onRetry,
                    onDismiss = onDismissFailure,
                )
            }
            when {
                state.isPreviewing -> PreviewBody(
                    preview = state.preview,
                    onRefreshPending = onRefreshPending,
                )

                // A failed read with no rows to keep is the failure line only: showing
                // "no files" next to "read failed" would claim a fact we lack.
                state.status == WorkbenchStatus.FAILED -> Unit

                else -> SegmentBody(state = state, onSelectSection = onSelectSection, onOpenFile = onOpenFile)
            }
        }
    }
}

/** The two-segment control plus the visible segment's body. */
@Composable
private fun SegmentBody(
    state: WorkbenchScreenState,
    onSelectSection: (WorkbenchSection) -> Unit,
    onOpenFile: (WorkbenchFileView) -> Unit,
) {
    val tokens = LocalUiTokens.current
    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = HomeMetrics.contentInset,
                    vertical = tokens.spacing.badgeInsetV,
                )
                .clip(RoundedCornerShape(HomeMetrics.bubbleRadius))
                .background(tokens.colors.userBubble),
        ) {
            SegmentTab(
                label = UiStrings.WORKBENCH_FILES,
                isSelected = state.section == WorkbenchSection.FILES,
                tag = UiPageTags.WORKBENCH_FILES_TAB,
                modifier = Modifier.weight(1f),
                onClick = { onSelectSection(WorkbenchSection.FILES) },
            )
            SegmentTab(
                label = UiStrings.WORKBENCH_COMMANDS,
                isSelected = state.section == WorkbenchSection.COMMANDS,
                tag = UiPageTags.WORKBENCH_COMMANDS_TAB,
                modifier = Modifier.weight(1f),
                onClick = { onSelectSection(WorkbenchSection.COMMANDS) },
            )
        }
        SessionHairline()
        when (state.section) {
            WorkbenchSection.FILES -> FilesSegment(state = state, onOpenFile = onOpenFile)
            WorkbenchSection.COMMANDS -> CommandsSegment(state = state)
        }
    }
}

/** One segment tab; colour is the only difference between the two states. */
@Composable
private fun SegmentTab(
    label: String,
    isSelected: Boolean,
    tag: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = label,
        style = type.listItem.copy(
            color = if (isSelected) tokens.colors.textPrimary else tokens.colors.textTertiary,
            textAlign = TextAlign.Center,
        ),
        modifier = modifier
            .testTag(tag)
            // Page-level geometry: a segment tab is a page control, so its floor is
            // the page row minimum rather than a signature button height.
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .clip(RoundedCornerShape(tokens.radius.card))
            .then(if (isSelected) Modifier.background(tokens.colors.surface, RoundedCornerShape(tokens.radius.card)) else Modifier)
            .clickable(role = Role.Tab, onClick = onClick)
            .semantics(mergeDescendants = true) { this.selected = isSelected }
            .padding(horizontal = tokens.spacing.iconText, vertical = tokens.spacing.badgeInsetV),
    )
}

@Composable
private fun FilesSegment(state: WorkbenchScreenState, onOpenFile: (WorkbenchFileView) -> Unit) {
    when (state.filesStatus) {
        WorkbenchSegmentStatus.UNKNOWN -> SegmentStateBlock(
            listTag = UiPageTags.WORKBENCH_FILES_LIST,
            stateTag = UiPageTags.WORKBENCH_FILES_UNKNOWN,
            title = UiStrings.UNKNOWN,
            hint = UiStrings.WORKBENCH_FILES_UNKNOWN_HINT,
        )

        WorkbenchSegmentStatus.EMPTY -> SegmentStateBlock(
            listTag = UiPageTags.WORKBENCH_FILES_LIST,
            stateTag = UiPageTags.WORKBENCH_FILES_EMPTY,
            title = UiStrings.WORKBENCH_FILES_EMPTY,
            hint = UiStrings.WORKBENCH_FILES_EMPTY_HINT,
        )

        WorkbenchSegmentStatus.READY -> LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiPageTags.WORKBENCH_FILES_LIST),
            verticalArrangement = Arrangement.spacedBy(pageListGap),
        ) {
            if (!state.canWrite) {
                item(key = "files.read-only") {
                    ReadOnlyHint(tag = UiPageTags.WORKBENCH_FAILURE + ".read-only")
                }
            }
            if (state.hasUnmeasuredValues) {
                item(key = "files.unmeasured") { UnmeasuredHint() }
            }
            items(items = state.files, key = { it.id }) { file ->
                FileRow(file = file, onOpenFile = onOpenFile, enabled = state.canWrite)
            }
        }
    }
}

@Composable
private fun CommandsSegment(state: WorkbenchScreenState) {
    when (state.commandsStatus) {
        WorkbenchSegmentStatus.UNKNOWN -> SegmentStateBlock(
            listTag = UiPageTags.WORKBENCH_COMMANDS_LIST,
            stateTag = UiPageTags.WORKBENCH_COMMANDS_UNKNOWN,
            title = UiStrings.UNKNOWN,
            hint = UiStrings.WORKBENCH_COMMANDS_UNKNOWN_HINT,
        )

        WorkbenchSegmentStatus.EMPTY -> SegmentStateBlock(
            listTag = UiPageTags.WORKBENCH_COMMANDS_LIST,
            stateTag = UiPageTags.WORKBENCH_COMMANDS_EMPTY,
            title = UiStrings.WORKBENCH_COMMANDS_EMPTY,
            hint = UiStrings.WORKBENCH_COMMANDS_EMPTY_HINT,
        )

        WorkbenchSegmentStatus.READY -> LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiPageTags.WORKBENCH_COMMANDS_LIST),
            verticalArrangement = Arrangement.spacedBy(pageListGap),
        ) {
            if (state.hasUnmeasuredValues) {
                item(key = "commands.unmeasured") { UnmeasuredHint() }
            }
            items(items = state.commands, key = { it.id }) { command ->
                CommandRow(command = command)
            }
        }
    }
}

/**
 * An empty or unknown segment body.
 *
 * It is still a lazy list with one item: a test that has to assert "this value is
 * absent" scrolls to the block first (`performScrollToNode`), so the assertion is
 * about the region rather than about what happened to be composed.
 */
@Composable
private fun SegmentStateBlock(
    listTag: String,
    stateTag: String,
    title: String,
    hint: String,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    LazyColumn(modifier = Modifier.fillMaxSize().testTag(listTag)) {
        item {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(stateTag)
                    .padding(
                        horizontal = HomeMetrics.contentInset,
                        vertical = tokens.spacing.iconText,
                    )
                    .semantics(mergeDescendants = true) {
                        contentDescription = "$title. $hint"
                    },
                verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
            ) {
                BasicText(text = title, style = type.body.copy(color = tokens.colors.textTertiary))
                BasicText(text = hint, style = type.listItem.copy(color = tokens.colors.textTertiary))
            }
        }
    }
}

/** The one line that explains a disabled control: visible before the tap. */
@Composable
private fun ReadOnlyHint(tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = UiStrings.HOST_READ_ONLY_HINT,
        style = type.listItem.copy(color = tokens.colors.textTertiary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** One file row: name, measured size and the writing tool. */
@Composable
private fun FileRow(
    file: WorkbenchFileView,
    onOpenFile: (WorkbenchFileView) -> Unit,
    enabled: Boolean,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.WORKBENCH_FILE_ROW)
            .clickable(enabled = enabled, role = Role.Button, onClick = { onOpenFile(file) })
            // Page-level geometry: a file row is a compact list row and uses the
            // page margin.
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = file.name,
                style = type.body.copy(color = tokens.colors.textPrimary),
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = file.byteCount?.let { formatByteSize(it) } ?: UiStrings.UNKNOWN,
                style = type.listItem.copy(
                    color = if (file.byteCount == null) tokens.colors.textTertiary else tokens.colors.textSecondary,
                ),
            )
        }
        BasicText(
            text = UiStrings.WORKBENCH_WRITTEN_BY.format(file.toolName ?: UiStrings.UNKNOWN),
            style = type.listItem.copy(color = tokens.colors.textTertiary),
        )
    }
}

/** One command row: the argv in a code card and the measured exit code. */
@Composable
private fun CommandRow(command: WorkbenchCommandView) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.WORKBENCH_COMMAND_ROW)
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = command.command,
            style = type.code.copy(color = tokens.colors.textSecondary),
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(tokens.radius.codeBlock))
                .background(tokens.colors.sessionCode)
                .border(
                    width = tokens.stroke.hairline,
                    color = tokens.colors.borderList,
                    shape = RoundedCornerShape(tokens.radius.codeBlock),
                )
                // unverified geometry: the tool row's terminal card inset reused for
                // the command card; only this page has one, so the spec declares no
                // page-level token for it.
                .padding(tokens.geometry.toolCardInset),
        )
        BasicText(
            text = UiStrings.WORKBENCH_EXIT_CODE.format(
                command.exitCode?.toString() ?: UiStrings.UNKNOWN,
            ),
            style = type.listItem.copy(color = command.exitCode.ink(tokens)),
        )
    }
}

/** One line that explains the word 未知 without repeating the explanation per row. */
@Composable
private fun UnmeasuredHint() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = UiStrings.WORKBENCH_UNMEASURED_HINT,
        style = type.listItem.copy(color = tokens.colors.textTertiary),
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

// ---------------------------------------------------------------------------
// Preview sub-page
// ---------------------------------------------------------------------------

@Composable
private fun PreviewBody(preview: WorkbenchPreview, onRefreshPending: (() -> Unit)?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    when (preview) {
        WorkbenchPreview.Hidden -> Unit

        // A tapped path the host has not listed yet: the write may still be in flight,
        // so the page waits instead of claiming the file is missing.
        is WorkbenchPreview.Pending -> Column(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiPageTags.WORKBENCH_PREVIEW_PENDING)
                .padding(horizontal = HomeMetrics.contentInset),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText, Alignment.CenterVertically),
        ) {
            BasicText(
                text = UiStrings.WORKBENCH_PREVIEW_PENDING,
                style = type.body.copy(color = tokens.colors.textPrimary),
            )
            BasicText(
                text = UiStrings.WORKBENCH_PREVIEW_PENDING_HINT,
                style = type.listItem.copy(color = tokens.colors.textSecondary, textAlign = TextAlign.Center),
            )
            BasicText(
                text = if (onRefreshPending == null) PENDING_REFRESH_UNAVAILABLE else PENDING_REFRESH_LABEL,
                style = type.listItem.copy(color = tokens.colors.pageAccent),
                modifier = Modifier
                    .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
                    .then(
                        if (onRefreshPending == null) Modifier
                        else Modifier.clickable(role = Role.Button, onClick = onRefreshPending),
                    )
                    .semantics { contentDescription = if (onRefreshPending == null) PENDING_REFRESH_UNAVAILABLE else PENDING_REFRESH_LABEL },
            )
        }

        is WorkbenchPreview.Loading -> EmptyHint(
            title = UiStrings.FILES_PREVIEW_LOADING,
            hint = null,
            tag = UiPageTags.WORKBENCH_PREVIEW,
        )

        is WorkbenchPreview.Text -> Column(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiPageTags.WORKBENCH_PREVIEW)
                .padding(horizontal = HomeMetrics.contentInset),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    // unverified geometry: the tool card's vertical inset reused as
                    // the preview card's outer vertical breathing room.
                    .padding(vertical = tokens.geometry.toolDetailVertical)
                    .clip(RoundedCornerShape(tokens.radius.codeBlock))
                    .background(tokens.colors.sessionCode)
                    .border(
                        width = tokens.stroke.hairline,
                        color = tokens.colors.borderList,
                        shape = RoundedCornerShape(tokens.radius.codeBlock),
                    )
                    // unverified geometry: no page-level preview card exists in the
                    // spec; the tool card's inset is reused as the padding.
                    .padding(tokens.geometry.toolCardInset)
                    .verticalScroll(rememberScrollState()),
            ) {
                BasicText(
                    text = preview.content,
                    style = type.code.copy(color = tokens.colors.textSecondary),
                )
            }
            if (preview.truncated) {
                BasicText(
                    text = UiStrings.FILES_PREVIEW_TRUNCATED,
                    style = type.listItem.copy(color = tokens.colors.textTertiary),
                )
            }
        }

        is WorkbenchPreview.Binary -> Box(
            modifier = Modifier.fillMaxSize().testTag(UiPageTags.WORKBENCH_PREVIEW),
        ) {
            PreviewCard(
                title = UiStrings.FILES_PREVIEW_BINARY,
                hint = UiStrings.FILES_PREVIEW_BINARY_HINT,
                // The size is a measured number or 未知; never a rounded guess.
                detail = preview.byteCount?.let { formatByteSize(it) } ?: UiStrings.UNKNOWN,
            )
        }

        is WorkbenchPreview.Unreadable -> Box(
            modifier = Modifier.fillMaxSize().testTag(UiPageTags.WORKBENCH_PREVIEW),
        ) {
            PreviewCard(
                title = UiStrings.FILES_PREVIEW_UNAVAILABLE,
                hint = preview.reason ?: UiStrings.FILES_PREVIEW_REASON_UNKNOWN,
                detail = null,
            )
        }
    }
}

/**
 * The degradation card: "you cannot see this content", with measured facts only.
 *
 * It carries the same semantics as the files page's private degradation card and
 * the same copy; `FilesPage`'s body is private, so this is the page-level rendering
 * of the shared `FileContentView` classification rather than a second classifier.
 */
@Composable
private fun PreviewCard(title: String, hint: String, detail: String?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            // unverified geometry: the tool card's vertical inset reused as the
            // degradation card's outer vertical breathing room.
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.geometry.toolDetailVertical,
            )
            .clip(RoundedCornerShape(tokens.radius.card))
            .background(tokens.colors.sessionCodeBanner)
            .padding(tokens.spacing.cardInset),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = title,
            style = type.listItem.copy(color = tokens.colors.pageWarning),
        )
        BasicText(
            text = hint,
            style = type.listItem.copy(color = tokens.colors.textTertiary),
        )
        if (detail != null) {
            BasicText(
                text = detail,
                style = type.listItem.copy(color = tokens.colors.textTertiary),
            )
        }
    }
}

/** The preview header title: the file's name, or the fallback title when hidden. */
private fun previewTitle(preview: WorkbenchPreview): String? = when (preview) {
    WorkbenchPreview.Hidden -> null
    is WorkbenchPreview.Pending -> preview.name
    is WorkbenchPreview.Loading -> preview.name
    is WorkbenchPreview.Text -> preview.name
    is WorkbenchPreview.Binary -> preview.name
    is WorkbenchPreview.Unreadable -> preview.name
}

/** The exit-code ink: unmeasured is neutral, zero is success, non-zero is failure. */
private fun Int?.ink(tokens: com.phonedsh.ui.theme.UiTokens): androidx.compose.ui.graphics.Color = when {
    this == null -> tokens.colors.textTertiary
    this == 0 -> tokens.colors.sessionSuccess
    else -> tokens.colors.pageDanger
}

/** The one path separator the display helper splits on. */
private const val PATH_SEPARATOR: Char = '/'
private const val PENDING_REFRESH_LABEL: String = "重新检查文件"
private const val PENDING_REFRESH_UNAVAILABLE: String = "宿主暂不支持重新检查"

/** Canonical spec names backed by the legacy resolved palette roles. */
private val UiColors.sessionSuccess get() = success
private val UiColors.sessionCode get() = code
private val UiColors.sessionCodeBanner get() = codeBanner

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest`'s page map does not list this file yet (that table is
 * owned by the session-pages lane), so this declaration is the entry a follow-up
 * adds there; `WorkbenchFoldersPageTest` only checks that every name here is a real
 * `tokens.json` leaf.
 */
internal object NativeWorkbenchPageTokens {
    val refs: List<String> = listOf(
        "colors.borderList",
        "colors.pageAccent",
        "colors.pageDanger",
        "colors.pageWarning",
        "colors.sessionCode",
        "colors.sessionCodeBanner",
        "colors.sessionSuccess",
        "colors.surface",
        "colors.textPrimary",
        "colors.textSecondary",
        "colors.textTertiary",
        "colors.userBubble",
        "geometry.toolCardInset",
        "geometry.toolDetailVertical",
        "radius.card",
        "radius.codeBlock",
        "spacing.badgeInsetV",
        "spacing.cardInset",
        "spacing.iconText",
        "stroke.hairline",
        "typography.body",
        "typography.code",
        "typography.listItem",
    )
}
