// Web search: which search the page follows, the address, the key, and when a change applies.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row WebSearchSettingsPage (网页搜索) and §3.1
// (the ScreenState layer). P5 `must`. Structure: the contract
// `spec/ui/v1/pages/web-search-settings.json`, regenerated from the iOS HEAD
// `86a39aac` (PR #13): 用哪一份搜索 / 地址 / 密钥状态 / the untitled delete group /
// 什么时候生效 / 需要处理 / 还要知道.
//
// The page is deliberately honest about what it knows:
//   * the mode comes from a fact, so 未知 is its own state, never "follow the
//     model";
//   * the address and the key are *drafts*: the page never reads a stored key or
//     a complete URL into its state, and it commits an address only when the user
//     says so (回车 / 保存 / 离开). A red line under the field is page-owned copy,
//     so a host error string cannot put a URL or a key on screen;
//   * the 保存 button is the page's own button composable: the contract models
//     that button without a label (`action-215`), so its visible text is copy,
//     not a contract action label.
//
// ScreenState: `WebSearchScreenState.from(facts, local)` is pure. The only local
// event is the 还要知道 fold; the mode, the commit and the engine are host
// actions that come back as new facts.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageRowMinHeight`); the list gap is the shared `pageListGap`.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.VisualTransformation
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.surface.SecretVisualTransformation
import com.phonedsh.ui.surface.SettingsBodyRow
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsFormRow
import com.phonedsh.ui.surface.SettingsSectionHeader
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.secretInputSemantics
import com.phonedsh.ui.surface.settingsFootnoteStyle
import com.phonedsh.ui.surface.settingsLabelStyle
import com.phonedsh.ui.surface.settingsValueStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.materialDialogColors
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/** Which search the local engine uses. The baseline's two-option group. */
public enum class WebSearchMode {
    /** Use whatever search the selected model service carries. */
    FOLLOW_MODEL,

    /** A search service configured on this page, with its own address and key. */
    SEARCH_API,
}

/** Why the page could not read the search configuration; wording is page-owned. */
public enum class WebSearchFailureReason {
    /** The web-search document could not be read. */
    CONFIG_UNREADABLE,

    /** The stored credential could not be read. */
    KEY_UNREADABLE,

    /** The host reported a failure without a category the page can name. */
    UNKNOWN,
}

/**
 * The page's read-only input.
 *
 * @param mode which search the host says the engine uses.
 * @param hasCredential whether a search-service key is stored. `UNKNOWN` is not
 *   "no": the page says 未知 rather than claiming the key is missing.
 * @param keyTail the trailing characters of the stored key, if the host offers
 *   them. Never the key itself — the page shows at most these four characters.
 * @param engineStarted whether the local engine runs, i.e. whether a committed
 *   change is already in effect.
 * @param launchWarning the sentence the engine reported about the search
 *   launcher, or `null`. Its section only renders when there is something to
 *   handle.
 * @param modelSearchSupported whether the selected model service carries search
 *   (`FOLLOW_MODEL`'s support line).
 * @param noModelProfile true when no model service is configured at all.
 * @param writable `NO` disables the controls and prints
 *   [UiStrings.HOST_READ_ONLY_HINT]; `UNKNOWN` is not `NO`.
 * @param readOnlyReason the host's own sentence for why this page cannot be
 *   written, or `null` when it offers no reason. It is the host's copy, not the
 *   page's: only the host knows which command is missing, and a generic
 *   "只读" would hide the difference between "this device must not" and "this
 *   build cannot". It renders only when [writable] is `NO`, so a writable host
 *   can never leave a stale reason on screen.
 */
