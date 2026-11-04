// Egress allow list: the effective rules, the allow-all switch and the add flow.
// SPDX-License-Identifier: MIT
//
// Mirror source: `examples/probe-app/PhoneDSHProbe/NativeShell.swift`, struct
// `EgressAllowListPage` (`:443`-`:731`). The baseline page is two `List` sections:
// an untitled one holding the 允许连任何网站 toggle and its footer (`:465`-`:471`),
// and 地址 holding the empty-list rows and 恢复成默认的 (`:474`-`:487`), the host
// rows with their delete context menu (`:489`-`:502`), the 添加地址 row (`:512`),
// and a header with the 现在不起作用 / N 个地址 caption (`:521`-`:538`). Posting a
// new address is an overlay with 取消 and 添加 (`:661`-`:691`).
//
// Every one of those controls is present here with the baseline's own label,
// because the page contract names them as actions. What the page does NOT own is
// the edit: the switch, the restore, the add and the delete all call a callback,
// and the page never mutates the rule list. `EgressAllowListFacts.writable` says
// whether the host publishes a command that persists such an edit; when it does
// not, the controls stay on screen (the baseline's structure) but are disabled,
// and [UiStrings.HOST_READ_ONLY_HINT] says why before the user taps. A disabled
// control that is explained is honest; an enabled control that silently does
// nothing is not.
//
// The four states are unchanged. An empty rule table is the deny-all policy, not
// an empty list and not an unknown read; a failed read is another state; a host
// that did not report the list is 未知. Neither may claim deny-all. The
// 规则语法 group explains the matching syntax the baseline puts in the field's
// placeholder and in its validation message; it is an Android-only group (the
// iOS page has no such Section) and is registered with the contract owner.
//
// ScreenState: `EgressAllowListScreenState.from(facts, local)` is pure; the fold
// script is the only persisted local state, so the same `(facts, script)` replays
// on the JVM. The add overlay's draft and the delete confirmation's target are
// transient interaction state owned by the page (the same split as ChatPage's
// rename overlay), and the entry validation is a pure function.
//
// Geometry: the page margin, the row floors and the card radius come from
// `spec/ui/v1/tokens.json` (`geometry.pageOuterMarginH`, `geometry.pageRowMinHeight`,
// `geometry.pageListRowMinHeight`, `geometry.cardPadding`, `radius.card`); the list
// gap is the shared `pageListGap`. Every colour and type comes through
// `LocalUiTokens`/`LocalUiType`. unverified geometry: the add overlay's inner
// padding is the approval card's `geometry.cardPadding`, because the spec
// declares no page-level dialog inset.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsFormRow
import com.phonedsh.ui.surface.SettingsSectionHeader
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.surface.settingsFootnoteStyle

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * One parsed egress rule, in the shape `:net`'s `GatewayHostRule` uses.
 *
 * @param id the host's stable id for the row.
 * @param scheme `http`, `https`, or `null` for a bare host that matches either.
 * @param host the host literal, `*`, or a `*.suffix` wildcard.
 * @param port the explicit effective port, or `null` for any port.
 */
@Immutable
public data class EgressRule(
    public val id: String,
    public val host: String,
    public val scheme: String? = null,
    public val port: Int? = null,
)

/**
 * The host's read-only snapshot of the allow list.
 *
 * @param rules the parsed entries; `null` means the host did not report the list
 *   (未知), while `emptyList()` is the deny-all policy and must never be shown as
 *   an ordinary empty state.
 * @param failure the host's read failure; non-null when the last read failed.
 * @param writable whether the host publishes a command that persists an edit.
 *   The default is [FactState.NO]: the Android host adapter has no egress-write
 *   command yet, so the baseline's controls are rendered (their labels are the
 *   contract's actions) but disabled. A host that adds the commands reports
 *   [FactState.YES] and wires the page's four write callbacks;
 *   [FactState.UNKNOWN] is treated like NO, because a host that did not answer
 *   cannot enable a button that would then do nothing.
 */
