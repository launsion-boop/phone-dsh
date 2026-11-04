// Workspace folders: the drawer's folder list and file-list entry.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (`WorkspaceFoldersPage`: 工作区文件夹列表与文件入口;
// entry: 抽屉「工作文件夹」; push; 每行打开 FilesPage), §3.1 (the ScreenState layer) and
// §5 (`insets`, `ime`, `back-gesture`).
//
// There is no harness event anchor here: the folder list, the current selection and
// the per-folder session count are host facts, so §3.1 rule 3 makes the host's
// read-only snapshot the UiState-side input. `WorkspaceFoldersScreenState.from` is a
// pure function of (snapshot, local create script); name validation is a pure
// function too, so the whole page replays on the JVM.
//
// Safety rules the state machine owns, not the caller:
//   * a name is trimmed and rejected when blank, when it contains a path separator
//     or a control character, or when it is longer than the declared limit;
//   * the current selection is a host fact; this page only opens a folder's FilesPage
//     and does not expose a switch/delete action that the iOS page does not have;
//   * a list the host did not report is 未知 with an explanation, never an empty
//     list; an unmeasured session count renders 未知, never 0.
//
// Geometry: the page margin, the two row floors and the current-selection dot are
// the page-level tokens declared in `spec/ui/v1/tokens.json`. No signature-surface
// geometry is reused here, so no reuse note is needed below.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.SessionsMetrics
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.surface.PageBarCapsule
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * One workspace folder exactly as the host lists it.
 *
 * @param id the host id used to open this folder's file listing.
 * @param name the host name; the built-in folder is reworded for display and a
 *   blank name renders 未知.
 * @param sessionCount the host's session count; `null` when it did not measure it.
 */
@Immutable
public data class WorkspaceFolder(
    public val id: String,
    public val name: String,
    public val sessionCount: Long? = null,
)

/**
 * The host's read-only snapshot of the folder list.
 *
 * @param folders the folders; `null` means the host did not report the list (未知),
 *   while `emptyList()` means it reported "none".
 * @param selectedID the folder the next session lands in; `null` when the host
 *   reported no current folder (the page then marks no row as current).
 * @param failure the host's read failure; non-null when the last read failed.
 */
@Immutable
public data class WorkspaceFoldersSnapshot(
    public val folders: List<WorkspaceFolder>? = null,
    public val selectedID: String? = null,
    public val failure: String? = null,
    /**
     * Whether the host can create, switch or delete a folder here. `NO` disables
     * the 新建 action, the create confirmation and every row action, and prints
     * [UiStrings.HOST_READ_ONLY_HINT].
     *
     * `UNKNOWN` is not `NO`: a host that did not report writability has not said
     * the page is read-only, and disabling on `UNKNOWN` would assert a negative
     * we do not know. Only an explicit `NO` disables — the same rule the page
     * follows when it renders 未知 instead of 0.
     */
    public val writable: FactState = FactState.UNKNOWN,
    /** Last host-confirmed workspace write, or `null` when no result was reported. */
    public val mutationReceipt: PageMutationReceipt? = null,
)

/** The four states the page distinguishes. */
public enum class WorkspaceFoldersStatus {
    /** The host reported at least one folder. */
    READY,

    /** The host reported a list and it is empty. */
    EMPTY,

    /** The last host read failed; no list claim survives it. */
    FAILED,

    /** The host did not report the list: the page says 未知 instead of "none". */
    UNKNOWN,
}

/** Why a typed folder name is not usable yet; `null` means it is. */
public enum class WorkspaceNameError {
    EMPTY,
    SEPARATOR,
    CONTROL,
    TOO_LONG,
}

/** The longest name the baseline accepts (`createWorkspaceFolder` rejects more). */
public const val WORKSPACE_NAME_MAX_LENGTH: Int = 64

/**
 * Validates a typed folder name.
 *
 * Pure: no clock, no filesystem. The accepted rule is the baseline's
 * (`createWorkspaceFolder`): non-empty, no `/`, at most [WORKSPACE_NAME_MAX_LENGTH]
 * characters. Control characters are rejected on top of that because the field is
 * single-line and a name carrying a line break could never be edited again; a
 * backslash is *not* rejected, because the baseline accepts it and the workspace is
 * a POSIX path (a stricter rule here would refuse a name iOS creates).
 */
