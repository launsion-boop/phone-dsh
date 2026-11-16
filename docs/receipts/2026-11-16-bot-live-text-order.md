# 2026-11-16 Bot 正文顺序与卡片配色修复回执

<!-- SPDX-License-Identifier: MIT -->

Base: `908d582b9`（`feat/bot-activity-ios-v2` / `origin/main`）
Head: 本次工作树（未提交）
Protocol impact: **P09** — Bot 转写中 live 正文的插入位置，以及卡片配色到头像色的映射；没有新增/修改 wire 字段、schema、golden 或行投影。`P27: none` — row/card payload 未动。

## 1. 现象与根因

用户报告：Bot 先输出文字回复，再输出建议卡片时，页面突然跳到建议卡片，随后卡片上方的文字又重新出现，整页来回跳。

根因在 live 转写的组装顺序，不在滚动状态机：

- `displayRows` 在 live 回合中过滤掉该回合的 durable assistant 正文，正文由 live 帧渲染。
- 页面把 **整个 live 正文** 无条件挂载在所有 durable row 之后。
- `show_next_steps` / `ask_user` 是收尾动作：卡片 row 在正文之后才落库。于是 live 期间顺序变成
  `[卡片 row][live 正文]`，卡片先出现在正文上方；页面按 `newestActionableCard` 滚到卡片，看起来像“跳到卡片”。
- 回合结束、durable 正文 row 到达后，顺序恢复为 `[正文][卡片]`，卡片上方的文字重新出现，页面再跳一次。

同一问题在 Android 移植中同样存在（`BotChatPage.kt` 先画 `state.rows` 再画 live）。

## 2. 修法

| 端 | 文件 | 变化 |
| --- | --- | --- |
| iOS | `examples/probe-app/PhoneDSHProbe/Bot/BotLiveTurn.swift` | 记录本回合第一段正文的 durable 事件时间 `textStartedAt`（首个 `assistant/message`）；后续正文不会移动已放置的卡片。 |
| iOS | `examples/probe-app/PhoneDSHProbe/Bot/BotChatModel.swift` | `transcriptSections(from:)` 把 durable rows 按 `createdAt` 与 `textStartedAt` 分成 leading/trailing；`newestActionableCard` 仍取 `displayRows.last`，因此仍滚到卡片。 |
| iOS | `examples/probe-app/PhoneDSHProbe/Bot/BotChatPage.swift` | 用两个 `ForEach` 块夹住 live 正文：`leading rows → live 正文 → trailing rows`。live 必须留在独立块中——把 live 塞进 rows 的单一 `ForEach` 会让键盘打开时 dense-card fixture 滚到 live 尾部、问题卡不可点（base 单测通过，本 diff 首次尝试失败，改回独立块后通过）。新增 committed live 正文的 accessibility id，供 UI 测试断言语序。 |
| iOS | `examples/probe-app/PhoneDSHProbe/Bot/BotFixtures.swift` | 新增 `runningTextThenSteps` fixture：先 committed 正文，再落一张 `createdAt` 更晚的 steps 卡。 |
| Android | `android/lib/.../driver/BotChatModel.kt` | `BotLiveChatTurn.textStartedAt`；`BotChatSnapshot.liveInsertIndex`。 |
| Android | `android/lib/.../state/BotDerivedState.kt` | 纯函数 `liveInsertIndex(rows, textStartedAt)`。 |
| Android | `android/lib/.../page/chat/BotChatPage.kt` | 先画 split 前的 rows，再画 live/streaming，再画 split 后的 rows；同时修正 `scrollToItem` 的索引（live/streaming item 插在 rows 之间后，`rows.lastIndex` 不再是 LazyColumn 索引）。 |

顺序规则：在回合第一段正文之前创建的 row（例如引出解释的审批卡）留在正文上方；在它之后创建的 row（收尾建议卡、提问卡）留在正文下方。cutoff 每回合只钉一次，所以后续 delta 不会让卡片在正文上下移动；durable 正文到达时顺序不变。

## 2.1 同 PR 追加：卡片色与 Bot 头像色差距过大

用户反馈卡片颜色虽然跟随 Bot，但和头像设置的颜色差距很大。根因在 `BotCardTheme.accent` 的固定变换：

- 浅色模式：每个 RGB 通道 `* 0.42`。紫色 `#8F59F9` 变成 `#3C2569`（深navy紫），蓝色 `#1680F3` 变成 `#093666`。
- 深色模式：每个通道向白 `+ (1-value) * 0.48`。同一紫色变成 `#C5A9FC`（粉紫），头像仍是亮紫。

修法：

- 新增 `Sources/PhoneDSHBot/Profile/BotColorAccessibility.swift`：sRGB/HSB/相对亮度/WCAG 对比度；`accessible` 只沿亮度轴调整，保留色相和饱和度，必要时再向白/黑混合。目标对比度 4.5（12pt 文字/图标）或 1.5（装饰色）。
- `BotCardTheme` 拆成两个值：
  - `accent`：4.5 对比度，用于 eyebrow、图标、标签、次要按钮文字；
  - `brand`：1.5 对比度，用于卡片顶部 3pt 条、渐变 wash、进度条填充；大多数饱和色直接保留头像 hex。
