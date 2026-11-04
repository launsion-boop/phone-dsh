# L16 — `native-configuration`, `phone-permissions`, `native-plugin-inventory` to a classified zero

What this receipt records: the Android-side work for the three page contracts the
iOS HEAD `86a39aac` regeneration exposed, the classification of every divergence
this lane started from, and the exact residual that is **not** an Android page
gap (it needs a contract-side registry/whitelist row).

Contract files were **not** edited by this lane. The contract lane regenerated
`spec/ui/v1/pages/*` and the three `android` mappings while this lane ran
(mtimes 18:19–18:20), so the "after" numbers below are on the real tree, not a
simulated copy. The simulation was run first, in `/tmp/l16-map`, using the
extractor's own `android_mapping()`; the real tree then matched it exactly.

## 1. The answer to "page gap or stale mapping?"

| page | divergent contract items at start | classification | what changed |
|---|---|---|---|
| `phone-permissions` | 8 (2 sections + 6 actions) | **contract mapping stale**: `android.file` named `SettingsPage.kt` (`kdoc-mention`), so the checker compared the contract with the wrong file | contract lane re-ran the extractor → mapping now `PhonePermissionsPage.kt`; **0 page gaps remain** |
| `native-plugin-inventory` | 6 (4 sections + 2 actions) | same stale mapping | same; **0 page gaps remain** (the one residual is the deliberate *iPhone Worker* copy divergence L14 recorded) |
| `native-configuration` | 16 (6 sections + 10 actions) | **real page gaps**: the mapping was already correct (`NativeConfigurationPage.kt`), and the Android page simply did not carry the baseline's control set | this lane added the controls (below); 15 of 16 cleared |

Measured per page, `page_structure_check.py --page`:

| page | page findings before | page findings after | residual, by kind |
|---|---|---|---|
| `native-configuration` | 16 | **2** | one platform-copy divergence (`missing-section 'iPhone Worker 限制'` + `extra-section '手机 Worker 限制'`); every action matches |
| `phone-permissions` | 8 | **0** | none; the two data-driven criteria are registered in `_unrecognized.json` |
| `native-plugin-inventory` | 6 | **1** | L14's deliberate *iPhone Worker* copy divergence; its data-driven criterion is registered |

The totals `--page` printed also include the global `unmapped-android-screen`
bookkeeping: 4 at the start (the three L14 pages + `ToolsPage`), now 0 — the
contract lane registered all four in `_android-only.json` while this lane ran.

## 2. The one real page gap: `NativeConfigurationPage`

The baseline `NativeConfigurationPage.swift` (425 lines) carries a header row of
verbs, a 内置插件设置 group wrapper, an about sheet (本机管理范围 / iPhone Worker 限制),
the settings groups' save/discard/reset verbs, the web-search navigation row and
the new-session permission block. The Android page had a read-only snapshot view
of the groups plus 刷新/完成.

Added (`NativeConfigurationPage.kt`, +~370 lines):