@Immutable
public data class WebSearchFacts(
    public val mode: WebSearchMode = WebSearchMode.FOLLOW_MODEL,
    public val hasCredential: FactState = FactState.UNKNOWN,
    public val keyTail: String? = null,
    public val engineStarted: FactState = FactState.UNKNOWN,
    public val launchWarning: String? = null,
    public val modelSearchSupported: FactState = FactState.UNKNOWN,
    public val noModelProfile: Boolean = false,
    public val failure: WebSearchFailureReason? = null,
    public val writable: FactState = FactState.UNKNOWN,
    public val readOnlyReason: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/**
 * The complete web-search screen state.
 *
 * @param phase the data phase; a failed read keeps its red line above the list.
 * @param mode which search the page follows.
 * @param followHint the support line under the mode group (only meaningful for
 *   [WebSearchMode.FOLLOW_MODEL]).
 * @param keyStatusLabel 存好了 / 还没存 / 未知.
 * @param keyTailLabel 尾号 xxxx, or `null` when the host offers no tail.
 * @param restartHint the 什么时候生效 sentence, chosen from [engineStarted].
 * @param notesExpanded whether the 还要知道 group is open.
 * @param canWrite false when the host reported the page is not writable.
 * @param readOnlyReason the host's sentence for why this page cannot be written;
 *   `null` when it reported none. Rendered only while [canWrite] is false.
 * @param failure the page-owned failure copy, or `null`.
 */
@Immutable
public data class WebSearchScreenState(
    public val phase: SettingsDataPhase,
    public val mode: WebSearchMode,
    public val followHint: String,
    public val keyStatusLabel: String,
    public val credential: FactState,
    public val keyTailLabel: String?,
    public val restartHint: String,
    public val engineStarted: FactState,
    public val launchWarning: String?,
    public val notesExpanded: Boolean = true,
    public val canWrite: Boolean = true,
    public val readOnlyReason: String? = null,
    public val failure: String? = null,
) {
    /** The last read failed; [failure] explains it. */
    public val isFailed: Boolean get() = phase == SettingsDataPhase.FAILED

    /** The address + key + delete groups only exist for the page's own service. */
    public val isSearchApi: Boolean get() = mode == WebSearchMode.SEARCH_API

    /** The stop action is offered only when the host said the engine runs. */
    public val canStopEngine: Boolean get() = engineStarted == FactState.YES

    /** Otherwise the start action is offered; `UNKNOWN` keeps it rather than hiding it. */
    public val canStartEngine: Boolean get() = engineStarted != FactState.YES

    /** The key is stored: 清除密钥 exists only then. */
    public val hasCredential: Boolean get() = credential == FactState.YES

    public companion object {
        /** Fold id of the 还要知道 group. */
        public const val NOTES_SECTION_ID: String = "websearch.notes"

        /**
         * Projects (facts, fold script) into the screen state.
         *
         * Pure: no clock, no I/O, no engine. The same facts and the same script
         * always yield the same state sequence (§3.1).
         */
        public fun from(
            facts: WebSearchFacts,
            local: WebSearchLocalState = WebSearchLocalState(),
        ): WebSearchScreenState {
            val phase = when {
                facts.failure != null -> SettingsDataPhase.FAILED
                else -> SettingsDataPhase.READY
            }
            return WebSearchScreenState(
                phase = phase,
                mode = facts.mode,
                followHint = facts.followHint(),
                keyStatusLabel = when (facts.hasCredential) {
                    FactState.YES -> UiStrings.WEB_SEARCH_KEY_STORED
                    FactState.NO -> UiStrings.WEB_SEARCH_KEY_NOT_STORED
                    FactState.UNKNOWN -> UiStrings.UNKNOWN
                },
                credential = facts.hasCredential,
                keyTailLabel = facts.keyTail?.trim()?.takeIf { it.isNotEmpty() }
                    ?.takeLast(KEY_TAIL_LENGTH)
                    ?.let { UiStrings.WEB_SEARCH_KEY_TAIL.format(it) },
                restartHint = if (facts.engineStarted == FactState.YES) {
                    UiStrings.WEB_SEARCH_RESTART_HINT_RUNNING
                } else {
                    UiStrings.WEB_SEARCH_RESTART_HINT_IDLE
                },
                engineStarted = facts.engineStarted,
                launchWarning = facts.launchWarning,
                notesExpanded = local.fold.isExpanded(NOTES_SECTION_ID),
                canWrite = facts.writable != FactState.NO,
                readOnlyReason = facts.readOnlyReason?.trim()?.takeIf { it.isNotEmpty() },
                failure = facts.failure?.text(),
            )
        }

        private fun WebSearchFacts.followHint(): String = when {
            noModelProfile -> UiStrings.WEB_SEARCH_FOLLOW_NO_PROFILE
            modelSearchSupported == FactState.YES -> UiStrings.WEB_SEARCH_FOLLOW_SUPPORTED
            modelSearchSupported == FactState.NO -> UiStrings.WEB_SEARCH_FOLLOW_UNSUPPORTED
            // 未知 is not 不带搜索: the support line says the page cannot tell.
            else -> UiStrings.WEB_SEARCH_FOLLOW_UNKNOWN
        }

        private fun WebSearchFailureReason.text(): String = when (this) {
            WebSearchFailureReason.CONFIG_UNREADABLE -> UiStrings.WEB_SEARCH_FAILURE_CONFIG
            WebSearchFailureReason.KEY_UNREADABLE -> UiStrings.WEB_SEARCH_FAILURE_KEY
            WebSearchFailureReason.UNKNOWN -> UiStrings.WEB_SEARCH_FAILURE_UNKNOWN
        }
    }
}

/** The local UI events of the web-search page: only the 还要知道 fold. */
public sealed interface WebSearchUiEvent {
    /**
     * Collapse or expand the 还要知道 group. The name predates the contract
     * refresh (the fold used to hide the backend list); the host already wires
     * this event, so it keeps its name.
     */
    public data object ToggleBackends : WebSearchUiEvent
}

/** The fold script; [apply] is pure, so a test drives it like a reducer. */
@Immutable
public data class WebSearchLocalState(public val fold: FoldState = FoldState()) {
    /** Applies one local event. */
    public fun apply(event: WebSearchUiEvent): WebSearchLocalState = when (event) {
        WebSearchUiEvent.ToggleBackends ->
            copy(fold = fold.toggle(WebSearchScreenState.NOTES_SECTION_ID))
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The web-search settings screen.
 *
 * @param state the pure screen state ([WebSearchScreenState.from]).
 * @param onToggle retained for the host's older switch wiring; this contract's
 *   page has no on/off switch (the mode group is the choice).
 * @param onSelectBackend retained for the host's older backend wiring; the
 *   contract's page commits an address instead (`onCommitAddress`).
 * @param onToggleBackends the 还要知道 fold; the host applies
 *   `WebSearchUiEvent.ToggleBackends` and re-projects.
 * @param onBack leave the page.
 * @param onRetry retry a failed read (the failure line's leading glyph; the
 *   contract declares no retry label for this page).
 * @param onModeChange the user picked which search to follow; `null` disables the
 *   mode group (the host declared it writable but handed no write).
 * @param onCommitAddress the user committed the address (回车 / 保存 / leaving).
 *   The page passes the trimmed text; it never reads a stored URL back.
 * @param onCommitKey the user pressed 保存 with a pasted key; the page passes the
 *   trimmed text, not the stored one.
 * @param onClearKey 清除密钥 was confirmed.
 * @param onRemoveConfiguration 删除这个搜索服务 was confirmed.
 * @param onStartEngine 启动本地引擎 was tapped.
 * @param onStopEngine 停止本地引擎 was tapped.
 */
@Composable
public fun WebSearchSettingsPage(
    state: WebSearchScreenState,
    onToggle: (Boolean) -> Unit,
    onSelectBackend: (String) -> Unit,
    onToggleBackends: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onModeChange: ((WebSearchMode) -> Unit)? = null,
    onCommitAddress: ((String) -> Unit)? = null,
    onCommitKey: ((String) -> Unit)? = null,
    onClearKey: (() -> Unit)? = null,
    onRemoveConfiguration: (() -> Unit)? = null,
    onStartEngine: () -> Unit = {},
    onStopEngine: () -> Unit = {},
) {
    // A write control is armed only when the host declared this page writable
    // **and** the caller handed the write for that control. The host's answer
    // alone is not enough: `PdshNavHost`'s WebSearchRoute never passes these five,
    // so a host that reported `writable = YES` would paint five enabled controls
    // whose taps land in a `{}` default — the exact fake the callback defaults used
    // to hide. With this gate the control is disabled instead, and the page's own
    // reason line (or the baseline's silence) is the visible answer.
    val tokens = LocalUiTokens.current
    val dialogPalette = materialDialogColors(tokens)
    val writable = state.canWrite
    val modeWritable = writable && onModeChange != null
    val addressWritable = writable && onCommitAddress != null
    val keyWritable = writable && onCommitKey != null
    val clearWritable = writable && onClearKey != null
    val removeWritable = writable && onRemoveConfiguration != null
    var address by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var feedback by remember { mutableStateOf<String?>(null) }
    var keyCommitPending by remember { mutableStateOf(false) }
    // `hasCredential` is level-triggered: an already-configured host reports YES
    // both before and after the save, so it cannot prove that *this* commit
    // landed. Remember the host facts at the moment 保存 was pressed and only
    // accept a change as the acknowledgement — no-key -> configured, or a new
    // key tail. Reading the pre-commit YES would drop a replacement the host
    // never stored.
    var keyCommitBaselineConfigured by remember { mutableStateOf(false) }
    var keyCommitBaselineTail by remember { mutableStateOf<String?>(null) }
    var pendingClearKey by remember { mutableStateOf(false) }
    var pendingRemove by remember { mutableStateOf(false) }

    // The key draft is dropped only after the host confirms it was stored. A
    // pasted credential the host never acknowledged must stay on screen: losing
    // it silently is worse than showing it. The address draft is not touched.
    LaunchedEffect(keyCommitPending, state.hasCredential, state.keyTailLabel, keyWritable) {
        if (keyCommitPending && keyWritable) {
            val acknowledged = state.hasCredential &&
                (!keyCommitBaselineConfigured || state.keyTailLabel != keyCommitBaselineTail)
            if (acknowledged) {
                apiKey = ""
                keyCommitPending = false
                feedback = null
            }
        }
    }

    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        largeTitle = UiStrings.WEB_SEARCH_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.WEB_SEARCH_ROOT,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            if (state.failure != null) {
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.WEB_SEARCH_FAILURE,
                    retryLabel = if (onRetry != null) RETRY_GLYPH else null,
                    onRetry = onRetry,
                )
            }
            LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        // The address/key fields are rows near the bottom of this
                        // list; the IME must shrink it so they can scroll clear of
                        // the keyboard (spec §5 row `insets`).
                        .imePadding()
                        .testTag(UiPageTags.WEB_SEARCH_LIST),
                    verticalArrangement = Arrangement.Top,
                ) {
                    modeGroup(
                        state = state,
                        enabled = modeWritable,
                        onModeChange = { onModeChange?.invoke(it) },
                    )
                    // The host's own reason, right under the controls it disabled:
                    // "why can this page not be written" is a host fact, and a
                    // bare 只读 would leave the person unable to tell a product
                    // limit from a missing command. It renders only while the
                    // controls are disabled, so a writable host never shows it.
                    if (!state.canWrite && state.readOnlyReason != null) {
                        item(key = "mode.readonly.reason") {
                            SettingsFootnoteRow(text = state.readOnlyReason)
                        }
                    }
                    if (state.isSearchApi) {
                        addressGroup(
                            address = address,
                            enabled = addressWritable,
                            feedback = feedback,
                            onAddressChange = {
                                address = it
                                feedback = null
                            },
                            onCommit = {
                                feedback = null
                                onCommitAddress?.invoke(address.trim())
                            },
                        )
                        keyGroup(
                            state = state,
                            enabled = keyWritable,
                            apiKey = apiKey,
                            feedback = feedback,
                            onKeyChange = {
                                apiKey = it
                                keyCommitPending = false
                                feedback = null
                            },
                            onCommit = {
                                feedback = null
                                keyCommitBaselineConfigured = state.hasCredential
                                keyCommitBaselineTail = state.keyTailLabel
                                keyCommitPending = true
                                onCommitKey?.invoke(apiKey.trim())
                            },
                            onClear = { if (clearWritable) pendingClearKey = true },
                        )
                        deleteGroup(
                            enabled = removeWritable,
                            onDelete = { if (removeWritable) pendingRemove = true },
                        )
                    }
                    applyGroup(state = state, onStart = onStartEngine, onStop = onStopEngine)
                    if (state.launchWarning != null) {
                        warningGroup(warning = state.launchWarning.orEmpty())
                    }
                notesGroup(
                    state = state,
                    onToggleBackends = onToggleBackends,
                )
            }
        }
        // The two confirmations are written out rather than shared: the contract
        // compares the alert's destructive label (清除 / 删除), and a shared helper
        // would pass it as a parameter, where it is a template instead of copy.
        if (pendingClearKey) {
            AlertDialog(
                onDismissRequest = { pendingClearKey = false },
                title = { Text(UiStrings.WEB_SEARCH_CLEAR_TITLE) },
                text = { Text(UiStrings.WEB_SEARCH_CLEAR_TEXT) },
                confirmButton = {
                    TextButton(
                        onClick = {
                            pendingClearKey = false
                            onClearKey?.invoke()
                        },
                    ) {
                        Text(UiStrings.WEB_SEARCH_CLEAR)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { pendingClearKey = false }) {
                        Text(UiStrings.CANCEL)
                    }
                },
                containerColor = dialogPalette.container,
                textContentColor = dialogPalette.content,
            )
        }
        if (pendingRemove) {
            AlertDialog(
                onDismissRequest = { pendingRemove = false },
                title = { Text(UiStrings.WEB_SEARCH_DELETE_TITLE) },
                text = { Text(UiStrings.WEB_SEARCH_DELETE_TEXT) },
                confirmButton = {
                    TextButton(
                        onClick = {
                            pendingRemove = false
                            onRemoveConfiguration?.invoke()
                        },
                    ) {
                        Text(UiStrings.WEB_SEARCH_DELETE)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { pendingRemove = false }) {
                        Text(UiStrings.CANCEL)
                    }
                },
                containerColor = dialogPalette.container,
                textContentColor = dialogPalette.content,
            )
        }
    }
}

