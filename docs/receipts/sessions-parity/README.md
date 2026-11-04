# Sessions family — Android vs iOS baseline (L2 lane receipt)

Seven states, captured at the iOS baseline's own viewport and compared to
`docs/receipts/ios-baseline-screens/ios-sessions-*.png`.

| state | iOS file | Android capture | side-by-side |
|---|---|---|---|
| default | `ios-sessions-default.png` | `page-sessions-default.png` | `side-by-side-default.png` |
| empty | `ios-sessions-empty.png` | `page-sessions-empty.png` | `side-by-side-empty.png` |
| error | `ios-sessions-error.png` | `page-sessions-error.png` | `side-by-side-error.png` |
| many | `ios-sessions-many.png` | `page-sessions-many.png` | `side-by-side-many.png` |
| nothing | `ios-sessions-nothing.png` | `page-sessions-nothing.png` | `side-by-side-nothing.png` |
| ungrouped | `ios-sessions-ungrouped.png` | `page-sessions-ungrouped.png` | `side-by-side-ungrouped.png` |
| schedules | `ios-sessions-schedules.png` | `page-sessions-schedules.png` | `side-by-side-schedules.png` |

`measurements.md` is the machine dump: for every state, each ink band's y, height
and x span on both sides.

## 0. Provenance

The captures were produced twice:

1. **Snapshot build** while the shared tree was red (another lane's half-written
   pages): `/tmp/l2/build` = the working tree's `android/` + `spec/` sources, with
   `examples/` and `shell/` symlinked (the `:app` module refuses to configure
   without the worker bundle and `libpdsh_jni.so`). Three throwaway-only edits made
   that snapshot compile, none of them part of this lane's deliverable:
   * deleted `ui/page/NativeDeviceConnectionPage.kt` and
     `ui/page/NativeDeviceSessionPage.kt` — **snapshot only, to make the snapshot
     compile; this is not a judgement that those pages should not exist**;
   * patched `ui/surface/Bubble.kt:160` (`type.body` → `bubbleBodyStyle()`, the
     one-line break another lane has since fixed in the tree);
   * deleted the in-flight `ParityScreenshotTest.kt`, `ChatParityScreenshotTest.kt`,
     `SettingsParityScreenshotTest.kt`, `ShellFilesParityScreenshotTest.kt`,
     `L4NavWiringTest.kt`, `DeviceConnectorParityScreenshotTest.kt`,
     `DeviceParityStates.kt`, `PageScreenshotTest.kt`,
     `SignatureSurfaceScreenshotTest.kt` from the snapshot's androidTest source
     set — **snapshot only**, because each was mid-write in another lane. The
     harness files this lane does use (`ScreenshotTestBase`, `ScreenshotProfile`,
     `ScreenshotStore`, `ScreenshotSamples`, `ParityStates`) were copied from the
     tree unmodified.
2. **Repository tree**, after it went green: same test class, same device, same
   frame.

All seven PNGs are **byte-identical** between the two runs
(`cmp` on each of `page-sessions-{default,empty,error,many,nothing,ungrouped,schedules}.png`),
so the snapshot edits did not touch a single sessions pixel and the receipt is
reproducible from the tree.

Device: self-built AVD `pdsh5614` on port 5614, `-no-window`, deleted after the run.

## Capture conditions (asserted, not assumed)

* AVD `pdsh5614`, API 35, arm64, `-no-window`, port **5614** (not 5558/5610/5612/5616/5618).
* `1206 × 2622 px @ 480 dpi` = **402 × 874 pt @3x**, exactly the iOS frame.
* light, `fontScale 1.0`, locale `en-US`, system bars hidden, white backdrop,
  animations off, virtual clock frozen at +1000 ms.
* Chain: `ScreenshotTestBase` → `setContent` → `captureToImage()` (PixelCopy of the
  real window) → PNG. Instrumented Compose on a real emulator, not Robolectric.
* `SessionsParityScreenshotTest` extends the shared base, pins
  `ScreenshotProfile.IOS_PARITY`, and takes its seven PNG names from `ParityState`
  (`page-sessions-*`), so the captures land in
  `pdsh-screenshots/ios-parity/fs-1.0/` next to `parity-registry.txt`.

## How to read the composites

