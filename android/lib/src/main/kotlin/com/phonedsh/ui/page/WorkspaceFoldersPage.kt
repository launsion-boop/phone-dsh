// Workspace folders: the drawer's folder list, its creation, switch and removal.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (`WorkspaceFoldersPage`: 工作区文件夹增删与切换;
// entry: 抽屉「工作文件夹」; push; 每行打开 FilesPage), §3.1 (the ScreenState layer) and
// §5 (`insets`, `ime`, `back-gesture`).
//
// There is no harness event anchor here: the folder list, the current selection and
// the per-folder session count are host facts, so §3.1 rule 3 makes the host's
// read-only snapshot the UiState-side input. `WorkspaceFoldersScreenState.from` is a
// pure function of (snapshot, local create/delete script); name validation is a pure
// function too, so the whole page replays on the JVM.
//
// Safety rules the state machine owns, not the caller:
//   * a name is trimmed and rejected when blank, when it contains a path separator
//     or a control character, or when it is longer than the declared limit;
//   * deleting needs a confirmation, and the folder the host reports as current is
//     never deletable: the page disables the action instead of silently retargeting
//     the selection, and the projection refuses to open the confirmation for it;
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * One workspace folder exactly as the host lists it.
 *
 * @param id the host id used for switch/delete/open.
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
 * @param onSwitch make the folder current; the host applies the switch and re-reads.
 * @param onBeginCreate open the inline create row.
 * @param onDraftChange edit the create draft.
 * @param onCancelCreate close the create row.
 * @param onCreate create the folder from the current draft (the host validates too).
 * @param onDeleteRequest ask for the delete confirmation.
 * @param onDeleteConfirm delete the confirmed folder.
 * @param onDeleteCancel cancel the confirmation.
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
    PageFrame(
        title = UiStrings.WORKSPACE_FOLDERS,
        onBack = onBack,
        rootTag = UiPageTags.WORKSPACE_ROOT,
        modifier = modifier,
        actions = {
            // `NativeShell.swift:376`: the baseline's toolbar verb is 添加; the
            // empty state carries the longer 添加工作文件夹 call to action below.
            SessionTextAction(
                label = UiStrings.WORKSPACE_ADD,
                onClick = onBeginCreate,
                tone = SessionActionTone.ACCENT,
                modifier = Modifier.testTag(UiPageTags.WORKSPACE_NEW),
                enabled = state.canWrite,
            )
        },
    ) {
        // The create field is a text input: the IME must lift the list, not cover it
        // (spec §5 row `ime`).
        Column(modifier = Modifier.fillMaxSize().imePadding()) {
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
                // The create row is pinned above the list on purpose: opening it must
                // not depend on where the (lazy) list happens to be scrolled, and the
                // field must stay visible while the IME is up.
                if (state.creating) {
                    CreateRow(
                        state = state,
                        onDraftChange = onDraftChange,
                        onCancelCreate = onCancelCreate,
                        onCreate = onCreate,
                    )
                }
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
                            items(items = state.folders, key = { it.id }) { folder ->
                                FolderRow(
                                    folder = folder,
                                    writable = state.canWrite,
                                    onOpenFiles = onOpenFiles,
                                    onSwitch = onSwitch,
                                    onDeleteRequest = onDeleteRequest,
                                    onDeleteConfirm = onDeleteConfirm,
                                    onDeleteCancel = onDeleteCancel,
                                )
                                SessionHairline()
                            }
                        }

                        WorkspaceFoldersStatus.FAILED -> Unit
                    }
                }
            }
        }
    }
}

