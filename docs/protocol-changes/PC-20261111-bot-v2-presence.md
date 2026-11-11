<!-- SPDX-License-Identifier: MIT -->

# Bot v2 在场降级梯（P18／P26／P27）

```yaml
change: PC-20261111-bot-v2-presence
contracts: [P18, P26, P27]
status: implemented
breaking: false
version_decision: Additive host-side delivery and settings semantics. No wire field, enum, event type, row shape or routine schema changed. The new routine-notification vector is a phoneDSH-owned v1 schema; old readers ignore it, old routine documents stay readable, and rollback simply stops registering local notifications.
base: 82ae59dc5
contract_revision: spec/bot/v2/README.md@v2-presence-20261111 + spec/ui/v1/pages/bot-info.md@v2-presence-20261111
```

Protocol impact: P18; P26; P27; P09; P16: none — `ChatModel.swift` changes only the background keep-alive/presence branch, not `PDSH_*` environment variables, worker startup or init frames; P25: none — no event type, envelope field or effect format changed, the re-delivery record reuses existing durable `comm.inbound`/`comm.reply` types.

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 方案 §3.8／§6 决定 3 要求：保活条件覆盖 Bot 工作与保活窗口内的 routine；
  建立/改期 routine 时登记本地到期通知；生产装配接通精简后的 interrupt 链；安静时段与勿扰有设置入口
  并持久化；Bot 信息页显示在场级别与延后项；设备任务结果从 at-most-once 改为先写事件、启动补投并去重。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `s2-s5`（分支
  `s2/s5-presence`）兼任 contract owner 与 implementer；先在 `spec/bot/v2`、`spec/ui/v1` 冻结，
  再实现 Swift 与 App 两端。
- **Owning spec / schema / fixtures.** `spec/bot/v2/README.md` §2／§3.1；
  `spec/bot/v2/routine-notification.schema.json`；`spec/bot/v2/golden/routine-notification.json`；
  `spec/ui/v1/pages/bot-info.md`；P18 的 UserDefaults key 记在 `spec/README.md` §3.2。
- **受影响的 producer／consumer.** Swift `Sources/PhoneDSHBot/{Routines,Proactive,Wake}` 生成通知、
  读写偏好、写终态事件；`UNUserNotificationCenter` 是系统 consumer；App
  `examples/probe-app/PhoneDSHProbe/Bot/**` 注入设置、展示在场状态、处理通知深链。Android 与
  HarmonyOS 没有 Bot runtime，没有实现端；`spec/bot/v1` 的事件信封、行与工具面不变。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 主动提醒链 | `RoutineScheduler` 的生产装配 `proactive == nil`，interrupt 结果不通知 → 生产装配传入 `ProactiveEngine(mode: on)` 与 `UNUserNotificationProactiveDelivery`；链保持 interrupt → DND → quiet hours → fuse → delivery（v2 §3）。 |
| routine 预定通知 | 无 → routine 建立/改期/运行/暂停/删除时登记、取消、重排 `routine-due:<botID>:<routineID>:<fireAt>`；标题固定 `例行任务到期`，深链 `phonedsh://bot/<botID>/routine/<routineID>`；上限 60；DND 取消，非紧急安静时段延后（v2 §3.1）。 |
| 打扰偏好 | 代码常量 → UserDefaults key `phone-dsh.bot.proactive-settings.v1` 的 Codable JSON；缺省 `on`/`false`/`23:00`–`08:00`/当前时区；读取时规范化；所有 Bot 共享（v2 §3.1，P18）。 |
| routine 深链 | 只有 `phonedsh://bot/<botID>/row/<rowID>` → 追加 `phonedsh://bot/<botID>/routine/<routineID>`，打开 Bot 信息页例行任务区并定位行；未知 routine 显示不可用（P27／bot-info）。 |
| 在场可见 | 无 → Bot 信息页只读「在场」区：前台／后台保活／预定通知、实际登记的通知数、`quiet_defer` 延后列表。 |
| 保活条件 | DSH 聊天页回合或任一 Bot 回合 → 追加“保活窗口内（15 分钟）有到期 routine”；routine 完成后仍有窗口内到期项时不停止静音音频。 |
| 设备任务结果 | 落盘 journal 后直接入队，至多一次，崩溃窗口丢失 → 先写 durable `comm.inbound` 终态记录，入队后写 `comm.reply` 确认；启动按未确认记录补投，`requestId` 去重（v2 §2）。 |
| 持久化格式 | 没有 Bot 偏好键 → 新 UserDefaults key；没有新事件类型；routine 文档、held inbox 文档与行 schema 不变。 |
| 条款状态 | v2 仍为 `target`；本单不把 v2 升级为 `implemented`，因为没有真机后台／通知证据。 |

