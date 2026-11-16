<!-- SPDX-License-Identifier: MIT -->

# Bot v2 来源版本、派生关系与当前状态（G-1）

状态：`target`（契约冻结，实现由 P/L/M/C 按本文件 revision 落地；本文件本身不是实现证据）。
本文件是 [P26](../../README.md) 登记表内 phoneDSH Bot v2 的**新能力契约**，2026-11-16 由 G
冻结。它只补 v2 已有的 `record://` 引用、`evidence`、`trust`、`review`、事件库和
`phone record`：不新增第二原始记录库、不新增事件类型、不新增固定知识分类。

**与既有权威的关系。** `spec/bot/v2/README.md` §1.5/§1.5.1 继续拥有记忆证据/信任/核对断言；
§4 拥有 maintainer 批次。本文件拥有：来源身份与来源版本（§2）、`derivation` 来源断言（§3）、
`freshness` 当前状态读视图（§4）、派生对象读模型（§5）、maintainer 核验增量与质量门槛
（§7）。冲突时以本文件对**新增成员**的定义为准；既有成员（`evidence`、`review`、`trust`、
`version`、`erasure`）的语义不变。

## 1. 术语

| 术语 | 定义 |
| --- | --- |
| 原始记录 | 只有两处：DSH session log 行 `record://session/<id>#<seq>`、`bot_events` 行 `record://event/<commitSeq>`（v1 §4.2）。 |
| 观察（observation） | 一条**捕获外部来源**的原始记录：它带 v1 §4.3 观察信封（`source`/`origin`/`at`/`owner`/`ref`），或 G-3 的 `context.observed`。用户消息、Bot 自身工具结果、派生物不是观察。 |
| 来源身份（source identity） | 观察信封的 `source` + `origin` 二元组，二者都按原字节比较；除该来源自己的契约写明外不做 URL/路径归一化。 |
| 来源版本（source revision） | 该外部来源在观察时刻的版本，显式 known 或 unknown（§2.1）。它不是记录序号、不是记忆文档 `version`、不是 `updated_at_ms`。 |
| 基线（baseline） | 写派生物时随断言一起记录的 `source version` + `observed_at_ms` 快照（§3.2），用于日后判断「来源是否已变」。 |
| 派生物（derived artifact） | 从原始记录产生的对象：记忆文档版本、review 断言、routine、proactive 决策、notification/delivery/suggestion/draft（G-2）、skill。 |
| 当前状态（current status） | 读时重新解析出的 `current/changed/unavailable/revoked/erased/unknown`，永不持久化。 |

## 2. 来源身份与来源版本

### 2.1 `source_revision`（形状见 `source-revision.schema.json`）

只有两种状态，二选一：

```json
{"basis":"content-sha256","value":"sha256:6f1c…（64 位小写十六进制）","observed_at_ms":1760000005000,"basis_ref":"record://session/gb-main#5"}
{"reason":"source-unversioned","basis_ref":"record://session/gb-main#5"}
```

- 两个形态互斥：出现 `basis`+`value` 就是已知版本；出现 `reason` 就是显式 unknown；同时出现或都
  不出现都是非法。
- `basis` 封闭：`content-sha256`、`etag`、`last-modified`、`provider-version`（**P/L/N 的实现必须
  改用这四个值**；`content-digest`/`native-revision`/`state:known` 是 freeze 前的草案名，不得再
  出现）；`value` 必须带与 basis 对应的前缀
- `content-sha256` 可选 `subject`，二选一：`file-bytes`（对原始文件/附件字节计算）或
  `record-text`（对记录可读文本/抽取文本计算）；缺省按 `record-text` 处理（旧数据保守语义）。
  **主体不可混用**：文件 recheck 只有 `subject=file-bytes` 才能与 re-stat 的字节摘要比较；缺省或
  `record-text` 只能按文本比较（`sha256(raw)==token` 才算 unchanged），否则 `notPerformed`，绝不
  把文本摘要当文件字节版本。：`sha256:`（64 位小写十六进制）、`etag:`、`last-modified:`、`rev:`。
  - 来源提供原生版本（ETag、Last-Modified、连接器版本号）时**必须**用原生 basis；没有时才用
    `content-sha256`。`content-sha256` 对记录中该来源的可读文本按 UTF-8 字节计算（附件等二进制
    按原始字节）。
  - `provider-version` 的 `value` 是不透明字符串，由该来源契约定义；本文件不猜语义。
- `observed_at_ms` 是**来源观察时间**（信封 `at` 或 OS 事件时刻），不是处理时间、不是记忆写入
  时间；无法取得时显式 `null` 或省略，不得填 0。
- `basis_ref` 必须是规范 `record://`，指向产生该版本的记录；它必须可解析且属于调用者。
- unknown 必须带 `reason`，封闭枚举：`record-unresolved`、`record-erased`、
  `record-without-content`、`source-unversioned`、`invalid-reference`。unknown 不等于「当前」或
  「已核对」。
- **禁止**：用记忆文档 `version`、事件 `commitSeq`、记录自身序号或 `updated_at_ms` 冒充来源版本；
  用正文摘要以外的哈希（如路径哈希）冒充内容版本；known 而缺 value/basis；unknown 而缺 reason。

### 2.2 什么时候必须有来源版本

一条派生物的来源（§3.2 的 `sources[]`）若是观察，写入时必须有 `sourceVersion`，取 known 或
显式 unknown；若不是观察（用户消息、Bot 自己输出、review 断言），`sourceVersion` 可省略，此时
该来源的当前状态只由记录本身是否 live/erased 决定（§4.3）。旧数据没有该成员：合法，但读视图
必须是 `unknown` + `no-baseline`/`no-derivation`，不得补造版本。

### 2.3 资源身份（resource identity，G-1 r5）

**通道不是资源。** `source` + `origin` 只说明“从哪条通道/工具来”：`web_search`、`mcp://server/tool`
都不标识具体资料。比较“是否同一资料的新版本”只能用**资源身份**：