/** 用哪一份搜索: the two modes, each with its own one-line explanation. */
private fun LazyListScope.modeGroup(
    state: WebSearchScreenState,
    enabled: Boolean,
    onModeChange: (WebSearchMode) -> Unit,
) {
    item(key = "mode.header") {
        SettingsSectionLabel(UiStrings.WEB_SEARCH_SECTION_MODE)
    }
    item(key = "mode.follow") {
        SettingsFormRow(
            title = UiStrings.WEB_SEARCH_MODE_FOLLOW,
            subtitle = UiStrings.WEB_SEARCH_MODE_FOLLOW_HINT,
            enabled = enabled,
            accentTitle = state.mode == WebSearchMode.FOLLOW_MODEL,
            trailing = if (state.mode == WebSearchMode.FOLLOW_MODEL) {
                { CheckmarkGlyph() }
            } else {
                null
            },
            onClick = if (enabled) {
                { onModeChange(WebSearchMode.FOLLOW_MODEL) }
            } else {
                null
            },
        )
    }
    item(key = "mode.api") {
        SettingsFormRow(
            title = UiStrings.WEB_SEARCH_MODE_API,
            subtitle = UiStrings.WEB_SEARCH_MODE_API_HINT,
            enabled = enabled,
            accentTitle = state.mode == WebSearchMode.SEARCH_API,
            trailing = if (state.mode == WebSearchMode.SEARCH_API) {
                { CheckmarkGlyph() }
            } else {
                null
            },
            onClick = if (enabled) {
                { onModeChange(WebSearchMode.SEARCH_API) }
            } else {
                null
            },
        )
    }
    if (state.mode == WebSearchMode.FOLLOW_MODEL) {
        item(key = "mode.follow.hint") {
            SettingsFootnoteRow(text = state.followHint)
        }
    }
}

