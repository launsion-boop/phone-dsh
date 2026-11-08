// Loaded plugins: the untitled, read-only inventory and its search.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/NativePluginInventoryPage.swift` at
// iOS HEAD 86a39aac (66 lines). Contract:
// `spec/ui/v1/pages/native-plugin-inventory.json`.
//
// Section shape (`NativePluginInventoryPage.swift:18-61`): one untitled section
// containing loading / empty / result rows and the platform footer. Search remains
// the page's only control; configuration is reached from the actual parent route.
//
// Data: the entries are `ConfigurationPlugin`, the host's one read model for DSH
// loader entries. `enabled` is a three-valued [FactState]: 是 / 否
// / 未知, and the leading dot is green only for `YES` with `phase == "active"`, the
// baseline's own condition (`:43`); everything else — including 未知 — is grey,
// never a green "on".
//
// Copy: the footer states what this phone's Worker cannot do. The baseline's
// sentence names an *iPhone* Worker; this page says the same thing about the phone
// it runs on (and the host may override it with its own measured message). The
// words are the one deliberate divergence from the baseline's copy on this page,
// because printing "iPhone" on an Android phone would be a false statement about
// the device the user is holding.
//
// Chrome: the page title is 已加载插件 (`:66`); the search field filters on module
// and id (`:11`), and nothing else is tappable.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames
import java.util.Locale

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The page's read-only input.
 *
 * @param plugins the loader entries; **`null` means the host reported none** (the
 *   page says 未知 rather than claiming an empty inventory).
 * @param isLoading whether a read is in flight (only shown when there is nothing
 *   to list yet, `NativePluginInventoryPage.swift:26`).
 * @param failure the host's inventory failure text, or `null`.
 * @param managementNotice the host's own explanation of what the phone can do with
 *   plugins; `null` renders this platform's default sentence.
 */
@Immutable
public data class PluginInventoryFacts(
    public val plugins: List<ConfigurationPlugin>? = null,
    public val isLoading: Boolean = false,
    public val failure: String? = null,
    public val managementNotice: String? = null,
)

// ---------------------------------------------------------------------------
// Local state
// ---------------------------------------------------------------------------

/**
 * The two things this page owns locally: the search text and which rows are open.
 *
 * @param query the search text; an empty string means no filter.
 * @param expanded the ids whose disclosure row is open. The baseline's
 *   DisclosureGroup starts closed.
 */
@Immutable
public data class PluginInventoryLocalState(
    public val query: String = "",
    public val expanded: Set<String> = emptySet(),
) {
    /** True when this row's detail block is open. */
    public fun isExpanded(id: String): Boolean = id in expanded
}

/** The two local events the inventory raises. */
public sealed interface PluginInventoryUiEvent {
    /** 搜索插件: the field's text changed. */
    public data class SetQuery(public val query: String) : PluginInventoryUiEvent

    /** A plugin row was tapped: open or close its detail block. */
    public data class ToggleRow(public val id: String) : PluginInventoryUiEvent
}

/** Folds one local event; pure, so a JVM test can replay the sequence. */
public fun PluginInventoryLocalState.apply(
    event: PluginInventoryUiEvent,
): PluginInventoryLocalState = when (event) {
    is PluginInventoryUiEvent.SetQuery -> copy(query = event.query)
    is PluginInventoryUiEvent.ToggleRow -> copy(
        expanded = if (event.id in expanded) expanded - event.id else expanded + event.id,
    )
}

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** One plugin row, display-ready. */
@Immutable
public data class PluginInventoryRowView(
    public val id: String,
    public val module: String,
    public val enabled: FactState,
    public val phase: String?,
    public val expanded: Boolean,
) {
    /** The baseline's green dot condition: enabled **and** `phase == "active"`. */
    public val active: Boolean get() = enabled == FactState.YES && phase == ACTIVE_PHASE

    /** 启用: 是 / 否 / 未知 — never a boolean the host did not report. */
    public val enabledLabel: String
        get() = when (enabled) {
            FactState.YES -> UiStrings.PLUGIN_INVENTORY_YES
            FactState.NO -> UiStrings.PLUGIN_INVENTORY_NO
            FactState.UNKNOWN -> UiStrings.UNKNOWN
        }

    public companion object {
        /** The phase word the baseline compares (`NativePluginInventoryPage.swift:43`). */
        public const val ACTIVE_PHASE: String = "active"
    }
}

