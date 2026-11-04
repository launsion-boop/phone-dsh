// Model service and key configuration: per-service key state, never the key itself.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row ModelProviderSettingsPage (模型服务、密钥、
// 编解码) and §3.1 (the ScreenState layer). P5 `must`. Structure: the contract
// `spec/ui/v1/pages/model-provider-settings.json`, regenerated from the iOS HEAD
// `86a39aac` (PR #13): 服务 / the untitled action group / 生效方式, plus the
// editor's 模型目录 / 密钥 (a subpage of the same contract).
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
// phases are shared with the other P5 settings pages through
// [SettingsDataPhase]; the only local event is the 服务 fold the page owns. Same
// facts + same fold script ⇒ same state sequence, which the JVM test replays
// (§3.1). The editor's draft ([ProviderDraft]) is page-local view state, exactly
// like the fold: it never holds a stored key, and the stored endpoint is a host
// fact the page does not read (an existing service's editor therefore starts
// with an empty URL field, and an empty field means "keep what the host has").
//
// Fixed vs data copy: a contract section title or action label is a literal
// call-site argument (`UiStrings.*`), which is what `page_structure_check.py`
// reads. A row whose label is host data (a service's display name) declares no
// fixed label — except the one case where the page's own label *is* the visible
// title: a service the host never named wears 模型服务, and that row's action
// carries it. This is the same split ChatPreferencesPage documents.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageRowMinHeight`); the list gap is the shared `pageListGap`.
package com.phonedsh.ui.page

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Switch
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.password
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.BACK_GLYPH
import com.phonedsh.ui.nav.PdshBackLevel
import com.phonedsh.ui.nav.RouteBackLevel
import com.phonedsh.ui.surface.SettingsHairline
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsNavAction
import com.phonedsh.ui.surface.settingsFootnoteStyle
import com.phonedsh.ui.surface.settingsLabelStyle
import com.phonedsh.ui.surface.settingsValueStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.materialDialogColors
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
 * A disabled row is not drawn as a switch that silently does nothing; the host
 * pairs it with a reason line, and [enabled] is false only when the page can say
 * why.
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
 * @param selected whether this is the stored default for the next process launch.
 * @param active whether this profile is the service captured by the current process.
 */
