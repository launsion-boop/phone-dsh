# Contract refresh — iOS HEAD `86a39aac` (PR #13 merged)

What this receipt records: the 2026-11-01 regeneration of the page contracts in
`spec/ui/v1/pages/`, the README inventory that goes with it, and the Android
worklist the new contracts expose.

Command: `python3 spec/ui/v1/tools/extract_ios_pages.py` (then `--check` → exit 0,
"contracts up to date"). iOS sources are read-only in this lane; nothing under
`examples/`, `Sources/` or `android/` was modified.

## 1. What changed

24 contracts were reported stale. Regenerating produced **15 rewritten files +
9 brand-new files**, and one **orphan was removed**.

### 1.1 Rewritten (source grew/moved, structure changed)

| page | source lines | sections | rows | actions | structural change |
|---|---|---|---|---|---|
| `settings` | 615 → **255** | 3 → **1** | 14 → **1** | 13 → **2** | **flat index → five-tab sheet.** `sectionModel: section → unmodeled`. The three sections (—/工具/关于) and their 13 rows are gone; what is left is the split-view tab list (one `NavigationLink(value: item)`), the 完成 button and the 5-tab `Picker` (which the extractor does not model). `unreachable` went from 2 dead sections to 0 (they were deleted). |
| `chat` | 2962 → **4471** | 4 | 5 | 52 → **67** | +15 actions: 产物 / 右侧边栏 / 运行状态 / 子智能体 / 后台任务 / 定时任务 / 刷新 / 排队消息行 / 2 menus / 2 shares; 8 old buttons and the 还有 1 个待确认 row disappeared from the contract. 33 provenance lines moved. |
| `runtime-details` | same file (struct 2603 → 4111) | 3 | 6 | 4 | pure re-pointing: the whole page moved down 1500 lines inside `ChatPage.swift`. |
| `model-provider-settings` | 670 → **708** | 3 | 5 → 6 | 16 → **19** | gained 默认模型 / 文本输入 / 图片输入 / 删除此模型 / 添加模型; lost 删除 {profile.displayName} / 启动 Web 主机 / 重启 Web 主机; the `switch host` extraction warning is gone (the host enum only has `.native` now). |
| `web-search-settings` | 541 → **505** | 7 | 18 → **20** | 12 → **10** | 什么时候生效 1 → 3 rows; lost 重启引擎（用上新设置）. |
| `native-configuration` | 358 → **425** | 7 | 34 | 15 | 撤销 / 完成 provenance moved; the 实验插件/已加载插件 titles moved 2 lines. |
| `sessions` | 708 → 712 | 5 | 16 | 34 | 29 provenance lines moved; action ids re-numbered. |
| `egress-allow-list`, `workspace-folders`, `settings-about` | `NativeShell.swift` 996 → 1001 | unchanged | unchanged | unchanged | pure re-pointing (+1 line in the shell). |
| `files` | 487 | 1 | 2 | 8 | only the `navigationTitle` anchor changed (`NativeText` bilingual). |
| `mcp-settings`, `mcp-editor` | 304 → **281** | 4 | 8 / 11 | 3 / 4 | 23 lines removed; all provenance shifted. |
| `native-automation` | 418 → 420 | 1 | 1 | 12 | sheets and actions shifted 2 lines. |
| `pdsh-shell` | 120 | 5 | 19 | 3 | no change at all in the file — listed stale only because the tool's output stabilised (no diff after regen). |

### 1.2 New contracts (9)

