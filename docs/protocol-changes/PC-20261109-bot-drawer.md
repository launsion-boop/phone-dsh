<!-- SPDX-License-Identifier: MIT -->

# Bot 列表侧边栏、添加/管理对话框与实时反应接线（P09/P26/P27）

```yaml
change: PC-20261109-bot-drawer
contracts: [P09, P26, P27]
status: implemented
breaking: false
version_decision: No wire, schema, durable-event or library API change. The app now renders the already-shipped BotRosterModel through NativeShell's existing drawer, calls the existing create/select/setMain/setHidden/delete APIs, registers the existing FishAction host tool, and feeds live DSH frames through the existing BotFishDirectorEventMapper. P26 volatile-context JSON is unchanged.
base: fd7d87632122ecae1613e8a9b2c15b84f72f50fa
contract_revision: docs/protocol-changes/PC-20261109-bot-drawer.md@drawer-v3
```

Protocol impact: P09 — Bot roster drawer, add/manage dialogs, live reactions wiring; P26: none — app passes existing teammates/description closures, library contracts unchanged; P27 — FishAction hidden from app process rows (existing display contract).

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 第 2 波已经交付 `BotRosterModel`、每 Bot runtime unit、`BotProductionHub`、`FishAction` 执行面与 `BotFishDirectorEventMapper`，但 App 只有一个 Bot 页面，没有侧边栏入口：用户无法看到多 Bot 列表、未读、实时头像、隐藏 Bot，也不能创建/改名/设主/隐藏/删除；`FishAction` 没有注册，live `textDelta` 和失败 turn 也没有进入 director，`FishAction` 仍会以普通工具行出现在过程列表。期望：Bot tab 用与任务 tab 相同的抽屉机制显示 Bot 列表，添加/管理走真实 API，所有头像消费同一 reaction/lifecycle，DSH 页抽屉和截图不变。
- **Coordinator / contract owner / implementer / reviewer-integrator:** `bm-drawer` 单元（本工作树）。Owning contract：P09 页面行为、P26 既有 volatile-context seam、P27 既有显示契约；本单元**不修改** `spec/bot/**`、`Sources/PhoneDSHBot/**`、插件或 `Bot/Fish/**`。
- **Affected ends:** 只有 iOS probe app 的 `Bot/**`（除 `Bot/Fish/**`）、`NativeShell.swift` 的 Bot tab 承载、`scripts/ci/bot-ui/**` 和 `spec/ui/v1/**`。没有 Worker、Kotlin/Rust/Android、wire、schema 或 golden 变化。
- **Base / head:** `fd7d87632122ecae1613e8a9b2c15b84f72f50fa` / 本单元工作区（按沙箱要求未提交）。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| Bot 列表入口 | Bot 页头部无入口 → 44pt 左上角圆形按钮，label「打开 Bot 列表」，复用 `NativeShell` 的 320pt 抽屉/遮罩/左滑/宽屏常驻；任务 tab 仍显示现有 `HomeDrawer`，离开 Bot tab 关闭 |
| 列表数据 | 无 UI → `BotRosterModel.visibleEntries`（主 Bot 置顶、隐藏排除、插入顺序）驱动行；每行 38pt 实时 `BotFishView(state:appearance:crowned:reaction:)`、名字、状态、未读角标、选中高亮 |
| 添加 | 无 → `BotAddDialog` 名字 + 发型 + 颜色，默认 long/blue；名字在 binding setter 中按字素簇安全截断到 ≤ 60 UTF-16 单元（输入/粘贴同路径），输入框下方无任何校验或字数提示；去空格非空才启用创建；成功后 `create(...)`、选中并关闭抽屉 |
| 管理 | 无 → 行长按菜单与「管理 Bot」列表（含隐藏 Bot）：改名（同一截断规则、无规则提示）、外观（打开信息页外观区）、`setMain`、`setHidden`、二次确认删除；删除调用 `BotProductionHub.deleteBot(_:)`，最后一个 Bot 显示不可删原因 |
| FishAction | 目录已宣告但 App 未注册 → 组装时 `await runtime.registerFishActionTool()`；live `tool/call` 解析为 `BotFishReaction`，同一 botID 的头部/空状态/状态行/侧边栏行都传 `reaction:` |
| Director 事件 | 手写映射、缺 textDelta/error → live 帧统一经 `BotFishDirectorEventMapper`；`streamStart`/`textDelta` 合成 `model.delta`，失败 `turn/end` 与运行时错误合成 `error`；页面和侧边栏共用 `BotLiveFishProjection`，60s 空闲由 unit 与页面共享触摸时钟 |
| 过程行 | `FishAction` 可能作为普通工具出现 → `BotTurnProcessProjector.isProcessTool` 使用 `BotDisplayContract.isToolCallVisible` 过滤 |
| 提示词 | `BotDomainVolatileContextProvider` 未接 teammates/description → 组装时传名册（排除自己与隐藏、含 isMain/description）和该 Bot description |
| agent-comm 行 | 小头像固定显示当前 Bot → 显示对方外观；对方为主 Bot 带皇冠；主 Bot 聊天页头部/空状态皇冠在 fixture 与生产接线核对 |