@Immutable
public data class EgressAllowListFacts(
    public val rules: List<EgressRule>? = null,
    public val failure: String? = null,
    public val writable: FactState = FactState.NO,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The four outcomes the page distinguishes; the empty table is a policy, not a state. */
public enum class EgressStatus {
    /** The host reported at least one rule. */
    READY,

    /** The table is empty: every host is denied. */
    DENY_ALL,

    /** The last host read failed; no rule claim survives it. */
    FAILED,

    /** The host did not report the list: the page says 未知 instead of "deny all". */
    UNKNOWN,
}

/** One rule row: the exact matching form plus the scope it covers. */
@Immutable
public data class EgressRuleView(
    public val id: String,
    /**
     * The host literal the entry contributes (`*`, `*.suffix` or a host name).
     * The page needs it for the duplicate check when a new address is typed; the
     * baseline compares against the parsed host list, not the canonical form.
     */
    public val host: String,
    /** The canonical form, for example `https://api.example.com:8443` or `*.example.com`. */
    public val form: String,
    /** 精确主机 / 通配后缀 / 任意主机. */
    public val formLabel: String,
    /** The scope detail: scheme, port and wildcard coverage. */
    public val detail: String,
)

/**
 * Why a typed address is not usable yet; `null` from [validateEgressEntry] means
 * it is.
 */
public enum class EgressRuleProblem {
    /** Not a bare host: it carries a scheme, a path, a port, a space or an `@`. */
    NOT_A_HOST,

    /** The list already holds this host. */
    DUPLICATE,
}

/**
 * The value an entry contributes to the list.
 *
 * The baseline trims and lower-cases before comparing and storing
 * (`NativeShell.swift:696`-`:703`), so the page does the same and the duplicate
 * check cannot be fooled by case or padding.
 */
public fun egressEntryValue(raw: String): String = raw.trim().lowercase()

/**
 * Validates a typed address against the baseline's rule and the current list.
 *
 * Pure: no clock, no host call. The baseline's `looksLikeHost` accepts a value
 * that contains a dot and none of `/`, `:`, a space or `@`; anything else gets
 * the baseline's 只写域名,例如 api.deepseek.com。 message.
 *
 * @param raw the field's text.
 * @param existing the hosts already in the list (the rule views' [EgressRuleView.host]).
 */
public fun validateEgressEntry(raw: String, existing: Collection<String>): EgressRuleProblem? {
    val value = egressEntryValue(raw)
    val looksLikeHost = value.contains(".") &&
        !value.contains("/") &&
        !value.contains(":") &&
        !value.contains(" ") &&
        !value.contains("@")
    if (!looksLikeHost) return EgressRuleProblem.NOT_A_HOST
    if (existing.any { egressEntryValue(it) == value }) return EgressRuleProblem.DUPLICATE
    return null
}

/** The message for one validation result; the page owns the copy. */
internal fun egressRuleProblemText(problem: EgressRuleProblem): String = when (problem) {
    EgressRuleProblem.NOT_A_HOST -> UiStrings.EGRESS_ADD_PROBLEM
    EgressRuleProblem.DUPLICATE -> UiStrings.EGRESS_ADD_DUPLICATE
}

/**
 * The complete egress screen state.
 *
 * @param status the four-state outcome; [EgressStatus.DENY_ALL] is the empty
 *   table and is deliberately not an empty state.
 * @param rules the visible rule rows, in host order.
 * @param ruleCount the reported rule count; `null` when the host did not report
 *   the list, so an unknown read never renders `0 个地址`.
 * @param allowAll true only for a bare `*` (any http(s) host, any port).
 * @param rulesExpanded whether the rule group is open.
 * @param grammarExpanded whether the syntax explanation is open.
 * @param failure the host's failure message, re-shown by the page.
 * @param canWrite true when the host declared a write command: the toggle, the
 *   restore row, 添加地址 and the delete confirmation are enabled. False (the
 *   default) keeps them on screen and disabled, with the host's reason above.
 *   The restore row also needs its own callback (`onRestoreDefaults`): a declared
 *   command with no handler would be an enabled button that cannot do anything.
 */
@Immutable
public data class EgressAllowListScreenState(
    public val status: EgressStatus,
    public val rules: List<EgressRuleView>,
    public val ruleCount: Int?,
    public val allowAll: Boolean,
    public val rulesExpanded: Boolean,
    public val grammarExpanded: Boolean,
    public val failure: String?,
    public val canWrite: Boolean = false,
) {
    /** True only for an empty rule table: the deny-all policy. */
    public val denyAll: Boolean get() = status == EgressStatus.DENY_ALL

    /** True when the host did not report the list at all. */
    public val isUnknown: Boolean get() = status == EgressStatus.UNKNOWN

    /** True when the last read failed. */
    public val isFailed: Boolean get() = status == EgressStatus.FAILED

    /**
     * A stable, display-free signature of the sequence-relevant state.
     *
     * Folding a group never changes the status or the effective policy, which is
     * exactly what the sequence test asserts.
     */
    public fun signature(): String = buildString {
        append(status.name).append(':')
        append("rules=").append(rules.size).append(':')
        append("expanded=").append(if (rulesExpanded) "1" else "0").append(':')
        append("grammar=").append(if (grammarExpanded) "1" else "0")
    }

    public companion object {
        public const val RULES_SECTION_ID: String = "egress.rules"
        public const val GRAMMAR_SECTION_ID: String = "egress.grammar"

        /**
         * Projects (facts, fold script) into the screen state.
         *
         * Pure: the empty table is classified here, once, as [EgressStatus.DENY_ALL];
         * the page cannot accidentally route it through an empty state because no
         * such enum member exists.
         */
        public fun from(
            facts: EgressAllowListFacts,
            local: EgressAllowListLocalState = EgressAllowListLocalState(),
        ): EgressAllowListScreenState {
            val rawRules = facts.rules
            val status = when {
                facts.failure != null -> EgressStatus.FAILED
                rawRules == null -> EgressStatus.UNKNOWN
                rawRules.isEmpty() -> EgressStatus.DENY_ALL
                else -> EgressStatus.READY
            }
            val rules = if (status == EgressStatus.READY) {
                rawRules.orEmpty().mapIndexed { index, rule ->
                    val wildcard = rule.host == "*"
                    val suffix = rule.host.startsWith("*.") && rule.host.length > 2
                    val detail = buildList {
                        when {
                            wildcard -> add(UiStrings.EGRESS_DETAIL_ANY_HOST)
                            suffix -> add(UiStrings.EGRESS_DETAIL_WILDCARD)
                            else -> Unit
                        }
                        if (rule.scheme == null) add(UiStrings.EGRESS_DETAIL_ANY_SCHEME)
                        add(rule.port?.let { UiStrings.EGRESS_DETAIL_PORT.format(it) }
                            ?: UiStrings.EGRESS_DETAIL_ANY_PORT)
                    }
                    EgressRuleView(
                        id = rule.id.ifBlank { "rule.$index" },
                        host = rule.host,
                        form = ruleForm(rule),
                        formLabel = when {
                            wildcard -> UiStrings.EGRESS_FORM_ANY
                            suffix -> UiStrings.EGRESS_FORM_WILDCARD
                            else -> UiStrings.EGRESS_FORM_EXACT
                        },
                        detail = detail.joinToString(DETAIL_SEPARATOR),
                    )
                }
            } else {
                emptyList()
            }
            val allowAll = status == EgressStatus.READY && facts.rules.orEmpty().any { rule ->
                rule.scheme == null && rule.host == "*" && rule.port == null
            }
            return EgressAllowListScreenState(
                status = status,
                rules = rules,
                ruleCount = when (status) {
                    EgressStatus.READY -> rules.size
                    EgressStatus.DENY_ALL -> 0
                    EgressStatus.FAILED, EgressStatus.UNKNOWN -> null
                },
                allowAll = allowAll,
                rulesExpanded = local.fold.isExpanded(RULES_SECTION_ID),
                grammarExpanded = local.fold.isExpanded(GRAMMAR_SECTION_ID),
                failure = facts.failure,
                canWrite = facts.writable == FactState.YES,
            )
        }

        private fun ruleForm(rule: EgressRule): String = buildString {
            rule.scheme?.let { append(it).append("://") }
            append(rule.host)
            rule.port?.let { append(':').append(it) }
        }
    }
}

/** The local UI events of the egress page: only the group folds. */
public sealed interface EgressAllowListUiEvent {
    /** Collapse or expand one group. */
    public data class ToggleSection(public val id: String) : EgressAllowListUiEvent
}

/** The fold script; [apply] is pure, so a test drives it like a reducer. */
@Immutable
public data class EgressAllowListLocalState(public val fold: FoldState = FoldState()) {
    /** Applies one local event. */
    public fun apply(event: EgressAllowListUiEvent): EgressAllowListLocalState = when (event) {
        is EgressAllowListUiEvent.ToggleSection -> copy(fold = fold.toggle(event.id))
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The egress allow-list page.
 *
 * The page renders the baseline's two sections and its add/delete flow, but it
 * never changes the rule list itself: every write is a callback. When the host's
 * [EgressAllowListFacts.writable] is not [FactState.YES], the write controls are
 * disabled and [UiStrings.HOST_READ_ONLY_HINT] says why.
 *
 * @param state the pure screen state (`EgressAllowListScreenState.from`).
 * @param onBack leave the page.
 * @param onToggleSection a group header was tapped; the host applies
 *   `EgressAllowListUiEvent.ToggleSection` and re-projects.
 * @param onToggleAllowAll the 允许连任何网站 switch moved (`NativeShell.swift:466`);
 *   `null` when the host has no write command.
 * @param onRestoreDefaults 恢复成默认的 (`:482`); `null` when the host has no
 *   write command. The row is enabled only when the host declared one *and* passed
 *   this callback, so a writable host without a handler cannot paint a dead button.
 * @param onAddRule the typed address passed validation and 添加 was tapped
 *   (`:670`); receives the trimmed, lower-cased value. `null` when the host has
 *   no write command.
 * @param onRemoveRule 删除这个地址 was confirmed for one row (`:496`); `null` when
 *   the host has no write command.
 * @param onRetry retry the failed read; `null` renders no retry row.
 * @param onDismissFailure dismiss the failure line; `null` renders no dismiss row.
 */
@Composable
public fun EgressAllowListPage(
    state: EgressAllowListScreenState,
    onBack: () -> Unit,
    onToggleSection: (String) -> Unit,
    modifier: Modifier = Modifier,
    onToggleAllowAll: ((Boolean) -> Unit)? = null,
    onRestoreDefaults: (() -> Unit)? = null,
    onAddRule: ((String) -> Unit)? = null,
    onRemoveRule: ((EgressRuleView) -> Unit)? = null,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
) {
    // Transient interaction state: which dialog is open and what was typed. The
    // rule list itself is the host's; nothing below mutates `state`.
    var adding by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<EgressRuleView?>(null) }

    Box(modifier = modifier.fillMaxSize()) {
        SettingsSubPageFrame(
            title = UiStrings.EGRESS_TITLE,
            onBack = onBack,
            backGlyph = SETTINGS_CLOSE_GLYPH,
            rootTag = UiPageTags.EGRESS_ROOT,
        ) {
            when (state.status) {
                EgressStatus.FAILED -> EgressFailureBlock(
                    failure = state.failure,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )

                EgressStatus.UNKNOWN -> EmptyHint(
                    title = UiStrings.EGRESS_UNKNOWN_STATE,
                    hint = UiStrings.EGRESS_UNKNOWN_HINT,
                    tag = UiPageTags.EGRESS_UNKNOWN,
                )

                EgressStatus.DENY_ALL, EgressStatus.READY -> EgressContent(
                    state = state,
                    onToggleSection = onToggleSection,
                    onToggleAllowAll = onToggleAllowAll,
                    onRestoreDefaults = onRestoreDefaults,
                    onAddRequest = { adding = true },
                    onDeleteRequest = { rule -> pendingDelete = rule },
                )
            }
        }
        if (adding) {
            AddRuleOverlay(
                existing = state.rules.map { it.host },
                onDismiss = { adding = false },
                onConfirm = { value ->
                    onAddRule?.invoke(value)
                    adding = false
                },
            )
        }
        val deleting = pendingDelete
        if (deleting != null) {
            DeleteRuleDialog(
                rule = deleting,
                canWrite = state.canWrite,
                onCancel = { pendingDelete = null },
                onConfirm = {
                    onRemoveRule?.invoke(deleting)
                    pendingDelete = null
                },
            )
        }
    }
}

/**
 * The allow-all switch, the rule list or the deny-all policy, the write rows, the
 * syntax explanation and the two dialogs' triggers.
 *
 * Both READY and DENY_ALL use the same lazy list: the deny-all banner is an item,
 * not a replacement for the screen, so the page still has a scrollable content
 * region and the grammar remains reachable.
 */
@Composable
private fun EgressContent(
    state: EgressAllowListScreenState,
    onToggleSection: (String) -> Unit,
    onToggleAllowAll: ((Boolean) -> Unit)?,
    onRestoreDefaults: (() -> Unit)?,
    onAddRequest: () -> Unit,
    onDeleteRequest: (EgressRuleView) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val canWrite = state.canWrite
    // A write control is enabled only when the host both declared a write command
    // *and* handed the callback for this one action: `writable = YES` with a null
    // `onRestoreDefaults` would otherwise paint an enabled button that does nothing.
    val canRestore = canWrite && onRestoreDefaults != null
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.EGRESS_LIST),
        verticalArrangement = Arrangement.Top,
    ) {
        // `NativeShell.swift:465`-`:471`: the untitled first section is the
        // allow-all switch and its footer.
        item(key = "egress.allow-all") {
            AllowAllBlock(
                checked = state.allowAll,
                canWrite = canWrite,
                onCheckedChange = { wanted -> onToggleAllowAll?.invoke(wanted) },
            )
        }
        // The host's own answer to "can this page save?": visible before the tap,
        // never a silent no-op afterwards.
        if (!canWrite) {
            item(key = "egress.read-only") {
                EgressNoteRow(
                    text = UiStrings.HOST_READ_ONLY_HINT,
                    tone = PageTone.NORMAL,
                    tag = UiPageTags.EGRESS_READ_ONLY,
                )
            }
        }
        item(key = "egress.rules.header") {
            SettingsSectionHeader(
                title = UiStrings.EGRESS_RULES,
                expanded = state.rulesExpanded,
                onToggle = { onToggleSection(EgressAllowListScreenState.RULES_SECTION_ID) },
                trailing = when {
                    state.allowAll -> UiStrings.EGRESS_INACTIVE
                    state.ruleCount != null && state.ruleCount > 0 ->
                        UiStrings.EGRESS_RULE_COUNT.format(state.ruleCount)
                    else -> null
                },
                tag = UiPageTags.EGRESS_RULES_SECTION,
            )
        }
        when (state.status) {
            EgressStatus.DENY_ALL -> item(key = "egress.deny-all") {
                SettingsFormRow(
                    title = UiStrings.EGRESS_POLICY,
                    value = UiStrings.EGRESS_DENY_ALL,
                    tone = PageTone.DEGRADED,
                    subtitle = UiStrings.EGRESS_DENY_ALL_HINT,
                    modifier = Modifier.testTag(UiPageTags.EGRESS_DENY_ALL),
                )
            }

            EgressStatus.READY -> {
                if (state.allowAll) {
                    item(key = "egress.allow-all.banner") {
                        SettingsFormRow(
                            title = UiStrings.EGRESS_POLICY,
                            value = UiStrings.EGRESS_ALLOW_ALL,
                            tone = PageTone.DEGRADED,
                            subtitle = UiStrings.EGRESS_ALLOW_ALL_HINT,
                            modifier = Modifier.testTag(UiPageTags.EGRESS_ALLOW_ALL),
                        )
                    }
                }
                if (state.rulesExpanded) {
                    items(count = state.rules.size, key = { index -> state.rules[index].id }) { index ->
                        EgressRuleRow(
                            rule = state.rules[index],
                            canWrite = canWrite,
                            onDeleteRequest = onDeleteRequest,
                        )
                    }
                }
            }

            EgressStatus.FAILED, EgressStatus.UNKNOWN -> Unit
        }
        // `:482`: the empty list can always be restored to the shipped defaults;
        // under the allow-all switch the baseline keeps the stashed list and shows
        // the same row (`:475`-`:487`).
        if (state.rules.isEmpty() || state.allowAll) {
            item(key = "egress.restore") {
                // The baseline's row is a bare text button with the accent ink and a
                // 48 pt floor (`NativeShell.swift:483`), not a form row: it has no
                // value column and no separator. The page's own text action carries
                // the accent ink and the page row floor, and it keeps the label a
                // literal `UiStrings` constant — which is also what the structure
                // checker can read (`SettingsFormRow(title = …)` is a row, not an
                // action, to it, so this control used to look absent).
                SessionTextAction(
                    label = UiStrings.EGRESS_RESTORE_DEFAULTS,
                    onClick = { onRestoreDefaults?.invoke() },
                    tone = SessionActionTone.ACCENT,
                    enabled = canRestore,
                    modifier = Modifier
                        .testTag(UiPageTags.EGRESS_RESTORE)
                        .padding(horizontal = tokens.geometry.pageOuterMarginH),
                )
            }
        }
        // `:512`: an address can be added even when the list is empty, and not
        // while the allow-all switch is on.
        if (!state.allowAll) {
            item(key = "egress.add") {
                SettingsFormRow(
                    title = UiStrings.EGRESS_ADD_ADDRESS,
                    value = null,
                    enabled = canWrite,
                    onClick = onAddRequest,
                    modifier = Modifier.testTag(UiPageTags.EGRESS_ADD),
                )
            }
        }
        item(key = "egress.grammar.header") {
            SettingsSectionHeader(
                title = UiStrings.EGRESS_GRAMMAR,
                expanded = state.grammarExpanded,
                onToggle = { onToggleSection(EgressAllowListScreenState.GRAMMAR_SECTION_ID) },
                tag = UiPageTags.EGRESS_GRAMMAR_SECTION,
            )
        }
        if (state.grammarExpanded) {
            items(count = GRAMMAR_LINES.size, key = { index -> "grammar.$index" }) { index ->
                EgressNoteRow(
                    text = GRAMMAR_LINES[index],
                    tone = PageTone.NORMAL,
                    tag = UiPageTags.EGRESS_GRAMMAR,
                )
            }
        }
    }
}

