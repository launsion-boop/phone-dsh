# L6 — UI metrics extracted from iOS source and baseline pixels

Status: **delivered**. Four `*Metrics.kt` declaration sites were added under
`android/lib/src/main/kotlin/com/phonedsh/ui/`; no page file and no spec file was
touched. `PageTokenReferenceTest` still passes (6/6).

The point of this lane: the three page lanes needed geometry that
`spec/ui/v1/tokens.json` does not declare. Instead of picking the closest token
and writing `unverified geometry`, every value below now has a **named source**
(a Swift literal with `file:line`, or a reproducible pixel measurement) and a
**confidence level**. Values that could not be established are listed in §3 and
were **not** encoded.

---

## 1. Method and authority

| priority | source | what it contributed |
|---|---|---|
| 1 | `examples/probe-app/PhoneDSHProbe/*.swift` | almost everything: explicit `.frame`, `.padding`, radii, font sizes, list insets, layout constants |
| 2 | `docs/receipts/ios-session-audit/screens/official/manifest.json` | **only** the viewport (402×874, DPR 3, PNG 1206×2622) and interaction `rect`s. It has **no layout-metric table**; it contributed no geometry |
| 3 | `docs/receipts/ios-session-audit/screens/current/*.png` (2026-11-01) | system-drawn chrome the Swift does not write: search field, grouped-list rows, switch, chevron, nav bar, large title |
| 4 | `spec/ui/v1/pages/*.json` | **nothing** — 24 contracts are stale (§4) and none carries geometry |

Pixel convention: PNGs are 1206×2622 at DPR 3, so `pt = px / 3`. Screenshots from
`docs/receipts/ios-baseline-screens/` (2026-10-31) were **not** used for chat or
settings: they predate the parity rewrite (§4). The 2026-11-01
`screens/current/` set was used instead.

One calibration is shared by every y-coordinate: the screen's top safe area is
**62 pt**. Check inside the same PNG set: the chat header is 50 pt
(`NativeParityTokens.swift:99`) and `sample-chat.png` draws its header hairline at
`y=335 px = 111.7 pt = 62 + 50`; independently, the Settings inline title's ink
centre is `y=253 px ≈ 84 pt = 62 + 22`.

Confidence vocabulary (repeated in every metrics file):

* **exact** — a literal (or token) in the Swift source;
* **measured** — read from a PNG, with the pixel evidence in the KDoc so it can
  be reproduced;
* **inferred** — derived from other values, never stated; each says from what.

Reproduction helper (used for every measurement below):

```python
from PIL import Image; import numpy as np
a = np.asarray(Image.open(path).convert("RGB")).astype(int)
# row/column scans: print runs of constant colour, then divide px by 3
```

---

## 2. Metric inventory

The Kotlin files are the canonical, per-constant record (every constant carries
its own `Source:` and `Confidence:` line). This is the review summary.

### 2.1 Sessions family — `SessionsMetrics.kt`