/** 地址: the one text field whose commit the user controls. */
private fun LazyListScope.addressGroup(
    address: String,
    enabled: Boolean,
    feedback: String?,
    onAddressChange: (String) -> Unit,
    onCommit: () -> Unit,
) {
    item(key = "address.header") {
        SettingsSectionLabel(UiStrings.WEB_SEARCH_SECTION_ADDRESS)
    }
    item(key = "address.field") {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH),
        ) {
            WebSearchTextField(
                value = address,
                enabled = enabled,
                placeholder = UiStrings.WEB_SEARCH_ADDRESS_PLACEHOLDER,
                onValueChange = onAddressChange,
                onDone = onCommit,
                tag = UiPageTags.WEB_SEARCH_ADDRESS_FIELD,
            )
            feedback?.let { line -> WebSearchFeedbackLine(text = line) }
        }
    }
    item(key = "address.footer") {
        SettingsFootnoteRow(text = UiStrings.WEB_SEARCH_ADDRESS_FOOTER)
    }
}

/** 密钥状态: the stored-key state, the paste field, 保存 and 清除密钥. */
private fun LazyListScope.keyGroup(
    state: WebSearchScreenState,
    enabled: Boolean,
    apiKey: String,
    feedback: String?,
    onKeyChange: (String) -> Unit,
    onCommit: () -> Unit,
    onClear: () -> Unit,
) {
    item(key = "key.header") {
        SettingsSectionLabel(UiStrings.WEB_SEARCH_SECTION_KEY)
    }
    item(key = "key.state") {
        KeyStateRow(state = state)
    }
    item(key = "key.field") {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH),
        ) {
            WebSearchTextField(
                value = apiKey,
                enabled = enabled,
                placeholder = UiStrings.WEB_SEARCH_KEY_PLACEHOLDER,
                onValueChange = onKeyChange,
                tag = UiPageTags.WEB_SEARCH_KEY_FIELD,
                secure = true,
            )
            feedback?.let { line -> WebSearchFeedbackLine(text = line) }
        }
    }
    item(key = "key.commit") {
        WebSearchSaveKeyButton(
            text = UiStrings.WEB_SEARCH_SAVE_KEY,
            enabled = enabled && apiKey.isNotBlank(),
            onClick = onCommit,
        )
    }
    if (state.hasCredential) {
        item(key = "key.clear") {
            SessionTextAction(
                label = UiStrings.WEB_SEARCH_CLEAR_KEY,
                onClick = onClear,
                tone = SessionActionTone.ACCENT,
                enabled = enabled,
                modifier = Modifier.padding(
                    horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
                ),
            )
        }
    }
    item(key = "key.footer") {
        SettingsFootnoteRow(text = UiStrings.WEB_SEARCH_KEY_FOOTER)
    }
}

