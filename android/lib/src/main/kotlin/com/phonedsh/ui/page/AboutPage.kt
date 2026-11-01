// About: the version, the platform the app runs on, licenses and developer access.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row SettingsAboutPage (版本、许可、开发者入口;
// child LicensesPage), §3.1 (the ScreenState layer) and §5 (`insets`).
//
// §1.1 records that the developer page is reached only by tapping the version
// repeatedly and only exists in DEBUG builds: the row therefore appears only
// when the host says the entry exists, and it is never invented by the page.
//
// Nothing here is a plausible default. A version, build number, API level, ABI
// or WebView version the host did not read renders 未知 — the page has no
// "fallback version" it could print.
//
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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/** The platform facts the app can read about itself. */
@Immutable
public data class PlatformInfo(
    /** `Build.VERSION.SDK_INT`. */
    public val sdkInt: Int? = null,
    /** `Build.VERSION.RELEASE`. */
    public val release: String? = null,
    /** The primary ABI, or the host's joined list. */
    public val abi: String? = null,
    /** `Build.MODEL`; `null` when the host redacts it. */
    public val deviceModel: String? = null,
    /** `WebView.getCurrentWebViewPackage()`'s version (`platform.webview-version-gate`). */
    public val webViewVersion: String? = null,
)

/**
 * The page's read-only input.
 *
 * @param version the app version; `null` when unread.
 * @param build the build number; `null` when unread.
 * @param platform the platform snapshot; `null` when unread.
 * @param developerEntry the DEBUG-only developer entry exists in this build.
 */
@Immutable
public data class AboutFacts(
    public val version: String? = null,
    public val build: String? = null,
    public val platform: PlatformInfo? = null,
    public val developerEntry: Boolean = false,
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
        /** The licenses row id; the page maps it to the host's callback. */
        public const val LICENSES_ROW_ID: String = "more.licenses"

        /** The DEBUG-only developer row id. */
        public const val DEVELOPER_ROW_ID: String = "more.developer"

        /**
         * Projects (facts, local folds) into the screen state.
         *
         * Pure: an unread value becomes [UiStrings.UNKNOWN] here, once, so the
         * page cannot render a value the facts did not carry (§3.1).
         */
        public fun from(
            facts: AboutFacts,
            local: AboutLocalState = AboutLocalState(),
        ): AboutScreenState {
            val platform = facts.platform
            val versionRows = listOf(
                AboutRowView(
                    id = "version.version",
                    title = UiStrings.ABOUT_VERSION,
                    value = facts.version ?: UiStrings.UNKNOWN,
                    tone = if (facts.version == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
                AboutRowView(
                    id = "version.build",
                    title = UiStrings.ABOUT_BUILD,
                    value = facts.build ?: UiStrings.UNKNOWN,
                    tone = if (facts.build == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
            )
            val systemRows = listOf(
                AboutRowView(
                    id = "system.android",
                    title = UiStrings.ABOUT_ANDROID,
                    value = platform?.release ?: UiStrings.UNKNOWN,
                    tone = if (platform?.release == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
                AboutRowView(
                    id = "system.api",
                    title = UiStrings.ABOUT_API_LEVEL,
                    value = platform?.sdkInt?.toString() ?: UiStrings.UNKNOWN,
                    tone = if (platform?.sdkInt == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
                AboutRowView(
                    id = "system.abi",
                    title = UiStrings.ABOUT_ABI,
                    value = platform?.abi ?: UiStrings.UNKNOWN,
                    tone = if (platform?.abi == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
                AboutRowView(
                    id = "system.device",
                    title = UiStrings.ABOUT_DEVICE,
                    value = platform?.deviceModel ?: UiStrings.UNKNOWN,
                    tone = if (platform?.deviceModel == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
                AboutRowView(
                    id = "system.webview",
                    title = UiStrings.ABOUT_WEBVIEW,
                    value = platform?.webViewVersion ?: UiStrings.UNKNOWN,
                    tone = if (platform?.webViewVersion == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
            )
            val moreRows = buildList {
                add(
                    AboutRowView(
                        id = LICENSES_ROW_ID,
                        title = UiStrings.ABOUT_LICENSES,
                        value = null,
                        nav = true,
                    ),
                )
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
            val sections = listOf(
                AboutSectionView("about.version", UiStrings.ABOUT_SECTION_VERSION, versionRows, expanded = true),
                AboutSectionView("about.system", UiStrings.ABOUT_SECTION_SYSTEM, systemRows, expanded = true),
                AboutSectionView("about.more", UiStrings.ABOUT_SECTION_MORE, moreRows, expanded = true),
            ).map { it.copy(expanded = local.fold.isExpanded(it.id)) }
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
 * @param onToggleSection a section header was tapped; the host applies
 *   `AboutUiEvent.ToggleSection` and re-projects.
 * @param onBack leave the page.
 * @param onOpenLicenses open the licenses sub-page; `null` renders the row as
 *   unavailable instead of pretending the action exists.
 * @param onOpenDeveloper open the DEBUG-only developer page.
 */
@Composable
public fun AboutPage(
    state: AboutScreenState,
    onToggleSection: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onOpenLicenses: (() -> Unit)? = null,
    onOpenDeveloper: (() -> Unit)? = null,
) {
    PageFrame(
        title = UiStrings.ABOUT,
        onBack = onBack,
        modifier = modifier,
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiTags.ABOUT_LIST),
            verticalArrangement = Arrangement.spacedBy(pageListGap),
        ) {
            state.sections.forEach { section ->
                item(key = "header-${section.id}") {
                    SectionHeader(
                        title = section.title,
                        expanded = section.expanded,
                        onToggle = { onToggleSection(section.id) },
                        trailing = UiStrings.ROW_COUNT.format(section.rows.size),
                        tag = UiTags.ABOUT_SECTION,
                    )
                }
                if (section.expanded) {
                    items(count = section.rows.size, key = { index -> section.rows[index].id }) { index ->
                        val row = section.rows[index]
                        val action = when (row.id) {
                            AboutScreenState.LICENSES_ROW_ID -> onOpenLicenses
                            AboutScreenState.DEVELOPER_ROW_ID -> onOpenDeveloper
                            else -> null
                        }
                        InfoRow(
                            title = row.title,
                            value = when {
                                row.nav && action == null -> UiStrings.UNAVAILABLE
                                else -> row.value
                            },
                            tone = when {
                                row.nav && action == null -> PageTone.UNKNOWN
                                else -> row.tone
                            },
                            enabled = action != null || !row.nav,
                            onClick = action,
                        )
                    }
                }
            }
        }
    }
}