`resource = {kind, key, owner?, scope?}`，`kind` 封闭：

| kind | canonical key | owner/scope | 何时可用 |
| --- | --- | --- | --- |
| `web-url` | 规范化 URL：scheme/host 小写、去默认端口、保留 path/query、去 fragment | `owner`=信封 owner 或 botID；`scope`=egress grant/授权域 | 来源是 http(s) URL |
| `connector-resource` | 连接器返回的稳定资源 id | 连接器账号/授权域 | **必须有**连接器资源 id；只有 `mcp://server/tool` → 不可用 |
| `file` | 规范化绝对路径（+ 文件 id 若来源提供） | 所属 Bot/工作区 | 附件/文件来源 |
| `context-source` | G-3 的 source + OS 资源 id（eventIdentifier/contact id/region id…） | `owner_bot_id` | G-3 observation |
| `provider` | 该 provider 契约定义的稳定 key | provider 账号/授权域 | 有专门 provider 契约 |

- `derivation.sources[].resource` 显式给出时优先；没有时只允许按上表**已注册规则**推导（web URL、
  file、context）。connector/tool 没有稳定资源 id 时**不得**用 origin 代替。
- 身份比较包含 `owner`/`scope`：**同工具不同资源**、**同 URL 不同 owner/授权域**都不是同一资源，
  不得合并、不得判 changed。`key` 相同但 owner/scope 不同 → `unknown` + `resource-scope-mismatch`，
  不比较版本。
- 取不到稳定身份 → `unknown` + `no-resource-identity`；不得把两条不同资料串成“新版”。
- 反例（共享向量强制）：同一 connector 的 res-a/res-b；同一 URL 的 bot-a/bot-b 两个授权域。

### 2.4 观察 carrier 的真实形状（G-1 r11，Q1 P0-2）

观察索引只能解析**生产真实写入**的 carrier；不存在“carrier 带 `data.observation`”这一契约形状，
它只是测试自造的实现假设，L 必须删除该假设：

| carrier（durable event / session 行） | 观察字段位置 | resource 身份 | 备注 |
| --- | --- | --- | --- |
| `conversation.tool_result`（外部工具结果） | 消息 content 文本里的 v1 §4.3 观察信封（`source/origin/at/owner/ref`） | 按 §2.3 从信封 `source`+`origin` 推导：web URL / file path / connector 需结构化 resource id | 宿主自己的 bash/文件工具不加信封，不是 observation |
| `context.observed`（G-3） | flat `data`：`source/kind/observed_at_ms/owner_bot_id/consent_generation/source_version/uncertainty/delivery/payload` | `data.resource{kind:"context-source",key:<OS 资源 id>,owner}`（G-3 r3 起必填） | trust=`observation`；P 必须识别，不得落 `.assistant` |
| `comm.inbound` / `device-task` 终态 | 结构化 held/设备事件；若正文含信封则解析信封 | 来源有稳定资源 id 才给 resource；否则 `no-resource-identity` | 设备任务不是“最新文件版本” |
| 其他 durable type | 不自动当 observation | — | 不得因工具名前缀 `mcp__*`/`web_search` 就猜 observation；名字不是身份 |

- P 的 `sourceStates`/`evidenceSnapshot` 必须对上述 carrier 返回 `trust=observation`、`resolved`、
  `observed_at_ms`、record type 与 version（信封/数据里的来源版本或内容摘要）；`context.observed`
  不能落到 `default: assistant`。**resource 身份由 L 从真实 carrier 推导**（tool_result 信封
  `source+origin`、`context.observed` 的 flat `resource`），P 的 facts 不要求返回 resource，也**不得**
  从工具名前缀/通道猜；若 P 恰好已有 resource 可一并给出，但 L 必须自行解析真实 carrier 并在缺失时
  给 `no-resource-identity`，不得 current。
- P 与 L 的 adapter 必须对 **session 和 event 两类 ref** 都工作：L 不能只把 `record://session/...`
  送 P；`record://event/N` 必须按事件 principal 的 botID 送 P facts（sessionID 可为 nil，P 对 nil
  返回空时 L 按 owner 组/事件上下文重试）。否则 event 来源仍会走测试自造的 observation 路径。
- L 的 observation 索引必须按本表解析；测试里构造的 `data.observation` 不再作为契约证据，golden/测试
  必须覆盖真实 flat context 与正文信封两类 carrier。
- 写入端（C/P/L）的 `prepareBaseline` 必须有生产 caller；只存在于测试/assembly API 的不算接线。
- 若某个 carrier 的正文/结构无法稳定解析，读视图必须 `unknown` + 对应 reason，不得退回 `current`。

## 3. `derivation`：派生物的来源断言

### 3.1 形状（`derivation.schema.json`）

`derivation` 是既有 durable 事件 `data` 的**可选成员**，不是新事件类型、不是新库。一份断言：

```json
"derivation": {
  "artifact": {"kind": "memory", "id": "user/profile.md", "version": 3},
  "sources": [
    {"record": "record://session/gb-main#5", "role": "evidence",
     "sourceVersion": {"basis":"etag","value":"etag:v2","observed_at_ms":1760000005000},
     "grantId": "grant-7"}
  ],
  "basis": "用户 11 月 10 日原话与当天的网页观察"
}
```

- `artifact.kind` 封闭：`memory`、`review`、`routine`、`proactive`、`notification`、`delivery`、
  `suggestion`、`draft`、`skill`。`skill` 自本 revision 起有真实写事件：成功的 skill 文件
  create/update/delete 写一条 durable `skill.changed`（见 §3.4）；没有该事件的旧数据仍是
  `unknown` + `no-skill-write-event`，不得冒充已覆盖。
