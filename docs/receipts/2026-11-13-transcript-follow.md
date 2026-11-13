# 2026-11-13 聊天跟随与「回到最新」修复回执

<!-- SPDX-License-Identifier: MIT -->

Base: `a2bb79dfe`（PR #159 合并后）
Head: 本次工作树（未提交）
Protocol impact: **P09: none** — 只改原生聊天页的本地滚动状态机与阈值，没有改 trajectory/ui-state 的 projection 格式或字段；`P27: none` — 卡片/行数据未动；其它 ID 未触发。

## 1. 现象与根因

### 1.1 BotChatPage：流式时尾部停住

`scheduleTranscriptScroll` 原实现每次触发都 `transcriptScrollTask?.cancel()`，再启动 120ms 的 sleep。流式 delta 的间隔通常小于 120ms，因此每次都被取消、永远等不到 fire；最后一段 Markdown/代码/卡片高度在这次“从未发生”的滚动之后才定型，又因为没有新的 key 变化，所以不会再有第二次滚动。表现就是“尾部往下长，但视口停在旧位置/跳上去了”。

`followsTail` 还有第二个脆弱点：程序化滚动/一次轻触的 settle 可能把 tail 判成 away，而 Bot 页没有「回到最新」胶囊可恢复；一旦为 false，后续所有流式触发都被 `guard followsTail` 丢掉。

### 1.2 ChatPage：「回到最新」容易触发、跳回后不跟随

`scheduleTailScroll` 同样每 50ms 取消重启；流式 token 快于 50ms 时同样永远不滚。`userScrolledAway` 用的是 44pt 的 near 带，而不是“故意离开”的阈值；内容增长、键盘/程序化跳转或动画中的一帧都可能把它置 true。点击「回到最新」虽然把 flag 清掉，但待处理的 scroll task 仍可能被取消/重启，或动画结束后没有新的触发，于是回到最新后不再跟随。

## 2. 修法

| 文件 | 变化 |
| --- | --- |
| `examples/probe-app/PhoneDSHProbe/Bot/BotChatPage.swift` | `scheduleTranscriptScroll` 改为最新请求盒 + generation；任务不取消，读最新 target/anchor，滚动后做一次 180ms settle 校正，再等新内容。`sendScrollTick` 和“tail 已回到 near”时重新 arm `followsTail`。`onDisappear` 取消任务。 |
| `examples/probe-app/PhoneDSHProbe/ChatPage.swift` | `scheduleTailScroll` 同样改为 generation + 180ms settle 校正；新增 `tailScrollViewportHeight`、`onDisappear` 取消；`userScrolledAway` 使用 96pt `isAwayFromTail`，near 时清除，用户驱动 settle 后 80ms 用最终几何再判一次；「回到最新」跳转取消待处理任务，动画后重新 schedule。 |
| `examples/probe-app/ProbeKit/ChatTranscriptTailPolicy.swift` | 新增 `awayMargin = 96` 与纯函数 `isAwayFromTail`，让阈值可测试。 |
| `examples/probe-app/PhoneDSHSimTests/ChatSessionSnapshotTests.swift` | 新增 44/96/24pt 边界与零 viewport 的用例。 |

## 3. 验证

| 命令 | 结果 |
| --- | --- |
| `xcodebuild test -only-testing:PhoneDSHSimTests/ChatTranscriptTailPolicyTests` | **PASS**（含新增 away-margin 用例） |
| `xcodebuild build -scheme PhoneDSH`（iPhone 17 Pro 模拟器） | **PASS** |
| Bot UI capture：`scripts/ci/bot-ui/capture.sh` | **PASS** — build + 22 个 XCUITest（`All tests passed`，0 failures）+ 61 张 fixture 截图 |
| `xcodebuild test -only-testing:PhoneDSHDeviceUITests/PhoneDSHDeviceUITests/testHistoryRestoreThenSendKeepsLatestMessageVisible` | **BLOCKED / NOT A CODE FAILURE** — 测试在 `createNewSession()` 等 `app.buttons["新建会话"]`，当前抽屉显示的是「新会话」（截图证据在 xcresult），15s 超时；它没有走到跟随断言。属于测试 label 与 UI 的既有不一致，需另开测试修复 |
| 现有 `swift test --filter PhoneDSHBotTests` | 未重跑；本 diff 只改 probe-app 视图，不改 PhoneDSHBot 包 |

## 4. 未验证 / 剩余风险

- **真机流式跟随**：**NOT_VERIFIED**。本机只有模拟器；主聊天 `testHistoryRestoreThenSendKeepsLatestMessageVisible` 需要 mock upstream + 设备 UI，未在本轮跑。
- **真机「回到最新」**：**NOT_VERIFIED**。阈值从 44pt 改为 96pt 后，小幅度上滑不会立刻出现胶囊；若产品希望更敏感，只需调 `ChatTranscriptTailPolicy.awayMargin`，不要把 near 带（44pt）直接当 away。
- 180ms settle 校正只覆盖一次晚到的布局；如果某个卡片在 >180ms 后才改变高度且没有新的行/key 变化，仍可能需要第三次校正。现有 settledCards 触发（300ms）和内容高度触发会补上大多数情况。
- `onScrollPhaseChange` 在程序化动画上是否报告 `.interacting` 因系统版本而异；本实现用“near 时清除 away”兜底，不依赖该假设。