/** The complete plugin-inventory screen state. */
@Immutable
public data class PluginInventoryScreenState(
    /** The filtered rows; `null` when the host reported no inventory. */
    public val rows: List<PluginInventoryRowView>? = null,
    /** True only while a read is in flight and there is nothing to show yet. */
    public val loading: Boolean = false,
    /** True when a reported inventory was filtered empty by the query. */
    public val empty: Boolean = false,
    public val error: String? = null,
    /** The footer sentence: the host's own, or this platform's default. */
    public val notice: String = UiStrings.PLUGIN_INVENTORY_MANAGEMENT_NOTICE,
    public val query: String = "",
    /** True while refreshing existing rows as well as during the initial read. */
    public val refreshing: Boolean = false,
) {
    public companion object {
        /** Projects the facts into the four groups. */
        public fun from(
            facts: PluginInventoryFacts,
            local: PluginInventoryLocalState = PluginInventoryLocalState(),
        ): PluginInventoryScreenState {
            val entries = facts.plugins?.filter { matches(it, local.query) }?.map { plugin ->
                PluginInventoryRowView(
                    id = plugin.id,
                    module = plugin.module,
                    enabled = plugin.enabled,
                    phase = plugin.phase,
                    expanded = local.isExpanded(plugin.id),
                )
            }
            return PluginInventoryScreenState(
                rows = entries,
                loading = facts.isLoading && facts.plugins.isNullOrEmpty(),
                empty = entries != null && entries.isEmpty(),
                error = facts.failure,
                notice = facts.managementNotice ?: UiStrings.PLUGIN_INVENTORY_MANAGEMENT_NOTICE,
                query = local.query,
                refreshing = facts.isLoading,
            )
        }

        /** The baseline's filter: module or id, case-insensitive (`:11`). */
        internal fun matches(plugin: ConfigurationPlugin, query: String): Boolean {
            if (query.isEmpty()) return true
            val needle = query.lowercase(Locale.ROOT)
            return plugin.module.lowercase(Locale.ROOT).contains(needle) ||
                plugin.id.lowercase(Locale.ROOT).contains(needle)
        }
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The loaded-plugin inventory page.
 *
 * @param state the pure screen state (`PluginInventoryScreenState.from`).
 * @param onOpenConfiguration kept for source compatibility; the iOS inventory
 *   page has no configuration CTA, so the parent route owns that navigation.
 * @param onQueryChange the search field's text changed.
 * @param onToggleRow a plugin row was tapped.
 * @param onBack leave the page.
 * @param embedded render as the settings sheet's 插件 tab: no page header.
 */
@Composable
@Suppress("UNUSED_PARAMETER")
public fun NativePluginInventoryPage(
    state: PluginInventoryScreenState,
    onOpenConfiguration: () -> Unit = {},
    onQueryChange: (String) -> Unit = {},
    onToggleRow: (String) -> Unit = {},
    onBack: () -> Unit = {},
    modifier: Modifier = Modifier,
    embedded: Boolean = false,
    onRefresh: (() -> Unit)? = null,
) {
    LaunchedEffect(Unit) { onRefresh?.invoke() }
    if (embedded) {
        Box(
            modifier = modifier
                .fillMaxSize()
                .windowInsetsPadding(
                    WindowInsets.safeDrawing.only(
                        WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom,
                    ),
                ),
        ) {
            PluginInventoryBody(
                state = state,
                onQueryChange = onQueryChange,
                onToggleRow = onToggleRow,
                onRefresh = onRefresh,
            )
        }
    } else {
        PageFrame(
            title = UiStrings.PLUGIN_INVENTORY_TITLE,
            onBack = onBack,
            modifier = modifier,
        ) {
            PluginInventoryBody(
                state = state,
                onQueryChange = onQueryChange,
                onToggleRow = onToggleRow,
                onRefresh = onRefresh,
            )
        }
    }
}

/** The untitled source section: search, one inventory state, and its footer. */
@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
private fun PluginInventoryBody(
    state: PluginInventoryScreenState,
    onQueryChange: (String) -> Unit,
    onToggleRow: (String) -> Unit,
    onRefresh: (() -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    PullToRefreshBox(
        isRefreshing = state.refreshing,
        onRefresh = onRefresh ?: {},
        modifier = Modifier.fillMaxSize(),
    ) {
      LazyColumn(
          modifier = Modifier
              .fillMaxSize()
              // The search field is an early row of this list; the IME must shrink the
              // viewport so the rows below it stay reachable, not just leave the field
              // visible (spec §5 row `insets`).
              .imePadding()
              .testTag(UiPageTags.PLUGIN_INVENTORY_LIST)
              .padding(horizontal = tokens.geometry.pageOuterMarginH),
          // unverified geometry: `spec/ui/v1/tokens.json` declares no page-level card
          // gap, so the approval card's outer vertical margin carries the gap between
          // this page's cards (and the list's own top/bottom inset).
          verticalArrangement = Arrangement.spacedBy(tokens.geometry.cardOuterMarginV),
          contentPadding = PaddingValues(vertical = tokens.geometry.cardOuterMarginV),
      ) {
        item(key = "search") {
            PluginSearchField(query = state.query, onQueryChange = onQueryChange)
        }
        when {
            state.loading -> item(key = "loading") {
                BasicText(
                    text = UiStrings.PLUGIN_INVENTORY_LOADING,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                    modifier = Modifier
                        .testTag(UiPageTags.PLUGIN_INVENTORY_LOADING)
                        .padding(horizontal = tokens.spacing.cardInset),
                )
            }

            state.empty -> item(key = "empty") {
                BasicText(
                    text = UiStrings.PLUGIN_INVENTORY_EMPTY,
                    style = type.caption.copy(color = tokens.colors.secondary),
                    modifier = Modifier
                        .testTag(UiPageTags.PLUGIN_INVENTORY_EMPTY)
                        .padding(horizontal = tokens.spacing.cardInset),
                )
            }

            state.rows == null -> item(key = "unread") {
                BasicText(
                    text = UiStrings.PLUGIN_INVENTORY_UNREAD,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                    modifier = Modifier
                        .testTag(UiPageTags.PLUGIN_INVENTORY_UNREAD)
                        .padding(horizontal = tokens.spacing.cardInset),
                )
            }

            else -> {
                val rows = state.rows.orEmpty()
                items(items = rows, key = { it.id }) { row ->
                    PluginRow(row = row, onToggle = { onToggleRow(row.id) })
                }
            }
        }
        // 3. the failure line can retry through the host's actual inventory read.
        state.error?.let { error ->
            item(key = "error") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(UiPageTags.PLUGIN_INVENTORY_FAILURE)
                        .padding(horizontal = tokens.spacing.cardInset),
                    horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicText(
                        text = error,
                        style = type.caption.copy(color = tokens.colors.danger),
                        modifier = Modifier.weight(1f),
                    )
                    // No retry button: pull-to-refresh is the recovery on both platforms
                    // (page-structure-rules.md rule 2).
                }
            }
        }
        // 4. the platform footer: untitled.
        item(key = "notice") {
            BasicText(
                text = state.notice,
                style = type.caption.copy(color = tokens.colors.secondary),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.PLUGIN_INVENTORY_NOTICE)
                    .padding(horizontal = tokens.spacing.cardInset),
            )
        }
      }
    }
}

