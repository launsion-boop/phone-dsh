<!-- SPDX-License-Identifier: MIT -->

# 例行任务页与例行任务卡的人话展示（包 A：ROU-01～ROU-05、CARD-02、GEN-02）

```yaml
change: PC-20261111-bot-ui-tidy-a
contracts: [P09, P27]
status: implemented
breaking: false
version_decision: "P09/P27 presentation only: the routine row schema, effect outbox, reconciliation decisions and card payload fields are unchanged. The page now maps the existing `delivery`/`creator`/`effectKey`/`constraints` values through the shared `BotUIFormat`; raw values stay available in the page's detail disclosure. No wire frame, event, row or version field is added; the same bundled app carries both presentations."
base: 21187f31
contract_revision: spec/ui/v1/pages/bot-info.md@ui-tidy-rou-v1 (worktree, not committed)
```

Protocol impact: P09; P27: none — 只改 iOS 页面与卡片的展示，`conversation.automation_run` / routine row 的字段、值域、动作与 effect key 均未变；没有第二个 envelope 或别名字段。

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 例行任务页主行直接显示 `Asia/Shanghai`、`held`/`interrupt`、
  `用户回合 · bot-fixture-1`、`routine:run-2`、`routine.deliver · routine-2:3 · unknown-outcome`，
  约束原文把 `SendToUser`、`[quiet]` 铺在主行；短值右对齐、长值换行后左对齐；动作散落成多行黑色
  文本按钮；`needs-reconciliation` 在同一条目里重复三次「结果未知」。期望：交付方式、时区、设立者、
  执行效果使用人话；内部 ID/effect key/原始约束只在「查看详情」里；字段统一左对齐（短值两列、长值
  上下）；动作区按状态分组、有主次；对账只保留一处说明 + 操作。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `ui-rou`
  （分支 `ui/tidy-rou`，worktree 基于 `21187f31`，协议比较基线同 commit）兼任四角色：先改 P09
  页面契约，再改 iOS 展示层、夹具与生产适配器，并跑检查与 light/dark 截图。
- **Owning contract / schema / fixtures.** P09：`spec/ui/v1/pages/bot-info.md` 的 Routines 行；
  无 schema/golden 变化。`BotWorkCardView.swift` 的 automation 卡只消费既有 row 字段
  （`title`/`status`/`schedule`/`timezone`/`context`/`quiet`/`urgent`/`result`/`durationMs`）。
- **受影响 producer / consumer.** iOS `examples/probe-app/PhoneDSHProbe/Bot/`：
  `BotInfoPage.swift`（`BotRoutinesPage` 与私有子视图）、`BotWorkCardView.swift`、
  `BotFixtures.swift`、`BotProductionUIAdapters.swift`、`BotProductionServices.swift`、
  `BotUIFormat.swift`（只追加）。Android/HarmonyOS 无 Bot runtime，不跟进。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| 设立者 | 契约要求主行展示 `creator.rpcId`／`turnId`／`origin`／`authorization`，实现拼 `授权 · 原始 ID` → 主行展示 authorization/origin 的人类可读来源（「由你在对话中创建」「你确认后创建」），原始 ID 只在「查看详情」 |
| 已产生效果 | 契约要求显示文字摘要 → 保留文字摘要，但必须是人类可读的效果说明（如「已尝试发送提醒，送达结果未确认。」）；原始 effect key/target/reason 只在「查看详情」 |
| `completion_criteria` / `constraints` | 契约要求展示 → 仍展示；自由文本包含工具名/提示词标记时主行只显示「原文包含执行提示」的说明，原文不改写地放进详情；不得推断摘要 |
| 下一次到期/安静延后 | 契约要求展示但实现未显示 → 使用既有 `next_run_at` 与 `quiet_defer` 展示「下次到期」「原定 …，延后至 …」 |
| delivery/timezone | 契约只要求展示字段 → 主行使用人类可读值（「下次聊天时送达」「上海时间（UTC+8）」），IANA 标识放详情 |
| 对账 | 契约要求显示效果摘要与两个动作 → 仍满足；重复的「结果未知」合并为一处警告块，两个动作独立存在 |
| accessibility id | `bot.routine.cancel.*`、`bot.routine.reconcile.ack/retry.*`、`bot.routine.toggle.*` → 不变；新增 `bot.routine.detail.<routineID>` |

自检：没有新增第二种表达；新增的展示字段全部来自既有 `Routine`/`BotEffectRecord`/row payload；
未知值走 `BotUIFormat.unknownValue`（「其他」），原始值仍可在详情中读到；旧数据无需迁移。

## 3. 兼容性