/**
 * 允许连任何网站 + its footer (`NativeShell.swift:465`-`:471`).
 *
 * The switch is the section's criterion row in the contract, so its label is a
 * literal the checker can read; the row merges its semantics so a screen reader
 * hears the label and the state together.
 */
@Composable
private fun AllowAllBlock(
    checked: Boolean,
    canWrite: Boolean,
    onCheckedChange: (Boolean) -> Unit,
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
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = UiStrings.EGRESS_ALLOW_ALL_TOGGLE,
                style = type.body.copy(color = tokens.colors.primary),
                modifier = Modifier
                    .weight(1f)
                    .testTag(UiPageTags.EGRESS_ALLOW_ALL_TOGGLE),
            )
            // Every colour this switch draws is named here, from the page's own
            // token table. Left to `SwitchDefaults`, the unchecked track is the
            // Material baseline's `surfaceVariant` = #E6E0E9 — the stray colour
            // the parity measurement found on this page (8 584 px of it), which no
            // token in `spec/ui/v1/tokens.json` owns. The green on-state is
            // `colors.switchOn` (#34C759, the UIKit `systemGreen` the baseline's
            // untinted `Toggle` uses); the off-state track is the same
            // `colors.borderLight` the settings index's own switch draws.
            Switch(
                checked = checked,
                onCheckedChange = onCheckedChange,
                enabled = canWrite,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = tokens.colors.input,
                    checkedTrackColor = tokens.colors.switchOn,
                    checkedBorderColor = tokens.colors.switchOn,
                    uncheckedThumbColor = tokens.colors.input,
                    uncheckedTrackColor = tokens.colors.borderLight,
                    uncheckedBorderColor = tokens.colors.borderLight,
                    disabledCheckedThumbColor = tokens.colors.input,
                    disabledCheckedTrackColor = tokens.colors.border,
                    disabledCheckedBorderColor = tokens.colors.border,
                    disabledUncheckedThumbColor = tokens.colors.input,
                    disabledUncheckedTrackColor = tokens.colors.border,
                    disabledUncheckedBorderColor = tokens.colors.border,
                ),
                modifier = Modifier.testTag(UiPageTags.EGRESS_ALLOW_ALL_TOGGLE + ".switch"),
            )
        }
        BasicText(
            text = UiStrings.EGRESS_ALLOW_ALL_FOOTER,
            style = type.caption.copy(color = tokens.colors.tertiary),
            modifier = Modifier
                .padding(top = tokens.spacing.badgeInsetV)
                .testTag(UiPageTags.EGRESS_ALLOW_ALL_FOOTER),
        )
    }
}