- `artifact.id` ≤200 scalar（memory 用完整 path，与 v2 §1.2 的 200 上限一致），`version` 仅在该对象真实有单调 revision 时出现。**断言不重复写
  `carrier`**：承载它的 durable event 的 `commitSeq` 在 append 时才分配，写 data 时不可知；读模型
  以「包含该 `derivation` 的事件自身」为 carrier，并从事件头取 `record://event/N`。若事件里出现
  自指 carrier 字段，schema 拒绝（`additionalProperties:false`）。
- `sources` 0–16 条，`record` 规范且去重；`role` 封闭：`evidence`、`review`、`trigger`、
  `creator`、`recipient`、`basis`。同一记录可因不同 role 出现一次；同一 `(record, role)` 不得
  重复。
- **role 的 provenance 分类（G-1 r14）**：

  | 类别 | role | 是否内容 provenance | 用途 |
  | --- | --- | --- | --- |
  | content | `evidence`、`basis`、`creator` | **是** | 决定 artifact 内容状态、upstream 失效、COMPACT/覆盖 scorer |
  | verification | `review` | 否（只进 review_effective） | 核对断言是否仍被当前记录支持；不单独把 artifact 判 erased/changed |
  | causal | `trigger` | **否** | 只记录触发/唤醒关系；不作为“为什么内容成立”的依据，不计覆盖、不参与 worst state |
  | delivery | `recipient` | **否** | 交付目标/接收方；不是内容来源 |

  - artifact 内容状态只取 content 类 source 的 worst state + content 上游；`review` 只决定
    `review_effective`，`trigger`/`recipient` 只在 trace/来源面板显示，不能把 artifact 判
    changed/erased/current，也不计入 COMPACT provenance 覆盖率。
  - 没有 content source（只 review/trigger/recipient）时，artifact 的 content 状态是
    `unknown` + `no-derivation`（不得 current）；旧数据无 derivation 同样 unknown。
  - COMPACT scorer 只统计 content role；不把 trigger/recipient 当 provenance，也不按业务关键词
    猜来源。
- `grantId` 可选：该来源当时依赖的授权标识；没有就不猜。
- `basis` 只作展示（≤200 scalar），宿主不因它认证任何事实。
- 写入顺序：先在同一次批量 resolve 中得到 trust 与来源版本，再把 `derivation` 放进**承载该
  派生物的那条事件**的 `data`；不能先写一条孤立 derivation 事件（本契约不提供该类型）。
- **幂等**：同一事件 `data` 里同一 `(artifact.kind,id,version)` 只能出现一次；跨事件重复断言
  按承载事件的 `commitSeq` 最大者为准，历史断言保留可回查，不覆盖、不删除。

### 3.2 基线（baseline）就是 sources 里的 `sourceVersion`

- **写路径 MUST**：memory/routine/proactive/notification/delivery/suggestion/draft 的写入者在
  **同一次**写前 resolve 中，把每条观察来源的版本作为该 source 的 `sourceVersion` 基线，并与
  `derivation` 一起放进承载该派生物的事件 `data`；只读时计算不构成基线，E2/E3 的真实版本变化
  将无法成立。P 的 `sourceStates` 负责提供事实，L 的 `derivation` 负责形状，写入端（Memory/
  Routine/Proactive/Delivery 服务）负责持久化；三者不得互相代写。
- **resource 的归属（方案 A，2026-11-16）**：`derivation.sources[].resource` 由**写入端**在写前
  调 L 的 `prepareBaseline(artifact:sources:)`（或等价的 provenance 预构造）得到，连同
  `sourceVersion` 一起作为完整 derivation 交给 P；P 的 `BotMemoryWriteRequest` 接受已构造好的
  `sourceBaselines`/derivation override，只校验与持久化，**不得自行推导/猜测 resource**（P 的
  record fact 没有 owner/scope/resource key）。写入端拿不到 resource 时整个写入 fail-closed：
  `memory-source-baseline-unavailable`（或该 artifact 自己的等价失败码），不写无身份基线。
  方案 B（P 的 `BotSourceBaseline` 增加 resource 字段）不作为本轮契约；若未来采用需另开 revision，
  不允许 A/B 并存。
- 观察来源同时 MUST 带 `resource`（或按 §2.3 注册规则可确定）；取不到稳定资源身份时写
  `unknown` 语义并在读视图给 `no-resource-identity`，不得用 origin 当身份。
- 读时用基线与**同一资源身份**的最新观察比较（§4.3）。没有基线（旧数据、非观察来源）时不得
  假装比较过；新写入路径不得以「读时再算」代替基线。
- **失败语义**：写路径 resolve 失败/超限时，整条写入失败并返回
  `memory-source-baseline-unavailable`，不写事件、不产生无基线版本，不降级成 `unknown` 后放行。
  旧事件（无 `derivation`）仍合法可回放；该失败码只约束新写入。
- 基线不是「永远有效」：来源更新、撤权、抹除后由 §4 重新判定；历史字段不回写。

### 3.3 各对象怎么带 `derivation`（不新增字段别名）

| artifact.kind | 承载事件（既有） | 来源断言 |
| --- | --- | --- |
| `memory` | `memory.document_written` / `memory.document_deleted` | `data.derivation`；缺省时读模型回退到 `document.evidence`（每条 role=`evidence`）。 |
| `review` | `memory.review_requested` / `memory.review_resolved` | `data.derivation`；缺省回退到 `data.evidence`/`refs`。 |
| `routine` | `routine.defined` / `routine.updated` / `routine.deleted` | `data.derivation`；缺省回退到 `causationId` 指向的记录（role=`creator`）。 |
| `proactive` | `proactive.considered` | `data.derivation`；缺省回退到 `causationId` 与 `data.trigger` 中的规范 ref（trigger 只作显示）。 |
| `notification` / `delivery` / `suggestion` / `draft` | G-2 冻结的承载事件（`card.presented`、`ui.send_to_user`、`comm.outbound`、G-2 delivery 事件 data） | `data.derivation`；缺省回退到 `data` 中键名为 `evidence`/`refs`/`sources`/`records` 的规范 ref 数组。 |
| `skill` | `skill.changed`（§3.4） | `data.derivation`（可选）或事件本身；artifact id=skill name，version=revision；删除事件后 lineage 为 unavailable + `skill-deleted`。旧数据无事件仍是 unknown + `no-skill-write-event`。 |