| Producer → Consumer | 支持／拒绝方式及理由；对应测试 |
| --- | --- |
| old → new | 不适用：同一 App bundle 内的页面与卡片展示，无跨进程/持久化格式变化。已有 `held`/`interrupt` 或旧夹具字符串仍由 `BotUIFormat.routineDelivery` 兼容映射。 |
| new → old | 不适用：未新增或修改任何 wire/持久化字段；回滚只影响该页是否展开详情。 |
| new → new | 页面、卡片和 `BotUIFormat` 在同一 target；生产适配器与夹具都通过同一映射函数，不再各自拼内部值。 |
| persisted old data → new／rollback | routine/row 数据格式不变，旧记录直接显示；effect 记录仍按原 key 读取。 |

- 版本／adapter 决定：无版本变化；P09/P27 页面呈现修订，复用 `pdsh.ui.page-structure/1`。
- bundle／image／native artifact 更新顺序：不涉及；无 Worker 或插件资产变化。
- `target`／`draft` 条款中，本次实现与仍保留的差异：Bot 信息页契约仍为 `target`；本轮只改
  Routines 行与 automation 卡的展示，不新增导航、分组顺序或页面框架。

## 4. 分工与证据

- Implementer 路径：`spec/ui/v1/pages/bot-info.md`、`docs/protocol-changes/PC-20261111-bot-ui-tidy-a.md`、
  `examples/probe-app/PhoneDSHProbe/Bot/{BotInfoPage,BotWorkCardView,BotFixtures,BotProductionUIAdapters,BotProductionServices,BotUIFormat}.swift`。
- 共享 fixtures：`BotUIFixtureCase.infoRoutines` / `infoReconcile`（routine 页）、
  `automation`（例行任务卡）；夹具改用与生产相同的展示值，`held`、`bot-fixture-1`、effect key
  不再出现在主行。没有新增 fixture case，截图入口不变。
- 各端真实 producer／consumer 测试：iOS 模拟器构建 + `capture.sh` 的 `infoRoutines`/`infoReconcile`/
  `automation`/`task` 浅色与深色截图；Android/HarmonyOS 不适用。
- Exact commands → `PASS／FAIL／SKIP／INCOMPLETE／NOT_RUN`：
  - `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS（5 files、13 contrast pairs、6 deferred AA pairs、0 failures）。
  - `python3 -m unittest discover -s spec/ui/v1/tools -p 'test_*.py'` → PASS（201 tests, OK）。
  - `python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` → FAIL（7 new divergences，与基线既有的 7 处完全同集合：connected-computer 1、files 1、home-drawer 2、pc-pairing 1、settings 2；没有新增 Bot 差异，按 ui-common 记为通过）。
  - `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS（phone-spec 18s、phone-cross-tree 36s；cross-tree 87 tests OK）。
  - `python3 scripts/ci/protocol_impact.py --root . --base HEAD --body-file docs/protocol-changes/PC-20261111-bot-ui-tidy-a.md` → PASS（P09、P27 triggered，declaration matches）。
  - `xcodegen generate` + `xcodebuild ... -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ui-rou-dd ... build`（沙箱绕行：`HOME`/`XDG_CACHE_HOME`/`CFFIXED_USER_HOME` 指向 `/tmp/ui-rou-home`、`IDEPackageSupportDisableManifestSandbox=YES`、`-clonedSourcePackagesDirPath /tmp/ui-rou-spm`、`OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'`）→ PASS（`** BUILD SUCCEEDED **`；构建后已恢复被 xcodebuild 改写的 `Package.resolved`）。
  - `HOME=/tmp/ui-rou-home … BOT_UI_SKIP_UI_TESTS=1 bash scripts/ci/bot-ui/capture.sh --appearance light,dark --out /tmp/ui-rou-shots` → PASS（80 screenshots，manifest `status=PASS`、`conformance=PASS`；XCUITest 交互测试按环境 SKIP，截图由 simctl 采集）。已人工检查 light/dark 的 `infoRoutines.png`、`infoReconcile.png`、`automation.png`、`task.png`。
- 剩余风险、未支持平台：真机未跑；只有模拟器截图，不能据此声称真机像素/触控证据；
  Android/HarmonyOS 无 Bot 页；动态字体、VoiceOver、窄屏下三个标签并排仍需后续验收；
  「查看详情」展开态未做交互截图（静态代码 + 折叠态截图验收）；共享 `BotUIPalette.danger`
  在深色背景的对比度未单独调整（沿用包 F 提供的 `BotDestructiveButtonStyle`）。
  生产的 `conversation.automation_run` 行目前不带 `schedule`/`timezone`/`urgent`，卡片会
  优雅省略这些行；要让生产卡也显示「每天 … · 上海时间（UTC+8）」与紧急标签，需要在
  `BotRuntimeEffects.swift` / `BotRuntimeComposition.swift` 的 row payload 增补只读展示字段，
  不在本单元文件范围，留给包 E/卡片接线。

## 5. 修订记录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | ui-rou | 初版：ROU-01～ROU-05、CARD-02、GEN-02（取消运行）；设立者/效果/自由文本的原始值折叠到详情 | iOS；P09/P27 reviewer |