Self-check（`spec/README.md` §5.1）：没有第二种 envelope、没有新增 wire frame/durable event/schema 字段；`FishAction` 注册沿用既有 host-tool seam；`BotDisplayContract` 是既有 P27 规则；没有放宽任何库层校验（`drawer-v3` 的 60 单元截断只是 UI 输入上限，模型层仍拒绝空白/超长）。所有新增 id/文案属于 P09 App UI。

## 3. 兼容性

| Producer → Consumer | 支持／拒绝方式及理由；对应测试 |
| --- | --- |
| old app → new library | 本单元只改 app；旧 app 不调用新入口，库层不变。 |
| new app → old Worker | `FishAction` 已由 fish-react 在 Worker 标记 auto；旧 Worker 不宣告时模型不会调用，按钮/列表仍走既有 profile store 与 runtime。 |
| persisted old data → new／rollback | `BotRosterModel` 读既有 `agents-index.json` / `runtime-settings.json`；抽屉不新增磁盘字段。回滚 App 只丢失 UI 入口，旧数据无迁移。 |
| DSH 页 | `NativeShell` 只在 Bot tab 替换面板内容；任务 tab 仍是 `SessionsDrawerPanel(HomeDrawer)`，抽屉宽度/圆角/动画/截图路径不变。`HomeDrawer.swift` 未改。 |

- 版本决定：不升 P26 schema、不升 P25 event envelope；没有新的 wire 参数、错误码或持久化格式。
- 首波/上游差异：手机端把上游 dock 的竖排 tile 改成与 DSH 抽屉一致的横向行；删除了上游模板导入/导出与团队入口（本 PR 范围外）。
- 回滚：删除 Bot tab 的 `BotDrawerHost` 与入口按钮即可回到单页 Bot；profile 数据和运行时不受影响。

## 4. 分工与证据

