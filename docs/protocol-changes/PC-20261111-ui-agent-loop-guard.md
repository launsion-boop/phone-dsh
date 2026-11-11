# UI 代理：动作没效果要告诉模型，反复兜圈就停（P07）

```yaml
change: PC-20261111-ui-agent-loop-guard
contracts: [P07]
status: implemented
breaking: false
version_decision: Behaviour inside the existing agent (tonolink-board.md §6). The iphone_agent_run result shape is unchanged; a stuck run is finished=false with an answer starting 「卡住了」.
base: e223d399
contract_revision: spec/device/v1/tonolink-board.md §6 @ this PR head
```

Protocol impact: P07; P05: none — the iphone_agent_run tool name, input, result fields and errors are unchanged; P09: none — no page, row or copy changes; P27: none — IPhoneAgentHost.swift changes only LaunchApp's Return handling, PC Link is unchanged

P07 — the agent compares consecutive screenshots and tells the model when an action changed nothing; repeated or ping-pong actions get one nudge, then the run stops; LaunchApp presses Return again while Spotlight is still showing.

## 1. 问题（真机日志）

- 「查看电池电量」：已经进了电池页，却在「< 设置」(206,185) 与「电池」(895,427) 之间来回点 7 次，用完 15 步，报「没有在 15 步内完成」（用户：明明到了正确的页面，像个无头苍蝇）。
- 「打开小红书」：拼音键盘把 `xiaohongshu` 留在候选栏，Return 只上屏，LaunchApp 却报「launched」；之后误入钱包，PressHome 连按 9 次都没效果（截图 8–15 完全相同），用完步数。

动作执行后一律报成功，模型不知道没效果；也没有任何东西阻止它重复。

## 2. Delta

| 项 | Before → After |
| --- | --- |
| 动作效果 | 不检查 → 每步比较前后截图（36×52 灰度平均差 < 2/255 视为没变），没变就告诉模型 |
| 重复 | 无限制，直到 15 步 → 同一动作 3 次或 A⇄B 两轮：提示一次（且不执行这次重复）；再犯即停止，`finished=false`、答案以「卡住了」开头 |
| LaunchApp | Return 一次、报 launched → Return 后仍是 Spotlight 就再按一次；返回文字如实写「searched … pressed Return」 |

## 3. 相容性

工具名、输入、结果字段与错误码不变；调用方只会更早拿到 `finished=false`。

## 4. 证据

见 PR。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知 |
| --- | --- | --- | --- |
| 1 | Claude | 初版 | iOS |
| 2 | Claude | 真机：聊天模型把任务写成「读出电量…完成后返回设置首页」，设置重新打开就在电池页，代理读完照指令返回、又按任务再进，来回兜圈；守卫在第 9 步停下后，聊天模型又重开同一任务。代理提示：要读的信息一出现就 Answer，绝不先离开；提示语更明确（已看过这两个页面，直接用看到的信息回答）；工具用法说明：只写要达成或报告的内容、不加「再返回」步骤，结果以「卡住了」开头时如实告诉用户、不重开同一任务。 | iOS |
