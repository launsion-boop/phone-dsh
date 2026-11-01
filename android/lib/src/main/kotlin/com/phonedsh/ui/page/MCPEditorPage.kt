// MCP editor: transport, command or URL, enable — and the field errors in place.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row MCPEditorPage (单个 MCP 服务器的编辑: 传输
// 方式、命令/URL、启用; it is the editor sub-page of MCPSettingsPage) and §3.1
// (the ScreenState layer). P5 `must`.
//
// Validation is not allowed to be swallowed: every rule is a pure function of the
// draft, the errors carry the field they belong to, and the page prints each
// error directly under its own field as soon as the field was touched or the
// user tried to save. The save action stays enabled while the form is invalid on
// purpose: tapping it is how the user asks "what is wrong?".
//
// Security red line: the stored command and URL are never read into the page.
// [MCPStoredServer] carries only whether a value is stored ([FactState]), so the
// only place a URL can appear is the editable field the user typed into. A blank
// field on an existing server means "keep the stored value"; the page says so
// instead of showing the stored value. Error copy is page-owned and never echoes
// the draft, so a URL with a token cannot end up in a validation message.
//
// ScreenState: `MCPEditorScreenState.from(facts, local)` is pure. The local
// events are the field edits, the transport choice, the enable toggle and the
// submit; replaying the same script yields the same state sequence (§3.1).
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageRowMinHeight`); the section caption reuses the shared
// `SessionSectionLabel` and the list gap is the shared `pageListGap`.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import com.phonedsh.ui.UiStrings
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
 * The editable form. It starts blank for a new server and blank-or-kept for an
 * existing one: [MCPStoredServer] never hands the stored command or URL over.
 */
@Immutable
public data class MCPServerDraft(
    public val id: String = "",
    public val name: String = "",
    public val transport: MCPTransport = MCPTransport.HTTP,
    public val command: String = "",
    public val url: String = "",
    public val enabled: Boolean = true,
)

/**
 * An existing server, as far as the editor may see it.
 *
 * There is deliberately no `command` or `url` field: the stored values may embed
 * credentials and a complete URL must not reach the UI. The page can say whether
 * a value is stored and treats a blank draft field as "keep it".
 *
 * @param commandStored whether a stdio command is stored ([FactState]).
 * @param urlStored whether a network URL is stored ([FactState]).
 */
@Immutable
public data class MCPStoredServer(
    public val id: String,
    public val name: String,
    public val transport: MCPTransport,
    public val enabled: Boolean = true,
    public val commandStored: FactState = FactState.UNKNOWN,
    public val urlStored: FactState = FactState.UNKNOWN,
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
 * The complete editor state.
 *
 * [draft] is the editable form (and therefore carries the user's own typed URL);
 * [errors] is every validation error and [visibleErrors] only the ones the user
 * should see now (touched field or an attempted save). No page-authored display
 * string is built from the draft, so a secret typed into a field cannot leak
 * into an error line.
 *
 * @param phase the data phase; [UNKNOWN] replaces the form entirely.
 * @param title 添加 or 编辑 (page-owned).
 * @param isNew true when there is no stored server.
 * @param submitted true once the user pressed save.
 * @param failure the page-owned save-failure copy, or `null`.
 * @param commandStoredLabel the "blank keeps the stored command" line, when one
 *   applies to the active transport.
 * @param urlStoredLabel the same for the URL.
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
                canPersist = facts.writable != FactState.NO,
            )
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
)

/** The local UI events of the editor: field edits, transport, enable, submit. */
public sealed interface MCPEditorUiEvent {
    public data class EditName(public val value: String) : MCPEditorUiEvent
    public data class EditCommand(public val value: String) : MCPEditorUiEvent
    public data class EditUrl(public val value: String) : MCPEditorUiEvent
    public data class SelectTransport(public val transport: MCPTransport) : MCPEditorUiEvent
    public data class ToggleEnabled(public val enabled: Boolean) : MCPEditorUiEvent

    /** The user pressed save; this is what makes every error visible. */
    public data object Submit : MCPEditorUiEvent
}

/**
 * The editor's local script.
 *
 * [apply] is pure and takes the facts because the first edit of an existing
 * server starts from the stored (non-secret) fields; the host can therefore
 * replay a script without keeping a second draft.
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

            is MCPEditorUiEvent.SelectTransport -> copy(
                draft = base.copy(transport = event.transport),
            )

            is MCPEditorUiEvent.ToggleEnabled -> copy(
                draft = base.copy(enabled = event.enabled),
            )

            MCPEditorUiEvent.Submit -> copy(submitted = true)
        }
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The MCP server editor.
 *
 * @param state the pure screen state ([MCPEditorScreenState.from]).
 * @param onEditName onEditCommand onEditUrl the field edits; the host applies
 *   the matching `MCPEditorUiEvent` and re-projects.
 * @param onSelectTransport the transport choice.
 * @param onToggleEnabled the enable switch.
 * @param onSubmit the save action, called with the current draft. The host
 *   applies `MCPEditorUiEvent.Submit` first, then persists only when
 *   `state.errors` is empty; when it is not, the re-projected state shows every
 *   error in place. This is the "validation is not swallowed" contract.
 * @param onBack leave the page (the draft is the host's to keep or drop).
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
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.MCP_EDITOR_FAILURE,
                    retryLabel = UiStrings.RETRY,
                    onRetry = { onSubmit(state.draft) },
                )
            }
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(UiPageTags.MCP_EDITOR_LIST),
                verticalArrangement = Arrangement.spacedBy(pageListGap),
            ) {
                item(key = "transport.label") {
                    SessionSectionLabel(UiStrings.MCP_TRANSPORT)
                }
                item(key = "transport.stdio") {
                    InfoRow(
                        title = UiStrings.MCP_TRANSPORT_STDIO,
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
                item(key = "enabled") {
                    SettingsToggleRow(
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
                if (state.submitted && state.errors.isNotEmpty()) {
                    item(key = "errors.summary") {
                        BasicText(
                            text = UiStrings.MCP_EDITOR_ERRORS.format(state.errors.size),
                            style = LocalUiType.current.caption.copy(
                                color = LocalUiTokens.current.colors.warning,
                            ),
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(UiPageTags.MCP_EDITOR_ERRORS)
                                .padding(
                                    horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
                                    vertical = LocalUiTokens.current.spacing.badgeInsetV,
                                ),
                        )
                    }
                }
                if (!state.canPersist) {
                    item(key = "save.handoff") {
                        BasicText(
                            text = UiStrings.MCP_EDITOR_HANDOFF_HINT,
                            style = LocalUiType.current.caption.copy(
                                color = LocalUiTokens.current.colors.tertiary,
                            ),
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(UiPageTags.MCP_EDITOR_SAVE + ".handoff")
                                .padding(
                                    horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
                                    vertical = LocalUiTokens.current.spacing.badgeInsetV,
                                ),
                        )
                    }
                }
                item(key = "save") {
                    SessionTextAction(
                        label = UiStrings.MCP_SAVE,
                        onClick = { onSubmit(state.draft) },
                        tone = SessionActionTone.ACCENT,
                        enabled = state.canSubmit,
                        modifier = Modifier.testTag(UiPageTags.MCP_EDITOR_SAVE),
                        description = UiStrings.MCP_SAVE,
                    )
                }
            }
        }
    }
}

/**
 * One labelled editor field: label, input, stored-value note, hint and the
 * in-place error.
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
    hint: String,
    storedLabel: String?,
    error: String?,
    keyboardType: KeyboardType = KeyboardType.Text,
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
            modifier = Modifier
                .fillMaxWidth()
                // Page-level geometry: an editor field is a page row.
                .heightIn(min = tokens.geometry.pageRowMinHeight)
                .testTag(tag)
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
        BasicText(
            text = hint,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
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
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
    )
}