自检（`spec/README.md` §5.1）：没有第二种表达（本地通知复用 `ProactiveNotification` 的深链规则和
独立 schema；routine 文档不新增字段）；新字段都是宿主侧可选行为，旧数据不受影响；没有收窄或放宽
两端都读的 routine/held schema；没有新增事件类型、enum 或错误码；没有删除或重用名称。

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 旧 routine/held goldens 仍逐字通过 v2 校验；旧 App 数据没有偏好键时读取缺省值。`routine-notification` 是新增 schema/golden，旧 reader 不读取它。 |
| new → old | 新代码写出的通知 identifier、深链和偏好键不被旧代码读取；回滚后旧代码继续用代码常量，routine 与 held inbox 数据不变。 |
| new → new | Swift `RoutineScheduledNotification` 与 golden 双向 encode/decode 测试；伪 `RoutineNotificationScheduling` 断言登记/取消/重排；生产 `UNUserNotificationRoutineScheduling` 只做系统适配。 |
| persisted old data → new／rollback | routine 文档与 held inbox 文档格式未变；device task 补投只依赖既有 `comm.inbound`/`comm.reply` 事件类型和新增的 data 标记，旧事件没有标记即忽略。偏好键回滚后可留可删，不影响旧代码。 |

- 版本决定：不升 v2 schema 版本，不新增事件类型。`routine-notification` 是新 schema，`title` 固定为
  `BotRoutineNotification v1`，用于宿主侧登记而不是 wire。
- bundle／Worker 更新顺序：没有 Worker/bundle 变更；Swift 与 App 必须同仓构建。
- `target`／`draft` 差异：v2 主动提醒与 routine 仍是 `target`；本单有本地单元/集成测试与模拟器截图，
  没有真机后台、系统通知投递或锁屏证据。

## 4. 分工与证据

- implementer 路径：`Sources/PhoneDSHBot/{Routines,Proactive,Wake}`、
  `examples/probe-app/PhoneDSHProbe/Bot/**`、`examples/probe-app/ProbeKit/Bot/Notifications/**`、
  `spec/bot/v2/**`、`spec/ui/v1/pages/bot-info.md`、`Tests/PhoneDSHBotTests/**`。
- shared fixtures：`spec/bot/v2/golden/routine-notification.json`（正常、安静时段延后、紧急绕过、
  缺深链、错误 scheme、错误标题、负时间）；`spec/ui/v1/pages/bot-info.md` 的 accessibility id。
- runtime 测试：`swift test --disable-sandbox --filter PhoneDSHBotTests`（含新增 notification/settings/
  replay/presence 用例，读取 golden）；App `PhoneDSHSimTests` 的在场/生命周期用例；`ui_check.py`。
- Exact commands 与结果：
  - `swift test --disable-sandbox --filter PhoneDSHBotTests` → **PASS**：457 tests / 0 failures（新增 19 个
    settings／notification／presence／replay 用例）。
  - `python3 spec/bot/v1/tools/validate_vectors.py`、`python3 spec/bot/v2/tools/validate_vectors.py` → **PASS**。
  - `CI_PROTOCOL_BASE=82ae59dc5 bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
    → `phone-spec` PASS、`phone-cross-tree` PASS；`phone-p0-conformance` **FAIL**，7 条 page-structure
    divergence 在基线 HEAD 已存在（GAP-32 等，非本单引入），本单未新增 whitelist 或放宽比较。
  - `python3 spec/ui/v1/tools/ui_check.py --root .`、`python3 -m unittest spec.ui.v1.tools.test_ui_check` → **PASS**。
  - `bash scripts/ci/check.sh --only phone-bot-eval-catalog` → **PASS**；`bash scripts/ci/bot-e2e/eval.sh
    --catalog scripts/ci/bot-e2e/selftest.json --results /tmp/s2-s5-eval` → **PASS 11/11**（新增
    `BOT-SELFTEST-PROACTIVE` 覆盖 interrupt routine → `proactive.considered`）。
  - App：`xcodebuild ... PhoneDSHProbe build` → **PASS**；`build-for-testing` → **PASS**。
  - App 测试：`xcodebuild test -scheme PhoneDSHSim -only-testing:.../BotPresenceKeepAliveTests ...` →
    **NOT_RUN**：DSH sandbox 的 `xctest` 启动报 Pseudo Terminal Setup Error；测试 bundle 已编译。
  - UI 截图：仓库现有 `scripts/ci/bot-ui/capture.sh` 在基线 HEAD 上因
    `BotLiveTurn.swift` 的 `import ProbeKit` 未被捕获工程链接而构建失败；用同一脚本的临时副本补上
    ProbeKit target 后 **PASS**：72 张 light/dark 截图（含 `infoPresence`），conformance PASS，
    交互测试因同一 Pseudo Terminal 限制记 NOT_RUN；manifest 在
    `/tmp/s2-s5-bot-ui-final2/manifest.json`。这是仓库捕获脚本的既有缺口，不是本单改动。
  - 真机后台、本地通知实际投递、系统权限/低电量限制 → **NOT_RUN**。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| v2-presence-20261111 | s2-s5 contract owner | 方案 §3.8／§6 决定 3；冻结 routine 预定通知、偏好键、设备任务补投和 UI 入口 | Swift、App、P09 |