| name | value (pt) | source | confidence |
|---|---|---|---|
| drawerColumnWidth | **320** | `NativeShell.swift:97` `drawerWidth = 320`; `:850` preview | exact |
| drawerContentWidth | **288** | `SessionsPage.swift:594` comment + hard-coded separator `:157,:596` (320−16−16) | exact |
| rowInset | **16** | `SessionsPage.swift:162,195,281,460,590` | exact |
| searchHeight | **44** | `darkfinal-sessions-light.png`: white capsule `y=350..482 px` → 132 px; same on `darkpass-files-light.png` `y=508..639` | measured |
| searchRadius | **22** | same shot, corner fit: top row white starts `x=102 px`, reaches `x=50 px` at `y=400`; capsule r = 66 px | measured |
| searchInset / width | **16 / 370** | `x=48..1157 px` | measured |
| sessionRowHeight | **56** | `SessionsPage.swift:580` `minHeight: 56`; PNG separators `y=1346,1514,1682…` = 168 px pitch | exact + measured |
| workspaceRowHeight ("组头") | **44** | `SessionsPage.swift:439` `.frame(height: 44)` | exact |
| actionRowHeight | **44** | `SessionsPage.swift:164,194,277` | exact |
| listSeparator | **288 × 0.5, inset 16** | `SessionsPage.swift:157,596`; PNG hairline `x=48..911 px` | exact + measured |
| ctaHeight / ctaRadius | **50 / 12** | `SessionsPage.swift:223,225`; PNG blue box `y=1046..1195 = 150 px`, corner fit r≈36 px | exact + measured |
| drawerRowHeight (bottom 定时任务/设置) | **48** | `NativeShell.swift:433` | exact |
| drawerRowIconSlot | **22** | `NativeShell.swift:422` | exact |
| sessionGlyph / gap / textGap | **17×17 / 10 / 3** | `SessionsPage.swift:550,546,551` | exact |
| toastHeight / radius | **28 / 12** | `SessionsPage.swift:332,334` | exact |
| emptyState top / bottom | **24 / 8** | `SessionsPage.swift:228,232` | exact |

Type reference (not Compose sizes): session title `.body` = 17, timestamp
`.caption` = 12, workspace title 17/600 (`SessionsPage.swift:427`), count 13
(`:433`).

### 2.2 Settings family — `SettingsMetrics.kt`

**The current page is not the page L3 measured.** `SettingsPage.swift` is now
255 lines: a 5-tab `Picker(.segmented)` over a default inset-grouped `List`
(`:64-72`, `:99-167`). The old flat-list numbers are superseded:

| L3's old number | current measured value | evidence |
|---|---|---|
| row 44 + overlay hairline | **row 52.33**, separator **1.0** inside a card | `settings-chat.png` separators `y=1179,1336,1493,1912,2069,2226` → 157 px = 52.33 pt, four times; hairline 3 px = 1 pt |
| value 15 pt | **17 pt** | "未设置" ink box 45 px = 15 pt ink → 17 pt font |
| hairline x 16 → 385.7, 0.33 pt | card x **48..1157 px** = 16..385.7; separator inset 16 inside the card; 1 pt | as above |
| group header 13, x32.7, 24 top / 8 bottom | **no section headers exist** in the current general tab (only footnotes) | `SettingsPage.swift:99-167` |

| name | value (pt) | source | confidence |
|---|---|---|---|
| navBarHeight | **44** | `.inline` (`SettingsPage.swift:169`) + token `pageHeaderMinHeight`; title centre `y=253 px` with 62 pt safe top | measured |
| navTitle | **17 / 600**, centred | PT ink 44 px → 17 pt; weight is the system inline-title role | measured / inferred |
| segmentedHeight | **32** | track `y=378..473 px` | measured |
| segmentedInset / paddingV | **16 / 10** | `SettingsPage.swift:69-70` | exact |
| segmentedRadius | **16** | capsule = height/2 | inferred |
| segmentedTopGap | **20** | nav bottom `62+44=106 pt=318 px`, track top 378 px → 20 pt; page declares 10, system adds 10 | measured |
| cardMarginH | **16** | card `x=48..1157 px` | measured |
| cardRadius | **26** (continuous) | top-left corner: `x=81@y=620`, `x=56@y=650`, reaches 48 at ~676 px → r≈78 px | measured |
| sectionGap | **38.67** | card1 bottom `y=914` → card2 top `y=1030` (also 1647→1763, 2380→2496) | measured |
| firstCardTopInset | **34.67** | list background `y=502` → card top `y=606` | measured |
| rowHeight | **52.33** | 157 px pitch, 4× | measured |
| rowVerticalPadding | **16** | (52.33 − 20.33 line box)/2 | inferred |
| rowContentInset | **16** | label glyph `x=98 px`; card starts 48 px → 16.7 | measured |
| separatorHeight / inset | **1.0 / 16** | 3 px line; `x=96..1109 px` | measured |
| chevron | **6.33 × 11.33**, trailing **18.67** | `x=1083..1101`, `y=668..701 px`; card right 1157 | measured |
| value→chevron slot ("值右缘 20.7") | **20.67** | value right 1039 px → chevron right 1101 px = 62 px | measured |
| value trailing inset | **39.33** | card right 1157 − value right 1039 = 118 px | measured |
| switch | **63 × 29.67**, trailing **14** | `x=927..1115`, `y=2104..2192 px` | measured |
| row label / value / footnote | **17 / 17 / 13** | ink boxes 45/45/35 px; footnote role `.footnote` | measured / exact |

