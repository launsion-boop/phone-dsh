# Android PR22 alignment — baseline audit (00)

Status: **AUDIT COMPLETE — CANDIDATE UNACCEPTED**
Prepared tree: `aa2e1aa` (candidate changes pinned in `9f09ef1`)
PR14 base: `8c2eeab7b29728ebd0a54b71b5deaab07e5ac6eb`
PR22 authority: `edd687463cd24b9c969914a13fa1da268df016fe`
Shared main: `45de1121ee8b6df4323609ae45e66caa0d0fe29a`
Date: 2026-11-02. Host: Linux/Debian 12, no Mac, no attached Android device.

This receipt audits the prepared tree. It does **not** accept it. Old Android
receipts, screenshots and green historical builds are history, not proof of this
baseline. No source was fixed outside the five assigned paths.

## 1. What the prepared tree actually is

- `git merge-base HEAD 8c2eeab7…` is `8c2eeab7…`, so the working tree is built on
  the PR14 line. The Android delta against PR14 is **66 files, 7047 insertions,
  1162 deletions** (`git diff --stat 8c2eeab7..HEAD -- android`). That delta
  includes the stopped candidate and later shared-main merges; it is not all UI
  port work.
- The candidate changes are pinned in `9f09ef1`; the iOS reference sources and
  lifecycle files are pinned in `aa2e1aa`. Shared main `45de112` is an ancestor
  of the tree, so the PR17/18/20 runtime fixes are present.
- **The PR22 commit object is not in this clone.** `git cat-file -t
  edd687463…` fails. The authority used here is the pinned
  `examples/probe-app` tree (27 `*Page.swift` files + `HomeDrawer.swift` +
  `HomeSpec.swift`) and `docs/design/ios-home-design-spec-no-overview.html`,
  exactly as the Fleet baseline declares. Byte-identity to PR22 is therefore a
  baseline claim, not something this audit could re-derive from Git.
- Scale: 370 production Kotlin files, 13 Gradle modules, 76 `:lib` JVM test
  files, 17 `:app` JVM test files, 58 instrumented test files and 902 `@Test`
  annotations. A large amount of code is present; presence is not acceptance.
- `.github` is absent (maintainer deletion `8ee772b`), and this audit did not
  recreate any workflow. No git operation was performed.
- The old 402pt parity material still exists (`docs/receipts/android-chat-parity`,
  `docs/receipts/ui-parity-sheet`, screenshot baselines, capture scripts). It is
  history under the new 430x932 authority and is not used as proof here.

## 2. Provenance map published with this audit

`docs/design/android-pr22-source-map.json` (schema
`pdsh.android-pr22-source-map/1`, 80 entries) maps:

- all 27 PR22 `*Page.swift` files, including private settings subpages declared
  inside `SettingsPage.swift` and `NativeShell.swift`;
- `HomeDrawer.swift`, `HomeSpec.swift` and all eight design-spec sections;
- the six signature surfaces (`bubble`, `toolRow`, `thinkingPill`,
  `approvalCard`, `composer`, `failLoudBanner`);
- settings subpages, schedule surfaces, device/files/workbench surfaces and the
  host/runtime seams the UI reads.

Status counts: **35 implemented-on-candidate, 38 partial, 6 missing, 1
unverifiable**. “implemented-on-candidate” means a surface exists with anchors
and tests; it does not mean the surface is accepted or visually equal to PR22.

`android/tools/test_android_pr22_source_map.py` validates the schema, status
enum, every anchor/path, page/drawer/HomeSpec/design-section coverage and the
absence of absolute machine paths.

## 3. Concrete defects (candidate, not accepted)

### 3.1 Product structure and navigation