/** The contract's untitled group: the one destructive row, no header. */
private fun LazyListScope.deleteGroup(
    enabled: Boolean,
    onDelete: () -> Unit,
) {
    item(key = "delete.row") {
        WebSearchRowAction(
            label = UiStrings.WEB_SEARCH_DELETE_SERVICE,
            onClick = onDelete,
            enabled = enabled,
            danger = true,
        )
    }
    item(key = "delete.footer") {
        SettingsFootnoteRow(text = UiStrings.WEB_SEARCH_DELETE_FOOTER)
    }
}

/** 什么时候生效: the hint plus the one engine action that applies. */
private fun LazyListScope.applyGroup(
    state: WebSearchScreenState,
    onStart: () -> Unit,
    onStop: () -> Unit,
) {
    item(key = "apply.header") {
        SettingsSectionLabel(UiStrings.WEB_SEARCH_SECTION_APPLY)
    }
    item(key = "apply.hint") {
        SettingsFootnoteRow(text = state.restartHint)
    }
    if (state.canStopEngine) {
        item(key = "apply.stop") {
            SessionTextAction(
                label = UiStrings.WEB_SEARCH_STOP_ENGINE,
                onClick = onStop,
                tone = SessionActionTone.DANGER,
            )
        }
    }
    if (state.canStartEngine) {
        item(key = "apply.start") {
            SessionTextAction(
                label = UiStrings.WEB_SEARCH_START_ENGINE,
                onClick = onStart,
                tone = SessionActionTone.ACCENT,
            )
        }
    }
}