@Immutable
public data class ProviderProfile(
    public val id: String,
    public val name: String,
    public val model: String? = null,
    public val endpoint: String? = null,
    public val key: ProviderKeyFact = ProviderKeyFact(),
    public val selected: Boolean = false,
    public val reasoningEffort: String? = null,
    public val models: List<ProviderModelDraft> = emptyList(),
    public val credentialRef: String? = null,
    public val active: Boolean? = null,
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
 * @param engineStarted whether the local engine runs, i.e. whether a saved
 *   change is already in effect. `UNKNOWN` keeps the 启动本地引擎 action: the page
 *   cannot tell whether the engine runs, so it offers the action that is safe
 *   either way instead of hiding it behind a guess.
 * @param writable whether the host can persist a service change. `NO` disables
 *   the row actions and prints [UiStrings.HOST_READ_ONLY_HINT].
 *
 * `UNKNOWN` is not `NO`: a host that did not report writability has not said
 * the page is read-only, and disabling on `UNKNOWN` would assert a negative
 * we do not know. Only an explicit `NO` disables — the same rule the page
 * follows when it renders 未知 instead of 0.
 */
@Immutable
public data class ModelProviderFacts(
    public val profiles: List<ProviderProfile>? = null,
    public val failure: ProviderFailureReason? = null,
    public val engineStarted: FactState = FactState.UNKNOWN,
    public val writable: FactState = FactState.UNKNOWN,
    /** Last test for the currently edited profile; contains no endpoint or key. */
    public val connectionTest: ProviderConnectionTestFact? = null,
    public val providerSave: ProviderSaveFact? = null,
    /** Request-bound model catalog result; contains model ids only. */
    public val catalog: ProviderCatalogFact? = null,
)

/** A real /models read, correlated to the editor request and profile that started it. */
@Immutable
public data class ProviderCatalogFact(
    public val requestId: String,
    public val profileId: String?,
    public val isNew: Boolean,
    public val isLoading: Boolean,
    public val models: List<String>? = null,
    public val message: String? = null,
)

/** A connection-test lifecycle/result, correlated by non-secret profile identity. */
@Immutable
public data class ProviderConnectionTestFact(
    public val profileId: String,
    public val isNew: Boolean,
    public val isTesting: Boolean,
    public val succeeded: Boolean? = null,
    public val message: String? = null,
)

/** Save progress/result for a form submission; request ID prevents stale success from closing a new editor. */
@Immutable
public data class ProviderSaveFact(
    public val requestId: String,
    public val profileId: String,
    public val isNew: Boolean,
    public val isSaving: Boolean,
    public val succeeded: Boolean? = null,
    public val message: String? = null,
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
 *
 * @param nameIsFallback true when the host gave no display name, so [name] is
 *   the page's own label (`模型服务`). The view renders that label as the row's
 *   title *and* as its action label; a named row carries no fixed label.
 * @param model the raw model id (not a secret), used to seed the editor draft.
 */
@Immutable
public data class ProviderRowView(
    public val id: String,
    public val name: String,
    public val nameIsFallback: Boolean,
    public val selected: Boolean,
    public val keyStatus: ProviderKeyStatus,
    public val keyValue: String,
    public val keyTone: PageTone,
    public val keyHint: String,
    public val model: String?,
    public val keySuffixLabel: String?,
    public val modelLabel: String?,
    public val endpointLabel: String?,
    public val reasoningEffort: String? = null,
    public val models: List<ProviderModelDraft> = emptyList(),
    public val credentialRef: String? = null,
    public val active: Boolean? = null,
)

/**
 * The complete model-provider screen state.
 *
 * @param phase the data phase; [READY] with no rows is the empty state.
 * @param rows one row per service, in host order.
 * @param failure the page-owned failure copy, or `null`.
 * @param servicesExpanded whether the 服务 group is open.
 * @param canWrite false when the host reported the page is not writable; the
 *   row actions and the add/edit rows are then rendered disabled.
 * @param engineStarted true/false when the host reported it; `UNKNOWN` still
 *   offers 启动本地引擎.
 * @param restartHint the 生效方式 sentence, chosen from [engineStarted].
 */
@Immutable
public data class ModelProviderScreenState(
    public val phase: SettingsDataPhase,
    public val rows: List<ProviderRowView> = emptyList(),
    public val failure: String? = null,
    public val servicesExpanded: Boolean = true,
    public val canWrite: Boolean = true,
    public val engineStarted: FactState = FactState.UNKNOWN,
    public val restartHint: String = PROVIDER_APPLY_HINT_STOPPED,
    public val connectionTest: ProviderConnectionTestFact? = null,
    public val providerSave: ProviderSaveFact? = null,
    public val catalog: ProviderCatalogFact? = null,
) {
    /** The empty state: the host read the page and there is nothing in it. */
    public val isEmpty: Boolean get() = phase == SettingsDataPhase.READY && rows.isEmpty()

    /** No readable snapshot: the page says 未知 instead of 未配置. */
    public val isUnknown: Boolean get() = phase == SettingsDataPhase.UNKNOWN

    /** The last read failed; [failure] explains it. */
    public val isFailed: Boolean get() = phase == SettingsDataPhase.FAILED

    /** The service the engine would use, if the host named one. */
    public val selected: ProviderRowView? get() = rows.firstOrNull { it.selected }

    /** The start action is offered unless the host said the engine already runs. */
    public val canStartEngine: Boolean get() = engineStarted != FactState.YES

    public companion object {
        /** Fold id of the 服务 group. */
        public const val SERVICES_SECTION_ID: String = "provider.services"

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
                canWrite = facts.writable != FactState.NO,
                engineStarted = facts.engineStarted,
                restartHint = if (facts.engineStarted == FactState.YES) {
                    PROVIDER_APPLY_HINT_RUNNING
                } else {
                    PROVIDER_APPLY_HINT_STOPPED
                },
                connectionTest = facts.connectionTest,
                providerSave = facts.providerSave,
                catalog = facts.catalog,
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
            val unnamed = profile.name.isBlank()
            return ProviderRowView(
                id = profile.id,
                name = if (unnamed) UiStrings.MODEL_PROVIDER_TITLE else profile.name,
                nameIsFallback = unnamed,
                selected = profile.selected,
                keyStatus = status,
                keyValue = status.value(),
                keyTone = status.tone(),
                keyHint = status.hint(),
                model = profile.model?.takeIf { it.isNotBlank() },
                keySuffixLabel = maskedSuffix?.let { UiStrings.PROVIDER_KEY_SUFFIX.format(it) },
                modelLabel = profile.model?.takeIf { it.isNotBlank() }
                    ?.let { UiStrings.PROVIDER_MODEL.format(it) },
                endpointLabel = redactEndpointHost(profile.endpoint)
                    ?.let { UiStrings.PROVIDER_ENDPOINT.format(it) },
                reasoningEffort = profile.reasoningEffort,
                models = profile.models,
                credentialRef = profile.credentialRef,
                active = profile.active,
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

// ---------------------------------------------------------------------------
// The editor's draft (page-local view state, never facts)
// ---------------------------------------------------------------------------

/** One entry of the editor's 模型目录. */
@Immutable
public data class ProviderModelDraft(
    public val id: String = "",
    public val name: String? = null,
    public val contextWindow: Int? = null,
    public val maxTokens: Int? = null,
    public val textInput: Boolean = true,
    public val imageInput: Boolean = false,
    public val reasoningEffort: String? = null,
)

/** A picker row keeps the wire value separate from its localized title. */
private data class ProviderPickerOption(val id: String, val label: String)

/**
 * The editor's draft: the fields the user is editing, and the only place a typed
 * key ever lives.
 *
 * @param apiKey the key the user typed or imported. It is *not* a fact: the page
 *   never reads a stored key into it, and the host is the only one that persists
 *   it.
 * @param removeStoredKey the 删除已保存的密钥 toggle.
 * @param isNew a new service: its identifier may still be generated by the host.
 */
@Immutable
public data class ProviderDraft(
    public val id: String = "",
    public val name: String = "",
    public val endpoint: String = "",
    public val model: String = "",
    public val reasoningEffort: String? = null,
    public val models: List<ProviderModelDraft> = emptyList(),
    public val apiKey: String = "",
    public val removeStoredKey: Boolean = false,
    public val isNew: Boolean = true,
) {
    /**
     * A draft can be saved when the service has a display name, and — for a new
     * service — a URL. An existing service's URL lives on the host, so an empty
     * field there means "keep the stored one".
     */
    public val modelValidationError: String?
        get() {
            if (models.isEmpty()) return "至少添加一个模型。"
            val ids = models.map { it.id.trim() }
            if (ids.any(String::isEmpty)) return "模型 ID 不能为空。"
            if (ids.distinct().size != ids.size) return "模型 ID 不能重复。"
            if (models.any { !it.textInput && !it.imageInput }) return "每个模型至少保留文本或图片一种输入类型。"
            if (models.any { (it.contextWindow != null && it.contextWindow <= 0) || (it.maxTokens != null && it.maxTokens <= 0) }) {
                return "上下文窗口和最大输出必须是正整数。"
            }
            return null
        }

    public val canSave: Boolean get() = name.isNotBlank() && (endpoint.isNotBlank() || !isNew) && model.isNotBlank() && modelValidationError == null

    /** The protocol the URL selects, said out loud so nobody has to guess. */
    public val protocolHint: String get() = if (endpoint.lowercase().contains("/anthropic")) {
        UiStrings.PROVIDER_PROTOCOL_ANTHROPIC
    } else {
        UiStrings.PROVIDER_PROTOCOL_OPENAI
    }

    public companion object {
        /** A new service, pre-filled with the adapter's documented defaults. */
        public fun new(): ProviderDraft = ProviderDraft(
            endpoint = DEFAULT_ENDPOINT,
            model = DEFAULT_MODEL,
            models = listOf(ProviderModelDraft(id = DEFAULT_MODEL)),
            isNew = true,
        )

        /**
         * The editor state for an existing row. The endpoint is deliberately
         * empty: the page never holds a complete URL, so the host keeps it.
         */
        public fun from(row: ProviderRowView): ProviderDraft = ProviderDraft(
            id = row.id,
            name = if (row.nameIsFallback) "" else row.name,
            model = row.model.orEmpty(),
            reasoningEffort = row.reasoningEffort,
            models = row.models.ifEmpty { listOf(ProviderModelDraft(id = row.model.orEmpty())) },
            isNew = false,
        )

        /** The hosted adapter's default; a service URL, never a key. */
        public const val DEFAULT_ENDPOINT: String = "https://api.deepseek.com/anthropic"

        /** The model the adapter advertises as its default. */
        public const val DEFAULT_MODEL: String = "deepseek-flash"
    }
}

/** The local UI events of the model-provider page: only the 服务 fold. */
public sealed interface ModelProviderUiEvent {
    /** Collapse or expand the 服务 group. */
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
 * @param onAdd the editor was opened for a new service; the host may take over.
 * @param onEdit the editor was opened for an existing service, by id.
 * @param onToggleSection kept for the settings sheet's call site. The baseline's
 *   服务 header is a plain label with no disclosure
 *   (`ModelProviderSettingsPage.swift:85-86`), so this page draws no fold.
 * @param onBack leave the page.
 * @param onRetry retry a failed read (the failure line's leading glyph; the
 *   contract declares no retry *label* for this page).
 * @param onStartEngine 启动本地引擎 was tapped.
 * @param onSave the editor's 保存 was tapped; the draft carries the typed key.
 * @param onTest the editor's 测试 was tapped.
 * @param onDelete a service was confirmed for deletion, by id.
 */
@Suppress("UNUSED_PARAMETER")
@Composable
public fun ModelProviderSettingsPage(
    state: ModelProviderScreenState,
    onAdd: () -> Unit,
    onEdit: (String) -> Unit,
    onToggleSection: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    embedded: Boolean = false,
    onSelect: (String) -> Unit = {},
    onStartEngine: () -> Unit = {},
    onSave: (ProviderDraft, String) -> Unit = { _, _ -> },
    onTest: (ProviderDraft) -> Unit = {},
    onDelete: (String) -> Unit = {},
    onGetModels: (ProviderDraft, String) -> Unit = { _, _ -> },
    /** Existing route back chain; editor and advanced pages consume one inner level each. */
    backLevel: PdshBackLevel? = null,
) {
    val tokens = LocalUiTokens.current
    val dialogPalette = materialDialogColors(tokens)
    var draft by remember { mutableStateOf<ProviderDraft?>(null) }
    var pendingDelete by remember { mutableStateOf<ProviderRowView?>(null) }
    var saveRequestId by remember { mutableStateOf<String?>(null) }
    var catalogRequestId by remember { mutableStateOf<String?>(null) }
    var advanced by remember { mutableStateOf(false) }
    var appliedCatalogRequestId by remember { mutableStateOf<String?>(null) }
    val editing = draft
    val editingCatalog = editing?.let { current ->
        state.catalog?.takeIf {
            it.requestId == catalogRequestId &&
                it.profileId == current.id.takeIf(String::isNotBlank) &&
                it.isNew == current.isNew
        }
    }
    LaunchedEffect(editingCatalog?.requestId, editingCatalog?.isLoading, editingCatalog?.models) {
        val current = editing ?: return@LaunchedEffect
        val fact = editingCatalog ?: return@LaunchedEffect
        val ids = fact.models ?: return@LaunchedEffect
        if (fact.isLoading || fact.requestId == appliedCatalogRequestId) return@LaunchedEffect
        appliedCatalogRequestId = fact.requestId
        val merged = ids.map { id ->
            current.models.firstOrNull { it.id == id } ?: ProviderModelDraft(id = id)
        }
        val selected = current.model.takeIf { it in ids } ?: ids.firstOrNull().orEmpty()
        draft = current.copy(models = merged, model = selected)
    }
    val saveFact = editing?.let { current ->
        state.providerSave?.takeIf {
            it.requestId == saveRequestId && it.isNew == current.isNew &&
                (current.isNew || it.profileId == current.id)
        }
    }
    val cancelEditor: () -> Unit = {
        draft = null
        saveRequestId = null
        catalogRequestId = null
        advanced = false
    }
    val leaveEditorLevel: () -> Unit = {
        if (advanced) advanced = false else cancelEditor()
    }
    val submitEditor: () -> Unit = {
        editing?.let { current ->
            val requestId = java.util.UUID.randomUUID().toString()
            saveRequestId = requestId
            onSave(current, requestId)
        }
    }
    val editorMain = editing != null && !advanced
    val editorBusy = saveFact?.isSaving == true
    RouteBackLevel(backLevel, enabled = editing != null) { leaveEditorLevel() }
    LaunchedEffect(editing?.id, editing?.isNew, saveFact?.requestId, saveFact?.isSaving, saveFact?.succeeded) {
        if (saveFact?.succeeded == true && !saveFact.isSaving) {
            draft = null
            saveRequestId = null
        }
    }

    SettingsSubPageFrame(
        // The source page, editor and advanced page all use inline navigation
        // titles; no 34pt large-title scaffold belongs to this NavigationStack.
        title = when {
            editing != null && advanced -> UiStrings.PROVIDER_ADVANCED
            editing != null && editing.isNew -> UiStrings.PROVIDER_ADD_SERVICE
            editing != null -> UiStrings.PROVIDER_EDITOR_EDIT_TITLE
            embedded -> null
            else -> UiStrings.MODEL_PROVIDER_TITLE
        },
        largeTitle = null,
        backGlyph = if (editorMain) UiStrings.CANCEL else BACK_GLYPH,
        embedded = embedded && editing == null,
        onBack = when {
            editorMain -> cancelEditor
            editing != null -> leaveEditorLevel
            else -> onBack
        },
        trailing = if (editorMain) {
            {
                SettingsNavAction(
                    text = UiStrings.SAVE,
                    onClick = submitEditor,
                    enabled = editing?.canSave == true && !editorBusy,
                )
            }
        } else null,
        rootTag = UiPageTags.PROVIDER_ROOT,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            if (state.failure != null) {
                SessionFailureLine(
                    message = state.failure,
                    tag = UiPageTags.PROVIDER_FAILURE,
                    // The contract declares no retry label for this page; the
                    // affordance is the glyph, so the read can still be retried.
                    retryLabel = if (onRetry != null) RETRY_GLYPH else null,
                    onRetry = onRetry,
                )
            }
            if (editing != null && advanced) {
                ProviderAdvancedEditor(
                    draft = editing,
                    keyStatus = state.rows.firstOrNull { it.id == editing.id }?.keyStatus
                        ?: ProviderKeyStatus.NOT_CONFIGURED,
                    connectionTest = state.connectionTest?.takeIf {
                        it.isNew == editing.isNew && (editing.isNew || it.profileId == editing.id)
                    },
                    onDraftChange = { draft = it },
                    onTest = { onTest(editing) },
                )
            } else if (editing != null) {
                ProviderEditor(
                    draft = editing,
                    keyStatus = state.rows.firstOrNull { it.id == editing.id }?.keyStatus
                        ?: ProviderKeyStatus.NOT_CONFIGURED,
                    connectionTest = state.connectionTest?.takeIf {
                        it.isNew == editing.isNew && (editing.isNew || it.profileId == editing.id)
                    },
                    catalog = editingCatalog,
                    saveFact = saveFact,
                    onDraftChange = { draft = it },
                    onGetModels = {
                        val requestId = java.util.UUID.randomUUID().toString()
                        catalogRequestId = requestId
                        appliedCatalogRequestId = null
                        onGetModels(editing, requestId)
                    },
                    onOpenAdvanced = { advanced = true },
                )
            } else if (state.isUnknown) {
                EmptyHint(
                    title = UiStrings.PROVIDER_UNKNOWN_STATE,
                    hint = UiStrings.PROVIDER_UNKNOWN_HINT,
                    tag = UiPageTags.PROVIDER_UNKNOWN,
                )
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag(UiPageTags.PROVIDER_LIST),
                    verticalArrangement = Arrangement.Top,
                ) {
                    serviceGroup(
                        state = state,
                        onStartEngine = onStartEngine,
                        onOpenNew = {
                            draft = ProviderDraft.new()
                            advanced = false
                            catalogRequestId = null
                            appliedCatalogRequestId = null
                            onAdd()
                        },
                        onOpen = { row ->
                            draft = ProviderDraft.from(row)
                            advanced = false
                            catalogRequestId = null
                            appliedCatalogRequestId = null
                            onEdit(row.id)
                        },
                        onSelect = onSelect,
                        onDeleteRequest = { pendingDelete = it },
                    )
                }
            }
        }
        pendingDelete?.let { row ->
            AlertDialog(
                onDismissRequest = { pendingDelete = null },
                title = { Text(UiStrings.PROVIDER_DELETE_CONFIRM_TITLE) },
                text = { Text(UiStrings.PROVIDER_DELETE_CONFIRM_TEXT) },
                confirmButton = {
                    TextButton(
                        onClick = {
                            pendingDelete = null
                            onDelete(row.id)
                        },
                    ) {
                        Text(UiStrings.PROVIDER_DELETE_NAMED.format(row.name))
                    }
                },
                dismissButton = {
                    TextButton(onClick = { pendingDelete = null }) {
                        Text(UiStrings.CANCEL)
                    }
                },
                containerColor = dialogPalette.container,
                textContentColor = dialogPalette.content,
            )
        }
    }
}

/**
 * The 服务 group, the contract's untitled action group, and 生效方式.
 *
 * Order is the baseline's: services, then the two actions, then when a change
 * applies. The action group has no header of its own in the contract, so its
 * first row (`添加模型服务`) is what identifies it.
 */
private fun LazyListScope.serviceGroup(
    state: ModelProviderScreenState,
    onStartEngine: () -> Unit,
    onOpenNew: () -> Unit,
    onOpen: (ProviderRowView) -> Unit,
    onSelect: (String) -> Unit,
    onDeleteRequest: (ProviderRowView) -> Unit,
) {
    item(key = "header.services") {
        // The baseline's header is a plain `Text("服务")` on a Section
        // (`ModelProviderSettingsPage.swift:85-86`): no disclosure, no count. The
        // Android fold and its `1 项` were the extra control the parity sheet
        // flagged, so the header is a label now — and because there is no fold,
        // the rows below are always drawn.
        SettingsSectionLabel(
            title = UiStrings.PROVIDER_SERVICES,
            modifier = Modifier.testTag(UiPageTags.PROVIDER_SERVICES_SECTION),
        )
    }
    run {
        if (state.rows.isEmpty()) {
            item(key = "services.empty") {
                EmptyHint(
                    title = UiStrings.PROVIDER_EMPTY,
                    hint = UiStrings.PROVIDER_EMPTY_HINT,
                    tag = UiPageTags.PROVIDER_EMPTY,
                )
            }
        }
        items(items = state.rows, key = { row -> "row.${row.id}" }) { row ->
            ProviderServiceRow(
                row = row,
                canWrite = state.canWrite,
                onOpen = { onOpen(row) },
                onSelect = { onSelect(row.id) },
                onDelete = { onDeleteRequest(row) },
            )
        }
        item(key = "services.footer") {
            ProviderFooterLine(text = UiStrings.PROVIDER_EFFECT)
        }
    }
    item(key = "actions.add") {
        ProviderRowAction(
            label = UiStrings.PROVIDER_ADD_SERVICE,
            onClick = onOpenNew,
            enabled = state.canWrite,
            tag = UiPageTags.PROVIDER_ADD,
        )
    }
    if (state.selected != null) {
        item(key = "actions.edit-default") {
            ProviderRowAction(
                label = UiStrings.PROVIDER_EDIT_DEFAULT,
                onClick = { state.selected?.let(onOpen) },
                enabled = state.canWrite,
            )
        }
    }
    item(key = "apply.hint") {
        ProviderFooterLine(text = state.restartHint)
    }
    if (state.canStartEngine) {
        item(key = "apply.start") {
            SessionTextAction(
                label = UiStrings.PROVIDER_START_ENGINE,
                onClick = onStartEngine,
                tone = SessionActionTone.ACCENT,
            )
        }
    }
}

/** One service: name + key state on the first line, supporting lines below. */
@Composable
private fun ProviderServiceRow(
    row: ProviderRowView,
    canWrite: Boolean,
    onOpen: () -> Unit,
    onSelect: () -> Unit,
    onDelete: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.PROVIDER_ROW_PREFIX + row.id)
            .clickable(enabled = canWrite, role = Role.Button, onClick = onSelect)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            // The row's title is the host's name. A service the host never named
            // wears the page's own label — and only that case declares a fixed
            // label for this row, because only that case shows one.
            if (row.nameIsFallback) {
                BasicText(
                    text = UiStrings.MODEL_PROVIDER_TITLE,
                    style = settingsLabelStyle().copy(color = tokens.colors.primary),
                    modifier = Modifier.weight(1f).clickable(role = Role.Button, onClick = onSelect),
                )
            } else {
                BasicText(
                    text = row.name,
                    style = settingsLabelStyle().copy(color = tokens.colors.primary),
                    modifier = Modifier.weight(1f).clickable(role = Role.Button, onClick = onSelect),
                )
            }
            if (row.selected) {
                BasicText(
                    text = if (row.active == true) UiStrings.PROVIDER_DEFAULT else PROVIDER_NEXT_LAUNCH_DEFAULT,
                    style = settingsFootnoteStyle().copy(color = tokens.colors.accent),
                )
            }
            BasicText(
                text = row.keyValue,
                style = settingsFootnoteStyle().copy(color = row.keyTone.ink(tokens)),
            )
            // The baseline marks the engine's service with `checkmark.circle.fill`
            // tinted with the accent (`ModelProviderSettingsPage.swift:129-132`) —
            // a filled circle with a check in it, not a word. It is drawn rather
            // than typed so the mark cannot contribute a font line box to the row.
            if (row.active == true) {
                SelectedServiceMark()
            }
        }
        row.modelLabel?.let { label ->
            val effort = row.reasoningEffort?.let(::providerEffortLabel)
            ProviderFooterLine(text = if (effort != null) "$label · $effort" else label)
        }
        row.endpointLabel?.let { label -> ProviderFooterLine(text = label) }
        row.keySuffixLabel?.let { label -> ProviderFooterLine(text = label) }
        ProviderFooterLine(text = row.keyHint)
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            SessionTextAction(
                label = UiStrings.PROVIDER_EDIT,
                onClick = onOpen,
                tone = SessionActionTone.ACCENT,
                enabled = canWrite,
            )
            SessionTextAction(
                label = UiStrings.PROVIDER_DELETE,
                onClick = onDelete,
                tone = SessionActionTone.DANGER,
                // iOS omits delete when the key cannot be read, so a destructive
                // action can never erase a credential it could not inspect.
                enabled = canWrite && row.keyStatus != ProviderKeyStatus.UNKNOWN,
            )
        }
    }
}

