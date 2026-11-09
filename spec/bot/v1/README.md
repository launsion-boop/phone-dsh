<!-- SPDX-License-Identifier: MIT -->

# phoneDSH Bot v1 契约

状态：`target`。本目录冻结 P25 BotEventLog、P26 BotToolSurface、P27 BotRows 的共享语义；静态 schema/golden 通过不等于 Swift、Worker、模型或真机已经实现。

唯一上游规格是 dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`，由 `dshbot-pin.json` 固定。除 Mac 专属和手机平台限制外，各子系统复用其语义。不得恢复 PR29 的 NativeToolLoop 主循环、Mandate、Ticket 或 MandateTokenStore。

## 1. 架构与存储

- 主 Bot 是 WKWebView Worker 中的一个 DSH session。每个 Bot 只有一条连续主对话；routine 与 Task 使用各自的后台 session。
- Swift 宿主常驻负责事件、授权、记忆、routine 调度、通知、账本和 Watchdog。WebContent 终止不能丢失 durable 数据。
- Bot 事件写 SQLite，不使用 JSONL 作为权威存储。`commitSeq` 由 SQLite 在同一事务中分配，单调且无缺口；`eventId` 去重。P03 journal 是另一序号域，不得混用。
- effects outbox 至少一次投递，包含 lease、去重、dead-letter 和 needs-reconciliation。接受、持久化和外部副作用完成是不同事实。
- SQLite schema v2 增加 `bot_user_action_nonces(bot_id, nonce, event_id, created_commit_seq)`，主键为 `(bot_id, nonce)`，`event_id` 唯一并引用同库动作事件。v1 打开时原地迁移，已有事件和 effects 不变；v2 拒绝更未来版本。回滚到只支持 v1 的 App 会明确拒绝该库，不删除或静默降级。
- 第一版不做回退引擎、回滚、import、Team 共享/发布/克隆、团队记忆/审核队列、Bot 模板导入导出、`CreateAgent` 云端工具、Box、CloudAgent、GenerateImage 或 macOS 本机工具。多 Bot 名册、逐 Bot 会话/记忆/held inbox 与 `SendToAgent`/`CreateTeammate` 见 §1.1；sidebar section 接受但忽略。

### 1.1 多 Bot 与 Team 边界

phoneDSH 从本期起支持多 Bot：名册沿用 dsh-bot 的 `agents-index.json`（`schemaVersion: 3`）和 `runtime-settings.json` 的 `mainAgentId`；每个 Bot 有独立的 DSH 会话、记忆、例行任务、授权、held inbox 与未读计数。首个 Bot 成为主 Bot；主 Bot 是指针，不是记录字段。删除主 Bot 时指针移到剩余第一个 Bot；隐藏的 Bot 仍留在名册，但不进入模型可见的工具描述。

- `SendToAgent`：`agent_id` 必填（接受 id 或名字；兼容别名 `target_id`/`bot_name`/`agentId`），`message` 必填（别名 `text`），可选 `title`。必须提供 `priority: Bool` 或 `delivery: "now"|"queued"` 之一；两者冲突、缺失或非法都 fail-closed，缺失时返回上游原句 `SendToAgent requires priority (true = wake now, false = hold for their next turn).`。发送者只能取已登记 principal 的 `botId`；目标必须存在，禁止发给自己；入站深度 + 1 超过 2 跳拒绝，目标已在线程链路中也按环路拒绝。`queued` 只写目标 held inbox（`kind: agent-held`），不唤醒目标；`now` 在目标空闲时开启可见回合，目标忙时排在当前回合之后（不打断）。目标回合最后一段 assistant 文本在 300 秒内返回，作为发送方的 `inbound` 行；phoneDSH 有意再把它作为一条 `agent-held` 回复写回发送方 held inbox，在发送方下一回合进入上下文，且不唤醒发送方。`requestId` 取调用 id，重复调用返回同一 `threadId`，不重复投递。
- `CreateTeammate`：只有当前主 Bot 可调用；其他 Bot 得到 `permission_denied`。`name` 去空格后 1–60 字符，`description` 截 300，`color` 为 15 色枚举，`hairstyle` 为 4 发型枚举，`section_id` 接受但忽略。
- 行：发送方 `outbound`/`inbound`、目标 `incoming`/`reply` 都使用上游 `toAgent`/`fromAgent`/`agentComm{direction,…}` 与 `threadId = <rowID>@<seq>:agent-comm`；发送方交换按 `summarizeCommRows` 汇总为 `single`/`fanout`/`thread`。
- 不在本期范围：Team 共享/发布/克隆、团队记忆/审核队列、Bot 模板导入导出、`CreateAgent` 云端工具、sidebar section 渲染，以及 macOS 本机工具。

## 2. 工具面

`tool-catalog.schema.json` 与 `golden/tool-catalog.json` 将工具分为两组：

- `p0`：第一版 App MCP 和 persona 可以暴露的全部工具。
- `p1`：`show_table`、`show_callout`、`show_info`、`show_payload`、`show_library`。本修订只冻结 schema 和 payload，标为 `target`；第一版不得注册到 App MCP，也不得写进 persona。

`canvas`、`product`、`gift` 不在手机卡片词汇中。未知工具、未知 `cardType`、缺少渲染所需数据的卡片一律 fail-closed；工具返回失败，不生成半空卡片。

`golden/tool-catalog.phone.json` 登记 phoneDSH 的团队工具与 `FishAction` 增量：这些名字不在上游 `tool-catalog.schema.json` 的 P0 enum 中，因此不改上游 `tool-catalog.json` 或其 schema。团队工具描述由可见名册减去调用者自己与隐藏 Bot 动态生成 `Available bots: <name> (id: <id>[, main Bot])`。`golden/tool-effects.phone.json` 以同一 `tool-effects.schema.json` 冻结分类：`SendToAgent` 为 `external-send + auto`，`CreateTeammate` 为 `write + auto`，`FishAction` 为 `read + auto`（纯外观、由宿主审计）；前两者不再向用户出审批卡。

`card-payload.schema.json` 的字段来自 dsh-bot `cardPayloads.cjs` 的白名单。`golden/card-payload.json` 是 `export-vectors.mjs` 的原样导出，不得手改；phoneDSH 对卡片负载的增量（宿主分配的 `optionID`、recommended 移到首位、负向 fixture）放在 `golden/card-payload.phone.json`，两个文件都由 `validate_vectors.py` 校验 schema/负向结果，并由 Swift `BotCardPayloadTests` 用真实 builder 对拍。重跑导出器后 `card-payload.json` 必须无 diff；`card-payload.phone.json` 不需要重新导出。链接只接受 HTTP/HTTPS；卡片数据必须自带，不能假设存在服务端 callback 补全。

`golden/tool-effects.phone.json` 的 `nativeMcp` 数组登记原生 MCP 的 BLE 工具分类（`ble_devices`、`ble_read`、`ble_alert`、`ble_link_tools`、`ble_link_call`、`ble_link_result`；经 Bot MCP 转发后模型看到 `mcp__phone__ble_*`）。读类为 `read + ask`，发送类为 `external-send + ask`；`resource` 取裁剪后的 `device_id`，没有则 `ble:*`，`ble_link_call` 还带 `name`。工具名来自 `spec/v1/native-mcp.md`「BLE tools」；設備須先在「設定 → 藍牙設備」中逐連接授權，Bot 的 ask 只是附加層。该数组是 phoneDSH 增量，与团队工具增量同在 `.phone.json` 覆盖文件；上游 `tool-effects.json` 保持原样导出。

### 2.1 volatile 上下文快照（WP2 CCR）

宿主通过既有 `phone` App MCP 提供 `BotVolatileContext`，Worker 中的发现名为 `mcp__phone__BotVolatileContext`。不新增环境变量、ordered-channel Remote 或第二种传输。WP2 是 consumer，WP7 是 Swift producer。

- 请求只含当前 `sessionId`（1–200 字符），不允许读取其他 session。宿主从已认领的 principal 推导 Bot 和授权范围，不能接受调用方自报的 botID 扩权。
- 成功结果的 `structuredContent` 符合 `volatile-context.schema.json`：`schemaVersion=1`、同一 `sessionId`、进程内单调递增的 `revision`，以及可选 `blocks.variant/persona/memory/automation`。块缺失或为空表示没有该类内容，不是成功伪造数据。
- variant/persona 各最多 12,000 字符，memory/automation 各最多 4,000 字符；总文本最多 24,000 字符。不得包含模型密钥、Bearer token 或无关 session 的内容。
- 传输失败、标准 MCP `isError`、超时、非法响应或 session 不符都不得携带部分快照。consumer 必须丢弃本次结果并使用空快照，不能沿用可能陈旧的记忆；`AbortSignal` 只用于本地忽略迟到结果，网络超时仍由既有 App MCP mount 管理。
- consumer 的本地 revision 防止旧请求覆盖新请求；producer revision 用于诊断，不作为跨进程持久游标。不得将静态工具发现当成宿主数据已接通。
- 只有实际注册 `mcp__phone__BotVolatileContext` 的 Bot MCP 才启用 Bot 专用身份登记和 `/approval`。普通 DSH 工作台没有此能力时，`identity-bridge` 与 Bot 专用审批门禁直接继续原工具权限链，不要求 Bot identity 路由，也不得把 Bot 缺失当成允许 Bot 写入。

### 2.2 Bot MCP 端点、身份与审批

App 运行 Bot runtime 时，`PDSH_PHONE_MCP_URL` 指向 Bot MCP listener，它是 Worker 唯一的 `phone` MCP 服务器；`PhoneDSHHost` 不得再用 `/mcp/native` 覆盖它。Bot server 在进程内把非 Bot 工具的 `tools/list`/`tools/call` 转发给原生 MCP 处理（ADB），因此两类工具共享一个 `mcp__phone__` 命名空间。`nativeMCP` 仍保留 `/mcp/native` 路由给其他调用方；只有未配置 Bot 端点时才沿用旧的原生 env。

身份登记在 `tools/pre-execute` 先于结构审批完成，并在 `tools/execute` 清理；登记有效期必须覆盖 300 秒审批等待。认领同时绑定代次、bare tool name、参数摘要和仍有效的 principal incarnation。Worker 重启时取消所有待审批（并写 `approval.decided`/`ui.notice`）、清空旧登记并推进代次；Task 记录持久化，未完成项以 `interrupted`/`worker_restarted` 返回并只唤醒父对话一次。HTTP 只监听 loopback、Origin 精确匹配、路径精确、Bearer 常量时间比较，且 Worker 只拿 token placeholder，由宿主在 `/v1/http` egress 注入真实 bearer。

完整条款见 [mcp-endpoint.md](mcp-endpoint.md)。

### 2.3 Grant 恢复与调用代次

- 生产 `BotGrantStore` 必须以同一个 `SQLiteDomainStore` 为权威，使用 `authz.grant_snapshot` durable 事件保存完整当前 Grant 集合及精确匹配字段；最后一次完整快照决定恢复状态。该投影不是审计：既有审计事件继续只存参数/resource 摘要，不能拿摘要反推 Grant。
- add/extend/consume/revoke 先持久化新快照，再公开新内存状态；once 在持久化期间不得被第二个执行找到。持久化失败不得改变可见授权。所有执行入口必须先完成恢复，缺失、损坏或版本不支持均 fail-closed，不能临时退回空 store 后按 auto-policy 放行。
- 每个 Gateway principal 都有宿主生成的随机 `incarnation`。工具归属在注册时绑定该代次，解析时必须仍与当前 session 代次一致；重签、rotate、revoke 或重启后的旧调用不得借用新 principal。token 仍只存摘要，不把 Bearer token 写入事件或审计。
- `BotExecutionPrincipal` 的已验证构造只在 `PhoneDSHBot` 宿主模块内使用；MCP 不得从工具参数反序列化 `userUI`、`certain` 或 trust。UI 写操作仍只能经 `BotUserActionDispatcher` 盖 `owner_direct`，effects 在执行点由宿主重新推导。

## 3. 记忆

facts 是 SQLite 唯一权威。写入归一为单行；注入块逐字对齐；召回使用 CJK 分词、BM25、时近度和重要度；非 `user-turn` 不得写 `scope:user` 或 `profile`，来源只降級；forget/erase 与上游一致。

第一版不实现自动抽取、MemoryPolicy 决策、L2 反思和衰減。facts 中对应字段保留供以后启用；`memory-policy` 向量仅作上游兼容证据，不表示该功能已开放。

## 4. 唤醒与主动提醒

routine、cron、run-attempt、安静时段、silent/held/interrupt、held inbox、隐藏唤醒和 `<automation_status>` 与上游一致。安静时段延后而不是丢弃；urgent 必须有理由；WebContent 不可用时常驻宿主排队，恢复后依次运行且错过的只补一次。

`HeldMessages.block` 的 `[agent]` 分支对 `fromAgentName`、`fromAgentId`、`title`、`text` 与 `msg id` 全部经 `escapedHeldField` 转义；agent-held 的回复仍是 held 数据与队友内容，不是用户授权，不能触发未经用户要求的动作。

设备任务终态另有一条只读 held 通知：`device-task-result` 只告诉 Bot 哪台设备、任务目标摘要和最终结果，不授予工具，也不提供把回复发回设备的路径。它来自 [device task-delegation](../../device/v1/task-delegation.md) 的终态记录，在 journal 落盘后、向设备回报前入队；投递至多一次（at-most-once）：Bot 未运行或落盘与入队之间崩溃时该通知丢失，journal 不受影响，不按 journal 补投或回放。`held-inbox-item.schema.json` 的该分支与 `golden/held-inbox.phone.json` 的 `deviceTaskResult` 是 phoneDSH 增量：上游 `held-inbox.json` 保持原样导出，例子放在覆盖文件，由合并加载器交付给真实 inbox codec。

主动提醒规则链只用于 interrupt。iOS 通知深链为 `phonedsh://bot/<botID>/row/<rowID>`。推送中继不在本轮，只保留 WakeSignalSource 接口。

