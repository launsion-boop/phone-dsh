<!-- SPDX-License-Identifier: MIT -->

# Bot v2 决策材料、交付来源与反馈（G-2）

状态：`target`（契约冻结，实现由 R/F/U/C 按本 revision 落地；本文件不是实现证据）。
本文件是 P26/P27 内的 phoneDSH Bot v2 新能力契约，2026-11-16 由 G 冻结。它消费 G-1 的
[provenance.md](provenance.md) 词表（`current|changed|unavailable|revoked|erased|unknown`），
不另造状态枚举；不新增第二套原始记录、不新增固定词表/分类。

## 1. 三个不同事件：retrieved → injected → adopted

宿主/Worker 必须能分别证明，且不得用一个字段代替另一个：

| 事件 | 载体 | 证明 |
| --- | --- | --- |
| retrieved | 检索服务返回的候选集（`decision-material.schema.json` 的 `materials` 全量） | `block_id`+`turn_id`+`retrieved_at_ms`+每项 `material_id`/`ref`/`selection_reason`。 |
| injected | 官方 DSH `systemPrompt.context` 的 runtime-context 快照（`source.kind=runtime-context`），带 `dshbot:decision-context` 与 `r<requestID>` 标记 | 真实模型请求中的 runtime-context 段；不是 user message、不是 `current-user-turn`、不是 system prompt。 |
| adopted | 产物/交付/工具参数引用 `material_id`（G-2 的 delivery/suggestion/feedback 或 R 的 trace） | 产物行/事件中出现该 `material_id` 或它对应的 ref；只有「材料出现过」不算 adopted。 |

- 材料块 `decision-material.schema.json`：`{block_id, turn_id, session_id, bot_id, stage,
  authorization_revision, query_digest, goal_digest?, retrieved_at_ms, materials[], limits,
  truncated, canceled}`；`materials` 每项 `{material_id, ref, path?, scope, version,
  updated_at_ms, snippet, evidence[0..2], selection_reason, state, reason?}`。
- `stage` 封闭 `pre_step`/`pre_delivery`。`pre_step` 材料在**同一 turn 的后续 step**复用；turn、
  `authorization_revision`、recipient、goal digest 或任一材料状态变化 → 整批失效，不局部沿用。
  旧 turn 的 block 不得进入新 turn 请求。
- 上限：默认 4 条/1,600 scalar，硬 6 条/2,400 scalar；单条 snippet ≤300 scalar；query/goal 各
  ≤600 scalar 且只以 digest 进入块；单条 evidence ≤2。超限必须截断并 `truncated:true`，不得静默。
- 材料区不是指令区：不得放入 `role`/`instruction`/`system` 等指令字段（schema 关闭），不得声称
  `current-user-turn`，不得改写用户消息；外部文本按 v2 §2.1 转义。
- 取消/失败：`canceled:true` 或省略整块；回合继续；不产生第二次后台补取。deadline 默认 1,500 ms
  （100–3,000），由宿主 signal 约束。
- 每条材料的 `state` 只能来自 G-1；`changed/revoked/erased/unavailable` 的材料不得作为「当前
  事实」注入，`unknown` 必须带 reason。材料项的 `ref` 用 `memory:<path>@v<version>` 或规范
  `record://`；`adopted` 时产物必须能回指同一 ref。

### 1.6 `.regenerate` 工具结果（model-visible，iOS-only）

交付/审批副作用执行前，R 的 pre-delivery review 发现 turn、授权 revision、材料、recipient 或 goal
与 pre-step 时不同，宿主**不得执行**该动作，返回给模型一条 tool result：

```json
{"ok":false,"code":"decision_context_changed","reason":"material-changed",
 "materials":{…decision-material block…},"message":"材料已更新，请按新参数重新生成并重走授权"}
```

- 形状冻结在 `decision-tool-result.schema.json`：`ok:false` + `code` 常量 + 封闭 `reason`
  （`turn-changed|authorization-revision-changed|material-changed|recipient-changed|goal-changed`）
  + 新的材料块 + 人话 `message`（≤300）。
- 它不是 P25 事件、不是 P27 行/card/user-action、不是 cloud wire；不落库、不写第二套 trace。
  成功路径仍用该交付工具自己的正常结果，没有 `ok:true` 变体。
- 模型收到后按新材料重新生成参数，再走既有授权；宿主不得在发送后偷偷补附件，也不得把旧审批
  当作新参数的授权。`materials` 必须通过 §1 的材料块规则（limits/state/无指令字段）。

### 1.7 `BotDecisionContext` internal additive tool（G-2 r3，方案 a）

R/C 的源码事实：DSH 的 Worker 插件只能通过 `ctx.tools.execute` 调 `mcp__phone__<tool>`，而
`BotMCPRuntime.execute` 要求该名字出现在 `toolDefinitions(callerBotID:)`（即 MCP `tools/list`）；
DSH 没有官方“非 tools/list 的 host→Worker 通道”。因此“完全 hidden”在生产不可实现。