/**
 * The 默认 service's mark: an accent-filled circle with a white check, sized from
 * the row label's own font so no bare length enters this file.
 *
 * `ModelProviderSettingsPage.swift:129-132`:
 * `Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)`.
 */
@Composable
private fun SelectedServiceMark() {
    val tokens = LocalUiTokens.current
    val diameter = with(LocalDensity.current) { settingsLabelStyle().fontSize.toDp() }
    Canvas(modifier = Modifier.size(diameter)) {
        drawCircle(color = tokens.colors.accent)
        // The glyph's two strokes, in the circle's own coordinate space: a check
        // from the left third down to the bottom third, then up to the right.
        val strokeWidth = size.minDimension * CHECK_STROKE_RATIO
        drawLine(
            color = tokens.colors.input,
            start = Offset(size.width * 0.28f, size.height * 0.52f),
            end = Offset(size.width * 0.44f, size.height * 0.68f),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tokens.colors.input,
            start = Offset(size.width * 0.44f, size.height * 0.68f),
            end = Offset(size.width * 0.72f, size.height * 0.36f),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round,
        )
    }
}

/** The check's stroke, as a fraction of the mark's diameter. */
private const val CHECK_STROKE_RATIO: Float = 0.11f

/** A 13 pt secondary line in the sub-page's footnote rhythm. */
@Composable
private fun ProviderFooterLine(text: String) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        style = settingsFootnoteStyle().copy(color = tokens.colors.secondary),
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/**
 * A settings row that is a page action (`添加模型服务` / `编辑默认服务`).
 *
 * The whole row is the tap target and [label] is its visible text, so this is
 * the page's own button wrapper: a call site passes a fixed `UiStrings` label.
 */