public fun validateWorkspaceName(raw: String): WorkspaceNameError? {
    val name = raw.trim()
    return when {
        name.isEmpty() -> WorkspaceNameError.EMPTY
        name.any { it == PATH_SEPARATOR } -> WorkspaceNameError.SEPARATOR
        name.any { it.isISOControl() } -> WorkspaceNameError.CONTROL
        name.length > WORKSPACE_NAME_MAX_LENGTH -> WorkspaceNameError.TOO_LONG
        else -> null
    }
}

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** One visible folder row. */
@Immutable
public data class WorkspaceFolderView(
    public val id: String,
    public val name: String,
    /** Measured session count; `null` renders 未知, never 0. */
    public val sessionCount: Long?,
    /** True for the folder the host reports as current. */
    public val current: Boolean,
    /** The current folder cannot be removed; every other folder can. */
    public val deletable: Boolean,
    /** True while this row's delete confirmation is open. */
    public val confirmingDelete: Boolean,
)

/**
 * The complete workspace-folders screen state.
 *
 * @param status the four-state outcome.
 * @param folders the visible rows; empty unless [status] is READY or EMPTY.
 * @param failure the host's failure message, re-shown by the page.
 * @param creating true while the inline create row is open.
 * @param draft the create field's text.
 * @param nameError the validation result for [draft]; `null` when usable.
 * @param canCreate true only when [creating] and [nameError] is `null`.
 * @param deleteTargetID the folder whose confirmation is open; never the current one.
 * @param hasUnmeasuredValues true when a row's session count is unmeasured.
 * @param canWrite false when the host reported the page is not writable: 新建,
 *   创建, 切换 and 删除 are disabled and the read-only line is shown.
 */
@Immutable
public data class WorkspaceFoldersScreenState(
    public val status: WorkspaceFoldersStatus,
    public val folders: List<WorkspaceFolderView>,
    public val failure: String?,
    public val creating: Boolean,
    public val draft: String,
    public val nameError: WorkspaceNameError?,
    public val canCreate: Boolean,
    public val deleteTargetID: String?,
    public val hasUnmeasuredValues: Boolean,
    public val canWrite: Boolean = true,
    public val mutationReceipt: PageMutationReceipt? = null,
) {
    /** True when the host reported an empty list. */
    public val isEmpty: Boolean get() = status == WorkspaceFoldersStatus.EMPTY

    /** True when the host reported no list at all. */
    public val isUnknown: Boolean get() = status == WorkspaceFoldersStatus.UNKNOWN

    public companion object {
        /**
         * Projects (snapshot, local create/delete script) into the screen state.
         *
         * Pure: the same snapshot and the same script always yield the same rows,
         * validation result and confirmation target, so the sequence replays in a
         * JVM test (§3.1).
         */
        public fun from(
            snapshot: WorkspaceFoldersSnapshot,
            local: WorkspaceFoldersLocalState = WorkspaceFoldersLocalState(),
        ): WorkspaceFoldersScreenState {
            val status = when {
                snapshot.failure != null -> WorkspaceFoldersStatus.FAILED
                snapshot.folders == null -> WorkspaceFoldersStatus.UNKNOWN
                snapshot.folders.isEmpty() -> WorkspaceFoldersStatus.EMPTY
                else -> WorkspaceFoldersStatus.READY
            }
            // A failed or unread list keeps no rows: keeping a stale list next to
            // "read failed" would claim it is current when it is not.
            val facts = if (status == WorkspaceFoldersStatus.READY) snapshot.folders.orEmpty() else emptyList()
            // The current folder is protected before the confirmation opens, so a
            // stale local request can never target it.
            val deleteTargetID = local.deleteTargetID?.takeIf { id ->
                id != snapshot.selectedID && facts.any { it.id == id }
            }
            val folders = facts.map { folder ->
                val current = folder.id == snapshot.selectedID
                WorkspaceFolderView(
                    id = folder.id,
                    name = workspaceDisplayName(folder.name),
                    sessionCount = folder.sessionCount,
                    current = current,
                    deletable = !current,
                    confirmingDelete = folder.id == deleteTargetID,
                )
            }
            val nameError = if (local.creating) validateWorkspaceName(local.draft) else null
            return WorkspaceFoldersScreenState(
                status = status,
                folders = folders,
                failure = snapshot.failure,
                creating = local.creating,
                draft = local.draft,
                nameError = nameError,
                canCreate = local.creating && nameError == null &&
                    snapshot.writable != FactState.NO,
                deleteTargetID = deleteTargetID,
                hasUnmeasuredValues = folders.any { it.sessionCount == null },
                canWrite = snapshot.writable != FactState.NO,
                mutationReceipt = snapshot.mutationReceipt,
            )
        }
    }
}

