<!-- SPDX-License-Identifier: MIT -->

# Bot 信息页与记忆页整理（包 B + 包 D，P09）

```yaml
change: PC-20261111-bot-ui-tidy-memi
contracts: [P09]
status: implemented
breaking: false
version_decision: "P09 page presentation only: the Bot profile, memory document, maintenance, presence and proactive-settings data shapes, host APIs, accessibility identifiers and persistence keys are unchanged. No wire frame, row, projection, event, schema, golden or version field is added; the same bundled app carries the page, so there is no cross-version interoperability to decide."
base: 21187f31b52bdfb71d932d65b4fb0cc3c2e15e06
contract_revision: spec/ui/v1/pages/bot-info.md@bot-ui-tidy-memi-v1 (worktree, not committed)
```

Protocol impact: P09; P26: none — the page only reads the existing `BotProfile.description` and the existing memory author/source values and changes their presentation, while profile/memory/maintenance schemas, host APIs, storage and validation are untouched; P27: none — no row, row-batch, user-action, action-result, projection or golden shape changed, the app-side changes are SwiftUI presentation and fixture copy only.

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 排查报告 `docs/research/bot-ui-audit-20261111.md`
  §3.1／§3.2／§7 包 B、包 D 的 INFO-01～INFO-08、MEM-01～MEM-08（INFO-02 外观 footer
  已在 `main` 上改为「点选即保存。」，本次只确认），以及 GEN-02 在本区域的抹除入口。
  现况：信息页名称分组标题和行标题都写「名称」、长名称在编辑行被截断、副标题对所有 Bot
  都是同一句、外观以外的三段 footer 暴露保活／持久化／routine／记忆偏好等实现词、
  安静时段在英文 Locale 下显示 12 小时制、「当前级别 预定通知」与「预定通知 N 条」重复；
  记忆页的后台整理说明和文档详情/抹除确认暴露宿主、批次、事件载荷、派生视图、墓碑、纪元、
  `record://`、原始路径与版本号等内部实现，token 用量在主视图出现两次，文档树的抹除入口
  混在文档行里且不是危险色。期望：footer 缩成一两句用户结果导向的话；安静时段固定
  `HH:mm`；名称只保留一处标签且长名称不截断；副标题优先使用 Bot 资料里的描述；记忆页
  主视图只留人类可读摘要，原始 ID／路径／版本／token 折叠到「查看详情」，抹除入口集中到
  独立「危险操作」分组并使用红色危险样式。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `ui-memi`
  （分支 `ui/tidy-memi`，worktree 基于 `21187f31`，协议比较基线
  `45b2e4b87ad1d68780df3df9cf905ba3f8ec6a24`）兼任四角色：先修订 P09 页面契约，再改 iOS
  呈现、生产适配器与截图夹具，最后跑检查与截图。
- **Owning contract / schema / fixtures.** P09：`spec/ui/v1/pages/bot-info.md` 的记忆章节、
  在场状态「已登记提醒」行、打扰设置 footer 和截图说明。无 schema／golden 变化。
- **受影响 producer / consumer.** iOS
  `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift`（信息页、记忆页、在场/打扰区）、
  `BotProductionUIAdapters.swift`（记忆作者显示值）、`BotFixtures.swift`（记忆/在场夹具、
  信息页资料描述）、`BotUIFormat.swift`（追加记忆作者映射，只追加）。Android/HarmonyOS
  没有 Bot runtime，不需要跟进。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| 记忆树分组 | 分组标题含 `（agent/）`／`（user/）`，树里再显示 `agent`／`user` 根行 → 标题为「本 Bot 的记忆」「所有 Bot 共享的记忆」，不渲染根文件夹行；仍按两个根分组 |
| 文档行 | `v2 · <英文日期> · 1 条引用` → `第 2 版 · <中文日期> · 1 条来源` |
| 文档详情 | 导航标题为完整 `document.path`；作者为 `chat · user-turn` 等原始枚举；`record://` 直接铺开 → 导航标题为文件名，路径在正文 footer；作者为「对话中的你」「这个 Bot」「例行任务」「维护整理」等用户可读标签；来源按「来源对话／来源记录」分组计数，原始 `record://` 在 disclosure 内仍可查看 |
| 后台整理说明 | 默认关闭 + 触发条件 + 批次回滚的长说明 → 一两句用户文案；契约不再要求主视图解释宿主／后台会话／批次细节 |
| 日额度 | `今日整理已用 12,400/96,000 token。` → `今日整理额度已用 13%`（或「已用完」），主视图不再出现准确 token |
| 上次整理卡片 | 主视图显示 `2 份文档 · 12,400 token · 检查通过`、`v3→v4 · user/INDEX.md`、失败码 → 主视图显示状态/时间/改动文档数/人类可读文档名与前后版本/检查结果；完整路径、失败码、准确 token 折叠在「查看详情」，仍可查看 |
| 抹除入口 | 文档树行间的普通文字按钮 → 独立「危险操作」分组，`BotDestructiveButtonStyle` 红色；文档详情抹除同样用红色样式 |
| 抹除文案 | 事件载荷／派生视图／墓碑／纪元／`agent/` 路径 → 范围 +「相关内容也会从旧对话里移除」+ 不可撤销；共享 `user/` 影响单独一句 |
| 在场行 | 级别为「预定通知」时下一行也写「预定通知 N 条」 → 下一行改写「已登记提醒 N 条」，N 的语义不变 |
| 打扰 footer | 说明含「改动立即持久化」「routine」「记忆偏好」「按理由放行」 → 一两句用户文案说明对所有 Bot 生效、勿扰暂停主动提醒、安静时段延后非紧急提醒 |
| 信息页名称 | 分组标题「名称」+ 行标题「名称」+ 顶部名字 → 只保留分组标题「Bot 名称」和整行输入框；长名称换行显示不截断 |
| 信息页副标题 | 固定「你的私人 Bot，替你跟进任务和提醒」 → 优先 `BotProfile.description`，为空时回退这句 |
| 在场/打扰截图 | capture-only `infoPresence` 的 footer 是夹具说明 → 与生产页面共用同一段 footer 文案 |