@Composable
private fun ProviderRowAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    tag: String? = null,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
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
                color = if (enabled) tokens.colors.accent else tokens.colors.tertiary,
            ),
        )
    }
}

/**
 * A labelled switch row.
 *
 * The whole row is the control and [label] is its visible text, so a call site
 * passes a fixed `UiStrings` label (the page's own wrapper idiom). The switch
 * itself is drawn non-interactive: tapping the row is the action.
 */
@Composable
private fun ProviderToggleRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Switch) { onCheckedChange(!checked) }
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(
            text = label,
            style = settingsLabelStyle().copy(color = tokens.colors.primary),
            modifier = Modifier.weight(1f),
        )
        Switch(checked = checked, onCheckedChange = null)
    }
}

/**
 * The editor: the sheet's body, inline (an `AlertDialog` holding text fields
 * never settles under Robolectric, and the baseline's sheet is a full-surface
 * panel on a phone anyway).
 */
@Composable
private fun ProviderEditor(
    draft: ProviderDraft,
    keyStatus: ProviderKeyStatus,
    connectionTest: ProviderConnectionTestFact?,
    catalog: ProviderCatalogFact?,
    onOpenAdvanced: () -> Unit,
    saveFact: ProviderSaveFact?,
    onDraftChange: (ProviderDraft) -> Unit,
    onGetModels: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val clipboard = LocalClipboardManager.current
    val saveInProgress = saveFact?.isSaving == true
    val fetching = catalog?.isLoading == true
    Column(
        modifier = Modifier
            .fillMaxSize()
            // The key field is the last input of this scrolled form; without the
            // IME inset the viewport still ends under the keyboard and the field
            // cannot be scrolled clear (spec §5 row `insets`). `imePadding` sits
            // outside `verticalScroll` so it shrinks the viewport, not the content.
            .imePadding()
            .verticalScroll(rememberScrollState()),
    ) {
        if (saveInProgress) ProviderProgressLine(UiStrings.PROVIDER_SAVING)
        SettingsHairline()
        SettingsSectionLabel(UiStrings.PROVIDER_SECTION_CONNECTION)
        ProviderField(
            label = UiStrings.PROVIDER_FIELD_NAME,
            value = draft.name,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
            onValueChange = { onDraftChange(draft.copy(name = it)) },
        )
        ProviderField(
            label = if (keyStatus == ProviderKeyStatus.CONFIGURED) {
                UiStrings.PROVIDER_KEY_FIELD_REPLACE
            } else {
                UiStrings.PROVIDER_KEY_FIELD
            },
            value = draft.apiKey,
            secure = true,
            onValueChange = { onDraftChange(draft.copy(apiKey = it, removeStoredKey = false)) },
        )
        ProviderField(
            label = UiStrings.PROVIDER_API_URL,
            value = draft.endpoint,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Uri,
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
            ),
            onValueChange = { onDraftChange(draft.copy(endpoint = it)) },
        )
        SessionTextAction(
            label = UiStrings.PROVIDER_IMPORT_CLIPBOARD,
            onClick = {
                clipboard.getText()?.text?.trim()?.takeIf { it.isNotEmpty() }?.let { value ->
                    onDraftChange(draft.copy(apiKey = value, removeStoredKey = false))
                }
            },
            tone = SessionActionTone.ACCENT,
            modifier = Modifier.padding(horizontal = tokens.geometry.pageOuterMarginH),
        )
        ProviderFooterLine(text = UiStrings.PROVIDER_CONNECTION_FOOTER)

        SettingsSectionLabel(UiStrings.MODEL_LABEL)
        SessionTextAction(
            label = if (fetching) UiStrings.PROVIDER_FETCHING else UiStrings.PROVIDER_FETCH,
            onClick = onGetModels,
            tone = SessionActionTone.ACCENT,
            enabled = draft.endpoint.isNotBlank() && !fetching && !saveInProgress,
            modifier = Modifier
                .padding(horizontal = tokens.geometry.pageOuterMarginH)
                .testTag(PROVIDER_FETCH_TAG),
        )
        ProviderPickerRow(
            label = UiStrings.PROVIDER_DEFAULT_MODEL,
            value = draft.model,
            options = draft.models.map { it.id }.filter { it.isNotBlank() }
                .map { ProviderPickerOption(it, it) },
            onSelect = { onDraftChange(draft.copy(model = it)) },
        )
        catalog?.message?.let { message -> ProviderFooterLine(text = message) }
        ProviderFooterLine(text = UiStrings.PROVIDER_MODEL_FOOTER)

        ProviderRowAction(
            label = UiStrings.PROVIDER_ADVANCED,
            onClick = onOpenAdvanced,
            modifier = Modifier.testTag(PROVIDER_ADVANCED_TAG),
        )
        ProviderFooterLine(text = UiStrings.PROVIDER_ADVANCED_FOOTER)
        connectionTest?.message?.let { message ->
            BasicText(
                text = message,
                style = settingsFootnoteStyle().copy(
                    color = if (connectionTest.succeeded == true) tokens.colors.secondary else tokens.colors.danger,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(PROVIDER_TEST_RESULT_TAG)
                    .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.badgeInsetV),
            )
        }
        saveFact?.message?.let { message ->
            BasicText(
                text = message,
                style = settingsFootnoteStyle().copy(
                    color = if (saveFact.succeeded == true) tokens.colors.secondary else tokens.colors.danger,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(PROVIDER_SAVE_RESULT_TAG)
                    .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.badgeInsetV),
            )
        }
    }
}

