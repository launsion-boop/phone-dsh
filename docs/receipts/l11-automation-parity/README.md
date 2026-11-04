# L11 — `NativeAutomationPage` (定时任务 / `page-sessions-schedules`) aligned to iOS

Owner: L11 (automation lane). State: `page-sessions-schedules`.
Target: `examples/probe-app/PhoneDSHProbe/NativeAutomationPage.swift` (read-only), baseline
`docs/receipts/ios-baseline-screens/ios-sessions-schedules.png` (reference only: it predates
`f39acd0a` and L7 is re-shooting it; every number below that matters was re-derived from the
Swift source and re-measured on the PNG).

## What was broken

Two independent defects, not one:

1. **The state layer erased the content.** `AutomationScreenState.from` made a read failure a
   *content* state (`AutomationStatus.FAILED`, "a failed read proves nothing"): it dropped the
   reported catalog, so an empty-but-failed read rendered one grey sentence instead of the empty
   block + CTA + error section. On iOS `error` is a field *beside* `scheduleRecords`
   (`DSHManagementModel.swift:120,137`, set in the same read at `:702-717`): the catalog stays and
   a red section is added under it. The captured state (`page-sessions-schedules`) is exactly that
   pair — an empty catalog **and** a failed read — so the Android capture could never match.
2. **The view was a different page.** A 17 pt `PageFrame` header with two right-hand text actions,
   a centred `EmptyHint` and a plain text action instead of the 34 pt large title, the leading
   ✕/刷新 + trailing 新建 bar, the 50 pt CTA and the 需要处理 section.

Both are fixed: the state layer now separates "what the snapshot says" from "what the last read
reported", and the view is rebuilt to the iOS structure.

## iOS structure, element by element (read from the Swift source)

`NativeAutomationPage.body` (`NativeAutomationPage.swift:16-110`) is one `List` under a bar and a
large title:

| # | element | source | notes |
|---|---|---|---|
| 1 | 34 pt large title 定时任务 | `:76` `.navigationTitle("定时任务")` | 17 pt leading inset, 14 pt below the 44 pt bar |
| 2 | ✕ close (leading) | presentation wrapper | the sheet's dismiss, drawn as a glass pill |
| 3 | 刷新 (leading) | `:78-81` `ToolbarItem(.topBarLeading)` + `arrow.clockwise` | accessibility label 刷新自动化任务 |
| 4 | 新建 (trailing) | `:82-88` `ToolbarItem(.topBarTrailing)` | accent semibold; disabled when there is no current session |
| 5 | empty block | `:18-44` `if management.scheduleRecords.isEmpty` | `VStack(spacing: 8)`, `.padding(.vertical, 24)` |
| 5a | 还没有定时任务 | `:20-22` | 17 pt semibold (= `.body.weight(.semibold)`), primary ink, centred |
| 5b | 到点让它自己跑,结果回到原会话。 | `:23-26` | `.footnote` = 13 pt, secondary ink, centred |
| 5c | 新建任务 CTA | `:27-38` | `maxWidth: .infinity`, `minHeight: 50` (`@ScaledMetric`, `:14`), radius 12, `accentFill`, white 17/600, `.padding(.horizontal, 16)`, `.padding(.top, 8)` |
| 6 | schedule rows (non-empty branch) | `:46-67` | title + 活动/已停止, prompt (`.subheadline`, 2 lines), `"\(sessionTitle) · \(detail)"` |
| 7 | 需要处理 section | `:69-71` `if let error = management.error` | `Section("需要处理") { Text(error).font(.footnote).foregroundStyle(.red) }` |
| 8 | pull-to-refresh | `:90` `.refreshable` | no in-content retry control anywhere on the page |

Not on this page but on its children: `ScheduleDetailPage` 提醒 / 投递记录 / 错误 (`:129,136,150`),
`ScheduleHistoryPage` 投递记录 + 错误 (`:205,203`), `ScheduleEditorPage` (a host sheet, `:212`).

## What changed