## 5. 行与交互

Row、RowBatch、UserAction 和 ActionResult 以对应 schema 为准。`golden/row-protocol.phone.json` 是 P27 覆盖文件：它追加 `cardAnswer` 正例（只含 `cardID` + `optionID`）、两条拒绝 `text`/`customText` 的反例、用户消息附件向量与 projection 向量；上游 `row-protocol.json` 不保存这些用例。`body.type` 为 `text`、`widget`、`attachment`、`approval`、`automation`、`notice`、`deleted`；`widget.cardType` 为 `question`、`steps`、`task`、`document`、`progress`、`checklist`、`link`、`table`、`callout`、`info`、`payload`、`library`。attachment、approval、automation 和 notice 使用独立 body 类型，不伪装成 widget。

- UI 只读行、只发用户动作；宿主盖 `owner_direct`，UI 不得自行设置信任级别。
- `watch(after:)` 增量补齐，游标单调；墓碑重建不复活；nonce 幂等。
- durable 用户动作采用 plan→commit，不允许先执行再记录 nonce。`BotUserActionPlanning.plan(_:trust:)` 只验证并返回 `commit(BotUserActionPlan)`、`stale` 或 `rejected`；plan 包含一个 durable 事件和零至多个 effects，不得提前产生任何外部副作用。`SQLiteDomainStore.performAndRecord(action:plan:)` 在一个 `BEGIN IMMEDIATE` 事务内提交事件、effects/outbox 和 nonce；commit 前崩溃全部回滚，commit 后重放返回原 eventID 的 duplicate。stale/rejected 不消耗 nonce。
- `BotUserActionDispatcher` 负责持久 nonce 预查和相同 `(botID,nonce)` 的进程内 Task 合并，生产提交只能走上述事务。旧的 `handler.perform→nonceStore.record` 不得用于生产，不能通过内存 nonce 或调换记录顺序伪装 crash-safe。外部 DSH、文件、网络和审批 continuation 不属于 SQLite 事务，仍使用 outbox 至少一次、inbox 去重与对账，不宣称 exactly-once。
- progress 使用相同 `cardKey` 原地更新同一行。
- 流式文字只存在内存覆盖层，不写 durable 事件，手机每秒最多推送 10 次。
- 运行中输入通过 steering 并入当前回合，不排队；停止只取消当前回合并丢弃迟到输出，不重启 runtime。
- 隐藏回合只显示卡片；question/steps 成功后宿主抑制模型收尾文字。
- question/steps 只有 2–4 个真实选项，无“其他”或卡内输入；宿主在生成卡片时分配稳定 `optionID`（`o0`…`o3`），UI 只提交这个 ID，`cardAnswer` 仅含 `cardID + optionID`，选项值作为普通 `chat` 新消息，自由文本不经过卡片。推荐取第一个合法 recommended/primary 并移到第一位，其余 primary 归一为 default，danger 不推荐。回答写 durable `card.answered`，关闭写 durable `card.dismissed`；已回答、已关闭或已过期的卡再次提交返回 stale，新 question/steps 卡出现时旧的 open 选择卡过期。仅 question 可关闭：关闭不产生模型可见回合，宿主在下一次用户回合开头以 held 项告知模型视为不回答；DSH 不可用时关闭仍在本地立即生效。steps 不提供关闭动作，`cardDismiss` 对 steps 返回 rejected。
- 所有消息卡片与同一 assistant 回复气泡共享列宽，不得超过该气泡；question/steps 内距 12、选项视觉高 44、间距 4，其他卡片同样按内容紧凑排列。超过 4 个步骤/条目默认折叠，详细规则以 `spec/ui/v1/pages/bot-chat.md` 为准。
- 第一版不提供新建对话、对话列表、回滚或删除单条。现有 DSH 多 session 工作台保留为独立高级入口。

