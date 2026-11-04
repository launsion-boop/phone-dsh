# iOS baseline screenshots — P1 visual lane

> ## ✅ Recaptured at HEAD `86a39aac` (2026-11-01)
>
> This set is **post-PR-#13** (`9d46fc3c` is an ancestor). The previous batch
> (2026-10-31) predated the settings five-tab rewrite and needed a one-constant
> build shim; **neither is true any more**:
>
> * `xcodebuild … -scheme PhoneDSHProbe … build CODE_SIGNING_ALLOWED=NO` at HEAD
>   ends in `** BUILD SUCCEEDED **` with **no source change of any kind** —
>   `ChatHostConfiguration.swift:28` declares `defaultOfficeInteractionTimeout`
>   again (600 s), which is the constant the 2026-10-31 shim had to add.
> * `NativeShell.swift:179` now presents the DEBUG cover as
>   `NavigationStack { screen.body }` with **no close button**, so the
>   44 × 44 blue-grey ✕ that used to sit in the top-left corner of most shots
>   **is gone**. No artifact needs to be explained away any more.
>
> The 27 **file names are unchanged on purpose**: `ParityStates.kt` (Android)
> registers exactly these 27 states and refuses a directory with an
> unregistered file. 26 app screenshots were re-shot; `ios-environment-home.png`
> is the environment proof and was carried over (same device, runtime, status
> bar, 1206 × 2622).

Read next: [`REACHABILITY.md`](REACHABILITY.md) (32 contract pages: reachable /
preview-only / unreachable at this HEAD) · [`VISUAL.md`](VISUAL.md) (measured
specs, with a validity banner) · [`ANDROID-DIFF.md`](ANDROID-DIFF.md) (visual-only
diff vs the Android baselines).

## What changed vs the 2026-10-31 batch

Pixel diff at 1206 × 2622, `ImageChops.difference`, threshold ΣRGB > 8:

| shot | changed px | what actually changed |
|---|---|---|
| `ios-settings.png` | 32.6 % | **flat index → five-tab sheet**: a segmented `Picker` (通用 / 模型 / 插件 / 手机权限 / 预设) sits under the bar, 完成 moved from the top-**left** glass circle to the top-**right**, and the body is the 通用 tab's five cards (权限 / 语言·外观·字号 / 工作步骤 / 发送行为 / 版本·许可). The old rows 模型服务、MCP、后台运行、网页搜索、网络访问、插件与模型、命令、导出诊断 are gone. |
| `ios-chat-official.png` | 22.6 % | **the blank-transcript bug is fixed**: the official rich transcript renders (code block, `E = mc²`, literal HTML, 脚注, the 已编辑 6 个文件 card, the stats row `5 轮 17 步 · 54 tok/s · 1.0M tok · 缓存命中 75% · 10%`). The 2026-10-31 note "renders blank even after 12 s" is obsolete. |
| `ios-chat-queued.png` | 16.7 % | the **queue strip renders** above the composer (queued text + delete + send-now), which the old note recorded as absent; 已排队 stays under the bubble. |
| `ios-chat-*` (other 6) | 16–26 % | composer bottom spacing tightened (`86a39aac`) and the header's 运行中 dot+text became a **device glyph button** plus a grey `⋯` (that header band is byte-identical across two runs, so it is a real change, not capture noise). |
| `ios-sessions-*` (6) | 0.1–9.4 % | content identical, list shifted up ~18 pt because the ✕ left the cover; `sessions-default` also lost a divider-sized gap (0.4 % outside the corner). |
| `ios-files.png`, `ios-settings-plugins.png`, `ios-settings-model.png` | 0.4 %, 0.25 %, 0.35 % | identical content; the page sits ~10–14 pt higher (✕ removed) and the `settings-plugins` card edges moved with it. |
| `ios-settings-about / -network / -runtime / -search`, `ios-shell.png` | **0 px outside the ✕ box** | these five pages are pixel-identical to the 2026-10-31 set once the removed ✕ is excluded — the strongest available proof that the recapture reproduces the same pixels. |
| `ios-code-block.png` | 16.2 % | the swatch moved up ~10 pt with the ✕ gone; the block itself (font, colours, wrap at `…HorizontalScroll`) is unchanged. |
| `ios-chat-default.png` | 24.5 % | route `sample` boots the real host; the transcript varies **run to run** (two consecutive captures differ by 4.4 %). The header is stable. Keep using it for chrome, not for transcript content. |
| `ios-environment-home.png` | 0 % | carried over, not re-shot (see above). |