### 2.3 Chat family — `ChatMetrics.kt`

| name | value (pt) | source | confidence |
|---|---|---|---|
| headerHeight | **50** | `NativeParityTokens.swift:99`; hairline at `y=335 px` in `sample-chat.png` | exact + measured |
| headerTitle | **14 / medium** | `NativeParityTokens.swift:65-66`; ink 38 px | exact |
| headerInsets / slots | **16**; **32/36/44 × 44**; title reserve **104** | `ChatPage.swift:302,224,235,288,216` | exact |
| headerDivider | **0.5** | `ChatPage.swift:199` | exact |
| contentColumn / side | **338 / 32** | `NativeParityTokens.swift:94,123` | exact |
| transcript top / bottom | **16 / 48** | `ChatPage.swift:1163,1166` | exact |
| flow / response / turn gap | **6 / 12 / 16** | `NativeParityTokens.swift:120-122` | exact |
| toolRow / turnProcess | **24 / 33** | `NativeParityTokens.swift:101,100`; `NativeMessageRows.swift:43`, `NativeTurnProcessRow.swift:179` | exact |
| disclosure icon / gap | **16 / 6** | `NativeMessageRows.swift:26-27` | exact |
| thinking indent / v | **22 / 4** | `NativeMessageRows.swift:82-83` | exact |
| userBubbleRadius | **20** | `NativeParityTokens.swift:115`; `ChatPage.swift:3741` | exact |
| userBubbleMaxWidth | **277** | `NativeParityTokens.swift:98`; applied `ChatPage.swift:3742` | exact |
| userBubblePadding | **16 h / 10 v** | `ChatPage.swift:3739,3738` | exact |
| userBubbleLine | **22** | `NativeParityTokens.swift:74-76` | exact |
| composer | **370 × 98, r28** | `NativeParityTokens.swift:96,97,116`; `:1884`; 98 = 8+36+10+32+12 | exact |
| composer margins | **16 / 12 / 8** | `ChatPage.swift:1892-1894` | exact |
| port | **min 36, max 336, lead 14, trail 8, top 8, font 16** | `ChatPage.swift:1851,1841,1849,1850,1852`; `NativeParityTokens.swift:79` | exact |
| control row | **32 h, lead 14, trail reserve 40, top 10, bottom 12** | `ChatPage.swift:1865-1869` | exact |
| send | **34 circle, 44 hit, 2 inset; stop 24/34** | `ChatPage.swift:1967,1970,1880-1881,1876,1963` | exact |
| permission card | **r12, pad 14, gap 10, outer 16/8; CTA 48 r12; deny 44** | `ChatPage.swift:4425,4447-4448,4460,4465,4468-4469` | exact |
| tool card | **r16, border 0.5, outer 4, banner 10/8/22/18, action 24, body 22/6/20, IO 16/12 max 150** | `NativeToolCardChrome.swift:33-59` | exact |
| tool details | **r16, pad 12, item 10/14, max 320** | `NativeToolDetailsCard.swift:23-25` | exact |
| standalone code block | **r12, banner 34, pad 12, expand 32, collapsed max 300** | `Components.swift:196,207,209,216,221` | exact |
| todo / question / plan / subagent menu | **36,180 / 520,40 / 60 / 336** | `NativeParityTokens.swift:102-107` | exact |
| queue row / header / dock | **28 r8 / 32 / r12** | `ChatPage.swift:1690,1692,1557,1577` | exact |