## 6. 观测与成本

- 每个模型 step 追加一条 LLM 账本，字段以 `llm-ledger.schema.json` 为准；四类 token 分开记录，快取命中率按上游公式计算，TTFT 不可得时省略。
- 只有 `front-turn` 和 `worker-turn` 允许大模型；其他 purpose 必须走小模型策略。模型密钥仍由 phoneDSH 宿主持有。
- Watchdog 只观察，不自动 nudge/stop。deadline、heartbeat、重复工具签名、重复工具错误、token/成本配额，以及手机新增的 WebContent 终止、温度、电量事件，每项每个工作单元只发一次 `watchdog.flagged`。
- compaction、pruner、spill 的 default/conservative 参数逐值复用 `CONTEXT_PROFILES`。未知 profile 回退 default，不新增环境变量。
- contextLint 对最近 session 做确定性检查；冻结重放和 rubric 不在第一版。

## 7. 大肥鱼与表现状态

素材来自上游 `public/assets/fish`，使用 512×512 RGBA PNG 和 manifest，不使用占位图。`fish-director.schema.json` 冻结真实事件到表现状态的映射、优先级、one-shot TTL、去重和生命周期恢复；Swift 只实现确定性状态机，不引入 JavaScript/Canvas runtime。

头像只能消费当前 Bot 的真实 BotEvent。审批和 Watchdog 进入 alerting，成功进入 celebrate，失败或拒绝进入 sad，回合结束恢复 idle。皇冠身份由真实 principal 决定，不能根据名称、颜色或发型推断。任何 UI 都不能自行申报运行状态。