冻结决定（a）：`BotDecisionContext` 是 **internal additive tool**：

- 注册在 `BotToolCatalog.allDefinitions`（与 `BotVolatileContext` 同路径），因此出现在 `tools/list`，
  模型理论上可调；**不**写进冻结的 `BotToolCatalog.definitions` / `tool-catalog.phone.json` golden，
  不新增模型可见工具契约。
- 输入/结果形状由 `decision-internal-tool.schema.json` 冻结：
  request `{schema:"bot-decision-context-request/v1", session_id, turn_id, step, stage, query,
  origin?, scopes, limits}`；result `{schema:"bot-decision-context-result/v1", ok:true, block}` 或
  `{ok:false, code:"permission-denied|invalid-request|material-unavailable", message}`。
- 宿主安全边界：`session_id` 必须等于已认领会话；`turn_id`/`step` 必须是当前 turn；principal 必须是
  真实 `.chat`/宿主签发的会话，模型不能自报 botID；不匹配 → `permission-denied` 或空材料。
  调用只读、无副作用、不授予工具、不扩大授权、只返回本 session 的有界材料块（§1 的 limits）。
- 模型主动调用它只会“多拿一次本 session 材料”（类似 `RecallMemory`），不构成越权；材料仍受
  freshness/authorization revision/recipient/goal 约束。
- **owner 转交**：K 的 L3 已 release，但 G worktree 的 `BotToolCatalog.swift` 仍是 release 前版本；
  G 若在该文件写入会把旧版本带回 cherry-pick。故 `BotToolCatalog.swift` 的这一处 additive 编辑
  **转交 C**（C 在 OWNERS 记录），G 只冻结本文件/schema/golden/validator。C 加：
  `static let decisionContextName = "BotDecisionContext"`；`allDefinitions` 增加一条 read-only
  definition（参数逐字按 `decision-internal-tool.schema.json` 的 request；description 按 §1 材料块，
  不提评分/不教流程/不含用户正文）；`isRegistered(name)` 对它在当前会话返回 true。
  **不写**冻结的 `BotToolCatalog.definitions` / `tool-catalog.phone.json` golden。
- R 的插件名/参数保持 `mcp__phone__BotDecisionContext` + 上述 request，不需要改 wire。
- 不是 P25 事件、不是 P27 行/card/user-action、不是 cloud wire；不落库、不写第二套 trace。

## 2. 交付来源、建议附件与重绑定

### 2.1 行/交付展示（U 的 `sources` / `delivery` 投影）

- 任意交付行可带 `sources[]`：每条 `{label,kind,reason?,observed_at?,verification,freshness,
  state,state_detail?}`；`label` 是人话（不得是 `record://`/session/event/tool id），`kind` 封闭
  `user_message|file|calendar|contact|web|memory|inference|bot`；`verification` 封闭
  `verified|unverified|disputed|unknown`；`freshness/state` 用 G-1 的 canonical 六值。
- **适用性 vs 当前有效性（R5）**：`state` 只表达来源当前有效性，不能单独决定“能不能用”。
  - `revoked|erased|unavailable`：宿主权限/可用性不允许选用，UI 显示不可用与原因；
  - `changed|unknown`：**可选用**但必须标“历史版本/时效未知”；是否适合本次任务由模型和用户判断，
    不得用通用 non-current 硬规则一律禁止（例如任务本来就是比较历史版本）；
  - `current`：可选用，但仍不表示 `review.verified`。
  系统守权限与可用性；用途判断不塞进来源状态。
- 交付/审批行可带 `delivery{draft_id,revision,parameters[],resources[]}`；`resources` 每项
  `{id,name,detail?,reason?,selected,state,source}`。这些是行投影，不是第二份权威：`source` 是
  G-1 `source_statuses` 的 UI 投影，`revision` 由宿主单调分配。
- 行没有 `sources`/`delivery` 时 UI 降级显示「未提供可核验来源」，不得补造 current/verified。

### 2.2 建议附件候选（`suggested-attachment.schema.json`）

- 一份候选：`{suggestion_id,draft_id,revision,artifact_kind,resource{…},selected,created_at_ms,
  updated_at_ms,approval_digest}`；`artifact_kind` 封闭 `delivery|draft|notification`。
- 生命周期：`candidate → selected/removed → submitted`；一次提交完整 `selected_resource_ids`
  集合（幂等），不是增量 toggle；`state != current` 的资源不可选。
- 选用规则：`resource.state` 为 `revoked|erased|unavailable` 的候选不可选（权限/可用性）；
  `changed|unknown` 可选，但 UI 必须标“历史/时效未知”，不能显示成 current；用途由模型/用户判断。