### 2.4 Shell / Files family — `ShellFilesMetrics.kt`

| name | value (pt) | source | confidence |
|---|---|---|---|
| shell header | **44 / inset 16 / title 17 / dot 8** | `NativeShell.swift:39-43` | exact |
| drawer furniture row | **48 / icon slot 22 / gap 10** | `NativeShell.swift:421-433` | exact |
| Files large title | **34**, leading 16 | `.large` at `FilesPage.swift:52`; ink 89 px = 29.7 → 34 pt | measured |
| Files search | **44 / r22 / inset 16 / text 17** | `darkpass-files-light.png` field `y=508..639 px`, `x=49..1155 px`; ink 46 px | measured |
| folder row | **min 44** | `FilesPage.swift:120` | exact |
| file row | glyph **24** in **34×38**, gap 12, text gap 3, padding v3 | `FilesPage.swift:187-212` | exact |
| empty state | gap **8**, padding v **24**, title 17/600, body 13 | `FilesPage.swift:101-112` | exact |

Files uses `.insetGrouped` (`FilesPage.swift:53`), i.e. the same system chrome as
Settings: reuse `SettingsMetrics.CARD_MARGIN_H_PT`, `CARD_RADIUS_PT`,
`ROW_HEIGHT_PT` rather than re-inventing them. No Files card shot exists to
measure independently.

---

## 3. What could not be determined (and was therefore not encoded)

This is the honest part. Each item is either absent from the source and not
measurable, or contradictory between source and pixels.

1. **The shipped drawer's search field does not exist.** `NativeShell.swift:291`
   hides the navigation bar for the drawer (`.toolbar(.hidden, for:
   .navigationBar)`), so the current drawer renders no title and no search. The
   44 / 22 measurement comes from the standalone `SessionsPage` presentation
   (`darkfinal-sessions-light.png`). If L2's drawer shows a search box, that is a
   product divergence, not a port of current iOS chrome. **Recommendation:** keep
   the field (it is useful) at the measured 44 / 22 and record it as a deliberate
   divergence, or hide it like iOS.
2. **"search 40 / r20" cannot be confirmed anywhere.** Sessions and Files both
   measure 44 / 22. The official-web manifest has no search rect. No source
   literal. **Recommendation:** 44 / 22; do not encode 40 / 20.
3. **Drawer row pitch / inter-row spacing.** Source heights are 44 (workspace)
   and 56 (session), but in `darkfinal-drawer-light.png` the workspace row's
   centre is `y=602 px` and the session row's centre `y=763 px` — 161 px = 53.7 pt
   apart, while 44/2 + 56/2 = 50 pt. Separately, the 新建会话 separator is at
   `y=509 px` and the workspace row starts at `y≈536 px` (if 44 tall), a 9 pt gap
   the source does not declare. This is likely iOS 26 `List` section/row spacing
   (the same PNG shows a 4 pt-feeling gap elsewhere). I could not attribute it to
   a source value, so no constant was added. **Recommendation:** lay out 44/56
   with 0 gap, then compare against a *fresh* drawer capture (the 2026-11-01
   13:04 drawer shot is chrome-stale — §4).
4. **"Group header 44".** There is no section header in the current Sessions
   source; the 44 pt thing is the workspace **row** (`:439`). The real `Section`
   header (已归档) is a button header whose height is not measurable from the
   available shot. Encoded the row, not a header.
5. **Settings section headers 13 / 24+8 / x32.7.** The current general tab has no
   section headers. They were part of the removed flat list. The 13 pt footnote
   exists and is encoded, but it is a footnote, not a header. **Recommendation:**
   if L3 keeps the old page design, it must also keep the old measurements from
   `VISUAL.md` §2, labelled legacy.
