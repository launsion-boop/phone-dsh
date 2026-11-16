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
  出现）；`value` 必须带与 basis 对应的前缀：`sha256:`（64 位小写十六进制）、`etag:`、`last-modified:`、`rev:`。
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
  `suggestion`、`draft`、`skill`。`skill` 保留枚举但当前**没有真实写事件**：读模型必须给
  `unknown` + `no-skill-write-event`，不得冒充已覆盖（新增写入路径需另开变更单）。
- `artifact.id` ≤200 scalar（memory 用完整 path，与 v2 §1.2 的 200 上限一致），`version` 仅在该对象真实有单调 revision 时出现。**断言不重复写
  `carrier`**：承载它的 durable event 的 `commitSeq` 在 append 时才分配，写 data 时不可知；读模型
  以「包含该 `derivation` 的事件自身」为 carrier，并从事件头取 `record://event/N`。若事件里出现
  自指 carrier 字段，schema 拒绝（`additionalProperties:false`）。
- `sources` 0–16 条，`record` 规范且去重；`role` 封闭：`evidence`、`review`、`trigger`、
  `creator`、`recipient`、`basis`。同一记录可因不同 role 出现一次；同一 `(record, role)` 不得
  重复。
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
| `skill` | **无** | 读模型固定 `unknown` + `no-skill-write-event`。这是**阶段未覆盖**，不是把 A04 的 skill 出处目标删掉：C 必须登记后续契约/接线；若 Bot 侧 skill 只在 DSH 工作台，需选等效通用接缝并保持普通 DSH 行为不变。 |

缺省回退只读**结构化字段**，不扫正文、不按日期/普通词/正文子串匹配，也不把模型自述当来源。

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
3. **授权撤权**：该 source 带 `grantId`，且 `grant.revoked` 的 `commitSeq` 晚于承载断言的
   `carrier` → `revoked` + `grant-revoked`。没有 `grantId` 时不做撤权推断（不猜）。
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
  metadata 对**原始文件字节**计算（`sha256:`），并用 `resource{kind:"file",key:<规范化路径或
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

- `state` 封闭：`current`、`changed`、`unavailable`、`revoked`、`erased`、`unknown`；取
  `sources[].status.state` 与 `upstream[].state` 的**最坏项**，优先级
  `erased > revoked > changed > unavailable > unknown > current`。非 current 的 `reasons` 是
  各来源 reason 的并集（去重、字典序）。
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

- 当前没有 Bot skill 写事件：`skill` 只以 `unknown` + `no-skill-write-event` 出现，不冒充已覆盖。
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
