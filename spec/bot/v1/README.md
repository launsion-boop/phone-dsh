<!-- SPDX-License-Identifier: MIT -->

# phoneDSH Bot v1 契约

状态：`target`。本目录冻结 P25 BotEventLog、P26 BotToolSurface、P27 BotRows 的共享语义；静态 schema/golden 通过不等于 Swift、Worker、模型或真机已经实现。

唯一上游规格是 dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`，由 `dshbot-pin.json` 固定。除 Mac 专属和手机平台限制外，本文件仍拥有的子系统复用其语义。记忆、唤醒标记和主动提醒三部分自 2026-11-10 起迁到 [v2](../v2/README.md)，由 phoneDSH 作准，不再跟随这个钉版。不得恢复 PR29 的 NativeToolLoop 主循环、Mandate、Ticket 或 MandateTokenStore。

## 1. 架构与存储

- 主 Bot 是 WKWebView Worker 中的一个 DSH session。每个 Bot 只有一条连续主对话；routine 与 Task 使用各自的后台 session。
- Swift 宿主常驻负责事件、授权、记忆、routine 调度、通知、账本和 Watchdog。WebContent 终止不能丢失 durable 数据。
- Bot 事件写 SQLite，不使用 JSONL 作为权威存储。`commitSeq` 由 SQLite 在同一事务中分配，单调且无缺口；`eventId` 去重。P03 journal 是另一序号域，不得混用。
- effects outbox 至少一次投递，包含 lease、去重、dead-letter 和 needs-reconciliation。接受、持久化和外部副作用完成是不同事实。
- SQLite schema v3（P25 破坏性存储变更）把 `bot_events` 拆成 `bot_event_headers` 与 `bot_event_payloads`，并保留只读视图 `bot_events` 给未跟进拆分的历史读取路径。事件头保存 `commit_seq`、`event_id`、`event_type`、`payload_digest`、`payload_size` 与不含 `data` 的路由元数据；载荷只保存 `data` 的规范 JSON 字节。事件头只追加、序号无缺口、`eventId` 去重的校验不变；载荷只有宿主的 `erasure` 路径能清空，清空后保留摘要并写入一条 `erasure` durable 事件（§4.6）。`payload_digest` 是 SHA-256 over 规范 JSON（sorted keys、不转义 `/`）。
- SQLite schema v2 增加 `bot_user_action_nonces(bot_id, nonce, event_id, created_commit_seq)`，主键为 `(bot_id, nonce)`，`event_id` 唯一并引用 `bot_event_headers(event_id)`。v1/v2 打开时原地迁移到 v3：旧 `bot_events.payload` 被解码后拆分，事件、effects 和 nonce 不变；新库直接建 v3。迁移在一个事务内完成，重复打开幂等；v3 拒绝更未来版本。回滚到只支持 v1/v2 的 App 会按现有 `schemaTooNew` 规则明确拒绝该库，不删除或静默降级。
- `bot_event_payloads` 的唯一合法变更是宿主抹除路径把 `payload` 置 NULL 并记录 `erased_at`/`erasure_commit_seq`；触发器拒绝其他 UPDATE 和所有 DELETE。打开数据库时 `PRAGMA secure_delete=ON`；抹除提交后 checkpoint WAL、VACUUM 并再次 truncate WAL，确保 SQLite 文件不保留原文字节。
- 第一版不做回退引擎、回滚、import、Team 共享/发布/克隆、团队记忆/审核队列、Bot 模板导入导出、`CreateAgent` 云端工具、Box、CloudAgent、GenerateImage 或 macOS 本机工具。多 Bot 名册、逐 Bot 会话/记忆/held inbox 与 `SendToAgent`/`CreateTeammate` 见 §1.1；sidebar section 接受但忽略。

### 1.1 多 Bot 与 Team 边界

phoneDSH 从本期起支持多 Bot：名册沿用 dsh-bot 的 `agents-index.json`（`schemaVersion: 3`）和 `runtime-settings.json` 的 `mainAgentId`；每个 Bot 有独立的 DSH 会话、记忆、例行任务、授权、held inbox 与未读计数。首个 Bot 成为主 Bot；主 Bot 是指针，不是记录字段。删除主 Bot 时指针移到剩余第一个 Bot；隐藏的 Bot 仍留在名册，但不进入模型可见的工具描述。

- `SendToAgent`：`agent_id` 必填（接受 id 或名字；兼容别名 `target_id`/`bot_name`/`agentId`），`message` 必填（别名 `text`），可选 `title`。必须提供 `priority: Bool` 或 `delivery: "now"|"queued"` 之一；两者冲突、缺失或非法都 fail-closed，缺失时返回上游原句 `SendToAgent requires priority (true = wake now, false = hold for their next turn).`。发送者只能取已登记 principal 的 `botId`；目标必须存在，禁止发给自己；入站深度 + 1 超过 2 跳拒绝，目标已在线程链路中也按环路拒绝。`queued` 只写目标 held inbox（`kind: agent-held`），不唤醒目标；`now` 在目标空闲时开启可见回合，目标忙时排在当前回合之后（不打断）。目标回合最后一段 assistant 文本在 300 秒内返回，作为发送方的 `inbound` 行；phoneDSH 有意再把它作为一条 `agent-held` 回复写回发送方 held inbox，在发送方下一回合进入上下文，且不唤醒发送方。`requestId` 取调用 id，重复调用返回同一 `threadId`，不重复投递。
- `CreateTeammate`：只有当前主 Bot 可调用；其他 Bot 得到 `permission_denied`。`name` 去空格后 1–60 字符，`description` 截 300，`color` 为 15 色枚举，`hairstyle` 为 4 发型枚举，`section_id` 接受但忽略。没有用户消息来源的回合（见 §4.1）调用时必须先经现有审批卡确认；确认后宿主把作者（`rpcId`/`turnId`/`origin`/`authorization`/`approvalID`）写入 `ui.system_event{event:"teammate.created"}` 的 durable 记录，描述随 Bot 资料保存。用户回合的记录同样写入，`authorization:"user-turn"` 且没有 `approvalID`。
- 行：发送方 `outbound`/`inbound`、目标 `incoming`/`reply` 都使用上游 `toAgent`/`fromAgent`/`agentComm{direction,…}` 与 `threadId = <rowID>@<seq>:agent-comm`；发送方交换按 `summarizeCommRows` 汇总为 `single`/`fanout`/`thread`。
- `agent.comm` 是 P27 的 additive UI event type，也是 P25 的 additive durable event；outbound/inbound 都写入 `origin = local/comm-service`。契约冻结见 [PC-20261111-bot-agent-comm-envelope](../../../docs/protocol-changes/PC-20261111-bot-agent-comm-envelope.md)。
- 不在本期范围：Team 共享/发布/克隆、团队记忆/审核队列、Bot 模板导入导出、`CreateAgent` 云端工具、sidebar section 渲染，以及 macOS 本机工具。

## 2. 工具面

`tool-catalog.schema.json` 与 `golden/tool-catalog.json` 将工具分为两组：

- `p0`：第一版 App MCP 和 persona 可以暴露的全部工具。
- `p1`：`show_table`、`show_callout`、`show_info`、`show_payload`、`show_library`。本修订只冻结 schema 和 payload，标为 `target`；第一版不得注册到 App MCP，也不得写进 persona。

`canvas`、`product`、`gift` 不在手机卡片词汇中。未知工具、未知 `cardType`、缺少渲染所需数据的卡片一律 fail-closed；工具返回失败，不生成半空卡片。

`golden/tool-catalog.phone.json` 登记 phoneDSH 的团队工具、`FishAction` 与记忆三原语增量：这些名字不在上游 `tool-catalog.schema.json` 的 P0 enum 中，因此不改上游 `tool-catalog.json` 或其 schema。团队工具描述由可见名册减去调用者自己与隐藏 Bot 动态生成 `Available bots: <name> (id: <id>[, main Bot])`。`ReadMemory` 是 [v2 §1.2](../v2/README.md#12-三个原语) 的新增原语，`UpdateMemory`/`RecallMemory` 的 fact 参数由同一节替换。`golden/tool-effects.phone.json` 以同一 `tool-effects.schema.json` 冻结分类：`SendToAgent` 为 `external-send + auto`，`CreateTeammate` 为 `write + auto`，`FishAction` 为 `read + auto`（纯外观、由宿主审计），`ReadMemory` 为 `read + auto`；`RecallMemory` 沿用上游 `golden/tool-effects.json` 的 `read + auto`。`auto` 分类的工具不向用户出审批卡；结构审批门禁必须使用同一分类，不得把已冻结的 `read + auto` 工具当作 `tool.unclassified` 再请求审批（否则 `alwaysScope` 与宿主期望不一致，调用会以 `stale:always_scope` 失败）。

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

身份登记在 `tools/pre-execute` 先于结构审批完成；普通调用在 `tools/execute` 清理，被 DSH job registry 保留的命令把同一登记持有到 `job/settled`/`removed`（heartbeat 续期，24 小时上限）。登记有效期必须覆盖 300 秒审批等待。认领同时绑定代次、bare tool name、参数摘要和仍有效的 principal incarnation。Worker 重启时取消所有待审批（并写 `approval.decided`/`ui.notice`）、清空旧登记并推进代次；Task 记录持久化，未完成项以 `interrupted`/`worker_restarted` 返回并只唤醒父对话一次。HTTP 只监听 loopback、Origin 精确匹配、路径精确、Bearer 常量时间比较，且 Worker 只拿 token placeholder，由宿主在 `/v1/http` egress 注入真实 bearer。

P05/P16/P26 的出口与身份增量（`mcp-egress-capability-v1`，见 [PC-20261110-bot-mcp-egress-capability](../../../docs/protocol-changes/PC-20261110-bot-mcp-egress-capability.md)）：宿主每次启动生成 `PDSH_MCP_EGRESS_TOKEN`，受信 MCP 客户端在目标命中精确 MCP 路由时带 `X-PDSH-MCP-Egress`；宿主在解析/注入任何 MCP 凭据前常量时间校验，缺失或错误以 403 `mcp_egress_forbidden` 在出口拒绝（用户配置的精确 MCP 路由同样覆盖）。宿主把会话 principal 的随机 token 经 `phone/botClaimSession` 的 `sessionToken` 字段交给 Worker，`identity-bridge` 在 `/identity/register` 带上它；宿主按 token 解析 principal，`sessionId` 不自证，缺失/撤销/不匹配一律 `unauthorized` 并 fail-closed。`tools/call` 认领身份后还要在该 principal 的 per-caller 目录里查到工具，否则 `permission_denied`；`CreateTeammate` 的主 Bot 检查保留。Android/HarmonyOS 没有 Bot runtime，三项均 `not started`。

完整条款见 [mcp-endpoint.md](mcp-endpoint.md)。

### 2.3 Grant 恢复与调用代次

- 生产 `BotGrantStore` 必须以同一个 `SQLiteDomainStore` 为权威，使用 `authz.grant_snapshot` durable 事件保存完整当前 Grant 集合及精确匹配字段；最后一次完整快照决定恢复状态。该投影不是审计：既有审计事件继续只存参数/resource 摘要，不能拿摘要反推 Grant。
- add/extend/consume/revoke 先持久化新快照，再公开新内存状态；once 在持久化期间不得被第二个执行找到。持久化失败不得改变可见授权。所有执行入口必须先完成恢复，缺失、损坏或版本不支持均 fail-closed，不能临时退回空 store 后按 auto-policy 放行。
- 每个 Gateway principal 都有宿主生成的随机 `incarnation`。工具归属在注册时绑定该代次，解析时必须仍与当前 session 代次一致；重签、rotate、revoke 或重启后的旧调用不得借用新 principal。token 仍只存摘要，不把 Bearer token 写入事件或审计。
- `BotExecutionPrincipal` 的已验证构造只在 `PhoneDSHBot` 宿主模块内使用；MCP 不得从工具参数反序列化 `userUI`、`certain` 或 trust。UI 写操作仍只能经 `BotUserActionDispatcher` 盖 `owner_direct`，effects 在执行点由宿主重新推导。

### 2.4 出口写审批、工作区根与文件 Grant 粒度

Bot 会话经宿主 `/v1/http` 发出的网络写不再是 Worker 命令文本的职责。`approval-gate.ts` / `BotApprovalPatterns` 里的 `curl`、`wget`、`python` 网络模式**降级为提示**，不是安全边界；脚本文件、变量拼接和解释器都不能绕过出口判断。冻结记录见 [PC-20261111-bot-egress-approval](../../../docs/protocol-changes/PC-20261111-bot-egress-approval.md)。

- **出口方法集合。** 仅 `POST`、`PUT`、`PATCH`、`DELETE` 进入审批；`GET`/`HEAD` 维持既有 allow-list。精确等于已配置模型推理端点的 `POST`（`ModelGatewayConfiguration.replaySafeModelEndpoints`）走模型路径；没有登记为模型端点的 `POST` 一律按普通网络写处理（B 兜底会送审或拒绝，绝不静默放行）。精确 MCP 路由（`MCPEgressPolicy` 命中，含 Bot 的 `/mcp`、`/identity/*`、`/approval` 与用户连接器）由既有 `X-PDSH-MCP-Egress` 门禁负责，不在这里再次审批，否则审批请求本身会递归。
- **归属跟随 `bash` 调用与后台 job。** 宿主把出口写归属到**当前存活的 `bash` identity registration**。普通调用在 `tools/execute` 返回时释放；DSH job registry 保留的命令（`run_in_background: true` 或前台超时转后台）在工具结果返回后继续持有同一登记，Worker 每 120 秒用同一 call/digest 重发 `/identity/register` 续期，宿主在原 id 上延长有效期（不超过会话 token 过期），直到 `job/settled`/`removed`、Worker 代次轮换或 24 小时硬上限。这样 job 后续发出的 `/v1/http` 写仍能归到发起它的 Bot/session。
- **同一 Bot 的多个活动登记不是歧义。** 多个后台 job 或 chat/task 会话同时活动时，宿主按 Bot 归组；同一 Bot 只有一个 owner，选其中一条仍存活的登记送审。不同 Bot 之间才用外层命令是否含目标主机做唯一消歧；仍不唯一 → `bot_egress_ambiguous` 拒绝，不猜 principal。会话 token 已撤销/过期 → `bot_egress_unattributed`。
- **失败关闭兜底（B）。** 完全没有存活登记时，宿主询问 App“是否有工作台会话正在运行回合”（由 `PhoneDSHHost` 的 journal turn state 回答，排除活动 Bot 会话）。有工作台回合 → `notBot`，工作台维持原 allow-list；没有工作台回合 → 该写只能是 Bot 的后台任务：恰好一个活动 Bot → 归该 Bot 送审；多个活动 Bot → `bot_egress_ambiguous` 拒绝；没有任何活动 Bot credential → `bot_egress_unattributed` 拒绝。兜底只在登记缺失时生效，已归属的 job 写不会被工作台活动改判给另一个 Bot。
- **审批与 Grant。** 无对应 Grant 时复用现有 Bot 审批卡：`tool=egress`、`operation=egress.<method>`、`resource=host=<lowercased host>`（不含 scheme、端口、路径、query），`alwaysScope=until`。用户选「总是」写入 30 天 `until` Grant；`allow_once` 在放行后立即消费；同一「主机 + 方法」的后续写不再出卡。拒绝、超时（300 s）、取消、Worker 重启/Bot 删除取消都 fail-closed，返回 HTTP 403；`xl_error.code` 统一为 `egress_approval_denied`，`error.code`/`X-PDSH-Proxy-Error` 为具体原因（拒绝/超时/取消 `egress_approval_denied`，多活动调用 `bot_egress_ambiguous`，会话凭证失效 `bot_egress_unattributed`，Task 缺少网络写授权 `task_network_write_denied`），且不解析凭据、不开 socket、不写 response log。
- **Task 子会话的网络写。** `approveEgress` 先完成归属，再检查被归属会话的授权子集：`kind=task` 且 capabilities 不含 `task.network-write` 时，直接以 403 `task_network_write_denied` 拒绝，不创建审批卡、不写 Grant，也不依赖任何 `curl-post`/`network-egress` 命令分类。带 `task.network-write` 的 Task 会话（夹具或兼容数据；本修订的 `Task` 工具不会生成）仍走与其他 Bot 会话相同的主机 + 方法审批卡。主对话没有这个子集检查，行为不变。
- **取消传播。** Worker 的 `/v1/http` 消费者取消 → 宿主取消对应 pending 审批（写 `approval.decided`，`status=cancelled`，`reason=consumer_cancelled`）；`workerRestarted`/Bot 删除继续走既有 `cancelAll`。同一被批准写不跟随重定向：3xx 原样返回，调用方需对新目标另行审批。
- **Bot 工作区根。** Bot 会话 cwd（及 DSH 文件沙箱的 `workspaceRoot`）是 `BotWorkspaceLayout.botRoot(botId:)`，即 `/dsh/workspace/.dshbot/agents/<safe botID>`；chat/task/routine 共享该 Bot 根，不同 Bot 不共享。根内 `write`/`edit` 不需要结构审批，DSH 文件沙箱是该层的执行边界；根外写是跨出口。
- **文件 Grant 粒度。** 根外 `write`/`edit` 的效果为 `tool=write|edit`、`operation=file.write|file.edit`、`resource=dir=<标准化绝对父目录>`；文件名、内容和参数摘要不参与。同一目录的连续写复用同一 `until` Grant；`..` 在包含判断前解析，`file_path` 缺失/为空按 `tool.unclassified` fail-closed。显式 `sandbox_permissions` 仍需走既有 sandbox escalation，二者是独立的两层。
- **残留风险。** ① 若 Worker 在 job 运行期间崩溃/被重置，或 job 登记在宿主 TTL 内未能续期，A 失效；只要此时没有工作台回合，B 仍按单 Bot 送审或多 Bot 拒绝，但若有工作台回合并发运行，该写仍可能按工作台放行——这是 A 失效 + B 不触发的已知残余，尚无跨进程 job id 对账。② 混合版本：旧宿主不延长 job 登记（重复注册只返回旧 id），旧 Worker 不持有 job 登记；旧宿主 + 新 Worker 的 job 超过 330 秒仍会落入旧行为，旧 Worker + 新宿主由 B 兜住。③ 工作台回合探测读取 journal；读取失败按“无工作台回合”失败关闭，可能把一次真实工作台写送成 Bot 审批。④ 重定向仍不跟随；不同 Bot 并发且无唯一主机文本时 fail-closed。
- **向量。** [golden/mcp-egress.phone.json](golden/mcp-egress.phone.json) 新增 `egress-approval`（有效：Grant 命中、一次批准、always、GET/HEAD、模型端点、workbench、主机消歧、后台 job 存活登记、同 Bot 多登记、Task 有网络写授权；无效：拒绝、超时、不同 Bot 歧义、无 Bot 未归属、错误方法/主机、PUT/PATCH/DELETE、Task 无网络写授权）与 `grant-directory`（有效：根内、同目录命中、session Grant；不命中：无 Grant、异目录、旧参数摘要资源、traversal、异工具、拒绝、缺失路径）套件。[golden/approval-patterns.phone.json](golden/approval-patterns.phone.json) 登记 upstream 网络模式在本端降级为 `matches=[]`。Python 校验器和 Swift `BotEgressApprovalTests`、`BotEgressSpikeApprovalPatternTests` 使用同一批 fixtures。

### 2.5 Task 授权子集（S4b）

Task 派发时宿主生成并持久化一个授权子集，随结果返回并在子会话的回合提示里说明：

```json
{
  "workspaceRoot": "/dsh/workspace/.dshbot/agents/main",
  "allowedWriteDirectories": ["/dsh/workspace/.dshbot/agents/main"],
  "canWriteOutsideWorkspace": false,
  "canNetworkWrite": false,
  "canDelegateTasks": false
}
```

- `allowed_write_directories` 接受绝对路径或相对于 Bot 工作区根的路径；`~` 展开，`.`/`..` 规范化，重复项合并，最多 32 项。省略或为空表示只允许 Bot 工作区根。任一项在根外时 `canWriteOutsideWorkspace` 才为 `true`。
- 子会话的 DSH principal capabilities 由该子集派生：`task.workspace:<root>`、`task.write-dir:<abs>`、`task.write-outside-workspace`、`task.network-write`、`task.delegate`。
- 结构审批门禁对 `write`/`edit` 的路径和可识别的 `bash` 写入目标按 `task.write-dir:*` 拒绝越界。网络写不再由命令文本效果判断：Task 子会话在宿主 `/v1/http` 出口按 `task.network-write` 处理，没有该 capability 时直接 403 `task_network_write_denied`（见 §2.4），不创建审批卡；有该 capability 的会话才进入与其他 Bot 会话相同的主机 + 方法审批卡。拒绝发生在向用户出审批卡之前，不执行。
- 本修订没有提高子会话权限的 Task 参数：`canNetworkWrite` 与 `canDelegateTasks` 恒为 `false`。因此 `Task` 的子会话默认不能再派 `Task`，`startTask` 对缺少 `task.delegate` 的调用 fail-closed。
- 结果与 `AwaitTask` 都带同一个 `authorization` 对象；durable `persistedTask` 保存它，Worker 重启后仍能对同一任务继续执行同一子集。

### 2.6 routine 的设立者与放宽授权（已迁至 v2）

唤醒标记（含 routine）自 2026-11-10 起归 [v2](../v2/README.md) 所有；S4b 新增的 routine
`creator`、`completion_criteria`、`constraints`、放宽授权审批与手动取消语义见
[v2 §2.2](../v2/README.md#22-routine-的设立者与放宽授权s4b)。本文件不再定义这些规则。

### 2.7 持久待办审批（S5 target，本修订只冻结契约）

现状：`BotApprovalCoordinator.defaultTimeoutMilliseconds = 300_000`，超时写 `approval.decided{status:"denied",timedOut:true}`；Worker 侧 `approval-gate.ts` 在 330 秒 abort 请求；身份登记 TTL 覆盖同一等待窗口。用户不在场的 routine/异步 Task 因此会得到“没有人回答”的拒绝。

目标语义（尚未实现）：非交互回合的审批请求在超时后**不拒绝**，而是一条持久待办；用户的决定按 `approvalID + digest` 恢复，任务停在原地直到处理。与现状冲突、需要一并修改的契约：

1. `approval.requested` 的 pending 状态必须跨进程重启保持，决定可由 `approvalID` 重新绑定；`BotApprovalCoordinator.resolve` 的 in-memory continuation 不能是唯一等待者。
2. Worker 的 `tools/pre-execute` 不能在 330 秒 abort；需要可恢复的等待/租约，或用“停住 + 后续恢复”代替单次阻塞调用。
3. 身份登记（`BotAttributionRegistry`）的 TTL 与 principal incarnation 必须覆盖停住的等待，或在恢复时重新登记同一次调用。
4. 审批卡/行投影在重启后仍显示 pending；决定只能生效一次，执行恢复不得重复副作用。
5. 交互前台回合是否保留 300 秒超时需单独决定；本契约只冻结“routine/异步 Task 不因超时拒绝”。

实现风险：第 1、2 条跨 Bot MCP、Worker 插件与 App 生命周期，超出本单元允许修改的路径。因此本修订只冻结上述语义和冲突清单，`status: target`，不声称已实现。

### 2.8 Task 交付终态与独立验证（S3）

Task 的交付物是终态，不是过程自述。`Task` 在既有 `title`/`prompt` 之外可选四个字段；
省略即旧行为，不伪造内容：

| 字段 | 形状 | 语义 |
| --- | --- | --- |
| `completion` | string，1–4,000 字符 | 可判定的完成条件。非空才进入独立验证 |
| `purpose` | string，≤2,000 字符 | 这次工作要解决什么 |
| `constraints` | array<string>，≤8 项、每项 ≤500 字符 | 边界与限制 |
| `budget` | object `{max_duration_ms?: integer}` | 任务预算；随 Task 记录并用于派生 verifier 预算，省略时取 `timeout_ms`，范围 1,000–300,000 ms；既有的 `timeout_ms` 仍是任务调用的超时 |

验证强度与任务相称：同步 Task 一律不验证；只有 `async: true` 且 `completion` 非空的 Task，
在做事会话以 `completed` 结束（或 routine 以 `succeeded` 结束且 `completion_criteria` 非空）后
验证一次。`failed`、`stopped`、`interrupted` 的做事会话不启动 verifier：它们已经是失败终态，
不会再被当成完成。

**只读 verifier 会话。** verifier 是独立 DSH session，principal kind 为 `verifier`（区别 chat/
task/routine），由宿主签发并认领自己的会话凭证；Agent preset 固定为 `pdsh-verifier`，只挂载
`read`、`grep`、`glob` 和只读 `bash`（`phone record search|read` 走同一 bash 桥）。可见面由
`tools.restrict({allow:[read,grep,glob,bash]})` 在**该 verifier Agent 自己的作用域**上、于
`agent/created`（第一回合之前）安装：它隐藏其余所有继承工具，同时保留 preset 自己挂载的四个
工具，模型看到的 `tools[]` 必须恰好是这四个名字。不能把 allow-list 装在共享的 preset 作用域：
DSH 会把祖先作用域的过滤器也应用到祖先自己注册的工具上，子 Agent 因此会得到空工具面。guard
再拒绝白名单外的调用和非只读 bash。它没有 `write`/`edit`、没有出站写、不能
`SendToUser`/`SendToAgent`、不能派 `Task`、不能读写记忆。

验证输入只有完成条件、目的、约束和做事会话的 `record://session/<sessionId>#<seq>` 引用；
全局 volatile 上下文（variant/persona/memory/automation）对 verifier 会话不注入；
不把做事会话的最后一段自述当证据。verifier 回合沿用既有的隐藏 `task-turn:` 请求前缀
（verifier 不写记忆，因此不新增前缀）；principal kind 仍是独立的 `verifier`。

**受限会话共用一套机制。** verifier 与 [v2 §4.1](../v2/README.md#41-会话与权限) 的 maintainer
都走同一份 `restricted-session` 实现：宿主在 `session/create` 带不可变创建头
`agentPreset`（verifier 为 `pdsh-verifier`，maintainer 为 `phone-bot-maintainer`）并核对返回值；
会话 id 使用同一约定 `gb-<kind>-`；执行点只有一个全局 `restricted-session-guard`，先按创建头、
再按保留前缀解析出所属策略，然后应用该策略的 allow-list 与 bash 规则；preset 行在
`agent/created` 时把同一个 guard 与该策略的 allow-list 装到**该 Agent 自己的作用域**上，只负责
可见面（不是共享 preset 作用域，见上一段）。可见面必须在第一回合前非空且恰好是契约白名单。
受限会话的 `bash` 仍走与普通 Bot 相同的身份登记；可用性 liveness 的证据是宿主签发并已认领的
session token，按同一份 `restricted-session` 保留前缀解析，不能依赖已被 allow-list 隐藏的
`BotVolatileContext` 工具（否则 verifier 的只读 bash 会在登记前被拒，读不到 `phone record`）。
volatile 注入也在同一处按“创建头或保留前缀”排除两种会话。两类会话
的差别只有工具白名单与 bash 规则，不存在第二套 guard。即使 preset 作用域没有生效，全局
guard 也只允许同一白名单。普通 Session 的创建头也会记录控制器默认 preset（例如 `standard`），
因此 `agent/created` 的“保留创建头”条件只认受限 preset，不能把所有带 header 的会话都跳过。

**Bot 会话必须使用 `phone-bot`。** chat、task、routine 的宿主会话必须在
`session/create` 带不可变创建头 `agentPreset: "phone-bot"`，并核对返回值里的
`agentPreset`；team/proactive/watchdog 回合复用这些 Bot 会话，若将来为它们创建独立
会话，也必须使用同一创建头。缺失或不一致时 fail-closed，
不运行该回合、不认领会话凭证。原因不是命名偏好：`standard` 会暴露 `subagent`/
`subagent_fork`（绕过 Task 授权子集与独立验证）、`schedule_*`（与 App RoutineMachine
形成第二套调度）、`skill`、`plan`/`exit_plan_mode`、原生 `ask_user_question` 和
`present` 等 phone persona 未讲授、也不授权给 Bot 的能力。`phone-bot` 是“以实际工具列表为准”
的唯一 Bot 工具面契约。

**已有会话与全局工具行的兼容（运行时收窄，不重建）。** 升级前创建的 Bot 会话（主对话、
Task、routine）创建头可能是 `standard`；DSH 在会话开始过回合后拒绝重挂 preset
（`agent-preset/locked`）。此外，phone Worker 镜像直接继承 `dsh-base` 的全局工具行
（官方 Web-app bundle 的全局禁用层没有 materialize），所以即使是创建头正确的
`phone-bot` 会话也会继承 `subagent`、`skill`、`working_directory`、`read_image`、
MCP resource 等 workbench 工具。Worker 因此对每个普通 Bot agent 在创建和每次恢复时
施加同一道运行时收窄：

- 当前可见面中，只保留 `phone-bot` preset 的 native 工具（即 persona 声明的
  `PHONE_NATIVE_TOOLS`，由测试与 preset 行保持一一对应）和 App MCP 的
  `mcp__phone__` 命名空间；其余名字用 `tools.restrict` 从可见面移除；
- 以同一谓词安装 per-agent `tools.guard`：在可见面快照之后才注册的工具即使一时可见
  也不可执行；`tools/change` 会把新出现的、不在集合内的工具补进 deny，使可见面收敛；
- App MCP 工具允许在 resume 之后重连/重新注册，不在启动快照里丢工具；
- restriction 与 guard 都随 agent 作用域销毁而解除，每次恢复重新施加。主对话因此
  保持连续，Task/routine 也无需重建。若 agent 没有作用域工具 registry 或当前面为空，
  则 fail-closed：拒绝该回合，绝不在宽面上运行 Bot 回合。

verifier 重新检查工作区产物和原始记录，最终回复必须恰好是
一个 JSON 对象（无代码围栏、无额外散文）：

```json
{"verdict":"passed|failed|uncertain","summary":"…","refs":["record://session/<id>#<seq>"],"unverified":["…"]}
```

- `summary` 非空、≤2,000 字符；`refs` 为 1–8 条规范 `record://` 引用；`unverified` ≤20 项、
  每项 ≤500 字符。`passed` 要求全部完成条件都已核验，因此 `unverified` 必须为空。
- 宿主校验格式、引用的规范形态、存在性和本 Bot 范围。任一失败、超时、预算耗尽或引用无效，
  结论记为 `uncertain`，不把模型输出原样当结论。verifier 引用的 `record://` 若已被
  [§4.6](#46-抹除erasure与两个强度) 的 S6 抹除路径物理清除，宿主按 `record_erased` 处理：
  结论 `uncertain`、`output:"invalid"`、`refs: []`，并在 `unverified` 保留 `record_erased`
  说明；这不是崩溃，也绝不升级为 `passed`。
- 验证预算 = `floor(任务预算 × 30%)`，在 `spec/bot/v1/README.md` 本节的 `0.30` 冻结；超过即
  `uncertain`，并在 `budget.exceeded=true` 留痕。该比例不随任务放宽。

每次实际启动 verifier 的验证写一条 durable `verification.reported`（P25），principal 是 verifier
的会话凭证，数据至少含 `verificationId`、`subjectKind`（`task|routine`）、`subjectId`、
`subjectSessionId`、`title`、`status`、`verification{verdict,summary,refs,unverified,budget{ratio,limitMs,usedMs,exceeded},output}`
和 `createdAt`；`output` 取 `valid|invalid|budget_exceeded|unavailable`。verifier 会话无法创建时没有
verifier 凭证，宿主不伪造事件，而是把 `uncertain`/`unavailable` 写进 Task/Routine 记录及其结束事件
（`task.settled`/`routine.run_finished`），Task 行仍由该结束事件显示结论。`output:"valid"` 时
`refs` 仍有 1–8 条；宿主自身的失败路径（`invalid`/`budget_exceeded`/`unavailable`）结论必须是
`uncertain`，并且允许 `refs: []`——没有可引用证据时不伪造引用。Task 的 durable 记录与
`AwaitTask` 结果都带同一个 `verification` 对象；`verification.reported` 不会把已经 `settled`
的 Task 改回运行态。

**结果以证据呈现。** 异步 Task 的父对话隐藏唤醒文本包含 verifier 的 `verdict`、`summary` 和
`refs`，不复制模型自述摘要；`failed`/`uncertain` 时唤醒文本必须写明“如实告诉用户没有通过或
无法验证”，回复不得把它说成完成。Task 行复用 `cardType:"task"` 形状，在标题下显示
验证结论、摘要和依据条数；`failed` 用 danger、`uncertain` 用 warning、`passed` 用 success tone。
共享向量见 [golden/verification.phone.json](golden/verification.phone.json)，输出与事件形状由
[verifier-output.schema.json](verifier-output.schema.json) 和
[verification-report.schema.json](verification-report.schema.json) 冻结。

## 3. 记忆（已迁至 v2）

记忆契约（`memory-document`、`memory-write-*`、`memory-read-result`、`memory-injection`、`memory-recall`）自 2026-11-10 起迁到
[v2/README.md](../v2/README.md) §1，由 phoneDSH 作准；`memory-policy` 随后按
PC-20261111-bot-v2-unwired 删除。本文件不再定义 facts、注入、召回、来源边界或 MemoryPolicy。

## 4. 回合来源、记录与观察（唤醒与主动提醒已迁至 v2）

routine 投递、安静时段延后、held inbox、隐藏唤醒、`<automation_status>`、宿主拼入文本的
转义和主动提醒规则链自 2026-11-10 起迁到 [v2/README.md](../v2/README.md) §§2–3，由 phoneDSH
作准。本文件保留与之一同使用的回合来源判定（§4.1），以及原始记录引用、观察信封、`phone record`、
脱敏留痕与抹除（§§4.2–4.6）；前缀表仍是本文件拥有的契约。

### 4.1 回合来源（turn origin）

回合是否隐藏、是否带 held 块、记忆写入算谁说的，只由 DSH `user/message` 事件里的 `data.source.rpcId` 前缀决定，不由消息文本决定。判定在 offset 0 做 ASCII 大小写敏感匹配；前缀后必须至少有一个非空白字符，否则按「其他或缺失」处理。`source.kind` 仍由 DSH 提供，本表只规定 phoneDSH 的隐藏、held 块剥离、气泡投影和记忆来源。用户输入与页面动作（`user-action:`）以及卡片点选（`card-answer:`）都属于真实用户回合。权威向量是 `golden/turn-origin.phone.json`，冻结记录见 [PC-20261110-bot-turn-origin](../../../docs/protocol-changes/PC-20261110-bot-turn-origin.md)。

| `rpcId` 前缀 | 含义 | 隐藏 | 带 held 块 | 记忆来源 |
| --- | --- | --- | --- | --- |
| `user-action:`、`card-answer:`、`bot-` | 用户消息 | 否 | 否 | `user-turn` |
| `held:` | 用户消息，开头拼了 held 块 | 否 | 是 | `agent-message`（沿用现有的降级规则） |
| `agent:`（新增） | 其他 Bot 的即时消息 | 否 | 否 | `agent-message` |
| `routine:` | routine 唤醒 | 是 | 否 | `routine` |
| `task-turn:` | Task 子会话的回合 | 是 | 否 | `task` |
| `task-settled:`、`task-interrupted:` | 子代理结束唤醒父对话 | 是 | 否 | `hidden-wake` |
| 其他或缺失 | 未知 | 否（按可见处理，不静默隐藏） | 否 | `agent-message`（按最低信任处理） |

向量里的 `origin` 固定为 `user`、`held`、`agent`、`routine`、`task`、`task-wake`、`unknown` 之一；`hidden` 当且仅当 `origin` 为 `routine`／`task`／`task-wake`，`held` 当且仅当 `origin` 为 `held`，`memorySource` 取表最后一列。实现和测试的前缀表只能来自 `golden/turn-origin.phone.json`，不得在代码里复制一份不同的前缀表。

- 未知或缺失前缀：`hidden=false`、不剥 held 块、记忆来源 `agent-message`（最低信任）；不能写 `scope:"user"` 或 `tier:"profile"`，沿用 `memory-source-boundary` 拒绝。不得为了「看起来像隐藏回合」而按前缀的相似写法（不同大小写、前缀在中间、只有前缀）静默隐藏。
- `agent:` 是 phoneDSH 新增的 requestId 前缀，不是上游 `source.kind`；WP4 起 Bot 间即时消息使用 `agent:<发送方 callId>`，不再复用 `sendUserMessage` 的可见用户回合路径。
- `card-answer:` 是宿主为卡片点选生成的 `session/prompt` requestId（`card-answer:<nonce>`）：宿主盖 `owner_direct`，选项值作为普通 chat 消息发出，因此与 `user-action:` 同属真实用户回合。它是回合前缀，不是 held 项 id；`card-dismissed:<cardID>` 是 held inbox 项的 id，不进入 `session/prompt` 的 `requestId`，按「其他或缺失」处理。
- `bot-` 仍是宿主默认的可见 chat requestId（`bot-<uuid>`）。`sendHiddenInteraction` 目前没有生产调用方；任何隐藏回合必须使用表中的隐藏前缀，不能依赖调用参数或消息文本。
- 旧 session log：宿主发起的 routine、Task 和子代理唤醒回合本来带上述前缀，重放时仍隐藏；旧的 Bot 间即时消息 requestId 是发送方工具调用的裸 `callId`，按「未知」处理（可见、`agent-message`），这正是 WP4 要修的兼容差异。

宿主拼进 prompt 的非宿主文本如何转义（held 块、隐藏唤醒 prompt 和同类结构字段）由 [v2 §2.1](../v2/README.md#21-宿主拼入文本的转义) 定义；本文件不复制那份规则。回合来源前缀仍是本文件 §4.1 的唯一权威，v2 只引用它。

### 4.2 原始记录引用（record reference）

原始记录只有两份权威：DSH session log（一行一个事件）和 `bot_events`（一行一个 durable 事件）。
其余都是派生物，需要精确原文时必须用下面两种引用指回其中一份：

- `record://session/<sessionId>#<seq>`：DSH session log 中 `seq` 对应的那一行。
- `record://event/<commitSeq>`：`bot_events` 中 `commitSeq` 对应的那一条。

`<sessionId>` 是 D-6 允许的 `^[A-Za-z0-9._-]{1,64}$`，但 `.` 和 `..` 不得作为完整 session id；`<seq>`
是 0 基 session-log 序号，`<commitSeq>` 是 1 基 `bot_events` 序号。两者都只能用 ASCII 十进制，
最大 `2^53-1`（JSON safe integer）。解析器**只**规范化三处：两端的 ASCII 空白、scheme／authority 的
ASCII 大小写、十进制前导零；session id 本身大小写敏感，不做百分号解码、Unicode 归一化或路径展开。
任何其他拼写都是非法引用，不得靠 trim、别名或宽松正则猜测。

`record-reference.schema.json` 冻结规范形态，`golden/record-reference.phone.json` 是共享正反向量：
`valid` 的每条同时给出 `canonical`、`kind` 与解析出的 `sessionId`／`seq` 或 `commitSeq`；`invalid`
的每条给出拒绝原因。Python 参考解析器、Swift `BotRecordReference` 和 Worker 的 CLI 校验必须读同一批
向量；实现不得复制一张不同的正则表。引用里的 session／event 是否属于调用者由宿主另行判断，
引用本身不携带身份。

引用规范化后再比较、存储和去重；事件信封、记忆证据和检索结果只输出规范化形态。原始记录被抹除时
引用即失效，不得把不存在的引用静默解析到相邻记录。

`record://event/<commitSeq>` 被宿主的 `erasure` 路径物理清除后，事件头、序号、类型和摘要仍存在，但
引用进入「已抹除」状态：`phone record read` 返回 `ok:false` 且 `error.code == "record_erased"`
（不返回原文、摘要或相邻记录），`search` 跳过该事件，`resolveEvidence` 拒绝把它当作证据。
`record://session/<sessionId>#<seq>` 在会话纪元抹除后若该行已被墓碑替换，引用进入同一「已抹除」
状态；`search` 跳过墓碑行，`resolveEvidence` 拒绝。未抹除的行仍可读，行窗口也不得把墓碑内容当作
原文返回。墓碑是 `phone-dsh/session-erasure` 事件，带 `ignorable: true`、原 `seq`/`time` 和
`record://session/<sessionId>#<seq>`，不含原文；DSH 加载会话时忽略它。旧会话归档、新会话接续，切换
由旧会话的 `runtime.exited{reason:"session-erased"}` 与新会话的 `runtime.started` 记录。引用存在性
与调用者范围校验顺序不变：先按既有规则判断引用/会话是否属于该 Bot，再判断是否已抹除；不得用
「已抹除」泄露别的 Bot 的记录。

### 4.3 观察信封（observation envelope）

`tools/post-execute` 在 `redact` 同一挂点给外部来源的结果加系统生成的信封。信封由 Worker 产生，
宿主记录并据此推导记忆证据；模型写出的同样文本不算信封。

编码固定为一行头部、正文、一行闭合：

```text
<observation source="web" origin="https://example.com/a?b=1&amp;c=2" at="2026-11-11T07:00:00.000Z" owner="unknown" ref="record://session/gb-main#12">
Example Domain
</observation>
```

- 属性顺序固定为 `source`、`origin`、`at`、`owner`、`ref`，缺一不可；不允许额外属性。
- `source` 是封闭集合：`tool`、`connector`、`device`、`device-task`、`web`、`subagent`、`agent`、
  `attachment`。`origin` 是具体来源（工具名、`mcp://<server>/<tool>`、`device:<id>`、URL、task id、
  agent id、附件路径），最长 512。`at` 是 UTC RFC 3339 毫秒时间。`owner` 是归属，未知写 `unknown`。
  `ref` 必须是 §4.2 的规范引用；无法确定引用时该结果**不加**信封，而不是写假引用。
- 属性值中的 `&`、`"`、`<`、`>` 依次转义为 `&amp;`、`&quot;`、`&lt;`、`&gt;`，控制字符写成
  `\uXXXX`。正文中任何 `<\s*/?\s*observation\b`（ASCII 大小写不敏感）只把开头 `<` 转义成字面量
  `\u003c`，因此内容不能提前闭合信封；其他 `<>` 保持原样。
- 只有外部来源加信封：网页抓取与搜索、外部 MCP 连接器返回、ADB／BLE 设备输出、设备任务结果、
  子代理结果、其他 Bot 的消息、附件内容。Bot 自己在盒子里跑的 `bash`、文件读写和其他宿主工具
  不加信封。`mcp__phone__<bot tool>` 是宿主自己的 Bot 工具面，不是外部连接器；`mcp__phone__android_*`
  与 `mcp__phone__ble_*` 属于设备。
- 多个文本块各自包一封；非文本块保持原样。隐藏回合、held 块、用户消息正文仍是消息内容，不因为
  出现信封标记就升级为可信来源；记忆信任只由 §4.2 引用指向的**宿主记录结构**推导，见
  [v2 §1.5](../v2/README.md#15-证据与信任推导)。
- held 块里的其他 Bot 消息、设备任务结果和子代理结果不在 `tools/post-execute` 路径上；宿主投递时
  已用 `[agent]`／`[device-task]`／`[subagent]` 结构行标明来源、归属和时间，并按
  [v2 §2.1](../v2/README.md#21-宿主拼入文本的转义) 转义，因此不回套本节 XML 信封；投递时若没有
  稳定的 `record://` 出处，按上一条「无法确定引用」处理，不伪造引用。
