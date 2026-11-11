# Cross-platform parity bench v0 (element geometry)

Status: v0, 2026-11-12. Owner: parity bench. This is the first bench that
compares the **real iOS app** with the **real Compose pages**. It does not
replace the screenshots in `docs/receipts/ui-parity-sheet/`; it replaces the
hand-authored Android `ScreenState` samples as the source of layout evidence.

Current v0 receipt on this host:

| command | result |
|---|---|
| `python3 -m unittest discover -s scripts/parity -p 'test_*.py'` | **PASS** (23 tests) |
| `bash android/tools/with-android-toolchain.sh ./gradlew :lib:testDebugUnitTest --tests '*parity*' --rerun-tasks --no-daemon` | **PASS** (4 tests, three exports written) |
| iOS `xcodebuild ... PhoneDSHDeviceUI` | **NOT_RUN** — the probe app's existing Swift sources do not type-check under Xcode 26.2; see the build-blocker section below |

No cross-platform comparison report exists yet because the iOS side did not
run. A report is only `PASS` when both export files describe the same fixture,
unit and origin.

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
      "ios": {"label": "打开会话列表"},
      "text": false,
      "tolerance": 1.0
    },
    {
      "id": "drawer.scroll",
      "android": {"testTag": "home.drawer.scroll"},
      "ios": {"first": "scrollView"},
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
| `elements[].ios.identifier` | an accessibility identifier, when one exists |
| `elements[].ios.label` | accessibility-label fallback when no stable identifier exists (recorded as missing outside this bench's scope) |
| `elements[].ios.first` | positional fallback for a container with no identifier (`scrollView`, `textView`) |
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
identity kinds. The bench needs these stable identifiers that do not exist yet;
they are listed under **Needed outside my scope** in the handoff, not edited
into the app here.

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

The capture frame reserves the measured iOS status band
(`SettingsMetrics.PARITY_SAFE_AREA_TOP_PT` = 62 pt), the same band the existing
pixel-parity suite uses. This is a capture condition, not a page inset: on a
device the page already gets the band from the platform.

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

These are the stable hooks the v0 fixtures need but cannot add from the bench's
owned files. The iOS exporter falls back to the accessibility label or the first
`scrollView` so the bench still runs; the comparator records the fallback as the
element's identity, and this list is the work item to remove it.

iOS `accessibilityIdentifier` missing (currently addressed by label):

* `chat.header.drawer` — label `打开会话列表`
* `chat.empty.start` — label `启动本地引擎`
* `chat.composer.field` — label `发消息或创建任务，/ 调用指令，@ 文件或对话`
* `chat.composer.send` — label `发送消息`
* `drawer.new-session` — label `新会话`
* `settings.done` — label `完成`
* `settings.row.modelProvider` — label `模型服务`
* `settings.row.agentPresets` — label `Agent 预设`
* `settings.row.pluginsTools` — label `插件与工具`
* `settings.row.permissionDefaults` — label `新会话默认权限`
* `settings.row.network` — label `网络访问`

iOS container without an identifier:

* `drawer.scroll` — currently resolved as `app.scrollViews.firstMatch`; needs an
  accessibility identifier on the drawer's `ScrollView`.

Both sides, text layout:

* The iOS exporter cannot read a line count or wrap points from XCUITest. A
  debug-only accessibility value (or an XCUITest-visible test surface) carrying
  `TextLayoutResult`'s `lineCount` and line start offsets is needed before the
  comparator can gate iOS line counts. Until then the report records
  `null` / "not exposed", never a guessed height.

No `examples/probe-app/project.yml` change is needed: the
`PhoneDSHDeviceUITests` target already uses the whole directory as its sources.

Build input registration:

* `:lib:testDebugUnitTest` does not declare `scripts/parity/fixtures/**` as an
  input, so editing a fixture alone leaves the Android test `UP-TO-DATE`. Run
  with `--rerun-tasks` (as the v0 receipt does) or register the fixture
  directory as a Gradle test input; the latter is in `android/lib/build.gradle.kts`,
  outside this bench's owned files.

## Known build blocker at this revision (2026-11-12)

The iOS exporter could not be run on this host even though Xcode 26.2 and an
iPhone simulator are available: the probe app target does not type-check its own
existing Swift sources. `xcodebuild build-for-testing -scheme PhoneDSHDeviceUI`
fails with

```
PhoneDSHProbe/ChatPage.swift:375:16: error: the compiler is unable to type-check this expression in reasonable time
PhoneDSHProbe/DSHManagementModel.swift:1442:9: error: the compiler is unable to type-check this expression in reasonable time
PhoneDSHVenus/IPhoneAgent.swift:49:13: error: the compiler is unable to type-check this expression in reasonable time
```

Raising `-Xfrontend -solver-expression-time-threshold` (120, 600, then
60000) did not change the result. These files are outside this bench's ownership; editing
them would be an app-source change. The iOS export therefore stays **NOT_RUN**
until the app builds, and no iOS numbers are reported as PASS. The Swift test
itself parses; only the XCTest assertion macros are unavailable to a standalone
`swiftc -typecheck`, which is expected.

## Report provenance

Every export records `platform`, `generatedAt`, `source`, `origin`, `frame` and
per-element identity. The report repeats those fields so a `PASS` cannot be
read as a claim about a different build, device, or state.
