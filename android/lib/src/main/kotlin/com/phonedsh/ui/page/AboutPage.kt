// About: the app identity and its package version/build facts.
// SPDX-License-Identifier: MIT
//
// Source: `NativeShell.swift:839-869` SettingsAboutPage branding, package values,
// and local-storage footnote. Legacy optional developer/diagnostic facts remain
// available to callers that explicitly supply them.
//
// Nothing here is a plausible default. A version the host did not read renders
// 未知 — the page has no "fallback version" it could print.
//
// The native page has one branding content block and one untitled card containing
// the actual version/build rows plus the local-storage footnote. Do not promote
// either row label into a group header.

// ScreenState: `AboutScreenState.from(facts, local)` is pure. §3.1 rule 3 makes
// the facts snapshot the UiState-side input on a page with no harness event
// anchor; the local event is the section fold only.
//
// Geometry: this page adds no length of its own. The page margin, the row floor
// and the section-header floor come from `PageScaffold.kt` as page-level tokens;
// the list gap still reuses the tool row's `disclosureIconGap` through
// `pageListGap`, marked `unverified geometry` in `PageScaffold.kt`.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.Image
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.lib.R
import com.phonedsh.ui.surface.SettingsCardGap
import com.phonedsh.ui.surface.SettingsFormRow
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.LocalSettingsRowInk
import com.phonedsh.ui.surface.SettingsGroupCard
import com.phonedsh.ui.surface.SettingsSectionLabelIndent
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsSubPageGroupedTopInset
import com.phonedsh.ui.surface.settingsSystemInk
import com.phonedsh.ui.surface.settingsValueInk
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The page's read-only input.
 *
 * @param version the app version; `null` when unread.
 * @param buildNumber the Android package versionCode; `null` when unavailable.
 * @param developerEntry the DEBUG-only developer entry exists in this build.
 */