| id | defect | evidence |
|---|---|---|
| A1 | **The product home is the sessions list, not PR22 ChatPage.** PR22 mounts `ChatPage` as the home and `HomeDrawer` as its overlay; Android's `HostHomeScreen` renders `HostSessionsScreen` and pushes `ChatPage` as a route. | `examples/probe-app/PhoneDSHProbe/NativeShell.swift:114`; `android/app/src/main/kotlin/com/phonedsh/probe/HostShell.kt:469-478`; `HostSessionsScreen.kt:264-306` |
| A2 | **The drawer is the pre-PR22 one.** `PdshDrawer` is a session-list body plus 定时任务/设置 rows; PR22 `HomeDrawer` has the white entries card (新会话/定时任务), 文件夹 section with 日常 default, folder create/edit, long-press rename/archive, archived toast and a settings bar. | `HomeDrawer.swift:12-170`; `android/lib/src/main/kotlin/com/phonedsh/ui/nav/PdshDrawer.kt:1-164` |
| A3 | **Settings is still the five-tab sheet.** PR22 renders one grouped phone-settings `List` (模型与智能体 / 权限与隐私 / 对话 / 会话与文件 / 引擎 / 关于). Android's own KDoc says “the five-tab picker, then the selected tab's body” and still draws the segmented picker. | `SettingsPage.swift:61-143`; `android/lib/src/main/kotlin/com/phonedsh/ui/page/SettingsPage.kt:1,995,1069` |
| A4 | **Settings subpages are missing or folded away.** PR22 has standalone `FontSizeSettingsPage` (three roles + font family), `ConversationSettingsPage`, `ArchivedSessionsPage` and `LicensesPage`; Android has only the two legacy font steppers, folds work-process controls into 通用, has no archived page and explicitly has no licenses page. | `SettingsPage.swift:229,267,316,408`; `ChatPreferencesPage.kt`; `AboutPage.kt` (no LicensesPage); map entries `subpage-*` |
| A5 | **The chat header menu is incomplete.** PR22 exposes 子智能体(n), 后台任务(n), 定时任务(n), 本会话产物, 工作面板, 本会话设置 and 插件与工具. Android only adds jobs/schedules rows when their lists are non-empty, has no subagent entry and no 插件与工具 entry. | `ChatPage.swift:285-314`; `android/lib/src/main/kotlin/com/phonedsh/ui/page/ChatPage.kt:618-640` |
| A6 | **后台任务 is unreachable because the host never fills `ChatSubpageFacts.jobs`.** `HostShell` fills `schedules` but not `jobs`; `jobRows == null` suppresses the row. The sheet and route exist, but the product cannot reach them. | `ChatPage.kt:619`; `HostShell.kt:507-518`; `ChatPage.kt:3392-3397` |
| A7 | **The subagent catalog is absent.** PR22 opens `NativeSubagentCatalogSheet` from the chat header; no Android equivalent symbol or route was found. | `NativeSubagentCatalogSheet.swift:71`; whole-tree search for `NativeSubagentCatalogSheet` in Android returns nothing |
| A8 | **Session activity is dev-tools-only with empty facts.** `SessionActivityPage` is rendered by `DeveloperToolsSurface` with `SessionActivitySource()` (no data); the PR22 chat-menu entry is missing, so the eight real sections cannot be seen in the product flow. | `PdshNavHost.kt` has no activity route; `SettingsSurfaces.kt:352-354` |
| A9 | **No PR22 default 日常 folder grouping.** `SessionsPage.kt` has ungrouped and workspace sections but no `日常`/default-folder title or grouping path; PR22 groups unfiled sessions under 日常. | `SessionsPage.swift:43-53`; `HomeDrawer.swift:233-299`; no `日常` literal in `SessionsPage.kt` |

### 3.2 Design system (root cause across pages)