/** The local UI events of the folder page: create and delete are the only ones. */
public sealed interface WorkspaceFoldersUiEvent {
    /** Open the inline create row. */
    public data object BeginCreate : WorkspaceFoldersUiEvent

    /** Edit the create field's draft. */
    public data class DraftChange(public val text: String) : WorkspaceFoldersUiEvent

    /** Close the create row and drop the draft. */
    public data object CancelCreate : WorkspaceFoldersUiEvent

    /** Ask for the delete confirmation of one folder. */
    public data class RequestDelete(public val folderID: String) : WorkspaceFoldersUiEvent

    /** Cancel the delete confirmation. */
    public data object CancelDelete : WorkspaceFoldersUiEvent
}

/**
 * The local script; [apply] is pure, so a test drives it like a reducer.
 *
 * Selection is not local: switching changes the host's current folder, so the host
 * applies that action and re-reads the snapshot.
 */
@Immutable
public data class WorkspaceFoldersLocalState(
    public val creating: Boolean = false,
    public val draft: String = "",
    public val deleteTargetID: String? = null,
) {
    /** Applies one local event. */
    public fun apply(event: WorkspaceFoldersUiEvent): WorkspaceFoldersLocalState = when (event) {
        WorkspaceFoldersUiEvent.BeginCreate -> copy(creating = true)
        is WorkspaceFoldersUiEvent.DraftChange -> copy(draft = event.text)
        WorkspaceFoldersUiEvent.CancelCreate -> copy(creating = false, draft = "")
        is WorkspaceFoldersUiEvent.RequestDelete -> copy(deleteTargetID = event.folderID)
        WorkspaceFoldersUiEvent.CancelDelete -> copy(deleteTargetID = null)
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The workspace folders page (`WorkspaceFoldersPage`).
 *
 * @param state the pure screen state ([WorkspaceFoldersScreenState.from]).
 * @param onBack pop the page (the drawer row pushes it).
 * @param onOpenFiles open the folder's file list (`FilesPage`).
 * @param onSwitch legacy host callback; this page does not render a switch action.
 * @param onBeginCreate open the create alert.
 * @param onDraftChange edit the create draft.
 * @param onCancelCreate close the create alert.
 * @param onCreate create the folder from the current draft (the host validates too).
 * @param onDeleteRequest legacy host callback; this page does not render deletion.
 * @param onDeleteConfirm legacy host callback; this page does not render deletion.
 * @param onDeleteCancel legacy host callback; this page does not render deletion.
 * @param onRetry retry a failed read.
 * @param onDismissFailure dismiss the failure line.
 */
@Composable
public fun WorkspaceFoldersPage(
    state: WorkspaceFoldersScreenState,
    onBack: () -> Unit,
    onOpenFiles: (WorkspaceFolderView) -> Unit,
    onSwitch: (WorkspaceFolderView) -> Unit,
    onBeginCreate: () -> Unit,
    onDraftChange: (String) -> Unit,
    onCancelCreate: () -> Unit,
    onCreate: () -> Unit,
    onDeleteRequest: (WorkspaceFolderView) -> Unit,
    onDeleteConfirm: (WorkspaceFolderView) -> Unit,
    onDeleteCancel: () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    // The baseline is a **large-title** page: `.navigationTitle("工作文件夹")` +
    // `.navigationBarTitleDisplayMode(.large)` (`NativeShell.swift:372`–`:373`),
    // measured on `ios-workspace-folders.png` at 34 pt, ink y 125.33–155.33, leading
    // inset 17.33. It also paints its own page fill (`.background(Color.white)`,
    // `:378`), so the frame's `pageFill` mode is what puts the same white behind the
    // rows instead of the Material surface.
    SettingsSubPageFrame(
        largeTitle = UiStrings.WORKSPACE_FOLDERS,
        onBack = onBack,
        backGlyph = PAGE_BACK_GLYPH,
        pageFill = true,
        rootTag = UiPageTags.WORKSPACE_ROOT,
        modifier = modifier,
        trailing = {
            // `NativeShell.swift:376`–`:379`: `Button("添加")` with a 17 pt accent
            // title. On iOS 26 a bar button floats in a white capsule over the page
            // (`ios-workspace-folders.png`: pill ≈ x 309.0–386.7, y ≈ 69.7–113.3, the
            // white fill visible only through its shadow; title ink #2F5BFF =
            // `colors.pageAccent`). The empty state below carries the longer
            // 添加工作文件夹 call to action.
            PageBarCapsule(
                description = UiStrings.WORKSPACE_ADD,
                onClick = onBeginCreate,
                insetH = com.phonedsh.ui.SettingsMetrics.WORKSPACE_TOOLBAR_TEXT_INSET_H_PT.dp,
                elevation = com.phonedsh.ui.SettingsMetrics.WORKSPACE_TOOLBAR_SHADOW_ELEVATION_PT.dp,
                enabled = state.canWrite,
                tag = UiPageTags.WORKSPACE_NEW,
            )
        },
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            state.mutationReceipt?.let { PageMutationReceiptLine(it) }
            if (state.failure != null) {
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.WORKSPACE_FAILURE,
                    retryLabel = UiStrings.RETRY,
                    onRetry = onRetry,
                    onDismiss = onDismissFailure,
                )
            }
            // A failed read with no rows to keep is the failure line only.
            if (state.status != WorkspaceFoldersStatus.FAILED) {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .testTag(UiPageTags.WORKSPACE_LIST),
                ) {
                    if (!state.canWrite) {
                        item(key = "read-only") {
                            ReadOnlyHint(tag = UiPageTags.WORKSPACE_FAILURE + ".read-only")
                        }
                    }
                    when (state.status) {
                        WorkspaceFoldersStatus.UNKNOWN -> item(key = "unknown") { UnknownBlock() }

                        WorkspaceFoldersStatus.EMPTY -> item(key = "empty") {
                            EmptyWorkspace(
                                canWrite = state.canWrite,
                                onCreate = onBeginCreate,
                                modifier = Modifier.fillParentMaxSize(),
                            )
                        }

                        WorkspaceFoldersStatus.READY -> {
                            if (state.hasUnmeasuredValues) {
                                item(key = "unmeasured") { UnmeasuredHint() }
                            }
                            itemsIndexed(items = state.folders, key = { _, folder -> folder.id }) { index, folder ->
                                FolderRow(
                                    folder = folder,
                                    onOpenFiles = onOpenFiles,
                                )
                                if (index < state.folders.lastIndex) {
                                    SessionHairline(modifier = Modifier.padding(horizontal = tokens.geometry.pageOuterMarginH))
                                }
                            }
                        }

                        WorkspaceFoldersStatus.FAILED -> Unit
                    }
                }
            }
        }
    }
    if (state.creating) {
        WorkspaceCreateDialog(
            state = state,
            onDraftChange = onDraftChange,
            onCancel = onCancelCreate,
            onCreate = onCreate,
        )
    }
}

