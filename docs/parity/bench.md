# Cross-platform parity bench v0 (element geometry)

Status: v0, 2026-11-12. Owner: parity bench. This is the first bench that
compares the **real iOS app** with the **real Compose pages**. It does not
replace the screenshots in `docs/receipts/ui-parity-sheet/`; it replaces the
hand-authored Android `ScreenState` samples as the source of layout evidence.

Current v0 receipt on this host (bench-host capture-frame fix, 2026-11-12):

| command | result |
|---|---|
| `python3 -m unittest discover -s scripts/parity -p 'test_*.py'` | **PASS** (23 tests) |
| `bash android/tools/with-android-toolchain.sh ./gradlew :lib:testDebugUnitTest --tests '*ParityGeometryExportTest*' --no-daemon` | **PASS** (6 tests: the four exports plus the two host-frame regressions, three exports written) |
| iOS `bash scripts/parity/run_ios_export.sh` | **FAIL (environment blocker)** — `xcodebuild test` exits 74 because this sandbox cannot allocate a pty; no Swift build failure was reached. The comparison reuses the iOS export written by the last successful host run on 2026-11-11T15:12Z (same iPhone 17 Pro, 402 x 874 pt), recovered from that simulator's container. |
| `python3 scripts/parity/compare_geometry.py ...` | **chat-empty PASS 5/5**; `session-drawer-open` FAIL 2/3 (the `drawer.scroll` exemption applies; `chat.header.drawer` still +62); `settings-root` FAIL 0/6 (row height and settings chrome, not the host frame). Per-fixture before/after deltas are recorded in the host-frame section below. A report is only `PASS` when both export files describe the same fixture, unit and origin. |

What the bench compares:

| compared | how |
|---|---|
| element presence | the fixture's element ids must exist on both sides |
| frame | `x`, `y`, `w`, `h` in points (iOS) / dp (Android), from the accessibility tree and Compose semantics |
| text | the accessible label/value where both sides expose one (informational; copy is not a geometry gate) |
| line count | Compose `TextLayoutResult.lineCount` vs the iOS export's `null` (see limitations) |
| wrap points | Compose line start offsets vs the iOS export's `null` |

What it does **not** compare: pixels, colours, glyph rasterisation, animation
timing, or the rendered shape of a platform control. CoreText and
Android's Minikin/HarfBuzz rasterise the same string differently; a pixel diff
would measure that difference, not layout. The spec's tolerance principle is
`spec/ui/v1/README.md` §5.1: layout assertions use measured geometry, never a
computed text height.

## Files

```
scripts/parity/
  fixtures/
    chat-empty.json
    session-drawer-open.json
    settings-root.json
  compare_geometry.py
  test_compare_geometry.py
  run_ios_export.sh
android/lib/src/test/kotlin/com/phonedsh/ui/parity/ParityGeometryExportTest.kt
examples/probe-app/PhoneDSHDeviceUITests/ParityGeometryExportUITests.swift
```

## Fixture format v0

One JSON object per screen/state under `scripts/parity/fixtures/`. The same file
drives both exporters; the per-platform selectors are addresses, not a second
state. The schema is versioned by `"schema": "pdsh.parity.fixture.v0"`.

```json
{
  "schema": "pdsh.parity.fixture.v0",
  "id": "chat-empty",
  "page": "chat",
  "description": "The real chat page with no transcript rows; the engine has not started.",
  "unit": "pt",
  "frame": {"widthPt": 402, "heightPt": 874},
  "origin": "chat.header.title",
  "seed": {
    "android": {"screen": "chat"},
    "ios": {"launchArguments": [], "launchEnvironment": {}}
  },
  "actions": [
    {"action": "tap", "element": "chat.header.drawer"},
    {"action": "wait", "element": "drawer.new-session", "timeoutMillis": 10000}
  ],
  "elements": [
    {
      "id": "chat.header.drawer",
      "android": {"testTag": "pdsh.chat.header.drawer"},
      "ios": {"identifier": "chat.header.drawer", "type": "button"},
      "text": false,
      "tolerance": 1.0
    },
    {
      "id": "drawer.scroll",
      "android": {"testTag": "home.drawer.scroll"},
      "ios": {"identifier": "drawer.scroll", "type": "scrollView"},
      "tolerance": 1.0,
      "gatedAxes": ["x", "w", "h"],
      "exemption": "spec/ui/v1 README §5 insets"
    }
  ]
}
```