/**
 * One allow-listed address.
 *
 * The baseline's network page draws each address as a single 17 pt line at the
 * measured 52.33 pt pitch (`ios-settings-network.png`: ink y=890..916 px, the
 * separators 157 px apart, 11 of them in frame), so the row is
 * [SettingsFormRow] — the page never re-types the pitch.
 *
 * The Android-only classification (精确主机 / 通配后缀 plus the scope sentence) is
 * printed on a second line **only when the canonical form differs from the host
 * the user typed**: for a bare host like `wttr.in` that line would repeat what the
 * first line already says and the row would stop matching the baseline, so it is
 * also exactly the case where the classification tells the user something new.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun EgressRuleRow(
    rule: EgressRuleView,
    canWrite: Boolean,
    onDeleteRequest: (EgressRuleView) -> Unit,
) {
    val tokens = LocalUiTokens.current
    SettingsFormRow(
        title = rule.form,
        // The baseline's address row carries no visible control: deleting one
        // address is the row's `contextMenu` (`NativeShell.swift:495`), i.e. a
        // long press, and the confirmation dialog is what performs it. Android's
        // extra `⋯` was the one control on this page iOS does not draw, so it is
        // gone; the row itself is the target, and it opens the same confirmation
        // the context menu does (a tap costs one 取消, never a write).
        modifier = Modifier
            .testTag(UiPageTags.EGRESS_RULE)
            .combinedClickable(
                // Not gated on `canWrite`: opening the confirmation is interaction,
                // not a write. The confirm button is what the host's answer
                // disables, and it says why inside the dialog.
                role = Role.Button,
                onLongClickLabel = UiStrings.EGRESS_DELETE_ADDRESS,
                onLongClick = { onDeleteRequest(rule) },
                onClick = { onDeleteRequest(rule) },
            ),
        subtitleContent = {
            Row(
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
            ) {
                BasicText(
                    text = rule.formLabel,
                    style = settingsFootnoteStyle().copy(color = tokens.colors.tertiary),
                )
                BasicText(
                    text = rule.detail,
                    style = settingsFootnoteStyle().copy(color = tokens.colors.tertiary),
                )
            }
        },
    )
}

/** One explanatory line; the tone is never a second colour source. */
@Composable
private fun EgressNoteRow(
    text: String,
    tone: PageTone,
    tag: String? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tone.ink(tokens)),
        modifier = Modifier
            .fillMaxWidth()
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/**
 * The baseline's add overlay (`NativeShell.swift:661`-`:691`): a scrim, the
 * 添加地址 title, the bare-host field, the validation line and 取消 / 添加.
 *
 * It is drawn in the page rather than with a platform dialog because a Compose
 * `AlertDialog` holding a text field never settles under Robolectric (the cursor
 * frame loop keeps the test harness from going idle); the baseline's own shape is
 * an overlay too, so this is the closer mirror. The content, the placeholder and
 * the validation sentence are the baseline's.
 *
 * @param existing the hosts already in the list, for the duplicate check.
 * @param onDismiss close the overlay without adding.
 * @param onConfirm add the validated value; the page's caller forwards it to the
 *   host and the host re-reads the list.
 */