## 8. 一致性向量

从仓库根运行：

```bash
# Verify the upstream batch without touching the worktree.
node spec/tools/bot/export-vectors.mjs \
  --checkout /tmp/phonedsh-bot-spec \
  --sha bf4075b0a2e8092b04b726c59a7b085d5a37e6f6 \
  --out /tmp/phonedsh-bot-export
python3 spec/tools/bot/check_golden.py --root . \
  --checkout /tmp/phonedsh-bot-spec \
  --sha bf4075b0a2e8092b04b726c59a7b085d5a37e6f6

# Regenerate the upstream files and export-manifest.json in place. The
# exporter never writes `*.phone.json`; existing overlays are preserved and
# hashed into the new manifest.
node spec/tools/bot/export-vectors.mjs \
  --checkout /tmp/phonedsh-bot-spec \
  --sha bf4075b0a2e8092b04b726c59a7b085d5a37e6f6 \
  --out spec/bot/v1
python3 spec/bot/v1/tools/validate_vectors.py
```

导出器只读 dsh-bot，临时 fixture 写系统临时目录。所有实现必须让真实 codec/状态机读取这些 golden；Python 校验器通过不能替代运行时 conformance。

### 8.1 上游导出与 `.phone.json` 覆盖

`spec/bot/v1/golden/` 中不带 `.phone.json` 后缀的文件都是 `export-vectors.mjs` 的原样导出，不得手改；重跑导出器必须 byte-identical。手机端增量只写在同名 `.phone.json`：