缺省回退只读**结构化字段**，不扫正文、不按日期/普通词/正文子串匹配，也不把模型自述当来源。

**新写入的 producer 矩阵（G-1 r14，生产接线缺口必须登记）**：

| artifact | 生产 producer（写前捕获 content source） | 缺 derivation 时的读视图 |
| --- | --- | --- |
| memory | P `BotMemory.write` + L `prepareDerivation` | 旧数据无 derivation → unknown/no-derivation；新写入 fail-closed |
| routine | S `UpdateRoutine`/C 写路径 + L `prepareDerivation` | **生产 producer 缺口**：causationId 只能作 legacy creator 回退，不能当内容来源；无 content derivation → unknown/no-derivation，不得 current |
| proactive/notification/delivery | F/U/C 的 delivery/proactive 写路径 + L | 无 content derivation → unknown/no-derivation |
| skill | C plugin→L `recordSkillWrite`（§3.4） | 无 skill.changed → unknown/no-skill-write-event |
| draft/suggestion | U/G-2 写路径 | 无 content derivation → unknown/no-derivation |

- routine 的 `causationId` 是**因果/触发**记录，fallback 到 role=`creator` 只在它能指认“谁/哪条记录
  设立了该 routine”时有效；若只是普通回合/唤醒，不能算内容来源。S/C 必须在新写入携带
  `derivation.sources`（content role），否则 A04 的 routine 出处只能 PARTIAL/NOT_RUN，不得以
  “有 causationId”关闭。

### 3.4 `skill.changed`（skill 写事件）

成功的 skill 文件 create/update/delete（`/dsh/home/skills/<kebab>.md`）由宿主写一条 durable
`skill.changed`（P25 add-only；`ignorable:true`；复用既有 `origin.kind=local, source=ipc` 与
`principal.kind=ipc`；不新增枚举值；author 记录实际写入者）。`data` 形状由 `skill-change.schema.json` 冻结：

- `skill{name,file,revision,content_sha256,bytes}`（delete 用 `previous_sha256`，不带 content/bytes）；
  `revision` 每 skill 从 1 单调，删除也占一个 revision；`content_sha256` 是对**原始 UTF-8 文件字节**
  的 `sha256:`（不是抽取文本、不是事件 JSON）；`previous_sha256` 是上一次成功写入的 hash。
- `author{kind:user|bot|migration|system,bot_id?,session_id?}`；事件不写 skill 正文、不写用户隐私
  内容，只写 id/revision/hash/author。
- 可选 `derivation`（G-1 同一形状）：有真实来源时带 `artifact{kind:"skill",id:name,version:revision}`
  与 sources；没有来源时省略，不得伪造。
- 写顺序：文件 rename + catalog invalidation 成功后写事件；事件失败 → 该次 mutation 返回失败并把
  catalog 标脏，下次启动按宿主 skill 目录 hash 对账补事件（author=system，revision 续接，不伪造
  sources）。文件改动但无事件 → 读 lineage 为 unknown + `no-skill-write-event`，不猜。
- 读取：任一 Bot 都可读同一 skill 的 lineage（skill 是 host-global，非 Bot 私有）；不得因此读取
  其他 Bot 的 session/事件。删除的 skill 不再可读正文，但历史 lineage 保留（最新事件 action=delete
  → unavailable + `skill-deleted`）。
- **state 优先级（G-4 r2，不得被文件 same 覆盖）**：skill write 的内容状态 =
  worst(content source 状态, content 上游状态, 文件 recheck 结果)。`recheck=same` 只有在上述来源与
  上游全部 `current` 时才把结果变成 `current`；任一 source erased/revoked/changed/unavailable 或
  上游失效必须保留（例如 source 已 erased + 文件字节未变 → `erased`，不是 `current`）。
  `recheck=changed` 为 changed；denied/unavailable/notPerformed 为 unknown + 对应 reason。
  最新 assertion 为 delete 时删除状态优先（unavailable + skill-deleted），但这不抹掉历史来源审计。
- 文件“当前字节未变”与“来源仍可用”是两件事：文件 recheck 只回答前者，不能重置 source/upstream
  的失效状态；任何实现不得在 skill 分支无条件 `current/reasons=[]`。
- 已知 `skill-deleted`/erased/revoked/`refresh-denied` 的 skill source **不得**再调用文件 recheck
  provider；直接返回对应状态；只有新授权/新 source identity 才重新尝试。
- 兼容：旧 reader 忽略未知 type；旧数据无事件 → unknown；回滚旧 App 不写/不读新事件，skill 文件
  仍可用；新 App 读到旧数据不伪造 revision。

### 3.5 artifact scope / 内部 key（G-1 r15，root 裁决）

跨 Bot 的 artifact 隔离**只用现有信息**，不新增持久 wire 字段、不做迁移：

- 内部 artifact key = `(owner_scope, kind, id, version?)`。`owner_scope` 在读取时由
  `event.principal.botId` + artifact 的 path/kind 推导：
  - `memory`/`review`：id 以 `user/` 开头 → `shared`（所有 Bot 同一 key）；以 `agent/` 开头 →
    `bot(<principal.botId>)`（每个 Bot 独立）；其他 path → `bot(...)`。
  - `skill`：`host`（host-global，跨 Bot 同一 key；session/event 仍按 Bot 隔离）。
  - `routine`/`proactive`/`notification`/`delivery`/`suggestion`/`draft`：`bot(<principal.botId>)`。
  - principal 缺失或无法解析 owner → key 为 `unknown`，读视图 `unknown`，**不得**落到 shared。