## Fixed conditions

| condition | value | how it is fixed |
|---|---|---|
| device | iPhone 16 Pro, UDID `4AAA363B-7B29-4415-9303-C692640BCF77` | `simctl create … com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro` |
| OS | iOS 26.5 (23F77) | only installed runtime |
| screen | 402 × 874 pt @ 3× = **1206 × 2622 px** | `simctl io enumerate`, `Default width/height` |
| appearance | **light** | `simctl ui <udid> appearance light`; the app also sets `.preferredColorScheme(.light)` |
| content size | **large** (default) | `simctl ui <udid> content_size large` |
| locale | **zh_CN / zh-Hans-CN** | simulator `AppleLocale` = `zh_CN`, `AppleLanguages` = (`zh-Hans-CN`, `en-CN`); all app copy renders in Simplified Chinese |
| status bar | **09:41**, wifi 3 bars, cellular 4 bars, battery 100 % charged | `simctl status_bar override --time "09:41" …` (verified with `status_bar list`) |
| build | Debug, simulator, `CODE_SIGNING_ALLOWED=NO`; DEBUG router enabled | `-uiPreview` is `#if DEBUG` only |
| launch | `simctl launch … -uiPreview <name>` with `SIMCTL_CHILD_PDSH_DEBUG_FORCE_NATIVE=1` | force the native shell instead of the Web surface |
| state reset | app uninstalled + reinstalled before every shot | `-uiPreview` persists drafts; a 5000-char draft leaked from `chat.draft` into later shots before this |
| settle | 3 s (simple pages), 4–6 s (chat transcripts) | animations and host-status changes |

Receipt: [`conditions.txt`](conditions.txt), regenerated by the capture script
and annotated with the HEAD sha, the strict build command and the ✕ finding.

## Manifest

All files are 1206 × 2622 px, light, zh_CN, status bar 09:41, **no DEBUG ✕**.
"How to reach" is the reproducible route; every one of them is a launch of
`dev.phone-dsh.probe` with `-uiPreview <name>` (fresh install + 1–6 s settle).
`state` names what the screenshot shows, not what the route is called.

| file | page | state | how to reach | notes |
|---|---|---|---|---|
| `ios-chat-default.png` | ChatPage | real shell, host running, sample thread + pending permission + question card | `-uiPreview sample` → NativeShell root, no cover | header = drawer glyph / 新会话 / **device glyph** / `⋯`; transcript varies run to run |
| `ios-chat-assistant.png` | ChatPage | empty host (未启动), one user bubble, tool row, code block | `chat.assistant` | composer disabled; no model name |
| `ios-chat-official.png` | ChatPage | official rich transcript | `chat.official` | **now renders** the rich transcript end to end (see the diff table) |
| `ios-chat-failed.png` | ChatPage | failed turn | `chat.failed` | red `没发出去 · 示例：这次回合失败了。` line under the last bubble, right-aligned |
| `ios-chat-queued.png` | ChatPage | queued message | `chat.queued` | `已排队` under the bubble **and** the queue strip above the composer (queued text / delete / send-now) |
| `ios-chat-long.png` | ChatPage | long thread | `chat.long` | long transcript + 5000-char draft |
| `ios-chat-draft.png` | ChatPage | empty host + 5000-char draft | `chat.draft` | composer at max height; the card is slightly taller than the 2026-10-31 shot after `86a39aac` |
| `ios-chat-permission.png` | ChatPage | two permission cards | `chat.permission` | standalone card screen |
| `ios-sessions-default.png` | SessionsPage | empty workspace, engine off | `sessions` | search field, 新建会话 disabled, 还没有工作文件夹 empty state + CTA |
| `ios-sessions-many.png` | SessionsPage | 40 sessions, 1 workspace | `sessions.many` | list rows / group header |
| `ios-sessions-empty.png` | SessionsPage | 0 sessions, 1 workspace | `sessions.empty` | empty state copy |
| `ios-sessions-nothing.png` | SessionsPage | 0 sessions, 0 workspaces | `sessions.nothing` | true empty |
| `ios-sessions-ungrouped.png` | SessionsPage | 3 sessions, no workspace | `sessions.ungrouped` | ungrouped section |
| `ios-sessions-error.png` | SessionsPage | read error | `sessions.error` | error line + retry |
| `ios-settings.png` | SettingsPage | default (**通用** tab) | `settings` | five-tab segmented picker; cards: 权限 / 语言·外观·字号 / 工作步骤·快捷键 / 发送行为 / 版本·许可 |
| `ios-settings-model.png` | ModelProviderSettingsPage | provider list (**模型** tab body) | `settings.model` | large title 模型服务, 服务 group, 默认 check, 读不到密钥 |
| `ios-settings-search.png` | WebSearchSettingsPage | search settings | `settings.search` | in-product: 插件 tab → 插件配置 → 网页搜索 |
| `ios-settings-network.png` | EgressAllowListPage | allow-all off, 15 hosts | `settings.network` | **preview-only**: no product entry since PR #13 |
| `ios-settings-plugins.png` | NativeConfigurationPage | session/plugin configuration | `settings.plugins` | in-product: 插件 tab → 插件配置 |
| `ios-settings-about.png` | SettingsAboutPage | about | `settings.about` | **preview-only page**: the product has no standalone About page |
| `ios-settings-runtime.png` | RuntimeDetailsPage | runtime details | `settings.runtime` | **preview-only route**; in-product the page is reached only from the chat header's device glyph (the settings 运行时 row is gone) |
| `ios-sessions-schedules.png` | NativeAutomationPage | scheduled tasks | `sessions.schedules` | in-product: the drawer's 定时任务 |
| `ios-workspace-folders.png` | WorkspaceFoldersPage | no folders | `workspace` | large title + 添加 + CTA |
| `ios-files.png` | FilesPage | empty workspace | `workspace.files` | large title + grey search + cube glass button |
| `ios-shell.png` | PDSHShellPage | command surface | `configuration` | in-product only from the workbench's second segment |
| `ios-code-block.png` | (not a page) | DSSCodeBlock swatch | `code.block` | supporting reference for the code block |
| `ios-environment-home.png` | — | springboard | no app launched | environment proof: 1206 × 2622, light, zh_CN, 09:41 (carried over) |

