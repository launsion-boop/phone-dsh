# ChatMetrics and sibling `*Metrics.kt`: constant classification (W1-07)

**Status:** analysis for the W1-07 base — the original audit edited only this file; wave-3 round-1/2 Kotlin deltas are recorded in the note below and in the affected rows.

**Base:** `feat/android-parity` @ `56e7b6ce`; the head and command evidence are in the handoff block of the task report.

**Wave-3 round-1 update (2026-11-12):** `ChatMetrics` deleted `SEND_HIT_PT`, added
`COMPOSER_PORT_MIN_HEIGHT_PT = 56` and narrowed `COMPOSER_TEXT_MIN_HEIGHT_PT` to 36
(`06e39dd2`); `SettingsMetrics` recorded two contract gaps in its KDoc only (`c532d63f`).
Wave-3 round 2 deleted the two dead `HOME_PRIMARY_BUTTON_*_OPACITY` re-exports from
`HomeMetrics` (the generated `HomeSpecData` leaves remain). The affected rows below are
updated in place; §2's aggregate counts are the W1-07 base audit and are not re-derived.

**Authority:** `spec/ui/v1/tokens.json` and the six signature-surface token sets in `spec/ui/v1/README.md` §4. iOS sources under `examples/probe-app/PhoneDSHProbe/` are provenance, not authority; every citation is checked against the current tree, not against the revision the KDoc was written for.

## 0. Headline

**588 source-of-truth declarations** were classified: **561 `public const val`** plus **24 literal `Dp`/`TextUnit` `val`s in `ConnectorsMetrics.kt`** and **3 generated-token reads in `SessionsMetrics.kt`**. `ChatMetrics.kt` has **386 `val` declarations**, exactly as the brief says: **374 `const val` + 12 derived `Dp` accessors**. The 12 accessors are not constants and are listed in Appendix A; the 374 constants are all in the table.

| class | count | share | meaning at HEAD |
|---|---:|---:|---|
| `token` | 101 | 17.2% | same value is already a `tokens.json` leaf; the constant should become (or already is) a generated-token read |
| `token-new` | 4 | 0.7% | real iOS value used by a signature surface, missing from `tokens.json`; proposed id + provenance |
| `page-local` | 130 | 22.1% | one page/surface layout value that legitimately does not belong in `tokens.json` (PageGeometryTokenTest header rule) |
| `android-only` | 12 | 2.0% | platform-forced capture/touch/elevation/glyph adaptation; §5 whitelist id or explicit explanation |
| `dead` | 138 | 23.5% | zero Kotlin references; delete |
| `stale` | 203 | 34.5% | the cited iOS line no longer carries the value; re-anchor the KDoc (or the value is gone) |
| **total** | **588** | **100%** | |

**The citation debt is the real finding.** Of the 588 declarations, only **158 (26.9%)** cite a Swift line that still carries the value; **278 (47.3%)** cite a line that no longer does. Another 52 cite a measured PNG, 47 cite no line, 37 are generated-token reads, 9 cite a design spec, and 7 are derived. Of the 448 declarations whose KDoc claims `Confidence: exact`, **274 (61.2%)** have a stale line citation. The values are mostly still right — the KDocs are pinned to a pre-PR22 `ChatPage.swift` (now 5,301 lines, while the cited lines are mostly in the 1,800–4,500 range) and were never re-anchored.

Four more things a convergence worker must know:

1. **22 constant names are declared in more than one `*Metrics.kt` file.** Four of them disagree on value: `DRAWER_ROW_HEIGHT_PT` (44 vs 48), `DRAWER_ROW_ICON_SLOT_PT` (24 vs 22), `HEADER_TITLE_REF_PT` (17.5 vs 17), and `SEPARATOR_HEIGHT_PT` (0.5 vs 1). The rest are duplicates that should collapse to one owner (table in §2.4).
2. **138 constants (23.5%) are dead.** Most are geometry for components Android has not ported (tool cards, queue dock, todo glyph canvas, changed-files text sizes). Deleting them is the cheapest large win and does not change rendering.
3. **101 live constants classify as exact token duplicates**, but only 37 are already generated reads (`HomeMetrics`). The other 64 are in six files: 61 are literal copies of `tokens.json` values and 3 (the Sessions drawer reads) already read the generated token but are kept as named constants; more token duplicates hide among the `dead` rows, where the note names the token.
4. **4 missing tokens are real signature-surface gaps**, all in the composer/approval surfaces: composer outer bottom inset 0, composer port leading 11, composer port trailing 8, and approval-card row spacing 10. Their current Swift provenance and proposed ids are in §4.

## 1. Method

- **Extraction.** Every `public [const] val NAME: Type = VALUE` in the seven `*Metrics.kt` files was parsed with its preceding KDoc. Multi-line expressions were joined; `ConnectorsMetrics.kt` literal `val … get() = N.dp` declarations were included because they are declaration sites, not derived accessors.
- **References.** Counted identifier occurrences of the exact `NAME` across `android/**/*.kt` (main, test and app), excluding the declaration line. Comments and test files are included, so this is a `grep(1)` count, not a call-graph count. Same-named constants in two files share one count; §2.4 resolves those cases. A `_PT` constant used through its `Dp` accessor (e.g. `ChatMetrics.headerHeight`) is **not** counted; the accessors are pass-throughs listed in Appendix A.
- **Citation check.** For every KDoc citation `File.swift:line` (including `a-b` and `a,b` lists) the current file was opened and the cited line range searched for the constant’s numeric value or an equivalent property/`expect` fragment. A match is `holds`; no match is `stale` and the current line text is recorded. Where the KDoc also names the code fragment (e.g. `.padding(.top, 8)`), the fragment was searched in the same file and the new line recorded as `stale→File:newline`. `HomeSpec.<property>` citations were resolved against `HomeSpec.swift` values and lines.
- **Token matching.** A constant maps to an existing token only when the **semantic role and provenance** match, not merely the number. A `page-local` value can equal a token by coincidence (eight different 16s are not `geometry.chromeInset`). Signature-surface membership was taken from `tokens.json#signatureSurfaces`, not guessed from the value.
- **Class precedence.** `dead` (zero refs) → `token` → `token-new` → `android-only` → `stale` → `page-local`. A dead constant that also duplicates a token is reported as `dead` with the token id in its note, because the action is deletion. A token-backed constant whose KDoc citation drifted is reported as `token` (citation column says stale): the convergence action is the token read, not a number change.
- **Page-local rule.** From `android/lib/src/test/kotlin/com/phonedsh/ui/page/PageGeometryTokenTest.kt`: every geometry token must be surface-owned, contract-owned, read by at least two pages, or a HomeSpec length owned by `HomeMetrics`; “a one-page length keeps reusing a declared token with the `unverified geometry` marker instead of entering the spec.” This is why most measured settings/connector geometry stays `page-local`.
- **No runtime, screenshot or device check was performed.** This classification is static: parsed source, current Swift lines, `grep` counts and `tokens.json`.

## 2. Counts

### 2.1 Per file × class

| file | rows | `token` | `token-new` | `page-local` | `android-only` | `dead` | `stale` |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ChatMetrics.kt` | 374 | 35 | 4 | 69 | 3 | 94 | 169 |
| `SessionsMetrics.kt` | 51 | 7 | 0 | 5 | 0 | 12 | 27 |
| `SettingsMetrics.kt` | 50 | 4 | 0 | 27 | 3 | 15 | 1 |
| `ShellFilesMetrics.kt` | 26 | 6 | 0 | 3 | 0 | 11 | 6 |
| `ConnectorsMetrics.kt` | 26 | 2 | 0 | 23 | 0 | 1 | 0 |
| `UiMetrics.kt` | 24 | 10 | 0 | 3 | 6 | 5 | 0 |
| `HomeMetrics.kt` | 37 | 37 | 0 | 0 | 0 | 0 | 0 |
| **total** | **588** | **101** | **4** | **130** | **12** | **138** | **203** |

### 2.2 Citation audit per file

| file | `holds` | `stale` | `measured` | `no-line` | `token-read` | `design-spec` | `derived` |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ChatMetrics.kt` | 119 | 220 | 5 | 17 | 0 | 9 | 4 |
| `SessionsMetrics.kt` | 2 | 37 | 6 | 6 | 0 | 0 | 0 |
| `SettingsMetrics.kt` | 3 | 4 | 31 | 11 | 0 | 0 | 1 |
| `ShellFilesMetrics.kt` | 2 | 17 | 6 | 1 | 0 | 0 | 0 |
| `ConnectorsMetrics.kt` | 23 | 0 | 0 | 3 | 0 | 0 | 0 |
| `UiMetrics.kt` | 9 | 0 | 4 | 9 | 0 | 0 | 2 |
| `HomeMetrics.kt` | 0 | 0 | 0 | 0 | 37 | 0 | 0 |
| **total** | **158** | **278** | **52** | **47** | **37** | **9** | **7** |

The 278 citation-stale rows are more than the 203 `stale` class rows: 75 stale citations sit on `token` or `dead` rows, where the convergence action is the token read/deletion, not a number change.

`holds` = a cited Swift line still carries the value; `stale` = it does not (current line quoted in the table); `measured` = PNG evidence with no Swift line; `no-line` = the KDoc names a file or nothing but no verifiable line; `token-read` = `HomeMetrics` already reads the generated table; `design-spec` / `derived` = not a Swift literal.

### 2.3 “exact” claims that no longer hold

`Confidence: exact` appears on 448 declarations. **274 of them (61.2%)** now cite a line that does not carry the value. This is a documentation-accuracy problem, not a value problem: the table records both the current line and, where the old snippet can still be found, its new line. The worst single cluster is `ChatPage.swift`: 220 `ChatMetrics` citations are stale (169 of them are class `stale`), and the permission card is the clearest example — it cites :4425–:4469, but the live `PermissionCardView` is at :5158–:5233 (`.padding(14)` at :5227, corner radius 12 at :5228).

### 2.4 Cross-file duplicates

| constant | declared in | values | convergence |
|---|---|---|---|
| `DISCLOSURE_GAP_PT` | `ChatMetrics.kt`, `HomeMetrics.kt`, `UiMetrics.kt` | `8`, `HomeSpecData.DISCLOSURE_GAP`, `8` | one owner; delete the copies |
| `HEADER_HEIGHT_PT` | `ChatMetrics.kt`, `ShellFilesMetrics.kt`, `UiMetrics.kt` | `44`, `44`, `44` | one owner; delete the copies |
| `PARAGRAPH_GAP_PT` | `ChatMetrics.kt`, `HomeMetrics.kt`, `UiMetrics.kt` | `16`, `HomeSpecData.PARAGRAPH_GAP`, `16` | one owner; delete the copies |
| `COMPOSER_CLOSED_HEIGHT_PT` | `ChatMetrics.kt`, `UiMetrics.kt` | `56`, `56` | one owner; delete the copies |
| `COMPOSER_CLOSED_RADIUS_PT` | `ChatMetrics.kt`, `UiMetrics.kt` | `28`, `28` | one owner; delete the copies |
| `COMPOSER_HEIGHT_PT` | `ChatMetrics.kt`, `UiMetrics.kt` | `104`, `104` | one owner; delete the copies |
| `COMPOSER_RADIUS_PT` | `ChatMetrics.kt`, `UiMetrics.kt` | `24`, `24` | one owner; delete the copies |
| `COMPOSER_WIDTH_PT` | `ChatMetrics.kt`, `UiMetrics.kt` | `398`, `398` | one owner; delete the copies |
| `CONTENT_COLUMN_WIDTH_PT` | `ChatMetrics.kt`, `UiMetrics.kt` | `390`, `390` | one owner; delete the copies |
| `DRAWER_ROW_HEIGHT_PT` | `SessionsMetrics.kt`, `ShellFilesMetrics.kt` | `44`, `48` | **same name, different value/role — rename or delete the losing copy** |
| `DRAWER_ROW_ICON_SLOT_PT` | `SessionsMetrics.kt`, `ShellFilesMetrics.kt` | `24`, `22` | **same name, different value/role — rename or delete the losing copy** |
| `FLOW_GAP_PT` | `ChatMetrics.kt`, `UiMetrics.kt` | `20`, `20` | one owner; delete the copies |
| `GROUPED_LIST_BODY_REF_PT` | `SettingsMetrics.kt`, `ShellFilesMetrics.kt` | `16`, `16` | one owner; delete the copies |
| `GROUPED_LIST_MIN_ROW_HEIGHT_PT` | `SettingsMetrics.kt`, `ShellFilesMetrics.kt` | `48`, `48` | one owner; delete the copies |
| `HEADER_TITLE_REF_PT` | `ChatMetrics.kt`, `ShellFilesMetrics.kt` | `17.5f`, `17` | **same name, different value/role — rename or delete the losing copy** |
| `SEARCH_HEIGHT_PT` | `SessionsMetrics.kt`, `ShellFilesMetrics.kt` | `44`, `SessionsMetrics.SEARCH_HEIGHT_PT` | one owner; delete the copies |
| `SEARCH_INSET_PT` | `SessionsMetrics.kt`, `ShellFilesMetrics.kt` | `16`, `16` | one owner; delete the copies |
| `SEARCH_RADIUS_PT` | `SessionsMetrics.kt`, `ShellFilesMetrics.kt` | `22`, `SessionsMetrics.SEARCH_RADIUS_PT` | one owner; delete the copies |
| `SEARCH_TEXT_REF_PT` | `SessionsMetrics.kt`, `ShellFilesMetrics.kt` | `17`, `17` | one owner; delete the copies |
| `SEPARATOR_HEIGHT_PT` | `SessionsMetrics.kt`, `SettingsMetrics.kt` | `0.5f`, `1f` | **same name, different value/role — rename or delete the losing copy** |
| `SEPARATOR_INSET_PT` | `SessionsMetrics.kt`, `SettingsMetrics.kt` | `16`, `16` | one owner; delete the copies |
| `TAB_BAR_HEIGHT_PT` | `HomeMetrics.kt`, `UiMetrics.kt` | `HomeSpecData.TAB_BAR_HEIGHT`, `50` | one owner; delete the copies |

Cross-task ownership: `HEADER_HEIGHT_PT` is shared by T1 (Chat/Ui) and T2 (ShellFiles); `GROUPED_LIST_*` and `SEPARATOR_*` are shared by T2 (Sessions/ShellFiles) and T3 (Settings); `TAB_BAR_HEIGHT_PT` is shared by T1 (Ui) and T4 (Home, already a token read). Land the lower-numbered task first and have the later task read the surviving owner; do not delete both copies in parallel.

`DISCLOSURE_GAP_PT`, `PARAGRAPH_GAP_PT` and `TAB_BAR_HEIGHT_PT` are HomeSpec-token duplicates as well as cross-file duplicates; their copies should be deleted, not renamed. `HEADER_HEIGHT_PT` is declared in three files for three different roles (chat nav 44, shell page header 44, capture header 44) — one token (`geometry.navButton` / its `pageHeaderMinHeight` alias) can own the value, but each call site should read the token by role. `DRAWER_ROW_HEIGHT_PT` and `DRAWER_ROW_ICON_SLOT_PT` are the dangerous pair: the same name means a 44/24 drawer furniture row in `SessionsMetrics` and a 48/22 shell furniture row in `ShellFilesMetrics`; an import of the wrong one compiles and draws the wrong row.

## 3. Full table

Columns: `line` in the Kotlin file; `constant`; `value` as written; `claimed iOS source` is the KDoc’s own `Source:` phrase (truncated where long); `citation check` is the current Swift line after opening it; `refs` is the exact-name Kotlin `grep` count; `class` includes the token id where one applies; `action / note` is the convergence hint. A `stale→` entry gives the line where the old code fragment can still be found; a plain `stale:` entry only proves the cited line is wrong, not where the value moved.

### 3.1 `ChatMetrics.kt` (374 rows)

