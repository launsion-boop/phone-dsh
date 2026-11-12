# PC-20261111-bot-ui-tidy-hints

## 0. 摘要（机器可读）

```yaml
change: PC-20261111-bot-ui-tidy-hints
contracts: [P09]
status: implemented
breaking: false
version_decision: 不新增协议版本；只删除或缩短 Bot 页面里解释机制、重复说明和显而易见的静态提示文字。没有新增或修改 wire 字段、事件、schema、持久化形状、按钮行为、accessibilityLabel 或数据显示。
base: 45b2e4b87ad1d68780df3df9cf905ba3f8ec6a24
contract_revision: 45b2e4b8+ui-hints
```

## 1. 识别与角色

- 具体 trigger → 现况 → 期望：
  - **P09**（UI 页面契约）：`bot-chat.md` 没有要求输入框下方显示回合/排队/停止说明，但实现里在运行中额外渲染了「发送会并入当前回合，不会排队；停止只取消当前回合。」；`bot-info.md` 要求「打扰」区 footer 用一两句说明设置范围，并要求 capture-only `infoPresence` 夹具复用生产 footer；`bot-drawer.md` 要求删除确认文案说明全部级联后果。现况是信息页、记忆页、例行任务页、授权页和卡片里还有大量分组 footer、空态附注和卡片备注解释机制。期望：按用户反馈删除这些画蛇添足的说明文字，只在不可逆确认弹窗保留一句后果说明、在失败/空状态保留状态本身、在必要前提保留一句提示；契约同步改为不要求显示这些说明。
  - **P26**：无影响——只删 UI 静态文案，不改工具面、effect、审批、记忆、wake、routine 的任何字段或语义。
  - **P27**：无影响——`bot-chat.md` 第 63、83 行的按钮行为与 accessibilityLabel（「发送并 steering」）不变，只删输入框下方的可见说明。
- 协调者兼 contract owner／implementer／reviewer-integrator：本单元 `ui-hints`（单 worker）。
- Owning spec：`spec/ui/v1/pages/bot-chat.md`、`spec/ui/v1/pages/bot-info.md`、`spec/ui/v1/pages/bot-drawer.md`。P09 页面契约只改“是否显示说明文字”，不改数据字段、交互、id 或失败语义。
- 受影响 producer／consumer：iOS probe app（`examples/probe-app/PhoneDSHProbe/Bot/**`）的 SwiftUI 显示层与截图夹具；Android/HarmonyOS 没有 Bot 页面 runtime，不涉及。P26/P27 的 wire、事件、row schema、action 语义均未变。

## 2. 契约 delta

只列改动；未变语义引用 owning clause。

| 项目 | Before → After／依据条款 |
| --- | --- |
| `bot-chat.md` §4 输入区 | Before：只规定按钮三态和 accessibilityLabel；实现自行在运行中显示回合/排队/停止说明。After：新增一条「输入胶囊下方不显示回合、排队或停止说明文字；按钮行为和 accessibilityLabel 不变」。第 63、83 行的三态行为保持不变。 |
| `bot-info.md` §4 打扰设置 | Before：要求 footer 用一两句面向用户的话说明设置对所有 Bot 生效以及勿扰/安静时段结果。After：不显示分组底部解释性文案；控件规则仍按原条目。 |
| `bot-info.md` §4 截图证据 | Before：capture-only `infoPresence` 夹具要求与生产相同的 footer 文案。After：同一 `BotPresenceSection` / `BotDisruptionSection` 组件，不带 footer 说明。 |
| `bot-drawer.md` §4 管理 Bot 删除 | Before：确认文案说明会中止回合、拒绝待审批、撤销授权、归档 DSH 会话，并删除记忆、例行任务和待处理消息。After：确认文案压成一句，保留同一组后果，去掉内部词 `DSH` 和「至少保留一个 Bot」的重复提示。 |
| fields／encoding／number domain／limits／default／null | 无变化。 |
| capability／version／unknown field／unknown method／unknown enum | 无变化。 |
| correlation／sequence scope／ordering／terminal outcome | 无变化。 |
| error code／retryable／deadline／cancel／late response | 无变化；取消运行、删除、抹除的确认弹窗及其后果说明保留，压缩为一句。 |
| idempotency／side effect unknown／ACK／durability／recovery | 无变化；删除、抹除、撤销授权的宿主调用和重读语义不变。 |
| origin／auth／scope／path／redaction／backpressure | 无变化；完整路径、evidence、token 等数据仍按原契约显示或折叠，未删任何数据字段。 |
| 条款状态变化（target → implemented 等） | 三个页面仍是 target；本变更只把“显示解释文字”的要求改为“不显示”。 |

