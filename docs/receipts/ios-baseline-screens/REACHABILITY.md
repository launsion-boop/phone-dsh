# iOS page reachability audit (HEAD 2026-10-31)

Scope: the 24 page contracts in `spec/ui/v1/pages/*.json` (excluding `_baseline`,
`_whitelist`, `_android-only`). For each contract page: can a user reach it in the
Debug probe app **without** launch arguments, and what is the evidence?

The audit was done by grepping every call site of the page's `struct` in
`examples/probe-app/PhoneDSHProbe/` (read-only). "0 call sites" means the page
type is declared but nothing instantiates it; a lone `.sheet` binding that is
never set is also unreachable.

Legend:

* **user-reachable** — a real control in the shipped native shell opens it.
* **preview-only** — no product control; `-uiPreview <name>` renders it for review.
* **unreachable** — no product control and no `-uiPreview` name; only source exists.

| # | page id | iOS page | status | evidence |
|---|---|---|---|---|
| 1 | `chat` | `ChatPage` | user-reachable | root of the shell: `NativeShell.swift:108` `ChatPage(openDrawer:)` |
| 2 | `sessions` | `SessionsPage` | user-reachable | drawer body: `NativeShell.swift:284` `SessionsPage(onSelect:)` |
| 3 | `files` | `FilesPage` | user-reachable | drawer folder → `NativeShell.swift:329`; workbench → `NativeWorkbenchPage.swift:24` |
| 4 | `settings` | `SettingsPage` | user-reachable | drawer 设置 → `NativeShell.swift:307`; chat toolbar → `ChatPage.swift:255` |
| 5 | `model-provider-settings` | `ModelProviderSettingsPage` | user-reachable | `SettingsPage.swift:75` row 模型服务; `ChatPage.swift:247`/`:251`; web sheets `RootView.swift:47` |
| 6 | `web-search-settings` | `WebSearchSettingsPage` | user-reachable | `SettingsPage.swift:88` row 网页搜索; `RootView.swift:56` |
| 7 | `mcp-settings` | `MCPSettingsPage` | user-reachable | `SettingsPage.swift:76` row MCP; `RootView.swift:68` |
| 8 | `mcp-editor` | `MCPEditorPage` | user-reachable | pushed by MCP settings: `MCPSettingsPage.swift:61`, `:83`, `:114` |
| 9 | `native-configuration` | `NativeConfigurationPage` | user-reachable | chat `⋯` → `ChatPage.swift:259`/`:263`; sessions row menu → `SessionsPage.swift:349`; settings 插件与模型 → `SettingsPage.swift:56` |
| 10 | `native-automation` | `NativeAutomationPage` | user-reachable | drawer 定时任务 → `NativeShell.swift:310`; sessions menu → `SessionsPage.swift:343` |
| 11 | `egress-allow-list` | `EgressAllowListPage` | user-reachable | `SettingsPage.swift:89` row 网络访问 |
| 12 | `runtime-details` | `RuntimeDetailsPage` | user-reachable | chat header status dot → `ChatPage.swift:273`; settings about row → `SettingsPage.swift:288` |
| 13 | `workspace-folders` | `WorkspaceFoldersPage` | user-reachable | drawer 工作文件夹 → `NativeShell.swift:311` |
| 14 | `pdsh-shell` | `PDSHShellPage` | user-reachable | `SettingsPage.swift:95` row 命令; workbench panel → `NativeWorkbenchPage.swift:26` |
| 15 | `native-workbench` | `NativeWorkbenchPage` | user-reachable (conditional) | sheet wired at `ChatPage.swift:242`, opened from a tool-written file path |
| 16 | `export` | `ExportPage` | user-reachable | `SettingsPage.swift:130` 关于 → 导出诊断 sheet |
| 17 | `web-surface` | `WebSurfacePage` | user-reachable | default surface whenever the local Web host is up: `RootView.swift:17` (not covered by this lane) |
| 18 | `settings-about` | `SettingsAboutPage` | **preview-only** | only `NativeShell.swift:775` (`settings.about`); in the product the 关于 rows are a group inside `SettingsPage`, not a page |
| 19 | `session-activity` | `SessionActivityPage` | **unreachable** | only `ChatPage.swift:294` inside `.sheet(isPresented: $showActivity)`. `showActivity` is declared at `ChatPage.swift:51` and never assigned `true` — the sheet can never present. The spec itself says "基線不可达" |
| 20 | `memory` | `MemoryPage` | **unreachable** | only `SettingsPage.swift:541` inside `DevelopmentToolsPage`; see note below |
| 21 | `probes` | `ProbesPage` | **unreachable** | only `SettingsPage.swift:540`, same dead branch |
| 22 | `background` | `BackgroundPage` | **unreachable** | only `SettingsPage.swift:542`, same dead branch |
| 23 | `task-screen` | `TaskScreenPage` | **unreachable** | only `SettingsPage.swift:543`, same dead branch |
| 24 | `daily-brief` | `DailyBriefPage` | **unreachable** | **zero** call sites in the whole app (`grep 'DailyBriefPage('` → nothing) |

## Why 20–23 are unreachable

`SettingsPage.body` mounts exactly three groups:

```swift
List {
    mainGroup
    toolsGroup
    aboutGroup
}
```

`developerGroup` (`SettingsPage.swift:512`) and `developerSection` (`:524`) are
dead code: neither is mounted, and nothing else references them. They are the
only parents of `DevelopmentToolsPage` (`:537`), which is the only parent of
`ProbesPage` / `MemoryPage` / `BackgroundPage` / `TaskScreenPage` / `ExportPage`
(`:540–:544`). So in the Debug build the 探针工具 screen exists as source but has
no navigation path. The contract's table ("设置 → 探针工具（仅 DEBUG）") describes a
link that is no longer mounted. `ExportPage` survives because the 关于 group
reaches it through `导出诊断` (`:130`).

The visible Settings page confirms this: `ios-settings.png` has 权限 / 写之前 /
模型服务 / MCP / 后台运行 / 工具 / 关于 and **no 开发者 row**.

## Consequence for the P1 lane

* Reachable and captured: chat (+7 states), sessions (+6 states), files,
  settings, settings.model / search / network / plugins / about / runtime,
  schedules (native-automation), workspace-folders, shell (pdsh-shell),
  code.block.
* Reachable by tap only, not in `-uiPreview`, therefore not captured this round:
  MCP settings, MCP editor, native-workbench (needs a tool-written path), export.
* Not reachable, not captured, no substitute: background, probes, task-screen,
  memory, session-activity, daily-brief.

The six unreachable pages' contracts are therefore contracts over **code that
exists**, not over pixels a user can see. The parent lane's rule "don't copy
dead code" applies to them; this audit is the evidence, and no screenshots of
those pages exist in this receipt.
