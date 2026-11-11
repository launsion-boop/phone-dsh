<!-- SPDX-License-Identifier: MIT -->

# Bot 信息页去掉重复的外观预览（P09）

```yaml
change: PC-20261111-bot-info-no-preview
contracts: [P09]
status: implemented
breaking: false
version_decision: "P09 page presentation only: the Bot profile schema, persistence, upsert patch semantics and the shared `BotAppearancePicker` accessibility identifiers are unchanged. No wire frame, event, row, projection or version field is added; the same bundled app carries both pages, so there is no cross-version interoperability to decide."
base: d988108c1
contract_revision: spec/ui/v1/pages/bot-info.md@bot-info-no-preview-v1 + spec/ui/v1/pages/bot-drawer.md@bot-info-no-preview-v1 (worktree, not committed)
```

Protocol impact: P09; P26: none — the Bot profile appearance fields, defaults, validation and `BotProfileStore.upsert` patch semantics are untouched, the page only stops drawing a second preview; P27: none — no row, row-batch, user-action, action-result, projection or golden shape changed.

## 1. 识别与角色

- **Trigger → 现况 → 期望.** Bot 信息页顶部已经画出 80pt
  `BotFishView(state: .idle, size: 80, appearance: model.appearance, still: true)`；「外观」区里的
  `BotAppearanceEditor` 又通过 `BotAppearancePicker` 画出 112pt 实时预览。用户看到同一页两个重复
  头像。期望：信息页去掉外观区的大预览，点选发型 / 颜色时只由顶部 80pt 头像跟随切换；「添加 Bot」
  对话框没有顶部头像，保留自己的 104pt 预览。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元
  `ui-avatar`（分支 `ui/bot-info-avatar`，worktree 基于 `1f1c1ea6`，协议比较基线
  `d988108c1`）兼任四角色：先改 P09 页面契约，再改 iOS 实现并跑检查与截图。
- **Owning contract / schema / fixtures.** P09：`spec/ui/v1/pages/bot-info.md` §外观、
  `spec/ui/v1/pages/bot-drawer.md` 添加对话框预览说明；无 schema 或 golden 变化。
- **受影响 producer / consumer.** iOS
  `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift`（信息页关闭预览、footer 文案）与
  `BotAppearancePicker.swift`（既有 `showsPreview` 调用方语义的注释）；`BotDrawer.swift` 的
  「添加 Bot」对话框保持原样。Android/HarmonyOS 没有 Bot runtime，不需要跟进。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| 信息页预览 | 112pt 实时预览（idle，可 poke）→ 信息页不另设预览，顶部 80pt 头像随发型 / 颜色点选即时更新 |
| 共享选择器 | 组件固定带预览 → 预览由调用方通过既有 `showsPreview` 控制；信息页关闭，对话框关闭组件内预览但保留自己的 104pt 预览 |
| accessibility id | 发型 / 颜色 id 与分组不变（`bot.info.appearance.*`、`bot.add.appearance.*`）→ 不变；预览无独立 accessibility id |
| 信息页 footer | 「只改发型和颜色，与桌面 DSH Bot 一致；点选即保存，自动外观保留给以后的多 Bot 接入。」→「点选即保存。」 |
| 添加对话框 | 104pt 预览 + 草稿状态 → 不变 |
| 点选写入语义 | `BotProfileStore.upsert` 只带改动字段，点选即保存 → 不变 |

## 3. 兼容性

| Producer → Consumer | 支持／拒绝方式及理由；对应测试 |
| --- | --- |
| old → new | 不适用：同一 App bundle 内的页面呈现，无跨进程或持久化格式变化；旧 Bot 资料直接显示在顶部头像与色点选择态。 |
| new → old | 不适用：未新增或修改任何 wire／持久化字段；回滚只影响该页是否再画第二个预览。 |
| new → new | 同一 bundle 内信息页与添加对话框共用 `BotAppearancePicker`，预览显隐由各自调用参数决定。 |
| persisted old data → new／rollback | Bot 资料文件、`BotProfileStore.upsert` 补丁字段与默认值不变，旧数据无需迁移。 |

- 版本／adapter 决定：无版本变化；P09 页面呈现修订，复用 `pdsh.ui.page-structure/1`。
- bundle／image／native artifact 更新顺序：不涉及；无 Worker 或插件资产变化。
- `target`／`draft` 条款中，本次实现与仍保留的差异：Bot 信息页契约仍为 `target`；本轮只改外观区，
  不新增导航、分组顺序或页面框架。

## 4. 分工与证据

- Implementer 路径：`spec/ui/v1/pages/bot-info.md`、`spec/ui/v1/pages/bot-drawer.md`、
  `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift`、
  `examples/probe-app/PhoneDSHProbe/Bot/BotAppearancePicker.swift`；
  `examples/probe-app/PhoneDSHProbe/Bot/BotDrawer.swift` 不改。
- 共享 fixtures：`BotUIFixtureCase.infoAppearance`（紫 / 双马尾）继续使用；顶部 80pt 头像和色点选中态
  仍能证明外观值；不再依赖 112pt 预览。无新增 fixture。
- 各端真实 producer／consumer 测试：iOS 模拟器构建 + `capture.sh` 的 `info`、`infoAppearance` 截图；
  Android/HarmonyOS 不适用。
- Exact commands → `PASS／FAIL／SKIP／INCOMPLETE／NOT_RUN`：
  - `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS（5 files、13 contrast pairs、6 deferred AA pairs、0 failures）。
  - `python3 -m unittest discover -s spec/ui/v1/tools -p 'test_*.py'` → PASS（201 tests, OK）。
  - `python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json` → FAIL（7 new divergences outside the baseline，与改动前同一输出：`connected-computer` 1、`files` 1、`home-drawer` 2、`pc-pairing` 1、`settings` 2；均为该集成基线上既有的 Android parity 差异，与 Bot 外观页无关，未修改 baseline）。
  - `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS（phone-spec 20s、phone-cross-tree 21s；phone-spec 237 tests、cross-tree 87 tests）。
  - `cd examples/probe-app && xcodegen generate` → PASS。
  - `xcodebuild ... -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ui-avatar-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build` → PASS（`** BUILD SUCCEEDED **`）。
  - `HOME=/tmp/ui-avatar-home CFFIXED_USER_HOME=/tmp/ui-avatar-home BOT_UI_SKIP_UI_TESTS=1 bash scripts/ci/bot-ui/capture.sh --appearance light --out /tmp/ui-avatar-shots` → PASS（40 screenshots；`/tmp/ui-avatar-shots/light/info.png`、`/tmp/ui-avatar-shots/light/infoAppearance.png` 已确认信息页只有一个顶部 80pt 头像、footer 为「点选即保存。」；`drawerAdd.png` 仍保留 104pt 预览）。
  - `python3 scripts/ci/protocol_impact.py --root . --base HEAD --body-file docs/protocol-changes/PC-20261111-bot-info-no-preview.md` → PASS（P09、P27 triggered，declaration matches）。
- 剩余风险、未支持平台：真机未跑；只有模拟器截图，不能据此声称真机像素或触控证据；Android/HarmonyOS
  无 Bot 页。

## 5. 修订记录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | ui-avatar | 初版：信息页去掉重复的 112pt 预览，顶部 80pt 头像随点选更新；添加对话框保留 104pt 预览 | iOS；P09 reviewer |