自检：没有新增第二种表达；没有新字段/新枚举；没有收窄或放宽两端都读的 wire 消息；旧持久化数据无需迁移。删除的只是 UI 静态文案，所有按钮、accessibility id、accessibilityLabel、空状态和失败状态保留。

## 3. 兼容性与发布

| Producer → Consumer | 支援／拒绝方式及理由；对应测试 |
| --- | --- |
| old → new | 无 wire 变化；旧数据、旧事件、旧 grant 继续按原字段读取和显示。 |
| new → old | 无 wire 变化；旧客户端看到同一份数据。 |
| new → new | 无协议变化，仅本地 SwiftUI 文案。 |
| persisted old data → new／rollback | 不适用：没有 schema/持久化形状变化；回滚 UI 代码即可恢复旧文案。 |

- 版本／adapter 决定：P09 页面展示微调，不新增 version/adapter；没有新旧互操作问题。
- bundle／image／native artifact 更新顺序、回滚限制：无。仅 probe app 源码与页面契约。
- `target`／`draft` 条款中，本次实现与仍保留的差异：Bot 页面只在 iOS simulator 上验证；真机后台、通知、动态字体和 VoiceOver 仍 NOT_RUN。

## 4. 分工与证据

- 独占路径：`examples/probe-app/PhoneDSHProbe/Bot/BotChatPage.swift`、`BotInfoPage.swift`、`BotDrawer.swift`、`BotWorkCardView.swift`、`BotFixtures.swift`、`spec/ui/v1/pages/bot-chat.md`、`bot-info.md`、`bot-drawer.md`、本变更单。
- 共享 fixtures：`BotFixtures.swift` 的截图夹具；只删说明性 footer/helpText、把 fixture 聊天消息改成普通回复，不新增或修改 wire fixture、事件或 schema。
- 各端真实测试：Swift `PhoneDSHBotTests` / `PhoneDSHGatewayTests`；iOS `xcodebuild` + `scripts/ci/bot-ui/capture.sh`（simulator）；spec `ui_check.py`、golden/vector validators、`scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-bot-eval-catalog,phone-license`；plugins `npm run typecheck`；Bot eval selftest。
- Exact commands → 结果（详见本次工作区报告与截图目录）：
  - `swift build --disable-sandbox` → PASS
  - `swift test --disable-sandbox --filter 'PhoneDSHBotTests|PhoneDSHGatewayTests'` → PASS（740 tests, 0 failures）
  - `xcodebuild build ...`（iOS simulator，`Bundle/worker` 以空目录占位） → PASS
  - `python3 spec/tools/bot/check_golden.py --root .` → PASS（31 files, 16 upstream, 15 overlays）
  - `python3 spec/bot/v1/tools/validate_vectors.py` → PASS
  - `python3 spec/bot/v2/tools/validate_vectors.py` → PASS
  - `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS
  - `python3 -m unittest discover -s spec/ui/v1/tools -p 'test_*.py'` → PASS（201 tests）
  - `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-bot-eval-catalog,phone-license` → PASS（4 stages）
  - `cd plugins && npm run typecheck` → PASS
  - `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/selftest.json --results /tmp/ui-hints-selftest` → PASS（upstream mock，18/18 runnable）
  - `git diff --check origin/main` → PASS
  - `BOT_UI_SKIP_UI_TESTS=1 bash scripts/ci/bot-ui/capture.sh --appearance light --out /tmp/ui-hints-shots` → PASS（42 张，逐张人工检查）
  - 同命令 `--appearance dark --out /tmp/ui-hints-shots-dark` → PASS（42 张，逐张人工检查）
  - `python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` → FAIL（7 处均为 ui-common 已登记的基线差异：connected-computer、files、home-drawer、pc-pairing、settings；无 Bot 页新增）
- 剩余风险、未支援平台、新发现的 GAP：只验证 iOS simulator；未在真机验证后台、通知、动态字体、VoiceOver。Android/HarmonyOS 无 Bot UI runtime，不适用。没有新增 GAP。

## 5. 修订纪录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `45b2e4b8+ui-hints` | `ui-hints` | 首次冻结：删除 Bot 界面的机制说明、重复 footer 和显而易见的提示，契约改为不要求显示；不改 wire、按钮行为、accessibilityLabel 或数据 | iOS Bot UI；Android/HarmonyOS 不适用 |