* `android/lib/src/main/kotlin/com/phonedsh/ui/page/NativeAutomationPage.kt`
  * **state**: `AutomationStatus` is `READY | EMPTY | UNKNOWN` (the `FAILED` member is gone — a
    failure is not a content outcome); `failure` is copied through in every branch and renders as a
    section; `isFailed` became `hasFailure`; `signature()` now carries the failure flag.
  * **view**: `AutomationFrame` (44 pt bar + 34 pt `SettingsLargeTitle` + content box; the same
    pieces as `SettingsSubPageFrame`, spelled in this file because the leading slot holds two
    controls), leading ✕ + 刷新, trailing 新建, the empty block (17/600 title, 13 pt hint, 50 pt
    CTA at radius 12 / `ctaOverride`), the 需要处理 section with the host's sentence in
    `colors.danger`, and the child routes' inline 定时任务 / 投递记录 titles with their own 错误
    sections. The rows' prompt moved to `subheadline` (15) and their meta line to
    `会话 · 规则 · 下次计划`, which is what iOS composes out of `detail`.
  * `onRetry` / `onDismissFailure` were removed: iOS has neither, the bar's 刷新 is the retry, and
    no call site passed them.
* `android/lib/src/main/kotlin/com/phonedsh/ui/UiStrings.kt` — three labels appended to the
  existing `AUTOMATION_*` block: `AUTOMATION_NEW_SHORT` 新建 (`:83`), `AUTOMATION_ATTENTION`
  需要处理 (`:70`), `AUTOMATION_ERROR` 错误 (`:150,203`).
* `android/lib/src/main/kotlin/com/phonedsh/ui/page/UiPageTags.kt` — three tags appended:
  `AUTOMATION_BACK`, `AUTOMATION_CTA`, `AUTOMATION_ATTENTION`.
* `android/lib/src/test/kotlin/com/phonedsh/ui/page/NativeAutomationPageTest.kt` — 10 tests on the
  new contract, including the regression the capture proves: *a failed read adds the section and
  keeps the empty block and the CTA*.
* `android/lib/src/androidTest/.../SessionsParityScreenshotTest.kt` — the capture now wires
  `onRefresh` / `onNewSchedule` (the page draws those controls from host callbacks, and iOS renders
  both).
* `android/lib/src/androidTest/.../ParityStates.kt` — the state's note and owner (no longer
  "not owned by this lane, reports the gap").

Not changed: `spec/**`, `Sources/**`, `examples/**`, `PdshNavHost.kt`, `ChatPage.kt`,
`SessionsPage.kt`, `SettingsPage.kt`, `FilesPage.kt`, `PDSHShellPage.kt`, the three device pages,
`UiMetrics.kt`, `*Metrics.kt`, `SettingsChrome.kt`. Every length comes from an existing token or an
L6 metric — the page file contains no `dp`/`sp` literal (asserted by
`PageTokenReferenceTest`).

## Structure table — `page-sessions-schedules`

Element by element, iOS vs the Android page *after* this change.

| element | iOS | Android before | Android now | position |
|---|---|---|---|---|
| 34 pt large title 定时任务 | yes (`:76`) | no (17 pt header) | **yes** (`SettingsLargeTitle`) | 17 pt inset, 14 pt under the bar |
| ✕ close / back | yes | yes (‹ chevron) | **yes** (✕, `SETTINGS_CLOSE_GLYPH`) | leading, 16 pt inset |
| 刷新 | yes, leading, icon | no | **yes, leading, word** | beside the ✕ (iOS: same slot) |
| 新建 | yes, trailing, accent | yes, but trailing *before* 刷新 and 13 pt | **yes, trailing, 17 pt accent** | trailing, 16 pt inset |
| empty block | yes | yes (centred `EmptyHint`, 13 pt) | **yes** | 24 pt above/below |
| empty title 17/600 | yes | 13 pt tertiary | **yes** (`type.headline`, primary) | centred |
| empty hint 13 pt secondary | yes | 13 pt tertiary | **yes** (`type.secondary`, secondary) | centred |
| 50 pt CTA, radius 12, `#2F5BFF` | yes | no (plain text action) | **yes** | x 32.0–370.0, y = measured |
| 需要处理 header | yes | no | **yes** (17 pt, 33 pt inset) | below the block |
| red error sentence | yes (13 pt red) | yes, but grey 13 pt tertiary and *replacing* the content | **yes** (13 pt `danger`, host sentence verbatim) | below the header, 33 pt inset |
| rows with 活动/已停止 + prompt + 会话·规则·下次计划 | yes | partial (13 pt prompt, meta without rule) | **yes** | n/a in this state |
| in-content retry / dismiss | no | yes (two rows) | **no** (removed; 刷新 is the retry) | — |
| Android-only read-only note | no | yes (catalog + detail) | catalog: **no**; detail: **kept** (Android has no schedule-write command) | — |
| `.refreshable` pull-to-refresh | yes | no | no (no pull-to-refresh anywhere in the Android shell) | — |
| swipe 编辑 / 删除 | yes | no | no (编辑 lives on the detail page) | — |

