# 2026-11-14 Bot 创建后一次性开场（A′）回执

<!-- SPDX-License-Identifier: MIT -->

## 实现

- 新增 `BotOnboarding.item(botID:now:)`：
  - `kind = "onboarding"`，走 `WakeInboxItem` / `WakeInbox` 的 durable stage/commit；
  - request id = `BotTurnOrigin.heldRequestId(digest: SHA256("onboarding:<botID>:1"))`；
  - `BotOnboarding.version = 1`，内容变更时升版本；
  - 不新增 `BotTurnOriginKind`、不新增 session kind。
- 创建入口统一在 `BotRuntimeComposition.createBot`（App 创建和主 Bot `CreateTeammate` 都走这里）：
  - 先 `enqueueOnboarding(botID:)`；
  - `started` 时异步 `ensureUnit` 并 `wakeWithHeldMessages`；
  - 若 Worker/session 尚未就绪，item 保持 pending，`BotRuntimeUnit.start` 成功后补一次 wake。
- 竞态：
  - `wakeWithHeldMessages` 只在没有运行/排队 chat turn 时开口；
  - 用户先开口时，`sendUserMessage` 将 pending item stage 成 held block，合入该回合，不额外回答；
  - Wake 先开口时是正常可见回合，用户下一条消息排队/steer。
- `HeldMessages.block` 新增 `[onboarding]` 行和对应 header 文案；所有字段仍按 held 文本转义。
- 默认可见回合，不隐藏。

## 指令

开场 prompt 写在 `BotOnboarding.prompt`：读描述/runtime-context，给出 2–3 个真实可执行的 `show_next_steps`，正文一句话说明身份能力，不罗列工具，不追问“接下来做什么”，不超过 3 句。

## 测试

- `BotOnboardingTests`：item/request id 确定性、文本长度、held 转义、enqueue 幂等；
- `BotDSHRemoteRuntimeTests.testOnboardingWakeOpensVisibleHeldTurn`：真实 wake 后 prompt 含开场指令、request id 为 `held:`、inbox 消费；
- App 模拟器/真机构建 **PASS**。

## 边界

- 只覆盖通过 `BotRuntimeComposition.createBot` 新建的 Bot；首次启动的默认 `main` Bot 不走这次 onboarding。
- 目标 Bot 若在同一进程已经启动，创建后会异步启动 unit 并 wake；Worker 尚不可用时保持 pending。
- 该 item 不会被 `sendAgentMessage` 折叠；队友消息期间 pending，等用户回合或 unit start 时消费。
