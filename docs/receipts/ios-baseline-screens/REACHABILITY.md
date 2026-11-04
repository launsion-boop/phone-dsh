# iOS page reachability audit — HEAD `86a39aac` (2026-11-01, post-PR-#13)

Scope: the **32 page contracts** in `spec/ui/v1/pages/*.json` (excluding the
`_*.json` registries) plus the 3 Android-only screens registered in
`pages/_android-only.json`. For each: can a user reach it in the Debug probe app
**without** launch arguments, and what is the evidence?

Method: every call site of the page's `struct` was grepped in
`examples/probe-app/PhoneDSHProbe/` (read-only), and the `PreviewScreen` router
(`NativeShell.swift:737`) was read case by case. "0 call sites" means the type is
declared but nothing instantiates it; a `.sheet` binding that is never set is
unreachable too. This file is the evidence behind the README §1 「入口」 column.

Legend:

* **user-reachable** — a real control in the shipped native shell opens it.
* **preview-only** — no product control; `-uiPreview <name>` renders it for review.
* **unreachable** — no product control and no `-uiPreview` name; only source exists.

| # | page id | iOS page | status | evidence |
|---|---|---|---|---|
| 1 | `chat` | `ChatPage` | user-reachable | root of the shell: `NativeShell.swift:122`; `-uiPreview sample` |
| 2 | `sessions` | `SessionsPage` | user-reachable | drawer body: `NativeShell.swift:288` |
| 3 | `settings` | `SettingsPage` | user-reachable | drawer 设置 → `NativeShell.swift:310`; chat `⋯` → `ChatPage.swift:396` |
| 4 | `native-general` (no contract) | `NativeGeneralSettingsPage` | user-reachable (embedded) | 通用 tab body: `SettingsPage.swift:85` |
| 5 | `model-provider-settings` | `ModelProviderSettingsPage` | user-reachable | 模型 tab: `SettingsPage.swift:85`; chat start card: `ChatPage.swift:388`/`:392` |
| 6 | `native-plugin-inventory` | `NativePluginInventoryPage` | user-reachable | 插件 tab: `SettingsPage.swift:86` |
| 7 | `phone-permissions` | `PhonePermissionsPage` | user-reachable | 手机权限 tab: `SettingsPage.swift:87`; `-uiPreview settings.permissions` |
| 8 | `native-agent-presets` | `NativeAgentPresetsPage` | user-reachable | 预设 tab: `SettingsPage.swift:88` |
| 9 | `native-shortcuts` | `NativeShortcutsPage` | user-reachable | 通用 tab row 快捷键: `SettingsPage.swift:145` |
| 10 | `native-configuration` | `NativeConfigurationPage` | user-reachable | chat `⋯` → 本会话设置: `ChatPage.swift:400`/`:404`; 插件配置 row: `NativePluginInventoryPage.swift:19` |
| 11 | `web-search-settings` | `WebSearchSettingsPage` | user-reachable | 插件配置 page → 网页搜索: `NativeConfigurationPage.swift:132` |
| 12 | `runtime-details` | `RuntimeDetailsPage` | user-reachable | chat header device glyph: `ChatPage.swift:414` (the settings 运行时 row is **gone**) |
| 13 | `session-artifacts` | `SessionArtifactsPage` | user-reachable | chat `⋯` → 产物: `ChatPage.swift:455` |
| 14 | `native-device-connection` | `NativeDeviceConnectionPage` | user-reachable | chat `⋯` → 设备连接: `ChatPage.swift:461` |
| 15 | `native-device-session` | `NativeDeviceSessionPage` | user-reachable | device-connection row: `NativeDeviceConnectionPage.swift:126` |
| 16 | `native-automation` | `NativeAutomationPage` | user-reachable | drawer 定时任务: `NativeShell.swift:313`; sessions menu: `SessionsPage.swift:346` |
| 17 | `files` | `FilesPage` | user-reachable (workbench only) | `NativeWorkbenchPage.swift:24`; the workbench opens from a tool-written path: `ChatPage.swift:383` |
| 18 | `pdsh-shell` | `PDSHShellPage` | user-reachable (workbench only) | `NativeWorkbenchPage.swift:26` |
| 19 | `native-workbench` | `NativeWorkbenchPage` | user-reachable (conditional) | `ChatPage.swift:383`, opened from a tool-written file path |
| 20 | `mcp-editor` | `MCPEditorPage` | **unreachable** | its only parents are `MCPSettingsPage.swift:38/60/91`, and MCPSettingsPage itself has 0 call sites |
| 21 | `workspace-folders` | `WorkspaceFoldersPage` | **preview-only** | only `NativeShell.swift:786` (`-uiPreview workspace`); the drawer's 工作文件夹 row was removed — it now holds 定时任务 and 设置 only (`NativeShell.swift:298`–`:305`) |
| 22 | `egress-allow-list` | `EgressAllowListPage` | **preview-only** | only `NativeShell.swift:778` (`settings.network`) |
| 23 | `settings-about` | `SettingsAboutPage` | **preview-only** | only `NativeShell.swift:782` (`settings.about`); the product has no standalone About page |
| 24 | `mcp-settings` | `MCPSettingsPage` | **unreachable** | **zero** call sites; no `-uiPreview` case either |
| 25 | `export` | `ExportPage` | **unreachable** | zero call sites (the 关于 group's 导出诊断 row left with the flat index) |
| 26 | `chat-preferences` | `ChatPreferencesPage` | **unreachable** | zero call sites; the settings rewrite dropped whatever opened it |
| 27 | `native-settings-document` | `NativeSettingsDocumentPage` | **unreachable** | zero call sites (the presets page's 查看配置 is its only would-be parent) |
| 28 | `session-activity` | `SessionActivityPage` | **unreachable** | only `ChatPage.swift:504` inside `.sheet(isPresented: $showActivity)`; `showActivity` is declared at `ChatPage.swift:79` and never set `true` |
| 29 | `memory` | `MemoryPage` | **unreachable** | zero call sites; `DevelopmentToolsPage`, its only parent, was deleted with PR #13 |
| 30 | `probes` | `ProbesPage` | **unreachable** | zero call sites, same reason |
| 31 | `background` | `BackgroundPage` | **unreachable** | zero call sites, same reason |
| 32 | `task-screen` | `TaskScreenPage` | **unreachable** | zero call sites, same reason |
| 33 | `daily-brief` | `DailyBriefPage` | **unreachable** | zero call sites |
| A1 | `—` | `WebSurfacePage` (Android-only) | **no iOS page** | deleted at `495da9b5` «Remove the app's complete-Web surface»; `RootView.swift:9` renders `NativeShell()` unconditionally |
| A2 | `—` | `SessionHistoryPage` (Android-only) | **no iOS page** | no `struct SessionHistoryPage`; history is the chat `⋯` → 历史 entry |
| A3 | `—` | `GoalDetailPage` (Android-only) | **no iOS page** | no `struct GoalDetailPage`; the goal is a bar in ChatPage |

## What PR #13 moved

* **Gained an entry:** `phone-permissions`, `native-agent-presets`,
  `native-plugin-inventory`, `native-shortcuts`, `session-artifacts`,
  `native-device-connection`/`native-device-session`.
* **Lost an entry:** `settings-about`, `egress-allow-list`, `mcp-settings`
  (settings rows removed by the five-tab rewrite), `runtime-details` (settings
  row gone, chat header glyph remains), `workspace-folders` (drawer row gone),
  `export` (the 关于 group is gone), `chat-preferences`, `native-settings-document`,
  `memory`/`probes`/`background`/`task-screen` (their parent `DevelopmentToolsPage`
  was deleted).
* `SettingsPage`'s contract `unreachable` list is now **empty**: the two dead
  sections the old contract recorded (`runtimeSection`, `advancedSection`) were
  deleted with the rewrite. `ChatPage`'s `showActivity` remains the only
  declared-but-never-set sheet in the app.

## Consequence for the P1 lane

* **Captured in this directory (26 states):** chat (8), sessions (6), files,
  settings, settings.model / search / network / plugins / about / runtime,
  schedules, workspace-folders, shell, code-block.
* **Reachable but not captured** (no `-uiPreview` name; the 27-state list is
  frozen because `ParityStates.kt` registers it): native-agent-presets,
  native-plugin-inventory, phone-permissions, native-shortcuts, session-artifacts,
  native-device-connection, native-device-session, native-workbench,
  native-configuration. Capturing them needs new `PreviewScreen` cases — an iOS
  source change, out of this lane — or XCUITest taps.
* **Not reachable, not captured:** the nine "unreachable" rows above plus
  `mcp-editor`. Their contracts describe code that exists, not pixels a user can
  see; the parent lane's rule "don't copy dead code" applies to them.

The machine-readable version of this audit is
`python3 spec/ui/v1/tools/page_structure_check.py --strict`, which compares each
contract against the Android screen it names and prints the remaining workload.