| id | defect | evidence |
|---|---|---|
| B1 | **The shared frame is still 402x874pt.** `UiMetrics` owns `BASELINE_WIDTH_PT=402`, `BASELINE_HEIGHT_PT=874`; no 430x932 constant exists anywhere in Android. The PR22 spec is 430x932 with content width 390. | `UiMetrics.kt:57-60`; design spec `#intro`, `#grid`; `HomeSpec.swift` |
| B2 | **HomeSpec is not the Android token source.** No `HomeSpec`-equivalent object exists; pages read `ChatMetrics`/`UiMetrics`/`spec/ui/v1/tokens.json`, whose values mirror the older 402pt iOS tokens. | `HomeSpec.swift`; `ChatMetrics.kt` header; `UiTokens.kt` |
| B3 | **Type is 17pt, not PR22 16/24.** `tokens.json` `typography.body.baseSize` is 17, while PR22 body is 16/24. | `spec/ui/v1/tokens.json` typography.body; `HomeSpec.swift` `bodySize/bodyLine` |
| B4 | **Bubble geometry/fill differ.** Android draws `RoundedCornerShape(radius.bubble=20)` on all four corners and fills `colors.userBubble` (#EDF3FE in the token set). PR22 draws radius 24 with the top-trailing corner square and fill #E8E8E8. | `Bubble.kt:168`; `tokens.json` radius.bubble=20; `HomeSpec.swift:78-96`; `ChatPage.swift:3904` |
| B5 | **Composer radius is 28, not 24; HomeSpec sizes absent.** PR22 composer min 104, send 36, icon 24, radius 24. | `Composer.kt:153`; `tokens.json` radius.composer=28; `HomeSpec.swift:71-80` |
| B6 | **Page/list radii and spacing are legacy.** PR22 list card r18 / nav r22 / block 20 / paragraph 16 / disclosure 8; Android still uses `radius.card=12` and flow gaps 6/12/16. | `tokens.json` radius; `ChatMetrics.kt` FLOW/RESPONSE/TURN gaps; design spec `#space`, `#shape` |

### 3.3 Functional binding and honest limitations

| id | defect | evidence |
|---|---|---|
| C1 | **Model provider has no 获取模型 flow and no 高级设置.** PR22's editor fetches the model catalog, shows fetch errors, supports manual models, context/output/reasoning fields and a test-connection path. Android has a test seam but no fetch-models call, no advanced page, and different field copy (显示名称/服务 URL vs 名称/API 地址). | `ModelProviderSettingsPage.swift:373-592`; `ModelProviderSettingsPage.kt:1084-1200`; missing literals include 获取模型/高级设置/API 地址 |
| C2 | **Web search is read-only on this host.** `HostNavFacts` sets a read-only reason and no `SetWebSearchEnabled`/`SelectWebSearchBackend` handler exists in `:app`; save/mode switching cannot complete. | `HostNavFacts.kt:227`; `HostShell.kt:831-832` only labels the action, no handler |
| C3 | **Shell run is refused.** `RunShellCommand` answers “本宿主没有调用 exec 桥的命令，本次未运行”; the PR22 run/stop/progress path is not executable. | `HostShell.kt:674-675` |
| C4 | **Export is refused.** The export route note says the host has no export command; the page can only render facts. | `HostShell.kt` `PdshRoute.Export` note |
| C5 | **MCP save is refused.** No `phone/mcpUpsert` host tool; the editor's save cannot land. | `HostShell.kt:704-705`; `MCPSettingsPage.kt` |
| C6 | **Shortcuts lack per-action capture/conflict validation.** PR22 has 按键, 保存快捷键 and conflict copy; Android has the reference/reset surface only. | `NativeShortcutsPage.swift`; missing literals 按键/保存快捷键/冲突 in `NativeShortcutsPage.kt` |
| C7 | **Configuration page is missing the subagent/auto-exec/terminal blocks.** 38 PR22 Chinese literals are absent, including 子 Agent 模型, 自动执行轮次, 终端, 最大递归层级, 并行工具调用上限. | `NativeConfigurationPage.swift:89-107`; `NativeConfigurationPage.kt` |
| C8 | **Chat queue strip is read-only.** Android renders queued messages but has no edit/delete/steer actions from the strip (the sessions page has a separate queue editor). | `ChatPage.kt:2261,2564`; PR22 `ChatPage.swift:1610-...` QueueDock |
| C9 | **No product demo data found, but a stale comment claims it.** `HostShell.kt` says the device routes read an in-memory double; the app actually passes no `DeviceConnectionSource`, so the product shows the honest “no connector” empty state. The stale “演示数据” route text is misleading and should be removed with the future real connector. | `HostShell.kt:924-929`; `PdshNavHost.kt` `deviceConnectionSource: DeviceConnectionSource? = null`; no `InMemoryConnector` in `:app` main |
| C10 | **Rule-triggered host actions are honest refusals, not fake successes.** The generic `handleHostAction` returns a specific “no command” line for unbound actions and never claims a write landed. This is the right failure mode, but it means several PR22 actions are not implemented. | `HostShell.kt:626-710` |

### 3.4 Spec / contract and test defects

| id | defect | evidence |
|---|---|---|
| D1 | **`ui_check` fails on README page inventory.** README misses `ArchivedSessionsPage`, `ConversationSettingsPage`, `FontSizeSettingsPage` — the three PR22 pages added to `SettingsPage.swift`. | `python3 spec/ui/v1/tools/ui_check.py --root .` → FAIL, 1 failure |
| D2 | **All page contracts are stale for 25 pages.** `extract_ios_pages.py --check` reports stale contracts for chat, runtime-details, daily-brief, files, mcp-settings, mcp-editor, model-provider-settings, model-provider-editor, native-agent-presets, native-automation, native-configuration, native-device-connection, native-plugin-inventory, workspace-folders, egress-allow-list, settings-about, native-shortcuts, native-workbench, pdsh-shell, phone-permissions, session-activity, session-artifacts, sessions, settings, web-search-settings. | `python3 spec/ui/v1/tools/extract_ios_pages.py --check` → exit 1 |
| D3 | **`page_structure_check` fails before it can report its ratchet.** The chat contract's anchors no longer match PR22 `ChatPage.swift:2090/2125/2172/2198` (e.g. `Section("暂不可用")` now resolves to `} label: {`). | `python3 spec/ui/v1/tools/page_structure_check.py --baseline spec/ui/v1/pages/_baseline.json` → FAIL |
| D4 | **The checker's own test fails on the same stale contract.** `test_every_repo_page_runs_independently` raises the stale-contract `CheckError`. | `python3 -m unittest spec.ui.v1.tools.test_page_structure_check -v` → 73 tests, 1 error; `test_page_structure_check.py:763` |
| D5 | **README inventory gate is narrower than the source.** `ui_check` scans every `*Page` struct including private ones; the pinned PR22 `SettingsPage.swift` added three private pages and the README was not updated. This is a docs/contract defect, not proof that the Android pages exist. | `spec/ui/v1/tools/ui_check.py` page inventory; `SettingsPage.swift:229,267,316` |
| D6 | **The candidate's own KDocs cite the pre-PR22 iOS HEAD.** Multiple page headers say “at iOS HEAD 86a39aac (PR #13)” (e.g. `SettingsPage.kt`, `NativeDeviceSessionPage.kt`, `SessionArtifactsPage.kt`, `WebSearchSettingsPage.kt`). PR22 is `edd6874`; where those pages changed, the Android mirror is stale by construction. | grep `86a39aac` under `android/lib/src/main/kotlin/com/phonedsh/ui/page` |
| D7 | **The required Gradle command fails during configuration because `:app` still configures and needs the absent Worker bundle.** `-Ppdsh.uiCoreOnly=true` narrows `:lib`'s API edge but does not skip `:app` configuration, so `:app/build.gradle.kts:31` aborts with “the prebuilt worker bundle is missing: examples/probe-app/Bundle/worker”. | `cd android && ./gradlew -Ppdsh.uiCoreOnly=true :lib:testDebugUnitTest --no-daemon --max-workers=2` → BUILD FAILED in 5m44s |
| D8 | **The documented `--configure-on-demand` UI-only equivalent configures `:lib` and runs the suite: 776 tests, 5 failed, 771 passed.** The first run of this equivalent failed 506 tests before executing product assertions because Robolectric tried to create its download lock in the read-only container home directory. With a task-local `user.home` and a pre-populated `android-all-instrumented` jar, the suite ran to completion. | `cd android && JAVA_TOOL_OPTIONS=-Duser.home=<task-local-home> ./gradlew --configure-on-demand -Ppdsh.uiCoreOnly=true :lib:testDebugUnitTest --no-daemon --max-workers=2` → 776 tests, 5 failed |
| D9 | **`PdshReachabilityTest.the_automation_route_is_a_sheet_and_exposes_the_catalog_bar` fails.** Expected `[RefreshAutomation]`, got `[]`: the automation route does not expose the catalog-bar refresh action the test contract requires. | `PdshReachabilityTest.kt:112` (failure; `PdshReachabilityTest.kt:111` call) |
| D10 | **`ChatPageTest.slash menu supports arrow tab enter and escape while command picks update the draft` fails.** `IllegalStateException: Cannot call setContent twice per test!` at the test's second `show()`; this is a test-harness/recomposition defect, not an assertion about the page. | `ChatPageTest.kt:627` → `show()` at `:820` → `setContent` at `:854` |
| D11 | **`ModelProviderSettingsPageTest.connection test progress and failure stay inline without closing or replacing the editor draft` fails.** `IllegalArgumentException: Required value was null.` — the expected editor/connection-test node is absent at the assertion. | `ModelProviderSettingsPageTest.kt:120` |
| D12 | **`ModelProviderSettingsPageTest.failed save keeps the exact editor draft and shows the host reason inline` fails.** `The component is not displayed!` at the inline host-reason assertion. | `ModelProviderSettingsPageTest.kt:384` |
| D13 | **`PageTokenReferenceTest.each page declares exactly the tokens its source reads` fails for `WorkspaceFoldersPage.kt`.** The page's declared token inventory and the tokens the gate derives from its source do not match: one side names `colors.input` / `typography.rowLabel` / `typography.subheadline`, the other names `geometry.statusDotDiameter` and omits those three. The owning page lane must reconcile the inventory with the reads; the gate is correctly red. | `PageTokenReferenceTest.kt:92`; failure message names `WorkspaceFoldersPage.kt` |

Compilation itself succeeded: `:lib:compileDebugKotlin` and
`:lib:compileDebugUnitTestKotlin` produced one main-source warning
(`ChatRows.kt:590`, “Condition is always 'false'”) and three deprecation warnings
in `SessionArtifactPreviewPageTest.kt`, with no unresolved import or renamed
source. The five red tests are runtime assertion/harness failures (D9-D13), not a
compile failure; that distinction is why they are listed individually.

## 4. Commands actually run (evidence, not acceptance)

All commands were run from the repository root unless `cd android` is shown. Red is
evidence; it is never reported as PASS.

| # | command | exit | result |
|---|---|---|---|
| 1 | `python3 spec/ui/v1/tools/ui_check.py --root .` | 1 | FAIL: README inventory misses 3 PR22 pages |
| 2 | `python3 spec/ui/v1/tools/extract_ios_pages.py --check` | 1 | FAIL: 25 stale page contracts |
| 3 | `python3 spec/ui/v1/tools/page_structure_check.py --baseline spec/ui/v1/pages/_baseline.json` | 1 | FAIL: stale chat anchors |
| 4 | `python3 -m unittest spec.ui.v1.tools.test_ui_check` | 0 | 28 tests OK |
| 5 | `python3 -m unittest spec.ui.v1.tools.test_extract_ios_pages spec.ui.v1.tools.test_page_structure_check` | 1 | 86 tests, 1 error (`test_every_repo_page_runs_independently`) |
| 6 | `python3 android/tools/structure_check.py` | 0 | 11 PASS, 1 SKIP (16 KB .so artifact absent) |
| 7 | `python3 android/tools/test_structure_check.py` | 0 | 21 tests OK |
| 8 | `python3 android/tools/test_android_pr22_source_map.py` | 0 | provenance gate (80 entries) |
| 9 | `cd android && ./gradlew -Ppdsh.uiCoreOnly=true :lib:testDebugUnitTest --no-daemon --max-workers=2` | 1 | BUILD FAILED at configuration: `:app/build.gradle.kts:31` missing Worker bundle |
| 10 | `cd android && JAVA_TOOL_OPTIONS=-Duser.home=<task-local-home> ./gradlew --configure-on-demand -Ppdsh.uiCoreOnly=true :lib:testDebugUnitTest --no-daemon --max-workers=2` | 1 | 776 tests, 5 failed, 771 passed; failures D9-D13 |
| 11 | same as #10 without the task-local `user.home` / pre-populated Robolectric jar | 1 | 776 tests, 506 failed, all `FileNotFoundException: .robolectric-download-lock` (environment, not a product assertion) |

Environment: task-local Microsoft OpenJDK 17.0.21, Android SDK 35
(platforms;android-35, build-tools;35.0.0), Gradle 8.13, `GRADLE_USER_HOME`
outside the repo. Full stdout/stderr is retained in a task-local run log for this audit; the
commands are reproducible without credentials.

## 5. What this audit did not do

- Did not fix another lane's files, including the stale spec/README or the
  home-routing defect. The assignment allows only the five receipt/map/tool paths.
- Did not run Xcode, an iPhone, an Android emulator/device, an installed-App
  capture, a real provider, or the app build with the real Worker bundle/JNI.
- Did not restore `.github` workflows.
- Did not stage or commit generated test caches.
- Did not accept the candidate, any page, any screenshot or any host action.

The accompanying `00-known-limitations.md` records the NOT_RUN list, the
toolchain evidence and the CI deletion policy.