- API 规则：`trace`/`reverseTrace`/`currentState(s)`/`sourceStatuses`/`invalidation`/`audit` 必须接受
  同一 key（或显式 owner）；缺省 owner 只能由宿主从已认领 session 的 botId 填，**不能**默认 shared/
  全局。所有 assertion 查找、latest 索引、baseline 查找、erasure/grant/invalidation、upstream 边、
  source_statuses 合并都用同一 key；不能只修一个查询。
- **nil/empty 不是 unscoped 许可（G-1 r16）**：带 `botID` 的 scoped API 在 nil/empty 时**不得**回退到
  未过滤 snapshot；必须返回 unknown/空结果或拒绝，不能把 cross-Bot latest 当成调用者自己的。只有
  明确命名、并记录调用者身份的 legacy unscoped API 可以读全量；生产调用点必须传宿主已认领的
  botID（MCP material/status、UI inspect、maintenance invalidation、R material adapter 同）。
  refs-only overload 若无法表达 artifact key，必须改为 artifact-scoped 或显式 unscoped；invalidation
  也必须带 scope，不能声称“同 key 贯穿”而生产接口无 botID。
- **查询隔离 ≠ 失效传播（G-1 r17）**：`invalidation` 由原始 source 的抹除/撤权触发时，传播是
  **全局**的：所有 Bot 中依赖该 source 的派生对象都必须失效/标 erased，不能只更新某个 Bot 而让其它
  Bot 的派生泄漏旧结论。查询/可见性仍按 §3.5 的 artifact key 隔离：调用者只能读自己有权看的
  artifact/trace，不能因全局传播而看到别的 Bot 的对象。两者必须同时成立：传播用 source/derived
  关系（跨 owner），查询用 owner scope；不得把 query 隔离误当“只擦一个 Bot”，也不得把全局传播
  误当“跨 Bot 可读”。
- 回归必须包含 nil/empty → 非 shared 的负例、trigger-only→unknown、evidence 有效/失效；只跑正例
  scope 不算完成。
- 基线按 `(artifact key, ref, role)` 存/查，不按全局 `ref` 覆盖：同一 ref 被两个 artifact/两个 Bot
  引用时各自保留 baseline；缺失 baseline → `unknown` + `no-baseline`，不借用其他 key 的 baseline。
- `user/` 共享：所有 Bot 看到同一 key；写入者证据仍按记录 owner 解析，跨 Bot 解析不到 →
  `cross-bot-unresolved`（§4.6）。`agent/` 按 Bot 隔离：Bot A 的 `agent/x.md` 与 Bot B 的同 path
  是两个 key，不得合并/invalidation 串扰。
- 兼容：事件/envelope/schema 不变；旧数据读时按上述规则推导 owner，不需要新字段；旧 reader 只忽略
  新增内部 API 参数，不影响 wire。

## 4. `source_statuses`：当前状态读视图

### 4.1 形状（`source-status.schema.json`）

一项对应一个 `record://` 来源，读时重新解析，不持久化：

```json
{
  "ref": "record://session/gb-main#5",
  "roles": ["evidence", "review"],
  "state": "changed",
  "reasons": ["source-changed"],
  "observed_at_ms": 1760000005000,
  "record_type": "tool/result",
  "trust": "observation",
  "source_version": {"basis":"etag","value":"etag:v2","observed_at_ms":1760000005000},
  "baseline": {"basis":"etag","value":"etag:v1","observed_at_ms":1760000004000},
  "resource": {"kind":"web-url","key":"https://example.com/a","owner":"bot-a","scope":"grant-7"},
  "rechecked_at_ms": 1760000010000,
  "latest_ref": "record://session/gb-main#9"
}
```

- `state` 封闭：`current`、`changed`、`unavailable`、`revoked`、`erased`、`unknown`。
- `reasons` 封闭（非 `current` 至少一项）：`record-unresolved`、`record-erased`、
  `grant-revoked`、`source-changed`、`newer-observation-unversioned`、`revision-basis-mismatch`、
  `no-baseline`、`source-version-unknown`、`cycle-detected`、`scan-limit-exceeded`、
  `no-resource-identity`、`resource-scope-mismatch`、`refresh-not-performed`、
  `refresh-unavailable`、`refresh-denied`。
- `observed_at_ms` 是该记录自己的时间（session 行时间/`bot_events.time`）；没有则显式 `null`。
- `record_type` 是记录类型（`tool/result`、`user/message`、`memory.document_written` 等）；
  无法取得时为 `null`。
- `trust` 按 v2 §1.5 的既有推导（`user`/`observation`/`assistant`）；无法取得时为 `null`，
  不得猜。
- `source_version` 是该来源**当前**版本；旧数据可为 `null`（未计算）。known/unknown 里含
  `basis_ref` 指向产生版本的那条记录。
- `baseline` 是写该派生物时快照的版本（可选；旧数据/非观察来源缺省）。它让来源面板/M 能解释
  「为什么 changed」，而不是只看到当前值。
- `resource` 是本次比较用的资源身份（§2.3）；`rechecked_at_ms` 是读时真实 recheck 成功的时间。
  `latest_ref` 是同一资源身份的最新观察（含自己）；没有则省略。`scan-limit-exceeded` 是
  `unknown` 的 reason：读模型在窗口内无法确定最新观察，不得当 current。

### 4.2 一次批量

一次 ReadMemory/Recall/lineage 调用只解析一次：同一不可变 snapshot 产出全部状态，不逐条重扫
事件库、不为每条命中新开事务。resolver 不可用或超限时，整个 `source_statuses` 成员省略并记录
诊断码 `source_status_unavailable`；不得用全 `unknown` 冒充「已计算」。