@Immutable
public data class AboutFacts(
    public val version: String? = null,
    public val developerEntry: Boolean = false,
    /** Android package versionCode (the build field shown by the native About page). */
    public val buildNumber: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** One label/value row. */
@Immutable
public data class AboutRowView(
    public val id: String,
    public val title: String,
    public val value: String?,
    public val tone: PageTone = PageTone.NORMAL,
    /** True for a row that opens a sub-page (licenses, developer). */
    public val nav: Boolean = false,
)

/** One collapsible section. */
@Immutable
public data class AboutSectionView(
    public val id: String,
    public val title: String,
    public val rows: List<AboutRowView>,
    public val expanded: Boolean,
)

/** The complete about screen state. */
@Immutable
public data class AboutScreenState(public val sections: List<AboutSectionView>) {
    public companion object {
        /** The 版本 card (`NativeShell.swift:900`). */
        public const val VERSION_SECTION_ID: String = "about.version"

        /** The 更多 card; present only when the build carries a developer entry. */
        public const val MORE_SECTION_ID: String = "about.more"

        /** The licenses row id; the page maps it to the host's callback. */
        public const val LICENSES_ROW_ID: String = "more.licenses"

        /** The DEBUG-only developer row id. */
        public const val DEVELOPER_ROW_ID: String = "more.developer"

        /**
         * Projects (facts, local folds) into the screen state.
         *
         * Pure: an unread value becomes [UiStrings.UNKNOWN] here, once, so the
         * page cannot render a value the facts did not carry (§3.1).
         *
         * The baseline is one card with 版本 and 构建 rows plus the one-sentence
         * footnote. The brand identity block is separate content above it.
         */
        public fun from(
            facts: AboutFacts,
            local: AboutLocalState = AboutLocalState(),
        ): AboutScreenState {
            val versionRows = listOf(
                AboutRowView(
                    // The baseline's label is 版本, not 版本号
                    // (`NativeShell.swift:900`: LabeledContent("版本", …)).
                    id = "version.version",
                    title = UiStrings.ABOUT_SECTION_VERSION,
                    value = facts.version ?: UiStrings.UNKNOWN,
                    tone = if (facts.version == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
                AboutRowView(
                    id = "version.build",
                    title = "构建",
                    value = facts.buildNumber ?: UiStrings.UNKNOWN,
                    tone = if (facts.buildNumber == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
            )
            val moreRows = buildList {
                if (facts.developerEntry) {
                    add(
                        AboutRowView(
                            id = DEVELOPER_ROW_ID,
                            title = UiStrings.ABOUT_DEVELOPER,
                            value = null,
                            nav = true,
                        ),
                    )
                }
            }
            val sections = buildList {
                add(AboutSectionView(VERSION_SECTION_ID, UiStrings.ABOUT_SECTION_VERSION, versionRows, expanded = true))
                // The 更多 card exists for the two sub-pages; with neither wired the
                // card would hold one 不可用 row, so the page drops it.
                if (moreRows.isNotEmpty()) {
                    add(AboutSectionView(MORE_SECTION_ID, UiStrings.ABOUT_SECTION_MORE, moreRows, expanded = true))
                }
            }.map { it.copy(expanded = local.fold.isExpanded(it.id)) }
            return AboutScreenState(sections = sections)
        }
    }
}

/** The local UI events of the about page: only the section fold. */
public sealed interface AboutUiEvent {
    /** Collapse or expand one section. */
    public data class ToggleSection(public val id: String) : AboutUiEvent
}

/** The fold script; [apply] is pure, so a test drives it like a reducer. */
@Immutable
public data class AboutLocalState(public val fold: FoldState = FoldState()) {
    /** Applies one local event. */
    public fun apply(event: AboutUiEvent): AboutLocalState = when (event) {
        is AboutUiEvent.ToggleSection -> copy(fold = fold.toggle(event.id))
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The about screen.
 *
 * @param state the pure screen state (`AboutScreenState.from`).
 * @param onToggleSection kept for the settings sheet's call site. The baseline's
 *   关于 page has no section header and no fold (`NativeShell.swift:897-908`), so
 *   this page draws neither and the fold script reaches no control here.
 * @param onBack leave the page.
 * @param onOpenLicenses open the licenses sub-page; `null` renders the row as
 *   unavailable instead of pretending the action exists.
 * @param onOpenDeveloper open the DEBUG-only developer page.
 */
@Suppress("UNUSED_PARAMETER")
@Composable
public fun AboutPage(
    state: AboutScreenState,
    onToggleSection: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onOpenLicenses: (() -> Unit)? = null,
    onOpenDeveloper: (() -> Unit)? = null,
) {
    SettingsSubPageFrame(
        title = UiStrings.ABOUT,
        backGlyph = PAGE_BACK_GLYPH,
        showSheetHandle = false,
        onBack = onBack,
        modifier = modifier,
        grouped = true,
    ) {
        // The row ink is the iOS system three (`colors.systemLabel` / `systemSecondary`
        // / `settingsFootnoteInk`), not the app theme's #111114 / #66666B: this card is
        // a SwiftUI `List` row, and the baseline's glyphs are pure black.
        CompositionLocalProvider(LocalSettingsRowInk provides settingsSystemInk()) {
            val type = LocalUiType.current
            val tokens = LocalUiTokens.current
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(UiTags.ABOUT_LIST),
                // A pushed page's grouped list keeps the whole navigation content
                // inset: `ios-settings-about.png` puts the card top at 151.0 pt under
                // a bar that ends at 106 pt (45.0), not the 34.67 the general tab's
                // list gets below its picker.
                contentPadding = PaddingValues(top = SettingsSubPageGroupedTopInset),
                verticalArrangement = Arrangement.spacedBy(SettingsCardGap),
            ) {
                item(key = "about-branding") {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(
                            vertical = ChatMetrics.ABOUT_BRANDING_ROW_PADDING_V_PT.dp,
                        ),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(
                            ChatMetrics.ABOUT_BRANDING_STACK_GAP_PT.dp,
                        ),
                    ) {
                        // Exact iOS LogoBackground asset, copied unchanged from
                        // Assets.xcassets/LogoBackground.imageset/LogoBackground@3x.png.
                        // SHA-256: 34f7a3134813cd01c5f13cc0bf48b704b34357f8b5171f3f7b771333a20e7016.
                        Image(
                            painter = painterResource(R.drawable.about_logo_background),
                            contentDescription = null,
                            modifier = Modifier.size(ChatMetrics.ABOUT_BRANDING_LOGO_SIZE_PT.dp)
                                .testTag("pdsh.about.brand-logo"),
                        )
                        BasicText(
                            text = "Phone DSH",
                            style = type.pageTitle.copy(
                                fontSize = HomeMetrics.NAV_TITLE_SIZE_PT.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = tokens.colors.textPrimary,
                            ),
                        )
                        BasicText(
                            text = "运行在手机上的 DeepSeek Harness",
                            style = type.secondary.copy(
                                fontSize = HomeMetrics.NAV_SUBTITLE_SIZE_PT.sp,
                                color = tokens.colors.textPlaceholder,
                            ),
                        )
                    }
                }
                // The baseline's 关于 is an identity block followed by one
                // inset-grouped card with no header or disclosure (`NativeShell.swift:842-864`):
                //
                //     List {
                //         Text("Phone DSH") / Text("运行在手机上的 DeepSeek Harness")
                //         LabeledContent("版本", value: …)
                //         LabeledContent("构建", value: …)
                //         Text("会话记录和文件都保存在这台手机上。").font(.footnote)…
                //     }
                //
                // One card per projection section, in the projection's order. The
                // licenses row belongs to the settings index (`SettingsPage.swift:165`),
                // so it is drawn on the last card only when the sheet handed a licenses
                // page over; without one the page is the baseline's single card.
                val cards = state.sections.map { section ->
                    section to section.rows.filter { row ->
                        // A navigation row without a destination is not drawn as
                        // 不可用: the baseline's about page has no such row at all.
                        !row.nav || actionFor(row.id, onOpenLicenses, onOpenDeveloper) != null
                    }
                }.filter { (_, rows) -> rows.isNotEmpty() }
                cards.forEachIndexed { cardIndex, (section, sectionRows) ->
                    val rows = buildList {
                        addAll(sectionRows)
                        if (onOpenLicenses != null && cardIndex == cards.lastIndex) {
                            add(
                                AboutRowView(
                                    id = AboutScreenState.LICENSES_ROW_ID,
                                    title = UiStrings.ABOUT_LICENSES,
                                    value = null,
                                    nav = true,
                                ),
                            )
                        }
                    }
                    item(key = "card-${section.id}") {
                        Column {
                            SettingsGroupCard(modifier = Modifier.testTag(ABOUT_VERSION_CARD_TAG)) {
                                rows.forEachIndexed { index, row ->
                                    SettingsFormRow(
                                        title = row.title,
                                        value = row.value,
                                        // iOS draws LabeledContent's value in system
                                        // .secondary (#8A8A8E); the tone would pick the
                                        // theme's #66666B.
                                        valueInk = settingsValueInk(),
                                        tone = row.tone,
                                        chevron = row.nav,
                                        dividerBelow = index != rows.lastIndex,
                                        dividerLeadingInset = SettingsSectionLabelIndent,
                                        onClick = actionFor(row.id, onOpenLicenses, onOpenDeveloper),
                                    )
                                }
                            }
                            // A SwiftUI Section footer sits on the list background,
                            // below the white rows card, rather than inside it.
                            if (section.id == AboutScreenState.VERSION_SECTION_ID) {
                                SettingsFootnoteRow(text = UiStrings.ABOUT_LOCAL_NOTE)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** The callback a row opens, or `null` when this host has no such page. */
private fun actionFor(
    rowId: String,
    onOpenLicenses: (() -> Unit)?,
    onOpenDeveloper: (() -> Unit)?,
): (() -> Unit)? = when (rowId) {
    AboutScreenState.LICENSES_ROW_ID -> onOpenLicenses
    AboutScreenState.DEVELOPER_ROW_ID -> onOpenDeveloper
    else -> null
}

private const val ABOUT_VERSION_CARD_TAG: String = "pdsh.settings.about.version-card"