/**
 * The baseline's empty state (`NativeShell.swift:345`-`:363`): 还没有工作文件夹,
 * the one-line hint, and the accent 「添加工作文件夹」 button that opens the same
 * create flow the toolbar's 添加 does. The baseline draws the button as a filled
 * 50 pt call to action (`NativeShell.swift:354-360`); this shared CTA metric was
 * measured on the sessions empty state and has the same source height/radius.
 *
 * @param canWrite false when the host reported the page read-only: the button is
 *   disabled, not hidden, so the empty state never promises an action it cannot do.
 * @param onCreate open the inline create row.
 */
@Composable
private fun EmptyWorkspace(
    canWrite: Boolean,
    onCreate: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = modifier
            .fillMaxSize()
            // `ios-workspace-folders.png`: the empty block starts directly below the
            // title area (24 pt of breathing room), not vertically centred.
            .padding(top = tokens.spacing.cardInset * 2)
            .testTag(UiPageTags.WORKSPACE_EMPTY),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Top,
    ) {
        BasicText(
            text = UiStrings.WORKSPACE_EMPTY,
            // `NativeShell.swift:347`: 17 pt semibold primary.
            style = type.headline.copy(
                color = tokens.colors.primary,
                textAlign = TextAlign.Center,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
        BasicText(
            text = UiStrings.WORKSPACE_EMPTY_HINT,
            // `NativeShell.swift:349`: 13 pt secondary, centred.
            style = type.secondary.copy(
                color = tokens.colors.secondary,
                textAlign = TextAlign.Center,
            ),
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = tokens.spacing.badgeInsetV),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    top = tokens.spacing.cardInset,
                    // `ios-workspace-folders.png`: the CTA is 337.7 pt wide, i.e. the
                    // page margin twice on each side, matching the baseline's inset
                    // grouped row inset plus the button's own 16 pt inset.
                    start = tokens.geometry.pageOuterMarginH * 2,
                    end = tokens.geometry.pageOuterMarginH * 2,
                )
                .height(SessionsMetrics.ctaHeight)
                .background(tokens.colors.pageAccent, RoundedCornerShape(tokens.radius.card))
                .clickable(enabled = canWrite, role = Role.Button, onClick = onCreate)
                .testTag(UiPageTags.WORKSPACE_ADD_FOLDER)
                .semantics { contentDescription = UiStrings.WORKSPACE_ADD_FOLDER },
            contentAlignment = Alignment.Center,
        ) {
            BasicText(
                text = UiStrings.WORKSPACE_ADD_FOLDER,
                style = type.headline.copy(color = tokens.colors.onAccent),
            )
        }
    }
}