**最新观察从哪里找（可实现索引）。** 观察身份只从 **durable `bot_events`** 的结构化数据取：
`conversation.tool_result`（外部工具结果，含信封/结构化 payload）、`comm.inbound`、
`context.observed`（G-3）以及未来登记为「observation carrier」的事件类型。一次解析在
`commitSeq > 最早待检基线所在事件` 的窗口内做一遍按 `type` 过滤的扫描，在内存按
**资源身份** `(resource.kind, resource.key, owner, scope)`（§2.3）建 latest 索引，**不按** `source+origin`
合并；没有稳定身份的记录不进入索引、不能参与 changed/current 判定。不逐条扫 DSH session 行、
不读 `materialized/home`。窗口上限
**10,000 条事件或 32 个来源身份**（先到者为准）：超出且仍未覆盖全部待检身份时，对应项为
`unknown` + `scan-limit-exceeded`，整个调用不得声称 current。读模型可以对同一 `generation` 缓存
该索引，`generation` 变化即丢弃。

### 4.3 状态判定（唯一权威，按顺序短路）

只看**结构化**记录与 `derivation`，不看正文语义：

1. **记录不存在**（含不属于本 Bot、已物理消失）→ `unavailable` + `record-unresolved`。
2. **记录已抹除**（`erasure` 覆盖，或 `record_erased`）→ `erased` + `record-erased`。
3. **授权撤权（终态）**：该 source 带 `grantId`，且该 grant 已有 `revoked_at_seq` → `revoked` +
   `grant-revoked`，**与 carrier 的先后无关**。撤权后新建的派生物若仍引用同一 grant，不能因
   `revokedSeq` 早于新 carrier 而复活 current；carrier 时间只用于审计顺序，不是重新授权。
   合法重新授权必须是**新的 grant id 或新的 generation**（旧 id 不得复用）；旧 grant 上的历史/新
   断言都保持 revoked。写时应拒绝引用已撤 grant；若已写入，读视图仍 revoked。没有 `grantId` 时
   不做撤权推断（不猜）。
4. **无基线**：来源是观察 → `unknown` + `no-baseline`；来源不是观察（用户消息、Bot 自身输出）
   → `current`（记录不可变，存在即当前）。
5. **基线 unknown**：`unknown` + `source-version-unknown`；旧数据没有基线时用
   `no-baseline` / `no-derivation`。
6. **资源身份**：按 §2.3 解析；观察来源取不到稳定身份 → `unknown` +
   `no-resource-identity`；同 `kind`+`key` 但 owner/scope 不同的更新观察 →
   `unknown` + `resource-scope-mismatch`，不与任何版本比较。
7. **有同一资源身份的更新观察**（`observed_at_ms` 更大；相同时间按记录引用排序更大者）：
   - 同 basis、不同 value → `changed` + `source-changed`；
   - 不同 basis → `unknown` + `revision-basis-mismatch`（不能跨 basis 断言相等/不等）；
   - 同 basis、同 value → `current`；
   - 更新观察版本 unknown → `unknown` + `newer-observation-unversioned`。
8. **没有更新观察**：**不等于仍然新鲜**。必须在本读取中做一次真实 recheck：
   - provider 成功且 revision 相同 → `current`，写 `rechecked_at_ms`；
   - provider 返回不同 revision → 按 §7 的 changed/revision-basis-mismatch 处理；
   - 无权限/被拒 → `unknown` + `refresh-denied`；
   - provider 不可用/超时/无 provider → `unknown` + `refresh-unavailable` / `refresh-not-performed`。
   非观察来源（用户消息等）仍是 `current`（不可变记录）。
9. 以上都不命中 → `unknown` + `refresh-not-performed`；**没有 recheck 证据不得返回 current**。

`current` 只表示「本次读取有真实 recheck 证据且与基线一致，或来源不是观察」，**不是**
「结论已核对」；核对仍是 v2 §1.5.1 的 `review` 写入断言。`review.verified` 不因 `current` 升级为
系统事实认证。

### 4.5 真实 recheck 的 producer（E3/A03）

“没有新 observation”不是新鲜度证据。每个来源类必须有真实 producer 在下一次使用/决策时重新观察：

| 来源类 | producer | 失败/无权限表达 |
| --- | --- | --- |
| web / connector | R/C 的 egress provider 真实重新抓取（ETag/Last-Modified/条件请求或内容摘要） | `refresh-denied` / `refresh-unavailable` |
| file / attachment | P 重新 stat + **原始文件字节**的流式 SHA-256（同一资源身份） | `refresh-denied`（越权/越界）/ `refresh-unavailable`（stat/read 失败）/ `no-resource-identity`（无 file key/owner） |
| context（G-3） | N 重新查询 OS/事件源（按 consent generation） | `refresh-denied` / `refresh-not-performed` |
| 无 provider | 不得假定新鲜 | `refresh-not-performed` |

- E3 验收必须**真实修改文件/HTTP 服务内容**（不改测试 seed、不手插 newer observation），再让下一次
  真实决策走同一 producer 观察；只塞一条 newer event 不算。
- **文件来源的版本必须是原始字节摘要**：观察/导入时的 `sourceVersion` 必须由 App/Worker import
  metadata 对**原始文件字节**计算（`sha256:` + `subject:"file-bytes"`），并用
  `resource{kind:"file",key:<规范化路径或
  文件 id>,owner:<bot/workspace>}` 固定身份。记录里若是抽取文本的摘要（PDF/图片文本等），**不得**
  当作文件字节版本与 re-stat 比较；缺原始字节摘要/resource → `source-version-unknown` /
  `no-resource-identity`，不得 current。
  - producer 边界：**C（App/Worker import 与 VFS→host URL resolver）** 负责写入/注入原始字节
    摘要与可解析的文件定位；**N** 提供用户选定媒体/分享的真实字节与来源；**P** 只实现
    `BotFileSourceRechecking`（bounded streaming SHA-256 + stat，注入 locator，不硬编码 VFS 映射）
    并返回 `refresh-*`/`no-resource-identity`，不自称 current。P 的 `BotRecordService` 现有文本
    `content-sha256` 不是文件版本，不得冒充。