/** The advanced editor is a pushed settings page, matching the iOS NavigationLink. */
@Composable
private fun ProviderAdvancedEditor(
    draft: ProviderDraft,
    keyStatus: ProviderKeyStatus,
    connectionTest: ProviderConnectionTestFact?,
    onDraftChange: (ProviderDraft) -> Unit,
    onTest: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
    ) {
        SettingsSectionLabel(UiStrings.PROVIDER_ADVANCED_SECTION)
        ProviderField(
            label = if (draft.isNew) UiStrings.PROVIDER_FIELD_ID_NEW else UiStrings.PROVIDER_FIELD_ID,
            value = draft.id,
            enabled = draft.isNew,
            onValueChange = { onDraftChange(draft.copy(id = it)) },
        )
        ProviderPickerRow(
            label = UiStrings.PROVIDER_REASONING_EFFORT,
            value = draft.reasoningEffort?.let(::providerEffortLabel) ?: UiStrings.PROVIDER_DEFAULT,
            options = listOf(
                ProviderPickerOption("", UiStrings.PROVIDER_DEFAULT),
                ProviderPickerOption("off", UiStrings.PROVIDER_EFFORT_OFF),
                ProviderPickerOption("low", UiStrings.PROVIDER_EFFORT_LOW),
                ProviderPickerOption("high", UiStrings.PROVIDER_EFFORT_HIGH),
                ProviderPickerOption("max", UiStrings.PROVIDER_EFFORT_MAX),
            ),
            onSelect = { onDraftChange(draft.copy(reasoningEffort = it.ifEmpty { null })) },
        )
        draft.modelValidationError?.let { ProviderFooterLine(text = it) }
        ProviderFooterLine(text = draft.protocolHint)
        draft.models.forEachIndexed { index, model ->
            ProviderModelCard(
                model = model,
                onModelChange = { changed ->
                    onDraftChange(draft.copy(models = draft.models.toMutableList().also { it[index] = changed }))
                },
                onDelete = {
                    onDraftChange(
                        draft.copy(
                            models = draft.models.filterIndexed { at, _ -> at != index },
                            model = if (draft.model == model.id) "" else draft.model,
                        ),
                    )
                },
            )
        }
        ProviderRowAction(
            label = UiStrings.PROVIDER_ADD_MODEL,
            onClick = { onDraftChange(draft.copy(models = draft.models + ProviderModelDraft())) },
        )
        SettingsSectionLabel(UiStrings.PROVIDER_SECTION_KEY_CONNECTION)
        ProviderFooterLine(text = keyStatus.keyStatusText())
        if (keyStatus == ProviderKeyStatus.CONFIGURED) {
            ProviderToggleRow(
                label = UiStrings.PROVIDER_DELETE_SAVED_KEY,
                checked = draft.removeStoredKey,
                onCheckedChange = { onDraftChange(draft.copy(removeStoredKey = it, apiKey = "")) },
            )
        }
        ProviderFooterLine(text = UiStrings.PROVIDER_KEY_STORE_HINT)
        SessionTextAction(
            label = if (connectionTest?.isTesting == true) UiStrings.PROVIDER_TESTING
                else UiStrings.PROVIDER_TEST_CONNECTION,
            onClick = onTest,
            tone = SessionActionTone.ACCENT,
            enabled = draft.canSave && connectionTest?.isTesting != true,
            modifier = Modifier
                .padding(horizontal = tokens.geometry.pageOuterMarginH)
                .testTag(PROVIDER_TEST_TAG),
        )
        connectionTest?.message?.let { message ->
            BasicText(
                text = message,
                style = settingsFootnoteStyle().copy(
                    color = if (connectionTest.succeeded == true) tokens.colors.secondary else tokens.colors.danger,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(PROVIDER_TEST_RESULT_TAG)
                    .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.badgeInsetV),
            )
        }
    }
}