## Coverage

* **Captured:** 26 app screenshots + 1 environment proof.
* **Contract pages captured:** chat (8 states), sessions (6), files, settings,
  model-provider-settings, web-search-settings, egress-allow-list,
  native-configuration, settings-about (preview-only), runtime-details,
  native-automation, workspace-folders, pdsh-shell, code-block.
* **Reachable in-product but with no `-uiPreview` name (this script cannot shoot
  them):** `native-agent-presets`, `native-plugin-inventory`,
  `phone-permissions` (`settings.permissions` exists but the 27-state list is
  frozen), `native-shortcuts`, `session-artifacts`, `native-device-connection`,
  `native-device-session`, `native-workbench`, `mcp-settings`, `mcp-editor`.
  Capturing them needs new `PreviewScreen` cases (an iOS source change, out of
  this lane) or XCUITest taps.
* **Unreachable at all** (no product control, no preview name; audited in
  `REACHABILITY.md`): `session-activity`, `memory`, `probes`, `background`,
  `task-screen`, `daily-brief`, `export`, `chat-preferences`,
  `native-settings-document`.

## Reproduce

```bash
# 1) strict HEAD build + 26 shots (the script fails loudly if HEAD does not build)
PDSH_CAPTURE_OUT=/tmp/pdsh-baseline-$(date +%Y%m%d) \
  bash android/tools/ios-baseline-capture.sh

# 2) copy in (see the note below for why the script cannot write here directly)
cp /tmp/pdsh-baseline-$(date +%Y%m%d)/*.png docs/receipts/ios-baseline-screens/
```

`simctl io screenshot <udid> docs/receipts/…/ios-settings.png` fails on this
machine with `NSCocoaErrorDomain 513 … You don't have permission to save the
file … in the folder "ios-baseline-screens"` (`EPERM`): the existing PNGs carry
`com.apple.provenance` and the simulator service is not allowed to overwrite
them. Capturing into `$TMPDIR` and copying the bytes in is not a workaround with
a visual cost: `ios-settings-about / -network / -runtime / -search` and
`ios-shell` come out **0 pixels** different outside the removed ✕, and
`ios-environment-home.png` diffs to 0.

## Validation

* Build: `** BUILD SUCCEEDED **` at `86a39aac`, strict, no shim (log:
  `$TMPDIR/pdsh-ios-baseline/build.log`).
* Determinism: the five static settings pages above are pixel-identical to the
  previous batch outside the ✕; `ios-chat-default.png` is the only state that
  varies (real host + sample thread), ±4.4 % between runs.
* Names: 27 files, unchanged; `ParityStates.kt` still resolves all of them.