- **独占路径：** `examples/probe-app/PhoneDSHProbe/Bot/**`（除 `Bot/Fish/**`）、`NativeShell.swift`（仅 Bot tab 承载）、`scripts/ci/bot-ui/**`、`spec/ui/v1/pages/{bot-chat,bot-info,bot-drawer}.md`、本文档。
- **共享 fixture：** `BotUIFixtureCase` 新增 `drawer`、`drawerAdd`、`drawerManage`、`reactionLive`，另加 capture-only `reactionHeader` 证明头部与侧边栏消费同一 reaction；`BotUIFixtureChecks` 新增抽屉投影/添加校验/FishAction 过滤/textDelta-error-reaction 检查。截图由 `scripts/ci/bot-ui/capture.sh` 在 light/dark 下生成。
- **测试（真实运行；环境限制按实际记录）：**
  - `swift test --filter PhoneDSHBotTests` → FAIL（环境）：SwiftPM manifest 的嵌套 `sandbox-exec` 被工作树沙箱拒绝（`sandbox_apply: Operation not permitted`）。
  - `swift test --disable-sandbox --filter PhoneDSHBotTests` → PASS：376 tests，0 failures。库层未改，用例数未减少。
  - `cd examples/probe-app && xcodegen generate` → PASS。
  - `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bm-drawer-dd-exact build CODE_SIGNING_ALLOWED=NO` → FAIL（环境）：SwiftPM 写 `~/Library/Caches/org.swift.swiftpm/manifests` 被拒。
  - 同上命令 + `HOME=/tmp/bm-drawer-home XDG_CACHE_HOME=/tmp/bm-drawer-home/.cache CFFIXED_USER_HOME=/tmp/bm-drawer-home -packageCachePath /tmp/bm-drawer-pkg-cache` + `OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox` → PASS（`** BUILD SUCCEEDED **`）。绕行只用于隔离沙箱，不改生产构建设置。
  - `bash scripts/ci/bot-ui/capture.sh --appearance light,dark --out /tmp/bm-drawer-shots --device 90F24C75-9E2A-41C4-8E56-0BAB7460DE1C` → FAIL（环境）：XCUITest runner 启动前 SwiftPM cache 被拒。
  - 同命令 + `HOME`/`CFFIXED_USER_HOME`、`BOT_UI_OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'`（保留 UI 测试）→ 构建成功，runner 启动报 `Pseudo Terminal Setup Error`，**interactions NOT_RUN**（不是断言失败）。
  - 同命令 + 上述环境 + `BOT_UI_SKIP_UI_TESTS=1` → PASS：70 张 light/dark 截图（含 `drawer`、`drawerAdd`、`drawerManage`、`reactionLive`、额外 `reactionHeader` 头部证据）；conformance PASS（`bot-drawer-main-first-hidden-excluded`、`bot-add-validation`、`fish-action-hidden-from-process-rows`、`live-fish-delta-error-reaction` 等）；manifest `interactions: NOT_RUN`。截图在 `/tmp/bm-drawer-shots/{light,dark}/`，manifest 在 `/tmp/bm-drawer-shots/manifest.json`。
  - `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS（5 files、13 contrast pairs、50 geometry tokens）。
  - `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS（phone-spec 90 files/0 errors；phone-cross-tree 8/8 invariants、registry byte-identical、89 schemas 0 breaking、87 tests OK）。
  - `git diff --check` → PASS。
- **沙箱外重跑失败的小修（`drawer-v2`，先读 `_logs/bm-drawer-e2e-errors.txt` 与沙箱外可访问性树）：**
  - **`testBotDrawerOpenSelectAndClose`：** 面板在可访问性树里是 ScrollView，不是 Other。测试改为按 identifier 匹配任意类型并取 `firstMatch`；关闭判定从「元素不存在」改成 `!isHittable || frame.maxX <= 0`（面板滑出后元素仍在树里），左滑关闭、点第二个 Bot 后抽屉关闭、头部名字切换三项断言均保留并加强。
  - **`testBotAddValidatesAndCreates`：** 添加对话框新增名字清除按钮（accessibility id `bot.add.name.clear`）；UI 测试不再用依赖光标位置的 80 次删除，而是先清空 61 字符草稿，输入「小舟」确认「创建」可用，再追加到 63 UTF-16 单元确认按钮重新禁用，最后清空并创建「小舟」。`BotUIFixtureChecks` 新增 `bot-add-edited-too-long-rejected`：`小舟`+61 个`长`（63 UTF-16 单元）同时被 UI 谓词和 fixture 的 `BotRosterModel.create → BotProfileStore.validateName` 拒绝；按钮文案由「建立」改为「创建」，`bot.add.create` 不变。
  - **Bot E2E 编译：** `BotLiveFrame` 从 `BotLiveTurn.swift` 移到 E2E target 已包含的 `BotRuntimePresentation.swift`（`BotRuntimeUnit` 同 target 消费它），不再依赖未包含的页面 view 层文件；未新增/复制第二份帧类型。
  - **本次复跑（沙箱内）：** `swift test --disable-sandbox --filter PhoneDSHBotTests` → PASS（376 tests，0 failures）；`xcodegen generate` + PhoneDSHProbe iOS Simulator build → PASS（`** BUILD SUCCEEDED **`）；`BOT_UI_SKIP_UI_TESTS=1` capture → PASS（70 张 light/dark 截图；conformance 含 `bot-add-edited-too-long-rejected`；`interactions: NOT_RUN`；manifest `/tmp/bm-drawer-shots-fix/manifest.json`）；`xcodegen generate --spec scripts/ci/bot-e2e/app/project.yml` + `xcodebuild build-for-testing` → PASS（`** TEST BUILD SUCCEEDED **`）；CaptureUITests 单独 `swiftc -typecheck`（iOS Simulator SDK + XCTest）→ PASS；`phone-spec,phone-cross-tree` 与 `ui_check` 仍 PASS；`git diff --check` → PASS。
