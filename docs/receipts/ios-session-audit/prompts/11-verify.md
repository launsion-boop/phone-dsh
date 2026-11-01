# Axis 11 — 交叉验证与纠错

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文，然后读 01–10 的报告：

- `01-data-path.md` … `10-completeness.md`

报告路径：`docs/receipts/ios-session-audit/11-verification.md`

## 目标

你是“复核者”。01–10 是并行审计，可能有幻觉引用、过度断言、把“实验包”当官方、把“截图观察”当源码事实、尺寸算错、状态机漏分支。请用源码逐项抽验，给出可信度评级与修正，确保最终汇总不会把错误结论带给用户。

## 必须做

### A. 引用抽验

1. 对 01–10 报告中的 `file:line` 引用做抽样验证（至少 40 个，覆盖每个报告）：
   - 打开文件，确认该行确实是报告声称的内容（类型/组件/CSS/事件）
   - 行号偏移 ±3 内可接受；完全不对记错误
   - 对“官方不存在”“iOS 不存在”的断言，自己跑一遍 grep 确认
2. 特别抽验所有 P0 断言与“完全缺失”断言。
3. 检查官方路径是否都在 `7be5505b0b` 这棵树上；检查是否把 `lib/` 构建产物当源码、把 experimental 包当 shipped。

### B. 事实核对

4. **数据链路**：`agent/inbox/spliced` 是否真的被 `DSHEventMapper` 映射、被 `ChatModel.handle` 丢弃、被 `NativeTranscriptProjector` 忽略；worker/channel 是否转发。逐条确认。
5. **事件/节点清单**：官方 `ChatNodeDataMap` / `tool.call.toolview` / docks 的数量与报告是否一致；shipped composition 是否包含对应包。
6. **像素/尺寸**：抽查报告中的 CSS 值是否与源码一致；`--dsw-radius-*`、字号/行高、`--dsh-*` 变量是否解析正确；iOS 当前值是否准确。
7. **状态机**：抽查 question/plan/subagent/timeline 的关键分支是否漏了（例如 error/stopped/review/skipped/one-shot/continuable）。
8. **文案**：抽查中文串是否来自官方 locale，而不是报告作者自译。
9. **范围**：是否有报告把设置页/会话列表/工作区的内容混进 session 会话线；是否漏了 phone 定制 UI。

### C. 冲突与修正

10. 列出 01–10 之间的冲突（同一事实不同说法），判定哪个正确，给出证据。
11. 对错误引用/错误结论给“修正表”：报告、原文、问题、正确说法、证据。
12. 对“无法从源码确定”的项，标注 `UNVERIFIED`，不要强行下结论。
13. 评估每份报告的可信度：A（可直接用于实现）/ B（有小错，修正后可用）/ C（方向对但细节不可靠）/ D（需重做），并说明原因。

### D. 最终建议

14. 给出一份“实现前必须补齐的验证清单”：哪些结论需要真机/官方 Web 实测，哪些需要产品决策，哪些需要补测试。
15. 如果发现某个 P0 其实是伪缺口（iOS 已有等价实现/数据可达），明确纠正。
16. 如果发现报告漏了用户点名的四类（计划、提问、子 Agent 状态/消息、收到新消息）中的任何关键状态，补一段“补充发现”。

## 质量要求

- 你的价值在“抓错”，不要复述报告。
- 每个修正必须给源码 `file:line` 和可复现的 grep/read 证据。
- 不要改源码；只写 `11-verification.md`。
- 可以读 10 的 master checklist 来检查覆盖，但不要被它带偏；以源码为准。

完成后按 BRIEF 的 JSON schema 返回：`axis` 用 `11-verification`，`top_gaps` 放最严重的错误/遗漏（最多 8 条），`unknowns` 放需要实测/决策的项。