- **重绑定**：`approval_digest = "sha256:"+sha256(canonical JSON of
  [draft_id, revision, sorted(selected_resource_ids), parameters sorted by label])`（UTF-8、
  无空白、键序固定）。`revision` 单调 +1；选中集合或参数变化必须产生新 revision/digest。
  旧 digest 的 allow/deny 一律拒绝（`digest_mismatch`/`draft_changed`），旧审批不能继续复用。
  revision 变化后同一行回到 `pending` 并重算 digest；不新建第二行（除非宿主显式 supersede）。
- 候选必须有 G-1 来源：`resource.source` 至少 `ref/trust/state`；`why used` 用 `reason` 人话。

## 3. 反馈（`feedback.schema.json` + `feedback.recorded`）

### 3.1 durable 事件

- 新 durable type **`feedback.recorded`**（P25 enum add-only；写入必须 `ignorable:true`，复用既有
  `origin.kind=local`+`source=card-bridge|mcp` 与 `principal.kind=chat`；不新增 origin/principal
  枚举值）。`eventId = feedback.recorded:<botId>:<nonce>`；同 nonce 重放由 store 拒绝重复，
  服务返回既有 outcome（`duplicated:true`）。
- `data` 形状：`{schema:"bot-feedback/v1", feedback_id, action, origin{kind:user-chat-turn|ui-action,
  session_id, nonce, verified_by:"host"}, target{kind,id,version?,delivery_key?}, scope{kind,key},
  class_key?, subjects[], applied?, reverses?, accepted, reason?}`。不写用户原话/记忆正文/凭据。
- `action` 封闭 `adopt|undo|correct|suppress`（**`correct` 是唯一“说错了”词**，不得用 `wrong`）。
- `scope.kind` 封闭 `artifact|routine|class|user`，解析规则（R4，防止把“这类别推”扩成全部主动行为）：
  - `artifact`：只命中该 artifact id；不带 class_key 也合法。
  - `routine`：class_key 必须恰为 `routine:<该 routine id>`；不同 routine 不互相影响。
  - `class`：class_key 必须是**具体目标的窄类**（`proactive:<kind>:<taskId|runId|reminderId>` 或
    `routine:<id>`）；仅 kind 级 class（如 `proactive:task-done`）→ `ambiguous-scope`，不得由
    单条 artifact 自动扩大。
  - `user`：只接受 kind 级 class（`proactive:task-done|routine-result|reminder`），且 origin 必须是
    `ui-action`（用户在 UI 明确选择）；`user-chat-turn` 的来源只证明“用户说过”，不证明宿主理解正确 →
    `scope-requires-confirmation`。routine/reminder 级 class 请求 `user` → `scope-not-shareable`。
  - 同一 Bot 的不同目标（task-1 vs task-2、routine r1 vs r2）互不影响；只有 `user` + UI 明确选择
    才跨 Bot 共用。禁止业务关键词黑名单/把正文当 scope。
- `correct` 必须绑定 memory 已应用版本（`target.version == applied.memory.version`），否则
  `correction-not-applied`；它同时追加既有 `memory.review_requested`（disputed），交 M；
  不改写历史版本、不伪造 verified。
- `undo` 引用原 `feedback_id`（`reverses`），写反向事件并回滚状态；撤销抑制后 gate 立即不再 hold。
- `suppress` 只 hold 下一次主动判定（`feedback-held`），不删 routine、不停全部目标、不消耗保险丝；
  记录保留审计，`expires_at_ms` 只影响 gate。
- 幂等：同 `(artifact, scope, action)` 已有 active 记录 → 不新建第二条，返回既有 id；同一句
  「别推了」说三遍只留一条活偏好。
- 入口：UI 走 phone-only `user-action.phone.schema.json` 的 `feedback` action（宿主 nonce 校验）；
  模型入口 `RecordFeedback` 工具在 K release L3 后接 catalog；本契约先冻结形状。
- 旧 reader：未知 durable type + `ignorable:true` 被忽略；旧 golden/共享 user-action 基线不改。

### 3.2 用户动作 phone 扩展（`spec/bot/v1/user-action.phone.schema.json`）

两个 kind，只由 iOS 宿主/UI 产生，共享 `user-action.schema.json` 不变：

```json
{"nonce":"…","botID":"…","kind":"deliverySelection","rowID":"…","draftID":"…","expectedRevision":3,
 "selectedResourceIDs":["r1","r3"]}
{"nonce":"…","botID":"…","kind":"feedback","rowID":"…","verdict":"adopt|correct|suppress|undo",
 "feedbackID":"…"}
```

- `verdict=undo` 必填 `feedbackID`；`verdict` 与 durable `action` 同词（`correct`，不是 `wrong`）。
- 反馈不发起模型回合、不产生可见用户消息、不改变待审批状态。