6. **Settings 15 pt value and 0.33 pt hairline.** Both are flat-list artifacts;
   the current render is 17 pt / 1 pt. Cannot be reproduced from current source.
7. **Settings card radius 26 is a continuous-corner nominal.** The corner is not
   circular (the top edge begins ~95 px in, the left edge lands ~70 px down), so
   a circular fit of 26 pt is approximate. A `RoundedCornerShape(26.dp)` is the
   closest Compose equivalent; a pixel diff will show a small corner delta.
8. **Files file-row height.** Content-driven: `.body` + optional `.caption` +
   `.caption2` + 3 pt padding. A folder+size row is ~61 pt by text metrics, but I
   had no populated Files screenshot to measure. Only `minHeight 44` (folders) is
   encoded. **Recommendation:** content-sized rows with 44 min.
9. **Chat body font size is a user preference, not a constant.** Source default
   is 17 (`NativeChatPreferences.swift:44`), the token table says 14
   (`typography.body.baseSize`), and the PNG renders 14 (bubble one-line height
   37 pt + ink 31 px = 10.3 pt cap height). No single authoritative value exists.
   **Recommendation:** use the token's 14 for the Android default and expose the
   preference later; this is a 3 pt visual delta against the current iOS default.
10. **Chat bubble height derived from the PNG is stale.** `chat.queued-chat.png`
    bubble = 37 pt, which is 14 pt text + 20 padding; current source (17 pt text,
    10/16 padding) yields ≈40.3 pt. Source wins. Do not copy 37.
11. **Sessions page large title.** `darkfinal-sessions*.png` show a 会话 large
    title; current `SessionsPage.swift` declares no `navigationTitle`. Not
    encoded.
12. **Dynamic Type.** Every measurement is at `content_size=large` only. Fixed
    `.system(size:)` chrome does not scale; the system `List`, segmented control
    and switch do (the current page uses default rows), so AX sizes are
    unmeasured. Files' `@ScaledMetric` icon (24→) is the one scaling geometry.
13. **Official-web layout data.** The golden manifest has interaction rects only
    (PWA close 32×32, 继续 306×36, get-started close 28×28) — nothing for the
    drawer, search, composer or settings. Those numbers are not page chrome and
    were not used.
14. **Switch height 29.67** may include 1 antialiased row; nominal 29.5. The 63
    pt width is exact.
15. **SF Symbols glyph ink.** Source gives point sizes (e.g. `ellipsis` 20 pt,
    `chevron.right` 12 pt) but the glyph's inked box is font-dependent; only the
    6.33×11.33 settings chevron was measured from pixels.

---

## 4. Stale PNG / spec list

### 4.1 Page contracts

`python3 spec/ui/v1/tools/extract_ios_pages.py --check` reports **24 stale
contracts** (the lane brief said 23; it is 24 as of this run):

```
chat, runtime-details, chat-preferences, files, mcp-settings, mcp-editor,
model-provider-settings, native-agent-presets, native-automation,
native-configuration, native-device-connection, native-device-session,
native-plugin-inventory, native-settings-document, workspace-folders,
egress-allow-list, settings-about, native-shortcuts, pdsh-shell,
phone-permissions, session-artifacts, sessions, settings, web-search-settings
```

Three of them matter for this lane:

* **`settings.json`** — declares `source.lines: 615` and one 13-row flat list.
  Current `SettingsPage.swift` is **255 lines**, 5 tabs, ~20 rows across the five
  tabs. Not a line-count drift: a different page.
* **`chat.json`** — declares `source.lines: 2962`; current `ChatPage.swift` is
  **4469 lines**. The `renderedFrom` list predates the tool/subagent/plan
  surfaces.
* **`sessions.json`** — 708 vs 712 lines, but the checker still flags it; the
  rendered rows changed.

`files.json` is also flagged even though `FilesPage.swift` still has 487 lines
(the last commit changed 21 lines: colours + `@ScaledMetric`, geometry unchanged
at the default type size).

### 4.2 Baseline screenshots