@Composable
private fun ProviderProgressLine(label: String) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = Modifier.defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.spacing.iconText)
            .semantics { contentDescription = label },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(tokens.geometry.statusDotDiameter),
            color = tokens.colors.accent,
            strokeWidth = tokens.stroke.hairline,
        )
        BasicText(label, style = settingsLabelStyle().copy(color = tokens.colors.accent))
    }
}

/** One text field of the editor: a fixed label above the field. */
@Composable
private fun ProviderField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    secure: Boolean = false,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    tag: String? = null,
) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = label,
            style = settingsFootnoteStyle().copy(color = tokens.colors.secondary),
        )
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            enabled = enabled,
            singleLine = true,
            keyboardOptions = if (secure) {
                KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                )
            } else {
                keyboardOptions
            },
            visualTransformation = if (secure) {
                PasswordVisualTransformation()
            } else {
                VisualTransformation.None
            },
            textStyle = settingsValueStyle().copy(
                color = if (enabled) tokens.colors.primary else tokens.colors.tertiary,
            ),
            cursorBrush = SolidColor(tokens.colors.accent),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = tokens.geometry.pageRowMinHeight)
                .then(if (secure) Modifier.semantics { password() } else Modifier)
                .testTag(tag ?: (PROVIDER_FIELD_TAG_PREFIX + label)),
        )
    }
}

