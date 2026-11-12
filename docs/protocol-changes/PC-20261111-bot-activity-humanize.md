<!-- SPDX-License-Identifier: MIT -->

# 活动行、工具行与抽屉状态行的人话化（P09）

```yaml
change: PC-20261111-bot-activity-humanize
contracts: [P09]
status: implemented
breaking: false
version_decision: "P09 presentation only: the activity line, Bot chat tool rows and drawer status line use existing runtime facts; no wire frame, event, row, schema, enum value, persisted field or version field is added or changed. The same bundle renders the same data with human-readable phrases, and raw tool names remain available through the existing accessibility/detail surfaces."
base: de47c0ee
contract_revision: spec/ui/v1/pages/bot-chat.md@ui-activity-humanize-v1 (worktree, not committed)
```

Protocol impact: P09; P27: none — 只改 iOS 的活动行/工具行/抽屉状态行展示和 P09 页面契约；`tool/call`、`tool/result`、`BotActivity`、`BotRosterRuntimeState` 与卡片 row 的字段、值域、动作和持久化格式均未变；没有第二个 envelope、别名字段或版本变化。

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 活动行把 `job_id`、`agent_id`、`task_id`、`routine_id`、`device_id`、`request_id`、Android `package`/`permission`、`RequestApproval.action` 直接拼进「 · 目标」；`bash`/`android_shell`/`android_command_help` 说「命令」，`job_list` 说「后台」，`botvolatilecontext` 说「上下文」，`android_logcat` 说「日志」，`task`/`awaittask`/`stopsubagent` 说「委派」「子代理」，`sendtoagent`/`createteammate` 说「队友」，`listroutines` 说「例行」，BLE 说「设备能力/调用/取结果」。抽屉状态行缺少契约要求的「 · N 分钟」后缀。Bot 聊天工具行在截图夹具里显示 `bash`、`mcp__phone__ReadMemory` 等原始工具名。截图图库副标题带 `FishAction` 工具名。期望：活动行只显示普通人能读懂的动作和人类可读目标；抽屉与聊天行共用分钟后缀；Bot 工具行使用宿主已有的 zh 动作名；图库副标题不再暴露工具名。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `ui-activity`（分支 `ui/activity-line`，worktree 基于 `de47c0ee`）兼任四角色：先改 P09 页面契约，再改 iOS 展示层、夹具和测试，并跑检查与 light/dark 截图。
- **Owning contract / schema / fixtures.** P09：`spec/ui/v1/pages/bot-chat.md` 的活动行目标与工具行；`spec/ui/v1/pages/bot-drawer.md` §2 已写明分钟后缀，本轮只补实现，不改契约文字。无 schema/golden 变化。
- **受影响 producer / consumer.** iOS `examples/probe-app/PhoneDSHProbe/Bot/` 与共享 ChatPage 工具行：`BotActivityPhrases.swift`、`BotDrawer.swift`、`BotChatPage.swift`、`NativeToolDetailCards.swift`、`ChatPage.swift`、`BotFixtures.swift`、`BotFishGallery.swift`、`scripts/ci/bot-ui/CaptureDependencies.swift`；测试 `scripts/ci/bot-e2e/app/TestsChatModel/BotActivityLineTests.swift`。Android/HarmonyOS 无 Bot runtime，不跟进。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| 活动行目标 | 契约只写「文件名/搜索词/网站域名」→ 收紧为只允许人类可读值（文件名、搜索词、网站域名、任务标题、Bot 名字、例行任务标题、设备显示名），明确内部 ID、Android 包名/权限和审批 `action` 不进入目标，没有人类可读值就不加目标 |
| 活动行动作短语 | 出现「命令/Shell/后台/上下文/日志/委派/子代理/队友/例行」等机制词 → 改成普通用户能懂的动作，并与 `BotUIFormat`/`BotToolEffects` 的既有「子任务」「协作 Bot」「例行任务」词汇一致 |
| Bot 聊天工具行 | 截图夹具显示原始工具名 → 标题复用 `BotToolEffects` 的 UI 卡片 zh label（「询问用户」「显示进度卡片」等）或 `BotActivityPhrases` 的动作短语（「在电脑上操作」「在翻文件」等），未知工具显示「工具操作」；原始工具名只留在 accessibility identifier/展开详情 |
| 抽屉状态行 | 契约要求「同一活动超过 60s 追加 · N 分钟」，实现缺失 → 复用 `BotActivityPhrases.sustainedMinutes` 和共享后缀函数；运行中每 30 秒刷新一次，跨分钟不滞后超过半分钟 |
| 截图图库副标题 | `FishAction · 一次性动作 / 表情` → `一次性动作 / 表情`（capture-only 页面） |
| 生成契约行号 | `ChatPage.swift` / `NativeToolDetailCards.swift` 源码行号因新增参数和注释平移 → `extract_ios_pages.py` 与 `tokens.json` provenance 同步更新，页面结构/动作集合无变化 |

自检：没有新增第二种表达；目标只来自既有 `tool/call` 参数里的人类可读字段；未知值仍走现有 generic 文案；原始工具名仍可从 `ChatItem.toolName`/展开详情取得；旧数据无需迁移。

## 3. 兼容性

| Producer → Consumer | 支持／拒绝方式及理由；对应测试 |
| --- | --- |
| old → new | 不适用：同一 App bundle 内的展示层变化，无跨进程/持久化格式变化。旧 `BotActivity` 数据继续按 `category` 和 `detail` 渲染；旧工具行如果没有 `toolName` 会显示「处理结果」而不是原始标题。 |
| new → old | 不适用：未新增或修改任何 wire/持久化字段；回滚只影响展示文案。 |
| new → new | 活动行、抽屉、Bot 工具行和截图夹具使用同一 `BotActivityPhrases` 表；UI 卡片工具名来自同一个 `BotToolEffectClassifier`，没有第三套映射。 |
| persisted old data → new／rollback | 活动/工具事件和 row payload 格式不变，旧记录直接显示；`BotRosterRuntimeState.activity` 字段不变。 |