| field | meaning |
|---|---|
| `id` | fixture name; also the export/report file stem |
| `page` | page/screen id from `spec/ui/v1/pages/*.json` or `sessions-drawer` for the overlay |
| `frame` | the shared logical viewport. Both sides run at 402 x 874 pt so no rescale is involved |
| `origin` | the element id whose top-left becomes `(0,0)` in the exported `frame`. `absoluteFrame` is kept in the export for debugging but is not gated |
| `seed.android.screen` | the real composed screen the JVM harness mounts: `chat` or `settings` |
| `seed.ios.launchArguments` / `launchEnvironment` | the app's existing `-uiPreview` and `PDSH_*` seed mechanisms |
| `actions` | ordered script: `tap`, `type`, `long_press`, `wait`; each names an element id |
| `elements[].android.testTag` | the Compose semantics tag (`UiTags` / `UiPageTags` / `HomeDrawerTags`) |
| `elements[].ios.identifier` | the stable accessibility identifier; all v0 fixtures now use this |
| `elements[].ios.label` | legacy accessibility-label fallback; no v0 fixture uses it since the 2026-11-12 identifier pass |
| `elements[].ios.first` | legacy positional fallback (`scrollView`, `textView`); no v0 fixture uses it since the 2026-11-12 identifier pass |
| `elements[].text` | export the accessible text and, on Android, the Compose text layout |
| `elements[].tolerance` | scalar or `{x,y,w,h}` override in pt; default is 1 pt |
| `elements[].gatedAxes` | optional subset of `x,y,w,h` that is gated. This is only for a spec §5 whitelisted platform difference, and the element must carry an `exemption` naming it |
| `elements[].exemption` | the whitelist row / reason printed in the report for every skipped axis |

`gatedAxes` is not a general escape hatch. If an axis is omitted only because
the two apps disagree, that is a **FAIL**; fix the page or file a GAP. The v0
fixtures use it in exactly one place: the drawer's scroll container, because
`spec/ui/v1/README.md` §5 `insets` lets the iOS drawer consume a status-band
inset inside its content while the Robolectric capture has no system bars. The
`Δy` is still printed in the report.

### Element identity

The canonical id is the fixture's `id`. Each exporter records how it resolved
that id (`testTag`, `accessibilityIdentifier`, `label`, `application`, or
`first:<type>`), and the comparator warns when the two sides used different
identity kinds. On 2026-11-12 the iOS elements gained the exact fixture ids as
`accessibilityIdentifier`s, so every v0 element now resolves as
`accessibilityIdentifier` on iOS and `testTag` on Android; the remaining
identity warning is the expected platform-kind difference, not a missing hook.
The identifiers are additive and do not change any accessibility label.

The P09 page contracts under `spec/ui/v1/pages/**` do not name identifiers for
these elements (only `vision.save` is named anywhere in that directory), so the
fixture ids were used. The Android tags are addresses, not the fixture ids
verbatim: `chat.header.drawer`, `chat.empty.start` and `settings.done` carry the
`pdsh.` namespace; the composer uses `pdsh.composer.field` /
`pdsh.composer.send`; the drawer uses `home.drawer.new-session` /
`home.drawer.scroll`; and the settings rows use
`pdsh.settings.index.row.<row>`. The Android side was not renamed.

## Android exporter (JVM / Robolectric)