| # | line | constant | value | claimed iOS source | citation check | refs | class | action / note |
|---:|---:|---|---|---|---|---:|---|---|
| 1 | 48 | `NO_GAP_PT` | `0` | No additional inset; iOS ChatPage.spacing uses zero for the first row. | no citation | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 2 | 53 | `ABOUT_BRANDING_LOGO_SIZE_PT` | `64` | `NativeShell.swift:859-862`. | stale: `NativeShell.swift:859` now `}      private static func join(_ hosts: [String]) -> String {   ` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 3 | 55 | `ABOUT_BRANDING_STACK_GAP_PT` | `8` | `NativeShell.swift:858`. | stale: `NativeShell.swift:858` now `.filter { !$0.isEmpty && $0 != ChatSettings.allowAllEgress }` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 4 | 57 | `ABOUT_BRANDING_ROW_PADDING_V_PT` | `12` | `NativeShell.swift:871`. | stale: `NativeShell.swift:871` now `case pairing` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 5 | 62 | `HEADER_HEIGHT_PT` | `44` | `HomeSpec.navButton = 44`, `.nav { height: 44 }`. | `HomeSpec.navButton` = 44 @ `HomeSpec.swift:65` holds | 7 | `token:geometry.navButton` | read `UiTokenData.geometryNavButton.value.dp` |
| 6 | 69 | `HEADER_TITLE_REF_PT` | `17.5f` | `HomeSpec.navTitleSize = 17.5`.   Reference only: Android text sizes come from `LocalUiType`. | `HomeSpec.navTitleSize` = 17.5 @ `HomeSpec.swift:43` holds | 0 | `dead` | delete; value is token `typography.navTitle`; no Kotlin reader |
| 7 | 72 | `HEADER_TITLE_WEIGHT_REF` | `600` | design spec `nav.title 600`. Reference only. | design spec / Apple HIG (no Swift line) | 0 | `dead` | delete; value is token `typography.navTitle`; no Kotlin reader |
| 8 | 75 | `HEADER_HORIZONTAL_INSET_PT` | `16` | `HomeSpec.chromeInset = 16`. | `HomeSpec.chromeInset` = 16 @ `HomeSpec.swift:16` holds | 2 | `token:geometry.chromeInset` | read `UiTokenData.geometryChromeInset.value.dp` |
| 9 | 78 | `HEADER_LEADING_SLOT_WIDTH_PT` | `44` | `HomeSpec.navButton`, `ChatPage.swift:207`. | `HomeSpec.navButton` = 44 @ `HomeSpec.swift:65` holds | 0 | `dead` | delete; value is token `geometry.navButton`; no Kotlin reader |
| 10 | 81 | `HEADER_DEVICE_SLOT_WIDTH_PT` | `46` | `ChatPage.swift:247`. | stale: `ChatPage.swift:247` now `parentID: row["parentSessionId"]?.stringValue,` | 0 | `dead` | delete |
| 11 | 84 | `HEADER_TRAILING_SLOT_WIDTH_PT` | `46` | `ChatPage.swift:330`. | stale: `ChatPage.swift:330` now `subject: Text("对话记录"),` | 0 | `dead` | delete |
| 12 | 87 | `HEADER_SLOT_HEIGHT_PT` | `44` | `HomeSpec.navButton`. | `HomeSpec.navButton` = 44 @ `HomeSpec.swift:65` holds | 0 | `dead` | delete; value is token `geometry.navButton`; no Kotlin reader |
| 13 | 90 | `HEADER_TITLE_SIDE_RESERVE_PT` | `108` | `HomeSpec.chromeInset/navButton/navPillWidth`. | derived / inferred | 0 | `dead` | delete |
| 14 | 93 | `HEADER_DIVIDER_PT` | `0f` | `ChatPage.swift:384` (`.background(HomeSpec.page)`). | stale: `ChatPage.swift:384` now `.padding(.bottom, 6)` | 0 | `dead` | delete |
| 15 | 96 | `CHAT_HEADER_MORE_ICON_PT` | `18` | `ChatPage.swift:329`. | stale: `ChatPage.swift:329` now `ShareLink(item: historyExport,` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 16 | 98 | `SYSTEM_EVENT_TEXT_GAP_PT` | `2` | `NativeMessageRows.swift:113`. | stale: `NativeMessageRows.swift:113` now `if preferences.collapseTiming == .nextInput && preferences.transc` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 17 | 103 | `CONTENT_COLUMN_WIDTH_PT` | `390` | `HomeSpec.contentInset`. | derived: `430 - 2 × HomeSpec.contentInset (20)`; no single Swift line | 6 | `page-local` | keep local; one page/surface layout value; no token fit |
| 18 | 106 | `TRANSCRIPT_SIDE_INSET_PT` | `20` | `HomeSpec.contentInset = 20`, `ChatPage.swift:1219`. | `HomeSpec.contentInset` = 20 @ `HomeSpec.swift:18` holds | 2 | `token:geometry.contentInset` | read `UiTokenData.geometryContentInset.value.dp` |
| 19 | 109 | `TRANSCRIPT_TOP_INSET_PT` | `20` | design spec spacing table (`20`). | design spec / Apple HIG (no Swift line) | 0 | `dead` | delete |
| 20 | 112 | `TRANSCRIPT_LATEST_CLEARANCE_PT` | `48` | `ChatPage.swift:1224-1225`. | stale: `ChatPage.swift:1224` now `private var transcript: some View {` | 3 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 21 | 114 | `FAILURE_LINE_GAP_PT` | `6` | `ChatPage.swift:955`. | stale: `ChatPage.swift:955` now `if keyboardVisible && !cardsExpanded {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 22 | 116 | `FAILURE_LINE_TOP_PT` | `6` | `ChatPage.swift:976`. | stale: `ChatPage.swift:976` now `ScrollView {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 23 | 118 | `FAILURE_TEXT_SIZE_PT` | `13` | `ChatPage.swift:957-972,1025-1038`. | `ChatPage.swift:957` holds | 8 | `token:typography.secondary` | read `UiTokenData.typeSecondary.baseSize` |
| 24 | 120 | `FAILURE_BANNER_GAP_PT` | `12` | `ChatPage.swift:1023`. | stale: `ChatPage.swift:1023` now `.font(.system(size: 13))` | 1 | `token:geometry.bannerGap` | read `UiTokenData.geometryBannerGap.value.dp` |
| 25 | 122 | `FAILURE_BANNER_INSET_H_PT` | `4` | `ChatPage.swift:1045`. | stale: `ChatPage.swift:1045` now `if previewItems != nil, let state = debugChatState, !didInjectDeb` | 1 | `token:geometry.bannerInsetH` | read `UiTokenData.geometryBannerInsetH.value.dp` |
| 26 | 124 | `FAILURE_BANNER_INSET_V_PT` | `6` | `ChatPage.swift:1046`. | stale: `ChatPage.swift:1046` now `didInjectDebugState = true` | 1 | `token:geometry.bannerInsetV` | read `UiTokenData.geometryBannerInsetV.value.dp` |
| 27 | 127 | `TRANSCRIPT_BOTTOM_INSET_PT` | `104 + 16` | design spec (`输入框高度 + 16`); open composer is 104. | design spec / Apple HIG (no Swift line) | 0 | `dead` | delete |
| 28 | 130 | `FLOW_GAP_PT` | `20` | `HomeSpec.blockGap = 20`. | `HomeSpec.blockGap` = 20 @ `HomeSpec.swift:57` holds | 5 | `token:spacing.blockGap` | read `UiTokenData.spacingBlockGap.dp` |
| 29 | 133 | `RESPONSE_GAP_PT` | `20` | `HomeSpec.blockGap = 20`. | `HomeSpec.blockGap` = 20 @ `HomeSpec.swift:57` holds | 2 | `token:spacing.blockGap` | read `UiTokenData.spacingBlockGap.dp` |
| 30 | 136 | `TURN_GAP_PT` | `20` | `HomeSpec.blockGap = 20`. | `HomeSpec.blockGap` = 20 @ `HomeSpec.swift:57` holds | 2 | `token:spacing.blockGap` | read `UiTokenData.spacingBlockGap.dp` |
| 31 | 139 | `PARAGRAPH_GAP_PT` | `16` | `HomeSpec.paragraphGap = 16`. | `HomeSpec.paragraphGap` = 16 @ `HomeSpec.swift:59` holds | 2 | `token:spacing.paragraphGap` | read `UiTokenData.spacingParagraphGap.dp` |
| 32 | 142 | `DISCLOSURE_GAP_PT` | `8` | `HomeSpec.disclosureGap = 8`. | `HomeSpec.disclosureGap` = 8 @ `HomeSpec.swift:61` holds | 1 | `token:spacing.disclosureGap` | read `UiTokenData.spacingDisclosureGap.dp` |
| 33 | 145 | `DISCLOSURE_ROW_HEIGHT_PT` | `24` | `HomeSpec.processRowHeight = 24`. | `HomeSpec.processRowHeight` = 24 @ `HomeSpec.swift:68` holds | 2 | `token:geometry.processRowHeight` | read `UiTokenData.geometryProcessRowHeight.value.dp` |
| 34 | 148 | `DISCLOSURE_ICON_PT` | `18` | `HomeSpec.processIcon = 18`. | `HomeSpec.processIcon` = 18 @ `HomeSpec.swift:69` holds | 1 | `token:geometry.processIcon` | read `UiTokenData.geometryProcessIcon.value.dp` |
| 35 | 151 | `DISCLOSURE_ICON_GAP_PT` | `6` | design spec (`间隔 6`). | design spec / Apple HIG (no Swift line) | 2 | `token:geometry.disclosureIconGap` | read `UiTokenData.geometryDisclosureIconGap.value.dp` |
| 36 | 154 | `DISCLOSURE_LIST_ICON_BOX_PT` | `16` | `NativeMessageRows.swift:34-35`. | stale: `NativeMessageRows.swift:34` now `ZStack {                         if expanded { NativeChatIcon(nam` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 37 | 156 | `DISCLOSURE_LIST_CATEGORY_ICON_PT` | `14` | `NativeMessageRows.swift:32`. | stale: `NativeMessageRows.swift:32` now `} label: {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 38 | 158 | `DISCLOSURE_LIST_ICON_GAP_PT` | `8` | `NativeMessageRows.swift:36`. | stale: `NativeMessageRows.swift:36` now `else { NativeChatIcon(name: icon, size: inListCard ? 14 : 16) }` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 39 | 161 | `MARKDOWN_COMPACT_BLOCK_SPACING_PT` | `4` | `NativeMarkdownBody.swift` variant blockSpacing. | no line cited (`NativeMarkdownBody.swift`) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 40 | 163 | `MARKDOWN_COMPACT_LIST_STACK_SPACING_PT` | `2` | `NativeMarkdownBody.swift` list spacing. | no line cited (`NativeMarkdownBody.swift`) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 41 | 165 | `MARKDOWN_COMPACT_LIST_ITEM_GAP_PT` | `8` | `NativeMarkdownBody.swift` list HStack. | no line cited (`NativeMarkdownBody.swift`) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 42 | 167 | `MARKDOWN_COMPACT_INLINE_CODE_SIZE_PT` | `13` | `NativeMarkdownBody.swift:267-272`. | stale: `NativeMarkdownBody.swift:267` now `switch part {             case .code, .link, .math:              ` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 43 | 169 | `MARKDOWN_INLINE_CODE_SIZE_OFFSET_PT` | `1` | `NativeMarkdownBody.swift:267-272`. | stale: `NativeMarkdownBody.swift:267` now `switch part {             case .code, .link, .math:              ` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 44 | 172 | `THINKING_CONTENT_INDENT_PT` | `22` | `NativeMessageRows.swift:92` (`.padding(.leading, 22)`). | stale→`NativeMessageRows.swift:105` `.padding(.leading, 22)` | 0 | `dead` | delete; value is token `geometry.thinkingContentIndent`; no Kotlin reader |
| 45 | 175 | `THINKING_CONTENT_VERTICAL_PT` | `4` | `NativeMessageRows.swift:93` (`.padding(.vertical, 4)`). | stale→`NativeMessageRows.swift:106` `.padding(.vertical, 4)` | 0 | `dead` | delete; value is token `geometry.thinkingContentVertical`; no Kotlin reader |
| 46 | 178 | `TURN_PROCESS_HEIGHT_PT` | `24` | `HomeSpec.processRowHeight`. | `HomeSpec.processRowHeight` = 24 @ `HomeSpec.swift:68` holds | 1 | `token:geometry.processRowHeight` | read `UiTokenData.geometryProcessRowHeight.value.dp` |
| 47 | 183 | `USER_BUBBLE_RADIUS_PT` | `24` | `HomeSpec.bubbleRadius = 24`, top-trailing square. | `HomeSpec.bubbleRadius` = 24 @ `HomeSpec.swift:78` holds | 0 | `dead` | delete; value is token `radius.bubble`; no Kotlin reader |
| 48 | 200 | `USER_BUBBLE_LINE_HEIGHT_PT` | `24` | `HomeSpec.bodyLine = 24`. | `HomeSpec.bodyLine` = 24 @ `HomeSpec.swift:48` holds | 0 | `dead` | delete; value is token `typography.body`; no Kotlin reader |
| 49 | 203 | `MESSAGE_PARAGRAPH_SPACING_PT` | `16` | `HomeSpec.paragraphGap = 16`. | `HomeSpec.paragraphGap` = 16 @ `HomeSpec.swift:59` holds | 0 | `dead` | delete; value is token `spacing.paragraphGap`; no Kotlin reader |
| 50 | 206 | `MESSAGE_LIST_SPACING_PT` | `10` | `NativeChatTheme.swift:50`. | stale→`NativeChatTheme.swift:49` `messageListSpacing = 10` (cited :50 is a comment) | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 51 | 209 | `MESSAGE_CONTENT_MARGIN_PT` | `20` | `NativeChatTheme.swift:48`. | stale→`NativeChatTheme.swift:47` `messageContentMargin = 20` | 0 | `dead` | delete |
| 52 | 212 | `COMPOSER_STATS_TOP_PT` | `2` | NativeComposerStats.swift: compact/detailed row both pad top by2, including empty detailed row. | no citation | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 53 | 217 | `COMPOSER_WIDTH_PT` | `398` | `HomeSpec.chromeInset`, design spec `左右边距 16, 宽 398`. | derived: `430 - 2 × HomeSpec.chromeInset (16)`; no single Swift line | 5 | `page-local` | keep local; one page/surface layout value; no token fit |
| 54 | 220 | `COMPOSER_HEIGHT_PT` | `104` | `HomeSpec.composerOpenMinHeight`. | `HomeSpec.composerOpenMinHeight` = 104 @ `HomeSpec.swift:71` holds | 6 | `token:geometry.composerOpenMinHeight` | read `UiTokenData.geometryComposerOpenMinHeight.value.dp` |
| 55 | 223 | `COMPOSER_CLOSED_HEIGHT_PT` | `56` | design spec `.composer.closed { height: 56 }`. | design spec / Apple HIG (no Swift line) | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 56 | 226 | `COMPOSER_RADIUS_PT` | `24` | `HomeSpec.composerOpenRadius = 24`. | `HomeSpec.composerOpenRadius` = 24 @ `HomeSpec.swift:80` holds | 2 | `token:radius.composerOpen` | read `UiTokenData.radiusComposerOpen.dp` |
| 57 | 229 | `COMPOSER_CLOSED_RADIUS_PT` | `28` | design spec `.composer.closed { border-radius: 28 }`. | design spec / Apple HIG (no Swift line) | 0 | `dead` | delete |
| 58 | 232 | `COMPOSER_OUTER_MARGIN_H_PT` | `16` | `HomeSpec.chromeInset = 16`. | `HomeSpec.chromeInset` = 16 @ `HomeSpec.swift:16` holds | 0 | `dead` | delete; value is token `geometry.chromeInset`; no Kotlin reader |
| 59 | 235 | `COMPOSER_OUTER_MARGIN_TOP_PT` | `8` | `ChatPage.swift:1931` (`.padding(.top, 8)`). | stale→`ChatPage.swift:2317` `.padding(.top, 8)` | 0 | `dead` | delete; value is token `geometry.composerOuterMarginTop`; no Kotlin reader |
| 60 | 247 | `COMPOSER_OUTER_MARGIN_BOTTOM_PT` | `0` | commit `86a39aac` changed `ChatPage.swift:1894` `.padding(.bottom, 8)`   to `.padding(.bottom, 0)` — the stats line sits | stale→`ChatPage.swift:2320` `.padding(.bottom, 0)` (value holds at new line) | 1 | `token-new:geometry.composerOuterMarginBottom` | add `geometry.composerOuterMarginBottom` = 0, then read it; signature composer outer bottom inset; provenance ChatPage.swift:2320 `.padding(.bottom, 0)` |
| 61 | 580 | `COMPOSER_PORT_MIN_HEIGHT_PT` | `56` | `ChatPage.swift:2405` (`.frame(height: max(56, composerHeight))`). | `ChatPage.swift:2405` holds | 1 | `page-local` | wave-3 round 1 keeps the port floor at 56 and reads it; the editable surface floor is row 298. Still a `token-new` candidate (`geometry.composerPortMinHeight`) if the composer port is tokenised. |
| 62 | 253 | `COMPOSER_PORT_MAX_HEIGHT_PT` | `336` | `ChatPage.swift:1841` (`maxHeight: 336`). | stale→`ChatPage.swift:2367` `maxHeight: 336` | 0 | `dead` | delete; value is token `geometry.composerMaxHeight`; no Kotlin reader |
| 63 | 256 | `COMPOSER_PORT_LEADING_PT` | `11` | `ChatPage.swift:1991` (`.padding(.leading, 11)`). | stale→`ChatPage.swift:2377` `.padding(.leading, 11)` | 1 | `token-new:geometry.composerPortLeading` | add `geometry.composerPortLeading` = 11, then read it; signature composer input port; provenance ChatPage.swift:2377 `.padding(.leading, 11)` |
| 64 | 259 | `COMPOSER_PORT_TRAILING_PT` | `8` | design spec `.composer.open .row { right: 8 }`. | no line in KDoc (`design spec .composer.open .row { right: 8 }`); source at `ChatPage.swift:2378` | 1 | `token-new:geometry.composerPortTrailing` | add `geometry.composerPortTrailing` = 8, then read it; signature composer input port; provenance ChatPage.swift:2378 `.padding(.trailing, 8)` |
| 65 | 262 | `COMPOSER_PORT_TOP_PT` | `8` | `ChatPage.swift:1993` (`.padding(.top, 8)`). | stale→`ChatPage.swift:2379` `.padding(.top, 8)` | 0 | `dead` | delete; value is token `geometry.composerPortTop`; no Kotlin reader |
| 66 | 269 | `COMPOSER_FONT_REF_PT` | `16` | `NativeParityTokens.swift:79`. Reference only: Android text sizes   come from `LocalUiType`. | `NativeParityTokens.swift:79` `composerFontSize = 16` holds | 0 | `dead` | delete; value is token `typography.body`; no Kotlin reader |
| 67 | 272 | `COMPOSER_CONTROL_ROW_HEIGHT_PT` | `44` | `ChatPage.swift:2007` (`.frame(height: 44)`). | stale→`ChatPage.swift:2393` `.frame(height: 44)` | 3 | `token:geometry.composerControlHeight` | read `UiTokenData.geometryComposerControlHeight.value.dp` |
| 68 | 275 | `COMPOSER_CONTROL_LEADING_PT` | `8` | `ChatPage.swift:2005`. | stale: `ChatPage.swift:2005` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 69 | 278 | `COMPOSER_CONTROL_TRAILING_RESERVE_PT` | `40` | `ChatPage.swift:1866` (`.padding(.trailing, 40)`). | stale: `ChatPage.swift:1866` now `}` | 0 | `dead` | delete |
| 70 | 281 | `COMPOSER_CONTROL_TOP_PT` | `4` | `ChatPage.swift:2008`. | stale: `ChatPage.swift:2008` now `.padding(.vertical, 2)` | 0 | `dead` | delete; value is token `geometry.composerControlTop`; no Kotlin reader |
| 71 | 284 | `COMPOSER_CONTROL_BOTTOM_PT` | `4` | `ChatPage.swift:2009`. | stale: `ChatPage.swift:2009` now `.background(NativeParityTokens.menu,` | 1 | `token:geometry.composerControlBottom` | read `UiTokenData.geometryComposerControlBottom.value.dp` |
| 72 | 287 | `SEND_DIAMETER_PT` | `36` | `HomeSpec.sendButton = 36`. | `HomeSpec.sendButton` = 36 @ `HomeSpec.swift:72` holds | 2 | `token:geometry.sendButton` | read `UiTokenData.geometrySendButton.value.dp` |
| 73 | — | `SEND_HIT_PT` | `44` | Android touch frame; paint stays at the source 36pt diameter, trailing-aligned to preserve its 8pt visual gaps. Conf | no citation | 0 | `deleted` | deleted in wave-3 round 1 (`06e39dd2`); the shared composer send key reads the source 36 pt paint and no Kotlin reader remains. |
| 74 | 293 | `SEND_OVERLAY_INSET_PT` | `8` | design spec (`离右边和底边各 8`). | design spec / Apple HIG (no Swift line) | 0 | `dead` | delete |
| 75 | 296 | `STOP_INLINE_DIAMETER_PT` | `36` | `HomeSpec.sendButton`. | `HomeSpec.sendButton` = 36 @ `HomeSpec.swift:72` holds | 0 | `dead` | delete; value is token `geometry.sendButton`; no Kotlin reader |
| 76 | 299 | `STOP_DIAMETER_PT` | `36` | `HomeSpec.sendButton = 36`. | `HomeSpec.sendButton` = 36 @ `HomeSpec.swift:72` holds | 0 | `dead` | delete; value is token `geometry.sendButton`; no Kotlin reader |
| 77 | 302 | `BACK_TO_LATEST_PADDING_H_PT` | `12` | `ChatPage.swift:1337`. | stale: `ChatPage.swift:1337` now `if #available(iOS 18.0, *) {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 78 | 305 | `BACK_TO_LATEST_PADDING_V_PT` | `8` | `ChatPage.swift:1338`. | stale: `ChatPage.swift:1338` now `// `onScrollGeometryChange` below replaces both` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 79 | 308 | `BACK_TO_LATEST_BOTTOM_PT` | `12` | `ChatPage.swift:1343-1345`. | stale: `ChatPage.swift:1343` now `.id("transcript-tail")                         } else {          ` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 80 | 309 | `BACK_TO_LATEST_BORDER_PT` | `1` |  | no citation | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 81 | 312 | `BACK_TO_LATEST_LABEL_PT` | `12` | Apple HIG Typography, “Text styles”; `ChatPage.swift:1335`. | stale: `ChatPage.swift:1335` now `.id("running-status")` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 82 | 314 | `BACK_TO_LATEST_LABEL_LINE_HEIGHT_PT` | `16` | Apple HIG Typography, “Text styles”. | design spec / Apple HIG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 83 | 317 | `BACK_TO_LATEST_RADIUS_PT` | `12` | `ChatPage.swift:1341-1342`. | stale: `ChatPage.swift:1341` now `Color.clear                                 .frame(height: 1)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 84 | 322 | `QUEUE_ROW_HEIGHT_PT` | `28` | `ChatPage.swift:1690` (`.frame(height: 28)`), radius at `:1692`. | stale→`ChatPage.swift:1648` `.frame(height: 28)` | 0 | `dead` | delete |
| 85 | 325 | `QUEUE_ROW_RADIUS_PT` | `8` | `ChatPage.swift:1692` (`RoundedRectangle(cornerRadius: 8)`). | stale: `ChatPage.swift:1692` now `VStack(alignment: .leading, spacing: 0) {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 86 | 328 | `QUEUE_DOCK_HEADER_HEIGHT_PT` | `32` | `ChatPage.swift:1557`. | stale: `ChatPage.swift:1557` now `scrollToTail(proxy, viewportHeight: viewportHeight)` | 0 | `dead` | delete |
| 87 | 331 | `QUEUE_DOCK_RADIUS_PT` | `12` | `ChatPage.swift:1577`. | stale: `ChatPage.swift:1577` now `let away = !near` | 0 | `dead` | delete |
| 88 | 334 | `QUEUE_ROW_INSET_H_PT` | `10` | `ChatPage.swift:1641`. | stale: `ChatPage.swift:1641` now `HStack(spacing: 6) {` | 0 | `dead` | delete |
| 89 | 339 | `PERMISSION_CARD_RADIUS_PT` | `12` | `ChatPage.swift:4467`. | stale→`ChatPage.swift:5228` `cornerRadius: 12` | 3 | `token:radius.card` | read `UiTokenData.radiusCard.dp` |
| 90 | 342 | `PERMISSION_CARD_PADDING_PT` | `14` | `ChatPage.swift:4465` (`.padding(14)`). | stale→`ChatPage.swift:5227` `.padding(14)` | 1 | `token:geometry.cardPadding` | read `UiTokenData.geometryCardPadding.value.dp` |
| 91 | 345 | `PERMISSION_CARD_SPACING_PT` | `10` | `ChatPage.swift:4425` (`VStack(spacing: 10)`). | stale→`ChatPage.swift:5176` `VStack(alignment: .leading, spacing: 10)` | 3 | `token-new:geometry.approvalCardSpacing` | add `geometry.approvalCardSpacing` = 10, then read it; signature approval card; provenance ChatPage.swift:5176 `VStack(alignment: .leading, spacing: 10)` |
| 92 | 348 | `PERMISSION_CARD_OUTER_MARGIN_H_PT` | `16` | `ChatPage.swift:4468-4469`. | stale→`ChatPage.swift:5229` `.padding(.horizontal, 16)` | 1 | `token:geometry.cardOuterMarginH` | read `UiTokenData.geometryCardOuterMarginH.value.dp` |
| 93 | 351 | `PERMISSION_CARD_OUTER_MARGIN_V_PT` | `8` | `ChatPage.swift:4469`. | stale→`ChatPage.swift:5230` `.padding(.vertical, 8)` | 1 | `token:geometry.cardOuterMarginV` | read `UiTokenData.geometryCardOuterMarginV.value.dp` |
| 94 | 354 | `PERMISSION_PRIMARY_HEIGHT_PT` | `48` | `ChatPage.swift:4447` (`.frame(height: 48)`). | stale→`ChatPage.swift:5209` `.frame(height: 48)` | 1 | `token:geometry.primaryButtonHeight` | read `UiTokenData.geometryPrimaryButtonHeight.value.dp` |
| 95 | 357 | `PERMISSION_PRIMARY_RADIUS_PT` | `12` | `ChatPage.swift:4448`. | stale→`ChatPage.swift:5210` `cornerRadius: 12` | 1 | `token:radius.card` | read `UiTokenData.radiusCard.dp` |
| 96 | 360 | `PERMISSION_DENY_HEIGHT_PT` | `44` | `ChatPage.swift:4460`. | stale→`ChatPage.swift:5222` `.frame(height: 44)` | 1 | `token:geometry.secondaryButtonHeight` | read `UiTokenData.geometrySecondaryButtonHeight.value.dp` |
| 97 | 363 | `QUESTION_RADIO_OUTLINE_PT` | `20` | Single-choice marker outer diameter in the current Android question fallback; source is the 20pt question marker in | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 98 | 365 | `QUESTION_RADIO_DOT_PT` | `8` | PR22 reference capture. | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 99 | 367 | `QUESTION_CHECKBOX_FRAME_PT` | `20` | `NativeQuestionComposer.swift:724`. | stale: `NativeQuestionComposer.swift:724` now `.frame(width: 24, height: 24).contentShape(Rectangle())` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 100 | 369 | `QUESTION_CHECKBOX_RADIUS_PT` | `4` | `NativeQuestionComposer.swift:675-691`. | stale: `NativeQuestionComposer.swift:675` now `.accessibilityHidden(true)     } }  private struct NativeQuestion` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 101 | 371 | `QUESTION_CHECKBOX_GLYPH_PT` | `14` | `NativeQuestionComposer.swift:691`. | `NativeQuestionComposer.swift:691` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 102 | 373 | `QUESTION_ANSWER_ADD_ICON_PT` | `16` | PR22 reference capture. | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 103 | 375 | `QUESTION_PAGER_ICON_PT` | `13` | `NativeQuestionComposer.swift:723-724`. | `NativeQuestionComposer.swift:723` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 104 | 377 | `QUESTION_HEADER_ACTION_GLYPH_PT` | `13` | `NativeQuestionComposer.swift:723-724`. | `NativeQuestionComposer.swift:723` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 105 | 379 | `PLAN_REVIEW_CHANGE_GLYPH_PT` | `14` | `ChatPage.swift:1585`. | stale: `ChatPage.swift:1585` now `if userScrolledAway { userScrolledAway = false }` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 106 | 381 | `GOAL_CLEAR_GLYPH_PT` | `11` | `ChatPage.swift:1514-1515`. | stale: `ChatPage.swift:1514` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 107 | 383 | `TODO_DOCK_GLYPH_PT` | `14` | `NativeTodoDock.swift:103-104`. | stale: `NativeTodoDock.swift:103` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 108 | 385 | `TODO_DOCK_CHEVRON_PT` | `14` | `NativeTodoDock.swift:130`. | `NativeTodoDock.swift:130` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 109 | 387 | `ATTACHMENT_DOCUMENT_GLYPH_PT` | `16` | PR22 reference capture. | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 110 | 389 | `ATTACHMENT_REMOVE_GLYPH_PT` | `14` | PR22 reference capture. | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 111 | 391 | `ACCESS_MODE_ICON_GAP_PT` | `2` | `ChatPage.swift` accessModeMenu. | no line cited (`ChatPage.swift`) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 112 | 393 | `ACCESS_MODE_SHIELD_GLYPH_PT` | `20` | `ChatPage.swift:2210-2218`. | stale: `ChatPage.swift:2210` now `}      private func nativeQuestionItems(_ question: HarnessQuesti` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 113 | 395 | `ACCESS_MODE_CHEVRON_GLYPH_PT` | `10` | `ChatPage.swift:2210-2218`. | stale: `ChatPage.swift:2210` now `}      private func nativeQuestionItems(_ question: HarnessQuesti` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 114 | 397 | `ACCESS_MODE_ALERT_DOT_PT` | `6` | `ChatPage.swift` accessModeMenu label. | no line cited (`ChatPage.swift`) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 115 | 399 | `ACCESS_MODE_SPINNER_STROKE_PT` | `1.5f` | `ChatPage.swift` accessModeMenu label. | no line cited (`ChatPage.swift`) | 1 | `android-only` | keep local; Compose circular-progress stroke has no iOS `ProgressView` equivalent; §5 has no id — platform-forced approximation. |
| 116 | 401 | `MODEL_EFFORT_GAP_PT` | `6` | `ChatPage.swift:2354`. | stale: `ChatPage.swift:2354` now `.foregroundStyle(HomeSpec.inputPlaceholder)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 117 | 403 | `MODEL_MENU_CHEVRON_GLYPH_PT` | `12` | `ChatPage.swift:2363`. | stale: `ChatPage.swift:2363` now `isEditable: composerEnabled,` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 118 | 405 | `COMPOSER_MENU_CHECK_GLYPH_PT` | `16` | `ChatPage.swift` model/access menu selection rows. | no line cited (`ChatPage.swift`) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 119 | 408 | `CHAT_QUEUE_HEADER_GAP_PT` | `10` | `ChatPage.swift:1632`. | stale: `ChatPage.swift:1632` now `/// fallback for a page that truly rendered nothing.` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 120 | 410 | `CHAT_QUEUE_HEADER_ICON_PT` | `14` | `ChatPage.swift:1625-1626`. | stale: `ChatPage.swift:1625` now `scrollToTail(proxy, viewportHeight: viewportHeight)         }` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 121 | 412 | `CHAT_QUEUE_HEADER_HEIGHT_PT` | `32` | `ChatPage.swift:1636`. | stale: `ChatPage.swift:1636` now `(blank line)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 122 | 414 | `CHAT_QUEUE_HEADER_FONT_PT` | `13` | `ChatPage.swift:1628`. | stale: `ChatPage.swift:1628` now `(blank line)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 123 | 416 | `CHAT_QUEUE_HEADER_CHEVRON_PT` | `12` | `ChatPage.swift:1633`. | stale: `ChatPage.swift:1633` now `private var oldPageDuringSwitch: SessionSwitchPresentationPolicy.` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 124 | 418 | `CHAT_QUEUE_ROW_GLYPH_PT` | `12` | `ChatPage.swift:1680`. | stale: `ChatPage.swift:1680` now `} else if providerNeedsKey {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 125 | 420 | `CHAT_QUEUE_ROW_GLYPH_BOX_PT` | `16` | `ChatPage.swift:1682`. | stale: `ChatPage.swift:1682` now `.padding(.top, 88)` | 0 | `dead` | delete |
| 126 | 422 | `CHAT_QUEUE_ROW_FONT_PT` | `13` | `ChatPage.swift:1685`. | stale: `ChatPage.swift:1685` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 127 | 424 | `CHAT_QUEUE_ACTION_GLYPH_PT` | `13` | `ChatPage.swift:1729`. | stale: `ChatPage.swift:1729` now `private var engineNotStartedState: some View {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 128 | 426 | `CHAT_QUEUE_ACTION_ICON_BOX_PT` | `28` | `ChatPage.swift:1731`. | stale: `ChatPage.swift:1731` now `Text("引擎还没启动")` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 129 | 428 | `CHAT_QUEUE_ACTION_TARGET_WIDTH_PT` | `34` | `ChatPage.swift:1732`. | stale: `ChatPage.swift:1732` now `.font(.system(size: 17.5, weight: .semibold))` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 130 | 430 | `CHAT_QUEUE_ACTION_TARGET_HEIGHT_PT` | `36` | `ChatPage.swift:1732`. | stale: `ChatPage.swift:1732` now `.font(.system(size: 17.5, weight: .semibold))` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 131 | 432 | `CHAT_QUEUE_ROW_MIN_HEIGHT_PT` | `36` | `ChatPage.swift:1721`. | stale: `ChatPage.swift:1721` now `case .offline:` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 132 | 434 | `CHAT_QUEUE_ROW_INSET_H_PT` | `10` | `ChatPage.swift:1720`. | stale: `ChatPage.swift:1720` now `return "正在重新连上这台电脑，连上后会回到上次的会话。"` | 4 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 133 | 436 | `CHAT_QUEUE_ROW_GAP_PT` | `8` | `ChatPage.swift:1677`. | stale: `ChatPage.swift:1677` now `} else if !model.isStarted {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 134 | 438 | `CHAT_QUEUE_STACK_GAP_PT` | `4` | `ChatPage.swift:1619`. | stale: `ChatPage.swift:1619` now `}` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 135 | 440 | `CHAT_QUEUE_CARD_INSET_V_PT` | `2` | `ChatPage.swift:1654`. | stale: `ChatPage.swift:1654` now `(blank line)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 136 | 442 | `CHAT_QUEUE_DIVIDER_INSET_PT` | `38` | `ChatPage.swift:1649`. | stale: `ChatPage.swift:1649` now `.background(HomeSpec.surface, in: Capsule())` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 137 | 444 | `CHAT_QUEUE_PENDING_STACK_GAP_PT` | `4` | `ChatPage.swift:1753`. | stale: `ChatPage.swift:1753` now `VStack(alignment: .leading, spacing: 0) {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 138 | 446 | `CHAT_QUEUE_PENDING_CONTENT_GAP_PT` | `8` | `ChatPage.swift:1755`. | stale: `ChatPage.swift:1755` now `.font(.system(size: 17.5, weight: .semibold))` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 139 | 448 | `CHAT_QUEUE_PENDING_TEXT_PT` | `13` | `ChatPage.swift:1759,1762`. | stale: `ChatPage.swift:1759` now `.foregroundStyle(HomeSpec.textPlaceholder)                 showPr` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 140 | 450 | `CHAT_QUEUE_PENDING_HEIGHT_PT` | `28` | `ChatPage.swift:1769`. | stale: `ChatPage.swift:1769` now `.frame(maxWidth: .infinity, alignment: .leading)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 141 | 452 | `CHAT_QUEUE_PENDING_INSET_H_PT` | `10` | `ChatPage.swift:1768`. | stale: `ChatPage.swift:1768` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 142 | 454 | `CHAT_QUEUE_PENDING_SPINNER_PT` | `12` | `ChatPage.swift:1756` (`controlSize(.mini)`). | stale: `ChatPage.swift:1756` now `.foregroundStyle(HomeSpec.textPrimary)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 143 | 457 | `TOOL_CARD_RADIUS_PT` | `16` | `NativeToolCardChrome.swift:33` (`radiusLG` = 16). | stale: `NativeToolCardChrome.swift:33` now `static let borderWidth: CGFloat = 0.5` | 0 | `dead` | delete |
| 144 | 460 | `TOOL_CARD_BORDER_PT` | `0.5f` | `NativeToolCardChrome.swift:34`. | stale: `NativeToolCardChrome.swift:34` now `static let outerTop: CGFloat = 4, outerBottom: CGFloat = 4, outer` | 0 | `dead` | delete; value is token `stroke.hairline`; no Kotlin reader |
| 145 | 463 | `TOOL_CARD_OUTER_PT` | `4` | `NativeToolCardChrome.swift:34`. | `NativeToolCardChrome.swift:34` holds | 0 | `dead` | delete |
| 146 | 466 | `TOOL_CARD_HEADER_TOP_PT` | `10` | `NativeToolCardChrome.swift:37`. | `NativeToolCardChrome.swift:37` holds | 0 | `dead` | delete |
| 147 | 469 | `TOOL_CARD_HEADER_BOTTOM_PT` | `8` | `NativeToolCardChrome.swift:37`. | `NativeToolCardChrome.swift:37` holds | 0 | `dead` | delete |
| 148 | 472 | `TOOL_CARD_HEADER_LEADING_PT` | `22` | `NativeToolCardChrome.swift:38`. | `NativeToolCardChrome.swift:38` holds | 0 | `dead` | delete |
| 149 | 475 | `TOOL_CARD_HEADER_TRAILING_PT` | `18` | `NativeToolCardChrome.swift:38`. | `NativeToolCardChrome.swift:38` holds | 0 | `dead` | delete |
| 150 | 478 | `TOOL_CARD_ACTION_TARGET_PT` | `24` | `NativeToolCardChrome.swift:43`. | `NativeToolCardChrome.swift:43` holds | 0 | `dead` | delete |
| 151 | 481 | `TOOL_CARD_BODY_HORIZONTAL_PT` | `22` | `NativeToolCardChrome.swift:48`. | `NativeToolCardChrome.swift:48` holds | 0 | `dead` | delete |
| 152 | 484 | `TOOL_CARD_BODY_TOP_PT` | `6` | `NativeToolCardChrome.swift:49`. | `NativeToolCardChrome.swift:49` holds | 0 | `dead` | delete |
| 153 | 487 | `TOOL_CARD_BODY_BOTTOM_PT` | `20` | `NativeToolCardChrome.swift:49`. | `NativeToolCardChrome.swift:49` holds | 0 | `dead` | delete |
| 154 | 490 | `TOOL_CARD_IO_HORIZONTAL_PT` | `16` | `NativeToolCardChrome.swift:56`. | `NativeToolCardChrome.swift:56` holds | 0 | `dead` | delete |
| 155 | 493 | `TOOL_CARD_IO_VERTICAL_PT` | `12` | `NativeToolCardChrome.swift:56`. | `NativeToolCardChrome.swift:56` holds | 0 | `dead` | delete |
| 156 | 496 | `TOOL_CARD_IO_MAX_HEIGHT_PT` | `150` | `NativeToolCardChrome.swift:57`. | `NativeToolCardChrome.swift:57` holds | 0 | `dead` | delete |
| 157 | 499 | `TOOL_DETAILS_PADDING_PT` | `12` | `NativeToolDetailsCard.swift:23`. | `NativeToolDetailsCard.swift:23` holds | 0 | `dead` | delete |
| 158 | 502 | `TOOL_DETAILS_ITEM_PADDING_V_PT` | `10` | `NativeToolDetailsCard.swift:24`. | `NativeToolDetailsCard.swift:24` holds | 0 | `dead` | delete |
| 159 | 505 | `TOOL_DETAILS_ITEM_PADDING_H_PT` | `14` | `NativeToolDetailsCard.swift:24`. | `NativeToolDetailsCard.swift:24` holds | 0 | `dead` | delete |
| 160 | 508 | `TOOL_DETAILS_LIST_MAX_HEIGHT_PT` | `320` | `NativeToolDetailsCard.swift:25`. | `NativeToolDetailsCard.swift:25` holds | 0 | `dead` | delete |
| 161 | 511 | `CODE_BLOCK_RADIUS_PT` | `12` | `Components.swift:221` (`.clipShape(RoundedRectangle(cornerRadius: 12 ...))`). | `Components.swift:221` holds | 0 | `dead` | delete; value is token `radius.codeBlock`; no Kotlin reader |
| 162 | 514 | `CODE_BLOCK_BANNER_HEIGHT_PT` | `34` | `Components.swift:196` (`.frame(height: 34)`). | `Components.swift:196` holds | 0 | `dead` | delete; value is token `spacing.codeHeaderHeight`; no Kotlin reader |
| 163 | 517 | `CODE_BLOCK_PADDING_PT` | `12` | `Components.swift:209` (`.padding(12)`). | stale→`Components.swift:205` `.padding(12)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 164 | 520 | `CODE_BLOCK_EXPAND_HEIGHT_PT` | `32` | `Components.swift:216` (`.frame(height: 32)`). | `Components.swift:216` holds | 0 | `dead` | delete; value is token `spacing.codeExpandHeight`; no Kotlin reader |
| 165 | 523 | `CODE_BLOCK_COLLAPSED_MAX_HEIGHT_PT` | `300` | `Components.swift:207` (`isLong ? 300 : nil`). | `Components.swift:207` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 166 | 526 | `TODO_DOCK_HEIGHT_PT` | `36` | `NativeParityTokens.swift:102`. | `NativeParityTokens.swift:102` holds | 0 | `dead` | delete |
| 167 | 529 | `TODO_LIST_MAX_HEIGHT_PT` | `180` | `NativeParityTokens.swift:103`. | `NativeParityTokens.swift:103` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 168 | 532 | `QUESTION_MAX_HEIGHT_PT` | `520` | `NativeParityTokens.swift:104`. | `NativeParityTokens.swift:104` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 169 | 535 | `QUESTION_OPTION_MIN_HEIGHT_PT` | `40` | `NativeParityTokens.swift:105`. | `NativeParityTokens.swift:105` holds | 0 | `dead` | delete |
| 170 | 538 | `PLAN_CARD_HEIGHT_PT` | `60` | `NativeParityTokens.swift:106`. | `NativeParityTokens.swift:106` holds | 0 | `dead` | delete |
| 171 | 541 | `SUBAGENT_MENU_WIDTH_PT` | `336` | `NativeParityTokens.swift:107`. | `NativeParityTokens.swift:107` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 172 | 543 | `SUBAGENT_MENU_MAX_HEIGHT_PT` | `560` | `NativeSubagentCatalogSheet.swift:124`. | stale: `NativeSubagentCatalogSheet.swift:124` now `(blank line)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 173 | 545 | `SUBAGENT_MENU_MIN_HEIGHT_PT` | `120` | `NativeSubagentCatalogSheet.swift:125`. | stale: `NativeSubagentCatalogSheet.swift:125` now `private var maxHeight: CGFloat {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 174 | 547 | `SUBAGENT_SHEET_TOP_INSET_PT` | `20` | `ChatPage.swift:481`. | stale: `ChatPage.swift:481` now `.onDisappear { voice.cancel(); voice.stopSpeaking() }` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 175 | 549 | `SUBAGENT_MENU_CARD_PADDING_PT` | `4` | `NativeSubagentCatalogSheet.swift:107`. | stale: `NativeSubagentCatalogSheet.swift:107` now `.background(HomeSpec.surface,` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 176 | 551 | `SUBAGENT_TITLE_STACK_GAP_PT` | `0` | `NativeSubagentCatalogSheet.swift:282`. | stale: `NativeSubagentCatalogSheet.swift:282` now `Button(action: onOpen) {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 177 | 553 | `SUBAGENT_ERROR_MESSAGE_PADDING_PT` | `8` | All-side inset retained by the Android inline notice, with no visual change. Confidence: existing implementation. | no citation | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 178 | 555 | `SUBAGENT_ROW_MIN_HEIGHT_PT` | `44` | `NativeSubagentCatalogSheet.swift:246`. | stale: `NativeSubagentCatalogSheet.swift:246` now `.padding(.vertical, 6)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 179 | 557 | `SUBAGENT_ROW_INSET_V_PT` | `6` | `NativeSubagentCatalogSheet.swift:245`. | stale: `NativeSubagentCatalogSheet.swift:245` now `.padding(.trailing, 7)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 180 | 559 | `SUBAGENT_ROW_INSET_LEADING_PT` | `9` | `NativeSubagentCatalogSheet.swift:243`. | stale: `NativeSubagentCatalogSheet.swift:243` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 181 | 561 | `SUBAGENT_ROW_INSET_TRAILING_PT` | `7` | `NativeSubagentCatalogSheet.swift:244`. | stale: `NativeSubagentCatalogSheet.swift:244` now `.padding(.leading, CGFloat(depth - 1) * 19 + 9)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 182 | 563 | `SUBAGENT_ROW_GAP_PT` | `6` | `NativeSubagentCatalogSheet.swift:236,280`. | stale: `NativeSubagentCatalogSheet.swift:236` now `var body: some View {` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 183 | 565 | `SUBAGENT_ACTIVITY_SLOT_PT` | `14` | `NativeSubagentCatalogSheet.swift:325`. | stale: `NativeSubagentCatalogSheet.swift:325` now `(blank line)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 184 | 567 | `SUBAGENT_ACTIVITY_DOT_PT` | `6` | `NativeSubagentCatalogSheet.swift:313-316`. | `NativeSubagentCatalogSheet.swift:313` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 185 | 569 | `SUBAGENT_TITLE_REF_PT` | `15` | `NativeSubagentCatalogSheet.swift:284`. | stale: `NativeSubagentCatalogSheet.swift:284` now `activitySlot` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 186 | 571 | `SUBAGENT_SECONDARY_REF_PT` | `13` | `NativeSubagentCatalogSheet.swift:324`. | stale: `NativeSubagentCatalogSheet.swift:324` now `}` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 187 | 573 | `SUBAGENT_SECONDARY_HEIGHT_PT` | `15` | `NativeSubagentCatalogSheet.swift:321-324`. | stale: `NativeSubagentCatalogSheet.swift:321` now `}         }         .frame(width: 14, height: 17)     }` | 3 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 188 | 575 | `SUBAGENT_SHEET_HEIGHT_REDUCTION_PT` | `260` | `NativeSubagentCatalogSheet.swift:125` with its ChatPage caller's screenH−120. | stale: `NativeSubagentCatalogSheet.swift:125` now `private var maxHeight: CGFloat {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 189 | 577 | `SUBAGENT_CARD_MIN_HEIGHT_PT` | `44` | `NativeSubagentCatalogSheet.swift:130`. | stale: `NativeSubagentCatalogSheet.swift:130` now `let notice: CGFloat = errorText != nil ? 48 : (isLoading ? 32 : 0` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 190 | 579 | `SUBAGENT_CARD_BASE_PADDING_PT` | `8` | `NativeSubagentCatalogSheet.swift:130`. | stale: `NativeSubagentCatalogSheet.swift:130` now `let notice: CGFloat = errorText != nil ? 48 : (isLoading ? 32 : 0` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 191 | 581 | `SUBAGENT_ROW_CARD_HEIGHT_PT` | `44` | `NativeSubagentCatalogSheet.swift:130`. | stale: `NativeSubagentCatalogSheet.swift:130` now `let notice: CGFloat = errorText != nil ? 48 : (isLoading ? 32 : 0` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 192 | 583 | `SUBAGENT_DISCLOSURE_SLOT_PT` | `14` | `NativeSubagentCatalogSheet.swift:257-275`. | `NativeSubagentCatalogSheet.swift:257` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 193 | 585 | `SUBAGENT_DISCLOSURE_HEIGHT_PT` | `17` | `NativeSubagentCatalogSheet.swift:266,320`. | stale: `NativeSubagentCatalogSheet.swift:266` now `.rotationEffect(.degrees(isExpanded ? 90 : 0))                 }` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 194 | 587 | `SUBAGENT_TITLE_LINE_HEIGHT_PT` | `22` | `NativeSubagentCatalogSheet.swift:288`. | stale: `NativeSubagentCatalogSheet.swift:288` now `.foregroundStyle(HomeSpec.textPrimary)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 195 | 589 | `SUBAGENT_SECONDARY_GAP_PT` | `4` | `NativeSubagentCatalogSheet.swift:324`. | stale: `NativeSubagentCatalogSheet.swift:324` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 196 | 591 | `SUBAGENT_MODE_CHIP_RADIUS_PT` | `4` | `NativeSubagentCatalogSheet.swift:335`. | `NativeSubagentCatalogSheet.swift:335` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 197 | 593 | `SUBAGENT_MODE_CHIP_INSET_H_PT` | `4` | `NativeSubagentCatalogSheet.swift:332`. | stale: `NativeSubagentCatalogSheet.swift:332` now `Text(modeText)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 198 | 595 | `SUBAGENT_ERROR_ROW_HEIGHT_PT` | `48` | `NativeSubagentCatalogSheet.swift:218-220`. | stale: `NativeSubagentCatalogSheet.swift:218` now `}         .padding(.horizontal, 10)         .padding(.vertical, 8` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 199 | 597 | `SUBAGENT_NO_NOTICE_HEIGHT_PT` | `0` | `NativeSubagentCatalogSheet.swift` cardHeight. | no line cited (`NativeSubagentCatalogSheet.swift`) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 200 | 602 | `CHAT_DRAWER_WIDTH_PT` | `44` | `HomeSpec.navButton = 44`. | `HomeSpec.navButton` = 44 @ `HomeSpec.swift:65` holds | 0 | `dead` | delete; value is token `geometry.navButton`; no Kotlin reader |
| 201 | 604 | `CHAT_DEVICE_ENTRY_WIDTH_PT` | `46` | `HomeSpec.navPillWidth`. | `HomeSpec.navPillWidth` = 92; half = 46 holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 202 | 606 | `CHAT_HEADER_MENU_WIDTH_PT` | `46` | `HomeSpec.navPillWidth`. | `HomeSpec.navPillWidth` = 92; half = 46 holds | 0 | `dead` | delete |
| 203 | 608 | `CHAT_HEADER_TITLE_RESERVE_PT` | `108` | `HomeSpec.chromeInset/navButton/navPillWidth`. | derived / inferred | 0 | `dead` | delete |
| 204 | 610 | `CHAT_HEADER_GROUP_GAP_PT` | `0` | design spec (two 46 pt halves, no gap). | design spec / Apple HIG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 205 | 612 | `CHAT_DRAWER_ICON_PT` | `22` | `HomeSpec.swift:207-211`. | stale: `HomeSpec.swift:207` now `.environment(\.defaultMinListRowHeight, 48)             .tint(Hom` | 1 | `token:geometry.navIcon` | read `UiTokenData.geometryNavIcon.value.dp` |
| 206 | 614 | `CHAT_DEVICE_STATUS_DOT_PT` | `6` | `NativeDeviceConnectionPage.swift:16-19`. | `NativeDeviceConnectionPage.swift:16` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 207 | 616 | `CHAT_DEVICE_STATUS_BORDER_PT` | `1` | `NativeDeviceConnectionPage.swift:19`. | stale: `NativeDeviceConnectionPage.swift:19` now `.offset(x: 4, y: -2)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 208 | 618 | `CHAT_DEVICE_STATUS_INSET_PT` | `9` | `NativeDeviceConnectionPage.swift:17-19`. | stale: `NativeDeviceConnectionPage.swift:17` now `.frame(width: 6, height: 6)                         .overlay(Circ` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 209 | 620 | `CHAT_DEVICE_ICON_SIZE_PT` | `19` | `ChatPage.swift:246`. | stale: `ChatPage.swift:246` now `activity: running ? .running : .inactive,` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 210 | 623 | `EMPTY_STATE_TOP_PT` | `88` | `ChatPage.swift:1402-1408`. | stale: `ChatPage.swift:1402` now `guard scrollTrace.contentHeight > 0 else { return }              ` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 211 | 625 | `EMPTY_STATE_TITLE_SIZE_PT` | `17.5f` | `ChatPage.swift:1420,1442`. | stale: `ChatPage.swift:1420` now `// different heights; the replacement must anchor again.         ` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 212 | 627 | `EMPTY_STATE_HINT_SIZE_PT` | `14` | `ChatPage.swift:1423,1445`. | stale: `ChatPage.swift:1423` now `scrollTrace.contentHeight = 0         // delay, so it cannot chan` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 213 | 629 | `EMPTY_STATE_HINT_TOP_PT` | `8` | `ChatPage.swift:1425,1447`. | stale: `ChatPage.swift:1425` now `}             Group {` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 214 | 631 | `EMPTY_STATE_ACTION_TOP_PT` | `24` | `ChatPage.swift:1433,1455`. | stale: `ChatPage.swift:1433` now `.onChange(of: viewport.size.height) { old, new in             // ` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 215 | 633 | `EMPTY_STATE_ACTION_HEIGHT_PT` | `50` | `HomeSpec.swift:211-220`. | stale→`HomeSpec.swift:239` `.frame(height: 50)` | 2 | `token:geometry.homePrimaryButtonHeight` | read `UiTokenData.geometryHomePrimaryButtonHeight.value.dp` |
| 216 | 635 | `EMPTY_STATE_ACTION_LABEL_SIZE_PT` | `16` | `HomeSpec.swift:215`. | stale→`HomeSpec.swift:234` `.font(.system(size: HomeSpec.bodySize, weight: .semibold))` (16) | 3 | `token:typography.buttonLabel` | read `UiTokenData.typeButtonLabel.baseSize` |
| 217 | 640 | `QUESTION_CARD_RADIUS_PT` | `20` | `NativeParityTokens.swift:112` (`radiusXL`). | stale: `NativeParityTokens.swift:112` now `static let radiusSM: CGFloat = 8` | 3 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 218 | 642 | `QUESTION_CARD_BOTTOM_PT` | `10` | `NativeQuestionComposer.swift:269`. | `NativeQuestionComposer.swift:269` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 219 | 644 | `QUESTION_SEAT_BOTTOM_PT` | `8` | `ChatPage.swift:1718,1732`. | stale: `ChatPage.swift:1718` now `switch workspaceModels.pcLink.presence.reachability {            ` | 0 | `dead` | delete |
| 220 | 646 | `QUESTION_HEADER_TOP_PT` | `20` | `NativeQuestionComposer.swift:308`. | `NativeQuestionComposer.swift:308` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 221 | 648 | `QUESTION_HEADER_LEADING_PT` | `24` | `NativeQuestionComposer.swift:308`. | `NativeQuestionComposer.swift:308` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 222 | 650 | `QUESTION_HEADER_TRAILING_PT` | `16` | `NativeQuestionComposer.swift:308`. | `NativeQuestionComposer.swift:308` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 223 | 652 | `QUESTION_HEADER_MINIMIZED_BOTTOM_PT` | `14` | `NativeQuestionComposer.swift:308`. | `NativeQuestionComposer.swift:308` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 224 | 654 | `QUESTION_HEADER_COPY_ACTION_GAP_PT` | `16` | `NativeQuestionComposer.swift:290`. | `NativeQuestionComposer.swift:290` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 225 | 656 | `QUESTION_HEADER_STACK_GAP_PT` | `5` | `NativeQuestionComposer.swift:290`. | stale: `NativeQuestionComposer.swift:290` now `HStack(alignment: .top, spacing: 16) {` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 226 | 658 | `QUESTION_EYEBROW_SIZE_PT` | `11` | `NativeQuestionComposer.swift:293`. | `NativeQuestionComposer.swift:293` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 227 | 660 | `QUESTION_PROMPT_SIZE_PT` | `16` | `NativeQuestionComposer.swift:299`. | `NativeQuestionComposer.swift:299` holds | 1 | `token:typography.body` | read `UiTokenData.typeBody.baseSize` |
| 228 | 662 | `QUESTION_HEADER_ACTION_SIZE_PT` | `32` | `NativeQuestionComposer.swift:323-328`. | stale: `NativeQuestionComposer.swift:323` now `NativeQuestionIconButton(systemName: minimized ? "chevron.up" : "` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 229 | 664 | `QUESTION_HEADER_ACTION_GAP_PT` | `4` | `NativeQuestionComposer.swift:312`. | `NativeQuestionComposer.swift:312` holds | 0 | `dead` | delete |
| 230 | 666 | `QUESTION_HEADER_EXPANDED_BOTTOM_PT` | `0` | `NativeQuestionComposer.swift:308`. | `NativeQuestionComposer.swift:308` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 231 | 668 | `QUESTION_OPTIONS_TOP_PT` | `12` | `NativeQuestionComposer.swift:397`. | `NativeQuestionComposer.swift:397` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 232 | 670 | `QUESTION_OPTIONS_INSET_H_PT` | `8` | `NativeQuestionComposer.swift:397`. | `NativeQuestionComposer.swift:397` holds | 0 | `dead` | delete |
| 233 | 672 | `QUESTION_OPTIONS_BOTTOM_PT` | `4` | `NativeQuestionComposer.swift:397`. | `NativeQuestionComposer.swift:397` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 234 | 674 | `QUESTION_OPTION_GAP_PT` | `1` | `NativeQuestionComposer.swift:389`. | `NativeQuestionComposer.swift:389` holds | 0 | `dead` | delete |
| 235 | 676 | `QUESTION_OPTION_PADDING_V_PT` | `8` | `NativeQuestionComposer.swift:433`. | `NativeQuestionComposer.swift:433` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 236 | 678 | `QUESTION_OPTION_PADDING_H_PT` | `6` | `NativeQuestionComposer.swift:433`. | `NativeQuestionComposer.swift:433` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 237 | 680 | `QUESTION_OPTION_RADIUS_PT` | `12` | `NativeParityTokens.swift:113` (`radiusMD`). | `NativeParityTokens.swift:113` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 238 | 682 | `QUESTION_OPTION_MARK_SIZE_PT` | `24` | `NativeQuestionOptionRow.swift:17`. | stale: file `NativeQuestionOptionRow.swift` no longer exists; 24 is at `NativeQuestionComposer.swift:706` `.frame(width: 24, height: 24)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 239 | 684 | `QUESTION_FREE_ANSWER_HEIGHT_PT` | `64` | `NativeQuestionComposer.swift:361`. | stale: `NativeQuestionComposer.swift:361` now `if question.hasOptions {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 240 | 686 | `QUESTION_FOOTER_TOP_PT` | `12` | `NativeQuestionComposer.swift:512`. | `NativeQuestionComposer.swift:512` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 241 | 688 | `QUESTION_FOOTER_INSET_H_PT` | `10` | `NativeQuestionComposer.swift:512`. | `NativeQuestionComposer.swift:512` holds | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 242 | 690 | `QUESTION_FOOTER_GAP_PT` | `12` | `NativeQuestionComposer.swift:489,512`. | `NativeQuestionComposer.swift:489` holds | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 243 | 692 | `QUESTION_PAGER_TARGET_PT` | `28` | `NativeQuestionComposer.swift:517-525`. | stale: `NativeQuestionComposer.swift:517` now `NativeQuestionIconButton(systemName: "chevron.left", label: Nativ` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 244 | 694 | `QUESTION_ACTION_HEIGHT_PT` | `36` | `NativeQuestionComposer.swift:674`. | stale: `NativeQuestionComposer.swift:674` now `.padding(.top, 2)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 245 | 696 | `QUESTION_ACTION_RADIUS_PT` | `12` | `NativeParityTokens.swift:114` (`radiusMD`). | stale: `NativeParityTokens.swift:114` now `static let radiusLG: CGFloat = 16` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 246 | 698 | `QUESTION_ACTION_PADDING_H_PT` | `14` | `NativeQuestionComposer.swift:687`. | stale: `NativeQuestionComposer.swift:687` now `RoundedRectangle(cornerRadius: NativeParityTokens.radiusXS, style` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 247 | 700 | `QUESTION_OPTION_TEXT_SIZE_PT` | `14` | `NativeQuestionComposer.swift:418`. | `NativeQuestionComposer.swift:418` holds | 4 | `token:typography.listItem` | read `UiTokenData.typeListItem.baseSize` |
| 248 | 702 | `QUESTION_DETAIL_INSET_H_PT` | `2` | `NativeQuestionComposer.swift:355`. | stale: `NativeQuestionComposer.swift:355` now `.lineSpacing(NativeParityTokens.bodyLineSpacing)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 249 | 704 | `QUESTION_DETAIL_INSET_V_PT` | `8` | `NativeQuestionComposer.swift:356`. | stale: `NativeQuestionComposer.swift:356` now `.foregroundStyle(NativeParityTokens.labelPrimary)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 250 | 706 | `QUESTION_ANSWER_INSET_V_PT` | `8` | `NativeQuestionComposer.swift:462`. | stale: `NativeQuestionComposer.swift:462` now `.frame(maxWidth: .infinity, alignment: .leading)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 251 | 708 | `QUESTION_ANSWER_INSET_H_PT` | `6` | `NativeQuestionComposer.swift:464`. | `NativeQuestionComposer.swift:464` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 252 | 710 | `QUESTION_ACTION_TEXT_INSET_H_PT` | `10` | `NativeQuestionComposer.swift:682`. | stale: `NativeQuestionComposer.swift:682` now `var body: some View {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 253 | 712 | `QUESTION_ACTION_TEXT_INSET_V_PT` | `8` | `NativeQuestionComposer.swift:682`. | stale: `NativeQuestionComposer.swift:682` now `var body: some View {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 254 | 714 | `QUESTION_OPTION_ROW_HEIGHT_PT` | `40` | `NativeParityTokens.swift:105` (`questionOptionMinHeight`). | `NativeParityTokens.swift:105` holds | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 255 | 716 | `QUESTION_ERROR_SLOT_HEIGHT_PT` | `16` | `NativeQuestionComposer.swift:493`. | stale: `NativeQuestionComposer.swift:493` now `.multilineTextAlignment(.trailing)` | 0 | `dead` | delete |
| 256 | 718 | `QUESTION_CARD_SHADOW_PT` | `4` | `NativeQuestionComposer.swift:282-283`; Android elevation differs. | stale: `NativeQuestionComposer.swift:282` now `.shadow(color: .black.opacity(0.031), radius: 8, x: 0, y: 3)     ` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 257 | 720 | `QUESTION_BODY_INSET_H_PT` | `8` | `NativeQuestionComposer.swift:397`. | `NativeQuestionComposer.swift:397` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 258 | 722 | `QUESTION_PAGER_GAP_PT` | `6` | `NativeQuestionComposer.swift:516`. | `NativeQuestionComposer.swift:516` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 259 | 724 | `QUESTION_PANEL_BOTTOM_PT` | `10` | `NativeQuestionComposer.swift:269`. | `NativeQuestionComposer.swift:269` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 260 | 729 | `PLAN_REVIEW_CARD_RADIUS_PT` | `20` | `NativeParityTokens.swift:110` (`radiusXL`). | stale: `NativeParityTokens.swift:110` now `(blank line)` | 0 | `dead` | delete |
| 261 | 731 | `PLAN_REVIEW_BUTTON_HEIGHT_PT` | `36` | `NativePlanReviewCard.swift:200-210`. | `NativePlanReviewCard.swift:200` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 262 | 733 | `PLAN_REVIEW_BUTTON_RADIUS_PT` | `12` | `NativeParityTokens.swift:111` (`radiusMD`). | stale: `NativeParityTokens.swift:111` now `static let radiusXS: CGFloat = 4` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 263 | 735 | `PLAN_REVIEW_BUTTON_INSET_H_PT` | `14` | `NativePlanReviewCard.swift:210`. | stale: `NativePlanReviewCard.swift:210` now `.frame(height: 36)` | 0 | `dead` | delete |
| 264 | 737 | `PLAN_REVIEW_BUTTON_GAP_PT` | `8` | `NativePlanReviewCard.swift:174`. | `NativePlanReviewCard.swift:174` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 265 | 739 | `PLAN_REVIEW_SECTION_GAP_PT` | `8` | `NativePlanReviewCard.swift:141`. | `NativePlanReviewCard.swift:141` holds | 0 | `dead` | delete |
| 266 | 741 | `PLAN_REVIEW_SHADOW_PT` | `3` | `NativePlanReviewCard.swift:97-98`; Android elevation differs. | `NativePlanReviewCard.swift:97` holds | 0 | `dead` | delete |
| 267 | 746 | `GOAL_BAR_HEIGHT_PT` | `40` | `ChatPage.swift:1452`. | stale: `ChatPage.swift:1452` now `.transition(.opacity)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 268 | 748 | `GOAL_BAR_RADIUS_PT` | `10` | `ChatPage.swift:1454`. | stale: `ChatPage.swift:1454` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 269 | 750 | `GOAL_BAR_INSET_H_PT` | `10` | `ChatPage.swift:1451`. | stale: `ChatPage.swift:1451` now `.allowsHitTesting(false)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 270 | 752 | `GOAL_BAR_ICON_SIZE_PT` | `14` | `ChatPage.swift:1421`. | stale: `ChatPage.swift:1421` now `guard showing == false, !visibleItems.isEmpty else { return }` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 271 | 754 | `GOAL_BAR_GAP_PT` | `8` | `ChatPage.swift:1420`. | stale: `ChatPage.swift:1420` now `// different heights; the replacement must anchor again.` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 272 | 756 | `GOAL_BAR_PHASE_SIZE_PT` | `11` | `ChatPage.swift:1425`. | stale: `ChatPage.swift:1425` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 273 | 758 | `GOAL_BAR_OBJECTIVE_SIZE_PT` | `13` | `ChatPage.swift:1428`. | stale: `ChatPage.swift:1428` now `userScrolledAway = false` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 274 | 760 | `GOAL_BAR_ACTION_SIZE_PT` | `12` | `ChatPage.swift:1437,1440`. | stale: `ChatPage.swift:1437` now `guard followsTail else { return }             }` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 275 | 762 | `GOAL_BAR_ICON_STROKE_TENTH_PT` | `1.4f` | Android target icon stroke approximation for the iOS target symbol. Confidence: approximated. | no citation | 0 | `dead` | delete |
| 276 | 764 | `TODO_DOCK_INSET_H_PT` | `12` | `NativeTodoDock.swift:93`. | `NativeTodoDock.swift:93` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 277 | 766 | `TODO_DOCK_INSET_V_PT` | `6` | `NativeTodoDock.swift:94`. | `NativeTodoDock.swift:94` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 278 | 768 | `TODO_DOCK_GAP_PT` | `8` | `NativeTodoDock.swift:89,166`. | `NativeTodoDock.swift:89` holds | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 279 | 770 | `TODO_DOCK_HEADER_LINE_PT` | `24` | `NativeTodoDock.swift:138`. | `NativeTodoDock.swift:138` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 280 | 772 | `TODO_ROW_HEIGHT_PT` | `20` | `NativeTodoDock.swift:196`. | `NativeTodoDock.swift:196` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 281 | 774 | `TODO_STATUS_SLOT_PT` | `16` | `NativeTodoDock.swift:187`. | stale: `NativeTodoDock.swift:187` now `TodoStatusDot(status: todo.status)` | 0 | `dead` | delete |
| 282 | 776 | `TODO_CHECKLIST_ICON_PT` | `14` | `NativeTodoDock.swift:118`. | `NativeTodoDock.swift:118` holds | 0 | `dead` | delete |
| 283 | 778 | `TODO_STATUS_DOT_PT` | `6` | `NativeTodoDock.swift:187-188`. | stale: `NativeTodoDock.swift:187` now `TodoStatusDot(status: todo.status)                 .frame(width: ` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 284 | 780 | `TODO_DOCK_RADIUS_PT` | `16` | `NativeParityTokens.swift:101` (`radiusLG`). | stale: `NativeParityTokens.swift:101` now `static let toolRowHeight: CGFloat = 24` | 3 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 285 | 782 | `TODO_TEXT_SIZE_PT` | `13` | `NativeTodoDock.swift:121,125,190`. | `NativeTodoDock.swift:121` holds | 3 | `page-local` | keep local; one page/surface layout value; no token fit |
| 286 | 784 | `TODO_GLYPH_STROKE_PT` | `0.875f` | `NativeTodoDock.swift:206`. | stale: `NativeTodoDock.swift:206` now `private let lineWidth: CGFloat = 14.0 / 16.0` | 0 | `dead` | delete |
| 287 | 786 | `TODO_GLYPH_DOT_RADIUS_PT` | `1.75f` | `NativeTodoDock.swift:218-220`. | `NativeTodoDock.swift:218` holds | 0 | `dead` | delete |
| 288 | 788 | `TODO_GLYPH_ROW1_Y_PT` | `4.5f` | `NativeTodoDock.swift:217`. | `NativeTodoDock.swift:217` holds | 0 | `dead` | delete |
| 289 | 789 | `TODO_GLYPH_ROW2_Y_PT` | `11.5f` |  | no citation | 0 | `dead` | delete |
| 290 | 791 | `TODO_GLYPH_BULLET_X_PT` | `2.0f` | `NativeTodoDock.swift:218`. | stale: `NativeTodoDock.swift:218` now `path.addEllipse(in: CGRect(x: (3.75 - 1.75) * scale,` | 0 | `dead` | delete |
| 291 | 793 | `TODO_GLYPH_LINE_START_X_PT` | `6` | `NativeTodoDock.swift:219-220`. | stale: `NativeTodoDock.swift:219` now `y: (centerY - 1.75) * scale,                                     ` | 0 | `dead` | delete |
| 292 | 794 | `TODO_GLYPH_LINE_END_X_PT` | `13` |  | no citation | 0 | `dead` | delete |
| 293 | 796 | `TODO_DOCK_SHADOW_PT` | `3` | `NativeTodoDock.swift:99-100`; Android elevation differs. | `NativeTodoDock.swift:99` holds | 1 | `android-only` | keep local; Android elevation approximation of the iOS shadow; §5 has no elevation id — platform-forced. |
| 294 | 798 | `TODO_STATUS_GAP_PT` | `10` | `NativeTodoDock.swift:186-196`. | `NativeTodoDock.swift:186` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 295 | 800 | `TODO_STATUS_DOT_CONTAINER_PT` | `16` | `NativeTodoDock.swift:187-188`. | `NativeTodoDock.swift:187` holds | 0 | `dead` | delete |
| 296 | 807 | `DISCLOSURE_CATEGORY_ICON_PT` | `16` | `NativeMessageRows.swift:32`. | stale: `NativeMessageRows.swift:32` now `} label: {` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 297 | 810 | `DISCLOSURE_CHEVRON_ICON_PT` | `14` | `NativeMessageRows.swift:31`. | stale: `NativeMessageRows.swift:31` now `withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 298 | 590 | `COMPOSER_TEXT_MIN_HEIGHT_PT` | `36` | `ChatPage.swift:85` ("editable surface (36…336)") and `:3893` (`min(max(ceil(content), 36), parent.maxHeight)`). | `ChatPage.swift:3893` holds; the 56 at `:2373` is the containing port, not this surface | 1 | `page-local` | wave-3 round 1 narrowed the editable-surface floor from 56 to 36 and reads it; the source has no token for this measured floor. |
| 299 | 816 | `COMPOSER_PLACEHOLDER_LEADING_PT` | `5` | `ChatPage.swift:1972`. | stale: `ChatPage.swift:1972` now `let showsLeadingGlyph = rows.count == 1` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 300 | 819 | `COMPOSER_PLACEHOLDER_TOP_PT` | `8` | `ChatPage.swift:1973`. | stale: `ChatPage.swift:1973` now `VStack(alignment: .leading, spacing: 4) {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 301 | 822 | `COMPOSER_CONTROL_TRAILING_PT` | `8` | `ChatPage.swift:2006`. | stale: `ChatPage.swift:2006` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 302 | 825 | `COMPOSER_CONTROL_MIN_WIDTH_PT` | `40` | `ChatPage.swift:2126,2140,2179`. | stale: `ChatPage.swift:2126` now `composerNotice = ComposerNotice(level: .error, text: message)    ` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 303 | 828 | `COMPOSER_MODEL_MIN_GAP_PT` | `8` | `ChatPage.swift:2148` (`Spacer(minLength: 8)`). | stale→`ChatPage.swift:2263` `Spacer(minLength: 8)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 304 | 831 | `COMPOSER_ACTION_GAP_PT` | `8` | `ChatPage.swift:2151,2155`. | stale: `ChatPage.swift:2151` now `.truncationMode(.tail)                 .frame(height: 28)` | 0 | `dead` | delete |
| 305 | 834 | `SEND_GLYPH_PT` | `15` | `ChatPage.swift:2067`. | stale: `ChatPage.swift:2067` now `queueRowAction(symbol: "paperplane", label: "插话发送",` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 306 | 837 | `STOP_GLYPH_PT` | `12` | `ChatPage.swift:2099`. | stale: `ChatPage.swift:2099` now `guard item.isPlainText else { return "包含非文本内容，暂不支持编辑" }` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 307 | 840 | `STOP_GLYPH_RADIUS_PT` | `3` | `ChatPage.swift:2097`. | stale: `ChatPage.swift:2097` now `private func queueEditUnavailableReason(_ row: ComposerQueue.Row)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 308 | 843 | `CODE_BLOCK_SOURCE_FONT_SIZE_PT` | `13` | `NativeCodeHighlighter.swift:19`. Separate from the user code preference (14pt). | stale: `NativeCodeHighlighter.swift:19` now `"null", "open", "operator", "override", "package", "private", "pr` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 309 | 846 | `CODE_BLOCK_HEADER_GAP_PT` | `8` | `Components.swift:164`. | `Components.swift:164` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 310 | 849 | `CODE_BLOCK_HEADER_INSET_H_PT` | `12` | `Components.swift:195`. | `Components.swift:195` holds | 1 | `token:spacing.codeToolbar` | read `UiTokenData.spacingCodeToolbar.dp` |
| 311 | 852 | `CODE_BLOCK_LABEL_SIZE_PT` | `11` | `Components.swift:166`. | `Components.swift:166` holds | 0 | `dead` | delete |
| 312 | 855 | `CODE_BLOCK_ACTION_SIZE_PT` | `11` | `Components.swift:172,187`. | `Components.swift:172` holds | 0 | `dead` | delete; value is token `typography.codeAction`; no Kotlin reader |
| 313 | 858 | `CODE_BLOCK_WRAP_ICON_SIZE_PT` | `11` | `Components.swift:172-173`. | `Components.swift:172` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 314 | 861 | `CODE_BLOCK_EXPAND_LABEL_SIZE_PT` | `12` | `Components.swift:213`. | `Components.swift:213` holds | 0 | `dead` | delete; value is token `typography.codeExpand`; no Kotlin reader |
| 315 | 864 | `CODE_BLOCK_COPY_GAP_PT` | `5` | `Components.swift:185`. | `Components.swift:185` holds | 0 | `dead` | delete; value is token `spacing.copyGap`; no Kotlin reader |
| 316 | 867 | `CODE_BLOCK_COPY_ICON_SIZE_PT` | `13` | `Components.swift:186`. | `Components.swift:186` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 317 | 870 | `CODE_BLOCK_COPY_MIN_WIDTH_PT` | `44` | `Components.swift:189`. | `Components.swift:189` holds | 0 | `dead` | delete; value is token `spacing.codeCopyMinWidth`; no Kotlin reader |
| 318 | 873 | `CODE_BLOCK_CONTROL_SIZE_PT` | `28` | `Components.swift:173,189`. | `Components.swift:173` holds | 1 | `token:spacing.codeWrapButton` | read `UiTokenData.spacingCodeWrapButton.dp` |
| 319 | 876 | `CODE_BLOCK_LINE_SPACING_PT` | `5` | `Components.swift:201`. | `Components.swift:201` holds | 0 | `dead` | delete; value is token `spacing.codeLineSpacing`; no Kotlin reader |
| 320 | 879 | `CODE_BLOCK_OUTER_INSET_V_PT` | `2` | `Components.swift:224`. | `Components.swift:224` holds | 0 | `dead` | delete; value is token `spacing.codeBlockOuterInsetV`; no Kotlin reader |
| 321 | 882 | `MARKDOWN_BLOCK_SPACING_PT` | `20` | `NativeChatTheme.swift:49`. | stale: `NativeChatTheme.swift:49` now `static let messageListSpacing: CGFloat = 10` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 322 | 885 | `MARKDOWN_BODY_LINE_HEIGHT_PT` | `24` | `NativeParityTokens.swift:55`. | `NativeParityTokens.swift:55` holds | 0 | `dead` | delete; value is token `typography.body`; no Kotlin reader |
| 323 | 888 | `MARKDOWN_LIST_INDENT_PT` | `8` | `NativeMarkdownBody.swift:88`. | stale: `NativeMarkdownBody.swift:88` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 324 | 891 | `MARKDOWN_LIST_COMPACT_INDENT_PT` | `4` | `NativeMarkdownBody.swift:88`. | stale: `NativeMarkdownBody.swift:88` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 325 | 894 | `MARKDOWN_ORDERED_MARKER_MIN_WIDTH_PT` | `24` | `NativeMarkdownBody.swift:77`. | stale: `NativeMarkdownBody.swift:77` now `.font(variant == .compact ? NativeChatTheme.secondaryFont() : Nat` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 326 | 897 | `MARKDOWN_BULLET_MARKER_MIN_WIDTH_PT` | `18` | `NativeMarkdownBody.swift:77`. | stale: `NativeMarkdownBody.swift:77` now `.font(variant == .compact ? NativeChatTheme.secondaryFont() : Nat` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 327 | 900 | `MARKDOWN_MARKER_TOP_INSET_PT` | `1` | `NativeMarkdownBody.swift:78`. | stale: `NativeMarkdownBody.swift:78` now `.foregroundStyle(NativeChatTheme.secondary)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 328 | 903 | `MARKDOWN_QUOTE_CHILD_GAP_PT` | `12` | `NativeMarkdownBody.swift:90`. | stale: `NativeMarkdownBody.swift:90` now `.padding(.leading, variant == .compact ? 4 : 8)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 329 | 906 | `MARKDOWN_QUOTE_COMPACT_CHILD_GAP_PT` | `4` | `NativeMarkdownBody.swift:90`. | `NativeMarkdownBody.swift:90` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 330 | 909 | `MARKDOWN_QUOTE_INSET_PT` | `14` | `NativeMarkdownBody.swift:96`. | stale: `NativeMarkdownBody.swift:96` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 331 | 912 | `MARKDOWN_QUOTE_COMPACT_INSET_PT` | `8` | `NativeMarkdownBody.swift:96`. | stale: `NativeMarkdownBody.swift:96` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 332 | 915 | `MARKDOWN_QUOTE_BAR_WIDTH_PT` | `2` | `NativeMarkdownBody.swift:98`. | stale: `NativeMarkdownBody.swift:98` now `.padding(.leading, variant == .compact ? 8 : 14)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 333 | 918 | `MARKDOWN_TABLE_CELL_INSET_H_PT` | `16` | `NativeMarkdownBody.swift:219`. | stale: `NativeMarkdownBody.swift:219` now `.multilineTextAlignment(textAlignment(index))` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 334 | 921 | `MARKDOWN_TABLE_CELL_INSET_V_PT` | `10` | `NativeMarkdownBody.swift:220`. | stale: `NativeMarkdownBody.swift:220` now `.frame(minWidth: 100, maxWidth: 320, alignment: frameAlignment(in` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 335 | 924 | `MARKDOWN_TABLE_COMPACT_CELL_INSET_H_PT` | `8` | `NativeMarkdownBody.swift:219`. | stale: `NativeMarkdownBody.swift:219` now `.multilineTextAlignment(textAlignment(index))` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 336 | 927 | `MARKDOWN_TABLE_COMPACT_CELL_INSET_V_PT` | `4` | `NativeMarkdownBody.swift:220`. | stale: `NativeMarkdownBody.swift:220` now `.frame(minWidth: 100, maxWidth: 320, alignment: frameAlignment(in` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 337 | 930 | `MARKDOWN_TABLE_COLUMN_MIN_WIDTH_PT` | `100` | `NativeMarkdownBody.swift:218`. | stale: `NativeMarkdownBody.swift:218` now `: NativeChatTheme.messageBodyFont().weight(header ? .semibold : .` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 338 | 933 | `MARKDOWN_TABLE_COLUMN_MAX_WIDTH_PT` | `320` | `NativeMarkdownBody.swift:218`. | stale: `NativeMarkdownBody.swift:218` now `: NativeChatTheme.messageBodyFont().weight(header ? .semibold : .` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 339 | 936 | `MARKDOWN_TABLE_CARD_GAP_PT` | `8` | `NativeMarkdownBody.swift:165`. | stale: `NativeMarkdownBody.swift:165` now `(blank line)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 340 | 939 | `MARKDOWN_TABLE_FIELD_GAP_PT` | `10` | `NativeMarkdownBody.swift:167`. | stale: `NativeMarkdownBody.swift:167` now `VStack(alignment: .leading, spacing: 8) {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 341 | 942 | `MARKDOWN_TABLE_LABEL_VALUE_GAP_PT` | `2` | `NativeMarkdownBody.swift:169`. | stale: `NativeMarkdownBody.swift:169` now `VStack(alignment: .leading, spacing: 10) {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 342 | 945 | `MARKDOWN_TABLE_CARD_INSET_PT` | `12` | `NativeMarkdownBody.swift:184`. | stale: `NativeMarkdownBody.swift:184` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 343 | 948 | `MARKDOWN_TABLE_CARD_RADIUS_PT` | `12` | `NativeMarkdownBody.swift:187`. | stale: `NativeMarkdownBody.swift:187` now `.frame(maxWidth: .infinity, alignment: .leading)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 344 | 951 | `MARKDOWN_H1_SIZE_PT` | `24` | `NativeMarkdownBody.swift:123`. | stale: `NativeMarkdownBody.swift:123` now `if variant == .compact { return NativeChatTheme.secondaryFont().w` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 345 | 954 | `MARKDOWN_H2_SIZE_PT` | `22` | `NativeMarkdownBody.swift:124`. | stale: `NativeMarkdownBody.swift:124` now `switch level {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 346 | 957 | `MARKDOWN_H3_SIZE_PT` | `20` | `NativeMarkdownBody.swift:125`. | stale: `NativeMarkdownBody.swift:125` now `case 1: return .system(size: 24, weight: .bold)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 347 | 960 | `MARKDOWN_H4_SIZE_PT` | `17` | `NativeMarkdownBody.swift:126`. | stale: `NativeMarkdownBody.swift:126` now `case 2: return .system(size: 22, weight: .bold)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 348 | 963 | `MARKDOWN_FOOTNOTE_SIZE_PT` | `9` | `NativeMarkdownBody.swift:292`. | stale: `NativeMarkdownBody.swift:292` now `displayScale: displayScale,` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 349 | 966 | `MARKDOWN_FOOTNOTE_BASELINE_OFFSET_PT` | `6` | `NativeMarkdownBody.swift:292`. | stale: `NativeMarkdownBody.swift:292` now `displayScale: displayScale,` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 350 | 969 | `MARKDOWN_RULE_INSET_V_PT` | `16` | `NativeMarkdownBody.swift:116`. | stale: `NativeMarkdownBody.swift:116` now `.fill(NativeChatTheme.border)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 351 | 972 | `MARKDOWN_RULE_COMPACT_INSET_V_PT` | `4` | `NativeMarkdownBody.swift:116`. | stale: `NativeMarkdownBody.swift:116` now `.fill(NativeChatTheme.border)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 352 | 975 | `MARKDOWN_RULE_HEIGHT_PT` | `0.5f` | `NativeMarkdownBody.swift:115`. | stale: `NativeMarkdownBody.swift:115` now `Rectangle()` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 353 | 978 | `CHANGED_FILES_HEADER_GAP_PT` | `10` | `NativeChangedFilesCard.swift:18`. | stale: `NativeChangedFilesCard.swift:18` now `Button { onOpenFile(changes.files[0].path) } label: {` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 354 | 981 | `CHANGED_FILES_HEADER_GLYPH_BOX_PT` | `40` | `NativeChangedFilesCard.swift:29`. | stale: `NativeChangedFilesCard.swift:29` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 355 | 984 | `CHANGED_FILES_HEADER_GLYPH_SIZE_PT` | `20` | `NativeChangedFilesCard.swift:25-26`. | `NativeChangedFilesCard.swift:25` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 356 | 987 | `CHANGED_FILES_HEADER_GLYPH_RADIUS_PT` | `10` | `NativeChangedFilesCard.swift:20,22`. | stale: `NativeChangedFilesCard.swift:20` now `ZStack {                             .fill(NativeChatTheme.input)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 357 | 990 | `CHANGED_FILES_TITLE_STACK_GAP_PT` | `2` | `NativeChangedFilesCard.swift:30`. | stale: `NativeChangedFilesCard.swift:30` now `.frame(width: 40, height: 40)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 358 | 993 | `CHANGED_FILES_TITLE_SIZE_PT` | `13` | `NativeChangedFilesCard.swift:33`. | stale: `NativeChangedFilesCard.swift:33` now `?? "已编辑 \(changes.files.count) 个文件")` | 0 | `dead` | delete |
| 359 | 996 | `CHANGED_FILES_TITLE_WEIGHT` | `500` | `NativeChangedFilesCard.swift:33`. | stale: `NativeChangedFilesCard.swift:33` now `?? "已编辑 \(changes.files.count) 个文件")` | 0 | `dead` | delete |
| 360 | 999 | `CHANGED_FILES_HEADER_COUNT_SIZE_PT` | `10` | `NativeChangedFilesCard.swift:40`. | stale: `NativeChangedFilesCard.swift:40` now `}` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 361 | 1002 | `CHANGED_FILES_DIFF_COUNT_GAP_PT` | `6` | `NativeChangedFilesCard.swift:36`. | stale: `NativeChangedFilesCard.swift:36` now `.lineLimit(1)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 362 | 1005 | `CHANGED_FILES_HEADER_INSET_PT` | `10` | `NativeChangedFilesCard.swift:44`. | stale: `NativeChangedFilesCard.swift:44` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 363 | 1008 | `CHANGED_FILES_HEADER_HEIGHT_PT` | `60` | `NativeChangedFilesCard.swift:45`. | stale: `NativeChangedFilesCard.swift:45` now `.padding(10)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 364 | 1011 | `CHANGED_FILES_ROW_GAP_PT` | `10` | `NativeChangedFilesCard.swift:55,62`. | stale: `NativeChangedFilesCard.swift:55` now `Button { onOpenFile(file.path) } label: {                        ` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 365 | 1014 | `CHANGED_FILES_ROW_PATH_SIZE_PT` | `12` | `NativeChangedFilesCard.swift:57`. | stale: `NativeChangedFilesCard.swift:57` now `Text(file.display)` | 0 | `dead` | delete |
| 366 | 1017 | `CHANGED_FILES_ROW_COUNT_SIZE_PT` | `11` | `NativeChangedFilesCard.swift:66`. | stale: `NativeChangedFilesCard.swift:66` now `}` | 0 | `dead` | delete |
| 367 | 1020 | `CHANGED_FILES_ROW_INSET_H_PT` | `14` | `NativeChangedFilesCard.swift:68`. | stale: `NativeChangedFilesCard.swift:68` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 368 | 1023 | `CHANGED_FILES_ROW_INSET_V_PT` | `7` | `NativeChangedFilesCard.swift:69`. | stale: `NativeChangedFilesCard.swift:69` now `.padding(.horizontal, 14)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 369 | 1026 | `CHANGED_FILES_ROW_MIN_HEIGHT_PT` | `44` | `NativeChangedFilesCard.swift:70,86`. | stale: `NativeChangedFilesCard.swift:70` now `.padding(.vertical, 7)                         .padding(.vertical` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 370 | 1029 | `CHANGED_FILES_TOGGLE_GAP_PT` | `4` | `NativeChangedFilesCard.swift:77`. | stale: `NativeChangedFilesCard.swift:77` now `Button { withAnimation(.easeOut(duration: 0.16)) { expanded.toggl` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 371 | 1032 | `CHANGED_FILES_TOGGLE_SIZE_PT` | `12` | `NativeChangedFilesCard.swift:82`. | stale: `NativeChangedFilesCard.swift:82` now `}` | 0 | `dead` | delete |
| 372 | 1035 | `CHANGED_FILES_TOGGLE_CHEVRON_SIZE_PT` | `14` | `NativeChangedFilesCard.swift:79`. | stale: `NativeChangedFilesCard.swift:79` now `Text(expanded ? "收起" : "全部 \(changes.files.count) 个文件")` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 373 | 1038 | `CHANGED_FILES_TOGGLE_INSET_H_PT` | `14` | `NativeChangedFilesCard.swift:84`. | stale: `NativeChangedFilesCard.swift:84` now `.foregroundStyle(NativeChatTheme.tertiary)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 374 | 1041 | `CHANGED_FILES_TOGGLE_INSET_V_PT` | `10` | `NativeChangedFilesCard.swift:85`. | stale: `NativeChangedFilesCard.swift:85` now `.padding(.horizontal, 14)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |

### 3.2 `SessionsMetrics.kt` (51 rows)

| # | line | constant | value | claimed iOS source | citation check | refs | class | action / note |
|---:|---:|---|---|---|---|---:|---|---|
| 375 | 31 | `DRAWER_WIDTH_PT` | `UiTokenData.drawer.width.value.toInt()` | HomeDrawer panel width; resolves `geometry.drawerWidth` (no local copy). | no citation | 5 | `token:geometry.drawerWidth` | already reads the generated token |
| 376 | 34 | `DRAWER_CONTENT_WIDTH_PT` | `280` | Folder reading width inside the actual 320pt panel: 20pt content insets. | no citation | 4 | `page-local` | keep local; one page/surface layout value; no token fit |
| 377 | 37 | `DRAWER_PANEL_RADIUS_PT` | `UiTokenData.drawer.panelTrailingRadius.value.toInt()` | Panel trailing radius; resolves `radius.drawerTrailing`. | no citation | 1 | `token:radius.drawerTrailing` | already reads the generated token |
| 378 | 40 | `DRAWER_SCRIM_ALPHA` | `UiTokenData.drawer.scrimMaxOpacity` | Scrim opacity; resolves `interaction.drawer.scrimMaxOpacity`. | no citation | 1 | `token:interaction.drawer.scrimMaxOpacity` | already reads the generated token |
| 379 | 43 | `DRAWER_PRESS_ALPHA` | `0.7f` | HomeDrawerRowStyle: HomeSpec.userBubble at 70% only while pressed. | `HomeDrawer.swift:706` `.fill(HomeSpec.userBubble.opacity(configuration.isPressed ? 0.7 : 0))` holds | 0 | `dead` | delete |
| 380 | 46 | `ROW_INSET_PT` | `8` | `HomeDrawer.swift:140,278` (`.padding(.horizontal, 8)`). | stale→`HomeDrawer.swift:459` `.padding(.horizontal, 8)` | 5 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 381 | 49 | `DRAWER_ROW_HEIGHT_PT` | `44` | Legacy furniture row height; the 新会话 entry is now a 52 pt capsule. | no citation | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 382 | 52 | `DRAWER_ROW_ICON_SLOT_PT` | `24` | `HomeDrawer.swift:150` (`.frame(width: 24, height: 24)`). | stale: `HomeDrawer.swift:150` now `get: { renameFolder != nil }, set: { if !$0 { renameFolder = nil ` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 383 | 55 | `DRAWER_ROW_SPACING_PT` | `12` | `HomeDrawer.swift:148` (`HStack(spacing: 12)`). | stale: `HomeDrawer.swift:148` now `}` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 384 | 58 | `DRAWER_ROW_CHEVRON_REF_PT` | `11` | `HomeDrawer.swift:307` (`.font(.system(size: 11, weight: .semibold))`). | stale→`HomeDrawer.swift:499` `.font(.system(size: 11, weight: .semibold))` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 385 | 63 | `SESSION_ROW_HEIGHT_PT` | `44` | `HomeDrawer.swift:342` (`.frame(height: 44)`). | stale→`HomeDrawer.swift:557` `.frame(height: 44)` | 3 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 386 | 66 | `STANDALONE_SESSION_ROW_HEIGHT_PT` | `56` | `SessionsPage.swift:589`. | stale: `SessionsPage.swift:589` now `.frame(width: 6, height: 6)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 387 | 69 | `WORKSPACE_ROW_HEIGHT_PT` | `40` | `HomeDrawer.swift:325` (`.frame(height: 40)`). | stale→`HomeDrawer.swift:519` `.frame(height: 40)` | 3 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 388 | 72 | `ACTION_ROW_HEIGHT_PT` | `44` | Action row height used by the standalone SessionsPage rows. | no citation | 0 | `dead` | delete |
| 389 | 75 | `SESSION_ROW_INNER_INSET_PT` | `8` | `SessionsPage.swift:588` (`.padding(.horizontal, 8)`). | stale→`SessionsPage.swift:606` `.padding(.horizontal, 8)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 390 | 78 | `SESSION_GLYPH_BOX_PT` | `17` | `SessionsPage.swift:559` (`.frame(width: 17, height: 17)`). | stale→`SessionsPage.swift:577` `.frame(width: 17, height: 17)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 391 | 81 | `SESSION_GLYPH_SIZE_PT` | `15` | `SessionsPage.swift:557`. | stale: `SessionsPage.swift:557` now `}` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 392 | 84 | `SESSION_GLYPH_GAP_PT` | `10` | `SessionsPage.swift:555`. | stale: `SessionsPage.swift:555` now `let index = (ordered.firstIndex(where: { $0.id == workspace.id })` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 393 | 87 | `SESSION_TEXT_GAP_PT` | `3` | `SessionsPage.swift:560`. | stale: `SessionsPage.swift:560` now `let pinRank = Dictionary(uniqueKeysWithValues: management.pinnedS` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 394 | 90 | `SESSION_METADATA_SIZE_PT` | `13` | `SessionsPage.swift:577`. | stale: `SessionsPage.swift:577` now `.frame(width: 17, height: 17)` | 3 | `token:typography.secondary` | read `UiTokenData.typeSecondary.baseSize` |
| 395 | 93 | `SESSION_METADATA_GAP_PT` | `5` | `SessionsPage.swift:562`. | stale: `SessionsPage.swift:562` now `let leftRank = pinRank[lhs.element.id] ?? Int.max` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 396 | 96 | `SESSION_STATUS_DOT_GAP_PT` | `4` | `SessionsPage.swift:568`. | stale: `SessionsPage.swift:568` now `@ViewBuilder` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 397 | 99 | `SESSION_SELECTED_CHECK_SIZE_PT` | `20` | `SessionsPage.swift:584`. | stale: `SessionsPage.swift:584` now `// 运行中的点挪到「运行中」前面,6 实心 #66666B,离字 4:` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 398 | 102 | `SESSION_SELECTED_CHECK_GAP_PT` | `4` | `SessionsPage.swift:581`. | stale: `SessionsPage.swift:581` now `Text(SessionTime.relative(session.updatedAt))` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 399 | 105 | `SESSION_ROW_PRESS_RADIUS_PT` | `12` | `SessionsPage.swift:553`. | stale: `SessionsPage.swift:553` now `private func displayWorkspaceTitle(_ workspace: ManagedWorkspace)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 400 | 108 | `SESSION_RUNNING_DOT_PT` | `6` | `SessionsPage.swift:571`. | stale: `SessionsPage.swift:571` now `// 按下时整行铺 #F2F3F5、圆角 12、0.15 秒渐入,松手菜单才出来。` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 401 | 111 | `WORKSPACE_CHEVRON_SLOT_PT` | `12` | `HomeDrawer.swift:308` (`.frame(width: 12)`). | stale→`HomeDrawer.swift:502` `.frame(width: 12)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 402 | 114 | `WORKSPACE_TITLE_GAP_PT` | `8` | `HomeDrawer.swift:305` (`HStack(spacing: 8)`). | stale→`HomeDrawer.swift:395` `HStack(spacing: 8)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 403 | 117 | `WORKSPACE_COUNT_GAP_PT` | `8` | `HomeDrawer.swift:305` (same 8 pt stack). | stale: `HomeDrawer.swift:305` now `(blank line)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 404 | 120 | `WORKSPACE_MENU_WIDTH_PT` | `36` | `HomeDrawer.swift:213` (`.frame(width: 36, height: 36)`). | stale→`HomeDrawer.swift:323` `.frame(width: 36, height: 36)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 405 | 125 | `SEPARATOR_WIDTH_PT` | `288` | `SessionsPage.swift:157` and `:596` (`.frame(width: 288, height: 0.5)`). | stale→`SessionsPage.swift:183` `.frame(width: 288, height: 0.5)` | 3 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 406 | 128 | `SEPARATOR_HEIGHT_PT` | `0.5f` | `SessionsPage.swift:157`, `:596`. | stale→`SessionsPage.swift:183` `.frame(width: 288, height: 0.5)` | 3 | `token:stroke.hairline` | read `UiTokenData.strokeHairline.dp` |
| 407 | 131 | `SEPARATOR_INSET_PT` | `16` | `SessionsPage.swift:590,593-597`. PNG check: `darkfinal-sessions-many-light.png` row 1346 has the hairline at x=48..911 | stale: `SessionsPage.swift:590` now `Text("运行中")                         }                     }      ` | 4 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 408 | 149 | `SEARCH_HEIGHT_PT` | `44` | `darkfinal-sessions-light.png`: the white capsule spans y=350..482 px at   x=600 (a vertical scan; the field is white-on | measured PNG: 132 px / 3 = 44 pt; no Swift literal | 6 | `page-local` | keep local; system search control measured from PNG; used by Sessions and Files, but no Swift literal to cite as token provenance |
| 409 | 152 | `SEARCH_RADIUS_PT` | `22` | the same fit as [SEARCH_HEIGHT_PT] (top-corner arc). | measured PNG (no Swift line) | 5 | `page-local` | keep local; system search control measured from PNG; used by Sessions and Files, but no Swift literal to cite as token provenance |
| 410 | 155 | `SEARCH_INSET_PT` | `16` | `darkfinal-sessions-light.png`. | measured PNG (no Swift line) | 1 | `page-local` | keep local; system search control measured from PNG; used by Sessions and Files, but no Swift literal to cite as token provenance |
| 411 | 158 | `SEARCH_WIDTH_PT` | `370` | arithmetic on the two measured edges. | measured PNG (no Swift line) | 0 | `dead` | delete |
| 412 | 161 | `SEARCH_TEXT_REF_PT` | `17` | `darkpass-files-light.png`. | measured PNG (no Swift line) | 0 | `dead` | delete |
| 413 | 166 | `CTA_HEIGHT_PT` | `50` | `SessionsPage.swift:223` (`.frame(height: 50)`). PNG check: `darkfinal-sessions-light.png` blue box y=1046..1195 px → 15 | stale→`SessionsPage.swift:249` `.frame(height: 50)` | 3 | `token:geometry.homePrimaryButtonHeight` | read `UiTokenData.geometryHomePrimaryButtonHeight.value.dp` |
| 414 | 169 | `CTA_RADIUS_PT` | `12` | `SessionsPage.swift:225` (`RoundedRectangle(cornerRadius: 12)`). PNG check: corner fit r≈36 px = 12 pt. | stale→`SessionsPage.swift:251` `RoundedRectangle(cornerRadius: 12)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 415 | 172 | `CTA_WIDTH_PT` | `370` | PNG check x=48..1157 px → 370.0 pt. | measured PNG (no Swift line) | 0 | `dead` | delete |
| 416 | 175 | `EMPTY_STATE_CTA_TOP_PT` | `24` | `SessionsPage.swift:228` (`.padding(.top, 24)`). | stale→`SessionsPage.swift:254` `.padding(.top, 24)` | 0 | `dead` | delete |
| 417 | 178 | `EMPTY_STATE_BOTTOM_PT` | `8` | `SessionsPage.swift:232` (`.padding(.bottom, 8)`). | stale→`SessionsPage.swift:258` `.padding(.bottom, 8)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 418 | 183 | `TOAST_HEIGHT_PT` | `30` | `HomeDrawer.swift:61` (`.frame(height: 30)`). | stale→`HomeDrawer.swift:89` `.frame(height: 30)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 419 | 186 | `TOAST_RADIUS_PT` | `TOAST_HEIGHT_PT / 2` | `HomeDrawer.swift:62` (`Capsule()`). | `HomeDrawer.swift:90` `.background(..., in: Capsule())` holds (height/2) | 0 | `dead` | delete |
| 420 | 189 | `TOAST_TOP_OFFSET_PT` | `8` | `HomeDrawer.swift:65` (`.padding(.top, topInset + 8)`); the safe area is platform-owned. | stale→`HomeDrawer.swift:92` `.padding(.top, topInset + 8)` | 0 | `dead` | delete |
| 421 | 194 | `DRAWER_CARD_RADIUS_PT` | `12` | `HomeDrawer.swift:499` (`HomeDrawerRowStyle(radius: 12)`). | stale→`HomeDrawer.swift:522` `HomeDrawerRowStyle(radius: 12)` | 1 | `token:radius.card` | read `UiTokenData.radiusCard.dp` |
| 422 | 197 | `DRAWER_ROW_GLYPH_REF_PT` | `18` | `HomeDrawer.swift:150,312` (18 pt system glyph in a 24/20 box). | stale: `HomeDrawer.swift:150` now `get: { renameFolder != nil }, set: { if !$0 { renameFolder = nil ` | 0 | `dead` | delete |
| 423 | 200 | `DRAWER_FOLDER_ICON_SLOT_PT` | `20` | `HomeDrawer.swift:313` (`.frame(width: 20)`). | stale→`HomeDrawer.swift:506` `.frame(width: 20)` | 0 | `dead` | delete |
| 424 | 203 | `DRAWER_SETTINGS_CONTROL_PT` | `36` | `HomeDrawer.swift:382-384` (`.frame(width: 36, height: 36)`). | stale: cited `HomeDrawer.swift:382-384`; the only 36×36 in current HomeDrawer is the folder “+” at :323, not a settings-bar control | 0 | `dead` | delete |
| 425 | 206 | `DRAWER_ENGINE_DOT_PT` | `7` | `HomeDrawer.swift:391` (`.frame(width: 7, height: 7)`). | stale: `HomeDrawer.swift:391` now `.map { ($0.element, $0.offset) })` | 0 | `dead` | delete |

### 3.3 `SettingsMetrics.kt` (50 rows)

| # | line | constant | value | claimed iOS source | citation check | refs | class | action / note |
|---:|---:|---|---|---|---|---:|---|---|
| 426 | 37 | `WORKSPACE_TOOLBAR_TEXT_INSET_H_PT` | `16` | 430pt PR22 workspace.png: 64pt text pill minus 32pt text => 16pt each side. | no citation | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 427 | 39 | `WORKSPACE_TOOLBAR_SHADOW_ELEVATION_PT` | `0` | UIKit toolbar halo is unmeasured on Android; preserve zero elevation until a native comparison. | measured PNG (no Swift line) | 2 | `android-only` | keep local; Android elevation has no UIKit toolbar halo; §5 has no elevation id — platform-forced zero. |
| 428 | 42 | `ARCHIVE_TEXT_GAP_PT` | `2` | SettingsPage.swift ArchivedSessionsPage: title/time VStack spacing 2. | no citation | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 429 | 47 | `NAV_BAR_HEIGHT_PT` | `44` | system `.navigationBarTitleDisplayMode(.inline)` at `SettingsPage.swift:169` + `tokens.json` `geometry.pageHeaderMinHeig | stale: `SettingsPage.swift:169` now `#if DEBUG` | 2 | `token:geometry.navButton` | read `UiTokenData.geometryNavButton.value.dp` |
| 430 | 50 | `NAV_TITLE_REF_PT` | `17` | `HomeAppearance.apply()` (`systemFont(ofSize: 17, weight: .semibold)`). | no citation | 0 | `dead` | delete; value is token `typography.pageTitle`; no Kotlin reader |
| 431 | 53 | `NAV_TITLE_WEIGHT_REF` | `600` | `HomeAppearance.apply()` (`.semibold`). | no citation | 0 | `dead` | delete; value is token `typography.pageTitle`; no Kotlin reader |
| 432 | 58 | `SEGMENTED_HEIGHT_PT` | `32` | PNG check `settings-chat.png` track y=378..473 px → 96 px = 32.0 pt. | measured PNG (no Swift line) | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 433 | 61 | `SEGMENTED_INSET_H_PT` | `16` | `SettingsPage.swift:69` (`.padding(.horizontal, 16)`); PNG check: track x=48..1157 px → 16.0..385.7 pt. | stale: `SettingsPage.swift:69` now `onOpenSession: @escaping () -> Void = {}) {` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 434 | 74 | `SEGMENTED_PADDING_V_PT` | `9.33f` | `SettingsPage.swift:70` (`.padding(.vertical, 10)`) — but the    rendered  list starts at y=502 px = 167.33 pt, i.e. 9.3 | measured correction: source literal 10 at `SettingsPage.swift:70`, rendered baseline 9.33 wins | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 435 | 77 | `SEGMENTED_RADIUS_PT` | `16` | `settings-chat.png` (top-edge corner fit). | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 436 | 80 | `SEGMENTED_TOP_GAP_PT` | `20` | `settings-chat.png`: bar bottom 62 + 44 = 106 pt = 318 px, track top 378 px → 60 px = 20 pt. The page declares 10 pt of | measured PNG (no Swift line) | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 437 | 85 | `CARD_MARGIN_H_PT` | `16` | PNG check card white starts at x=48 px and ends at 1157 px → 16.0..385.7 pt on the 402 pt screen. | measured PNG (no Swift line) | 3 | `token:geometry.chromeInset` | read `UiTokenData.geometryChromeInset.value.dp` |
| 438 | 97 | `CARD_RADIUS_PT` | `26` | `settings-chat.png` first card: top edge y=606 px, left edge x=48 px. The   left boundary follows x=81 at y=620, x=56 at | measured PNG (no Swift line) | 3 | `page-local` | keep local; one page/surface layout value; no token fit |
| 439 | 127 | `SECTION_GAP_PT` | `35f` | `docs/receipts/ios-baseline-screens/ios-settings.png`, the PNG the   parity sheet lays beside the Android capture. Card | measured PNG (no Swift line) | 1 | `page-local` | keep local. Wave-3 round 1 measured a 57 pt iOS card-to-card band (system section header + grouped-list section spacing); neither `SettingsPage.swift` nor `tokens.json` declares it, so it is a contract gap and this 35 pt stays the pixel-suite band. |
| 440 | 116 | `FIRST_CARD_TOP_INSET_PT` | `34.67f` | PNG check grouped list background starts y=502 px, card 1 top y=606 px → 104 px = 34.7 pt. | measured PNG (no Swift line) | 3 | `page-local` | keep local; one page/surface layout value; no token fit |
| 441 | 129 | `SUB_PAGE_GROUPED_TOP_INSET_PT` | `45f` | `ios-settings-about.png` — the inline bar ends at the safe top 62 +   44 = 106 pt and the single card's top edge is y=45 | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 442 | 148 | `ROW_TEXT_OPTICAL_OFFSET_PT` | `-1f` | The row text's optical offset: 1 pt up, for labels and values only.     iOS `List` rows and Compose rows both cent | measured PNG (no Swift line) | 2 | `android-only` | keep local; Android glyph-metric optical correction; §5 `font-scale`/`cjk-fallback` cover the cause, so keep local. |
| 443 | 165 | `PARITY_SAFE_AREA_TOP_PT` | `62f` | the calibration above pins the inline bar to 62..106 pt (the title's   ink centre at 84.35 pt against a 44 pt bar), and | measured PNG (no Swift line) | 2 | `android-only` | keep local; Capture-harness only (hides system bars to match iOS safe area); §5 `insets` explains the platform difference. |
| 444 | 199 | `ROW_HEIGHT_PT` | `48f` | One grouped row's rendered height.     PR22's `HomeSpec.homeGroupedList()` sets   `.environment(\.defaultMinListRo | measured PNG (no Swift line) | 5 | `token:geometry.defaultMinListRowHeight` | read `UiTokenData.geometryDefaultMinListRowHeight.value.dp`. Wave-3 round 1 measured 62 pt rows in the iOS fixture: 32 pt content minimum (`SettingsPage.swift:459`) plus 30 pt system `List` padding, which no Swift literal or token declares — a contract gap; 48 stays the token-owned minimum. |
| 445 | 178 | `ROW_MIN_HEIGHT_PT` | `48` | `HomeSpec.homeGroupedList()` (`.environment(\.defaultMinListRowHeight, 48)`). | `HomeSpec.swift:207` `.environment(\.defaultMinListRowHeight, 48)` holds | 0 | `dead` | delete; value is token `geometry.defaultMinListRowHeight`; no Kotlin reader |
| 446 | 181 | `ROW_VERTICAL_PADDING_PT` | `12f` | arithmetic on [ROW_HEIGHT_PT] and the 16/24 body role. | derived / inferred | 0 | `dead` | delete |
| 447 | 184 | `ROW_CONTENT_INSET_PT` | `16` | PNG check label glyph starts x=98 px; card starts x=48 px → 16.7 pt (16 pt inset plus ~0.7 pt glyph bearing). | measured PNG (no Swift line) | 15 | `page-local` | keep local; read by 4 settings-family pages; token candidate, but evidence is PNG-only and token provenance requires a Swift file:line |
| 448 | 187 | `SEPARATOR_HEIGHT_PT` | `1f` | PNG check the hairline at y=760 occupies y=760..762 px → 3 px = 1.0 pt (iOS 26's grouped-list separator is thicker than | measured PNG (no Swift line) | 3 | `page-local` | keep local; one page/surface layout value; no token fit |
| 449 | 190 | `SEPARATOR_INSET_PT` | `16` | PNG check hairline x=96..1109 px, card x=48..1157 px → 16.0 pt on both sides. | measured PNG (no Swift line) | 4 | `page-local` | keep local; one page/surface layout value; no token fit |
| 450 | 195 | `CHEVRON_TRAILING_INSET_PT` | `18.67f` | PNG check card right 1157 px, chevron right 1101 px → 56 px = 18.7 pt. | measured PNG (no Swift line) | 0 | `dead` | delete |
| 451 | 198 | `CHEVRON_WIDTH_PT` | `6.33f` | PNG check x=1083..1101 px → 19 px = 6.3 pt. | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 452 | 201 | `CHEVRON_HEIGHT_PT` | `11.33f` | PNG check y=668..701 px → 34 px = 11.3 pt. | measured PNG (no Swift line) | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 453 | 204 | `VALUE_CHEVRON_SLOT_PT` | `20.67f` | PNG check value right 1039 px, chevron right 1101 px → 62 px = 20.7 pt. | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 454 | 207 | `VALUE_TRAILING_INSET_PT` | `39.33f` | arithmetic on the two measured edges; PNG check 1157-1039 = 118 px = 39.3 pt. | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 455 | 209 | `MENU_TRAILING_INSET_PT` | `17.6f` | A  menu  row's trailing inset: 17.6 pt from the card edge to the up-down chevron's right edge (`ios-settings.png` 语言 | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 456 | 212 | `MENU_CHEVRON_SLOT_PT` | `16f` | A  menu  row's glyph slot: 16.0 pt between the value's right edge (351.7) and the chevron's (367.7). Confidence: mea | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 457 | 215 | `SWITCH_WIDTH_PT` | `63` | PNG check green track x=927..1115 px → 189 px = 63.0 pt. | measured PNG (no Swift line) | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 458 | 218 | `SWITCH_HEIGHT_PT` | `29.67f` | PNG check green track y=2104..2192 px → 89 px = 29.7 pt. | measured PNG (no Swift line) | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 459 | 221 | `SWITCH_TRAILING_INSET_PT` | `14` | PNG check card right 1157 px, switch right 1115 px → 42 px = 14.0 pt. | measured PNG (no Swift line) | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 460 | 226 | `ROW_LABEL_REF_PT` | `16` | `SettingsRowLabel` (`.font(.system(size: HomeSpec.bodySize))` = 16). Reference only. | `SettingsPage.swift:442` `.font(.system(size: HomeSpec.bodySize))` = 16 holds | 0 | `dead` | delete; value is token `typography.body`; no Kotlin reader |
| 461 | 229 | `ROW_VALUE_REF_PT` | `15` | `SettingsRowLabel` value (`.font(.system(size: 15))`). Reference only. | no citation | 0 | `dead` | delete; value is token `typography.process`; no Kotlin reader |
| 462 | 232 | `FOOTNOTE_REF_PT` | `13` | `SettingsPage.swift:105,127` + `settings-chat.png`. | stale: `SettingsPage.swift:105` now `.navigationBarTitleDisplayMode(.inline)     }` | 0 | `dead` | delete; value is token `typography.secondary`; no Kotlin reader |
| 463 | 235 | `CAPTION_REF_PT` | `12` | `PhonePermissionsPage.swift:116`; reference only. | stale: `PhonePermissionsPage.swift:116` now `.fixedSize(horizontal: false, vertical: true)` | 0 | `dead` | delete; value is token `typography.caption`; no Kotlin reader |
| 464 | 240 | `ROW_GLYPH_BOX_PT` | `24` | `SettingsRowLabel` (`.frame(width: 24, height: 24)`). | no citation | 0 | `dead` | delete |
| 465 | 243 | `ROW_GLYPH_REF_PT` | `17` | `SettingsRowLabel` (`.font(.system(size: 17))`). | no citation | 0 | `dead` | delete |
| 466 | 246 | `ROW_GLYPH_GAP_PT` | `12` | `SettingsRowLabel` (`HStack(spacing: 12)`). | no citation | 0 | `dead` | delete |
| 467 | 249 | `ROW_LABEL_MIN_HEIGHT_PT` | `32` | `.frame(minHeight: 32)`. | no citation | 0 | `dead` | delete |
| 468 | 252 | `ROW_VALUE_LEADING_PT` | `8` | `SettingsRowLabel` (`Spacer(minLength: 8)`). | no citation | 0 | `dead` | delete |
| 469 | 255 | `GROUPED_LIST_BODY_REF_PT` | `16` | `HomeSpec.homeGroupedList()` (`.font(.system(size: HomeSpec.bodySize))`). | `HomeSpec.swift:207` `homeGroupedList()` body = 16 holds | 0 | `dead` | delete; value is token `typography.body`; no Kotlin reader |
| 470 | 258 | `GROUPED_LIST_MIN_ROW_HEIGHT_PT` | `48` | same helper (`defaultMinListRowHeight 48`). | no citation | 2 | `token:geometry.defaultMinListRowHeight` | read `UiTokenData.geometryDefaultMinListRowHeight.value.dp` |
| 471 | 265 | `FONT_STEPPER_WIDTH_PT` | `94` | PR22 `settings-font-runtime.png`, 1290x2796 at 3x (gray fill 279px plus antialiasing). | measured PNG (no Swift line) | 6 | `page-local` | keep local; one page/surface layout value; no token fit |
| 472 | 268 | `FONT_STEPPER_HEIGHT_PT` | `32` | Native Stepper painted height: 96px / 3 in the same reference. Confidence: measured. | measured PNG (no Swift line) | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 473 | 271 | `FONT_STEPPER_GLYPH_PT` | `14` | Plus/minus painted glyph extent in the same native Stepper capture. Confidence: measured (rounded). | measured PNG (no Swift line) | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 474 | 274 | `FONT_STEPPER_STROKE_PT` | `2` | Plus/minus stroke in the same 3x capture. Confidence: measured (rounded). | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 475 | 277 | `FONT_STEPPER_SEPARATOR_HEIGHT_PT` | `24` | Separator painted height inside the native Stepper. Confidence: measured (rounded). | measured PNG (no Swift line) | 2 | `page-local` | keep local; one page/surface layout value; no token fit |

### 3.4 `ShellFilesMetrics.kt` (26 rows)

| # | line | constant | value | claimed iOS source | citation check | refs | class | action / note |
|---:|---:|---|---|---|---|---:|---|---|
| 476 | 29 | `HEADER_HEIGHT_PT` | `44` | `NativeShell.swift:39` (`NativeHeaderStyle.barHeight = 44`), also `tokens.json` `geometry.pageHeaderMinHeight`. Not the | stale→`NativeShell.swift:45` `barHeight = 44` | 7 | `token:geometry.navButton` | read `UiTokenData.geometryNavButton.value.dp` |
| 477 | 32 | `HEADER_INSET_H_PT` | `16` | `NativeShell.swift:40` (`horizontalInset = 16`), applied at `:432`. | stale→`NativeShell.swift:46` `horizontalInset = 16` | 2 | `token:geometry.chromeInset` | read `UiTokenData.geometryChromeInset.value.dp` |
| 478 | 35 | `HEADER_TITLE_REF_PT` | `17` | `NativeShell.swift:41` (`titleSize = 17`). | stale→`NativeShell.swift:47` `titleSize = 17` | 0 | `dead` | delete; value is token `typography.pageTitle`; no Kotlin reader |
| 479 | 38 | `STATUS_DOT_PT` | `8` | `NativeShell.swift:42` (`statusDot = 8`). | stale→`NativeShell.swift:48` `statusDot = 8` | 0 | `dead` | delete; value is token `geometry.statusDotDiameter`; no Kotlin reader |
| 480 | 41 | `DRAWER_ROW_HEIGHT_PT` | `48` | `NativeShell.swift:448`. | stale→`NativeShell.swift:579` `.frame(height: 48)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 481 | 44 | `DRAWER_ROW_ICON_SLOT_PT` | `22` | `NativeShell.swift:437`. | stale→`NativeShell.swift:568` `.frame(width: 22)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 482 | 49 | `LARGE_TITLE_REF_PT` | `34` | old `.large` capture. | measured PNG (no Swift line) | 1 | `token:typography.largeTitle` | read `UiTokenData.typeLargeTitle.baseSize` |
| 483 | 52 | `INLINE_TITLE_REF_PT` | `17` | `FilesPage.swift` `.navigationBarTitleDisplayMode(.inline)` + `HomeAppearance` 17 pt semibold. | no line cited (`FilesPage.swift`) | 1 | `token:typography.pageTitle` | read `UiTokenData.typePageTitle.baseSize` |
| 484 | 55 | `GROUPED_LIST_BODY_REF_PT` | `16` | `HomeSpec.homeGroupedList()` (`HomeSpec.bodySize = 16`). | `HomeSpec.bodySize` = 16 @ `HomeSpec.swift:47` holds | 0 | `dead` | delete; value is token `typography.body`; no Kotlin reader |
| 485 | 58 | `GROUPED_LIST_MIN_ROW_HEIGHT_PT` | `48` | `HomeSpec.homeGroupedList()` (`48`). | `HomeSpec.swift:207` `.environment(\.defaultMinListRowHeight, 48)` holds | 2 | `token:geometry.defaultMinListRowHeight` | read `UiTokenData.geometryDefaultMinListRowHeight.value.dp` |
| 486 | 61 | `LARGE_TITLE_INSET_PT` | `16` | `darkpass-files-light.png` title ink box. | measured PNG (no Swift line) | 0 | `dead` | delete; value is token `geometry.chromeInset`; no Kotlin reader |
| 487 | 64 | `SEARCH_HEIGHT_PT` | `SessionsMetrics.SEARCH_HEIGHT_PT` | [SessionsMetrics.SEARCH_HEIGHT_PT] (measured 44.0 pt). | measured PNG (no Swift line) | 6 | `page-local` | keep local; one page/surface layout value; no token fit |
| 488 | 67 | `SEARCH_RADIUS_PT` | `SessionsMetrics.SEARCH_RADIUS_PT` | [SessionsMetrics.SEARCH_RADIUS_PT]. | measured PNG (no Swift line) | 5 | `page-local` | keep local; one page/surface layout value; no token fit |
| 489 | 70 | `SEARCH_INSET_PT` | `16` | PNG check grey field x=49..1155 px → 16.3..385.0 pt. | measured PNG (no Swift line) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 490 | 73 | `SEARCH_TEXT_REF_PT` | `17` | PNG check ink box 46 px = 15.3 pt → 17 pt font. Reference only. | measured PNG (no Swift line) | 0 | `dead` | delete |
| 491 | 76 | `FOLDER_ROW_MIN_HEIGHT_PT` | `44` | `FilesPage.swift:120` (`.frame(minHeight: 44)`). | stale→`FilesPage.swift:116` `.frame(minHeight: 44)` | 2 | `token:geometry.pageRowMinHeight` | read `UiTokenData.geometryPageRowMinHeight.value.dp` |
| 492 | 79 | `FILE_ROW_GLYPH_SLOT_WIDTH_PT` | `34` | `FilesPage.swift:189` (`.frame(width: 34, height: 38)`). | stale→`FilesPage.swift:183` `.frame(width: 34, height: 38)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 493 | 82 | `FILE_ROW_GLYPH_SLOT_HEIGHT_PT` | `38` | `FilesPage.swift:189`. | stale: `FilesPage.swift:189` now `if let folder = folderName {` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 494 | 85 | `FILE_ROW_GLYPH_PT` | `24` | `FilesPage.swift:188` (`size: 24`). | stale→`FilesPage.swift:182` `size: 24` | 0 | `dead` | delete |
| 495 | 88 | `FILE_ROW_GAP_PT` | `12` | `FilesPage.swift:187` (`HStack(spacing: 12)`). | stale→`FilesPage.swift:181` `HStack(spacing: 12)` | 0 | `dead` | delete |
| 496 | 91 | `FILE_ROW_TEXT_GAP_PT` | `3` | `FilesPage.swift:191` (`VStack(spacing: 3)`). | stale: `FilesPage.swift:191` now `.font(.system(size: 13))` | 0 | `dead` | delete |
| 497 | 94 | `FILE_ROW_PADDING_V_PT` | `3` | `FilesPage.swift:212` (`.padding(.vertical, 3)`). | stale→`FilesPage.swift:205` `.padding(.vertical, 3)` | 0 | `dead` | delete |
| 498 | 97 | `EMPTY_STATE_GAP_PT` | `8` | `FilesPage.swift:101` (`VStack(spacing: 8)`). | stale→`FilesPage.swift:98` `VStack(spacing: 8)` | 2 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 499 | 100 | `EMPTY_STATE_PADDING_V_PT` | `24` | `FilesPage.swift:112` (`.padding(.vertical, 24)`). | stale→`FilesPage.swift:107` `.padding(.vertical, 24)` | 1 | `stale` | re-anchor KDoc; cited iOS line does not carry this value now |
| 500 | 103 | `EMPTY_STATE_TITLE_REF_PT` | `17` | `FilesPage.swift:103` (`.font(.system(size: 17, weight: .semibold))`). Reference only. | stale: `FilesPage.swift:103` now `.foregroundStyle(ChatPage.inkSecondary)` | 0 | `dead` | delete; value is token `typography.pageTitle`; no Kotlin reader |
| 501 | 106 | `EMPTY_STATE_BODY_REF_PT` | `13` | `FilesPage.swift:106` (`.font(.system(size: 13))`). Reference only. | stale→`FilesPage.swift:102` `.font(.system(size: 13))` | 0 | `dead` | delete; value is token `typography.secondary`; no Kotlin reader |

### 3.5 `ConnectorsMetrics.kt` (26 rows)

| # | line | constant | value | claimed iOS source | citation check | refs | class | action / note |
|---:|---:|---|---|---|---|---:|---|---|
| 502 | 27 | `TILE_RADIUS_RATIO` | `0.27f` | `:167` (`cornerRadius: size   0.27`). | `ConnectorsPage.swift:167` `cornerRadius: size * 0.27` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 503 | 30 | `TILE_GLYPH_RATIO` | `0.46f` | `:163` (`size   0.46`). | `ConnectorsPage.swift:163` `size * 0.46` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 504 | 21 | `rowTile` | `44.dp` | `ConnectorsPage.swift:134` (`ConnectorTile(…, size: 44)`). | `ConnectorsPage.swift:134` `size: 44` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 505 | 24 | `sheetTile` | `96.dp` | `:198` (`size: 96`). | `ConnectorsPage.swift:198` `size: 96` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 506 | 33 | `rowSpacing` | `14.dp` | `:133` (`HStack(spacing: 14)`). | `ConnectorsPage.swift:133` `HStack(spacing: 14)` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 507 | 36 | `rowPaddingV` | `10.dp` | `:147` (`.padding(.vertical, 4)`) over the list row's own inset. | `ConnectorsPage.swift:147` `.padding(.vertical, 4)` + list inset ~ 10 (approximate) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 508 | 39 | `rowSeparatorInset` | `74.dp` | `:151` (`listRowSeparatorLeading … 58`) plus the 16 pt card inset. | `ConnectorsPage.swift:151` separator leading 58 + 16 card inset = 74 (approximate) | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 509 | 42 | `subtitleSize` | `13.sp` | `:140` (`.font(.system(size: 13))`). | `ConnectorsPage.swift:140` `.font(.system(size: 13))` holds | 1 | `token:typography.secondary` | read `UiTokenData.typeSecondary.baseSize` |
| 510 | 45 | `pillTextSize` | `15.sp` | `:178` (`.font(.system(size: 15, weight: .semibold))`). | `ConnectorsPage.swift:178` `size: 15, weight: .semibold` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 511 | 48 | `pillPaddingH` | `16.dp` | `:180` (`.padding(.horizontal, 16)`). | `ConnectorsPage.swift:180` `.padding(.horizontal, 16)` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 512 | 51 | `pillHeight` | `32.dp` | `:181` (`.frame(height: 32)`). | `ConnectorsPage.swift:181` `.frame(height: 32)` holds | 3 | `page-local` | keep local; one page/surface layout value; no token fit |
| 513 | 54 | `sectionHeaderSize` | `15.sp` | `:126` (`.font(.system(size: 15, weight: .medium))`). | `ConnectorsPage.swift:126` `size: 15, weight: .medium` holds | 0 | `dead` | delete; value is token `typography.process`; no Kotlin reader |
| 514 | 57 | `sheetTileTop` | `28.dp` | `:200` (`.padding(.top, 28)`). | `ConnectorsPage.swift:200` `.padding(.top, 28)` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 515 | 60 | `sheetTitleSize` | `24.sp` | `:202` (`.font(.system(size: 24, weight: .bold))`). | `ConnectorsPage.swift:202` `size: 24, weight: .bold` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 516 | 63 | `sheetTitleTop` | `16.dp` | `:204` (`.padding(.top, 16)`). | `ConnectorsPage.swift:204` `.padding(.top, 16)` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 517 | 66 | `sheetActionTop` | `20.dp` | `:208` (`.padding(.top, 20)`). | `ConnectorsPage.swift:208` `.padding(.top, 20)` holds | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 518 | 69 | `sheetActionMaxWidth` | `260.dp` | `:207` (`.frame(maxWidth: 260)`). | `ConnectorsPage.swift:207` `.frame(maxWidth: 260)` holds | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 519 | 72 | `sheetBodyTop` | `28.dp` | `:222` (`.padding(.top, 28)`). | `ConnectorsPage.swift:222` `.padding(.top, 28)` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 520 | 75 | `sheetBodyBottom` | `32.dp` | `:223` (`.padding(.bottom, 32)`). | `ConnectorsPage.swift:223` `.padding(.bottom, 32)` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 521 | 78 | `sheetBodySpacing` | `14.dp` | `:210` (`VStack(alignment: .leading, spacing: 14)`). | `ConnectorsPage.swift:210` `VStack(..., spacing: 14)` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 522 | 81 | `sheetBodyTextSize` | `15.sp` | `:212`, `:216` (`size: 15`). | `ConnectorsPage.swift:212,216` `size: 15` holds | 2 | `token:typography.process` | read `UiTokenData.typeProcess.baseSize` |
| 523 | 84 | `aboutHeaderTop` | `10.dp` | `:218` (`.padding(.top, 10)`). | `ConnectorsPage.swift:218` `.padding(.top, 10)` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 524 | 87 | `aboutCardRadius` | `20.dp` | `:317` (`RoundedRectangle(cornerRadius: 20)`). | `ConnectorsPage.swift:317` `cornerRadius: 20` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 525 | 90 | `aboutRowPadding` | `16.dp` | `:338` (`.padding(16)`). | `ConnectorsPage.swift:338` `.padding(16)` holds | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 526 | 93 | `aboutRowSpacing` | `4.dp` | `:327` (`VStack(… spacing: 4)`). | `ConnectorsPage.swift:327` `VStack(..., spacing: 4)` holds | 1 | `page-local` | keep local; one page/surface layout value; no token fit |
| 527 | 96 | `listBottom` | `24.dp` | List bottom clearance above the bottom menu. Approximate: the grouped list's own bottom inset. | no line cited; approximate grouped-list bottom inset | 1 | `page-local` | keep local; one page/surface layout value; no token fit |

### 3.6 `UiMetrics.kt` (24 rows)

| # | line | constant | value | claimed iOS source | citation check | refs | class | action / note |
|---:|---:|---|---|---|---|---:|---|---|
| 528 | 46 | `BASELINE_WIDTH_PT` | `430` | Design/capture width of the PR22 reference, in points. | measured PNG (no Swift line) | 6 | `android-only` | keep local; Capture-harness frame only (Android screenshot contract), no iOS source; not UI geometry. |
| 529 | 49 | `BASELINE_HEIGHT_PT` | `932` | Design/capture height of the PR22 reference, in points. | measured PNG (no Swift line) | 4 | `android-only` | keep local; Capture-harness frame only (Android screenshot contract), no iOS source; not UI geometry. |
| 530 | 52 | `BASELINE_DPR` | `3` | Device pixel ratio of the reference (`@3x`). | no citation | 5 | `android-only` | keep local; Capture-harness density only (`@3x` reference), no iOS source; not UI geometry. |
| 531 | 55 | `BASELINE_WIDTH_PX` | `BASELINE_WIDTH_PT * BASELINE_DPR` | Reference PNG width: `430 pt x 3`. | measured PNG (no Swift line) | 3 | `android-only` | keep local; Derived Android capture pixel width; no iOS source. |
| 532 | 58 | `BASELINE_HEIGHT_PX` | `BASELINE_HEIGHT_PT * BASELINE_DPR` | Reference PNG height: `932 pt x 3`. | measured PNG (no Swift line) | 3 | `android-only` | keep local; Derived Android capture pixel height; no iOS source. |
| 533 | 61 | `BASELINE_DENSITY_DPI` | `160 * BASELINE_DPR` | Android `wm density` that makes 1 dp equal 1 pt: `160 x 3`. | no citation | 3 | `android-only` | keep local; Android `wm density` for the capture harness; no iOS source. |
| 534 | 70 | `HEADER_HEIGHT_PT` | `44` | Floating nav row height: 44 pt (`HomeSpec.navButton`, `.nav { height: 44 }`).   It starts 8 pt below the top safe | `HomeSpec.navButton` = 44 @ `HomeSpec.swift:65` holds | 7 | `token:geometry.navButton` | read `UiTokenData.geometryNavButton.value.dp` |
| 535 | 73 | `HEADER_TITLE_ROW_PT` | `44` | The nav row is a single 44 pt row: title (22) + subtitle (20) fit inside it. | no citation | 0 | `dead` | delete; value is token `geometry.navButton`; no Kotlin reader |
| 536 | 76 | `HEADER_VERTICAL_PAD_PT` | `0` | No extra vertical padding inside the 44 pt nav row (the 8 pt is [HomeMetrics.NAV_TOP_PT]). | no citation | 0 | `dead` | delete |
| 537 | 79 | `COMPOSER_WIDTH_PT` | `398` | Composer card width at 430 pt: `430 - 2 x 16`. | derived: `430 - 2 × HomeSpec.chromeInset (16)`; no single Swift line | 5 | `page-local` | keep local; one page/surface layout value; no token fit |
| 538 | 82 | `COMPOSER_HEIGHT_PT` | `104` | Open composer minimum height (`HomeSpec.composerOpenMinHeight = 104`). | `HomeSpec.composerOpenMinHeight` = 104 @ `HomeSpec.swift:71` holds | 6 | `token:geometry.composerOpenMinHeight` | read `UiTokenData.geometryComposerOpenMinHeight.value.dp` |
| 539 | 85 | `COMPOSER_CLOSED_HEIGHT_PT` | `56` | Closed composer height (`.composer.closed { height: 56 }`). | no citation | 2 | `page-local` | keep local; one page/surface layout value; no token fit |
| 540 | 88 | `COMPOSER_RADIUS_PT` | `24` | Open composer radius (`HomeSpec.composerOpenRadius = 24`). | `HomeSpec.composerOpenRadius` = 24 @ `HomeSpec.swift:80` holds | 2 | `token:radius.composerOpen` | read `UiTokenData.radiusComposerOpen.dp` |
| 541 | 91 | `COMPOSER_CLOSED_RADIUS_PT` | `28` | Closed composer radius (`.composer.closed { border-radius: 28px }`). | no citation | 0 | `dead` | delete |
| 542 | 96 | `CONTENT_COLUMN_WIDTH_PT` | `390` | Reading content column at 430 pt: `430 - 2 x 20` (`HomeSpec.contentInset`). | derived: `430 - 2 × HomeSpec.contentInset (20)`; no single Swift line | 6 | `page-local` | keep local; one page/surface layout value; no token fit |
| 543 | 99 | `COMPOSER_OUTER_MARGIN_PT` | `(BASELINE_WIDTH_PT - COMPOSER_WIDTH_PT) / 2` | Composer-to-screen inset, both sides: `(430 - 398) / 2`. | no citation | 1 | `token:geometry.chromeInset` | read `UiTokenData.geometryChromeInset.value.dp` |
| 544 | 103 | `CONTENT_COLUMN_INSET_PT` | `(BASELINE_WIDTH_PT - CONTENT_COLUMN_WIDTH_PT) / 2` | Content-column inset, both sides: `(430 - 390) / 2`. | no citation | 0 | `dead` | delete; value is token `geometry.contentInset`; no Kotlin reader |
| 545 | 107 | `TOOL_ROW_HEIGHT_PT` | `24` | Collapsed process row height (`HomeSpec.processRowHeight = 24`). | `HomeSpec.processRowHeight` = 24 @ `HomeSpec.swift:68` holds | 2 | `token:geometry.processRowHeight` | read `UiTokenData.geometryProcessRowHeight.value.dp` |
| 546 | 110 | `FLOW_GAP_PT` | `20` | Block gap between transcript blocks (`HomeSpec.blockGap = 20`). | `HomeSpec.blockGap` = 20 @ `HomeSpec.swift:57` holds | 5 | `token:spacing.blockGap` | read `UiTokenData.spacingBlockGap.dp` |
| 547 | 113 | `FLOW_GAP_RESPONSE_PT` | `20` | Gap after a response row (`HomeSpec.blockGap = 20`; the old 12 is gone). | `HomeSpec.blockGap` = 20 @ `HomeSpec.swift:57` holds | 2 | `token:spacing.blockGap` | read `UiTokenData.spacingBlockGap.dp` |
| 548 | 116 | `FLOW_GAP_TURN_PROCESS_PT` | `20` | Gap after a turn-process control row (`HomeSpec.blockGap = 20`). | `HomeSpec.blockGap` = 20 @ `HomeSpec.swift:57` holds | 0 | `dead` | delete; value is token `spacing.blockGap`; no Kotlin reader |
| 549 | 119 | `PARAGRAPH_GAP_PT` | `16` | Paragraph gap after a user bubble / between paragraphs (`16`). | no citation | 2 | `token:spacing.paragraphGap` | read `UiTokenData.spacingParagraphGap.dp` |
| 550 | 122 | `DISCLOSURE_GAP_PT` | `8` | Process row to its opened card (`HomeSpec.disclosureGap = 8`). | `HomeSpec.disclosureGap` = 8 @ `HomeSpec.swift:61` holds | 1 | `token:spacing.disclosureGap` | read `UiTokenData.spacingDisclosureGap.dp` |
| 551 | 125 | `TAB_BAR_HEIGHT_PT` | `50` | Tab bar content height above the bottom safe area (`HomeSpec.tabBarHeight = 50`). | `HomeSpec.tabBarHeight` = 50 @ `HomeSpec.swift:22` holds | 1 | `token:geometry.tabBarHeight` | read `UiTokenData.geometryTabBarHeight.value.dp` |

### 3.7 `HomeMetrics.kt` (37 rows)

| # | line | constant | value | claimed iOS source | citation check | refs | class | action / note |
|---:|---:|---|---|---|---|---:|---|---|
| 552 | 24 | `CHROME_INSET_PT` | `HomeSpecData.CHROME_INSET` | Floating chrome (nav buttons, composer) is 16pt from the screen edge. | generated token read; no Swift claim | 3 | `token:geometry.chromeInset` | already generated (`HomeSpecData`) |
| 553 | 27 | `CONTENT_INSET_PT` | `HomeSpecData.CONTENT_INSET` | Reading content (messages, cards, tables) is 20pt from the edge. | generated token read; no Swift claim | 5 | `token:geometry.contentInset` | already generated (`HomeSpecData`) |
| 554 | 30 | `NAV_TOP_PT` | `HomeSpecData.NAV_TOP` | The nav row starts 8pt below the top safe area. | generated token read; no Swift claim | 3 | `token:geometry.navTop` | already generated (`HomeSpecData`) |
| 555 | 33 | `TAB_BAR_HEIGHT_PT` | `HomeSpecData.TAB_BAR_HEIGHT` | Tab-bar content height above the bottom safe area. | generated token read; no Swift claim | 1 | `token:geometry.tabBarHeight` | already generated (`HomeSpecData`) |
| 556 | 38 | `NAV_TITLE_SIZE_PT` | `HomeSpecData.NAV_TITLE_SIZE` | Nav title size (`17.5 / 600 / 22`; weight and line come from the HTML spec). | generated token read; no Swift claim | 2 | `token:typography.navTitle` | already generated (`HomeSpecData`) |
| 557 | 41 | `NAV_TITLE_LINE_PT` | `HomeSpecData.NAV_TITLE_LINE` | Nav title line box. | generated token read; no Swift claim | 1 | `token:typography.navTitle` | already generated (`HomeSpecData`) |
| 558 | 44 | `NAV_SUBTITLE_SIZE_PT` | `HomeSpecData.NAV_SUBTITLE_SIZE` | Nav subtitle (folder name) size. | generated token read; no Swift claim | 2 | `token:typography.navSubtitle` | already generated (`HomeSpecData`) |
| 559 | 47 | `NAV_SUBTITLE_LINE_PT` | `HomeSpecData.NAV_SUBTITLE_LINE` | Nav subtitle line box. | generated token read; no Swift claim | 1 | `token:typography.navSubtitle` | already generated (`HomeSpecData`) |
| 560 | 50 | `BODY_SIZE_PT` | `HomeSpecData.BODY_SIZE` | Body size (`16 / 24`). | generated token read; no Swift claim | 1 | `token:typography.body` | already generated (`HomeSpecData`) |
| 561 | 53 | `BODY_LINE_PT` | `HomeSpecData.BODY_LINE` | Body line box. | generated token read; no Swift claim | 1 | `token:typography.body` | already generated (`HomeSpecData`) |
| 562 | 56 | `PROCESS_SIZE_PT` | `HomeSpecData.PROCESS_SIZE` | Process-row size (`15`). | generated token read; no Swift claim | 1 | `token:typography.process` | already generated (`HomeSpecData`) |
| 563 | 59 | `LIST_ITEM_SIZE_PT` | `HomeSpecData.LIST_ITEM_SIZE` | Step-list item size (`14 / 22`). | generated token read; no Swift claim | 1 | `token:typography.listItem` | already generated (`HomeSpecData`) |
| 564 | 62 | `LIST_ITEM_LINE_PT` | `HomeSpecData.LIST_ITEM_LINE` | Step-list item line box. | generated token read; no Swift claim | 1 | `token:typography.listItem` | already generated (`HomeSpecData`) |
| 565 | 65 | `TAG_LABEL_SIZE_PT` | `HomeSpecData.TAG_LABEL_SIZE` | Tag label size (`12`, `HomeTag`). | generated token read; no Swift claim | 1 | `token:typography.tagLabel` | already generated (`HomeSpecData`) |
| 566 | 68 | `TAB_LABEL_SIZE_PT` | `HomeSpecData.TAB_LABEL_SIZE` | Tab label size (`10.5`). | generated token read; no Swift claim | 2 | `token:typography.tabLabel` | already generated (`HomeSpecData`) |
| 567 | 73 | `BLOCK_GAP_PT` | `HomeSpecData.BLOCK_GAP` | Between transcript blocks (process rows, paragraphs, cards). | generated token read; no Swift claim | 1 | `token:spacing.blockGap` | already generated (`HomeSpecData`) |
| 568 | 76 | `PARAGRAPH_GAP_PT` | `HomeSpecData.PARAGRAPH_GAP` | After a user bubble, and between paragraphs. | generated token read; no Swift claim | 2 | `token:spacing.paragraphGap` | already generated (`HomeSpecData`) |
| 569 | 79 | `DISCLOSURE_GAP_PT` | `HomeSpecData.DISCLOSURE_GAP` | From a process row to the card it opens. | generated token read; no Swift claim | 1 | `token:spacing.disclosureGap` | already generated (`HomeSpecData`) |
| 570 | 84 | `NAV_BUTTON_PT` | `HomeSpecData.NAV_BUTTON` | Square floating nav button (`44 x 44`, r22). | generated token read; no Swift claim | 2 | `token:geometry.navButton` | already generated (`HomeSpecData`) |
| 571 | 87 | `NAV_PILL_WIDTH_PT` | `HomeSpecData.NAV_PILL_WIDTH` | Device + more pill width (`92 x 44`). | generated token read; no Swift claim | 1 | `token:geometry.navPillWidth` | already generated (`HomeSpecData`) |
| 572 | 90 | `NAV_ICON_PT` | `HomeSpecData.NAV_ICON` | Nav button glyph box. | generated token read; no Swift claim | 1 | `token:geometry.navIcon` | already generated (`HomeSpecData`) |
| 573 | 93 | `PROCESS_ROW_HEIGHT_PT` | `HomeSpecData.PROCESS_ROW_HEIGHT` | Process row height. | generated token read; no Swift claim | 1 | `token:geometry.processRowHeight` | already generated (`HomeSpecData`) |
| 574 | 96 | `PROCESS_ICON_PT` | `HomeSpecData.PROCESS_ICON` | Process row glyph box. | generated token read; no Swift claim | 1 | `token:geometry.processIcon` | already generated (`HomeSpecData`) |
| 575 | 99 | `LIST_ROW_HEIGHT_PT` | `HomeSpecData.LIST_ROW_HEIGHT` | Step-list row height. | generated token read; no Swift claim | 1 | `token:geometry.listRowHeight` | already generated (`HomeSpecData`) |
| 576 | 102 | `DEFAULT_MIN_LIST_ROW_HEIGHT_PT` | `HomeSpecData.DEFAULT_MIN_LIST_ROW_HEIGHT` | Grouped list/Form default minimum row height (HomeSpec 48, separate from compact 22pt rows). | generated token read; no Swift claim | 12 | `token:geometry.defaultMinListRowHeight` | already generated (`HomeSpecData`) |
| 577 | 105 | `HOME_PRIMARY_BUTTON_HEIGHT_PT` | `HomeSpecData.HOME_PRIMARY_BUTTON_HEIGHT` | HomeSpec primary action capsule height (50). | generated token read; no Swift claim | 4 | `token:geometry.homePrimaryButtonHeight` | already generated (`HomeSpecData`) |
| 578 | — | `HOME_PRIMARY_BUTTON_DISABLED_OPACITY` | `HomeSpecData.HOME_PRIMARY_BUTTON_DISABLED_OPACITY` | `HomePrimaryButtonStyle` disabled fill opacity. | generated token read; no Swift claim | 0 | `deleted` | deleted in wave-3 round 2: dead since the pages adopted `primaryPressed`, which reads `interaction.pressed.primaryDisabledOpacity`; the generated `HomeSpecData` leaf remains. |
| 579 | — | `HOME_PRIMARY_BUTTON_PRESSED_OPACITY` | `HomeSpecData.HOME_PRIMARY_BUTTON_PRESSED_OPACITY` | `HomePrimaryButtonStyle` pressed content opacity. | generated token read; no Swift claim | 0 | `deleted` | deleted in wave-3 round 2: dead since the pages adopted `primaryPressed`, which reads `interaction.pressed.primaryPressedOpacity`; the generated `HomeSpecData` leaf remains. |
| 580 | 114 | `COMPOSER_OPEN_MIN_HEIGHT_PT` | `HomeSpecData.COMPOSER_OPEN_MIN_HEIGHT` | Open composer minimum height. | generated token read; no Swift claim | 1 | `token:geometry.composerOpenMinHeight` | already generated (`HomeSpecData`) |
| 581 | 117 | `SEND_BUTTON_PT` | `HomeSpecData.SEND_BUTTON` | Send / stop circle diameter. | generated token read; no Swift claim | 1 | `token:geometry.sendButton` | already generated (`HomeSpecData`) |
| 582 | 120 | `COMPOSER_ICON_PT` | `HomeSpecData.COMPOSER_ICON` | Composer glyph box. | generated token read; no Swift claim | 2 | `token:geometry.composerIcon` | already generated (`HomeSpecData`) |
| 583 | 123 | `TAB_ICON_PT` | `HomeSpecData.TAB_ICON` | Tab bar glyph box. | generated token read; no Swift claim | 1 | `token:geometry.tabIcon` | already generated (`HomeSpecData`) |
| 584 | 128 | `BUBBLE_RADIUS_PT` | `HomeSpecData.BUBBLE_RADIUS` | User bubble radius; the top-trailing corner is square (see below). | generated token read; no Swift claim | 2 | `token:radius.bubble` | already generated (`HomeSpecData`) |
| 585 | 131 | `BUBBLE_TOP_TRAILING_RADIUS_PT` | `HomeSpecData.BUBBLE_TOP_TRAILING_RADIUS` | Top-trailing corner of `HomeSpec.bubbleShape`: `UnevenRoundedRectangle` sets it to 0. | generated token read; no Swift claim | 3 | `token:geometry.bubbleTopTrailingRadius` | already generated (`HomeSpecData`) |
| 586 | 134 | `BUBBLE_MAX_WIDTH_RATIO` | `HomeSpecData.BUBBLE_MAX_WIDTH_RATIO` | Runtime bubble cap rule: `(containerWidth - 2   contentInset)   ratio`; never a fixed width. | generated token read; no Swift claim | 2 | `token:geometry.bubbleMaxWidthRatio` | already generated (`HomeSpecData`) |
| 587 | 137 | `LIST_CARD_RADIUS_PT` | `HomeSpecData.LIST_CARD_RADIUS` | White step-list card radius. | generated token read; no Swift claim | 1 | `token:radius.listCard` | already generated (`HomeSpecData`) |
| 588 | 140 | `COMPOSER_OPEN_RADIUS_PT` | `HomeSpecData.COMPOSER_OPEN_RADIUS` | Open composer radius. | generated token read; no Swift claim | 1 | `token:radius.composerOpen` | already generated (`HomeSpecData`) |

## 4. `token-new` proposals

These are the constants that meet the brief’s `token-new` bar (a real iOS value, missing from `tokens.json`, and on a signature surface). All four are read today; all four have an exact current Swift line. `COMPOSER_PORT_MIN_HEIGHT_PT` (56, `ChatPage.swift:2405`) is the optional fifth: it is read today as the containing port floor, but the composer port is still a literal, so it is a `page-local` row and a `geometry.composerPortMinHeight` proposal rather than a landed token. `COMPOSER_TEXT_MIN_HEIGHT_PT` (36, `ChatPage.swift:3893`) is the editable-surface floor inside that port and stays page-local because the source has no token for it.

| proposed id | value | current Swift provenance | used by | why it is a token |
|---|---:|---|---|---|
| `geometry.composerOuterMarginBottom` | 0 | `ChatPage.swift:2320` `.padding(.bottom, 0)` | `Composer.kt` (composer signature surface) | the old token/KDoc carried 8; the live source is 0 and the value is part of the composer’s outer box |
| `geometry.composerPortLeading` | 11 | `ChatPage.swift:2377` `.padding(.leading, 11)` | `Composer.kt` (composer signature surface) | input-port inset is signature geometry; no leaf exists |
| `geometry.composerPortTrailing` | 8 | `ChatPage.swift:2378` `.padding(.trailing, 8)` | `Composer.kt` (composer signature surface) | input-port inset is signature geometry; no leaf exists |
| `geometry.approvalCardSpacing` | 10 | `ChatPage.swift:5176` `VStack(alignment: .leading, spacing: 10)` | `ApprovalCard.kt` (approval signature surface) | row spacing of the signature approval card; no leaf exists |

`COMPOSER_PORT_MIN_HEIGHT_PT` 56 (`ChatPage.swift:2405`) is the optional fifth: it is read as the containing port floor, and if the composer port is tokenised it should become `geometry.composerPortMinHeight` rather than stay a literal. It is not dead and is no longer 36.

## 5. Proposed convergence order

The order is by **number of rows removed or converted**, not by file name. Each task owns disjoint files. Within a task the safe sequence is: delete dead → replace token literals with generated reads → re-anchor KDocs (comments last, so the diff does not churn while the code moves) → add a token only with its consumer in the same head (an orphan geometry token fails `PageGeometryTokenTest`).

| order | task | owned files | dead | token | token-new | stale | page-local | android-only |
|---:|---|---|---:|---:|---:|---:|---:|---:|
| 1 | T1 — Chat family | `ChatMetrics.kt`, `UiMetrics.kt`, `spec/ui/v1/tokens.json` | 99 | 45 | 4 | 169 | 72 | 9 |
| 2 | T2 — Drawer/files family | `SessionsMetrics.kt`, `ShellFilesMetrics.kt` | 23 | 13 | 0 | 33 | 8 | 0 |
| 3 | T3 — Settings/connectors family | `SettingsMetrics.kt`, `ConnectorsMetrics.kt` | 16 | 6 | 0 | 1 | 50 | 3 |
| 4 | T4 — Home facade (verify only) | `HomeMetrics.kt` (no edit expected) | 0 | 37 | 0 | 0 | 0 | 0 |

### T1 — `ChatMetrics.kt` + `UiMetrics.kt` (biggest win)

Rows: 398. Delete 99 dead constants; replace 45 token literals with generated reads; re-anchor 169 stale KDocs; add the 4 token-new leaves and read them. Keep 72 page-local and 9 android-only rows, with the table note as the justification comment.

- `ChatMetrics` is 374 rows; `UiMetrics` is 24. Consolidate the `UiMetrics` duplicates (`COMPOSER_HEIGHT_PT`, `COMPOSER_RADIUS_PT`, `HEADER_HEIGHT_PT`, `FLOW_GAP_PT`, `PARAGRAPH_GAP_PT`, `DISCLOSURE_GAP_PT`, `TAB_BAR_HEIGHT_PT`, and the already-dead `COMPOSER_CLOSED_RADIUS_PT`): move each consumer to the surviving owner first, then delete the copy. This is the one case where a token-row constant is removed; it needs the consumer files listed in §6. `UiMetrics` should keep only the capture-frame constants and the values that are genuinely its own (see its header: “NOT a second token store”).
- Do **not** delete a `token` row’s public constant just because it duplicates a token: consumers call the constant by name. Change its value expression to the generated read (`UiTokenData.geometryX…`, `UiTokenData.typeX.baseSize`, etc.) so the signature stays source-compatible; delete only `dead` rows.
- The token-new additions must be one change with their consumers: add the four `geometry.*` leaves and their provenance, then switch the four `ChatMetrics` rows to reads. A token with no `signatureSurfaces`/page owner fails `PageGeometryTokenTest`.
- `UiTokens.kt` is hand-written and only maps a subset of leaves into `UiGeometry`; reading `UiTokenData.geometry…` directly needs no edit there. If the task wants named fields instead, `UiTokens.kt` is owned by that task (outside the two Metrics files).

Acceptance (after T1):

```bash
bash android/tools/with-android-toolchain.sh ./gradlew :lib:testDebugUnitTest --no-daemon
bash scripts/ci/check.sh --only phone-android-tests
bash scripts/ci/check.sh --only phone-p0-conformance
bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree   # only if tokens.json changed
git diff --check
```

### T2 — `SessionsMetrics.kt` + `ShellFilesMetrics.kt`

Rows: 77. Delete 23; convert 13 to reads; re-anchor 33; keep 8 page-local. First fix the two name collisions: `DRAWER_ROW_HEIGHT_PT` (44 vs 48) and `DRAWER_ROW_ICON_SLOT_PT` (24 vs 22) must become role-named or one file must drop its copy. `SEARCH_HEIGHT_PT`, `SEARCH_RADIUS_PT`, `SEARCH_INSET_PT` are declared twice (ShellFiles delegates to Sessions); keep the Sessions owner and have ShellFiles read it, or move the search metrics to a shared owner. The search values are PNG-measured, so they stay page-local unless the spec provenance rule changes.

Acceptance: same Gradle/CI commands as T1 (no `tokens.json` change expected).

### T3 — `SettingsMetrics.kt` + `ConnectorsMetrics.kt`

Rows: 76. Delete 16; convert 6 to reads; re-anchor 1; keep 50 page-local and 3 android-only. This family is mostly measured page geometry, so the win is the 16 dead reference-only constants and the six token reads, not new tokens. `ROW_CONTENT_INSET_PT` (16) is read by four pages and is the one real token candidate, but its only evidence is a PNG measurement; do not invent a Swift line — see §6.

### T4 — `HomeMetrics.kt` (verify only)

All 37 constants already read `HomeSpecData` (the generated facade). There is no value to converge. Keep this file as the single `HomeSpecData` declaration site; the only work is a gate run and, if the generator changes, `HomeMetricsTest`.

### T5 — gates and the next wave (no source ownership)

After T1–T3: run `bash scripts/ci/check.sh --only phone-android-tests,phone-android-structure,phone-p0-conformance`, then the full `bash scripts/ci/check.sh` once. The known pre-existing reds are in `docs/parity/lessons.md` §3 (`page-structure` 7 diffs, `android-structure` readme-map); a worker must confirm the reds are only those and report them, not fix them.

## 6. Needed outside my scope

1. **`spec/ui/v1/tokens.json` + provenance for the four `token-new` leaves.** This is a contract-layer edit; the Android task cannot add a geometry leaf on its own. It must land with its consumer (T1) so `PageGeometryTokenTest` does not see an orphan. The proposed provenance is in §4. `spec/ui/v1/README.md`’s geometry table may need one row if the checker requires the page-layer owner to be listed.
2. **`UiTokens.kt` / `UiGeometry`.** The generator emits `UiTokenData.geometry…` for every leaf, but the hand-written `UiGeometry` data class maps only a subset. If T1 wants named `tokens.geometry.composerPortLeading` fields rather than direct `UiTokenData` reads, `android/lib/src/main/kotlin/com/phonedsh/ui/theme/UiTokens.kt` changes; it is outside the seven `*Metrics.kt` files.
3. **Consumer files if a duplicate owner is dropped.** Deleting `UiMetrics`/`ChatMetrics` duplicates is source-compatible only while the surviving name is the one consumers import. The table’s `refs` column and the duplicate table in §2.4 name the files to inspect (`ChatPage.kt`, `ChatRows.kt`, `Composer.kt`, `ApprovalCard.kt`, `SessionsPage.kt`, `PdshDrawer.kt`, `SettingsChrome.kt`, `FilesPage.kt`, etc.). Those files are not mine; assign them to T1/T2/T3 if a rename is chosen.
4. **`PageGeometryTokenTest` unchanged.** Its header rule (surface-owned / contract-owned / ≥2 pages / HomeSpec-owned) is the rule this classification follows. If a page-local value is promoted, the test must continue to pass; do not relax it.
5. **`ShellFilesMetrics` KDoc contradiction.** It says the chat header is 50 (`ChatMetrics.HEADER_HEIGHT_PT`), but `ChatMetrics.HEADER_HEIGHT_PT` is 44 and the current `HomeSpec.navButton` is 44. Fix the comment in T2; do not change the value to 50 (that is the legacy `NativeParityTokens.headerHeight`).
6. **`SessionsMetrics` header wording.** The file header says PR22 replaced the 320 pt drawer with a full-screen `HomeDrawer`, but `DRAWER_WIDTH_PT` reads `geometry.drawerWidth` (320) and `NativeShell.swift:112` still defines `drawerWidth = 320`. Fix the comment in T2; the token value is not stale.
7. **Measured page geometry cannot become a token under the current provenance rule.** `ROW_CONTENT_INSET_PT` (4 pages), `SEARCH_HEIGHT_PT`/`SEARCH_RADIUS_PT` (2 pages), and the settings card/row measurements are real values with only PNG evidence. `tokens.json` provenance is `file:line`; adding them would require inventing a Swift line. If the contract owner wants them tokenised, that is a provenance-tier change (a `CONTRACT CHANGE REQUEST`), not a worker guess. The tables therefore keep them `page-local`.

## 7. Limitations and how to read a `stale` row

- `stale` means **the cited line is wrong**, not necessarily the value. Many rows have the correct value at another current line; where the KDoc’s code fragment was unique, the table gives `stale→File:newline`. Where it was not, the table gives the current line only; re-anchor by role, not by searching for the bare number.
- The `refs` count is identifier-based and includes comments/tests. A `0` is a real absence of the exact name in `android/**/*.kt`; it does not prove the value is unused (the page may re-type the number). That is precisely why the `page-local` rows are worth keeping until the page reads them.
- The four `token-new` rows and all `token` rows were checked against current Swift lines by value, but this is still a static audit. No emulator, screenshot comparison or device measurement was run.
- `Confidence: measured` rows are not re-measured here. Their PNG citations are accepted as the KDoc’s evidence; only the ones that also claim a Swift line are marked stale when that line fails.

## Appendix A — `ChatMetrics.kt` derived `Dp` accessors (not classified)

`headerHeight`, `headerHorizontalInset`, `transcriptSideInset`, `flowGap`, `responseGap`, `turnGap`, `disclosureRowHeight`, `composerWidth`, `composerHeight`, `composerRadius`, `sendDiameter`, `permissionCardRadius` — each is `get() = <CONST>.dp` and carries no independent value. They are the remaining 12 of the brief’s 386 `val`s. `UiMetrics`, `HomeMetrics`, `SettingsMetrics`, `ShellFilesMetrics` and `SessionsMetrics` have analogous pass-through accessors; they are excluded for the same reason. `ConnectorsMetrics`’ literal `val … get() = N.dp` declarations are included because they are not pass-throughs.

## Appendix B — class rules used in one line

`dead` (0 refs) → `token:<leaf>` (same semantic value already in tokens) → `token-new:<proposed>` (signature-surface value missing from tokens) → `android-only` (platform-forced) → `stale` (cited line fails) → `page-local` (one page/surface, not a token under the PageGeometryTokenTest rule).