| page | source | sections | rows | actions | notes |
|---|---|---|---|---|---|
| `chat-preferences` | `ChatPreferencesPage.swift` (84) | 4 | 5 | 4 | 外观 / 字号 / 过程折叠 / 转录; **no call site anywhere** |
| `native-agent-presets` | 182 | 3 | 12 | 5 | the 预设 tab body |
| `native-device-connection` | 172 | 3 | 5 | 2 | 设备会话映射 / 真实连接设备 / 传输能力 |
| `native-device-session` | 442 | 1 | 7 | 1 | one flat read-only transcript → `sectionModel: single-region` (manual judgement added to `SINGLE_REGION_PAGES`) |
| `native-plugin-inventory` | 66 | 4 | 7 | 3 | the 插件 tab body |
| `native-settings-document` | 39 | 1 | 2 | 2 | configuration file viewer; **no call site** |
| `native-shortcuts` | 93 | 3 | 5 | 2 | 通用 tab → 快捷键 |
| `phone-permissions` | 274 | 2 | 3 | 8 | the 手机权限 tab body |
| `session-artifacts` | 349 | 4 | 6 | 8 | chat `⋯` → 产物 |

### 1.3 Removed

* `web-surface.json` — its source `examples/probe-app/PhoneDSHProbe/WebSurfacePage.swift`
  was deleted at `495da9b5` «Remove the app's complete-Web surface». The extractor
  never noticed because it only walks files that exist, so the contract had gone
  stale silently and `page_structure_check` failed on it
  ("Swift source … is missing"). Android still ships `WebSurfacePage.kt`, so the
  screen is now registered in `pages/_android-only.json` with the commit as
  evidence, and its 4 known-divergence rows were removed from
  `pages/_baseline.json`.

## 2. Registries touched (all machine-checked)

| file | change | why |
|---|---|---|
| `pages/_spec-required.json` | removed `settings/运行时详情`; re-pointed `chat/提交回答` to `ChatPage.swift:3430` and `chat/打开会话列表` to `:228` | the settings row it acknowledged no longer exists (the five-tab rewrite); the chat anchors moved with the 1500-line growth |
| `pages/_unrecognized.json` | added `settings/<manual region>`; added `native-configuration/<untitled: nativeConfigurationError(error)>` (renamed from `<untitled: error>`); dropped the old name | the settings page is a tab shell, not a Section tree; the error block's criterion text changed |
| `pages/_whitelist.json` | removed `settings.platform-appendix` | with `sectionModel: unmodeled` the settings sections are no longer compared, so the finding it excused cannot occur; the three platform divergences stay documented in README §5 |
| `pages/_android-only.json` | added `WebSurfacePage` with reason + evidence | iOS deleted the page; Android still ships it |
| `pages/_baseline.json` | 134 → 118 rows (16 stale rows removed: 4 web-surface, 10 Android-fixed, 2 native-automation) | the ratchet only shrinks; `--write-baseline` was **not** run, so the 33 new Android gaps below stay visible |
| `tools/extract_ios_pages.py` | `SINGLE_REGION_PAGES += NativeDeviceSessionPage` | one flat transcript, no Section anywhere — a manual judgement, printed as such |

## 3. Gate state

See the lane report for the before/after table. Summary at HEAD:

* `ui_check.py` — **PASS** (was FAIL: 11 `*Page` structs missing from the README).
* `extract_ios_pages.py --check` — **exit 0** (was exit 1, 24 stale).
* `page_structure_check.py` (the `--baseline` form CI uses) — **FAIL**: the
  contract-side errors are gone; what remains is Android-side drift (list below).
  The count moved while it was measured because the Android lane was rewriting
  `android/…/ui/page/*.kt` (mtimes 16:44–16:54): 32 → 33 → **51** findings. The
  last jump is 21 findings from `native-agent-presets` / `native-plugin-inventory`
  / `phone-permissions` picking up a `kdoc-mention` mapping to `SettingsPage.kt`
  (the Android lane's new file header names those tab bodies while the pages
  themselves are still unimplemented). Those three will collapse back to one
  `missing-section '<android-screen>'` each as soon as the real screens land, or
  the mapping needs tightening if the mention is only prose.