Why JVM and not instrumented: the pages are pure composables whose ScreenState
comes from the fixture, `:lib` already runs Compose interaction tests on
Robolectric, and geometry comes from the same Compose semantics tree an
instrumented test would read. Robolectric's known limitation is fake glyph
metrics; this bench never measures glyphs or line heights, only semantics
frames and `TextLayoutResult.lineCount`. There is therefore no instrumented
exporter in v0.

```bash
bash android/tools/with-android-toolchain.sh \
  ./gradlew :lib:testDebugUnitTest --tests '*parity*' --no-daemon
```

The test is `ParityGeometryExportTest`. It reads the fixtures from
`pdsh.repo.root` (already supplied by `:lib`'s Gradle config), drives the real
`ChatPage` / `HomeDrawer` / `SettingsPage` with the fixture's seed and action
script, and writes:

```
build/parity/android/chat-empty.json
build/parity/android/session-drawer-open.json
build/parity/android/settings-root.json
```

Override the output directory with `PDSH_PARITY_OUT=<dir>`. The exporter reports
missing nodes (`found: false`) instead of failing the whole run, so the
comparator can name the missing element on one side. It does not invent a line
count: a node without `GetTextLayoutResult` exports `lines: null`.

The capture frame reserves **one** measured iOS status band in total
(`SettingsMetrics.PARITY_SAFE_AREA_TOP_PT` = 62 pt): the page keeps its own
production `statusBarsPadding()` (56 dp under Robolectric) and the frame adds
only the missing 6 pt. It also mounts the real shell `HomeTabBar` (50 pt) and
the measured 34 pt home-indicator area below it, so the page ends at the same
y as the iOS tab page. The settings fixture uses iOS's full-screen
`-uiPreview settings` cover instead, so it keeps the status band but has no tab
bar. These are capture conditions, not page insets: on a device the page gets
the band from the platform and the host supplies the tab bar. See the
bench-host fix section below for the measured before/after.

## iOS exporter (XCUITest)

The test is
`examples/probe-app/PhoneDSHDeviceUITests/ParityGeometryExportUITests.swift`.
`project.yml`'s `PhoneDSHDeviceUITests` target already uses the whole directory
as its sources, so no project.yml edit is needed; `xcodegen generate` picks the
new file up.

```bash
bash scripts/parity/run_ios_export.sh
# or, explicitly:
xcrun simctl boot <UDID> || true
xcrun simctl bootstatus <UDID> -b
(cd examples/probe-app && xcodegen generate)
TEST_RUNNER_PDSH_PARITY_FIXTURES_JSON="$(python3 - <<'PY'
import json, pathlib
print(json.dumps([json.loads(p.read_text()) for p in sorted(pathlib.Path('scripts/parity/fixtures').glob('*.json'))], ensure_ascii=False, separators=(',', ':')))
PY
)" xcodebuild test \
  -project examples/probe-app/PhoneDSHProbe.xcodeproj \
  -scheme PhoneDSHDeviceUI \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:PhoneDSHDeviceUITests/ParityGeometryExportUITests/testExportAllParityFixtures \
  -derivedDataPath /tmp/pdsh-parity-derived \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
```

The host passes the fixture JSON in `TEST_RUNNER_PDSH_PARITY_FIXTURES_JSON`
because the simulator cannot read the repository checkout. The test prints
`PDSH_PARITY_IOS_OUT=<simulator path>`; `run_ios_export.sh` copies the JSON into
`build/parity/ios/`. Run it on an iPhone simulator whose logical viewport is
402 x 874 pt (the same frame as the iOS baselines). A different device is a
different frame; the comparator does not rescale.

If `xcodebuild`, `xcodegen`, or an available simulator is missing, the exact
blocker is printed and the run is **NOT_RUN**, never PASS.

## Comparator

```bash
python3 scripts/parity/compare_geometry.py \
  --android build/parity/android/chat-empty.json \
  --ios build/parity/ios/chat-empty.json \
  --out-dir build/parity/reports
```

It matches elements by fixture id, prints `Δx/Δy/Δw/Δh`, compares line counts
and wrap points when both sides expose them, and writes
`build/parity/reports/<fixture>.md` plus `.json`. Exit status is 0 only on
`PASS`, 1 on a geometry/line/wrap failure, 2 on malformed input (missing file,
fixture/unit/origin mismatch).

Tolerance:

* default **1 pt per axis**;
* `elements[].tolerance` may be a number or `{x,y,w,h}`;
* an element only gates the axes in `gatedAxes`; skipped axes are still printed;
* missing element, `found: false`, frame delta above tolerance, line-count
  mismatch or wrap-point mismatch FAIL;
* a side that exposes no line layout (`lines: null`) is reported, not guessed.
  v0 iOS always reports `null`: XCUITest exposes no text layout object.

The unit tests are synthetic and run without either app:

```bash
python3 -m unittest discover -s scripts/parity -p 'test_*.py'
```

## Tolerances and known platform whitelists

The only differences this bench treats as expected are the ones already in
`spec/ui/v1/README.md` §5:

| whitelist id | where it appears in v0 |
|---|---|
| `insets` | the drawer's scroll container is measured on `x/w/h`; iOS puts its status band inside the scroll content. The report prints the `Δy` and the exemption |
| `font-scale` | not exercised; both sides run at the default scale. If a future fixture changes it, compare base size and use the §5.1 ±2sp rule, never a rendered-pixel equality |
| `cjk-fallback` | the line count / wrap-point comparison is the machine-checkable half of this row; glyph shapes are out of scope |
| `back-gesture`, `ime`, `scroll-refresh`, `fgs-notification`, `share-sheet` | not measured by v0 (no interaction/timing assertions) |

No other platform difference is whitelisted. A different x/width/height in a
gated axis is a finding, not a tolerance to widen.

## v0 coverage and limitations

Fixtures:

* `chat-empty` — chat header, empty-state CTA, composer field and send key.
* `session-drawer-open` — the drawer is opened by the real chat-header button;
  exports the new-session capsule and the drawer scroll container.
* `settings-root` — the settings sheet root; exports 完成 and the first two
  groups' link rows.

Known gaps, tracked outside this bench:

* XCUITest exposes no text layout, so iOS `lines` / `wrapPoints` are `null` in
  v0. The comparator's line-count contract is unit-tested with synthetic
  inputs and is ready for an app-side debug export.
* The drawer fixture cannot yet export folder/session rows: their ids are
  host-state dependent and the two apps seed different drawer contents.
* Android `SettingsPage` rows are `LazyColumn` items. A row below the fold is
  not composed, so the fixture only names rows visible at 402 x 874.
* This is **not** a nightly gate yet. There is no committed CI job that builds
  both apps; the commands above are the reproducible v0 entry points.

## Needed outside my scope

The stable iOS identifiers that this section used to list are now implemented:
`chat.header.drawer`, `chat.empty.start`, `chat.composer.field`,
`chat.composer.send`, `drawer.new-session`, `drawer.scroll`, `settings.done`
and the five `settings.row.*` ids carry the exact fixture ids. They were added
as identifier modifiers only in `ChatPage.swift` (including the UIKit composer
text view), `HomeDrawer.swift` and `SettingsPage.swift`; labels, layout and
modifier order are unchanged. The fixtures no longer use `label` or `first`,
and the P09 page contracts named no identifiers for these elements.

Remaining outside this bench's owned files:

* **`HomeDrawer`'s dialog window.** The drawer's `new-session` row needs the
  62 pt status band, but its `Dialog` window reports no status-bar inset under
  Robolectric. A host-supplied top inset (or an instrumented exporter) is
  needed before `chat.header.drawer` can pass in `session-drawer-open`.
* **Settings row chrome.** `SettingsPage` rows are 48 pt on Android vs 62 pt on
  iOS, and `settings.done` exposes a different semantics frame. That belongs to
  the settings page/chrome owners, not this capture host.
* **Both sides, text layout.** XCUITest exposes no line count or wrap points. A
  debug-only accessibility value (or an XCUITest-visible test surface) carrying
  `TextLayoutResult`'s `lineCount` and line start offsets is needed before the
  comparator can gate iOS line counts. Until then the report records
  `null` / "not exposed", never a guessed height.
* **Build input registration.** `:lib:testDebugUnitTest` does not declare
  `scripts/parity/fixtures/**` as an input, so editing a fixture alone leaves
  the Android test `UP-TO-DATE`. Run with `--rerun-tasks` (as the v0 receipt
  does) or register the fixture directory as a Gradle test input; the latter is
  in `android/lib/build.gradle.kts`, outside this bench's owned files.

No `examples/probe-app/project.yml` change is needed: the
`PhoneDSHDeviceUITests` target already uses the whole directory as its sources.

## Build blocker resolved (2026-11-12)

At the previous revision `xcodebuild build-for-testing -scheme
PhoneDSHDeviceUI` failed with three "unable to type-check this expression in
reasonable time" errors:

```
PhoneDSHProbe/ChatPage.swift:375:16
PhoneDSHProbe/DSHManagementModel.swift:1442:9
PhoneDSHVenus/IPhoneAgent.swift:49:13
```

Raising `-Xfrontend -solver-expression-time-threshold` (120, 600, then 60000)
did not change the result. The expressions were split without changing
behaviour, layout, strings, modifier order or accessibility:

* `ChatPage.swift` — the body's root `VStack` and its ~50-modifier chain became
  small typed stages: the two conditional regions are `pcStatusStrips` and
  `failureBanners` (`@ViewBuilder`), the stack is `pageStack`, and the modifier
  chain is ordered across `pageChrome`, `pageSheets`, `pageMoreSheets` and
  `pageLifecycle`. `body` now renders the same stack and applies the same
  modifiers in the same order.
* `DSHManagementModel.swift` — the preview-session `map` closure now has an
  explicit `(Int) -> ManagedSession` type, and `title`, `updatedAt` and `cwd`
  are typed `let`s before the initializer call.
* `IPhoneAgent.swift` — the chained `??` text fallback is now three typed
  `String?` locals (`assignmentText`, `jsonText`, `quotedText`) and one final
  `String`; evaluation order is unchanged.

The same `build-for-testing` command now succeeds, and the XCUITest export runs.

## First two-platform run (2026-11-12, before the host-frame fix)

Environment:

* **iOS:** iPhone 17 Pro simulator, iOS 26.2, Xcode 26.2 (17C52), logical
  viewport 402 x 874 pt. Export source:
  `examples/probe-app/PhoneDSHDeviceUITests/ParityGeometryExportUITests.swift`
  (XCUITest frames).
* **Android:** JVM/Robolectric export, `@Config(sdk = [35], qualifiers =
  "w402dp-h874dp")`, Compose semantics; the capture frame reserves the measured
  62 pt status band (`SettingsMetrics.PARITY_SAFE_AREA_TOP_PT`). Export source:
  `android/lib/src/test/kotlin/com/phonedsh/ui/parity/ParityGeometryExportTest.kt`.
* **Commit:** `9af4d7f3` (HEAD at export) plus the working-tree identifier and
  type-check changes recorded in this section. Unit is pt on both sides; no
  rescale.
* **Result:** all three fixtures **FAIL** on observed deltas. No threshold,
  fixture tolerance or Android UI was changed.

Commands and results:

| command | result |
|---|---|
| `xcodebuild build-for-testing -scheme PhoneDSHDeviceUI ...` | **PASS** |
| `bash scripts/parity/run_ios_export.sh` | **PASS** (1 test, 3 exports) |
| `bash android/tools/with-android-toolchain.sh ./gradlew :lib:testDebugUnitTest --tests '*parity*' --rerun-tasks --no-daemon` | **PASS** (4 tests, 3 exports) |
| `python3 -m unittest discover -s scripts/parity -p 'test_*.py'` | **PASS** (23 tests) |
| comparator `chat-empty` | **FAIL**, 2/5 elements pass |
| comparator `session-drawer-open` | **FAIL**, 1/3 elements pass |
| comparator `settings-root` | **FAIL**, 0/6 elements pass |

Frames below are in the fixture origin space; `absoluteFrame` is retained in
the export JSON. `Δ = Android − iOS`, so a positive Δ means the Android frame
starts lower/further right or is larger. All identity comparisons are
`testTag` / `accessibilityIdentifier` (warning only).

### `chat-empty`

Origin `chat.header.title`; absolute origin is Android `(76,126)` vs iOS
`(76,70)`.

| element | Android frame (x,y,w,h) | iOS frame (x,y,w,h) | Δx, Δy, Δw, Δh | status |
|---|---|---|---|---|
| `chat.header.drawer` | -60, 0, 44, 44 | -60, 0, 44, 44 | 0, 0, 0, 0 | PASS |
| `chat.header.title` | 0, 0, 202, 44 | 0, 0, 202, 44 | 0, 0, 0, 0 | PASS |
| `chat.empty.start` | -56, 510, 362, 50 | -56, 463, 362, 50 | 0, **+47**, 0, 0 | FAIL |
| `chat.composer.field` | -49, 632, 351, 56 | -49, 594, 351, 36 | 0, **+38**, 0, **+20** | FAIL |
| `chat.composer.send` | 258, 692, 44, 44 | 266, 648, 36, 36 | **-8**, **+44**, **+8**, **+8** | FAIL |

Text: `chat.header.title` matches (`新会话`). iOS `chat.composer.send` exposes
`发送消息` while Android exposes no text/layout for the send node. iOS line
layout is `null`, as expected.

### `session-drawer-open`

Origin `drawer.new-session`; absolute origin is Android `(16,8)` vs iOS
`(16,70)`.

| element | Android frame (x,y,w,h) | iOS frame (x,y,w,h) | Δx, Δy, Δw, Δh | status |
|---|---|---|---|---|
| `chat.header.drawer` | 0, 118, 44, 44 | 0, 0, 44, 44 | 0, **+118**, 0, 0 | FAIL |
| `drawer.new-session` | 0, 0, 288, 52 | 0, 0, 288, 52 | 0, 0, 0, 0 | PASS |
| `drawer.scroll` | -16, -8, 320, 874 | -16, -70, 320, 874 | 0, **+62**, 0, 0 | FAIL |

The drawer scroll `Δy=+62` is the status-band difference the fixture marks as
spec §5 `insets`; it appears as a failure in this first run because the Android
export omitted `gatedAxes` (fixed and re-run below). The `chat.header.drawer`
Δy is measured against a drawer origin that itself differs by 62 pt, so it is
an origin-space consequence of the same inset. Text `新会话` matches; iOS line
layout is `null`.

### `settings-root`

Origin `settings.row.modelProvider`; absolute origin is Android `(16,281)` vs
iOS `(16,155.33)`.

| element | Android frame (x,y,w,h) | iOS frame (x,y,w,h) | Δx, Δy, Δw, Δh | status |
|---|---|---|---|---|
| `settings.done` | 342, -163, 28, 59 | 308, -89.33, 58, 36 | **+34**, **-73.67**, **-30**, **+23** | FAIL |
| `settings.row.modelProvider` | 0, 0, 370, 48 | 0, 0, 370, 62 | 0, 0, 0, **-14** | FAIL |
| `settings.row.agentPresets` | 0, 98, 370, 48 | 0, 124, 370, 62 | 0, **-26**, 0, **-14** | FAIL |
| `settings.row.pluginsTools` | 0, 147, 370, 48 | 0, 186, 370, 62 | 0, **-39**, 0, **-14** | FAIL |
| `settings.row.permissionDefaults` | 0, 289, 370, 48 | 0, 305, 370, 62 | 0, **-16**, 0, **-14** | FAIL |
| `settings.row.network` | 0, 387, 370, 48 | 0, 429, 370, 62 | 0, **-42**, 0, **-14** | FAIL |

The rows are 14 pt taller on iOS (62 pt vs Android 48 pt), which accumulates
into the row-to-row `Δy` sequence. `settings.done` is also a different
semantics frame: Android's toolbar node is 28 x 59 at x=342, iOS's button is
58 x 36 at x=308. Text differs on every settings row because the Android export
runs in English (`Model providers`) while the iOS app renders Chinese
(`模型服务`); copy is informational in this bench, not a gate. Android exposes
one text line per row; iOS exposes no line layout.

No PASS is claimed for any fixture above, and none of these deltas were tuned.

### Re-run after the Android `gatedAxes` / `exemption` fix (2026-11-12, before the host-frame fix)

The Android exporter now copies `gatedAxes` and `exemption` from the shared
fixture exactly as it copies `tolerance`; the comparator, fixtures and UI were
not changed. `build/parity/` is not tracked, so the iOS export was re-run on
this host before re-running the Android export and the comparator:

| command | result |
|---|---|
| `bash scripts/parity/run_ios_export.sh` | **PASS** (1 test, 3 exports) |
| `bash android/tools/with-android-toolchain.sh ./gradlew :lib:testDebugUnitTest --tests '*parity*' --no-daemon` | **PASS** (4 tests, 3 exports) |
| comparator `chat-empty` | **FAIL**, 2/5 elements pass (unchanged) |
| comparator `session-drawer-open` | **FAIL**, 2/3 elements pass; `drawer.scroll` now **PASS** on its gated `x/w/h` axes with `Δy=+62` printed as the spec §5 `insets` exemption |
| comparator `settings-root` | **FAIL**, 0/6 elements pass (unchanged) |

`drawer.scroll` is the only result that changed. `chat.header.drawer` still
fails with `Δy=+118` because its frame is relative to `drawer.new-session`,
whose absolute origin differs by the same 62 pt status band. The fixture-level
`session-drawer-open` result therefore remains **FAIL**; no threshold, fixture
tolerance, fixture, skip or Android UI was changed to make an element pass.

## Bench-host capture-frame fix (2026-11-12, P09)

### Measured cause (before the fix)

The Android export put the chat header at absolute `y=126` while the iOS export
put it at `y=70`. The frame reserved the full 62 pt band **and** the page's own
`statusBarsPadding()` reported 56 dp under Robolectric, then the header added
its 8 pt nav top: `62 + 56 + 8 = 126` against iOS `62 + 8 = 70`, a +56 pt top
offset. At the bottom the Android page ran to `y=874`; the iOS tab page ends on
the shell menu at `y=790` (`50 pt` menu content + `34 pt` home-indicator area),
so Android had 84 pt more page. The net title-to-page-bottom distance was
Android `748` vs iOS `720` — the reported **+28 pt** — made of `+56` top and
`-84` bottom. The composer field was at `y=748` vs iOS `664` (+84 net), which
is the same cause.

The fixtures, page composables and tolerances were not the cause.

### Change

`ParityGeometryExportTest` now builds the capture frame from:

* the page's own production status inset plus only the missing part of the
  62 pt iOS band (6 pt under Robolectric, 0 on a device that already reports
  62 pt);
* the real `HomeTabBar(selection = HomeTab.TASKS)` (50 pt) and the measured
  34 pt home-indicator area for `chat` / `sessions-drawer` fixtures;
* the status band but no tab bar for the `settings` fixture, matching iOS's
  full-screen `-uiPreview settings` cover.

Two tests assert the frame on the real composition: the chat title is at
`62 + 8 = 70`, the bar spans `790..840`, and the settings preview has the
status band without a `HomeTabBar`. No page source, fixture, tolerance,
`gatedAxes` entry or comparator rule was changed.

### Before/after

Both columns use the same iOS export (the last successful host run,
`2026-11-11T15:12Z`). `Δ = Android − iOS`; only `Δy` changed.

| fixture | element | Δy before | Δy after | status before → after |
|---|---|---:|---:|---|
| `chat-empty` | `chat.header.drawer` | 0 | 0 | PASS → PASS |
| `chat-empty` | `chat.header.title` | 0 | 0 | PASS → PASS |
| `chat-empty` | `chat.empty.start` | **+29** | **+1** | FAIL → **PASS** (tolerance is 1 pt) |
| `chat-empty` | `chat.composer.field` | **+28** | **0** | FAIL → **PASS** |
| `chat-empty` | `chat.composer.send` | **+28** | **0** | FAIL → **PASS** |
| `session-drawer-open` | `chat.header.drawer` | **+118** | **+62** | FAIL → FAIL |
| `session-drawer-open` | `drawer.new-session` | 0 | 0 | PASS → PASS (fixture origin) |
| `session-drawer-open` | `drawer.scroll` | **+62** | **+62** | PASS → PASS (only x/w/h gated; §5 `insets`) |
| `settings-root` | `settings.done` | **-73.67** | **-73.67** | FAIL → FAIL |
| `settings-root` | `settings.row.modelProvider` | 0 | 0 | FAIL → FAIL (Δh `-14`) |
| `settings-root` | `settings.row.agentPresets` | **-26** | **-26** | FAIL → FAIL |
| `settings-root` | `settings.row.pluginsTools` | **-39** | **-39** | FAIL → FAIL |
| `settings-root` | `settings.row.permissionDefaults` | **-16** | **-16** | FAIL → FAIL |
| `settings-root` | `settings.row.network` | **-42** | **-42** | FAIL → FAIL |

Absolute origins after the fix: chat `chat.header.title` is Android `(76,70)`
= iOS `(76,70)`; the chat page bottom is `790` on both sides. The
`session-drawer-open` origin is still Android `(16,8)` vs iOS `(16,70)`: the
`HomeDrawer` is a separate `Dialog` window and Robolectric reports no status
bar inside it, so its `new-session` row starts at 8 pt. That is why
`chat.header.drawer` remains +62 in origin space even though the page behind it
now starts at the same absolute y as iOS. The settings origin is Android
`(16,225)` vs iOS `(16,155.33)`; the remaining 69.67 pt is settings chrome
above the first row, not the capture frame, and the relative row deltas are
unchanged.

### Remaining findings (not fixed, not relaxed)

* **Drawer dialog status band.** `HomeDrawer`'s own `Dialog` window gets no
  status-bar inset under Robolectric, so the drawer's `new-session` row is
  62 pt higher than iOS and `chat.header.drawer` still fails in origin space.
  Fixing it needs a production seam (e.g. a host-supplied top inset for the
  dialog) or an instrumented exporter; editing the bench host cannot reach
  that window. This is recorded under "Needed outside my scope".
* **Settings rows.** Android rows are 48 pt vs iOS 62 pt, and `settings.done`
  is a different semantics node; this is `SettingsPage` / `SettingsChrome`
  geometry, outside the bench host. Relative deltas are unchanged from before
  the fix.
* No tolerance, fixture, `gatedAxes` entry or skip was changed to produce any
  of the results above.

## Report provenance

Every export records `platform`, `generatedAt`, `source`, `origin`, `frame` and
per-element identity. The report repeats those fields so a `PASS` cannot be
read as a claim about a different build, device, or state.