@Composable
private fun AddRuleOverlay(
    existing: List<String>,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var draft by remember { mutableStateOf("") }
    val value = egressEntryValue(draft)
    val problem = if (draft.isBlank()) null else validateEgressEntry(draft, existing)
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(tokens.colors.primary.copy(alpha = SCRIM_ALPHA))
            .clickable(role = Role.Button, onClick = onDismiss)
            .semantics { contentDescription = UiStrings.EGRESS_ADD_ADDRESS }
            .testTag(UiPageTags.EGRESS_ADD_OVERLAY),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .padding(horizontal = tokens.geometry.pageOuterMarginH)
                .fillMaxWidth()
                .background(tokens.colors.input, RoundedCornerShape(tokens.radius.card))
                .padding(tokens.geometry.cardPadding),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = UiStrings.EGRESS_ADD_ADDRESS,
                style = type.headline.copy(color = tokens.colors.primary),
                modifier = Modifier.semantics { heading() },
            )
            BasicTextField(
                value = draft,
                onValueChange = { draft = it },
                singleLine = true,
                textStyle = type.body.copy(color = tokens.colors.primary),
                cursorBrush = SolidColor(tokens.colors.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.EGRESS_ADD_FIELD),
                decorationBox = { inner ->
                    Box {
                        if (draft.isEmpty()) {
                            BasicText(
                                text = UiStrings.EGRESS_ADD_HINT,
                                style = type.body.copy(color = tokens.colors.tertiary),
                            )
                        }
                        inner()
                    }
                },
            )
            if (problem != null) {
                BasicText(
                    text = egressRuleProblemText(problem),
                    style = type.caption.copy(color = tokens.colors.warning),
                    modifier = Modifier.testTag(UiPageTags.EGRESS_ADD_PROBLEM),
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText, Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SessionTextAction(
                    label = UiStrings.CANCEL,
                    onClick = onDismiss,
                    tone = SessionActionTone.SECONDARY,
                    modifier = Modifier.testTag(UiPageTags.EGRESS_ADD_CANCEL),
                )
                SessionTextAction(
                    label = UiStrings.EGRESS_ADD,
                    onClick = { onConfirm(value) },
                    tone = SessionActionTone.ACCENT,
                    enabled = problem == null && value.isNotEmpty(),
                    modifier = Modifier.testTag(UiPageTags.EGRESS_ADD_CONFIRM),
                )
            }
        }
    }
}