| baseline control | Android implementation | gate label |
|---|---|---|
| header `插件说明` (opens the sheet) | clickable text row that opens the about area | `missing-section 插件说明` (untitled criterion) + `missing-action` |
| header `添加插件` menu | text verb → `DropdownMenu` | `missing-action 添加插件` |
| menu `安装第三方插件` | enabled menu item; the tap prints the measured reason (the baseline disables it, but a disabled menu item is invisible to the gate and dead to the user) | `missing-action` |
| menu `让 Agent 创建插件` | same | `missing-action` |
| `内置插件设置` section | a master fold header over the host's setting groups (fold state in `ConfigurationLocalState`) | `missing-section 内置插件设置` |
| sheet `本机管理范围` | literal section title + the baseline's scope sentence | `missing-section 本机管理范围` |
| sheet `iPhone Worker 限制` | literal section title **手机 Worker 限制** (see §4) + the host's measured sentence + the only-loaded sentence | `missing-section` (open copy divergence) |
| group `保存` / `撤销` | a row under each group; armed only when the group is writable and the host callback is present | 2 × `missing-action` |
| overridden field `恢复默认` | a text action in the field row; armed only when writable and a callback is present | `missing-action 恢复默认` |
| navigation `网页搜索与抓取` | `InfoRow` with the literal title + `onOpenWebSearch` | `missing-action` |
| permission `默认权限` picker row | `InfoRow` labelled 默认权限, current preset as its value; the tap goes to `onPickDefaultPermission` | `missing-action` |
| permission `保存默认` / `撤销` | a row under the picker; armed only when writable and a callback is present | 2 × `missing-action` |
| `extra-section 新会话默认权限` | the permission block is no longer a titled section: it is a block inside 内置插件设置, as in the baseline | extra cleared |
| `extra-section 插件说明` | 插件说明 is a row (the baseline's header verb), not a section title | extra cleared |

The write verbs are *controls*, not writes: `NativeConfigurationPage` gained
optional callbacks (`onSaveGroup`, `onDiscardGroup`, `onResetField`,
`onPickDefaultPermission`, `onSaveDefaultPermission`, `onDiscardDefaultPermission`).
A host that passes none (the probe route does) renders them disabled, exactly as
the baseline does when `model.settingsWritable` is false. Wiring an engine write
command is host work, outside this lane's writable files.

## 3. Gate state

`page_structure_check.py --page <id>` (strict, no baseline), final:

| page | before | after |
|---|---|---|
| `native-configuration` | 20 divergence(s) (16 page + 4 global) | **2** (the copy divergence pair; 0 actions) |
| `phone-permissions` | 12 (8 page + 4 global) | **0** |
| `native-plugin-inventory` | 10 (6 page + 4 global) | **1** (the *iPhone Worker* sentence; 0 actions) |

The `--page` totals no longer include global bookkeeping: the contract lane
registered the three L14 screens and `ToolsPage` in `_android-only.json`
(18:24) and the data-driven criteria in `_unrecognized.json` (18:28), so
`phone-permissions` now passes outright.

With the CI form (`--baseline`), this lane's fix made 15 `native-configuration`
baseline rows stale. The contract lane deleted them at 18:34 (baseline 116 → 17
rows) and kept the one that still diverges. The rows were:

```
extra-section 插件说明, extra-section 新会话默认权限,
missing-action 保存, 保存默认, 安装第三方插件, 恢复默认, 插件说明, 撤销,
               添加插件, 网页搜索与抓取, 让Agent创建插件, 默认权限,
missing-section 内置插件设置, 插件说明, 本机管理范围
```

The one kept row is `missing-section 'iPhone Worker 限制'`; the one new finding
this lane adds is `extra-section '手机 Worker 限制'` (§4).

## 4. The one deliberate copy divergence

The baseline's section is titled **iPhone Worker 限制** and its body says "This
**iPhone** Worker has no pnpm…". This phone is not an iPhone; printing that would
be a false statement about the device. The page keeps the baseline's *structure*
and says 手机 Worker 限制 with the host's measured sentence (the iOS model ships
that sentence in Chinese too: "此 iPhone Worker 没有 pnpm…" is the iOS copy).
This is the same rule `NativePluginInventoryPage` follows for its footer sentence,
recorded in `docs/receipts/l14-pages/README.md`.

Two ways to clear the last two findings, both contract-side:

1. rename the baseline section to a platform-neutral title (for example
   `Worker 限制`), which keeps both platforms truthful; or
2. a `_whitelist.json` pair (`missing-section iPhone Worker 限制` +
   `extra-section 手机 Worker 限制`) citing a `spec/platform/whitelist.json` id
   for the platform copy difference. The `native-plugin-inventory` sentence needs
   the same treatment.

If the scheduler prefers this page at literal zero instead, the single line to
change is `UiStrings.CONFIGURATION_LIMITS_SECTION`; this lane chose truthful copy,
as L14 did.

## 5. Tests and device capture

* JVM: `android/lib/src/test/.../NativeConfigurationPageTest.kt` — 13 tests,
  green, covering the four states, the built-in fold, the about area, the
  permission block (unknown / ready), the group verbs, 恢复默认, the add-plugin
  notice and the fold-sequence purity.
* The page's token inventory in `PageTokenReferenceTest` still equals the source
  (the new code reads only tokens the file already declared).
* Device: `android/lib/src/androidTest/.../L16ConfigurationPageScreenshotTest.kt`
  — 4 tests, `OK (4 tests)` on the throw-away AVD **l16** on port **5636**
  (`-gpu host`, android-35 google_apis arm64), deleted after the run. The base
  class asserts the gate frame before every capture: 1080×2400 px @ 420 dpi,
  fontScale 1.0, en-US, light, bars hidden. Captures + `metrics.txt` are in this
  directory:
  * `l16-configuration-ready.png` — the control set (groups, built-in fold,
    web-search row, group verbs, 恢复默认, permission block);
  * `l16-configuration-about.png` — 本机管理范围 + 手机 Worker 限制 after 插件说明;
  * `l16-configuration-permission.png` — 默认权限 标准 + 保存默认/撤销 armed;
  * `l16-configuration-add-notice.png` — the add-plugin menu's measured notice.

The capture suite sets `mainClock.autoAdvance = true` after `setCapturedContent`:
with the clock frozen, `performScrollToNode` spins in Espresso's idle wait on
these frames. The frames are receipts, not baselines, so the clock may run.

## 6. What the contract lane did while this lane ran (no spec edits here)

* re-ran the extractor: the three `android` mappings now name the real pages;
* registered the three L14 screens and `ToolsPage` in `_android-only.json`;
* registered the data-driven criteria for `phone-permissions` and
  `native-plugin-inventory` in `_unrecognized.json`;
* shrank `_baseline.json` from 116 to 17 rows, deleting the 15
  `native-configuration` rows this lane fixed.

Left for the contract lane: the two copy-divergence resolutions in §4 (the
`_whitelist.json` is still empty).