## 3. 兼容性

| Producer → Consumer | 支持／拒绝方式及理由；对应测试 |
| --- | --- |
| old → new | 不适用：同一 App bundle 内的页面呈现，无跨进程或持久化格式变化；旧 Bot 资料、旧记忆文档和旧批次数据直接按新标签显示，未知作者值显示「其他来源」。 |
| new → old | 不适用：未新增或修改任何 wire／持久化字段；回滚只影响该页的文案、折叠和按钮样式。 |
| new → new | 信息页、记忆页和截图夹具共用 `BotUIFormat` 的日期、百分比与作者映射；页面与夹具使用同一 footer 常量。 |
| persisted old data → new／rollback | `agents-index.json`、`phone-dsh.bot.memory-maintenance.v1`、`phone-dsh.bot.proactive-settings.v1` 和 memory 事件格式不变，旧数据无需迁移。 |

- 版本／adapter 决定：无版本变化；P09 页面呈现修订，复用 `pdsh.ui.page-structure/1`。
- bundle／image／native artifact 更新顺序：不涉及；无 Worker 或插件资产变化。
- `target`／draft 条款中，本次实现与仍保留的差异：Bot 信息页契约仍为 `target`；本轮只改
  既有文案、字段层级、格式和危险按钮样式，不新增导航结构、分组顺序或页面框架。

## 4. 分工与证据

- Implementer 路径：`spec/ui/v1/pages/bot-info.md`、
  `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift`、
  `examples/probe-app/PhoneDSHProbe/Bot/BotUIFormat.swift`、
  `examples/probe-app/PhoneDSHProbe/Bot/BotProductionUIAdapters.swift`、
  `examples/probe-app/PhoneDSHProbe/Bot/BotFixtures.swift`。
- 共享 fixtures：`info`、`infoLong`、`infoMemory`、`infoPresence`、`infoEmpty`、`infoError`
  继续使用；`infoPresence` 改用生产 footer 文案，`info`/`infoLong` 的副标题使用夹具里的
  Bot 资料描述，无描述时回退通用句。
- 各端真实 producer／consumer 测试：iOS 模拟器构建 + `capture.sh` 的浅色／深色截图；
  Android/HarmonyOS 不适用。
- Exact commands → `PASS／FAIL／SKIP／INCOMPLETE／NOT_RUN`：
  - `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS（5 files、13 contrast pairs、6 deferred AA pairs、1 unmeasured token、50 geometry tokens、0 failures）。
  - `python3 -m unittest discover -s spec/ui/v1/tools -p 'test_*.py'` → PASS（201 tests, OK）。
  - `python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` → FAIL（7 处均为基线既有：connected-computer 1、files 1、home-drawer 2、pc-pairing 1、settings 2；无 Bot 页或新增项，未改 baseline）。
  - `CI_PROTOCOL_BASE=45b2e4b87ad1d68780df3df9cf905ba3f8ec6a24 bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS（phone-spec 14s、phone-cross-tree 26s；`CI GATE: PASS`）。
  - `cd examples/probe-app && xcodegen generate` → PASS。
  - `HOME=/tmp/ui-memi-home CFFIXED_USER_HOME=/tmp/ui-memi-home xcodebuild build -project PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ui-memi-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` → PASS（`** BUILD SUCCEEDED **`）。
  - `HOME=/tmp/ui-memi-home CFFIXED_USER_HOME=/tmp/ui-memi-home BOT_UI_SKIP_UI_TESTS=1 bash scripts/ci/bot-ui/capture.sh --appearance light --out /tmp/ui-memi-shots` → PASS（40 screenshots；`info.png`、`infoLong.png`、`infoPresence.png`、`infoMemory.png`、`infoAppearance.png`、`infoEmpty.png`、`infoError.png` 已逐张检查）。
  - `HOME=/tmp/ui-memi-home CFFIXED_USER_HOME=/tmp/ui-memi-home BOT_UI_SKIP_UI_TESTS=1 bash scripts/ci/bot-ui/capture.sh --appearance dark --out /tmp/ui-memi-shots-dark` → PASS（40 screenshots；同名 7 张已逐张检查）。
  - `python3 scripts/ci/protocol_impact.py --root . --base HEAD --body-file docs/protocol-changes/PC-20261111-bot-ui-tidy-memi.md` → PASS（P09、P27 triggered，declaration matches）。
- 未验证：真机、动态字体、VoiceOver、横屏、真实后台保活／通知；截图只能证明模拟器浅色和
  深色下的页面呈现。`infoError` 首屏仍与 `info` 相同（失败态在首屏下方的数据入口），这是
  仓库既有夹具覆盖缺口，本次没有新增失败态截图。

## 5. 修订记录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | ui-memi | 初版：包 B 记忆页 + 包 D 信息页的 P1/P2 文案、格式、折叠与危险按钮整理；同步在场「已登记提醒」行和打扰 footer 契约 | iOS；P09 reviewer |