iOS on the left, Android on the right, **Android top-padded by 177 px (59 pt)** so
both frames share the content origin. The iOS status bar and the capture harness's
blue-grey ✕ stay visible on the left; the Android column's top 59 pt is padding,
not page UI. Horizontal scale is identical (1 pt = 3 px), so an x difference is a
real layout difference — including the deliberate one described in §4.

## 1. Per-state conclusion

| state | structure (rows, order, copy, states) | rhythm | verdict |
|---|---|---|---|
| default | identical blocks: search → section label → 新建会话 + hairline → engine-off sentence → 还没有工作文件夹 → hint → CTA | everything lands 3–26 pt tighter than iOS; CTA is 48 vs 50 pt tall | **structure ✓**, metrics off (see §3) |
| empty | identical: two folder sections, each 还没有会话 + 点上面的「新建会话」开始。, hairline, 添加工作文件夹, 已归档 0 | same systematic tightening (~35 pt by the first folder) | **structure ✓** |
| error | identical: red 读不到会话 + accent 重试 on one 44 pt row above the folder header | row pitch 57.7 vs 56; error row at rel 197 vs 229 | **structure ✓** |
| many | identical: 项目资料 · 20 个会话, 20 rows with the baseline's titles (预览会话 1/3/5…, 新会话 at index 10) and times (刚刚, 2 小时前, …) | row pitch **57.7 vs 56** (+3 %), 11 rows visible vs iOS 9 (the tightening above) | **structure ✓**, closest state |
| nothing | identical to `default`; iOS's only difference is a container that hides the 会话 label | — | **identical by construction** (see §4) |
| ungrouped | identical: three ungrouped rows directly under the hairline, no folder header | pitch 57.7 vs 56 | **structure ✓** |
| schedules | **different page**: Android renders `NativeAutomationPage`'s FAILED state (定时任务读取失败 + raw probe error), iOS renders 34 pt 定时任务 + 新建/refresh pills + 还没有定时任务 + 新建任务 CTA + 需要处理 header + red error | n/a (different block set) | **not aligned** — the page is outside this lane's writable set (see §5) |

## 2. Measured agreement (pt, relative to each frame's search placeholder ink)

`many`, content-relative, after the `SessionsMetrics` swap:

