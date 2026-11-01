// Web search: the on/off switch, the backend choice, and why the switch is held.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row WebSearchSettingsPage (网页搜索开关与后端;
// entries: 设置行, 配置页) and §3.1 (the ScreenState layer). P5 `must`.
//
// The page is deliberately small and honest:
//   * the switch position comes from a [FactState], so 未知 is its own position,
//     never "off";
//   * the switch is disabled only when the page can name the reason, and the
//     reason is printed below the row (未配置后端 / 未选择 / 后端不可用 /
//     读取不到). A disabled control without a reason would be a silent failure;
//   * a backend carries no URL, credential or token: only its name and whether
//     it is configured. Nothing here can put a complete URL on screen.
//
// ScreenState: `WebSearchScreenState.from(facts, local)` is pure. The only local
// event is the backend group's fold; the toggle and the selection are host
// actions that come back as new facts.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageRowMinHeight`); the list gap is the shared `pageListGap`.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * One search backend the host knows about.
 *
 * @param id the host's stable id (also the row's test tag suffix).
 * @param name the display name; blank falls back to the page's own label.
 * @param configured whether the backend has a usable endpoint/credential. This
 *   is the only credential-shaped information the page accepts: a boolean-ish
 *   fact, never a URL or a key.
 */
@Immutable
public data class WebSearchBackend(
    public val id: String,
    public val name: String,
    public val configured: FactState = FactState.UNKNOWN,
)

/** Why the page could not read the search configuration; wording is page-owned. */
public enum class WebSearchFailureReason {
    /** The on/off document could not be read. */
    CONFIG_UNREADABLE,

    /** The backend list could not be read. */
    BACKENDS_UNREADABLE,

    /** The host reported a failure without a category the page can name. */
    UNKNOWN,
}

/**
 * The page's read-only input.
 *
 * @param enabled the switch position as a three-valued fact.
 * @param backends the available backends; `null` means no snapshot was read at
 *   all and the page renders its unknown state (never "empty").
 * @param selectedBackendId the backend the host selected, if any.
 * @param failure the last read failure, as a category.
 */