/**
 * The delete confirmation: 删除这个地址？ with the address and 删除这个地址 / 取消.
 *
 * The confirmation is an interaction step, not a write: the write happens only in
 * [onConfirm], which the page forwards to the host. When the host cannot write the
 * confirm button is disabled and the same [UiStrings.HOST_READ_ONLY_HINT] the page
 * shows is repeated inside the dialog, so the reason travels with the control.
 */
@Composable
private fun DeleteRuleDialog(
    rule: EgressRuleView,
    canWrite: Boolean,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    AlertDialog(
        onDismissRequest = onCancel,
        modifier = Modifier.testTag(UiPageTags.EGRESS_DELETE_DIALOG),
        title = {
            BasicText(
                text = UiStrings.EGRESS_DELETE_CONFIRM,
                style = type.headline.copy(color = tokens.colors.primary),
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText)) {
                BasicText(
                    text = rule.form,
                    style = type.code.copy(color = tokens.colors.secondary),
                )
                BasicText(
                    text = UiStrings.EGRESS_DELETE_DETAIL,
                    style = type.secondary.copy(color = tokens.colors.secondary),
                )
                if (!canWrite) {
                    BasicText(
                        text = UiStrings.HOST_READ_ONLY_HINT,
                        style = type.caption.copy(color = tokens.colors.tertiary),
                    )
                }
            }
        },
        confirmButton = {
            SessionTextAction(
                label = UiStrings.EGRESS_DELETE_ADDRESS,
                onClick = onConfirm,
                tone = SessionActionTone.DANGER,
                enabled = canWrite,
                modifier = Modifier.testTag(UiPageTags.EGRESS_DELETE_CONFIRM),
            )
        },
        dismissButton = {
            SessionTextAction(
                label = UiStrings.CANCEL,
                onClick = onCancel,
                tone = SessionActionTone.SECONDARY,
                modifier = Modifier.testTag(UiPageTags.EGRESS_DELETE_CANCEL),
            )
        },
        shape = RoundedCornerShape(tokens.radius.card),
        containerColor = tokens.colors.input,
        titleContentColor = tokens.colors.primary,
        textContentColor = tokens.colors.secondary,
    )
}