| element | iOS | Android | Δ |
|---|---|---|---|
| 会话 section label | 76.4 | 81.0 | +4.6 |
| 新建会话 row | 123.7 | 121.3 | −2.4 |
| hairline under it | 153.4 | 150.7 | −2.7 |
| engine-off sentence | 180.0 | 167.3 | −12.7 |
| folder header | 229.0 | 201.7 | −27.3 |
| first session row | 274.7 | 253.7 | −21.0 |
| **session row pitch** | **56.0** | **56.7** | **+0.7** |
| **row separator span** | **16 → 303.7** | **16 → 304.0** | **+0.3** |
| **drawer content column** | **288** | **288** | **0** |
| search capsule height | 40 (this PNG) / 44 (L6's PNG) | 44 | see §3.1 |
| CTA height | 50 | 50 | 0 |
| CTA / empty-block x (drawer states) | 16 → 304 | 16 → 304 | 0 |

The horizontal geometry of the drawer states now matches exactly: the list is a
320 pt column (`SessionsMetrics.drawerWidth`), rows inset 16 + 8, separators
`288 × 0.5` starting at 16 — the same construction as `SessionsPage.swift:590-597`.
The vertical residue is one thing only: iOS's plain `List` puts ~24 pt of section
spacing above every section, which no source line in `SessionsPage.swift` owns
(L6: *"Drawer inter-row spacing … likely iOS 26 List section spacing; can't
attribute to source"*), so it is left out rather than invented.

## 3. Known differences and their cause

1. **The search capsule is a deliberate divergence.** `NativeShell.swift:291`
   gives the drawer `.toolbar(.hidden, for: .navigationBar)`, so the *shipped*
   drawer (iOS HEAD) has no search field and no 会话 nav title; both survive only
   in the standalone presentation that `ios-sessions-default.png` /
   `ios-sessions-empty.png` were captured from. Android keeps them, because
   (a) the parity target this lane was given is those PNGs and `VISUAL.md` §3
   specs the 369.7 × 40 capsule as SessionsPage chrome, and (b) this page is a
   full-screen route where filtering a 40-row list is a real need. Flipping to
   HEAD parity means deleting `SessionsSearchField` and `SessionsSectionLabel` —
   no other code depends on them.
   Height: L6 measures **44 / r22** from `darkfinal-sessions-light.png`; the
   baseline PNG measures **40 / r20** (`VISUAL.md` §3, re-measured here). The two
   PNG sets disagree by 4 pt; the page uses L6's 44 (`SessionsMetrics.searchHeight`).
2. **`sessions` (default) vs `sessions.nothing`**: iOS renders the same drawer in
   two containers (`.sessions` → `SessionsPage` directly, `sessions.nothing` →
   `DrawerPreview`). The standalone one is 402 wide (CTA 370, separators 16 → 386)
   and hides nothing; the drawer one is 320/288. Android always renders the drawer
   column, so `page-sessions-default.png` is the *drawer* layout while
   `ios-sessions-default.png` is the *standalone* one — the one remaining
   horizontal difference in this receipt, and it is the baseline that is
   inconsistent. The two Android captures are byte-identical.
3. **Copy**: the section label reads `UiStrings.SESSIONS` = 会话列表, the baseline
   prints 会话 (the drawer's own title). `UiStrings.kt` is outside this lane.
4. **Icons**: iOS uses SF Symbols (`magnifyingglass`, `bubble.left`, `ellipsis`,
   `chevron.down`, `plus`); Android has no icon set, so glyphs are text (the
   convention documented in `ChatRows.kt`). The row glyph sits in a
   `SESSION_GLYPH_BOX_PT` = 17 box but draws ~10.7 pt wide, so the title lands at
   47 instead of 51.7. The search field carries no magnifier.
5. **Glyph metrics**: the platform CJK font draws ~5 % taller than PingFang SC at
   the same nominal size (17 pt 会话: 15.3 pt ink on iOS, 16.3 pt on Android).
   This is also why the 56 pt session row renders 56.7: the row applies
   `heightIn(min = SESSION_ROW_HEIGHT_PT)`, and the two default line boxes
   (17 sp title + 3 + 12 sp caption) come out 0.7 pt taller than the frame — a
   font-metrics artefact, not a geometry choice.
6. **Status area**: the iOS frames include a 59 pt status bar, the Android capture
   is immersive. The composites pad Android to line the content origins up.

## 4. What is *not* claimed

This receipt does not claim pixel equality. It claims: same blocks in the same
order with the same copy and the same state transitions, row/control heights within
a few points, x geometry matching within ~1.3 pt where the column width is not a
deliberate difference, and every remaining gap named with its cause and its measured
size.

## 5. `schedules` (`NativeAutomationPage`)

`android/lib/src/main/kotlin/com/phonedsh/ui/page/NativeAutomationPage.kt` is not in
this lane's writable set, so the capture records the page as it stands. To match
`ios-sessions-schedules.png` it needs: a 34 pt large title 定时任务 with the
refresh / 新建 pills in the bar; the empty block (还没有定时任务 17 semibold,
到点让它自己跑,结果回到原会话。13 pt, a 370 × 50 pt radius-12 `#2F5BFF` CTA
新建任务); and the 需要处理 20 pt grey section header above the red 15 pt error,
with the empty block **and** the error visible in the same frame (today the FAILED
status replaces the catalogue).

## 6. Route evidence

`SessionsParityScreenshotTest#sessionsRouteRendersThePage` mounts the router, not
the page:

```kotlin
PdshNavHost(
    nav = PdshNavState(stack = listOf(PdshRoute.Home, Sessions)),
    facts = PdshNavFacts(), onNavigate = {}, onBack = {}, onHome = {},
    onHostAction = {}, home = {}, webSurface = {},
)
```
and asserts `pdsh.sessions.root` + `pdsh.sessions.workspace.unknown` +
`pdsh.sessions.new.row` are on screen. Run: `am instrument … -e class
…SessionsParityScreenshotTest` → **OK (8 tests)** (7 captures + this one).

The wiring is three lines in `PdshNavHost.kt`: the subtype
(`public data object Sessions : PdshRoute`, PUSH), one branch
(`Sessions -> SessionsRoute(facts, onBack)`) and the route composable that builds
`SessionsScreenState.from(...)` out of `facts.workspaceFolders`.