/**
 * The baseline's empty state (`NativeShell.swift:345`-`:363`): 还没有工作文件夹,
 * the one-line hint, and the accent 「添加工作文件夹」 button that opens the same
 * create flow the toolbar's 添加 does. The baseline draws the button as a filled
 * 50 pt call to action; the page-level `geometry.pageRowMinHeight` is the page's
 * declared control floor, so the button takes it instead of a screen-specific
 * height (`geometry.primaryButtonHeight` belongs to the approval card and is not
 * borrowed here).
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
            .testTag(UiPageTags.WORKSPACE_EMPTY),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        BasicText(
            text = UiStrings.WORKSPACE_EMPTY,
            style = type.body.copy(color = tokens.colors.tertiary),
        )
        BasicText(
            text = UiStrings.WORKSPACE_EMPTY_HINT,
            style = type.caption.copy(color = tokens.colors.tertiary),
            modifier = Modifier.padding(top = tokens.spacing.badgeInsetV),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    top = tokens.spacing.iconText,
                    start = tokens.geometry.pageOuterMarginH,
                    end = tokens.geometry.pageOuterMarginH,
                )
                // Page-level geometry: the CTA is a page control and takes the page
                // row floor rather than a screen-specific button height.
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .background(tokens.colors.accent, RoundedCornerShape(tokens.radius.card))
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

/** The inline create row: a validated name field, 创建 and 取消. */
@Composable
private fun CreateRow(
    state: WorkspaceFoldersScreenState,
    onDraftChange: (String) -> Unit,
    onCancelCreate: () -> Unit,
    onCreate: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.WORKSPACE_CREATE_ROW)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = UiStrings.WORKSPACE_NEW,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicTextField(
                value = state.draft,
                onValueChange = onDraftChange,
                singleLine = true,
                textStyle = type.body.copy(color = tokens.colors.primary),
                cursorBrush = SolidColor(tokens.colors.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                modifier = Modifier
                    .weight(1f)
                    // Page-level geometry: an inline field is a page row.
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
            SessionTextAction(
                label = UiStrings.WORKSPACE_CREATE,
                onClick = onCreate,
                tone = SessionActionTone.ACCENT,
                enabled = state.canCreate,
                modifier = Modifier.testTag(UiPageTags.WORKSPACE_CREATE),
            )
            SessionTextAction(
                label = UiStrings.CANCEL,
                onClick = onCancelCreate,
                tone = SessionActionTone.SECONDARY,
            )
        }
        // A blank draft has no message: an error before the first keystroke would
        // shout at the reader for not typing yet. The create action is still disabled.
        val error = state.nameError
        if (state.draft.isNotEmpty() && error != null) {
            BasicText(
                text = workspaceNameErrorText(error),
                style = type.caption.copy(color = tokens.colors.warning),
                modifier = Modifier.testTag(UiPageTags.WORKSPACE_NAME_ERROR),
            )
        }
    }
}

/** One folder row: name, current mark, measured count and the two actions. */
@Composable
private fun FolderRow(
    folder: WorkspaceFolderView,
    writable: Boolean,
    onOpenFiles: (WorkspaceFolderView) -> Unit,
    onSwitch: (WorkspaceFolderView) -> Unit,
    onDeleteRequest: (WorkspaceFolderView) -> Unit,
    onDeleteConfirm: (WorkspaceFolderView) -> Unit,
    onDeleteCancel: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .testTag(UiPageTags.WORKSPACE_ROW)
                .clickable(enabled = writable, role = Role.Button, onClick = { onOpenFiles(folder) })
                // Page-level geometry: a folder row is a compact list row and uses the
                // page margin.
                .defaultMinSize(minHeight = tokens.geometry.pageListRowMinHeight)
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.iconText,
                )
                .semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            if (folder.current) {
                Box(
                    modifier = Modifier
                        // Page-level geometry: the current-selection dot.
                        .size(tokens.geometry.statusDotDiameter)
                        .clip(CircleShape)
                        .background(tokens.colors.accent),
                )
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                ) {
                    BasicText(
                        text = folder.name,
                        style = type.body.copy(
                            color = if (folder.current) tokens.colors.accent else tokens.colors.primary,
                        ),
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                    if (folder.current) {
                        BasicText(
                            text = UiStrings.WORKSPACE_CURRENT,
                            style = type.caption.copy(color = tokens.colors.accent),
                            modifier = Modifier.testTag(UiPageTags.WORKSPACE_CURRENT),
                        )
                    }
                }
                BasicText(
                    // A measured count is a number; an unmeasured one is the word.
                    text = folder.sessionCount?.let { UiStrings.WORKSPACE_SESSION_COUNT.format(it) }
                        ?: UiStrings.UNKNOWN,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                )
            }
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            SessionTextAction(
                label = UiStrings.WORKSPACE_SWITCH,
                onClick = { onSwitch(folder) },
                tone = SessionActionTone.SECONDARY,
                enabled = writable && !folder.current,
                description = "${UiStrings.WORKSPACE_SWITCH} ${folder.name}",
                modifier = Modifier.testTag(UiPageTags.WORKSPACE_SWITCH),
            )
            SessionTextAction(
                label = UiStrings.WORKSPACE_DELETE,
                onClick = { onDeleteRequest(folder) },
                tone = SessionActionTone.DANGER,
                enabled = writable && folder.deletable,
                description = "${UiStrings.WORKSPACE_DELETE} ${folder.name}",
                modifier = Modifier.testTag(UiPageTags.WORKSPACE_DELETE),
            )
            if (!folder.deletable) {
                BasicText(
                    text = UiStrings.WORKSPACE_SELECTED_LOCKED,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                    modifier = Modifier
                        .weight(1f)
                        .testTag(UiPageTags.WORKSPACE_LOCKED),
                )
            }
        }
        if (folder.confirmingDelete) {
            DeleteConfirmRow(
                folder = folder,
                writable = writable,
                onDeleteConfirm = onDeleteConfirm,
                onDeleteCancel = onDeleteCancel,
            )
        }
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
        trimmed.lowercase() == DEFAULT_FOLDER_NAME -> UiStrings.WORKSPACE_DEFAULT_NAME
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
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_ON_ACCENT,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_PAGE_LIST_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_STATUS_DOT_DIAMETER,
    )
}
