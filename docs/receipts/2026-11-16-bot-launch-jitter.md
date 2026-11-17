# 2026-11-16 Bot / DSH 冷启动转写抖动修复

<!-- SPDX-License-Identifier: MIT -->

Base: `d71b46f61`（`main`，PR #188 合并后）
Head: 本次工作树（未提交）
Protocol impact: **P09** — 冷启动转写的初始滚动/分页时机；`P27: none` — row/card/payload 未动。

## 1. 现象与根因

用户报告：每次重新打开 App，默认 Bot 页带着上次输出时，页面内容 100% 抖动；DSH 页也有类似现象。

根因不在数据恢复，而在转写的跟随滚动有两个叠加问题：

1. **初始位置被当成普通跟播动画。** Bot 页的 `scheduleTranscriptScroll` 每一轮都用
   `withAnimation(.easeOut(0.18))`。启动时 `contentHeight` 先到、`defaultScrollAnchor(.bottom)`
   随后才把内容放到末尾，第一次跟播会从旧位置滑到末尾；180ms 后的“settle”轮又无条件再滑一次。
   模拟器逐帧测量：恢复 30 轮对话后，转写出现后的两帧分别上移 **78px / 44px**，第三帧才停。
2. **初始落位期间的历史分页也在抢滚动。** Bot 的历史 sentinel 在首帧可见时会 expand/load
   history 并 `scrollTo(anchor: .top)`；DSH 的 cached-tail 状态行原本是 LazyVStack 的一行，
   cached → live 切换时整行插入/删除，改变滚动内容高度。两者都会和“先去尾部”的初始落位
   互相拉扯。

## 2. 修法

| 文件 | 变化 |
| --- | --- |
| `Sources/PhoneDSHBot/BotTranscriptLayoutSupport.swift` | 新增纯值 `ScrollPass` 与 `shouldPerformScrollPass`：只有 generation、contentHeight（0.5pt 容差）或 target 变化才允许下一轮跟播；相同轮次直接停。 |
| `examples/probe-app/PhoneDSHProbe/Bot/BotChatPage.swift` | 首轮落位标记 `initialTailPlacementPending`：首轮和 0.6s 内的修正都不带动画，只做一次普通 `scrollTo`；之后才恢复 easeOut 跟播。历史 sentinel 在首轮落位前不分页。 |
| `examples/probe-app/PhoneDSHProbe/ChatPage.swift` | DSH 跟播循环改用同一 `ScrollPass` 去重，去掉无条件的第二次 settle 滚动；历史 sentinel 在 `pendingInitialScroll` 消费前不分页；cached-tail 状态行移出 LazyVStack，改为顶部 overlay，cached → live 不再改变滚动内容高度。 |

顺序规则：

- 启动/恢复时先做**一次无动画**的尾部落位；首帧 Markdown/卡片高度修正也不动画。
- 相同 target + 相同高度的重复 pass 直接停，不再每 180ms 重复滚同一个位置。
- 初始落位完成前，不自动分页历史；完成后保持原行为。

## 3. 验证

| 命令/检查 | 结果 |
| --- | --- |
| `swift test --filter BotTranscriptLayoutSupportTests` | **PASS** — 10 tests（含 1 条 `ScrollPass` 回归） |
| `xcodebuild build -scheme PhoneDSHProbe`（iOS Simulator） | **PASS** |
| `PhoneDSHDeviceUITests/testLaunchOpensOnBotTab` | **PASS** |
| `PhoneDSHDeviceUITests/testLongTranscriptInitialTailStaysAboveTallComposer` | **PASS**（最终重跑；该用例在本机偶发 preview cover 未出现的 harness flake，非本次代码路径） |
| Bot 恢复 30 轮对话的模拟器逐帧测量 | **修复前**：转写出现后连续两帧 78px / 44px；**修复后**：`正在连接 Bot…` 被转写替换后的所有帧 0px 位移。证据：`phone-dsh-fix-evidence/bot-launch-jitter-20261117/` |
| 真机 | **NOT_RUN** |

DSH 的真实 cached 快照复现未成功（模拟器上恢复流程被当前 session 的 live log 抢先填充），因此 DSH 侧结论来自代码路径 + build/既有启动 UI 测试，不是逐帧真实验证。

## 4. 剩余风险

- 真机未验证；不同机型/帧率下 0.6s 的 settle 窗口可能需要调整。
- 初始落位前禁止历史分页；对“内容比视口短但仍有更早历史”的会话，首次自动分页会推迟到用户滚动或下一次几何变化。这是为了避免启动时 sentinel 与尾部落位互相拉扯。
- DSH 的 cached → live 内容本身如果行高不同，仍可能有一次性布局差异；本次已消除状态行导致的滚动内容高度变化。