## Quantified residuals

Frame: 1206 × 2622 px @3 = 402 × 874 pt on both sides (`android/lib/.../ui/UiMetrics.kt`
`BASELINE_*`; the iOS PNG is the same frame). The Android capture has the system bars hidden, so the
iOS status bar (62 pt) is the origin offset: **iOS y values below are `y − 62`**, i.e. both columns
start at the bar's top edge. Ink bands, `pt = px / 3`.

| element | iOS (rel) y | h | Android y | h | Δy top | iOS x | Android x | Δx0 |
|---|---|---|---|---|---|---|---|---|
| bar (✕ / 刷新 / 新建) | 10.7–33.7 | 23.0 | 14.7–31.0 | 16.3 | +4.0 | 17.3–368.7 | 23.0–379.3 | +5.7 |
| 34 pt large title | 63.3–93.7 | 30.3 | 67.7–100.3 | 32.7 | +4.3 | 17.0–143.0 | 18.0–152.0 | +1.0 |
| 还没有定时任务 | 132.7–148.0 | 15.3 | 136.0–152.3 | 16.3 | +3.3 | 143.0–259.0 | 142.0–260.0 | −1.0 |
| hint | 160.3–173.0 | 12.7 | 167.7–180.3 | 12.7 | +7.3 | 103.0–291.7 | 97.7–296.7 | −5.3 |
| CTA 新建任务 | 190.0–240.0 | **50.0** | 198.3–248.3 | **50.0** | +8.3 | 32.0–370.0 | 32.0–370.0 | **0.0** |
| 需要处理 header | 294.3–309.7 | 15.3 | 303.7–319.7 | 16.0 | +9.3 | 33.0–98.3 | 34.0–100.3 | +1.0 |
| error line 1 | 339.7–351.7 | 12.0 | 349.3–361.7 | 12.3 | +9.7 | 32.7–258.3 | 33.3–245.7 | +0.7 |
| error line 2 | 357.7–369.7 | 12.0 | 364.0–377.3 | 13.3 | +6.3 | 33.3–238.0 | 33.7–227.7 | +0.3 |

Gaps (the honest way to read the cumulative drift):

| gap | iOS | Android | Δ |
|---|---|---|---|
| bar ink centre → title ink top | 41.3 | 45.0 | +3.7 |
| title ink bottom → empty title top | 39.3 | 36.0 | −3.3 |
| empty title ink bottom → hint top | 12.7 | 15.7 | +3.0 |
| hint ink bottom → CTA top | 17.3 | 18.3 | +1.0 |
| CTA bottom → 需要处理 ink top | 54.7 | 55.7 | +1.0 |
| 需要处理 ink bottom → error ink top | 30.3 | 30.0 | −0.3 |

Largest residual: **+9.7 pt** (the last red line, out of 874). It is the sum of six ≤3.7 pt gaps and
comes from text metrics, not layout numbers: Compose's `PlatformTextStyle` line box puts the 34 pt
ink 4.3 pt lower than CoreText, and the 17 pt CJK ink is 1 pt taller. The two boxes that were wrong
when the first capture ran are exact now: the CTA spans **32.0–370.0 pt on both sides** and its
height is **50.0 pt on both sides**.

### Known deltas that are not geometry

