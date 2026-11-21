# 2026-11-14 建议卡使用率：低成本优化回执

<!-- SPDX-License-Identifier: MIT -->

## 判断

`show_next_steps` 使用率低的直接原因不是模型单次“偷懒”，而是三处设计叠加：

1. 工具描述说成功调用会结束回合；
2. 宿主在这个工具成功后压掉后续助手文本；
3. prompt 第 59 行说只有“真实取舍”才出卡，第 62/63 行又说建议/下一步应该用卡——模型可以按前者把建议写成正文列表。

`show_next_steps` 仍然保留“成功即收尾”的协议行为；本次只修正模型面文案，不改变宿主事件时序，也不做正文自动生成卡片。

## 改动

### P0a：允许“完整正文 + 最后一张卡”

- `BotToolCatalog.show_next_steps` 描述改为：
  - 先写完整答案；
  - 把卡片作为最后一个动作；
  - 卡片成功后仍不再输出。
- prompt 中英文同步：
  - 明确“提问卡”只用于真实取舍；
  - `show_next_steps` 是建议卡，不受该限制；
  - 回复有建议/下一步时，先写完整结论和一句理由，再调用卡片；
  - 做完一件事有自然后续时，优先给 2–4 个真实下一步，不硬造。

### 为什么不做 P0b / P1

- P0b“宿主在 turn/end 附着卡片”需要缓存卡片事件、改 projection/durability，并处理中断；收益不如先验证文案。
- P1“回合末提醒”在 `turn/end` 后已经无法影响当前回合；要生效必须 pre-final 再跑一步模型，成本和重复正文风险高。
- 不做正文选项的自动生成；边界保持不变。

## 测试

- `BotFinalCardSuppressionTests.testShowNextStepsKeepsCompleteProseBeforeTheCardButDropsTrailingText`：
  - 完整正文保留；
  - 建议卡 row 存在；
  - 卡片之后文本仍被压掉。
- `BotCardPayloadTests` 增加工具描述契约：`complete answer first`、`last action`、`ends the turn`。
- `plugins/bot-runtime/scripts/check-prompt.mjs` 增加中英文提示词断言，防止第 59 行再次把建议卡归入“真实取舍”。
- `BotCardPayloadTests`、`BotFinalCardSuppressionTests`、`BotToolCatalog*` 共 28 个测试 **PASS**；prompt check **PASS**。

## 未验证

- 真机模型使用率是否上升需要 next-turn 数据；本次没有做模型 eval 采样。
- 卡片顺序仍由工具调用位置决定；若模型先调用卡片再写正文，正文仍会被压掉。文案要求“卡片最后”，但没有宿主强制。