- **`drawer-v3` 小修（无内联提示 + 输入即截断）：**
  - **代码：** 新增 `BotAddValidation.capped(_:)`，按 `Character` 累加 UTF-16 宽度，超过 60 即停止；添加对话框和两处改名 alert 的 TextField 都用这个 binding setter（输入/粘贴同路径）。添加对话框删除 `bot.add.name.hint` 与常驻规则提示行；改名 alert 删除规则 message；空名仍只禁用创建，模型层 `BotRosterModel.create` / `BotProfileStore.validateName` 未改。
  - **fixture / 交互测试：** `drawerAdd` 改为空名普通填写态，不再预置超长错误草稿；`testBotAddValidatesAndCreates` 改为：初始空名创建禁用且无 `不能为空`/`最多` 静态文本 → 输入 61 个`长`断言字段值为 60 且创建可用 → 清空后输入「小舟」创建并断言头部切换。`bot-add-edited-too-long-rejected` 保留，直接调用 fixture 的 `BotRosterModel.create` 验证模型层拒绝 63 单元；新增 `bot-add-name-typing-cap` 验证 61→60 以及 family emoji / combining mark 不被截断。
  - **本次复跑：** `swift test --disable-sandbox --filter PhoneDSHBotTests` → PASS（384 tests，0 failures）；`xcodegen generate` + PhoneDSHProbe iOS Simulator build → PASS（`** BUILD SUCCEEDED **`）；`BOT_UI_SKIP_UI_TESTS=1` capture → PASS（70 张 light/dark 截图；conformance PASS，含 `bot-add-name-typing-cap` 与 `bot-add-edited-too-long-rejected`；`interactions: NOT_RUN`；manifest `/tmp/bm-addtip-shots2/manifest.json`，`drawerAdd` 截图在 `/tmp/bm-addtip-shots2/{light,dark}/drawerAdd.png`）；CaptureUITests `swiftc -typecheck`（iOS Simulator SDK + XCTest）→ PASS；`python3 spec/ui/v1/tools/ui_check.py --root .` → PASS；`phone-spec`、`phone-cross-tree` → PASS；`phone-p0-conformance` → FAIL（`page-structure` 报 `files missing-action '完成'`；在干净 HEAD 的 `git archive` 副本上复跑同样 FAIL，属分支既有问题，本单元未改该页）；`git diff --check` → PASS。
- **Not verified:** 真机、真实模型 E2E、宽屏 iPad 实机、XCUITest runner 被沙箱阻止（本单元只做了 typecheck；`interactions: NOT_RUN`）。
- **剩余风险：**
  1. 侧边栏对非选中 Bot 的 live activity 依赖 `BotRuntimeUnit`；未创建 unit 的 Bot 只显示 idle，符合惰性创建，但隐藏 routine 回合只有 working 没有详情。
  2. `BotLiveFishProjection` 每次重放已收 live 事件；长时间单回合会随事件数增长，但每个回合只在内存中保留该回合帧，复杂度与现有 `BotLiveTurn` 同阶。
  3. 添加/管理对话框的 fixture 使用临时 `BotProfileStore`；生产删除级联的完整证据仍由 `bm-app` 的 fixture/单测覆盖，本单元只接线 UI。
  4. XCUITest runner 在本沙箱被 `Pseudo Terminal Setup Error` 阻止，抽屉交互测试只编译未运行；截图与 conformance 真实执行。

## 5. 修订记录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| `drawer-v1` | `bm-drawer`（contract owner / implementer） | 初次实现 Bot 侧边栏、添加/管理、reaction/director 接线与 UI 契约 | lead、`bm-lib`、`bm-spec` |
| `drawer-v2` | `bm-drawer`（contract owner / implementer） | 沙箱外验证失败小修：ScrollView 面板查询与真实关闭断言、添加对话框可靠清空与双层超长拒绝、`BotLiveFrame` 移到 E2E 已包含文件；契约/线格式未变 | lead、`bm-spec` |
| `drawer-v3` | `bm-drawer`（contract owner / implementer） | 添加/改名对话框去掉内联校验/字数提示，输入与粘贴按字素簇安全截断到 60 UTF-16 单元；模型层空白/超长拒绝不变；契约/线格式未变 | lead、`bm-spec` |