- `card-payload.phone.json`：宿主分配的 `optionID`、recommended 移到首位、负向 fixture。
- `held-inbox.phone.json`：`deviceTaskResult`（P07/P26）与 `agentHeld`（多 Bot held 回复）正例、非法 `device-task-result` 反例。
- `row-protocol.phone.json`：`cardAnswer`、附件向量与 projection 向量。
- `tool-catalog.phone.json`：团队工具与 `FishAction` 的目录增量。
- `tool-effects.phone.json`：团队工具、`FishAction` 与原生 MCP BLE 工具的效果分类。

覆盖文件的合并语义由 `spec/tools/bot/golden_overlay.py`、Swift `BotGoldenFixture` 与 `plugins/tests/bot-golden.ts` 一致实现：

- 对象的 case 容器（如 `valid`）按键合并；同名键由覆盖文件替换。
- 数组的 case 容器（如 `valid`、`invalid`、`invalidActions`、`nativeMcp`）按 identity 追加或替换：identity 依次取 `name`、`id`、`nonce`、`action.nonce`；无 identity 的条目只有在与上游条目完全相同时才去重。覆盖文件只能增加或按 identity 替换，不能删除上游用例。
- `schemaVersion`、`vector`、`source`、`upstream`、`delta` 是覆盖文件的文档元数据，不参与合并；合并结果保留上游元数据。
- 读取 golden 的 Swift/TS 测试必须使用合并加载器（`BotGoldenFixture.mergedObject`／`wp6Golden`／`readBotGoldenMerged`），不得只读上游文件。

`export-manifest.json` 由导出器生成，`files` 列出全部 golden，`upstream` 是本轮导出器写出的文件，`phoneOverlays` 是全部 `.phone.json`，`sha256` 是每个文件精确字节的摘要。`spec/tools/bot/check_golden.py` 校验清单/摘要/覆盖文件的 append-only 语义；带 `--checkout` 时还会重新导出并逐字节比较上游文件。CI 的 `phone-spec` 阶段运行离线校验（没有私有 dsh-bot checkout 时不能声称已证明“上游 = 原样导出”）。
