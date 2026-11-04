# L14 — the three B-group pages (device receipts)

The three iOS page contracts the iOS HEAD `86a39aac` regeneration introduced and
Android did not carry, implemented as Android pages and rendered on a device.

| page | contract | Android screen | capture |
|---|---|---|---|
| `PhonePermissionsPage` | `spec/ui/v1/pages/phone-permissions.json` (274 L, 2 sections, 3 rows) | `android/lib/src/main/kotlin/com/phonedsh/ui/page/PhonePermissionsPage.kt` | `l14-phone-permissions-*.png` |
| `NativeAgentPresetsPage` | `native-agent-presets.json` (182 L, 3 sections, 12 rows) | `.../NativeAgentPresetsPage.kt` | `l14-agent-presets-*.png` |
| `NativePluginInventoryPage` | `native-plugin-inventory.json` (66 L, 4 sections, 7 rows) | `.../NativePluginInventoryPage.kt` | `l14-plugin-inventory-*.png` |

## Capture conditions

`ScreenshotTestBase`'s `gate` profile, asserted before every frame, not assumed:
`1080 x 2400 px @ 420 dpi` (density 2.625), `fontScale 1.0`, `locale en-US`,
`theme light`, system bars hidden, animation clock frozen (`metrics.txt` records
one line per capture). Emulator: a throw-away AVD `l14-b` on port **5632**
(android-35, `-no-window`), deleted after the run.

Which capture shows what:

| file | what it proves |
|---|---|
| `l14-phone-permissions-unread.png` | the honest default: this host reads no permission, so every row says 未知 with its switch off and disabled — and no row says 已允许 |
| `l14-phone-permissions-statuses.png` | the matrix with host-reported statuses: 已拒绝 + 去系统设置, 已允许 + switch on, an untouched capability with no status line |
| `l14-phone-permissions-limited.png` | 部分允许（7）+ 管理可访问照片 for a limited photo library |
| `l14-phone-permissions-confirm.png` | 允许使用这项能力？ with the capability's own purpose and 取消 / 继续 (full-screen capture: a dialog is its own window) |
| `l14-agent-presets-unread.png` | the route render with no roster: 让 Agent 创建预设 + the footnote + the unknown line |
| `l14-agent-presets-two.png` | two presets: 默认 / 自定义 badges, the wire id, the 查看配置 / 设为默认 pair, the broken preset's disabled 设为默认 |
| `l14-plugin-inventory-unread.png` | 插件配置 + the read-only footnote + 插件列表 + 搜索插件 + the unknown line |
| `l14-plugin-inventory-expanded.png` | a disclosure block expanded: 条目 / 模块 / 启用 / 运行状态, the active dot green and the inactive one grey, plus the platform footer |

Every capture is taken by
`android/lib/src/androidTest/kotlin/com/phonedsh/ui/screenshot/L14BGroupPageScreenshotTest.kt`
(8 tests, all green on `l14-b`); the suite also asserts the text a reader can see,
so a blank or greyed page fails the run rather than producing a screenshot.

## Provenance

The device run used a snapshot, not the shared working tree, because `android/lib`
has several lanes editing at once:

```
/tmp/l14-snap = git archive HEAD (86a39aac) + this lane's 9 files only
```

* the 3 new pages, the 3 new tests (the shared `PageTokenReferenceTest` map is
  HEAD + this lane's 3 entries) and this suite;
* `UiStrings.kt` / `UiPageTags.kt`: HEAD + only this lane's appended blocks;
* `PdshRoute.kt`: HEAD + this lane's 3 routes;
* `PdshNavHost.kt`: HEAD + this lane's 11 imports, 3 `when` branches and 3 route
  composables.

`examples/probe-app/Bundle` and `shell/target` are symlinked into the snapshot
because `:app` refuses to configure without those uncommitted build products;
nothing under `android/lib/src` comes from another lane. The build script is
`/tmp/build-l14-snapshot.py`.

## Contract check

`spec/ui/v1/tools/page_structure_check.py`. The contracts still map these three
pages to `SettingsPage.kt` (the `kdoc-mention` fallback written before the pages
existed), so the run was re-done against a copy of `spec/` whose `android` block
names the new file/screen — exactly what re-running `extract_ios_pages.py` will
produce, since `android_mapping()` keys on `public fun <Page>(`:

| page | before | after |
|---|---|---|
| `native-agent-presets` | 3 sections + 4 actions | 1 unresolved (`<untitled: error>` — the contract's own dynamic criterion) |
| `native-plugin-inventory` | 4 sections + 2 actions | 1 unresolved (contract's own) + 1 missing (the *iPhone Worker* sentence, see below) |
| `phone-permissions` | 2 sections + 6 actions | 2 unresolved (the contract's own `row(capability)` criterion + this page's data-driven group caption) |
| **total** | **21** | **5** |

No missing action remains on any of the three pages. The one new finding class is
`unresolved-section 'group.title'` on `phone-permissions`: the baseline renders
`Section(group.title)`, the caption is data, and the gate's section vocabulary
only compares literals — the same shape already registered in
`spec/ui/v1/pages/_unrecognized.json` for `native-configuration 'group.title'`,
`runtime-details 'section.title'` and `session-activity 'section.kind.title'`.
That entry (or a `_whitelist.json` one) belongs to the contract lane, which owns
`spec/**`.

Untouched in the real tree, the run goes 168 → 171: the three extra findings are
`unmapped-android-screen` bookkeeping (the page files exist, the contracts do not
name them yet), and they disappear with the same regeneration. With the mapping
regenerated on the real tree the total is 171 → 152.

## The one copy difference

`NativePluginInventoryPage`'s footer is a platform sentence. The baseline says
"This **iPhone** Worker has no pnpm, execa or subprocess installation
environment…"; this page says the same thing about the phone it runs on
("这台手机没有 pnpm、execa 或子进程安装环境…"), and the host may override it with
its own measured message (`PluginInventoryFacts.managementNotice`). Printing
"iPhone" on an Android phone would be a false statement about the device, so the
wording differs; that is the one deliberate divergence from the baseline copy.