/** 需要处理: the launcher's warning, only when there is something to handle. */
private fun LazyListScope.warningGroup(warning: String) {
    item(key = "warning.header") {
        SettingsSectionLabel(UiStrings.WEB_SEARCH_SECTION_WARNING)
    }
    item(key = "warning.line") {
        SettingsFootnoteRow(text = warning)
    }
    item(key = "warning.tail") {
        SettingsFootnoteRow(text = UiStrings.WEB_SEARCH_WARNING_TAIL)
    }
}

/** 还要知道: the three sentences that are not an action. */
private fun LazyListScope.notesGroup(
    state: WebSearchScreenState,
    onToggleBackends: () -> Unit,
) {
    item(key = "notes.header") {
        SettingsSectionHeader(
            title = UiStrings.WEB_SEARCH_SECTION_NOTES,
            expanded = state.notesExpanded,
            onToggle = onToggleBackends,
        )
    }
    if (state.notesExpanded) {
        // The baseline renders these three as bare `Text` rows in a `List`
        // section, i.e. `.body` at 17 pt, not a `.footnote` footer:
        // `ios-settings-search.png` measures them at ink 16.7 pt with a 22.3 pt
        // line pitch. Every other line on this page is an explicit
        // `.font(.system(size: 13))` in `WebSearchSettingsPage.swift` (measured
        // ink 13.0 pt), which is why they stay footnotes.
        item(key = "notes.model") {
            SettingsBodyRow(text = UiStrings.WEB_SEARCH_NOTE_MODEL)
        }
        item(key = "notes.key") {
            SettingsBodyRow(text = UiStrings.WEB_SEARCH_NOTE_KEY)
        }
        item(key = "notes.restart") {
            SettingsBodyRow(text = UiStrings.WEB_SEARCH_NOTE_RESTART)
        }
    }
}