/** The iOS alert (`NativeShell.swift:376-394`) with a single validated name field. */
@Composable
private fun WorkspaceCreateDialog(
    state: WorkspaceFoldersScreenState,
    onDraftChange: (String) -> Unit,
    onCancel: () -> Unit,
    onCreate: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    AlertDialog(
        onDismissRequest = onCancel,
        modifier = Modifier.testTag(UiPageTags.WORKSPACE_CREATE_ROW),
        title = {
            BasicText(
                text = UiStrings.SESSIONS_NEW_WORKSPACE,
                style = type.headline.copy(color = tokens.colors.primary),
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText)) {
                BasicTextField(
                    value = state.draft,
                    onValueChange = onDraftChange,
                    singleLine = true,
                    textStyle = type.body.copy(color = tokens.colors.primary),
                    cursorBrush = SolidColor(tokens.colors.accent),
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.None,
                        autoCorrectEnabled = false,
                        imeAction = ImeAction.Done,
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = tokens.geometry.pageRowMinHeight)
                        .testTag(UiPageTags.WORKSPACE_NAME_FIELD)
                        .semantics { contentDescription = UiStrings.WORKSPACE_NAME },
                    decorationBox = { inner ->
                        if (state.draft.isEmpty()) {
                            BasicText(
                                text = UiStrings.WORKSPACE_NAME,
                                style = type.body.copy(color = tokens.colors.tertiary),
                            )
                        }
                        inner()
                    },
                )
                BasicText(
                    text = UiStrings.SESSIONS_WORKSPACE_CREATE_DETAIL,
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
                val error = state.nameError
                if (state.draft.isNotEmpty() && error != null) {
                    BasicText(
                        text = workspaceNameErrorText(error),
                        style = type.caption.copy(color = tokens.colors.warning),
                        modifier = Modifier.testTag(UiPageTags.WORKSPACE_NAME_ERROR),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = onCreate,
                enabled = state.canCreate,
                modifier = Modifier.testTag(UiPageTags.WORKSPACE_CREATE),
            ) {
                BasicText(
                    text = UiStrings.WORKSPACE_CREATE,
                    style = type.body.copy(color = if (state.canCreate) tokens.colors.accent else tokens.colors.tertiary),
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onCancel) {
                BasicText(text = UiStrings.CANCEL, style = type.body.copy(color = tokens.colors.secondary))
            }
        },
        containerColor = tokens.colors.input,
        textContentColor = tokens.colors.secondary,
    )
}

/** One iOS navigation row: name and count, opening that folder's FilesPage. */
@Composable
private fun FolderRow(folder: WorkspaceFolderView, onOpenFiles: (WorkspaceFolderView) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(tokens.colors.surface)
            .testTag(UiPageTags.WORKSPACE_ROW)
            // Folder opening is a read; the grouped-list row stays available in
            // the host's read-only mode.
            .clickable(role = Role.Button, onClick = { onOpenFiles(folder) })
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .padding(horizontal = HomeMetrics.contentInset)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(WORKSPACE_ROW_GAP_PT.dp),
    ) {
        BasicText(
            text = folder.name,
            style = type.body.copy(color = tokens.colors.primary),
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        // iOS's HStack places the measured count on the same line before the
        // navigation chevron (`NativeShell.swift:279-290`).
        BasicText(
            text = folder.sessionCount?.let { UiStrings.WORKSPACE_SESSION_COUNT.format(it) }
                ?: UiStrings.UNKNOWN,
            style = type.subheadline.copy(color = tokens.colors.secondary),
            maxLines = 1,
        )
        BasicText(
            text = WORKSPACE_ROW_CHEVRON,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
    }
}

/** The destructive confirmation; deleting a folder is never a single tap. */
@Composable
private fun DeleteConfirmRow(
    folder: WorkspaceFolderView,
    writable: Boolean,
    onDeleteConfirm: (WorkspaceFolderView) -> Unit,
    onDeleteCancel: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = UiStrings.WORKSPACE_DELETE_CONFIRM,
            style = type.secondary.copy(color = tokens.colors.primary),
        )
        BasicText(
            text = UiStrings.WORKSPACE_DELETE_DETAIL,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            SessionTextAction(
                label = UiStrings.WORKSPACE_DELETE,
                onClick = { onDeleteConfirm(folder) },
                tone = SessionActionTone.DANGER,
                enabled = writable,
                description = "${UiStrings.WORKSPACE_DELETE} ${folder.name}",
                modifier = Modifier.testTag(UiPageTags.WORKSPACE_DELETE_YES),
            )
            SessionTextAction(
                label = UiStrings.CANCEL,
                onClick = onDeleteCancel,
                tone = SessionActionTone.SECONDARY,
                modifier = Modifier.testTag(UiPageTags.WORKSPACE_DELETE_NO),
            )
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
        style = type.caption.copy(color = tokens.colors.tertiary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** The unknown block: the word plus the reason the page cannot say more. */
@Composable
private fun UnknownBlock() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.WORKSPACE_UNKNOWN)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {
                contentDescription = "${UiStrings.UNKNOWN}. ${UiStrings.WORKSPACE_UNKNOWN_HINT}"
            },
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = UiStrings.UNKNOWN,
            style = type.body.copy(color = tokens.colors.tertiary),
        )
        BasicText(
            text = UiStrings.WORKSPACE_UNKNOWN_HINT,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
    }
}

/** One line that explains the word 未知 without repeating it per row. */
@Composable
private fun UnmeasuredHint() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = UiStrings.WORKSPACE_UNMEASURED_HINT,
        style = type.caption.copy(color = tokens.colors.tertiary),
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

// ---------------------------------------------------------------------------
// Copy policy helpers
// ---------------------------------------------------------------------------

/**
 * The visible folder name.
 *
 * The baseline rewords the built-in `workspace` folder as 默认文件夹; a user folder
 * keeps its own name, and a blank host name is 未知 rather than an empty row.
 */
internal fun workspaceDisplayName(raw: String): String {
    val trimmed = raw.trim()
    return when {
        trimmed.isEmpty() -> UiStrings.UNKNOWN
        trimmed.lowercase() == DEFAULT_FOLDER_NAME -> UiStrings.DRAWER_DEFAULT_FOLDER
        else -> trimmed
    }
}

/** The message for one validation result; the page owns the copy. */
internal fun workspaceNameErrorText(error: WorkspaceNameError): String = when (error) {
    WorkspaceNameError.EMPTY -> UiStrings.WORKSPACE_NAME_EMPTY
    WorkspaceNameError.SEPARATOR -> UiStrings.WORKSPACE_NAME_SEPARATOR
    WorkspaceNameError.CONTROL -> UiStrings.WORKSPACE_NAME_CONTROL
    WorkspaceNameError.TOO_LONG -> UiStrings.WORKSPACE_NAME_TOO_LONG.format(WORKSPACE_NAME_MAX_LENGTH)
}

/** The one path separator the validation rejects (the baseline's own rule). */
private const val PATH_SEPARATOR: Char = '/'

/** The baseline's built-in folder name, compared lowercase and never shown raw. */
private const val DEFAULT_FOLDER_NAME: String = "workspace"
/** `NativeShell.swift:327`: folder name/count spacing in the navigation row. */
private const val WORKSPACE_ROW_GAP_PT: Float = 12f
private const val WORKSPACE_ROW_CHEVRON: String = "›"

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest`'s page map does not list this file yet (that table is
 * owned by the session-pages lane), so this declaration is the entry a follow-up
 * adds there; `WorkbenchFoldersPageTest` only checks that every name here is a real
 * `tokens.json` leaf.
 */
internal object WorkspaceFoldersPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_PAGE_ACCENT,
        UiTokenNames.COLORS_ON_ACCENT,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.COLORS_INPUT,
        UiTokenNames.COLORS_SURFACE,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.TYPOGRAPHY_SUBHEADLINE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        // L75: the toolbar capsule's two page-layer lengths. The white page fill and
        // the 34 pt title are the frame's (`pageFill` / `largeTitle`).
    )
}