### 3.3 `RecordFeedback` 工具定义（K L3 release 后接入 catalog）

冻结定义（`spec/bot/v2/record-feedback-tool.json`，字段与 F §3.1 一致）：`name=RecordFeedback`，
effect `write + confirm`（分类沿用现有 tool-effects：该调用写 durable feedback 并可能改变 gate，
必须可撤销，不是 auto）；`inputSchema` 要求 `action`+`target`，`action` 封闭
`adopt|undo|correct|suppress`，`target.kind` 封闭 `proactive|routine|memory|task|delivery|feedback`，
`target.version` 仅 correct/undo 需要，`scope` 默认 `artifact`，`disputed_refs` ≤8 且必须是规范
`record://`。工具必须由 `principal.kind=chat` 的真实用户回合调用；routine/task/proactive/
maintainer/verifier 调用返回 `permission-denied`。`suppress` 不暴露 class 字符串/“all”。

K L3（`BotToolCatalog.swift`、`golden/tool-catalog.phone.json`）未 release 前，G 只冻结本文件，
不写 catalog；release 后由 G 把同一 JSON 加进 catalog/golden，F 不改 schema。

### 3.4 P18 反馈状态文件（F，非事实源）

- UserDefaults key **`phone-dsh.bot.feedback.v1`**，值
  `{"v":1,"records":[{feedback_id,action,target,scope,class_key?,status:"active|undone|expired",
  created_at_ms,expires_at_ms?}],"rebuilt_from_commit_seq":N}`。
- **唯一事实是 `feedback.recorded` durable 事件**；该文件是 gate 的快速索引/缓存，可随时按事件重建。
  崩溃顺序：先写事件、后写文件；文件落后 → 下次启动按事件重放；文件超前 → 以事件为准删除幻影。
- 版本不是 1 或 JSON 损坏 → 整份忽略并按事件重建，不把未知版本读成 active；回滚旧 App 直接忽略该
  key（旧 App 无此 key 语义）。上限 512 条 active；超出按 `created_at_ms` 淘汰最旧，active 记录
  对应的 durable 事件永不删除。
- 跨 Bot：`scope.kind=user` 的记录按 `class_key` 全局生效；其他 Bot 只读该 key 的 typed 结果，
  不读模型写的 user/ 正文，也不复制判定。

### 3.5 三阶段 trace（R/E）

`trace` 只作为读视图（不新增事件）：`{turn_id, retrieved:[material_id], injected:{request_marker:
"dshbot:decision-context", request_id, request_fingerprint?}, adopted:[{artifact, material_ids}]}`。
- `injected` 必须来自真实模型请求的 runtime-context 段（`source.kind=runtime-context`），
  `request_marker` 逐字包含 `dshbot:decision-context`；没有这次请求快照就没有 injected。
- `adopted` 的每个 `material_id` 必须先在 `injected.material_ids`（由 block 的 materials 展开），
  再在 `retrieved` 中；顺序/子集违反 → 该次轨迹无效（不是 adopted）。
- 三阶段字段名冻结为 `retrieved`/`injected`/`adopted`；不得用 `used`/`seen` 别名。

## 4. 词表与显示

- 状态/理由一律用 G-1；feedback 额外 reason 封闭：`target-unresolved`、`scope-not-shareable`、
  `correction-not-applied`、`duplicate`、`permission-denied`、`insufficient-evidence`。
- `verification` 仍是写入断言（verified/unverified/disputed/unknown），不是系统认证；UI 显示
  「已核对/未核对/有冲突/未知」，`current` 不得显示成「已核对」。

## 5. 兼容、回滚与未覆盖

- 新成员/新 kind 全为可忽略增量；共享 P27 `user-action.schema.json`/共享 golden 不动。
- 旧 App 读新库：忽略 `feedback.recorded`（`ignorable:true`）与 phone action；不崩、不误判。
- 回滚：feedback 事件只追加；旧 App 不消费，抑制状态由新 App 的 gate 读；不复活已撤销记录。
- 未覆盖：`RecordFeedback` catalog 条目（K L3 未 release）；跨 Bot gate 的持久状态文件实现
  （F）；草稿/审批行的真实数据（C/U）；真实模型 adopted 证据（E/R）。

## 6. 共享向量与验收

- `golden/decision-context.json`：材料块 limits/状态/指令注入反例、digest 重绑定、feedback
  动作/scope/undo/幂等/错误反例、phone user-action 正反例、`feedback.recorded` 事件正例。
- `tools/validate_decision_context.py`：真实重算 limits/ digest / action 规则，并做 mutation。
- 命令：`python3 -B spec/bot/v2/tools/validate_decision_context.py`；`pytest` 不需要。
- 实现端：R（材料/三阶段）、F（feedback service/gate）、U（UI 投影）、C（adapter/装配）、
  E（用 `material_id`/`adopted` 证据）。