- `buttonInk` 保持浅色白、深色黑；accent 已按对应背景做到 4.5:1，所以两种方案都成立，避免按钮文字颜色随色相跳变。
- 紫色结果：浅色 `#8F59F9 → #8A56F0`（旧 `#3C2569`），深色 `#8F59F9 → #9863FF`（旧 `#C5A9FC`）；蓝色浅色 `#1680F3 → #1475DF`。装饰色对蓝/紫/红/橙/绿等直接是原 hex。
- Android 的卡片仍是固定 `BotCardTone` 语义色（GAP-38 Android Bot 移植未完成），没有 appearance-bound 的 card theme；本 PR 不改 Android 的卡片色，避免半移植。

验证：

- `swift test --filter BotColorAccessibilityTests`：**PASS** 7 tests（15 色 × 明暗对比度、强色近距离、浅色可读、装饰色原 hex）。
- `xcodebuild build -scheme PhoneDSHProbe`：**PASS**。
- 截图（classic 蓝，`progress` fixture）：卡片顶条/进度条采样 **#1680F3**（与头像 hex 相同），eyebrow/勾选/链接采样 **#1475DF**（4.5:1 accent）；旧值为 **#093666**。证据在 `phone-dsh-fix-evidence/bot-card-color-20261116/`。

## 3. 验证

| 命令 | 结果 |
| --- | --- |
| `xcodebuild test -scheme BotChatModelUnit`（bot-e2e app，iOS Simulator） | **PASS** — `BotActivityLineTests` 38 + `BotChatModelTests` 26，0 failures（含 2 条新增顺序回归） |
| `xcodebuild build -scheme PhoneDSHProbe`（iOS Simulator） | **PASS** |
| Bot UI capture：`scripts/ci/bot-ui/capture.sh --appearance light` | 新用例 `testClosingStepsCardStaysBelowTheLiveAnswer` **PASS**；`testKeyboardOpenDenseCardsStayHittableAndTappable` **PASS**（base 上同一用例 **PASS**；单 ForEach 版本失败，独立块版本通过）。全量 26 tests 有 3 个失败，见下。 |
| `ANDROID_HOME=… ./gradlew :lib:testDebugUnitTest --tests 'com.phonedsh.ui.bot.driver.BotChatModelTest' --tests 'com.phonedsh.ui.bot.state.BotUiStateRulesTest'` | **PASS** — 17 + 36 tests / 0 failures（含 2 条新增顺序回归） |
| `ANDROID_HOME=… ./gradlew :lib:testDebugUnitTest --tests 'com.phonedsh.ui.bot.page.chat.*'` | **PASS** — 25 tests / 0 failures |
| `python3 spec/ui/v1/bot/tools/check_bot_ui.py --root .` | **FAIL（base 已存在）** — `strings.json[header.waiting.plural]` 锚点 `BotHeaderPresence.swift:70` 已过期；本 diff 未改 `BotHeaderPresence.swift`。 |

首次全量 capture 时，单 `ForEach` 版本让 `testKeyboardOpenDenseCardsStayHittableAndTappable` 失败（问题卡 `isHittable == false`，frame.y ≈ -328）；在 base `908d582b9` 上同一用例 **PASS**，确认是该版本的回归。改成独立 live 块后，keyboard 用例与新顺序用例分别 **PASS**。

最终全量 capture（独立块版本）的 3 个失败：

- `testApprovalDecisionAndAlwaysScopeNone`：断言「此操作仅支持单次授权」文案，未命中。
- `testLostTurnEndSettlesToDurableRows`：running fixture 的活动气泡未出现；**base `908d582b9` 上单跑同样失败**，与本次顺序修复无关。
- `testTaskAttachmentAndLongPressSource`：在「查看来源」sheet 后 runner 意外退出/超时，日志为 restart after unexpected exit；属该测试自身的模拟器 flake，未进入本 diff 的路径。

新顺序用例和 keyboard 用例在全量 suite 中均 **PASS**；base 对照只用于区分 keyboard/lost-turn 是否由本 diff 引入。

另：`testNewestActionableCardWinsOverTrailingLiveText` 原把已决审批的 `updatedSeq` 设成 2，低于初始行的 3；`upsert` 正确地丢弃过期更新，导致该断言在该 target 可运行后必然失败。改为 4。该 target 之前缺 `BotApprovalOffer.swift` 无法编译，本轮补上后才跑到这条断言。

## 4. 未验证 / 剩余风险

- 真机未安装、未验证。以上均为模拟器。
- 同一条 live 正文中间夹一张非收尾内容卡（progress/checklist），且卡片之后还有正文时，live 阶段仍把整段正文当作一个块；这一交错场景需要按段合并才能完全消除。本修复的 cutoff 规则保证收尾建议卡/提问卡与审批卡不再跨越正文跳动，且不会新增该场景之外的 durable/正文顺序变化。
- `check_bot_ui.py` 的 base 锚点漂移与本修复无关，未改 `strings.json` 或 `BotHeaderPresence.swift`。
