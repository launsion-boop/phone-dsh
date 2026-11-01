// Model service and key configuration: per-service key state, never the key itself.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row ModelProviderSettingsPage (模型服务、密钥、
// 编解码; entries: 设置首行, 起手卡「去配置模型服务」, 启动失败横幅) and §3.1
// (the ScreenState layer). This page is P5 `must`.
//
// Security red line: a key, a token and a complete URL never reach the UI. The
// page cannot print a key even if a host hands one over:
//   * the only key-shaped input is [ProviderKeyFact.suffix], and [maskKeySuffix]
//     keeps at most the last four characters (a value shorter than eight
//     characters is refused rather than printed in full);
//   * [ProviderProfile.endpoint] is reduced to its host by
//     [redactEndpointHost]; scheme, credentials, path and query never render;
//   * a failure is a page-owned enum ([ProviderFailureReason]), not host text, so
//     a host error string cannot smuggle a key or a URL onto the screen.
//
// ScreenState: `ModelProviderScreenState.from(facts, local)` is pure. The data
// phases are shared with the other three P5 settings pages through
// [SettingsDataPhase]; the local events are the two disclosure folds the page
// owns (服务 / 说明). Same facts + same fold script ⇒ same state sequence, which
// the JVM test replays (§3.1).
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageRowMinHeight`); the list gap is the shared `pageListGap`.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames
import java.net.URI
import java.net.URISyntaxException

// ---------------------------------------------------------------------------
// Shared vocabulary of the four P5 settings pages
// ---------------------------------------------------------------------------

/**
 * The data phase of a settings-family page (model provider, web search, MCP
 * list and MCP editor).
 *
 * The four visible states are three phases plus [READY] with no rows:
 *  * [UNKNOWN]: no snapshot, or the host read nothing. The page says unknown and
 *    invents no value;
 *  * [READY] and empty: the host read the page and it has no rows;
 *  * [READY] with rows: data;
 *  * [FAILED]: the last read or save failed. The reason is a page-owned enum, so
 *    a host cannot inject a key, a token or a URL into the failure copy.
 *
 * This enum is shared by the four page files of this lane, so it has four users.
 * It lives here because the lane may add exactly four page files and
 * `PageScaffold.kt` belongs to another lane. When that four-file budget allows,
 * move it into a shared page file; until then this is its documented home.
 */
public enum class SettingsDataPhase {
    UNKNOWN,
    READY,
    FAILED,
}

/**
 * One settings toggle row: the row is the control (role Switch), its trailing
 * value is the state and [value] is also the accessibility state description.
 *
 * A disabled row is not drawn as a switch that silently does nothing: the host
 * pairs it with a [reason][WebSearchScreenState.reason] line, and [enabled] is
 * false only when the page can say why.
 *
 * Shared by the web-search page (the search switch) and the MCP editor (启用):
 * two users. It lives in this file for the same reason [SettingsDataPhase] does;
 * when the four-file budget allows, move both into the same shared page file.
 *
 * @param label the row label (from `UiStrings`).
 * @param value the visible state (已开启/已关闭/未知 or 已启用/已停用).
 * @param checked the switch position; only meaningful when [enabled].
 * @param enabled false renders the row disabled and adds the Disabled semantics.
 * @param onToggle the host persists the new value; the page never mutates facts.
 * @param tag a stable test tag.
 */
@Composable
internal fun SettingsToggleRow(
    label: String,
    value: String,
    checked: Boolean,
    enabled: Boolean,
    onToggle: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val ink = when {
        !enabled -> tokens.colors.tertiary
        checked -> tokens.colors.success
        else -> tokens.colors.tertiary
    }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            // Page-level geometry: a settings toggle is a page row.
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .then(
                if (enabled) {
                    Modifier.toggleable(value = checked, role = Role.Switch, onValueChange = onToggle)
                } else {
                    Modifier.semantics(mergeDescendants = true) { disabled() }
                },
            )
            .semantics { stateDescription = value }
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = label,
            style = type.body.copy(
                color = if (enabled) tokens.colors.primary else tokens.colors.tertiary,
            ),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = value,
            style = type.secondary.copy(color = ink),
        )
    }
}

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/** What the host knows about one service's stored key. */
public enum class ProviderKeyStatus {
    /** The host read the store and there is no key for this service. */
    NOT_CONFIGURED,

    /** A key is stored and was accepted the last time it was used. */
    CONFIGURED,

    /** A key is stored but the service rejected it (or the configuration is unusable). */
    INVALID,

    /** The host could not read the key state; this is 未知, never 未配置. */
    UNKNOWN,
}

/**
 * The host's key fact.
 *
 * @param status the three-way state plus the explicit unknown.
 * @param suffix the trailing characters the host wants shown. The page re-masks
 *   it through [maskKeySuffix], so even a host that passes a whole key can only
 *   ever contribute four characters.
 */
@Immutable
public data class ProviderKeyFact(
    public val status: ProviderKeyStatus = ProviderKeyStatus.UNKNOWN,
    public val suffix: String? = null,
)

/**
 * One configured model service.
 *
 * @param id the host's stable id (also the row's test tag suffix).
 * @param name the display name; blank falls back to the page's own label.
 * @param model the model name (not a secret).
 * @param endpoint a host name, or a URL the host happens to have. Only the host
 *   part is rendered ([redactEndpointHost]); a complete URL is never printed.
 * @param key the stored-key fact.
 * @param selected whether this is the service the engine will use.
 */
@Immutable
public data class ProviderProfile(
    public val id: String,
    public val name: String,
    public val model: String? = null,
    public val endpoint: String? = null,
    public val key: ProviderKeyFact = ProviderKeyFact(),
    public val selected: Boolean = false,
)

/** Why the page could not read or use the configuration; wording is page-owned. */
public enum class ProviderFailureReason {
    /** The non-secret configuration document could not be read. */
    CONFIG_UNREADABLE,

    /** The configuration was read but the device's key store could not be. */
    KEY_UNREADABLE,

    /** The host reported a failure without a category the page can name. */
    UNKNOWN,
}

/**
 * The page's read-only input.
 *
 * @param profiles the configured services; `null` means no snapshot was read at
 *   all and the page renders its unknown state. It is never treated as an empty
 *   list.
 * @param failure the last read failure, as a category.
 */
@Immutable
public data class ModelProviderFacts(
    public val profiles: List<ProviderProfile>? = null,
    public val failure: ProviderFailureReason? = null,
    /**
     * Whether the host can persist a service change. `NO` disables 添加 and the row
     * edit and prints [UiStrings.HOST_READ_ONLY_HINT].
     *
     * `UNKNOWN` is not `NO`: a host that did not report writability has not said
     * the page is read-only, and disabling on `UNKNOWN` would assert a negative
     * we do not know. Only an explicit `NO` disables — the same rule the page
     * follows when it renders 未知 instead of 0.
     */
    public val writable: FactState = FactState.UNKNOWN,
)

// ---------------------------------------------------------------------------
// Secret handling (pure, testable without Compose)
// ---------------------------------------------------------------------------

/**
 * Masks a key down to its last four characters.
 *
 * Returns `null` when there is nothing safe to show: an absent value, or a value
 * shorter than [KEY_MASK_MIN_LENGTH]. A four-character input is not echoed in
 * full, because "the last four of a four-character key" would be the key.
 *
 * This is the page's last line of defence: a host is supposed to pass a suffix,
 * but the function is correct even when it passes the whole key.
 */
public fun maskKeySuffix(raw: String?): String? {
    val text = raw?.trim().orEmpty()
    if (text.length < KEY_MASK_MIN_LENGTH) return null
    return text.takeLast(KEY_SUFFIX_LENGTH)
}

/**
 * Reduces an endpoint to a host (plus a port), or `null` when no safe host can be
 * read.
 *
 * Scheme, credentials, path and query are dropped; a non-HTTP scheme, an
 * authority the host grammar rejects, or embedded whitespace yields `null`, so
 * the page omits the line instead of printing something that is not a host.
 */
public fun redactEndpointHost(raw: String?): String? {
    val text = raw?.trim().orEmpty()
    if (text.isEmpty() || text.any { it.isWhitespace() }) return null
    val authority = if (text.contains("://")) {
        val uri = try {
            URI(text)
        } catch (_: URISyntaxException) {
            return null
        }
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        val host = uri.host ?: return null
        if (uri.port > 0) "$host:${uri.port}" else host
    } else {
        text.substringBefore('/').substringBefore('?').substringBefore('#')
    }
    val host = authority.substringAfterLast('@')
    if (host.isEmpty() || !HOST_PATTERN.matches(host)) return null
    return host
}

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/**
 * One visible service row.
 *
 * Every field is display-ready and contains no complete key: [keySuffixLabel] is
 * built from the masked suffix only, and [endpointLabel] from the redacted host.
 */
@Immutable
public data class ProviderRowView(
    public val id: String,
    public val name: String,
    public val selected: Boolean,
    public val keyValue: String,
    public val keyTone: PageTone,
    public val keyHint: String,
    public val keySuffixLabel: String?,
    public val modelLabel: String?,
    public val endpointLabel: String?,
)

/**
 * The complete model-provider screen state.
 *
 * @param phase the data phase; [READY] with no rows is the empty state.
 * @param rows one row per service, in host order.
 * @param failure the page-owned failure copy, or `null`.
 * @param servicesExpanded whether the service group is open.
 * @param helpExpanded whether the page's key/privacy help group is open.
 * @param canWrite false when the host reported the page is not writable; both the
 *   添加 action and the row edit are then rendered disabled, with the read-only
 *   line above the list.
 */
@Immutable
public data class ModelProviderScreenState(
    public val phase: SettingsDataPhase,
    public val rows: List<ProviderRowView> = emptyList(),
    public val failure: String? = null,
    public val servicesExpanded: Boolean = true,
    public val helpExpanded: Boolean = true,
    public val canWrite: Boolean = true,
) {
    /** The empty state: the host read the page and there is nothing in it. */
    public val isEmpty: Boolean get() = phase == SettingsDataPhase.READY && rows.isEmpty()

    /** No readable snapshot: the page says 未知 instead of 未配置. */
    public val isUnknown: Boolean get() = phase == SettingsDataPhase.UNKNOWN

    /** The last read failed; [failure] explains it. */
    public val isFailed: Boolean get() = phase == SettingsDataPhase.FAILED

    public companion object {
        /** Fold id of the service group. */
        public const val SERVICES_SECTION_ID: String = "provider.services"

        /** Fold id of the help group. */
        public const val HELP_SECTION_ID: String = "provider.help"

        /**
         * Projects (facts, fold script) into the screen state.
         *
         * Pure: no clock, no I/O, no engine. The same facts and the same script
         * always yield the same state sequence (§3.1).
         */
        public fun from(
            facts: ModelProviderFacts,
            local: ModelProviderLocalState = ModelProviderLocalState(),
        ): ModelProviderScreenState {
            val phase = when {
                facts.failure != null -> SettingsDataPhase.FAILED
                facts.profiles == null -> SettingsDataPhase.UNKNOWN
                else -> SettingsDataPhase.READY
            }
            return ModelProviderScreenState(
                phase = phase,
                rows = facts.profiles.orEmpty().map(::providerRow),
                failure = facts.failure?.text(),
                servicesExpanded = local.fold.isExpanded(SERVICES_SECTION_ID),
                helpExpanded = local.fold.isExpanded(HELP_SECTION_ID),
                canWrite = facts.writable != FactState.NO,
            )
        }

        private fun providerRow(profile: ProviderProfile): ProviderRowView {
            val status = profile.key.status
            val maskedSuffix = when (status) {
                // `ProviderKeyFact.suffix` is **already the last four characters** — the host masks
                // it before the page sees it. Re-masking looked safer but silently deleted the
                // label: `maskKeySuffix` returns null below eight characters, and a four-character
                // input is always below eight, so a configured key rendered no suffix at all.
                // Keep the guard for the case where a host sends more than four (a full key must
                // still become "9f3a"), but never let an already-masked value fall through.
                ProviderKeyStatus.CONFIGURED, ProviderKeyStatus.INVALID ->
                    profile.key.suffix?.let { maskKeySuffix(it) ?: it.takeLast(KEY_SUFFIX_LENGTH) }

                ProviderKeyStatus.NOT_CONFIGURED, ProviderKeyStatus.UNKNOWN -> null
            }
            return ProviderRowView(
                id = profile.id,
                name = profile.name.ifBlank { UiStrings.MODEL_PROVIDER_TITLE },
                selected = profile.selected,
                keyValue = status.value(),
                keyTone = status.tone(),
                keyHint = status.hint(),
                keySuffixLabel = maskedSuffix?.let { UiStrings.PROVIDER_KEY_SUFFIX.format(it) },
                modelLabel = profile.model?.takeIf { it.isNotBlank() }
                    ?.let { UiStrings.PROVIDER_MODEL.format(it) },
                endpointLabel = redactEndpointHost(profile.endpoint)
                    ?.let { UiStrings.PROVIDER_ENDPOINT.format(it) },
            )
        }

        private fun ProviderKeyStatus.value(): String = when (this) {
            ProviderKeyStatus.NOT_CONFIGURED -> UiStrings.NOT_CONFIGURED
            ProviderKeyStatus.CONFIGURED -> UiStrings.CONFIGURED
            ProviderKeyStatus.INVALID -> UiStrings.PROVIDER_KEY_INVALID
            ProviderKeyStatus.UNKNOWN -> UiStrings.UNKNOWN
        }

        private fun ProviderKeyStatus.tone(): PageTone = when (this) {
            ProviderKeyStatus.NOT_CONFIGURED -> PageTone.DEGRADED
            ProviderKeyStatus.CONFIGURED -> PageTone.ON
            ProviderKeyStatus.INVALID -> PageTone.DEGRADED
            ProviderKeyStatus.UNKNOWN -> PageTone.UNKNOWN
        }

        private fun ProviderKeyStatus.hint(): String = when (this) {
            ProviderKeyStatus.NOT_CONFIGURED -> UiStrings.PROVIDER_KEY_NOT_CONFIGURED_HINT
            ProviderKeyStatus.CONFIGURED -> UiStrings.PROVIDER_KEY_CONFIGURED_HINT
            ProviderKeyStatus.INVALID -> UiStrings.PROVIDER_KEY_INVALID_HINT
            ProviderKeyStatus.UNKNOWN -> UiStrings.SETTINGS_UNKNOWN_HINT
        }

        private fun ProviderFailureReason.text(): String = when (this) {
            ProviderFailureReason.CONFIG_UNREADABLE -> UiStrings.PROVIDER_FAILURE_CONFIG
            ProviderFailureReason.KEY_UNREADABLE -> UiStrings.PROVIDER_FAILURE_KEY
            ProviderFailureReason.UNKNOWN -> UiStrings.PROVIDER_FAILURE_UNKNOWN
        }
    }
}

/** The local UI events of the model-provider page: only the two folds. */
public sealed interface ModelProviderUiEvent {
    /** Collapse or expand one of the page's groups. */
    public data class ToggleSection(public val id: String) : ModelProviderUiEvent
}

/** The fold script; [apply] is pure, so a test drives it like a reducer. */
@Immutable
public data class ModelProviderLocalState(public val fold: FoldState = FoldState()) {
    /** Applies one local event. */
    public fun apply(event: ModelProviderUiEvent): ModelProviderLocalState = when (event) {
        is ModelProviderUiEvent.ToggleSection -> copy(fold = fold.toggle(event.id))
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The model-provider settings screen.
 *
 * @param state the pure screen state ([ModelProviderScreenState.from]).
 * @param onAdd open the editor for a new service.
 * @param onEdit open the editor for an existing service, by id. The page passes
 *   an id rather than the host object: the screen state never carries a raw key
 *   or URL, so a handler resolves the profile from the facts it already holds.
 * @param onToggleSection a group header was tapped; the host applies
 *   `ModelProviderUiEvent.ToggleSection` and re-projects.
 * @param onRetry retry a failed read.
 * @param onBack leave the page.
 */
@Composable
public fun ModelProviderSettingsPage(
    state: ModelProviderScreenState,
    onAdd: () -> Unit,
    onEdit: (String) -> Unit,
    onToggleSection: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
) {
    PageFrame(
        title = UiStrings.MODEL_PROVIDER_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.PROVIDER_ROOT,
        modifier = modifier,
        actions = {
            SessionTextAction(
                label = UiStrings.PROVIDER_ADD,
                onClick = onAdd,
                tone = SessionActionTone.ACCENT,
                modifier = Modifier.testTag(UiPageTags.PROVIDER_ADD),
                enabled = state.canWrite,
            )
        },
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            if (state.failure != null) {
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.PROVIDER_FAILURE,
                    retryLabel = UiStrings.RETRY,
                    onRetry = onRetry,
                )
            }
            when {
                state.isUnknown -> EmptyHint(
                    title = UiStrings.PROVIDER_UNKNOWN_STATE,
                    hint = UiStrings.PROVIDER_UNKNOWN_HINT,
                    tag = UiPageTags.PROVIDER_UNKNOWN,
                )

                state.isFailed && state.rows.isEmpty() -> Unit

                state.isEmpty -> EmptyHint(
                    title = UiStrings.PROVIDER_EMPTY,
                    hint = UiStrings.PROVIDER_EMPTY_HINT,
                    tag = UiPageTags.PROVIDER_EMPTY,
                )

                else -> LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag(UiPageTags.PROVIDER_LIST),
                    verticalArrangement = Arrangement.spacedBy(pageListGap),
                ) {
                    if (!state.canWrite) {
                        item(key = "read-only") {
                            ReadOnlyHint(tag = UiPageTags.PROVIDER_FAILURE + ".read-only")
                        }
                    }
                    item(key = "header.services") {
                        SectionHeader(
                            title = UiStrings.PROVIDER_SERVICES,
                            expanded = state.servicesExpanded,
                            onToggle = { onToggleSection(ModelProviderScreenState.SERVICES_SECTION_ID) },
                            trailing = UiStrings.ROW_COUNT.format(state.rows.size),
                            tag = UiPageTags.PROVIDER_SERVICES_SECTION,
                        )
                    }
                    if (state.servicesExpanded) {
                        items(
                            count = state.rows.size,
                            key = { index -> "row.${state.rows[index].id}" },
                        ) { index ->
                            val row = state.rows[index]
                            ProviderRow(
                                row = row,
                                onEdit = if (state.canWrite) { { onEdit(row.id) } } else null,
                            )
                        }
                    }
                    item(key = "header.help") {
                        SectionHeader(
                            title = UiStrings.PROVIDER_HELP,
                            expanded = state.helpExpanded,
                            onToggle = { onToggleSection(ModelProviderScreenState.HELP_SECTION_ID) },
                            tag = UiPageTags.PROVIDER_HELP_SECTION,
                        )
                    }
                    if (state.helpExpanded) {
                        item(key = "help.privacy") {
                            InfoRow(title = UiStrings.PROVIDER_PRIVACY, value = null)
                        }
                        item(key = "help.effect") {
                            InfoRow(title = UiStrings.PROVIDER_EFFECT, value = null)
                        }
                    }
                }
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

/** One service: name + key state on the first line, supporting lines below. */
@Composable
private fun ProviderRow(
    row: ProviderRowView,
    onEdit: (() -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.PROVIDER_ROW_PREFIX + row.id)
            .then(
                if (onEdit != null) {
                    Modifier.clickable(role = Role.Button, onClick = onEdit)
                } else {
                    Modifier
                },
            )
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
                    text = UiStrings.PROVIDER_DEFAULT,
                    style = type.caption.copy(color = tokens.colors.accent),
                )
            }
            BasicText(
                text = row.keyValue,
                style = type.secondary.copy(color = row.keyTone.ink(tokens)),
            )
        }
        row.modelLabel?.let { label ->
            BasicText(
                text = label,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
        row.endpointLabel?.let { label ->
            BasicText(
                text = label,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
        row.keySuffixLabel?.let { label ->
            BasicText(
                text = label,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
        BasicText(
            text = row.keyHint,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
    }
}

/** Four is the only suffix the page ever shows. */
private const val KEY_SUFFIX_LENGTH: Int = 4

/** Below this length, "the last four" would be the whole value. */
private const val KEY_MASK_MIN_LENGTH: Int = 8

/** A host name, a dotted name or an IPv4 address, with an optional port. */
private val HOST_PATTERN: Regex = Regex("""^[A-Za-z0-9](?:[A-Za-z0-9.\-]*[A-Za-z0-9])?(?::\d{1,5})?$""")

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest`'s page map is owned by the session-pages lane; this
 * declaration is the entry that table adds for this file. The equality there is
 * "declared == what the source reads", so the typography roles this file names
 * are part of the list together with the value tokens.
 */
internal object ModelProviderSettingsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
    )
}