`docs/receipts/ios-baseline-screens/*.png` — all 27 shots are from **2026-10-31
15:55Z**, i.e. before commit `f39acd0a` (2026-11-01 15:29), which rewrote chat
(+1900 lines), settings (+176), sessions (+54), files (+21), shell (+144) and
added the whole parity token file. They are **not** a current baseline. Concretely:

| shot family | why stale | what to use instead |
|---|---|---|
| `ios-settings*.png` (7) | flat 615-line page; current is 5-tab segmented | `screens/current/settings-chat.png` (15:38, after the rewrite) |
| `ios-chat-*.png` (8) | 44 pt header, **no** header hairline, 22 pt composer / 93.7 pt height, 17 pt body, 13.3/15 bubble padding | `screens/current/sample-chat.png`, `chat.queued-chat.png` (geometry matches current; body type is 14 there, see §3.9) |
| `ios-sessions-*.png` (7) | pre-rewrite sessions chrome | `screens/current/darkfinal-sessions*.png` for the list rows; drawer chrome still differs (§4.3) |
| `ios-settings-*` subpages | some pages no longer reachable from the 5-tab index | source per page |
| `ios-files.png`, `ios-workspace-folders.png`, `ios-shell.png` | same pre-rewrite build; Files geometry did not change | `screens/current/darkpass-files-light.png` |

`docs/receipts/ios-baseline-screens/VISUAL.md` is therefore **out of date** in
§1.1 (44 pt header), §1.4 (17 pt body, 13.3/15 bubble padding), §1.5 (93.7 pt
composer, 22 pt radius) and §2 (the whole flat Settings section).

### 4.3 The 2026-11-01 `screens/current/` set is *closer* but not entirely current

These were captured 12:41–15:38, i.e. mostly before the 15:29 commit. Their
*geometry* matches the committed source for chat/composer/permission cards (the
work was already in the tree), but three things differ:

* `darkfinal-drawer-light.png` shows a 会话 large title, a search field and
  **three** bottom rows (定时任务 / 工作文件夹 / 设置). Current `SessionsDrawer`
  renders **two** rows (定时任务 / 设置) and hides the navigation bar
  (`NativeShell.swift:291,297-303`). Drawer chrome is stale; the row interiors
  still match `SessionsPage`.
* `darkfinal-sessions*.png` show the 会话 large title that current
  `SessionsPage.swift` does not declare.
* `chat.queued-chat.png` renders 14 pt body text; current source default is 17
  (§3.9). Bubble padding/radius still match.

What *is* current in the chat shots was checked independently: `sample-chat.png`
permission card blue CTA is `x=90..1115, y=580..723 px` → **342 × 48 pt**, which
is exactly the current card (370 outer − 2×14 padding wide, 48 tall,
`ChatPage.swift:4447-4448`), and the header hairline is at the 50 pt offset. So
the chat geometry is trustworthy even though the set predates the commit.

Only `settings-chat.png` and `settings.permissions.tab-chat.png` (15:38) postdate
the settings rewrite and are safely current.

---

## 5. What landed

All new files are declaration sites; no page imports them yet, so pages keep
compiling and the token gate is unaffected.

| file | contents |
|---|---|
| `android/lib/src/main/kotlin/com/phonedsh/ui/ChatMetrics.kt` | header, transcript, bubble, composer, queue, permission/tool/code cards, todo/question/plan |
| `android/lib/src/main/kotlin/com/phonedsh/ui/SessionsMetrics.kt` | drawer column, search, rows, separators, CTA, toast |
| `android/lib/src/main/kotlin/com/phonedsh/ui/SettingsMetrics.kt` | nav bar, segmented picker, grouped cards, row/separator, switch, chevrons |
| `android/lib/src/main/kotlin/com/phonedsh/ui/ShellFilesMetrics.kt` | shell header, drawer furniture row, Files title/search/rows/empty state |

