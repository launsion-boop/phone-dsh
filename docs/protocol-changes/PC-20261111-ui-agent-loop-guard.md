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
| 4 | Claude | 真机自动测试 12 个只读任务（首轮 2/6 成功后停止）：①Home 在菜单没打开时仍盲点「主屏幕」位置，主屏上那里正好是钱包图标，进钱包后其浮动按钮压在辅助触控下面，Home 再也不起作用；②LaunchApp 只等 1.2 s，镜像还没显示新 App 就按第二次 Return；③板子 HID 执行器忙时回 503 busy_exec，动作直接失败；④「共享联系人」权限提示挡在前面，代理反复按 Home。改：Home 必须看到菜单打开（画面差 ≥6/255）才点主屏幕，否则重试、找按钮、最后如实失败并提示；LaunchApp 最多等 2.5 s 看新 App 出现；busy_exec 每 300 ms 重发、最多约 3 s（板子什么都没执行，重发安全，§2 写明）；权限／隐私提示一律 CallUser。 | iOS |
| 3 | Claude | 真机：UI-Venus 偶尔退化成重复思考 + JSON 动作（`{"action_type": "LaunchApp", "app_name": "小红书"}`），每步 16 s；JSON 解析不认 `app_name`，空名 LaunchApp 默认开「设置」，代理随后到处找小红书。解析认 JSON 的 `app_name`／`app`／`text`／`content`；空名 LaunchApp 报错给模型、不再默认；请求加 `stop: ["</action>"]`，并接受没有结束标签的 `<action>`。 | iOS |
| 2 | Claude | 真机：聊天模型把任务写成「读出电量…完成后返回设置首页」，设置重新打开就在电池页，代理读完照指令返回、又按任务再进，来回兜圈；守卫在第 9 步停下后，聊天模型又重开同一任务。代理提示：要读的信息一出现就 Answer，绝不先离开；提示语更明确（已看过这两个页面，直接用看到的信息回答）；工具用法说明：只写要达成或报告的内容、不加「再返回」步骤，结果以「卡住了」开头时如实告诉用户、不重开同一任务。 | iOS |