* `spec/v1/tools/spec_golden.py --full` — **0 errors** (untouched by this lane).
* `spec/tools/cross_check.py` — **8/8 invariants ok**.
* `spec/ui/v1/tools` unit tests — **86 tests OK** (README cap 300 and the
  `ChatPage.swift:1048` baseline anchor are asserted there).

## 4. Android worklist (snapshot 2026-11-01T17:00+08:00, 51 findings)

The Android tree was in flight (`android/…/ui/page/*.kt` mtimes 16:44–16:54), so
treat the list as a snapshot: rows kept disappearing while it was taken
(`native-automation` extra 关闭/重试, then 刷新).

| page | finding | what Android must do |
|---|---|---|
| `chat-preferences`, `native-shortcuts`, `native-settings-document` | `missing-section '<android-screen>'` | **no `fun *Page()` exists** — three pages to build (or register as deliberately skipped) |
| `native-agent-presets`, `native-plugin-inventory`, `phone-permissions` | 21 findings (sections + actions) | mapped to `SettingsPage.kt` by a kdoc mention; the tab bodies themselves are not implemented yet |
| `session-artifacts` | `missing-section '<android-screen>'` | `SessionArtifactsPage.kt` exists but no longer declares `fun SessionArtifactsPage()` |
| `chat` | 4 `missing-action` (产物 / 右侧边栏 / 运行状态 / 刷新) + 2 `extra-action` (更多操作 / 还有 1 个待确认) | align the header menu and the pending strip with the new contract |
| `egress-allow-list` | 2 `android-only-stale` (重试 / 关闭) + 1 `missing-action` (恢复成默认的) | delete the two stale `_android-only-items.json` rows, add 恢复成默认的 |
| `model-provider-settings` | 6 `missing-action` (删除 %@, 默认模型, 文本输入, 图片输入, 删除此模型, 添加模型) | the model editor's per-model rows |
| `native-device-connection` | 1 `missing-section` (criterion row 解除该设备的会话映射) | the first group's row label |
| `native-device-session` | 1 `missing-action` (正在读取…) | the loading button label |
| `pdsh-shell` | 4 `missing-section` (这台手机 / 运行命令 / 输出 / 限制) | section headers, or a whitelist entry if Android renders them differently |
| `sessions` | `extra-section 会话列表` + `missing-section 已归档` | the archived section is now titled |
| `settings` | `missing-action 完成` | the sheet's 完成 button is not declared as an Android action |
| `native-automation` | 1 `unresolved-section` (empty title expression) | a title built from state with no literal |
| `(android)` | `unmapped-android-screen ToolsPage` | `ToolsPage.kt` has no contract and is not in `_android-only.json` |

## 5. Open questions

1. **Should the baseline absorb the 33 Android gaps?** Leaving them out keeps the
   gate red but visible; `page_structure_check.py --write-baseline` would make it
   green in one command. This lane did not run it: recording 33 unowned
   divergences as "known" is the Android lane's call, not the baseline lane's.
2. **Does `SettingsPage` deserve a tab model?** The contract is now
   `sectionModel: unmodeled` with one implicit region, so section comparison for
   the app's most-changed page is skipped. Options: (a) teach the extractor to
   model a segmented `Picker` + `switch` over an enum as regions, (b) accept
   `unmodeled` and register it (done), (c) hand-write the five tab rows via
   `_spec-required.json`.
3. **`WorkspaceFoldersPage` and `FilesPage` lost their product entry.** The
   drawer now holds only 定时任务 / 设置; files are reachable only from the
   workbench. Android still has a workspace-folders route. Is that intentional on
   iOS, and should Android drop its route?
4. **`MCPSettingsPage` is unreachable** (zero call sites) yet keeps a contract and
   an Android screen. Keep it as `later`, or retire both?
5. **`ios-chat-default.png` is a live-host shot** that varies run to run (±4.4 %).
   If Android diffs against it, it should probably become a static preview state
   (new `PreviewScreen` case) instead of `sample`.