@Immutable
public data class WebSearchFacts(
    public val enabled: FactState = FactState.UNKNOWN,
    public val backends: List<WebSearchBackend>? = null,
    public val selectedBackendId: String? = null,
    public val failure: WebSearchFailureReason? = null,
    /**
     * Whether the host can persist a change here. `NO` disables the switch and
     * the backend rows and prints [UiStrings.HOST_READ_ONLY_HINT] as the reason;
     * the page never moves a control the host cannot accept.
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

/** One visible backend row; display-ready and free of secrets by construction. */
@Immutable
public data class WebSearchBackendView(
    public val id: String,
    public val name: String,
    public val selected: Boolean,
    public val status: String,
    public val statusTone: PageTone,
    public val statusHint: String,
)

/**
 * The complete web-search screen state.
 *
 * @param phase the data phase; [READY] with no backends is the empty state.
 * @param toggleChecked true only when the host said the switch is on.
 * @param toggleEnabled false when the page cannot honestly toggle anything; the
 *   pairing [reason] says why.
 * @param toggleValue the visible switch value (已开启/已关闭/未知).
 * @param reason the explanation printed under a disabled switch, or `null`.
 * @param backends the backend rows, in host order.
 * @param backendsExpanded whether the backend group is open.
 * @param failure the page-owned failure copy, or `null`.
 * @param canSelectBackends false when the host reported the page is not writable:
 *   the rows stay visible but are not clickable.
 */
@Immutable
public data class WebSearchScreenState(
    public val phase: SettingsDataPhase,
    public val toggleChecked: Boolean,
    public val toggleEnabled: Boolean,
    public val toggleValue: String,
    public val reason: String?,
    public val backends: List<WebSearchBackendView> = emptyList(),
    public val backendsExpanded: Boolean = true,
    public val failure: String? = null,
    public val canSelectBackends: Boolean = true,
) {
    /** The empty state: the page was read and has no backend. */
    public val isEmpty: Boolean get() = phase == SettingsDataPhase.READY && backends.isEmpty()

    /** No readable snapshot: the page says 未知 instead of "关闭". */
    public val isUnknown: Boolean get() = phase == SettingsDataPhase.UNKNOWN

    /** The last read failed; [failure] explains it. */
    public val isFailed: Boolean get() = phase == SettingsDataPhase.FAILED

    public companion object {
        /** Fold id of the backend group. */
        public const val BACKENDS_SECTION_ID: String = "websearch.backends"

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
                facts.backends == null -> SettingsDataPhase.UNKNOWN
                else -> SettingsDataPhase.READY
            }
            val backends = facts.backends.orEmpty()
            val selected = backends.firstOrNull { it.id == facts.selectedBackendId }
            val writeBlocked = facts.writable == FactState.NO
            val reason = when {
                phase != SettingsDataPhase.READY -> null
                writeBlocked -> UiStrings.HOST_READ_ONLY_HINT
                backends.isEmpty() -> UiStrings.WEB_SEARCH_REASON_NO_BACKENDS
                selected == null -> UiStrings.WEB_SEARCH_REASON_NO_SELECTION
                selected.configured == FactState.NO -> UiStrings.WEB_SEARCH_REASON_BACKEND_UNCONFIGURED
                selected.configured == FactState.UNKNOWN -> UiStrings.WEB_SEARCH_REASON_BACKEND_UNKNOWN
                facts.enabled == FactState.UNKNOWN -> UiStrings.WEB_SEARCH_REASON_TOGGLE_UNKNOWN
                else -> null
            }
            return WebSearchScreenState(
                phase = phase,
                toggleChecked = facts.enabled == FactState.YES,
                // A disabled switch needs a reason; the invariant is asserted by
                // the state test, so the two can never drift apart.
                toggleEnabled = phase == SettingsDataPhase.READY && reason == null,
                toggleValue = facts.enabled.value(),
                reason = reason,
                backends = backends.map { backend ->
                    WebSearchBackendView(
                        id = backend.id,
                        name = backend.name.ifBlank { UiStrings.WEB_SEARCH_TITLE },
                        selected = backend.id == facts.selectedBackendId,
                        status = backend.configured.configuredValue(),
                        statusTone = when (backend.configured) {
                            FactState.YES -> PageTone.ON
                            FactState.NO -> PageTone.DEGRADED
                            FactState.UNKNOWN -> PageTone.UNKNOWN
                        },
                        statusHint = when (backend.configured) {
                            FactState.YES -> UiStrings.WEB_SEARCH_BACKEND_CONFIGURED_HINT
                            FactState.NO -> UiStrings.WEB_SEARCH_BACKEND_UNCONFIGURED_HINT
                            FactState.UNKNOWN -> UiStrings.SETTINGS_UNKNOWN_HINT
                        },
                    )
                },
                backendsExpanded = local.fold.isExpanded(BACKENDS_SECTION_ID),
                failure = facts.failure?.text(),
                canSelectBackends = phase == SettingsDataPhase.READY && !writeBlocked,
            )
        }

        private fun FactState.value(): String = when (this) {
            FactState.YES -> UiStrings.WEB_SEARCH_ON
            FactState.NO -> UiStrings.WEB_SEARCH_OFF
            FactState.UNKNOWN -> UiStrings.UNKNOWN
        }

        /**
         * A backend's own state says whether it is configured, not whether the
         * switch is on: sharing [value] would print 已开启 on a backend row and
         * make three different facts look like one.
         */
        private fun FactState.configuredValue(): String = when (this) {
            FactState.YES -> UiStrings.CONFIGURED
            FactState.NO -> UiStrings.NOT_CONFIGURED
            FactState.UNKNOWN -> UiStrings.UNKNOWN
        }

        private fun WebSearchFailureReason.text(): String = when (this) {
            WebSearchFailureReason.CONFIG_UNREADABLE -> UiStrings.WEB_SEARCH_FAILURE_CONFIG
            WebSearchFailureReason.BACKENDS_UNREADABLE -> UiStrings.WEB_SEARCH_FAILURE_BACKENDS
            WebSearchFailureReason.UNKNOWN -> UiStrings.WEB_SEARCH_FAILURE_UNKNOWN
        }
    }
}

/** The local UI events of the web-search page: only the backend fold. */
public sealed interface WebSearchUiEvent {
    /** Collapse or expand the backend group. */
    public data object ToggleBackends : WebSearchUiEvent
}