/** The failure line: the host's message, a retry row and a dismiss row. */
@Composable
private fun EgressFailureBlock(
    failure: String?,
    onRetry: (() -> Unit)?,
    onDismissFailure: (() -> Unit)?,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        SettingsFormRow(
            title = UiStrings.EGRESS_FAILED,
            value = null,
            subtitle = failure,
            modifier = Modifier.testTag(UiPageTags.EGRESS_FAILURE),
        )
        if (onRetry != null) {
            SettingsFormRow(
                title = UiStrings.RETRY,
                value = null,
                onClick = onRetry,
                modifier = Modifier.testTag(UiPageTags.EGRESS_RETRY),
            )
        }
        if (onDismissFailure != null) {
            SettingsFormRow(
                title = UiStrings.DISMISS,
                value = null,
                onClick = onDismissFailure,
                modifier = Modifier.testTag(UiPageTags.EGRESS_DISMISS),
            )
        }
    }
}

/** The scrim of the add overlay: the page ink at a fixed opacity, as in ChatPage. */
private const val SCRIM_ALPHA: Float = 0.32f

private const val DETAIL_SEPARATOR: String = " · "

/** The fixed syntax explanation; the order is stable so the page is replayable. */
private val GRAMMAR_LINES: List<String> = listOf(
    UiStrings.EGRESS_GRAMMAR_EXACT,
    UiStrings.EGRESS_GRAMMAR_WILDCARD,
    UiStrings.EGRESS_GRAMMAR_ANY,
    UiStrings.EGRESS_GRAMMAR_PORT,
    UiStrings.EGRESS_GRAMMAR_EMPTY,
)

/** Every token this file reads; kept equal to the source by `PageTokenReferenceTest`. */
internal object EgressAllowListTokens {
    val refs: List<String> = listOf(
        "colors.accent",
        "colors.border",
        "colors.borderLight",
        "colors.input",
        "colors.switchOn",
        "colors.primary",
        "colors.secondary",
        "colors.tertiary",
        "colors.warning",
        "geometry.cardPadding",
        "geometry.pageOuterMarginH",
        "geometry.pageRowMinHeight",
        "radius.card",
        "spacing.badgeInsetV",
        "spacing.codeToolbar",
        "spacing.iconText",
        "typography.body",
        "typography.caption",
        "typography.code",
        "typography.headline",
        "typography.secondary",

    )
}