| item | iOS | Android | why |
|---|---|---|---|
| CTA fill | `(47,91,255)` `#2F5BFF` | `(47,91,255)` | identical (`colors.ctaOverride`) |
| hint ink | `(102,102,107)` | `(102,102,107)` | identical (`colors.secondary`) |
| title / body ink | `(0,0,0)` | `(17,17,20)` `#111114` | `colors.primary`; iOS draws a system colour |
| 需要处理 ink | `(138,138,142)` = system `secondaryLabel` (60 % of `#3C3C43` on white) | `(102,102,107)` `#66666B` | there is no static token for a dynamic system label; the page uses `SettingsSectionLabel`'s ink, which is the same choice the six settings sub-pages made |
| error ink | `(255,56,60)` = system `red` | `(192,57,43)` `#C0392B` | `colors.danger` (the repo's red, contrast-based) |
| hint copy | `到点让它自己跑,结果回到原会话。` (half-width comma) | `到点让它自己跑，结果回到原会话。` (full-width) | pre-existing `UiStrings.AUTOMATION_EMPTY_HINT`; not rewritten by this lane |
| 刷新 | `arrow.clockwise` icon in a glass pill | the word 刷新 | this page has no icon set; the ✕ is `SettingsCloseGlyph`'s word form too. Same slot, same label |
| bar padding | glass capsules (16 pt) | text + 6 pt padding | 新建 ink ends at 379.3 vs 368.7 (+10.6) |
| status bar | visible (62 pt) | hidden by the capture harness | profile-level, not a page difference |

## Provenance

Built and captured from a **snapshot**, because `:app` is red on the L8 `SettingsPage.kt` rewrite
and several other lanes' files are mid-write in the shared tree:

```
HEAD (86a39aac) + this snapshot's tree
     minus every untracked file that does not compile yet
     (android/lib/src/test/.../nav/PdshDrawerTest.kt, PdshReachabilityTest.kt,
      page/DeviceConnectionWiringTest.kt, DeviceConnectorPagesTest.kt, DeviceSessionPagingTest.kt)
     plus android/lib/src/test/.../theme/TokenReferenceTest.kt refreshed from the working tree
     (the snapshot's copy still expected radius.bubble = 22; L9 re-based it to 20, and tokens.json
      already said 20 — a snapshot skew, not a defect)
```

* snapshot: `/tmp/l11-snap` (`rsync` of the working tree, `build/`, `.gradle/`, `.kotlin/` and
  `examples/` excluded, plus `examples/probe-app/Bundle/worker`, which `:app`'s configuration needs)
* the files this lane changed were copied into the snapshot byte-for-byte from the working tree
* `:lib` unit tests run in the snapshot; nothing was committed and no git write was run
* emulator: dedicated AVD `l11-auto` (`system-images;android-35;google_apis;arm64-v8a`),
  serial `emulator-5626`, `-no-window`, deleted after the run

Later lanes should re-run the capture from a clean tree once `:app` compiles; the page itself needs
no change for that.

## Gates

| gate | result |
|---|---|
| `:lib:testDebugUnitTest` (whole module, 479 tests) | PASS (snapshot, see provenance) |
| `NativeAutomationPageTest` (10 tests, incl. the failure-keeps-content regression) | PASS |
| `PageTokenReferenceTest` (token inventory equal to the source, no `dp`/`sp`/colour literal, insets consumed, SPDX) | PASS |
| `structure_check.py` (11 checks) | 10 PASS, 1 FAIL: `absolute-paths` names `android/tools/README.md:224` — another lane's doc, untouched by this change |
| instrumented capture `SessionsParityScreenshotTest#pageSessionsSchedules` on `emulator-5626` | `OK (1 test)`, `metrics.txt` records `profile=ios-parity width=1206 height=2622 dpi=480` |
| parity registry (`parity-registry.txt`, 27 states) | 27 rows, 0 malformed, every iOS file named, `page-sessions-schedules` owner now `Automation lane (L11)` |

## Files

* `page-sessions-schedules.png` — the Android capture, 1206 × 2622 @3 (device `emulator-5626`)
* `side-by-side-schedules.png` — iOS left, Android right, Android top-padded **186 px = 62 pt** so
  both columns share the bar's top edge (L2's composite in `docs/receipts/sessions-parity/` padded
  59 pt; 62 is the measured safe-area top of the iOS frame, `bar ink centre 84 pt − 22 pt`)
* `metrics.txt`, `parity-registry.txt` — the harness receipts for that capture

Supersedes, but does **not** overwrite (another lane's files):

* `docs/receipts/sessions-parity/page-sessions-schedules.png` — still the pre-alignment page
* `docs/receipts/sessions-parity/side-by-side-schedules.png` — same
* `docs/receipts/sessions-parity/measurements.md` § schedules — its Android column has 4 ink bands
  for the old page; the table above is the replacement, and it should also drop the
  "search field's placeholder" anchor, which does not exist on this page.