/** The fold script; [apply] is pure, so a test drives it like a reducer. */
@Immutable
public data class WebSearchLocalState(public val fold: FoldState = FoldState()) {
    /** Applies one local event. */
    public fun apply(event: WebSearchUiEvent): WebSearchLocalState = when (event) {
        WebSearchUiEvent.ToggleBackends ->
            copy(fold = fold.toggle(WebSearchScreenState.BACKENDS_SECTION_ID))
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The web-search settings screen.
 *
 * @param state the pure screen state ([WebSearchScreenState.from]).
 * @param onToggle the user flipped the switch; the host persists and re-reads.
 *   The page never moves the switch itself, so it cannot show a state the host
 *   did not accept.
 * @param onSelectBackend the user chose a backend (by id).
 * @param onToggleBackends collapse/expand the backend group; the host applies
 *   `WebSearchUiEvent.ToggleBackends` and re-projects.
 * @param onRetry retry a failed read.
 * @param onBack leave the page.
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
) {
    PageFrame(
        title = UiStrings.WEB_SEARCH_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.WEB_SEARCH_ROOT,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            if (state.failure != null) {
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.WEB_SEARCH_FAILURE,
                    retryLabel = UiStrings.RETRY,
                    onRetry = onRetry,
                )
            }
            when {
                state.isUnknown -> EmptyHint(
                    title = UiStrings.WEB_SEARCH_UNKNOWN_STATE,
                    hint = UiStrings.WEB_SEARCH_UNKNOWN_HINT,
                    tag = UiPageTags.WEB_SEARCH_UNKNOWN,
                )

                // A failed read is replaced by its failure line: rendering stale
                // facts would either show a switch the page cannot explain or
                // claim a position the host just failed to report.
                state.isFailed -> Unit

                else -> LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag(UiPageTags.WEB_SEARCH_LIST),
                    verticalArrangement = Arrangement.spacedBy(pageListGap),
                ) {
                    item(key = "switch") {
                        SettingsToggleRow(
                            label = UiStrings.WEB_SEARCH_TITLE,
                            value = state.toggleValue,
                            checked = state.toggleChecked,
                            enabled = state.toggleEnabled,
                            onToggle = onToggle,
                            tag = UiPageTags.WEB_SEARCH_TOGGLE,
                        )
                    }
                    if (state.reason != null) {
                        item(key = "reason") {
                            ToggleReasonLine(reason = state.reason)
                        }
                    }
                    item(key = "header.backends") {
                        SectionHeader(
                            title = UiStrings.WEB_SEARCH_BACKENDS,
                            expanded = state.backendsExpanded,
                            onToggle = onToggleBackends,
                            trailing = UiStrings.ROW_COUNT.format(state.backends.size),
                            tag = UiPageTags.WEB_SEARCH_BACKENDS_SECTION,
                        )
                    }
                    if (state.backendsExpanded) {
                        items(
                            count = state.backends.size,
                            key = { index -> "row.${state.backends[index].id}" },
                        ) { index ->
                            val row = state.backends[index]
                            BackendRow(
                                row = row,
                                onSelect = if (state.canSelectBackends) {
                                    { onSelectBackend(row.id) }
                                } else {
                                    null
                                },
                            )
                        }
                        if (state.backends.isEmpty()) {
                            item(key = "empty") {
                                BackendEmptyBlock()
                            }
                        }
                    }
                }
            }
        }
    }
}

/** The reason line under a held switch: the disabled control is never silent. */
@Composable
private fun ToggleReasonLine(reason: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = reason,
        style = type.caption.copy(color = tokens.colors.warning),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.WEB_SEARCH_REASON)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** The empty backend block: the switch stays visible, the list explains itself. */
@Composable
private fun BackendEmptyBlock() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.WEB_SEARCH_EMPTY)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.WEB_SEARCH_EMPTY,
            style = type.body.copy(color = tokens.colors.tertiary),
        )
        BasicText(
            text = UiStrings.WEB_SEARCH_EMPTY_HINT,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
    }
}

/** One backend: name + selected marker + whether it is configured. */
@Composable
private fun BackendRow(
    row: WebSearchBackendView,
    onSelect: (() -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.WEB_SEARCH_BACKEND_ROW_PREFIX + row.id)
            // A null handler means the host cannot persist a selection: the row is
            // visible and disabled rather than silently inert.
            .clickable(enabled = onSelect != null, role = Role.Button, onClick = { onSelect?.invoke() })
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
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
                text = row.name,
                style = type.body.copy(color = tokens.colors.primary),
                modifier = Modifier.weight(1f),
            )
            if (row.selected) {
                BasicText(
                    text = UiStrings.SELECTED,
                    style = type.caption.copy(color = tokens.colors.accent),
                )
            }
            BasicText(
                text = row.status,
                style = type.secondary.copy(color = row.statusTone.ink(tokens)),
            )
        }
        BasicText(
            text = row.statusHint,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
        if (!row.selected) {
            BasicText(
                text = UiStrings.WEB_SEARCH_SELECT,
                style = type.caption.copy(color = tokens.colors.accent),
            )
        }
    }
}

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest`'s page map is owned by the session-pages lane; this
 * declaration is the entry that table adds for this file. The equality there is
 * "declared == what the source reads", so the typography roles this file names
 * are part of the list together with the value tokens. The switch row itself is
 * shared (`SettingsToggleRow`), but it lives in the model-provider file, so its
 * token reads are declared there, not here.
 */
internal object WebSearchSettingsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
    )
}