/** 搜索插件: the filter field, marked as a search action for the IME. */
@Composable
private fun PluginSearchField(query: String, onQueryChange: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        textStyle = type.body.copy(color = tokens.colors.primary),
        cursorBrush = SolidColor(tokens.colors.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .clip(RoundedCornerShape(tokens.radius.card))
            .background(tokens.colors.selector)
            .padding(horizontal = tokens.spacing.cardInset)
            .testTag(UiPageTags.PLUGIN_INVENTORY_SEARCH)
            .semantics { contentDescription = UiStrings.PLUGIN_INVENTORY_SEARCH },
        decorationBox = { inner ->
            Box(modifier = Modifier.fillMaxWidth()) {
                if (query.isEmpty()) {
                    BasicText(
                        text = UiStrings.PLUGIN_INVENTORY_SEARCH,
                        style = type.body.copy(color = tokens.colors.tertiary),
                    )
                }
                inner()
            }
        },
    )
}

/**
 * One plugin: a status dot and its module name, opening a detail block with the
 * baseline's four label/value lines (`NativePluginInventoryPage.swift:34`–`:39`).
 */
@Composable
private fun PluginRow(row: PluginInventoryRowView, onToggle: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val state = if (row.expanded) UiStrings.EXPANDED else UiStrings.COLLAPSED
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.PLUGIN_INVENTORY_ROW_PREFIX + row.id)
            .border(
                width = tokens.stroke.hairline,
                color = tokens.colors.border,
                shape = RoundedCornerShape(tokens.radius.card),
            )
            .padding(tokens.spacing.cardInset),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .testTag(UiPageTags.PLUGIN_INVENTORY_ROW_HEADER + row.id)
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .clickable(onClick = onToggle)
                .semantics(mergeDescendants = true) { stateDescription = state },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            Box(
                modifier = Modifier
                    .size(tokens.geometry.statusDotDiameter)
                    .clip(CircleShape)
                    .background(
                        if (row.active) tokens.colors.success else tokens.colors.secondary,
                    ),
            )
            BasicText(
                text = row.module,
                style = type.body.copy(color = tokens.colors.primary),
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = if (row.expanded) CHEVRON_OPEN else CHEVRON_CLOSED,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
        if (row.expanded) {
            PluginDetailLine(UiStrings.PLUGIN_INVENTORY_ENTRY, row.id)
            PluginDetailLine(UiStrings.PLUGIN_INVENTORY_MODULE, row.module)
            PluginDetailLine(UiStrings.PLUGIN_INVENTORY_ENABLED, row.enabledLabel)
            row.phase?.let { phase -> PluginDetailLine(UiStrings.PLUGIN_INVENTORY_PHASE, phase) }
        }
    }
}

/** One label/value line of the expanded block. */
@Composable
private fun PluginDetailLine(label: String, value: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = label,
            style = type.caption.copy(color = tokens.colors.secondary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = value,
            style = type.code.copy(color = tokens.colors.secondary),
        )
    }
}

// ---------------------------------------------------------------------------
// Constants and the token inventory
// ---------------------------------------------------------------------------

/** The disclosure glyphs; chrome, never an action label. */
private const val CHEVRON_OPEN: String = "▾"
private const val CHEVRON_CLOSED: String = "▸"

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest` asserts that this list equals the tokens the source
 * reads, so an unlisted use and a stale entry both fail.
 */
internal object NativePluginInventoryPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_SELECTOR,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_CODE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_CARD_OUTER_MARGIN_V,
        UiTokenNames.GEOMETRY_STATUS_DOT_DIAMETER,
    )
}