`UiMetrics.kt` was **not** modified: it keeps its five official-web values and
the viewport. Each family object states, where it overlaps `UiMetrics`, which
surface it belongs to (the header 50 vs 44 is the clearest example).

### Gate status

```
./gradlew :lib:compileDebugKotlin                       -> BUILD SUCCESSFUL
./gradlew :lib:testDebugUnitTest \
  --tests "com.phonedsh.ui.page.PageTokenReferenceTest"  -> BUILD SUCCESSFUL (6 tests, 0 failures)
```

The first test run hit a transient Gradle race with a concurrent build on the
shared `lib/build/test-results` directory ("unreadable inputs or outputs"); the
XML written by that run already showed 6/6 passing
(`lib/build/test-results/testDebugUnitTest/TEST-com.phonedsh.ui.page.PageTokenReferenceTest.xml`),
and the clean re-run succeeded. No page file was touched, so the inventory
equality / bare-length / insets assertions are untouched.

---

## 6. Spec gaps (tokens.json is read-only — reported, not edited)

The token table cannot express the pages it is supposed to drive. Recommended
additions, in the table's own shape (`unit: pt`, `scalesWith: null`):

| proposed token | value | source |
|---|---|---|
| `geometry.sessionSearchHeight` / `sessionSearchRadius` | 44 / 22 | PNG, this report §2.1 |
| `geometry.drawerWidth` / `drawerContentWidth` | 320 / 288 | `NativeShell.swift:97`, `SessionsPage.swift:594` |
| `geometry.sessionRowHeight` | 56 | `SessionsPage.swift:580` |
| `geometry.pageActionRowHeight` | 44 | `SessionsPage.swift:164,439` |
| `geometry.ctaHeight` / `radius.cta` | 50 / 12 | `SessionsPage.swift:223-225` |
| `geometry.settingsGroupedRowHeight` (new kind) | 52.33 | PNG, §2.2 |
| `geometry.settingsGroupedCardRadius` | 26 | PNG, §2.2 |
| `geometry.settingsSwitchWidth` / `Height` | 63 / 29.67 | PNG, §2.2 |
| `geometry.chevronSlot` | 20.67 | PNG, §2.2 |

Three **existing token values are stale against the current source** and should
be corrected (not fixed here, `spec/**` is read-only):

| token | now | current source | source |
|---|---|---|---|
| `radius.bubble` | 22 | **20** | `NativeParityTokens.swift:115` + `ChatPage.swift:3741` |
| `radius.composer` | 22 | **28** | `NativeParityTokens.swift:116` + `ChatPage.swift:1884` |
| `geometry.bubbleMaxWidth` | 296 | **277** | `NativeParityTokens.swift:98` |

(`typography.body.baseSize: 14` is not wrong — it is the official-web baseline —
but the iOS app renders 17 by default; see §3.9.)

---

## 7. Open questions

1. **Sessions drawer: search or no search?** iOS currently hides it; the Android
   design (L2) expects one. If kept, it is a deliberate divergence from current
   iOS; if dropped, the "search 40/20" requirement disappears. This needs a
   product call, not more measurement.
2. **Which Settings design ships on Android?** The current iOS page is the 5-tab
   segmented page; L3's `SettingsPage.kt` (as of this writing) still mirrors the
   removed 13-row flat index. The metrics in `SettingsMetrics.kt` describe the
   current page. If L3 keeps the flat index, those numbers do not apply — and
   the old numbers must stay labelled legacy.
3. **A fresh capture of the current drawer + a populated Files page** would close
   the two remaining measurement holes (inter-row spacing, file-row height).
   Neither is on disk today.
4. **Body type 14 vs 17**: should Android follow the token (14) or the iOS
   preference default (17)? This affects every chat row height, not just text.
5. **`official` golden as a metric source**: it has no layout table. If the
   official web is the parity target for Android, someone should add measured
   rects to `manifest.json` (drawer, composer, settings) — currently the manifest
   only proves the viewport.