/**
 * A picker row: the label opens a menu of the draft's options.
 *
 * [label] is the row's visible text and the tap target, so a call site passes a
 * fixed `UiStrings` label; the options are data and never become action labels.
 */
@Composable
private fun ProviderPickerRow(
    label: String,
    value: String,
    options: List<ProviderPickerOption>,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val tokens = LocalUiTokens.current
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(role = Role.Button) { expanded = true }
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = label,
                style = settingsLabelStyle().copy(color = tokens.colors.primary),
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = value,
                style = settingsValueStyle().copy(color = tokens.colors.secondary),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option.label) },
                    onClick = {
                        expanded = false
                        onSelect(option.id)
                    },
                )
            }
        }
    }
}

private fun providerEffortLabel(raw: String): String = when (raw.lowercase()) {
    "off", "none", "minimal" -> UiStrings.PROVIDER_EFFORT_OFF
    "low" -> UiStrings.PROVIDER_EFFORT_LOW
    "medium", "mid" -> "中"
    "high" -> UiStrings.PROVIDER_EFFORT_HIGH
    "max", "maximum" -> UiStrings.PROVIDER_EFFORT_MAX
    else -> raw
}

/** One 模型目录 entry: its id, its two input capabilities, and its delete row. */
@Composable
private fun ProviderModelCard(
    model: ProviderModelDraft,
    onModelChange: (ProviderModelDraft) -> Unit,
    onDelete: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Column(modifier = Modifier.fillMaxWidth()) {
        ProviderField(
            label = UiStrings.PROVIDER_MODEL_ID,
            value = model.id,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
            ),
            onValueChange = { onModelChange(model.copy(id = it)) },
        )
        ProviderField(
            label = UiStrings.PROVIDER_FIELD_NAME,
            value = model.name.orEmpty(),
            onValueChange = { onModelChange(model.copy(name = it.takeIf(String::isNotBlank))) },
            tag = "pdsh.provider.model.name",
        )
        ProviderField(
            label = UiStrings.PROVIDER_TOKENS,
            value = model.contextWindow?.toString().orEmpty(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            onValueChange = { onModelChange(model.copy(contextWindow = it.filter(Char::isDigit).toIntOrNull())) },
        )
        ProviderField(
            label = UiStrings.PROVIDER_MAX_OUTPUT,
            value = model.maxTokens?.toString().orEmpty(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            onValueChange = { onModelChange(model.copy(maxTokens = it.filter(Char::isDigit).toIntOrNull())) },
        )
        ProviderField(
            label = UiStrings.PROVIDER_EFFORT_FIELD,
            value = model.reasoningEffort.orEmpty(),
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
            ),
            onValueChange = { onModelChange(model.copy(reasoningEffort = it.takeIf(String::isNotBlank))) },
        )
        ProviderToggleRow(
            label = UiStrings.PROVIDER_TEXT_INPUT,
            checked = model.textInput,
            onCheckedChange = { onModelChange(model.copy(textInput = it)) },
        )
        ProviderToggleRow(
            label = UiStrings.PROVIDER_IMAGE_INPUT,
            checked = model.imageInput,
            onCheckedChange = { onModelChange(model.copy(imageInput = it)) },
        )
        Row(modifier = Modifier.fillMaxWidth()) {
            SessionTextAction(
                label = UiStrings.PROVIDER_DELETE_MODEL,
                onClick = onDelete,
                tone = SessionActionTone.DANGER,
                modifier = Modifier.padding(horizontal = tokens.geometry.pageOuterMarginH),
            )
        }
    }
}

