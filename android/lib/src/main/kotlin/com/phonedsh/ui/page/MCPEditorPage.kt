// MCP editor: the baseline's two groups — the server form and its auth headers.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/pages/mcp-editor.json` (extracted from
// `MCPSettingsPage.swift:165` in the probe app) and `spec/ui/v1/README.md` §1 row
// MCPEditorPage (单个 MCP 服务器的编辑; it is the editor sub-page of
// MCPSettingsPage), plus §3.1 (the ScreenState layer).
//
// The baseline's four blocks, in its order:
//   * `服务器` (`MCPSettingsPage.swift:188`) — 名称, MCP URL, 启用, 工具调用超时;
//   * `认证头与设备密钥` (`:203`) — one editable row per header plus 添加认证头,
//     with the "the value only lives in this phone's keychain" footer (`:229`);
//   * an untitled error block (`:233`, runtime text only — the contract's own
//     unresolved entry, so it has no group title here either);
//   * an untitled block (`:238`) holding the save verb (`:239`, whose label is
//     dynamic in the baseline: 保存并连接 / 保存修改并重连) and, for an existing
//     server, 删除并撤销授权与密钥 (`:260`).
//
// Android additionally offers a transport choice (本地命令 / 网络地址): the phone's
// host can launch a local command as well as reach a URL, which the iOS baseline
// (HTTP only) has no counterpart for. It lives inside `服务器` because it is a
// property of the server, not a group of its own.
//
// Validation is not allowed to be swallowed: every rule is a pure function of the
// draft, the errors carry the field they belong to, and the page prints each
// error directly under its own field as soon as the field was touched or the
// user tried to save. The save action stays enabled while the form is invalid on
// purpose: tapping it is how the user asks "what is wrong?".
//
// Security red line: the stored command, URL and header values are never read
// into the page. [MCPStoredServer] carries only whether a value is stored
// ([FactState]), and a header row's placeholder says "keep" instead of showing
// what is kept, so the only place a secret can appear is the editable field the
// user typed into. Error copy is page-owned and never echoes the draft, so a URL
// or a header value with a token cannot end up in a validation message.
//
// ScreenState: `MCPEditorScreenState.from(facts, local)` is pure. The local
// events are the field edits, the transport choice, the enable toggle, the
// header edits and the submit; replaying the same script yields the same state
// sequence (§3.1).
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageRowMinHeight`); the section captions reuse the shared
// `SessionSectionLabel` and the list gap is the shared `pageListGap`.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.VisualTransformation
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SecretVisualTransformation
import com.phonedsh.ui.surface.SettingsSubPageFootnote
import com.phonedsh.ui.surface.secretInputSemantics
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames
import java.net.URI
import java.net.URISyntaxException

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/** How the host talks to an MCP server. */
public enum class MCPTransport {
    /** A local command the host launches (`stdio`). */
    STDIO,

    /** A network endpoint (`http`/`https`). */
    HTTP,
}

/**
 * One authentication header being edited.
 *
 * @param name the header name (`Authorization`, …).
 * @param envName the environment variable the value is stored under; blank lets
 *   the host generate one.
 * @param value the value the user typed **in this session**. It is deliberately
 *   not seeded from the store: the page never receives a stored value, only
 *   [hasStoredValue].
 * @param hasStoredValue whether the device keychain already holds a value for
 *   this header. [FactState.YES] and [FactState.UNKNOWN] both make a blank field
 *   mean "keep"; [FactState.NO] is a freshly added row.
 */
@Immutable
public data class MCPHeaderDraft(
    public val name: String = "",
    public val envName: String = "",
    public val value: String = "",
    public val hasStoredValue: FactState = FactState.NO,
)

/**
 * The editable form. It starts blank for a new server and blank-or-kept for an
 * existing one: [MCPStoredServer] never hands the stored command, URL or header
 * value over.
 *
 * @param toolCallTimeoutMs the tool-call timeout in milliseconds, as typed. Blank
 *   means "the host's own default" — an empty field is not a zero.
 * @param headers the auth-header rows, in the user's order.
 */
@Immutable
public data class MCPServerDraft(
    public val id: String = "",
    public val name: String = "",
    public val transport: MCPTransport = MCPTransport.HTTP,
    public val command: String = "",
    public val url: String = "",
    public val enabled: Boolean = true,
    public val toolCallTimeoutMs: String = "",
    public val headers: List<MCPHeaderDraft> = emptyList(),
)

/**
 * One stored header, as far as the editor may see it.
 *
 * There is deliberately no `value` field: the value lives in the device keychain
 * and must not reach the UI. [hasStoredValue] is the only thing the page knows.
 */
@Immutable
public data class MCPStoredHeader(
    public val name: String,
    public val envName: String = "",
    public val hasStoredValue: FactState = FactState.UNKNOWN,
)

/**
 * An existing server, as far as the editor may see it.
 *
 * There is deliberately no `command`, `url` or header value: the stored values
 * may embed credentials and must not reach the UI. The page can say whether a
 * value is stored and treats a blank draft field as "keep it".
 *
 * @param commandStored whether a stdio command is stored ([FactState]).
 * @param urlStored whether a network URL is stored ([FactState]).
 * @param toolCallTimeoutMs the stored timeout, or `null` when the host did not
 *   report one. A timeout is not a secret, so it is safe to seed the field.
 * @param headers the stored header names; the values stay in the keychain.
 */
@Immutable
public data class MCPStoredServer(
    public val id: String,
    public val name: String,
    public val transport: MCPTransport,
    public val enabled: Boolean = true,
    public val commandStored: FactState = FactState.UNKNOWN,
    public val urlStored: FactState = FactState.UNKNOWN,
    public val toolCallTimeoutMs: String? = null,
    public val headers: List<MCPStoredHeader> = emptyList(),
)

/** Why the editor could not load or save; the wording is page-owned. */
public enum class MCPEditorFailureReason {
    /** The host rejected the save. The draft is kept in the form. */
    SAVE_FAILED,

    /** The host reported a failure without a category the page can name. */
    UNKNOWN,
}

/**
 * The editor's read-only input.
 *
 * @param server the stored server; `null` when adding a new one.
 * @param targetUnreadable true when the host was asked to edit a server but
 *   could not read it. That is 未知, never an empty new-server form.
 * @param failure the last save failure, as a category.
 */
@Immutable
public data class MCPEditorFacts(
    public val server: MCPStoredServer? = null,
    public val targetUnreadable: Boolean = false,
    public val failure: MCPEditorFailureReason? = null,
    /**
     * Whether the host can persist the draft. `NO` does not disable 保存 — §1
     * makes that a handoff to the host — but it prints
     * [UiStrings.MCP_EDITOR_HANDOFF_HINT] next to the button so the person knows
     * the save is a handoff rather than a local commit.
     *
     * `UNKNOWN` is not `NO`: a host that did not report writability has not said
     * the page is read-only, and disabling on `UNKNOWN` would assert a negative
     * we do not know. Only an explicit `NO` disables — the same rule the page
     * follows when it renders 未知 instead of 0.
     */
    public val writable: FactState = FactState.UNKNOWN,
)

/** The fields a validation error can point at. */
public enum class MCPField {
    NAME,
    COMMAND,
    URL,
}

/** One validation error, attached to the field it explains. */
@Immutable
public data class MCPFieldError(
    public val field: MCPField,
    public val message: String,
)

// ---------------------------------------------------------------------------
// Validation (pure)
// ---------------------------------------------------------------------------

/**
 * Validates one draft.
 *
 * @param storedCommand whether a stdio command is already stored. [FactState.NO]
 *   is the new-server default and makes a blank field an error; [FactState.YES]
 *   and [FactState.UNKNOWN] make a blank field mean "keep", because the page
 *   cannot prove the host has nothing to keep.
 * @param storedUrl same, for the network URL.
 *
 * Errors are returned in field order (name, then the active transport's field)
 * so the screen and a test can compare the list without sorting.
 *
 * The auth-header rows and the timeout are deliberately not validated here: the
 * baseline accepts a half-filled header row (`MCPSettingsPage.swift:224` appends
 * an empty one) and a blank timeout means "the host's default", so rejecting
 * either would be the page inventing a rule the host does not have.
 */
public fun validateServerDraft(
    draft: MCPServerDraft,
    storedCommand: FactState = FactState.NO,
    storedUrl: FactState = FactState.NO,
): List<MCPFieldError> {
    val errors = mutableListOf<MCPFieldError>()
    val name = draft.name.trim()
    when {
        name.isEmpty() -> errors += MCPFieldError(MCPField.NAME, UiStrings.MCP_ERR_NAME_REQUIRED)
        !MCP_NAME_PATTERN.matches(name) ->
            errors += MCPFieldError(MCPField.NAME, UiStrings.MCP_ERR_NAME_INVALID)
    }
    when (draft.transport) {
        MCPTransport.STDIO -> {
            if (draft.command.isBlank() && storedCommand == FactState.NO) {
                errors += MCPFieldError(MCPField.COMMAND, UiStrings.MCP_ERR_COMMAND_REQUIRED)
            }
        }

        MCPTransport.HTTP -> {
            if (draft.url.isBlank() && storedUrl == FactState.NO) {
                errors += MCPFieldError(MCPField.URL, UiStrings.MCP_ERR_URL_REQUIRED)
            } else if (draft.url.isNotBlank()) {
                when {
                    draft.url.trim().any { it.isWhitespace() } ->
                        errors += MCPFieldError(MCPField.URL, UiStrings.MCP_ERR_URL_INVALID)

                    else -> {
                        val uri = parseHttpUri(draft.url)
                        when {
                            uri == null ->
                                errors += MCPFieldError(MCPField.URL, UiStrings.MCP_ERR_URL_INVALID)

                            uri.userInfo != null ->
                                errors += MCPFieldError(MCPField.URL, UiStrings.MCP_ERR_URL_CREDENTIALS)

                            else -> Unit
                        }
                    }
                }
            }
        }
    }
    return errors
}

/**
 * True when [raw] is an `http`/`https` URL with a host and no embedded
 * credentials.
 *
 * Pure: `java.net.URI` parses without touching the network, so the same string
 * yields the same verdict on the JVM and on the device.
 */
public fun isValidHttpUrl(raw: String): Boolean {
    val text = raw.trim()
    if (text.isEmpty() || text.any { it.isWhitespace() }) return false
    val uri = parseHttpUri(text) ?: return false
    return uri.userInfo == null
}

private fun parseHttpUri(raw: String): URI? {
    val text = raw.trim()
    val uri = try {
        URI(text)
    } catch (_: URISyntaxException) {
        return null
    }
    val scheme = uri.scheme?.lowercase() ?: return null
    if (scheme != "http" && scheme != "https") return null
    if (uri.host.isNullOrEmpty()) return null
    return uri
}

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/**
 * One auth-header row, projected from the draft and the stored facts.
 *
 * @param name the header name as typed (or as stored), never a placeholder.
 * @param envName the environment variable name as typed.
 * @param value the value typed in this session — the field's own content, never
 *   a stored value.
 * @param valuePlaceholder what the empty value field means for this row:
 *   [UiStrings.MCP_FIELD_HEADER_VALUE_STORED] (a value is stored; blank keeps
 *   it), [UiStrings.MCP_EDITOR_STORED_UNKNOWN] (the host did not say), or
 *   [UiStrings.MCP_FIELD_HEADER_VALUE] (a fresh row).
 */
@Immutable
public data class MCPHeaderRowView(
    public val name: String,
    public val envName: String,
    public val value: String,
    public val valuePlaceholder: String,
)

/**
 * The complete editor state.
 *
 * [draft] is the editable form (and therefore carries the user's own typed URL
 * and header values); [errors] is every validation error and [visibleErrors]
 * only the ones the user should see now (touched field or an attempted save).
 * No page-authored display string is built from the draft, so a secret typed
 * into a field cannot leak into an error line.
 *
 * @param phase the data phase; [UNKNOWN] replaces the form entirely.
 * @param title 添加 or 编辑 (page-owned).
 * @param isNew true when there is no stored server.
 * @param submitted true once the user pressed save.
 * @param failure the page-owned save-failure copy, or `null`.
 * @param commandStoredLabel the "blank keeps the stored command" line, when one
 *   applies to the active transport.
 * @param urlStoredLabel the same for the URL.
 * @param headers one row per auth header, in the user's order.
 */
@Immutable
public data class MCPEditorScreenState(
    public val phase: SettingsDataPhase,
    public val title: String,
    public val draft: MCPServerDraft,
    public val isNew: Boolean,
    public val errors: List<MCPFieldError> = emptyList(),
    public val visibleErrors: List<MCPFieldError> = emptyList(),
    public val submitted: Boolean = false,
    public val failure: String? = null,
    public val commandStoredLabel: String? = null,
    public val urlStoredLabel: String? = null,
    public val headers: List<MCPHeaderRowView> = emptyList(),
    /**
     * False when the host reported it cannot persist a draft: 保存 stays enabled
     * (it is a handoff) and the handoff line is shown before the tap.
     */
    public val canPersist: Boolean = true,
) {
    /** No readable target: there is no form to fill in. */
    public val isUnknown: Boolean get() = phase == SettingsDataPhase.UNKNOWN

    /** The last save failed; the form is kept and can be submitted again. */
    public val isFailed: Boolean get() = phase == SettingsDataPhase.FAILED

    /** The initial form: a new server with nothing typed yet. */
    public val isEmpty: Boolean
        get() = phase == SettingsDataPhase.READY && isNew &&
            draft.name.isBlank() && draft.command.isBlank() && draft.url.isBlank()

    /** Save is only hidden when there is no form at all. */
    public val canSubmit: Boolean get() = phase != SettingsDataPhase.UNKNOWN

    /**
     * 删除并撤销授权与密钥 only exists for a server that is already registered
     * (`MCPSettingsPage.swift:249`: `if let existing`). A new server has nothing
     * to delete, so the row is not rendered — the verb is never a no-op.
     */
    public val canDelete: Boolean get() = !isNew && !isUnknown

    /** The visible error for one field, or `null` when that field is fine. */
    public fun errorFor(field: MCPField): String? =
        visibleErrors.firstOrNull { it.field == field }?.message

    public companion object {
        /**
         * Projects (facts, local script) into the screen state.
         *
         * Pure: no clock, no I/O, no engine. The same facts and the same script
         * always yield the same state sequence (§3.1).
         */
        public fun from(
            facts: MCPEditorFacts,
            local: MCPEditorLocalState = MCPEditorLocalState(),
        ): MCPEditorScreenState {
            val isNew = facts.server == null
            val draft = local.draft ?: facts.server?.toDraft() ?: MCPServerDraft()
            // A new server has nothing stored; an existing one reports its own
            // fact, including UNKNOWN (blank keeps whatever the host holds).
            val errors = validateServerDraft(
                draft = draft,
                storedCommand = facts.server?.commandStored ?: FactState.NO,
                storedUrl = facts.server?.urlStored ?: FactState.NO,
            )
            val visible = errors.filter { local.submitted || it.field in local.touched }
            val phase = when {
                // An unreadable target wins: there is no form to retry a save
                // from, and the unknown state is the honest statement.
                facts.targetUnreadable -> SettingsDataPhase.UNKNOWN
                facts.failure != null -> SettingsDataPhase.FAILED
                else -> SettingsDataPhase.READY
            }
            val storedLabel = when (facts.server?.commandStored) {
                FactState.YES -> UiStrings.MCP_EDITOR_KEEP_COMMAND
                FactState.UNKNOWN -> UiStrings.MCP_EDITOR_STORED_UNKNOWN
                else -> null
            }
            val storedUrlLabel = when (facts.server?.urlStored) {
                FactState.YES -> UiStrings.MCP_EDITOR_KEEP_URL
                FactState.UNKNOWN -> UiStrings.MCP_EDITOR_STORED_UNKNOWN
                else -> null
            }
            return MCPEditorScreenState(
                phase = phase,
                // An unreadable target is still an edit, not a new server: the
                // title must not promise an empty form the page cannot show.
                title = if (isNew && !facts.targetUnreadable) {
                    UiStrings.MCP_EDITOR_NEW
                } else {
                    UiStrings.MCP_EDITOR_EDIT
                },
                draft = draft,
                isNew = isNew,
                errors = errors,
                visibleErrors = visible,
                submitted = local.submitted,
                failure = facts.failure?.text(),
                commandStoredLabel = storedLabel.takeIf { draft.transport == MCPTransport.STDIO },
                urlStoredLabel = storedUrlLabel.takeIf { draft.transport == MCPTransport.HTTP },
                headers = draft.headers.map { header ->
                    MCPHeaderRowView(
                        name = header.name,
                        envName = header.envName,
                        value = header.value,
                        valuePlaceholder = header.hasStoredValue.placeholder(),
                    )
                },
                canPersist = facts.writable != FactState.NO,
            )
        }

        /**
         * What an empty value field means for one row.
         *
         * NO is a fresh row: the placeholder is the field's own name. YES and
         * UNKNOWN both say "blank keeps what is stored"; UNKNOWN says the page
         * cannot even tell whether something is stored, which is not the same
         * claim as "nothing is".
         */
        private fun FactState.placeholder(): String = when (this) {
            FactState.YES -> UiStrings.MCP_FIELD_HEADER_VALUE_STORED
            FactState.NO -> UiStrings.MCP_FIELD_HEADER_VALUE
            FactState.UNKNOWN -> UiStrings.MCP_EDITOR_STORED_UNKNOWN
        }

        private fun MCPEditorFailureReason.text(): String = when (this) {
            MCPEditorFailureReason.SAVE_FAILED -> UiStrings.MCP_EDITOR_FAILURE_SAVE
            MCPEditorFailureReason.UNKNOWN -> UiStrings.MCP_EDITOR_FAILURE_UNKNOWN
        }
    }
}

/** Seeds the editable fields from the stored server; secrets stay on the host. */
private fun MCPStoredServer.toDraft(): MCPServerDraft = MCPServerDraft(
    id = id,
    name = name,
    transport = transport,
    enabled = enabled,
    toolCallTimeoutMs = toolCallTimeoutMs.orEmpty(),
    headers = headers.map { header ->
        MCPHeaderDraft(
            name = header.name,
            envName = header.envName,
            // The stored value is not read, so the row starts blank and keeps it.
            value = "",
            hasStoredValue = header.hasStoredValue,
        )
    },
)

/** The local UI events of the editor: field edits, transport, enable, headers, submit. */
public sealed interface MCPEditorUiEvent {
    public data class EditName(public val value: String) : MCPEditorUiEvent
    public data class EditCommand(public val value: String) : MCPEditorUiEvent
    public data class EditUrl(public val value: String) : MCPEditorUiEvent
    public data class EditTimeout(public val value: String) : MCPEditorUiEvent
    public data class SelectTransport(public val transport: MCPTransport) : MCPEditorUiEvent
    public data class ToggleEnabled(public val enabled: Boolean) : MCPEditorUiEvent

    /** Appends one empty header row (`MCPSettingsPage.swift:224`). */
    public data object AddHeader : MCPEditorUiEvent

    /** Drops the header row at [index]; an out-of-range index is a no-op. */
    public data class RemoveHeader(public val index: Int) : MCPEditorUiEvent
    public data class EditHeaderName(public val index: Int, public val value: String) : MCPEditorUiEvent
    public data class EditHeaderEnv(public val index: Int, public val value: String) : MCPEditorUiEvent
    public data class EditHeaderValue(public val index: Int, public val value: String) : MCPEditorUiEvent

    /** The user pressed save; this is what makes every error visible. */
    public data object Submit : MCPEditorUiEvent
}

/**
 * The editor's local script.
 *
 * [apply] is pure and takes the facts because the first edit of an existing
 * server starts from the stored (non-secret) fields; the host can therefore
 * replay a script without keeping a second draft.
 *
 * The header events are index-addressed and tolerate a stale index (a row
 * removed between the event and the replay): the draft simply does not change,
 * rather than the script throwing on a list the user already changed.
 */
@Immutable
public data class MCPEditorLocalState(
    public val draft: MCPServerDraft? = null,
    public val touched: Set<MCPField> = emptySet(),
    public val submitted: Boolean = false,
) {
    /** Applies one local event. */
    public fun apply(
        event: MCPEditorUiEvent,
        facts: MCPEditorFacts = MCPEditorFacts(),
    ): MCPEditorLocalState {
        val base = draft ?: facts.server?.toDraft() ?: MCPServerDraft()
        return when (event) {
            is MCPEditorUiEvent.EditName -> copy(
                draft = base.copy(name = event.value),
                touched = touched + MCPField.NAME,
            )

            is MCPEditorUiEvent.EditCommand -> copy(
                draft = base.copy(command = event.value),
                touched = touched + MCPField.COMMAND,
            )

            is MCPEditorUiEvent.EditUrl -> copy(
                draft = base.copy(url = event.value),
                touched = touched + MCPField.URL,
            )

            is MCPEditorUiEvent.EditTimeout -> copy(
                draft = base.copy(toolCallTimeoutMs = event.value),
            )

            is MCPEditorUiEvent.SelectTransport -> copy(
                draft = base.copy(transport = event.transport),
            )

            is MCPEditorUiEvent.ToggleEnabled -> copy(
                draft = base.copy(enabled = event.enabled),
            )

            MCPEditorUiEvent.AddHeader -> copy(
                draft = base.copy(headers = base.headers + MCPHeaderDraft()),
            )

            is MCPEditorUiEvent.RemoveHeader -> copy(
                draft = base.copy(
                    headers = base.headers.filterIndexed { index, _ -> index != event.index },
                ),
            )

            is MCPEditorUiEvent.EditHeaderName -> copy(
                draft = base.copy(
                    headers = base.headers.editAt(event.index) { it.copy(name = event.value) },
                ),
            )

            is MCPEditorUiEvent.EditHeaderEnv -> copy(
                draft = base.copy(
                    headers = base.headers.editAt(event.index) { it.copy(envName = event.value) },
                ),
            )

            is MCPEditorUiEvent.EditHeaderValue -> copy(
                draft = base.copy(
                    headers = base.headers.editAt(event.index) { it.copy(value = event.value) },
                ),
            )

            MCPEditorUiEvent.Submit -> copy(submitted = true)
        }
    }
}

/** Replaces one row, leaving every other row (and a stale index) alone. */
private fun List<MCPHeaderDraft>.editAt(
    index: Int,
    change: (MCPHeaderDraft) -> MCPHeaderDraft,
): List<MCPHeaderDraft> = mapIndexed { position, header ->
    if (position == index) change(header) else header
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The MCP server editor.
 *
 * @param state the pure screen state ([MCPEditorScreenState.from]).
 * @param onEditName onEditCommand onEditUrl onEditTimeout the field edits; the
 *   host applies the matching `MCPEditorUiEvent` and re-projects.
 * @param onSelectTransport the transport choice.
 * @param onToggleEnabled the enable switch (the baseline's 启用 row).
 * @param onSubmit the save action, called with the current draft. The host
 *   applies `MCPEditorUiEvent.Submit` first, then persists only when
 *   `state.errors` is empty; when it is not, the re-projected state shows every
 *   error in place. This is the "validation is not swallowed" contract.
 * @param onBack leave the page (the draft is the host's to keep or drop).
 * @param onAddHeader appends one header row (`MCPEditorUiEvent.AddHeader`).
 * @param onRemoveHeader drops the row at that index.
 * @param onEditHeaderName onEditHeaderEnv onEditHeaderValue the header edits; the
 *   value is the one secret this page ever holds, and it is never read back.
 * @param onDeleteServer 删除并撤销授权与密钥; `null` (or a new server, which
 *   [MCPEditorScreenState.canDelete] already hides) means the page offers no
 *   delete, because a delete that cannot reach the host would be a false verb.
 */
@Composable
public fun MCPEditorPage(
    state: MCPEditorScreenState,
    onEditName: (String) -> Unit,
    onEditCommand: (String) -> Unit,
    onEditUrl: (String) -> Unit,
    onSelectTransport: (MCPTransport) -> Unit,
    onToggleEnabled: (Boolean) -> Unit,
    onSubmit: (MCPServerDraft) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onEditTimeout: (String) -> Unit = {},
    onAddHeader: () -> Unit = {},
    onRemoveHeader: (Int) -> Unit = {},
    onEditHeaderName: (Int, String) -> Unit = { _, _ -> },
    onEditHeaderEnv: (Int, String) -> Unit = { _, _ -> },
    onEditHeaderValue: (Int, String) -> Unit = { _, _ -> },
    onDeleteServer: (() -> Unit)? = null,
) {
    PageFrame(
        title = state.title,
        onBack = onBack,
        rootTag = UiPageTags.MCP_EDITOR_ROOT,
        modifier = modifier,
    ) {
        if (state.isUnknown) {
            EmptyHint(
                title = UiStrings.MCP_EDITOR_UNKNOWN_STATE,
                hint = UiStrings.MCP_EDITOR_UNKNOWN_HINT,
                tag = UiPageTags.MCP_EDITOR_UNKNOWN,
            )
            return@PageFrame
        }
        Column(modifier = Modifier.fillMaxSize()) {
            if (state.failure != null) {
                // The baseline's error block (`MCPSettingsPage.swift:233`) carries
                // the reason only: the save row below is the retry, so the page
                // does not grow a second verb for one command.
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.MCP_EDITOR_FAILURE,
                )
            }
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    // The form's fields are rows of this list (名称 / 命令 / URL /
                    // 认证头 …); the IME shrinks the viewport so the focused row
                    // can be brought clear of the keyboard (spec §5 row `insets`).
                    .imePadding()
                    .testTag(UiPageTags.MCP_EDITOR_LIST),
                verticalArrangement = Arrangement.spacedBy(pageListGap),
            ) {
                // 服务器 (`MCPSettingsPage.swift:188`).
                item(key = "server.label") {
                    SessionSectionLabel(
                        text = UiStrings.MCP_SECTION_SERVER,
                        modifier = Modifier.testTag(UiPageTags.MCP_EDITOR_SERVER_SECTION),
                    )
                }
                item(key = "transport.stdio") {
                    InfoRow(
                        title = UiStrings.MCP_TRANSPORT_STDIO,
                        subtitle = UiStrings.MCP_TRANSPORT_STDIO_HINT,
                        value = if (state.draft.transport == MCPTransport.STDIO) {
                            UiStrings.SELECTED
                        } else {
                            null
                        },
                        tone = PageTone.ON,
                        modifier = Modifier.testTag(UiPageTags.MCP_EDITOR_TRANSPORT_STDIO),
                        onClick = { onSelectTransport(MCPTransport.STDIO) },
                    )
                }
                item(key = "transport.http") {
                    InfoRow(
                        title = UiStrings.MCP_TRANSPORT_HTTP,
                        subtitle = UiStrings.MCP_TRANSPORT_HTTP_HINT,
                        value = if (state.draft.transport == MCPTransport.HTTP) {
                            UiStrings.SELECTED
                        } else {
                            null
                        },
                        tone = PageTone.ON,
                        modifier = Modifier.testTag(UiPageTags.MCP_EDITOR_TRANSPORT_HTTP),
                        onClick = { onSelectTransport(MCPTransport.HTTP) },
                    )
                }
                item(key = "field.name") {
                    FieldBlock(
                        label = UiStrings.MCP_FIELD_NAME,
                        value = state.draft.name,
                        onValueChange = onEditName,
                        placeholder = UiStrings.MCP_FIELD_NAME_PLACEHOLDER,
                        hint = UiStrings.MCP_FIELD_NAME_HINT,
                        storedLabel = null,
                        error = state.errorFor(MCPField.NAME),
                        tag = UiPageTags.MCP_EDITOR_NAME,
                        errorTag = UiPageTags.MCP_EDITOR_NAME_ERROR,
                    )
                }
                if (state.draft.transport == MCPTransport.STDIO) {
                    item(key = "field.command") {
                        FieldBlock(
                            label = UiStrings.MCP_FIELD_COMMAND,
                            value = state.draft.command,
                            onValueChange = onEditCommand,
                            placeholder = UiStrings.MCP_FIELD_COMMAND_PLACEHOLDER,
                            hint = UiStrings.MCP_FIELD_COMMAND_HINT,
                            storedLabel = state.commandStoredLabel,
                            error = state.errorFor(MCPField.COMMAND),
                            tag = UiPageTags.MCP_EDITOR_COMMAND,
                            errorTag = UiPageTags.MCP_EDITOR_COMMAND_ERROR,
                        )
                    }
                } else {
                    item(key = "field.url") {
                        FieldBlock(
                            label = UiStrings.MCP_FIELD_URL,
                            value = state.draft.url,
                            onValueChange = onEditUrl,
                            placeholder = UiStrings.MCP_FIELD_URL_PLACEHOLDER,
                            hint = UiStrings.MCP_FIELD_URL_HINT,
                            storedLabel = state.urlStoredLabel,
                            error = state.errorFor(MCPField.URL),
                            tag = UiPageTags.MCP_EDITOR_URL,
                            errorTag = UiPageTags.MCP_EDITOR_URL_ERROR,
                            keyboardType = KeyboardType.Uri,
                        )
                    }
                }
                // 启用 (`MCPSettingsPage.swift:198`): a labelled toggle, and the whole
                // row is the tap target.
                item(key = "enabled") {
                    McpToggleRow(
                        label = UiStrings.MCP_FIELD_ENABLED,
                        value = if (state.draft.enabled) {
                            UiStrings.MCP_ENABLED_ON
                        } else {
                            UiStrings.MCP_ENABLED_OFF
                        },
                        checked = state.draft.enabled,
                        enabled = state.canSubmit,
                        onToggle = onToggleEnabled,
                        tag = UiPageTags.MCP_EDITOR_ENABLED,
                    )
                }
                // 工具调用超时 (`:199`): blank is the host's default, not a zero.
                item(key = "field.timeout") {
                    FieldBlock(
                        label = UiStrings.MCP_FIELD_TIMEOUT,
                        value = state.draft.toolCallTimeoutMs,
                        onValueChange = onEditTimeout,
                        placeholder = UiStrings.MCP_FIELD_TIMEOUT_PLACEHOLDER,
                        hint = UiStrings.MCP_FIELD_TIMEOUT_HINT,
                        storedLabel = null,
                        error = null,
                        tag = UiPageTags.MCP_EDITOR_TIMEOUT,
                        errorTag = UiPageTags.MCP_EDITOR_TIMEOUT + ".error",
                        keyboardType = KeyboardType.Number,
                    )
                }
                // 认证头与设备密钥 (`:203`).
                item(key = "auth.label") {
                    SessionSectionLabel(
                        text = UiStrings.MCP_SECTION_AUTH,
                        modifier = Modifier.testTag(UiPageTags.MCP_EDITOR_AUTH_SECTION),
                    )
                }
                if (state.headers.isEmpty()) {
                    item(key = "auth.empty") {
                        SettingsSubPageFootnote(text = UiStrings.MCP_AUTH_FOOTER)
                    }
                }
                items(
                    count = state.headers.size,
                    key = { index -> "auth.row.$index" },
                ) { index ->
                    McpHeaderRow(
                        index = index,
                        row = state.headers[index],
                        onEditName = onEditHeaderName,
                        onEditEnv = onEditHeaderEnv,
                        onEditValue = onEditHeaderValue,
                        onRemove = onRemoveHeader,
                    )
                }
                item(key = "auth.add") {
                    SessionTextAction(
                        label = UiStrings.MCP_ACTION_ADD_HEADER,
                        onClick = onAddHeader,
                        tone = SessionActionTone.ACCENT,
                        modifier = Modifier.testTag(UiPageTags.MCP_EDITOR_ADD_HEADER),
                    )
                }
                if (state.headers.isNotEmpty()) {
                    item(key = "auth.footer") {
                        SettingsSubPageFootnote(text = UiStrings.MCP_AUTH_FOOTER)
                    }
                }
                if (state.submitted && state.errors.isNotEmpty()) {
                    item(key = "errors.summary") {
                        // A local `tokens` binding rather than four `LocalUiTokens.current`
                        // reads: the page's declared inventory must be what the source
                        // visibly reads (`PageTokenReferenceTest`), and a token reached
                        // through the local composition is exactly that.
                        val tokens = LocalUiTokens.current
                        BasicText(
                            text = UiStrings.MCP_EDITOR_ERRORS.format(state.errors.size),
                            style = LocalUiType.current.caption.copy(color = tokens.colors.warning),
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(UiPageTags.MCP_EDITOR_ERRORS)
                                .padding(
                                    horizontal = tokens.geometry.pageOuterMarginH,
                                    vertical = tokens.spacing.badgeInsetV,
                                ),
                        )
                    }
                }
                if (!state.canPersist) {
                    item(key = "save.handoff") {
                        SettingsSubPageFootnote(text = UiStrings.MCP_EDITOR_HANDOFF_HINT)
                    }
                }
                // The untitled save/delete block (`:238`): save first, then the
                // destructive verb, exactly as the baseline orders them.
                item(key = "save") {
                    if (state.isNew) SessionTextAction(
                        label = UiStrings.MCP_SAVE_CONNECT,
                        onClick = { onSubmit(state.draft) },
                        tone = SessionActionTone.ACCENT,
                        enabled = state.canSubmit,
                        modifier = Modifier.testTag(UiPageTags.MCP_EDITOR_SAVE),
                        description = UiStrings.MCP_SAVE_CONNECT,
                    ) else SessionTextAction(
                        label = UiStrings.MCP_SAVE_RECONNECT,
                        onClick = { onSubmit(state.draft) },
                        tone = SessionActionTone.ACCENT,
                        enabled = state.canSubmit,
                        modifier = Modifier.testTag(UiPageTags.MCP_EDITOR_SAVE),
                        description = UiStrings.MCP_SAVE_RECONNECT,
                    )
                }
                if (state.canDelete) {
                    item(key = "delete") {
                        // A clickable `BasicText`, not a `SessionTextAction`: this row
                        // is the untitled group's criterion (`MCPSettingsPage.swift:260`,
                        // kind `first-clickable-row`), and the gate reads a row's label
                        // from a text call site — a shared action renders its label in
                        // its own file. Same ink and same tap target as every other
                        // page action.
                        val tokens = LocalUiTokens.current
                        BasicText(
                            text = UiStrings.MCP_ACTION_DELETE_SERVER,
                            style = LocalUiType.current.body.copy(
                                color = if (onDeleteServer != null) {
                                    tokens.colors.danger
                                } else {
                                    tokens.colors.tertiary
                                },
                            ),
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = tokens.geometry.pageRowMinHeight)
                                .testTag(UiPageTags.MCP_EDITOR_DELETE)
                                .clickable(enabled = onDeleteServer != null) {
                                    onDeleteServer?.invoke()
                                }
                                .semantics {
                                    contentDescription = UiStrings.MCP_ACTION_DELETE_SERVER
                                }
                                .padding(
                                    horizontal = tokens.geometry.pageOuterMarginH,
                                    vertical = tokens.spacing.badgeInsetV,
                                ),
                        )
                    }
                    item(key = "delete.hint") {
                        SettingsSubPageFootnote(text = UiStrings.MCP_DELETE_HINT)
                    }
                }
            }
        }
    }
}

/**
 * One labelled on/off row: the label is visible text and the row is the tap
 * target, so the baseline's 启用 row is a row with a verb rather than a bare
 * switch whose label lives somewhere else.
 *
 * The state is announced (`Role.Switch`, the value as the description) because a
 * row that is only a colour change is invisible to a screen reader.
 */
@Composable
private fun McpToggleRow(
    label: String,
    value: String,
    checked: Boolean,
    enabled: Boolean,
    onToggle: (Boolean) -> Unit,
    tag: String,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            // Page-level geometry: an editor row.
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .testTag(tag)
            .clickable(enabled = enabled) { onToggle(!checked) }
            .semantics {
                role = Role.Switch
                contentDescription = "$label $value"
            }
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(
            text = label,
            style = type.body.copy(
                color = if (enabled) tokens.colors.primary else tokens.colors.tertiary,
            ),
        )
        BasicText(
            text = value,
            style = type.caption.copy(
                color = when {
                    !enabled -> tokens.colors.tertiary
                    checked -> tokens.colors.success
                    else -> tokens.colors.tertiary
                },
            ),
        )
    }
}

/**
 * One auth-header row: name, the environment variable it is stored under, the
 * value field (a fresh secret, never the stored one) and its own remove verb.
 *
 * @param row the row's projected content ([MCPHeaderRowView]); [row.value] is
 *   the only secret the page holds and it is never printed outside the field.
 * @param onRemove called with [index]. The remove affordance is a glyph on a
 *   `BasicText` row: the baseline deletes with a swipe (`:220` `onDelete`), and a
 *   phone row needs a visible target. A glyph is not a word, so it does not
 *   compete with the page's named verbs.
 */
@Composable
private fun McpHeaderRow(
    index: Int,
    row: MCPHeaderRowView,
    onEditName: (Int, String) -> Unit,
    onEditEnv: (Int, String) -> Unit,
    onEditValue: (Int, String) -> Unit,
    onRemove: (Int) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val tagPrefix = UiPageTags.MCP_EDITOR_HEADER_PREFIX + index
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = MCP_REMOVE_GLYPH,
                style = type.secondary.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .heightIn(min = tokens.geometry.pageRowMinHeight)
                    .testTag(tagPrefix + UiPageTags.MCP_EDITOR_HEADER_REMOVE_SUFFIX)
                    .clickable(role = Role.Button) { onRemove(index) }
                    .semantics { contentDescription = UiStrings.MCP_REMOVE_HEADER }
                    .padding(
                        horizontal = tokens.geometry.pageOuterMarginH,
                        vertical = tokens.spacing.badgeInsetV,
                    ),
            )
        }
        FieldBlock(
            label = UiStrings.MCP_FIELD_HEADER_NAME,
            value = row.name,
            onValueChange = { onEditName(index, it) },
            placeholder = UiStrings.MCP_FIELD_HEADER_NAME,
            storedLabel = null,
            error = null,
            tag = tagPrefix + UiPageTags.MCP_EDITOR_HEADER_NAME_SUFFIX,
            errorTag = tagPrefix + UiPageTags.MCP_EDITOR_HEADER_NAME_SUFFIX + ".error",
        )
        FieldBlock(
            label = UiStrings.MCP_FIELD_HEADER_ENV,
            value = row.envName,
            onValueChange = { onEditEnv(index, it) },
            placeholder = UiStrings.MCP_FIELD_HEADER_ENV,
            storedLabel = null,
            error = null,
            tag = tagPrefix + UiPageTags.MCP_EDITOR_HEADER_ENV_SUFFIX,
            errorTag = tagPrefix + UiPageTags.MCP_EDITOR_HEADER_ENV_SUFFIX + ".error",
        )
        FieldBlock(
            label = UiStrings.MCP_FIELD_HEADER_VALUE,
            value = row.value,
            onValueChange = { onEditValue(index, it) },
            placeholder = row.valuePlaceholder,
            hint = UiStrings.MCP_FIELD_HEADER_HINT,
            storedLabel = null,
            error = null,
            tag = tagPrefix + UiPageTags.MCP_EDITOR_HEADER_VALUE_SUFFIX,
            errorTag = tagPrefix + UiPageTags.MCP_EDITOR_HEADER_VALUE_SUFFIX + ".error",
            keyboardType = KeyboardType.Password,
            secure = true,
        )
    }
}

/**
 * One labelled editor field: label, input, stored-value note, hint and the
 * in-place error.
 *
 * [secure] marks a value that must never be drawn or announced in plaintext: it
 * applies the shared secret-input transformation and password semantics. Only
 * the auth-header value uses it; every other field stays readable.
 *
 * The error is a sibling of the field, not a toast: the reason must stay on
 * screen while the user fixes the value.
 */
@Composable
private fun FieldBlock(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    tag: String,
    errorTag: String,
    storedLabel: String?,
    error: String?,
    hint: String? = null,
    keyboardType: KeyboardType = KeyboardType.Text,
    secure: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = label,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = type.body.copy(color = tokens.colors.primary),
            cursorBrush = SolidColor(tokens.colors.accent),
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = ImeAction.Done),
            visualTransformation = if (secure) {
                SecretVisualTransformation
            } else {
                VisualTransformation.None
            },
            modifier = Modifier
                .fillMaxWidth()
                // Page-level geometry: an editor field is a page row.
                .heightIn(min = tokens.geometry.pageRowMinHeight)
                .testTag(tag)
                .then(if (secure) Modifier.secretInputSemantics() else Modifier)
                .semantics { contentDescription = label },
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty()) {
                        BasicText(
                            text = placeholder,
                            style = type.body.copy(color = tokens.colors.tertiary),
                        )
                    }
                    inner()
                }
            },
        )
        if (storedLabel != null) {
            BasicText(
                text = storedLabel,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
        }
        if (hint != null) {
            BasicText(
                text = hint,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
        if (error != null) {
            BasicText(
                text = error,
                style = type.caption.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(errorTag),
            )
        }
    }
}

/** A name is a registry key, not free text: the same grammar the host enforces. */
private val MCP_NAME_PATTERN: Regex = Regex("""^[A-Za-z0-9_-]+$""")

/**
 * The remove glyph a header row carries.
 *
 * A page-local constant rather than the shared `SETTINGS_CLOSE_GLYPH`: the gate
 * resolves a label only when the source itself carries the string, and a glyph is
 * what the row shows either way. Same glyph, same meaning as the frame's ✕.
 */
private const val MCP_REMOVE_GLYPH: String = "✕"

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest`'s page map is owned by the session-pages lane; this
 * declaration is the entry that table adds for this file. The equality there is
 * "declared == what the source reads", so the typography roles this file names
 * are part of the list together with the value tokens.
 */
internal object MCPEditorPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
    )
}