- producer 不可用/失败时，材料块/来源面板必须显示“未能验证/可能过时”，不得显示 current 或 verified。
- `skill` 当前无写事件：`unknown` + `no-skill-write-event` 是阶段未覆盖，C 登记后续契约/接线，
  不因本文件自动缩小 A04 范围。

### 4.4 读取面集成

`ReadMemory` 的单文档结果与 `RecallMemory` 的每个命中新增**可选** `source_statuses` 数组：
与 `evidence ∪ review.refs` 的并集一一对应（`roles` 标明来源组），顺序按首次出现。它是本文件
§4 的唯一当前状态视图。既有 `evidence_status` 保留为 legacy：`source_version` 继续 `null`，
不再扩展、不得改变语义；新读取方用 `source_statuses`，新代码不得再写第二套判定。

### 4.5.1 云侧公开来源 recheck（E7，复用现有 fetch）

web/connector 的真实 recheck 可以复用云仓**现有** `POST /v1/web/fetch`（Bearer + 既有 target/
allow-list/超时/大小约束），不新增端点、不新增存储、不新增 wire 字段；原正文只在内存中用于比较：

- 归一化：对返回 `content` 统一换行（`\r\n`/`\r` → `\n`）、去首尾空白，按 UTF-8 计算
  `sha256:<hex>`（G-1 `basis=content-sha256`，web 公开文本用 `subject:"record-text"`）；`title` 不入
  version。规则由 R/P 共用，不得一边归一化一边不归一化。
- `observed_at_ms`：优先云响应标准 `Date` 头（秒级，转 ms）；需要 ms 精度时可用客户端接收时间，但
  必须标明来源；不得用模型/客户端本地猜测的抓取时间冒充云时间。
- identity：请求的规范化 URL（scheme/host 小写、去默认端口、保留 path/query、去 fragment）；现有
  response 不暴露 redirect 最终 URL，因此**不得**声称跨 redirect 的资源身份；digest 变即 changed。
- 比较：同 digest → current/unchanged；不同 → changed；401/403/私网/目标拒绝 → refresh-denied；
  5xx/超时/空正文/不可得 → refresh-unavailable/refresh-not-performed；这些情况不得 current，也不得
  用旧正文冒充新鲜。
- **已知拒绝不再调 provider（recheck gate）**：source 已处于 `refresh-denied`/`grant-revoked`/
  `record-erased`/`skill-deleted` 或 scope mismatch 时，后续 recheck 必须直接返回对应状态，**不得**
  再调用网络/文件/技能 provider 试探；只有出现新的显式授权（新 grant/generation）或新的 source
  identity 才可重新尝试。skill 的 source recheck 同此规则（见 §3.4），已知删除/撤权时不做文件
  recheck。
- 云侧不落正文/URL/凭据到 DB/log；手机只在内存 hash/比较，写时基线仍按 G-1 持久化。
- 若现有响应未来不足以表达版本/时间，再以最小 additive delta 变更；本 revision 不需要。

### 4.6 cross-Bot shared read（G-1 补充）

- 共享 `user/` 记忆的 evidence 可能指向**另一个 Bot**的 session/event。宿主只能按引用解析出被引用的
  那条用户原话（及 `user` trust），不得把其他 Bot 的 session、事件、索引或 freshness 暴露给读者；
  读者 Bot 不能因此扩大 `phone record` 范围。
- 能解析 → 该 source 可按 `current`（用户消息不可变）显示；不能解析（越权/宿主未提供 shared reader）
  → `unknown` + `cross-bot-unresolved`，**不得**降级成 current，也不得把别的 Bot 记录标 erased。
- `latest_ref`/resource 仍属于写者 Bot 的记录；读者只读该引用，不合并到自己的 latest 索引。
- skill 是 host-global：lineage 跨 Bot 可读；这不改变上面的 session/event 隔离。

### 4.7 COMPACT provenance（压缩不改写来源身份）

- DSH 压缩用 surface replace 替换区间，被替换的 session 行仍保留；`record://session/<id>#<seq>` 的
  身份、时间、内容摘要不变，`shadowedBy` 只是“被哪条 replace 遮蔽”的读视图链接。
- 压缩不是新的 observation、不是 source version、不是 erased；不得因 `shadowedBy` 把 source 判
  changed/current/erased，也不得改写 baseline。latest 索引只按 §4.2 的 durable carrier 建，压缩不会
  删除 durable event；若某 carrier 只在 session 行且已被 replace，仍按原 ref 解析，解析不到才按
  `record-unresolved`/`no-resource-identity` 处理。
- 源面板/材料块可以显示“已被压缩，原文可按引用取回”，但状态仍是来源版本状态；不得用压缩摘要冒充
  原文或当前事实。

## 5. 派生对象读视图（`derivation-view.schema.json`）

```json
{
  "artifact": {"kind":"memory","id":"user/profile.md","version":3},
  "carrier": "record://event/41",
  "state": "changed",
  "reasons": ["source-changed"],
  "sources": [{"record":"record://session/gb-main#5","role":"evidence",
               "status": {…§4.1 一项…}}],
  "review_effective": {"state":"unverified","reasons":["source-changed"]},
  "upstream": [{"artifact":{…},"state":"erased"}],
  "generation": {"head_commit_seq": 57,"last_erasure_seq": 55,"last_grant_seq": 12}
}
```

- `state` 封闭：`current`、`changed`、`unavailable`、`revoked`、`erased`、`unknown`；只取
  **content 类 source**（`evidence`/`basis`/`creator`）与 content 上游的**最坏项**，优先级
  `erased > revoked > changed > unavailable > unknown > current`。`review` 只进
  `review_effective`；`trigger`/`recipient` 不参与 state/upstream（G-1 r14）。非 current 的
  `reasons` 是参与状态的来源 reason 并集（去重、字典序）。