- 一个结果自身已经是信封时不得嵌套；先解析出原信封，再把内容作为新封包正文转义。

`observation-envelope.schema.json` 冻结解码后的头部形状，`golden/observation-envelope.phone.json`
冻结编码、解码、转义和拒绝向量（`valid`／`invalid`／`decodeErrors`）。

### 4.4 只读记录命令桥（`phone record`）

agent 用既有 `phone` 命令桥查询记录，不新增 MCP 工具 schema：

```text
phone record search <词> [--since <RFC3339|epoch-ms>] [--session <sessionId>]
phone record read <record-ref> [--around <0..20>]
```

`--session` 只是过滤条件；调用者身份只能来自宿主：Worker 的 `phone` 命令在 `args[0] == "record"` 时
把**当前 tool-call 的 session** 作为 out-of-band 字段放进 `PDSH_TOOL_CALL_SESSION`（与 `ubuntu` 同一
机制；shell 导出的同名变量一律删除），宿主用 `BotGateway` 的已认领 session 解析 principal。缺失、
未认领或已撤销的 session 一律 `unclaimed_session`，不执行检索；`--session` 越出该 Bot 自己的会话集合
一律 `session_out_of_scope`。宿主不得接受 argv、env 或回复里的 botID 自报。

数据源是宿主的物化副本（`materialized/home/sessions/**`）和 SQLite `bot_events`；不放宽
`/dsh/home/sessions` 对 bash 的 EACCES 规则。检索范围是该 principal 的 botID 自己的会话与事件；
共享记忆的出处在 [v2 §1.5](../v2/README.md#15-证据与信任推导) 另由 v2 定义，不扩大本命令的读取范围。

结果使用 P19 手机工具 envelope：成功为
`{ok:true,tool:"record.search"|"record.read",egress:false,scope:"bot",data:{…}}`，失败为
`{ok:false,tool:…,error:{code,message}}`。错误码至少包含 `unclaimed_session`、
`session_out_of_scope`、`unknown_record`、`record_erased`、`invalid_reference`、`invalid_query`、
`invalid_since`、`invalid_around`；用法错误退出 2，查询拒绝退出 1。`record_erased` 的 `message` 为
`该记录已被抹除`，且结果不得包含原文字节。`search` 返回规范化引用、记录种类、时间、
类型与至多 20 条片段；`read` 返回中心行和前后至多 20 行原文（每条带引用与 `truncated`），
原文按落盘字节返回，不重新编码。单次输出上限 256 KiB。

**压缩后可回查。** DSH 压缩摘要用 `surfaceOp.replace` 替换 surface 区间，但被替换的行仍留在
session log 里。`read` 一个 replace 事件时 `data` 带 `replacedRange`（起止引用）；`read` 该区间内的
原始行时带 `shadowedBy`（替换事件引用）。因此 `phone record read` 能取回压缩前的原文，`search`
也能命中被替换的行。agent 侧的说明见 `plugins/bot-runtime/prompts/**`：上下文里出现压缩摘要后，
用摘要里的稳定词／编号执行 `phone record search`，或读取摘要对应 replace 事件的 `replacedRange`，
再 `read --around` 取回原文。没有「摘要即丢失」的例外。

`record-query.schema.json` 冻结上述两种结果形状，`golden/record-query.phone.json` 的
`compactionRecall` 用真实 DSH 事件形状驱动 Swift 服务的回归。

### 4.5 脱敏留痕（redaction trace）

工具结果在落 session log 前先经过 `redact`，这个顺序不变：凭据不进入权威记录。每次发生脱敏时，
Worker 在最后一个文本块尾部追加一行系统标记（规则名排序、只记次数，不记原文）：

```text
[pdsh-redaction rules=sk-token:2,jwt:1]
```

宿主在把 `tool/result` 记为 `conversation.tool_result` 后，解析该标记并追加**一条**
`redaction.applied` durable 事件：

```json
{"sessionId":"gb-main","seq":5,"record":"record://event/7",
 "sessionRecord":"record://session/gb-main#5",
 "rules":[{"rule":"jwt","count":1},{"rule":"sk-token","count":2}]}
```

`record` 指向被脱敏的工具结果事件，`sessionRecord` 指向对应 session 行；`rules` 只含规则名与次数。
事件类型追加到 P25 `event-envelope.schema.json` 的封闭 enum 和 `golden/event-envelope.phone.json`；
旧读者按 P25 的未知 durable 事件规则处理。标记本身保留在记录里，作为「这里被改写过」的证据；
不得把原文、命中片段或替换后的秘密写进事件。没有命中的结果不写事件。

### 4.6 抹除（erasure）与两个强度

用户删除只有两个强度，名字和行为一一对应：

- **忘记（forget）**：逻辑删除。记忆文档从 live 集合移除、不再注入/检索/显示，历史版本和原始记录
  保留。模型工具 `UpdateMemory{"action":"delete"}` 和记忆页的「忘记」只走这个强度。
- **抹除（erase）**：物理删除。由宿主专用路径执行，作用于原始记录和派生物：事件载荷、记忆文档及其
  全部历史版本、检索结果、UI 行、`phone record` 结果、观察信封/脱敏留痕中指向被抹除事件的内容，
  以及已关闭会话纪元的 DSH 会话日志行。当前主会话在抹除时先切换到新纪元（旧会话归档、新会话从
  未抹除记录和记忆索引接续），然后宿主按 [P02 WAL §5.3](../../v1/wal.md) 的受控改写把旧会话的命中行
  替换成墓碑；确认文案与结果不得再声称会话日志未覆盖。

**事件存储。** 拆分为事件头与载荷（§1）。只有宿主的抹除路径能清空载荷；每次抹除追加一条 durable
`erasure` 事件，列出目标（`memory` scope/path）、每个路径被抹除的版本号、被清除事件的
`record://event/...`、类型、原摘要、字节数、`legacyFactIDs`、被墓碑替换的
`record://session/...`（`erasedSessionRecords`）和切换的会话纪元（`sessionEpochs`）。只有确实
无法覆盖的 session 引用才进入 `uncoveredRecords`，reason 为
`session-log-erasure-not-implemented`（旧数据）或 `session-log-session-not-closed`（该会话仍有活动
回合）。`erasure` 事件自己的载荷不清除；它的 `data` 由
[erasure-event.schema.json](erasure-event.schema.json) 冻结，正反向量在
[golden/erasure-event.phone.json](golden/erasure-event.phone.json)。`event-envelope.schema.json`
的 durable type enum 追加 `erasure`（P25 additive event type），旧读者按未知 durable 规则处理。

**作用范围与顺序。** 宿主先解析目标文档/scope 及全部版本，再扫描 durable 事件：

1. 该路径的 `memory.document_written`/`memory.document_deleted` 载荷（包括历史版本）；
2. 共享 `user/` scope 跨 Bot；`agent/` scope 只限该 Bot（`erasure` 事件按写入者的 principal 限定）；
3. 与版本文本相同的事件载荷，以及由版本文本中唯一标记（含 `_` 或数字、长度 ≥ 8）匹配到的副本；
4. `redaction.applied`、观察信封等非 memory 事件中指向被清除 `record://event/...` 的内容；
5. 版本文本和证据中的 `record://session/...` 引用，以及由版本文本唯一标记匹配到的会话日志行：
   先切换/关闭会话纪元，再按 P02 §5.3 用墓碑替换；替换成功后才清空事件载荷并写 `erasure` 事件。
   仍处于活动回合或宿主无法改写的会话行留在 `uncoveredRecords`，不得伪称已覆盖。

清除范围之外的内容不得因为抹除被误删；其他 Bot 的 `agent/` 文档和保留的 `user/` 文档必须存活。
会话日志中未命中的行、旧纪元归档和新纪元的接续上下文必须保留；接续上下文不含墓碑行。
抹除是幂等的：重复执行不再产生第二条 `erasure` 事件，目标已不存在时返回 `memory-not-found`（单文档）
或 `removed=0`（scope）。失败路径：不存在的路径、越权 scope、事件不存在或已经抹除都不得伪造成功。

**与只追加的关系。** 只追加约束进程和 agent，不约束有权的用户。宿主抹除路径是唯一的例外：它不
删除事件头，不重编序号，不改变既有事件 id/类型/摘要；它只把载荷置 NULL 并追加 `erasure` 事件。
`verifyIntegrity` 在打开与 `verifyIntegrity()` 时仍要求序号从 1 无缺口、每个载荷摘要匹配、每个
被抹除行指向一条更晚的 `erasure` 事件。

## 5. 行与交互

Row、RowBatch、UserAction 和 ActionResult 以对应 schema 为准。`golden/row-protocol.phone.json` 是 P27 覆盖文件：它追加 `cardAnswer` 正例（只含 `cardID` + `optionID`）、两条拒绝 `text`/`customText` 的反例、用户消息附件向量与 projection 向量；上游 `row-protocol.json` 不保存这些用例。`body.type` 为 `text`、`widget`、`attachment`、`approval`、`automation`、`notice`、`deleted`；`widget.cardType` 为 `question`、`steps`、`task`、`document`、`progress`、`checklist`、`link`、`table`、`callout`、`info`、`payload`、`library`。attachment、approval、automation 和 notice 使用独立 body 类型，不伪装成 widget。

- UI 只读行、只发用户动作；宿主盖 `owner_direct`，UI 不得自行设置信任级别。
- 回合是否隐藏、是否剥 held 块、`agent:` 是否投影为用户气泡，按 §4.1 的 `source.rpcId` 判定，不读消息文本；`isInjected` 按 `source.kind`，文本前缀只在 `source` 缺失的旧记录上兜底。
- `watch(after:)` 增量补齐，游标单调；墓碑重建不复活；nonce 幂等。
- durable 用户动作采用 plan→commit，不允许先执行再记录 nonce。`BotUserActionPlanning.plan(_:trust:)` 只验证并返回 `commit(BotUserActionPlan)`、`stale` 或 `rejected`；plan 包含一个 durable 事件和零至多个 effects，不得提前产生任何外部副作用。`SQLiteDomainStore.performAndRecord(action:plan:)` 在一个 `BEGIN IMMEDIATE` 事务内提交事件、effects/outbox 和 nonce；commit 前崩溃全部回滚，commit 后重放返回原 eventID 的 duplicate。stale/rejected 不消耗 nonce。
- `BotUserActionDispatcher` 负责持久 nonce 预查和相同 `(botID,nonce)` 的进程内 Task 合并，生产提交只能走上述事务。旧的 `handler.perform→nonceStore.record` 不得用于生产，不能通过内存 nonce 或调换记录顺序伪装 crash-safe。外部 DSH、文件、网络和审批 continuation 不属于 SQLite 事务，仍使用 outbox 至少一次、inbox 去重与对账，不宣称 exactly-once。
- progress 使用相同 `cardKey` 原地更新同一行。
- 流式文字只存在内存覆盖层，不写 durable 事件，手机每秒最多推送 10 次。
- 运行中输入通过 steering 并入当前回合，不排队；停止只取消当前回合并丢弃迟到输出，不重启 runtime。
- 隐藏回合只显示卡片；question/steps 成功后宿主抑制模型收尾文字。
- question/steps 只有 2–4 个真实选项，无“其他”或卡内输入；宿主在生成卡片时分配稳定 `optionID`（`o0`…`o3`），UI 只提交这个 ID，`cardAnswer` 仅含 `cardID + optionID`，选项值作为普通 `chat` 新消息，自由文本不经过卡片。推荐取第一个合法 recommended/primary 并移到第一位，其余 primary 归一为 default，danger 不推荐。回答写 durable `card.answered`，关闭写 durable `card.dismissed`；已回答、已关闭或已过期的卡再次提交返回 stale，新 question/steps 卡出现时旧的 open 选择卡过期。仅 question 可关闭：关闭不产生模型可见回合，宿主在下一次用户回合开头以 held 项告知模型视为不回答；DSH 不可用时关闭仍在本地立即生效。steps 不提供关闭动作，`cardDismiss` 对 steps 返回 rejected。
- 所有消息卡片与同一 assistant 回复气泡共享列宽，不得超过该气泡；question/steps 内距 12、选项视觉高 44、间距 4，其他卡片同样按内容紧凑排列。超过 4 个步骤/条目默认折叠，详细规则以 `spec/ui/v1/pages/bot-chat.md` 为准。
- Bot 信息页（`spec/ui/v1/pages/bot-info.md`）新增三个宿主服务型用户出口，不进入 durable `BotUserAction` nonce 事务：查看/撤销本 Bot 的常设 Grant（`scope != once`，`BotGrantStore.revoke(id:)`）、取消运行中的 routine（`RoutineScheduler` 取消链）、处理 `needs-reconciliation`（显示 routine 的已产生效果，选择“确认完成”走 `BotEffectOutbox.ackReconciled` + `RoutineMachine.resolveReconciliation(decision:"acknowledge")`，或“重试”走 `retryNeedsReconciliation` + `resolveReconciliation(decision:"retry")`）。读取失败显示失败，不显示为零；撤销/取消/对账后重读权威状态，不用本地删除伪装成功。
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

本节只描述仍由 dsh-bot 钉版导出的 v1 批次。记忆、后台整理、唤醒标记和主动提醒的向量已移到
[v2](../v2/README.md) §5，`export-vectors.mjs` 不写、`export-manifest.json` 也不列它们。

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
- `row-protocol.phone.json`：`cardAnswer`、附件向量与 projection 向量。
- `tool-catalog.phone.json`：团队工具、`FishAction` 与记忆三原语（`UpdateMemory`/`ReadMemory`/`RecallMemory`）的目录增量。
- `tool-effects.phone.json`：团队工具、`FishAction`、`ReadMemory`（`RecallMemory` 沿用上游 `tool-effects.json`）与原生 MCP BLE 工具的效果分类。
- `approval-patterns.phone.json`：把 upstream 的 curl/wget/python 网络命令模式登记为手机端降级（`matches=[]`），并列出脚本文件/变量拼接/解释器与 `python3 /tmp/x.py`；`rm`/`git reset --hard`/`find -delete` 仍匹配 upstream，不得降级。出口写审批与文件 Grant 的向量在 `mcp-egress.phone.json` 的 `egress-approval`、`grant-directory` 套件。
- `turn-origin.phone.json`：回合来源的有效／无效 `rpcId` 向量；它没有同名上游文件，用 `"upstream": []` 声明为手机专属向量，`check_golden.py` 对显式注册的手机专属文件跳过 append-only 合并，`validate_vectors.py` 逐条校验解析结果并做 mutation 自检。
- `record-reference.phone.json`、`observation-envelope.phone.json`、`record-query.phone.json`、`erasure-event.phone.json`：原始记录引用、观察信封、`phone record` 结果和 `erasure` 事件的手机专属向量；同样用 `"upstream": []` 登记，逐条校验解析／编码／解码并做 mutation 自检。这四个文件不是 dsh-bot 的上游导出，重跑导出器不会写它们。
- `verification.phone.json`：S3 只读 verifier 的工具白名单、只读 bash 允许/拒绝命令、结构化输出正反例、30% 预算边界与 `verification.reported` 事件正反例；`"upstream": []`，由 Python 校验器和 Swift／TS 运行时测试共用。它不是 dsh-bot 的上游导出。
- `authority.phone.json`：routine 设立者/放宽判定、Task 授权子集和 CreateTeammate 作者的手机专属向量；用 `"upstream": []` 登记，含 schema 负例、解析负例和 mutation 自检。
- `mcp-egress.phone.json`：MCP 出口凭证、会话凭证与 `tools/call` 调用者目录的手机专属向量；同样用 `"upstream": []` 登记。`valid` / `invalid` 的每条用例带 `suite`（`egress` / `identity` / `tools-call` / `egress-approval` / `grant-directory`）；`egress` 由精确路由集合与常量时间 token 比较判定，`identity` 由 token 登记表（含撤销／过期／轮换）解析 principal 并比较 `sessionId`，`tools-call` 由与 `tools/list` 相同的 per-caller 目录判定；`egress-approval` 逐条覆盖登记/job 生命周期、同 Bot 分组、无登记时的单/多/无 Bot 与工作台回合，以及 Task 授权子集（无 `task.network-write` 拒绝且不出卡、有授权照常送审、主对话不受影响），`grant-directory` 覆盖目录 Grant 命中和不命中。`validate_vectors.py` 逐条校验并按 suite 强制边界覆盖，内部 mutation 变异预期值；`check_golden.py` 在 `PHONE_ONLY_VECTORS` 显式登记该文件。

覆盖文件的合并语义由 `spec/tools/bot/golden_overlay.py`、Swift `BotGoldenFixture` 与 `plugins/tests/bot-golden.ts` 一致实现：

- 对象的 case 容器（如 `valid`）按键合并；同名键由覆盖文件替换。
- 数组的 case 容器（如 `valid`、`invalid`、`invalidActions`、`nativeMcp`）按 identity 追加或替换：identity 依次取 `name`、`id`、`nonce`、`action.nonce`；无 identity 的条目只有在与上游条目完全相同时才去重。覆盖文件只能增加或按 identity 替换，不能删除上游用例。
- `schemaVersion`、`vector`、`source`、`upstream`、`delta` 是覆盖文件的文档元数据，不参与合并；合并结果保留上游元数据。
- 读取 golden 的 Swift/TS 测试必须使用合并加载器（`BotGoldenFixture.mergedObject`／`wp6Golden`／`readBotGoldenMerged`），不得只读上游文件。

`export-manifest.json` 由导出器生成，`files` 列出全部 golden，`upstream` 是本轮导出器写出的文件，`phoneOverlays` 是全部 `.phone.json`，`sha256` 是每个文件精确字节的摘要。`spec/tools/bot/check_golden.py` 校验清单/摘要/覆盖文件的 append-only 语义；带 `--checkout` 时还会重新导出并逐字节比较上游文件。CI 的 `phone-spec` 阶段运行离线校验（没有私有 dsh-bot checkout 时不能声称已证明“上游 = 原样导出”）。