/** 密钥 / 存好了 / 尾号 xxxx. */
@Composable
private fun KeyStateRow(state: WebSearchScreenState) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.WEB_SEARCH_KEY_LABEL,
            style = settingsLabelStyle().copy(color = tokens.colors.primary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = state.keyStatusLabel,
            style = settingsFootnoteStyle().copy(color = tokens.colors.secondary),
        )
        state.keyTailLabel?.let { tail ->
            BasicText(
                text = tail,
                style = settingsFootnoteStyle().copy(color = tokens.colors.secondary),
            )
        }
    }
}

/**
 * One text field of the page: the placeholder is copy, the value is a draft.
 *
 * [secure] marks a credential draft that must never be drawn or announced in
 * plaintext; it applies the shared secret-input transformation and password
 * semantics. The address field stays readable.
 *
 * A `BasicTextField` is not one of the gate's action idioms unless it declares a
 * search IME action, which this field does not; the field is an input, not a
 * button.
 */
@Composable
private fun WebSearchTextField(
    value: String,
    enabled: Boolean,
    placeholder: String,
    onValueChange: (String) -> Unit,
    tag: String,
    onDone: (() -> Unit)? = null,
    secure: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        enabled = enabled,
        singleLine = true,
        keyboardOptions = KeyboardOptions(
            keyboardType = if (secure) KeyboardType.Password else KeyboardType.Text,
            imeAction = ImeAction.Done,
        ),
        keyboardActions = KeyboardActions(onDone = { onDone?.invoke() }),
        visualTransformation = if (secure) {
            SecretVisualTransformation
        } else {
            VisualTransformation.None
        },
        textStyle = settingsValueStyle().copy(
            color = if (enabled) tokens.colors.primary else tokens.colors.tertiary,
        ),
        cursorBrush = SolidColor(tokens.colors.accent),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .then(if (secure) Modifier.secretInputSemantics() else Modifier)
            .heightIn(min = tokens.geometry.pageRowMinHeight),
        decorationBox = { inner ->
            if (value.isEmpty()) {
                BasicText(
                    text = placeholder,
                    style = settingsValueStyle().copy(color = tokens.colors.tertiary),
                )
            }
            inner()
        },
    )
}

/** The one red line under a field; page-owned, cleared as soon as the text changes. */
@Composable
private fun WebSearchFeedbackLine(text: String) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        style = settingsFootnoteStyle().copy(color = tokens.colors.danger),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = tokens.spacing.badgeInsetV),
    )
}

/**
 * 保存 — the page's only button.
 *
 * The contract models this button without a label, so the visible copy is passed
 * to a private composable whose first parameter is not the gate's `label`:
 * nothing here claims a contract action.
 */
@Composable
private fun WebSearchSaveKeyButton(
    text: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH)
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight),
    ) {
        Text(text = text)
    }
}

/**
 * A settings row that is a page action (`删除这个搜索服务`).
 *
 * The whole row is the tap target and [label] is its visible text, so this is
 * the page's own button wrapper: the call site passes a fixed `UiStrings` label.
 */
@Composable
private fun WebSearchRowAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    danger: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(
            text = label,
            style = settingsLabelStyle().copy(
                color = when {
                    !enabled -> tokens.colors.tertiary
                    danger -> tokens.colors.danger
                    else -> tokens.colors.accent
                },
            ),
        )
    }
}

/** The selected-option checkmark (a glyph, never a label). */
@Composable
private fun CheckmarkGlyph() {
    val tokens = LocalUiTokens.current
    BasicText(
        text = CHECKMARK,
        style = settingsValueStyle().copy(color = tokens.colors.accent),
    )
}

/** Four is the only tail the page ever shows. */
private const val KEY_TAIL_LENGTH: Int = 4

/** The retry affordance the failure line draws (a glyph, not a contract label). */
private const val RETRY_GLYPH: String = "↻"

/** The baseline's selected-option checkmark. */
private const val CHECKMARK: String = "✓"

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest`'s page map is owned by the session-pages lane; this
 * declaration is the entry that table has for this file. The equality there is
 * "declared == what the source reads", so every value token this file names is
 * listed here.
 */
internal object WebSearchSettingsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
    )
}
