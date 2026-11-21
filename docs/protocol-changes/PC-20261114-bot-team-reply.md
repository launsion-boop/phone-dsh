# PC-20261114-bot-team-reply — 转交后的直接回复（回复上一跳）

## 0. 摘要（機器可讀）

```yaml
change: PC-20261114-bot-team-reply
contracts: [P25, P26, P27]
status: implemented
breaking: false
version_decision: no wire/schema/event-type/version bump. `BotAgentCommContext` gains one optional in-memory `inbound` hop (default nil; a host that does not supply it keeps today's cycle rejection), and the `SendToAgent` success object gains one optional `reply:true`. The reply row reuses the frozen P25 `agent.comm` event with the already-defined `reply` direction and the existing v2 `agent-held` item; no new event type, error code, tool, field on any persisted/wire format, or enum value.
base: 139d1026d5cc6f31fa92d890f47c563c43106580
contract_revision: spec/bot/v1/team.md @ bot-team-d12-v2（本 commit 冻结）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。** 真機 Bot SQLite `bot_events`：`main`＝大肥鱼、`agent-99f7b0759b04ede9`＝联调。
  联调 调 `SendToAgent{agent_id: main, delivery: "now"}` → 接受（`agent.comm` outbound，hop 1）。
  大肥鱼 随后向 联调 调 `SendToAgent`，得到
  `转交链已经走过 联调 → 大肥鱼 → 联调，联调 在这条链上，不能再转回去。请直接回答当前请求。`；
  联调 再回复 大肥鱼 也是同一类拒绝（“两个 Bot 之间的闭环确认走不了”）。用户反馈：
  “bot 和 bot 应该实现相互通信”“消息流有一条提示，但是他也没有被激活”。
  **現況**：`BotTeamTools.swift` 在 `chain.contains(target.id)` 时一律拒绝；`now` 投递在对方整个回合内
  安装 `chain = [sender, target]`，直到 `sendAgentMessage` 返回才释放；`queued` 安装一次性 pending
  context，在对方下一次 team 工具调用时消耗——恰好就是它想回复的时候。自动回复路径只把目标回合的
  最终 assistant 文本写回发送方 held inbox（`requestId: reply:<…>`），从不唤醒发送方。
  **期望**：收到队友转交后，直接回复**刚把消息交给自己的一方**是合法操作，不是环路错误：
  它是一次转交的结束，记录成 `reply` 行、写回对方 held inbox、不推进 hop、不安装链；
  原投递与本次回复都为 `now` 时唤醒发送方一次，任一侧 `queued` 保持静默。真正的环（目标是更早的、
  非相邻的跳）与新 hop 超过 2 层仍用既有错误句拒绝。
- **Coordinator / contract owner：** 本 lane（`fix/team`，worktree `/tmp/pdsh-fix-team`），兼 implementer
  与 reviewer。**Implementers：** Swift 在同一个 lane 完成；Kotlin B6 `not started`，开始时必须按本
  revision 实现，不能沿用 D12 outline。**Reviewer-integrator：** 父整合 head，必须在本 commit 的
  head SHA 上确认 Swift tool、App composition 与 fixtures 处在同一 revision。
- **Owning spec / schema / shared fixtures：** `spec/bot/v1/team.md`（§2.1 校验顺序、§2.3 hop/环/回复、
  §2.8 结果、§2.9 行、§2.10 held 回复、§5 catalog、§6 相容）、`spec/bot/v1/README.md` §1.1、
  `spec/bot/v1/golden/team-cases.phone.json`、`spec/bot/v1/golden/tool-catalog.phone.json`
  （`team.sendToAgent.descriptionContains`）、`spec/bot/v1/export-manifest.json`（两个 digest）、
  `spec/bot/v1/tools/validate_vectors.py`。
- **受影響 producer/consumer：** P26 Swift `Sources/PhoneDSHBot/Team/{BotTeamHost,BotTeamTools}.swift`
  与 `MCP/BotToolCatalog.swift`（team 描述）；App composition 的 agent-comm 区
  `examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift`（`BotAgentCommTracker`、
  `deliverToAgent` 的 setActive/clearActive、`enqueueHeld`、durable 索引）；P27 row projection 沿用
  `agent.comm`，不需要改；P25 durable event 仍是 `agent.comm`；Kotlin B6 未开始；HarmonyOS 无 Bot
  runtime；P05 无 wire 变更。

## 2. 契約 delta

只列改動；未變語義引用 owning clause，不複製整份協議。

| 項目 | Before → After／依據條款 |
| --- | --- |
| 接受／拒絕規則 | `target.id ∈ chain` 一律拒絕 → **回复上一跳**：`context.inbound != nil`、`context.chain.count ≥ 2`、`context.chain.last == caller`、`context.chain[count-2] == target.id` 时按回复接受；`chain` 中任何其他命中（更早的非相邻跳）仍按环拒绝，错误句逐字不变（`team.md` §2.3）。 |
| hop | `depth = inbound depth + 1`，`> 2` 拒绝；**回复不推进 hop**：inbound depth 为 2 的调用者仍可回复上一跳，但不能向第四人发起新 hop（`team.md` §2.3）。 |
| 链 | 回复不安装链：写回的 held item `handOff = nil`；发送方的下一次 `SendToAgent` 是**新的** hop-1 转交，不是同一链的下一跳（`team.md` §2.3）。 |
| 行 | 回复在**回复方**写一条 `BotTeamAgentCommRecord`：`direction:"reply"`、`role:"assistant"`、`text`＝消息、`toAgent{id,name}`（不带 `kind`）、`threadID`/`requestID` 取自 inbound 交换、`rowID = t<turn>u[<n>]`（回复方 context 的 turn/existingRowIDs）、`callID`＝本次回复调用 id。成为既有 P25 `agent.comm` durable event（`team.md` §2.9）。 |
| held item | 与自动回复同形：`kind:"agent-held"`、`fromAgent`＝回复方、`title`＝`回复：<inbound title>` / `回复`、`text`＝消息前 **1,200** grapheme、`requestId = "reply:agent:<reply callId>"`、`threadId`＝交换 thread、无 `handOff`、`state:"pending"`（`team.md` §2.10）。 |
| 唤醒 | 恰好一次**尽力**唤醒原发送方：当且仅当 inbound 投递为 `now` **且**回复调用也要求 `delivery:"now"`；`queued`（任一侧）保持静默。唤醒失败不回滚已写的行与 held item（`team.md` §2.10）。 |
| 结果 | 成功对象新增可选 `"reply":true`，`threadId`＝原交换 thread，`requestId = "agent:<reply callId>"`，`delivery` 回显本次调用；`content[0].text` 固定为 `已回复 <name>：回复已写入对方的 held inbox，这次回复不算新的转交。`（`team.md` §2.8）。 |
| 错误 | 不新增错误码：参数/层/环仍是 `invalid_arguments`；回复行已写、held inbox 写失败为 `execution_failed` `held inbox write failed: <failure>`（复用既有句，不造第二个语义相同的码）。 |
| idempotency | 回复行以 `callID` 进入宿主 durable thread 索引；重放先查 `agent:<callId>`，再查兼容的 bare `callId`：命中返回 `duplicated:true` 与既有 thread，不写第二行、不再入队、不再唤醒（`team.md` §2.4）。 |
| catalog | `SendToAgent` 描述追加：收到队友转交后直接回复对方是合法操作（不开启新的转交），最终回答也会自动写回对方 held inbox（`team.md` §5）。 |
| 條款狀態 | `team.md` 本修订为 `implemented`（Swift）；Kotlin B6 仍 `not started`，其 catalog 文案在 B6 落地前保持旧句（见 §3 的已知差异）。 |

**自檢（spec/README.md §5.1）：** 没有新增 wire 字段、schema 版本、事件类型、错误码、enum 值或工具名；
`inbound` 是宿主内存 seam 的可选成员（旧宿主不供即保持旧行为）；`reply:true` 是可忽略的可选成功成员；
`agent.comm` 的 `reply` 方向与 `direction` enum 早已在 `event-envelope.schema.json` 冻结；没有把
“回复”做成第二套投递机制——回复仍是 `agent-held` item，只是一个不推进链的结束通知。唯一“放宽”是
原本被当作环拒绝的**相邻上一跳**现在被接受；同一变更用 golden 的正反例把“更早非相邻跳”“hop > 2”
“queued 不唤醒”固定住，`invalid[send-cycle]` 不弱化。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old host → new tool | 宿主的 `BotAgentCommContext` 没有 `inbound`（默认 nil）时 `immediatePreviousHop` 返回 nil，`SendToAgent` 走原来的 depth/cycle 路径，回复仍以既有错误句拒绝：旧宿主行为逐字不变，不会静默产生 reply 行或 held item。`team-cases` 的 `invalid[send-cycle]`（无 inbound）与 Swift `BotTeamCasesTests` 覆盖。 |
| new host → old tool | 无新 wire 字段/事件类型；旧 tool 从不写 `reply` 行、不认 `inbound`（字段被忽略）。新 tool 写出的 `reply` 行是既有 `agent.comm` + 既有 `reply` 方向，旧 reader 按既有方向投影；held item 是既有 v2 `agent-held` 文档。 |
| new → new | Swift tool 与 App composition 在同一 commit：composition 在 `now` 投递时安装带 `inbound` 的 active context 并在回合结束释放，`queued` 的 `handOff` 携带同一 `inbound`，`enqueueHeld` 按请求唤醒。`Tests/PhoneDSHBotTests/Team/` 的 round-trip 测试走真实 install/release；`team-cases.phone.json` 的正反例同时驱动 tool 与 fake host。 |
| persisted old data → new／rollback | 不迁移、不重写：本修订之前不存在 `reply` 行；本修订写出的 `reply` 行是普通 `agent.comm` durable event，回滚到旧 App 仍可读、按既有方向投影（旧代码对 `reply` 的 unread/projection 规则本来就已冻结）。回滚后回复重新被当作环拒绝，已写入的 reply 行与 held item 保留可读。 |

- **版本／adapter 決定。** 不升 Bot event schema、SQLite schema、MCP protocol 或工具 schema 版本；
  不新增 route/header/env。`inbound` 只在宿主内存中传递（进程重启即丢失，与既有 chain 语义一致，
  `team.md` §2.3）；不得持久化它。
- **bundle／image／native artifact。** 不涉及 Worker bundle、native ABI 或 image 产物；App 与 package
  同 commit 更新。
- **`target`／`draft` 條款中保留的差異。** Kotlin B6 `not started`：`android/bot/.../BotToolCatalog.kt`
  的 `SendToAgent` 描述仍是旧句，且 Kotlin 尚无 `inbound` seam；B6 开始时必须按本 revision 实现并
  同步描述。Team 共享/发布/克隆、团队记忆等仍不在本期。

## 4. 分工與證據

- **本 lane 的獨占路徑：** `Sources/PhoneDSHBot/Team/**`；`Sources/PhoneDSHBot/MCP/BotToolCatalog.swift`
  的 team 描述；`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift` 的 agent-comm 区
  （`BotAgentCommTracker`、`agentCommContext`、`deliverToAgent` 的 setActive/clearActive、
  `enqueueHeld`、durable thread 索引；不碰 `bind()`/`select()`）；`Tests/PhoneDSHBotTests/Team/**`；
  `spec/bot/v1/{README.md,team.md,golden/team-cases.phone.json,golden/tool-catalog.phone.json,
  export-manifest.json,tools/validate_vectors.py}`；本变更单。
  任务书写的 `Sources/PhoneDSHBot/MCP/BotRuntimeComposition.swift` 在 base 不存在；composition 的实际
  位置是 `examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift`（行号 1379-1381 与之对应）。
- **共享 fixtures：** `golden/team-cases.phone.json` 新增 `send-reply-to-previous-hop`、
  `send-reply-at-depth-two`、`send-reply-queued-no-wake`、`send-reply-to-queued-handoff-no-wake`
  四个正例与 `send-reply-older-hop-cycle`、`send-reply-depth-three-new-hop`、
  `send-reply-without-inbound-context` 三个反例（17 valid / 23 invalid）；`contract.sendToAgent`
  追加 `replyText`、`replyHeldRequestIdTemplate`、`replyRowDirection`、`replyRowIdTemplate`、
  `replyAddsHop`、`replyInstallsChain`、`replyWakeRule`、`replyPredicate`、`replyResultMember`；
  `rowCases.reply-event` 补顶层 `callId` 以固定 durable 幂等键（`agentComm.reply` 形状不变）。
- **各端真實 producer/consumer 測試：**
  - `Tests/PhoneDSHBotTests/Team/BotTeamCasesTests.swift` 读 fixtures 驱动真实 `BotTeamTools`、
    `BotAgentCommIdentity`、`BotTeamAgentCommRecord`（包含新增的 `wake` 断言）。
  - `Tests/PhoneDSHBotTests/Team/BotTeamToolsTests.swift` 覆盖：回复上一跳被接受并唤醒一次、
    不安装链、深度 2 回复、更早非相邻跳仍用既有环句、hop > 2 新 hop 仍拒绝、queued 回复不唤醒、
    重放幂等、以及经 `FakeBotTeamHost` 真实 install/release 的 A→B→A round trip（回复行 + 两条 held
    item + 单次唤醒）。
  - `Tests/PhoneDSHBotTests/Team/TeamTestSupport.swift` 的 fake host 现在按生产语义安装/释放 active
    context、消费一次性 pending context、按 `callID` 索引 reply 行并记录唤醒请求。
- **Baseline 前提：** 本 worktree 的 base 已有两个与本变更无关的红灯，均先记录未静默绕过：
  `spec/bot/v1/export-manifest.json` 的 `mcp-rpc-cases.phone.json` / `tool-effects.phone.json`
  digest 自 vision commit `4f4955d70` 起未更新（`check_golden.py` 在 base 即 FAIL）；本变更顺手
  重算这两个 digest（纯生成物，无内容改动），否则 `phone-spec` 无法验证本变更。`phone-hygiene`
  在 base 即因 `spec/v1/tono-account.md` 与 `golden/tono-account/cases.json` 的 `tonoai` 命中而
  FAIL，本变更不触碰该文件，也不改 allowlist。
- **Exact commands → result（本 commit 实测）：**
  - `swift test --filter PhoneDSHBotTests` → **FAIL（既有红灯，非本变更）**：778 tests，3 个失败
    测试 / 6 条断言失败，全部在 `BotApprovalResultTextTests` 与
    `BotMCPIdentityApprovalCasesTests`（approval scope：期望 `session|until`，实得 `once`）。
    把本变更的 Sources/Tests 路径 stash 后在同一 worktree 重跑这两个 class，得到同样的确定性失败，
    证明它们在 base 即失败；失败测试与代码均不在本 diff 内。本变更自身的
    `BotTeamCasesTests` / `BotTeamToolsTests` / `BotTeamCommPersistenceTests` 全部通过。
  - `python3 spec/bot/v1/tools/validate_vectors.py` → **PASS**（team-phone 17 valid / 23 invalid /
    4 row cases，11 mutation checks）。
  - `python3 spec/tools/bot/check_golden.py --root .` → **PASS**（47 files / 16 upstream /
    31 overlays；修复了 base 遗留的两个 stale digest，见上）。
  - `bash scripts/ci/check.sh --only phone-spec` → **PASS**（2414s）：`spec/v1` 105 files / 0 error、
    265 个 spec tool 测试 OK、bot vectors `team-phone 17 valid / 23 invalid / 4 row cases / 11 mutation`、
    `bot golden PASS (47 files / 16 upstream / 31 overlays)`、PCLink schema/vectors PASS。
  - `bash scripts/ci/check.sh --only phone-hygiene,phone-license` → **license PASS**；
    **hygiene FAIL（base 既有）**：`spec/v1/tono-account.md` 与 `golden/tono-account/cases.json`
    的 `tonoai` banned-word/hostname 命中（398 条），该文件不在本 diff 内，本变更不改 allowlist。
  - App composition 的编译不在 `swift test` 覆盖范围内（`examples/probe-app` 不是 SwiftPM target）。
    `xcrun swiftc -parse …/BotRuntimeComposition.swift` → **PASS**；把 app Bot 源码对着 iOS 模拟器
    SDK 的 `PhoneDSHBot` swiftmodule 做 ad-hoc `-typecheck` 时，composition 自身 0 error，但整包
    typecheck 因 app 专属第三方 module（`GoogleSignIn`/`Markdown`/`SwiftMath`）与生成工程缺失而
    **INCOMPLETE**；`xcodegen generate` 因 gitignored `Bundle/worker` 缺失而失败，Xcode 全量编译
    **NOT_RUN**。
- **剩餘風險／未支援平台：**
  1. reply 行 rowID 仍属 `t<turn>u` 家族，而 durable `eventId = "agent.comm:" + rowID` 在**全局**
     域去重；不同 Bot 的同一 turn 号可能撞 id（既有 inbound 行已存在的风险，本修订新增 reply 行会
     增加同类概率）。本变更**不修**该 id 域问题，需另开变更单（owner：Bot store/agent-comm）。
  2. 唤醒是尽力而为：发送方回合正忙时 `wakeWithHeldMessages` 不会开新回合，回复仍耐久落在 held
     inbox 并在下一次回合被折叠；“唤醒一次”只保证调用一次，不保证立刻开始回合。
  3. 回复结束这次转交后，被唤醒方再次 `SendToAgent` 是**新的** hop-1 转交；跨回合的 A→B→A→B
     不是同一条链，环保护不跨回合生效。回合成本是唯一节流，属于已接受的产品语义。
  4. `BotUnreadRules.reply` 把未读加在行所有者（回复方）身上；回复行现在由回复方写，可能让回复方
     看到自己的未读。该规则是既有冻结行为，本修订不改。
  5. Kotlin B6 未开始；其 catalog 文案与回复规则 owed。
  6. App composition 的运行时行为未在真机验证；本 lane 只做静态/单元验证。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `bot-team-d12-v2` | `fix/team` contract owner | 真机复现“转交后无法回复上一跳、闭环确认未激活”；把相邻上一跳的显式回复定为合法结束通知，同时保留真环/层数拒绝 | Swift tool + App composition（同 commit）；Kotlin B6（未开始，记录为 owed） |