- `upstream`：若某 source 的 `record` 是另一个派生物的 `carrier`（该来源本身是派生物断言），
  递归其状态；深度 ≤8、对象总数 ≤10,000，超出截断并给 `truncated: true`，不得静默返回 current。
- **环**：依赖图成环时，环内对象一律 `unavailable` + `cycle-detected`，不参与 current；
  不递归爆栈。
- `review_effective`：存储的 `review.state` 只有在 `evidence ∪ review.refs` 全部 `current` 时
  才派生为 `verified`；任一失效 → `unverified` + 失效 reason；存储为 `disputed` 时保留
  `disputed`；无 review → `unknown`。**不改写**历史 `review` 字段、不删除对象、不复活已抹除
  内容。
- `generation`：`(head_commit_seq, last_erasure_seq, last_grant_seq)` 的可比较 token；缓存/上下文
  只在本 token 变化时重算，旧 token 的状态不得复用。token 缺失/不可比较时按最坏情况重算。
- 解析顺序固定（`sources` 按 `record` 字典序、`upstream` 按 `(kind,id,version)` 字典序），
  同一事件序列任意重复/乱序查询得到字节级一致结果；ephemeral 事件与缺失 `commitSeq` 不进入图。
- 并发：一次查询内使用一个不可变 snapshot；查询与新 append 不得混合两代状态。

## 6. maintainer 核验增量与质量门槛（M）

### 6.1 durable 增量（既有事件、可选成员）

`memory.maintenance_finished` 的 `data` 增加（都是可选，旧批次合法）：

- `checks.verification_rechecked`：boolean；
- `verification`：`{checked,verified,stale,disputed,unverifiable,blocking,findings[]}`，
  `findings` ≤24 条，每条 `{path,state,reasons,refs,newer_refs?,preferred_ref?}`；
  `state` 封闭 `verified|stale|disputed|unverifiable`，`reasons` 用 §4.1 的 reasons 加
  `trust-mismatch`、`review-model-basis`、`single-signal-fact`、`cross-signal-mismatch`、
  `conflict-not-preserved`、`user-scope-without-user-evidence`；
- `failure_code` 追加 `maintenance-verification-unrechecked`、
  `maintenance-conflict-not-preserved`、`maintenance-user-scope-evidence`。
- **旧数据没有 `verification` 是合法**：读作「无核验记录」，不伪造 verified。schema 不把
  `verification` 设为 required（那会让旧事件对校验器非法）；新写入者 SHOULD 写。
- `memory.maintenance_started` 可选 `verification_policy {gate_revision, gate_sha256}`；缺省只
  在 finished 里记录实际证据。

### 6.2 质量门槛（`maintenance-quality-gate.json`）

冻结阈值（阈值只能由 root/用户显式变更范围时修改；M 的评测器按文件内容 fail-closed）：

- 矛盾样例 2 条、过期外部证据样例 2 条（catalog SHA-256 由 M 在 delivery 中给出，随批次写入
  `verification_policy`/评测报告）。
- `correction_rate_min = 0.75`、`stale_detection_rate_min = 0.75`、
  `mechanical_violations_max = 0`、`false_verified_max = 0`、
  `memory_suite_regressions_max = 0`、`min_real_batches = 2`、`repeat = 1`、独立 judge。
- 文件缺失/SHA 不符/样例数不足 → `NOT_RUN`，不按默认值放行；PASS 不自动把 maintainer 从
  `off` 打开。

## 7. 兼容、迁移与回滚

| 组合 | 行为 |
| --- | --- |
| 旧 producer → 新 reader | 没有 `derivation`/`source_statuses`/`verification`：合法；读视图为 `unknown` + `no-baseline`/`no-derivation`；不从 `evidence` 补造版本，不伪造 verified。 |
| 新 producer → 旧 reader | `derivation` 是既有事件 `data` 的可选成员，旧 Swift/Android reader 忽略未知成员；`source_statuses` 是工具结果的可选成员，旧 reader 忽略。**不新增事件类型、不新增 wire kind。** |
| 旧持久化数据 → 新代码 | 事件库/session log 不重写；旧记忆 golden/旧 Android 解析器仍按原字段工作。 |
| 新数据 → 回滚旧代码 | 旧代码忽略新增成员；不依赖「读到 derivation 才活」；`erasure`/`grant.revoked` 语义不变。 |
| 已抹除/撤权 | 读时重算；缓存、索引、上下文材料必须按 §5 `generation` 失效；不得复活或把旧值当 current。 |

## 8. 明确不覆盖

- 旧 skill 数据无 `skill.changed`：仍以 `unknown` + `no-skill-write-event` 出现，不冒充已覆盖；
  新写入按 §3.4，生产 producer/reconcile 由 C 接。
- 建议附件/draft 的创建与选择语义在 G-2；本文件只定义它们的来源断言与状态。
- 云端只读公开来源核验与端云调度在 G-3；云侧不得把本文件的 `unknown` 当 current。
- 不新增固定知识分类、不新增第二原始库、不新增 `*invalidated` 事件流。

## 9. 共享向量与验收命令

- 向量：`golden/provenance.json`（valid/invalid + 期望状态 + mutation）。
- 参考实现：`tools/validate_provenance.py`（真实重算状态；mutation 自检必须失败）。
- 局部命令：`python3 -B spec/bot/v2/tools/validate_provenance.py`
  `python3 -B spec/bot/v2/tools/test_validate_provenance.py`
- 全量：`python3 -B spec/bot/v1/tools/validate_vectors.py`（phone-spec 会一并跑 v2；本文件新增
  检查接入前先局部，接入后由 E 统一跑一次）。
- 实现端验收由 P（Memory/Journal）、L（Provenance）、M（maintenance）、C（装配）各自用真实
  codec 跑同一批向量；只跑 schema/checker 不算 runtime conformance。