/** The key-state sentence the editor shows above the key field. */
private fun ProviderKeyStatus.keyStatusText(): String = when (this) {
    ProviderKeyStatus.CONFIGURED -> UiStrings.PROVIDER_KEY_SAVED_LINE
    ProviderKeyStatus.NOT_CONFIGURED -> UiStrings.PROVIDER_KEY_NONE_LINE
    ProviderKeyStatus.INVALID, ProviderKeyStatus.UNKNOWN -> UiStrings.PROVIDER_KEY_UNREADABLE_LINE
}

/** Four is the only suffix the page ever shows. */
internal const val PROVIDER_APPLY_HINT_STOPPED: String = "保存后的配置将在下次启动 App 时生效。"
internal const val PROVIDER_APPLY_HINT_RUNNING: String =
    "保存后的配置将在完全退出并重新打开 App 后生效；当前会话继续使用启动时配置。"

private const val KEY_SUFFIX_LENGTH: Int = 4

/** Below this length, "the last four" would be the whole value. */
private const val KEY_MASK_MIN_LENGTH: Int = 8

/** A host name, a dotted name or an IPv4 address, with an optional port. */
private val HOST_PATTERN: Regex = Regex("""^[A-Za-z0-9](?:[A-Za-z0-9.\-]*[A-Za-z0-9])?(?::\d{1,5})?$""")

/** The retry affordance the failure line draws (a glyph, not a contract label). */
private const val RETRY_GLYPH: String = "↻"
private const val PROVIDER_TEST_TAG: String = "pdsh.provider.test"
private const val PROVIDER_FETCH_TAG: String = "pdsh.provider.fetch"
private const val PROVIDER_ADVANCED_TAG: String = "pdsh.provider.advanced"
private const val PROVIDER_NEXT_LAUNCH_DEFAULT: String = "下次默认"
private const val PROVIDER_TEST_RESULT_TAG: String = "pdsh.provider.test-result"
private const val PROVIDER_SAVE_RESULT_TAG: String = "pdsh.provider.save-result"
private const val PROVIDER_FIELD_TAG_PREFIX: String = "pdsh.provider.field."

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest`'s page map is owned by the session-pages lane; this
 * declaration is the entry that table has for this file. The equality there is
 * "declared == what the source reads", so the typography roles this file names
 * are part of the list together with the value tokens.
 */
internal object ModelProviderSettingsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_ACCENT,
        // The 默认 mark's check is drawn in the card's own ground colour, so the
        // circle reads as a filled accent disc with the page's white through it.
        UiTokenNames.COLORS_INPUT,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_STATUS_DOT_DIAMETER,
        UiTokenNames.STROKE_HAIRLINE,
    )
}