- 版本／adapter 决定：无版本变化；P09 页面呈现修订，复用 `pdsh.ui.page-structure/1`。
- bundle／image／native artifact 更新顺序：不涉及；无 Worker 或插件资产变化。

## 4. 分工与证据

- Implementer 路径：`spec/ui/v1/pages/bot-chat.md`、`spec/ui/v1/pages/{chat,runtime-details}.json`、`spec/ui/v1/tokens.json`、`docs/protocol-changes/PC-20261111-bot-activity-humanize.md`、`examples/probe-app/PhoneDSHProbe/{ChatPage.swift,NativeToolDetailCards.swift,Bot/BotActivityPhrases.swift,Bot/BotDrawer.swift,Bot/BotChatPage.swift,Bot/BotFixtures.swift,Bot/Fish/BotFishGallery.swift}`、`scripts/ci/bot-ui/CaptureDependencies.swift`、`scripts/ci/bot-e2e/app/TestsChatModel/BotActivityLineTests.swift`。
- 共享 fixtures：`BotUIFixtureCase.runningTool` / `runningToolPhone` / `runningToolDescribed` / `runningToolReviewing` / `drawer`；drawer 夹具的活动起点设为 65 秒前，截图同时覆盖分钟后缀。`scripts/ci/bot-e2e/harness/Sources/BotEvalApp/BotActivityPhrases.swift` 仍是指向 probe 版本的 symlink，未单独修改。
- 各端真实 producer／consumer 测试：iOS 模拟器构建、`BotActivityLineTests` 和 `capture.sh` 的 light/dark 截图；Android/HarmonyOS 不适用。
- Exact commands → `PASS／FAIL／SKIP／INCOMPLETE／NOT_RUN`：
  - `python3 spec/ui/v1/tools/extract_ios_pages.py --root .` → PASS（46 pages, 180 sections, 531 rows, 377 actions；只更新 chat/runtime-details 的行号与 source.lines）。
  - `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS（6 files、13 contrast pairs、6 deferred AA pairs、1 unmeasured token、0 unmeasured surface items、51 geometry tokens）。
  - `python3 -m unittest discover -s spec/ui/v1/tools -p 'test_*.py'` → PASS（207 tests, OK）。
  - `python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` → FAIL（7 new divergences outside baseline，仍为既有 connected-computer 1、files 1、home-drawer 2、pc-pairing 1、settings 2；没有新增 Bot 差异，按 ui-common 记为通过）。
  - `CI_PROTOCOL_BASE=de47c0ee bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS（phone-spec 13s、238 tests OK；phone-cross-tree 19s、98 tests OK）。
  - `cd scripts/ci/bot-e2e/app && xcodegen generate && xcodebuild test -project BotE2E.xcodeproj -scheme BotE2EApp -destination 'platform=iOS Simulator,id=A8C95B95-1EC3-4F77-806E-B86A388D3A16' -derivedDataPath /tmp/ui-activity-e2e-dd -only-testing:BotActivityLineTests CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` → FAIL。未改 scheme 时先被无关的 `BotE2ETests` 目标挡住（`BotProductionServices.swift` 找不到 `BotUIFormat`，与本次改动无关）；从生成 scheme 移除该目标后 `BotActivityLineTests.xctest` 编译成功，但 runner 启动被沙箱拒绝：`Pseudo Terminal Setup Error` / `Operation not permitted`，未执行到用例。
  - 临时 SwiftPM 包跑同一份 `BotActivityLineTests.swift` → PASS（22 tests, 0 failures；在 macOS SwiftPM 测试 target 中直接编译同一份测试和三个展示源文件）。
  - `cd examples/probe-app && xcodegen generate` + `xcodebuild build -project PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ui-activity-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` → PASS（`** BUILD SUCCEEDED **`；只有既有 warning）。
  - `HOME=/tmp/ui-activity-e2e-home CFFIXED_USER_HOME=/tmp/ui-activity-e2e-home TMPDIR=/tmp/ui-activity-e2e-tmp BOT_UI_SKIP_UI_TESTS=1 bash scripts/ci/bot-ui/capture.sh --appearance light,dark --device A8C95B95-1EC3-4F77-806E-B86A388D3A16 --out /tmp/ui-activity-shots` → PASS（`** BUILD SUCCEEDED **`；90 screenshots；manifest `status=PASS`、`conformance=PASS`；XCUITest 交互测试按环境 NOT_RUN，截图由 simctl 采集）。已逐张检查 light/dark 的 `runningTool.png`、`runningToolDescribed.png`、`runningToolPhone.png`、`runningToolReviewing.png`、`runningThinking.png`、`drawer.png`、`chat.png`、`gallery.png`、`task.png`：无原始工具名、无内部 ID，drawer 显示「在电脑上操作 · 1 分钟」，gallery 副标题为「一次性动作 / 表情」。
- 剩余风险、未支持平台：真机未跑；只有模拟器截图，不能据此声称真机像素/触控证据；Android/HarmonyOS 无 Bot 页；动态字体、VoiceOver 未覆盖；生产模型若把内部 ID 放进 `description`/`summary`/`label`，活动行仍会显示模型写的这句（契约只约束工具目标，不审查模型自然语言）。

## 5. 修订记录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | ui-activity | 初版：活动行目标与短语人话化、Bot 工具行统一动作名、抽屉分钟后缀、图库副标题去工具名 | iOS；P09 reviewer |
