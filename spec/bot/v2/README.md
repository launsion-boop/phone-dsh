<!-- SPDX-License-Identifier: MIT -->

# phoneDSH Bot v2 契约（记忆、唤醒标记、主动提醒）

状态：`target`。本目录冻结 P26 中由 phoneDSH 主导的三部分：记忆、唤醒标记和主动提醒。
静态 schema/golden 通过不等于 Swift、Worker、模型或真机已经实现。

**权威。** 从 2026-11-10 起，记忆、唤醒标记、主动提醒三部分以本目录为唯一权威，由 phoneDSH
维护，不再跟随 dsh-bot 钉版。记忆部分在 PC-20261112-bot-memory-v2 中从 fact 改为文档树；
routine 预定通知、在场/打扰和设备任务结果重投是 phoneDSH 自有增量
（PC-20261111-bot-v2-presence）；其余唤醒标记与主动提醒仍沿用移交时的上游形状。
`spec/tools/bot/export-vectors.mjs` 不再导出或覆盖本目录的任何文件。

其余 Bot 契约仍在 `spec/bot/v1`，仍跟随 dsh-bot 钉版：事件信封、工具面、卡片、行、
回合来源（[v1/README.md §4.1](../v1/README.md#41-回合来源turn-origin)）和 MCP 端点。
Android 与 HarmonyOS 没有 Bot runtime，本目录对它们没有实现端。

本目录没有 `dshbot-pin.json`，也没有 `export-manifest.json`：那两份文件只约束 v1 的原样
上游导出。变更本目录必须按 [AGENTS.md](../../../AGENTS.md) §3 走变更单，并从
[P26](../../README.md) 的登记表/触发表触发；不得把“手机主导”解释成可以放宽未知字段、
版本或失败路径。

## 1. 记忆：agent 组织的文档树

记忆是带路径的 Markdown 文档树，**不是 fact**。产品只固定两个根，因为根表达归属和可见范围：

- `user/`：关于用户的事，所有 Bot 共享、彼此可见；一份，多个写入者。
- `agent/`：这个 Bot 自己的工作知识；每个 Bot 一份，其他 Bot 不可见。

根以下的分目录、命名、篇幅都由 agent 决定；没有 tier，也没有 `importance`、`sensitivity`、
`applicableWhen`、`archived`、`l2`、`superseded_by` 或 `expires_at`。旧 fact 只作为迁移输入存在
（`memory-legacy-fact.schema.json`）。

### 1.1 权威与版本

- 权威仍是 SQLite `bot_event_headers` + `bot_event_payloads`（P25 v3 拆分；只读视图
  `bot_events` 供旧读取路径），不新增文件系统权威。每次写入是一条 durable 事件
  （`memory.document_written`），每次逻辑删除是一条 `memory.document_deleted`；事件携带作者
  （`principal`）、完整新版本和版本前提 `expected_version`。物理抹除另写一条 `erasure` 事件，
  见 §1.8。
- 回放按 `commitSeq` 顺序应用事件。每份文档的 `version` 从 1 单调递增，删除也占用一个版本；
  历史版本可从事件库回看，`UpdateMemory{"action":"restore"}` 把旧版本作为新版本写回。
- `memory-document.schema.json` 冻结 live 文档/版本形状；`memory-write-request.schema.json`、
  `memory-write-result.schema.json`、`memory-read-result.schema.json`、`memory-recall.schema.json`
  冻结三个原语的输入/输出形状。`memory-legacy-fact.schema.json` 只描述迁移输入。
- 路径规则（实现和参考向量都必须一致）：
  - 以 `user/` 或 `agent/` 开头，大小写敏感；总长 ≤ 200 个 Unicode scalar。
  - 段间用 `/`；不允许空段、`.`、`..`、反斜线、控制字符或首尾空白；每段 ≤ 64 scalar。
  - `user/INDEX.md` 和 `agent/INDEX.md` 是保留索引路径；路径本身不做 Unicode 归一化。
- 文档内容没有产品篇幅上限。`INDEX.md` 有硬上限，见 §1.4。

### 1.2 三个原语

`UpdateMemory`（`memory-write-request.schema.json`）对路径写入、局部修改、移动、删除和回滚：

| `action` | 参数 | 语义 |
| --- | --- | --- |
| `write` | `content` | 用完整内容覆盖文档（创建时 `expected_version=0`）。 |
| `append` | `content` | 在现有内容末尾追加；文档必须存在。 |
| `replace` | `find`, `replace` | 精确替换所有 `find` 出现；一个都没找到返回 `memory-replace-not-found`。 |
| `move` | `to` | 源文档必须存在，目标必须不存在；同一批次写目标并删除源。 |
| `delete` | — | 忘记一份文档（逻辑删除）；历史版本仍可回看。模型工具永远不能触发物理抹除；物理抹除只走宿主 UI/服务路径，见 §1.8。 |
| `restore` | `restore_version` | 取历史版本内容，作为当前版本写回。 |

所有 action 都要求 `expected_version`：调用方刚读到的 live 版本；`0` 表示文档当前不存在。
版本对不上返回 `memory-version-conflict` 和 `current_version`，不写事件。成功返回新 `version`
（`move` 返回目标版本 1）。失败结果见 `memory-write-result.schema.json`。

`ReadMemory` 读一份文档或列一个目录（`memory-read-result.schema.json`）：

- `{path}` 是 live 文档时返回完整 `content`、`version`、`author`、`evidence`、`trust`。
- `{path, version}` 读历史版本；已删除版本返回 `deleted:true`、空 `content` 和
  `deletion_reason`。未知版本返回 `memory-version-not-found`。
- `{path}` 是根或目录时只列直接子项（`document`/`directory`），按路径排序。
- 既不是文档也不是目录前缀返回 `memory-not-found`。

`RecallMemory`（`memory-recall.schema.json`）在 live 文档正文上做全文检索，沿用既有 BM25 和
CJK 分词。`scope` 为 `agent`、`user` 或 `all`；默认 `all`，但 `agent` 只命中本 Bot。
返回 `path`、最多 500 scalar 的 `snippet`、`version`、`updated_at_ms`、`evidence`、`score`、
`relevance`、`recency`。两个根的 `INDEX.md` 已在每回合注入，因此不进入检索结果。`score = 0.85 * relevance + 0.15 * recency`，recency 以
`updated_at_ms` 计算、半衰期 180 天；`importance` 随字段一起删除。空 query 按更新时间倒序。
结果被截断时返回 `count`、`total` 和 `truncated`。

### 1.3 单一作者与版本前提

- 主对话（`chat`）可以写 `user/` 和 `agent/`。Task、routine、team、proactive、watchdog 会话不能
  直接改这两个根，只能提交到 `agent/inbox/<自己的 sessionId>/`；写到别的目录或别人的 inbox
  返回 `memory-scope-denied`。inbox 的合入由主对话或 §4 的 maintainer 负责。
- maintainer 会话可以写 `user/` 和 `agent/`，但写 `user/` 的回合来源规则换成 §4.2 的证据
  边界：至少一条 `user` 引用，且必须是主 Bot 的 maintainer。它不在用户回合里，`source.kind`
  是 `maintenance`；见 §1.5。
- 每次写入都必须带 `expected_version`。宿主在写入前按当前 live 版本校验；并发写入只有一个
  能成功，另一个得到 `memory-version-conflict`，因此同一时刻一份文档只有一个作者能写成功。
- `user/` 有多个 Bot 写入者，靠版本前提加证据约束：写入 `user/` 必须同时满足
  （a）回合来源是真实用户回合、（b）`evidence` 中至少一条按 §1.5 推导为 `user`。缺一返回
  `memory-source-boundary` 或 `memory-evidence-required`。`agent/` 写入不要求用户证据。
- `move` 同时检查源路径和 `to` 的权限与证据边界。`delete` 同样受单一作者权限约束；UI 的
  「忘记」走宿主直接路径，不经过模型工具。

### 1.4 常驻只注入索引

- 每个根下有一份 `INDEX.md`，由 agent 维护；它是**唯一每回合注入**的记忆内容
  （`memory-injection.schema.json`）。正文不会被自动注入。
- `INDEX.md` 硬上限 **每份 1,500 个 Unicode scalar**。写入或局部修改后超限时宿主**拒绝写入**
  并返回 `memory-index-too-long`（`limit`、`actual`），不截断、不落事件。注入阶段也从不截断。
- 注入块总量上限 4,000 scalar；包含两个索引和说明文本，说明两个根的归属/可见范围、
  三个原语，以及「可以不记」。缺失索引由宿主以空 `# Index` 文档补齐，因此注入里出现的
  路径真实存在。
- 记什么的界线只写在工具描述，不写流程：值得记的是验证过的规则、决定与承诺、偏好、策略及
  原因；能从原始记录重新读到的内容不复制，需要原文时写 `record://` 引用。

### 1.5 证据与信任推导

`UpdateMemory` 的任一 action 都可以带 `evidence`：0–8 条 [v1 §4.2](../v1/README.md#42-原始记录引用record-reference)
的规范 `record://` 引用。宿主校验每条引用存在且属于调用者这个 Bot，再按引用指向的**宿主记录
结构**推导信任。任一条无效都整条失败（`memory-evidence-invalid`），不降级、不忽略。

| 引用指向 | 推导出的信任 | 说明 |
| --- | --- | --- |
| 真实用户消息 | `user` | `user/message`，`source.kind == "user"`，且 `source.rpcId` 按 v1 §4.1 属于用户回合（`bot-`、`user-action:`、`card-answer:`；缺失按用户处理）。`held:`、`agent:`、`routine:`、`task-*` 与 `compact-checkpoint` 都不算用户消息。 |
| 观察信封或外部来源调用 | `observation` | 引用指向的 session `tool/call`／`tool/result` 的名称属于 v1 §4.3 的外部来源，或事件是可核验的观察记录；模型文本里出现信封标记不算证据。 |
| 其他记录或没有引用 | `assistant` | agent 自己的推断；包括 routine、Task、held、其他 Bot 消息、压缩摘要和普通宿主工具结果。 |

**保留值 `current-user-turn`（当前回合用户消息）。** `evidence` 的每一项可以是上面的规范
`record://` 引用，或单个保留值 `current-user-turn`。保留值只在当前回合是真实用户回合时有效：
宿主在执行点使用本回合在权威 `session/follow` 流上观察到的 `user/message` 事件（事件自身的
`source.kind == "user"`，且 `source.rpcId` 等于本回合请求 id），解析为
`record://session/<id>#<seq>`；该引用来自宿主观察，按 `user` trust 写入。显式 `record://` 引用仍走
本节的存在性、归属和 trust 推导。宿主不读取模型提供的 session/seq，也不依赖回合结束后的物化日志。隐藏回合、held 回合、`agent:` 消息、routine、Task 和
maintainer 回合都得不到保留值（`memory-evidence-invalid`）。
保留值必须逐字写成 `current-user-turn`，不做 trim、大小写折叠或别名；模型自报的 session/seq
从不被当作「本回合」的证据。解析结果绑定当前回合的 `rpcId`，下一回合的 `rpcId` 不同，旧保留值
不会指向上一回合的消息，因此跨回合不可复用。**更正用户偏好时应改写原文档，旧值不要保留在正文或
索引里**（用户明确要求保留历史时除外）。

- 每条引用必须在解析后存在，且 session 属于该 Bot 的已认领会话、event 的 principal 是该 Bot；
  任一失效都整条写入失败（`memory-evidence-invalid`），不降级、不忽略。
- 推导结果写入文档版本的 `trust`，并取代旧的「会话类型决定 trust」规则；`source` 仍记录实际回合
  来源，供审计。`evidence` 按规范化形态写入，最多 8 条。
- `user/` 写入必须**同时**满足两条边界：现有回合来源规则（`source.kind` 必须是 `user-turn`）和
  至少一条推导为 `user` 的引用；取更严的一方。来源不合格返回 `memory-source-boundary`，来源合格
  但缺 `user` 引用（或没有 `evidence`）返回 `memory-evidence-required`。`agent/` 写入不要求用户证据。
  **maintainer 例外：** `source.kind == "maintenance"` 时不套用 `user-turn` 来源检查（它不在用户
  回合里），但至少要有一条 `user` 引用，否则返回 `memory-evidence-required`；只有主 Bot 的
  maintainer 能写 `user/`，否则 `memory-scope-denied`（§4.2、§4.7）。
- 共享 `user/` 记忆的出处在其他 Bot 看来只能读到被引用的那句用户原话；本读取能力由宿主按引用
  实现，不扩大 v1 §4.4 的 `phone record` 检索范围。
- 注入文本必须说明：写记忆时优先引用来源；关于用户的持久事实用用户消息引用，观察所得注明观察，
  没有引用就按自己的推断记录。不得再声称所有聊天回合都是用户陈述。

`memory-write-request.schema.json` 的 `evidence`、`memory-document.schema.json` 的 `trust`／`source`
与 `golden/memory-write.json` 的 `evidenceCases`／`boundaryCases` 是共享向量；`validate_vectors.py`
用参考解析器逐条校验 `user`／`observation`／`assistant` 推导、引用无效时的拒绝和 source 规则的叠加。
物理抹除的共享向量在 `golden/memory-erasure.json`（§1.8）；它同时校验目标范围、版本计数、跨 Bot
隔离和不覆盖的 session 引用。

### 1.6 迁移

现有 fact 一次性、按 scope 分别渲染成文档，不丢文本：

| 旧 fact | 目标路径 |
| --- | --- |
| `tier=profile` | `<scope>/profile.md` |
| `tier=note` | `<scope>/notes/<slug(key)>.md` |
| `tier=log` | `<scope>/log/<YYYY-MM>.md`（UTC） |

- `scope` 决定根：`scope=user` 进共享 `user/`，`scope=agent` 进该 Bot 私有的 `agent/`；多 Bot
  下每个 Bot 的 agent 范围分别迁移。`slug`：小写，非 `[a-z0-9._-]` 折叠成 `-`，空则 `note`；
  同 scope 内冲突按排序追加 `-2`、`-3`。
- 每个文档正文按 fact 的 `learned_at_ms` 排序：profile 为 `# Profile` 加 `- <text>`；note 为
  `# <key>` 加 `- <text>`；log 为 `# <YYYY-MM>` 加 `- <text>`。evidence 取并集前 8 条。
- 迁移只补齐缺失文档/缺失 fact 文本，不覆盖 agent 已有编辑；生成初始 `INDEX.md` 列出该根文档
  路径，若超出 1,500 scalar 则省略后续项并留一行指向 `ReadMemory`。
- 迁移事件 ID 由目标内容和版本决定，重复运行不再写事件；新增旧 fact 再跑只补差异。向量
  `golden/memory-migration.json` 同时覆盖单 Bot、多 Bot、共享 user 去重和幂等。

### 1.7 工具目录增量

`ReadMemory` 是 phoneDSH 的 P0 增量，登记在
`spec/bot/v1/golden/tool-catalog.phone.json` 与 `tool-effects.phone.json`（`read + auto`）；
上游 `tool-catalog.json`、`tool-effects.json` 及其 schema 的 P0 enum 保持不动。`UpdateMemory`、
`RecallMemory` 的原语名不变，但参数/结果按本节替换旧 fact 形状。

### 1.8 两个删除强度：忘记与抹除（S6）

- **忘记（forget）**：`UpdateMemory{"action":"delete"}` 或记忆页的「忘记」写入
  `memory.document_deleted`，live 文档消失，历史版本和原始事件保留。
- **抹除（erase）**：只由宿主的记忆页/服务路径发起，模型工具面没有这个 action。它物理清除：
  该文档（或 `agent/`、`user/` 整个根）的 live 文档、**全部历史版本**、对应
  `memory.document_written`/`memory.document_deleted` 事件载荷、检索结果、UI 行，以及事件载荷里
  与版本文本相同或由唯一标记匹配到的副本；`redaction.applied`/观察信封等指向被清除
  `record://event/...` 的内容也一并清除。事件头、序号、id、类型和 SHA-256 摘要保留，并追加一条
  durable `erasure` 事件（v1 §4.6、[erasure-event.schema.json](../v1/erasure-event.schema.json)）。
- **范围**：单份文档只作用于该路径的全部版本；`agent/` 只作用于该 Bot（`erasure` 事件按写入者
  principal 限定，其他 Bot 的 agent 文档必须存活）；`user/` 是所有 Bot 共享的根，抹除会跨 Bot
  清除共享文档和事件副本。`user/` 与 `agent/` 的入口必须分开确认，文案写明范围。
- **会话日志**：S6 第二步起，抹除还会命中版本内容、唯一标记和 `evidence` 指向的
  `record://session/...` 行。主会话先切换到新纪元（旧会话归档、新会话从未抹除记录和记忆索引
  接续），宿主再按 P02 `wal.md` §5.3 把命中行替换成墓碑；抹除成功后
  `record://session/...` 的命中行与 `record://event/...` 一样返回 `record_erased`。仍处于活动
  回合、无法关闭的会话行留在 `erasure.uncovered_records`，reason 为
  `session-log-session-not-closed`，不得伪称已覆盖。确认文案不再声明会话日志未覆盖。
- **幂等与失败**：重复抹除不再写第二条 `erasure` 事件；单文档不存在返回 `memory-not-found`，
  scope 无文档返回 `removed=0`；路径非法返回 `memory-path-invalid`；任何失败都不能伪称已清除。
- **向量**：`golden/memory-erasure.json` 冻结单文档全版本、agent scope 隔离、共享 user 跨 Bot、
  分类计数和非法目标；`spec/bot/v2/tools/validate_vectors.py` 用参考实现校验，并做 mutation 自检。

## 2. 唤醒标记

routine、cron、run-attempt、安静时段、silent/held/interrupt、held inbox、隐藏唤醒和 `<automation_status>` 与上游一致。安静时段延后而不是丢弃；urgent 必须有理由；WebContent 不可用时常驻宿主排队，恢复后依次运行且错过的只补一次。

`HeldMessages.block` 的 `[agent]` 分支对 `fromAgentName`、`fromAgentId`、`title`、`text` 与 `msg id` 全部经 `escapedHeldField` 转义；agent-held 的回复仍是 held 数据与队友内容，不是用户授权，不能触发未经用户要求的动作。

设备任务终态另有一条只读 held 通知：`device-task-result` 只告诉 Bot 哪台设备、任务目标摘要和最终结果，不授予工具，也不提供把回复发回设备的路径。它来自 [device task-delegation](../../device/v1/task-delegation.md) 的终态记录，在 journal 落盘后、向设备回报前入队。

投递语义是 **write-before-enqueue + replay with dedupe**：宿主先把该终态写成一条 durable `comm.inbound` 事件（event id 与 held item id 都由设备 ID＋idempotency key 的 SHA-256 决定），成功入队后再写一条 `comm.reply` 确认事件。Bot 进程启动时重放没有确认事件的终态记录，重新调用 `WakeInbox.enqueue`；inbox 以 `requestId` 去重，所以“事件已写、入队前崩溃”会在下次启动补投，“已入队、确认事件前崩溃”只会生成同一 item 的 duplicate，不产生第二条。确认事件写完后，即使 held item 已被 commit 消费，也不再补投；这保持“同一终态至多交付一次给主对话”的效果，同时消除落盘与入队之间的永久丢失窗口。journal 自身仍不用于回放。`held-inbox-item.schema.json` 的该分支与 `golden/held-inbox.phone.json` 的 `deviceTaskResult` 是 phoneDSH 增量：上游 `held-inbox.json` 保持原样导出，例子放在覆盖文件，由合并加载器交付给真实 inbox codec。

### 2.1 宿主拼入文本的转义

宿主拼进 prompt 的任何非宿主文本一律按既有的 `HeldMessages.escapedHeldField` 规则转义后再放入：`\` → `\\`，换行／回车／制表 → `\n`／`\r`／`\t`，`<`／`>`／`&` → `\u003c`／`\u003e`／`\u0026`，U+2028／U+2029 和其他控制／格式字符 → `\uXXXX`。外部文本不得闭合 `</held_agent_messages>`、伪造 `- [agent]` 行或让 held 块变成多行。适用位置：

- `HeldMessages.block` 的 `[routine]` 分支：routine 名称（`title`）与正文；
- `[subagent]` 分支：task id、status 与结果正文；
- `[card-dismissed]` 分支：标题与正文；
- `[device-task]` 分支：设备／标题、task id、status 与正文；
- `[agent]` 分支：发送方名字、id、title、正文与 msg id（当前已转义，保持）；
- 子代理唤醒 prompt：`task-settled` 的标题、状态、task id 与最多 1,200 字结果摘录；`task-interrupted` 的标题与 task id；
- 以后新增的宿主结构化块／前缀默认同样转义。

普通用户消息正文和其他 Bot 的即时消息正文是消息内容，不是宿主拼进结构化框架的字段，不按本规则改写。该规则只约束宿主插入的 held 块、隐藏唤醒 prompt 和同类结构字段。回合是否隐藏、是否带 held 块、记忆写入算谁说的，仍由 [v1 §4.1](../v1/README.md#41-回合来源turn-origin) 的 `source.rpcId` 前缀决定；本目录不复制那张表。


### 2.2 routine 的设立者与放宽授权（S4b）

- 每个 routine 记录 `creator`：本修订用回合来源 `rpcId`/`turnId`/`sessionId` 加 `origin`
  （[v1 §4.1](../v1/README.md#41-回合来源turn-origin) 的七种）表达，`authorization` 为
  `user-turn` 或 `user-confirmed`，后者带审批卡 `approvalID`。S1 的 `record://` 引用已在
  [v1 §4.2](../v1/README.md#42-原始记录引用record-reference) 落地；routine `creator` 仍按上述
  字段记录，改为引用需另开变更单，不新增第二种字段。
- routine 另带 `completion_criteria` 与 `constraints`（各最多 2,000 字符，可空）。创建/更新可携带；
  空字符串表示没有记录，不伪造内容。
- `completion_criteria` 非空且本次运行以 `succeeded` 结束时，宿主按
  [v1 §2.8](../v1/README.md#28-task-交付终态与独立验证s3) 起一次只读 verifier；预算取本次 routine
  运行预算的 30%。结论写入 durable `verification.reported`，`subjectKind:"routine"`。若结论不是
  `passed`，交付文本以「验证未通过：…」或「验证不确定：…」开头并保留 verifier 的依据引用，不能把
  未验证的运行说成成功；安静运行在这种情况下不再保持 `[quiet]`。
- **放宽**指：排程比当前更频繁、`delivery` 从 `held` 改为 `interrupt`、`urgent` 从 false 改为 true、
  `resume` 一个暂停的 routine。排程频率按同一时区下接下来两次运行的平均间隔比较。
- 在**没有用户消息来源**的回合（[v1 §4.1](../v1/README.md#41-回合来源turn-origin) 的 `routine`、
  `task`、`task-wake`、`agent`、`held`、`unknown`，以及隐藏回合）里创建 routine 或放宽已有 routine，
  必须先走现有审批卡并把 `approvalID` 写入 `creator`。用户回合不需要额外确认。删除、暂停、读取、
  以及不改变频率/交付/紧急度的更新不要求确认。
- 审批卡是 durable `approval.requested`；拒绝或超时都不写 routine。审批被拒绝时的返回是
  `permission_denied`，理由明确指出需要用户确认。
- 手动取消运行中的 routine 走宿主 `RoutineScheduler` 的同一取消链（`reason:"user"`），结果是交付行里的
  `cancelOrigin:"user"`，不产生新的强制通知；`needs-reconciliation` 的人工处理见
  [v1 §5](../v1/README.md#5-行与交互) 的 Bot 信息页。

## 3. 主动提醒

主动提醒只用于 interrupt。保留的规则链只由三道硬限制和通知投递接口组成：

1. **投递对象。** 只有 `delivery == interrupt`、非 quiet、成功的 routine 结果（或失败终态）
   可以进入通知；held 结果只进 held inbox，不通知。
2. **勿扰（DND）。** `ProactiveSettings.dnd == true` 时拒绝所有候选；显式 reminder
   （`reminderId` 非空且 `allowDuringDnd == true`）是唯一例外。
3. **安静时段。** 落在 `quietStart`–`quietEnd` 的候选拒绝；显式 reminder 例外同上。routine
   调度器的安静时段延后（§2）仍在调度层生效，不因通知被拒绝而丢弃运行。
4. **频率保险丝。** 同一 Bot 在一个 `fuseWindowMs`（默认 900,000 ms）窗口内最多
   `fuseMaxWakeups`（默认 4）次 `did`/`would` 决策；达到上限后新的候选记 `fuse` 并跳过。
5. **通知投递接口。** `ProactiveDelivering` 接收 `ProactiveNotification` 并返回
   `ProactiveDeliveryResult`。`dedupeKey` 是通知的稳定标识（用于替换同一通知），不是抑制窗口；
   iOS 深链为 `phonedsh://bot/<botID>/row/<rowID>`。推送中继不在本轮，只保留
   WakeSignalSource 接口。

模式：`off` 只记 `mode-off`，不投递；`would` 记录 `would` 决策但不投递；`on` 对
`deliveryKinds` 内的类别投递，投递失败记 `delivery-failed` 且不消耗保险丝。生产 Bot 装配使用
`on`，并把 `routine-result` 接到 `RoutineScheduler` 的 interrupt 结果；`delivery == held` 的结果
仍只进 held inbox，不进入这条链。


### 3.1 预定本地通知（routine 到期）

iOS 的后台执行不是常驻能力。为了让 App 被挂起或杀掉时仍能告诉用户 routine 到期，宿主在 routine
建立或改期后把**下一次到期**登记为一条 `UNUserNotificationCenter` 本地通知；这条路径不依赖进程存活。

- **内容。** 标题固定 `例行任务到期`，正文 `「<routine title>」到点，点开运行。`，深链
  `phonedsh://bot/<botID>/routine/<routineID>` 定位 Bot 信息页的该 routine 行。它不是主动提醒，
  不消耗保险丝，也不改变 routine 的运行或 held/interrupt 交付档位。
- **标识。** 每条通知的 identifier 为 `routine-due:<botID>:<routineID>:<fireAt>`；同一 routine 改期时
  旧 identifier 取消、新 identifier 登记。`routine-notification.schema.json` 与
  `golden/routine-notification.json` 固定字段、标题、深链和边界。
- **重排。** routine 运行、暂停、删除、改期、启用/恢复或安静时段延后时，宿主取消旧登记并按新的
  `nextRunAt` 重排。App 被杀后系统保留最后一次登记；再次启动时按当前 routine 状态做一次全量对账，
  取消孤儿 identifier。
- **勿扰与安静时段。** `dnd == true` 时不登记任何 routine 到期通知。落在安静时段的非紧急 routine
  把通知 `fireAt` 延到安静时段结束；`urgent == true` 且 `urgent_reason` 非空的 routine 保持原
  `nextRunAt`。安静时段仍由调度层执行“延后而不是丢弃”。
- **上限。** iOS 每个 App 最多保留 64 条 pending 通知。宿主每个 Bot 最多登记 **60** 条 routine
  到期通知，按 `fireAt` 取最早的 60 条；超出部分只影响通知，不影响 routine 本身。多个 Bot 的总数
  超过系统上限时，由系统决定保留哪些；宿主下一次对账会重试被丢弃的登记。系统在低电量或用户关闭
  通知时可能不显示通知，这是平台行为，不能从静态检查或模拟器推断真机结果。
- **失败。** 登记失败不回滚 routine、不阻塞运行；宿主保留当前内存签名，下一次 tick 重试。被系统
  丢弃的 pending 通知在下次启动对账时重新登记。

### 3.2 在场降级梯

宿主按能力逐级降级，并把实际级别暴露给 Bot 信息页；不支持的能力不伪装成在运行：

1. **前台。** App 处于 active，全功能。
2. **后台保活。** App 不在前台，用户开启保活，且任一 Bot 有进行中的回合，或该 Bot 在一个
   **900,000 ms（15 分钟）** 保活窗口内有 enabled、未进入 needs-reconciliation 的 routine
   `nextRunAt`。命中时持有现有静音音频会话；routine 完成后窗口内仍到期时继续持有。
3. **预定通知。** App 被挂起或杀掉后不依赖进程存活，由 §3.1 的本地通知提醒 routine 到期。
   系统通知权限未授予、用户关闭通知或低电量限制时不显示，宿主只能显示实际登记成功数。
4. **系统后台任务／推送中继。** 前者由既有 BGTask 路径补跑到期 routine；后者只保留
   `WakeSignalSource` 接口，本轮不实现。

Bot 信息页的在场区显示当前级别、实际登记的通知数，以及 `quiet_defer` 中因安静时段延后的
routine（标题、原定时间、延后到时间）。没有条目时显示空状态，不伪造运行、通知或延后。

**已删除、不得重新接线的规则**（PC-20261111-bot-v2-unwired）：每日预算、分类配额、冷却、
TTL、去重窗口、模型 triage 和 idle-checkin 来源。它们没有 schema，也不再有 Swift 类型或
事件字段；重新引入需要新的 v2 变更单。

## 4. 后台整理（maintainer，S3 后半）

状态 `target`，默认关闭。这一节冻结方案 §3.4 的 maintainer：一个受限的独立后台会话，
对照原始记录整理记忆；它不替模型做分类，也不在用户回合里做。运行、检查、回滚和通知
都由宿主做；模型只负责读写记忆。

### 4.1 会话与权限

- 新增 `maintainer` session kind / principal kind。宿主像其他 Bot 会话一样签发 token 并在
  Worker 里认领（`phone/botClaimSession`），session id 固定为 `gb-maintainer-<…>`；它不是
  主对话、不是 Task、不是 routine，不能复用任何已有会话的凭证。
- maintainer preset（`phone-bot-maintainer`）用 `tools.restrict` 加 guard 限定工具：允许
  `bash`（只为 `phone record search/read`）、`UpdateMemory`、`ReadMemory`、`RecallMemory`；
  可见面 allow-list 在 `agent/created` 时装到该 maintainer Agent 自己的作用域上（不是共享
  preset 作用域），模型看到的 `tools[]` 必须恰好是这四个名字；
  不挂载出站、网页、设备工具、`SendToUser`／`SendToAgent`／`CreateTeammate`、
  `Task`／`AwaitTask`／`StopSubagent`、routine、goal 或卡片工具。guard 对每个调用再按
  bare name 检查一次，restrict 只是可见面。`bash` 实参也必须匹配
  `phone record search|read`，否则 guard 拒绝；这是“能读原始记录”的唯一 shell 能力。
- **与 verifier 共用受限会话机制。** maintainer 和 [v1 §2.8](../v1/README.md#28-task-交付终态与独立验证s3)
  的只读 verifier 使用同一份 `restricted-session` 实现：同一个 guard 函数、同一套
  `session/create` 创建头 + 返回值核对、同一组 `gb-<kind>-` 保留前缀约定、同一份
  “创建时在 Agent 自己作用域装 allow-list”的可见面逻辑，以及 volatile 上下文同一处排除逻辑。
  两者的差别只有 allow-list 与 bash 规则；不存在第二套 guard。受限会话的 `bash` 身份登记以
  已认领的 session token 作为 liveness 证据（按保留前缀解析），不依赖被 allow-list 隐藏的
  `BotVolatileContext`。
- **preset 在 `session/create` 时指定。** 会话控制器在发布 `agent/created` 之前就已经
  解析并挂载 preset，之后再 `agentPresets.select` 会被 `agent-preset/locked` 拒绝。宿主
  必须在创建 maintainer 会话时带 `agentPreset: "phone-bot-maintainer"`，并核对
  `session/create` 返回值里的 `agentPreset`；不一致时 fail-closed，不运行该批次。若传输
  丢了创建头，`agent/created` 仍按 `gb-maintainer-` 前缀选择同一 preset，并同样核对返回。
- **全局兜底 guard。** 只有一个全局 `restricted-session-guard` 行：先按不可变创建头、再按
  保留前缀解析会话，然后在执行点应用对应策略的 allow-list 与 bash 规则。它同时覆盖 verifier
  和 maintainer，覆盖“会话在升级前已创建”或“preset 解析失败但会话仍被复用”的情况；
  `tools.restrict` 只是可见面，执行边界不依赖 preset 是否成功挂载。
- **volatile 上下文。** 两种受限会话（verifier 与 maintainer）都按创建头或保留前缀在
  [v1 §2.8](../v1/README.md#28-task-交付终态与独立验证s3) 的同一处逻辑排除，不注入
  variant/persona/memory/automation。
- maintainer 的回合是 hidden turn，不进入主对话行、不向用户显示过程。它的工具调用和
  结果仍按 P25 记录 durable 事件（`principal.kind = "maintainer"`），供审计与批次检查。
- 会话只用于整理：不与另一个 maintainer 并发、不派 Task、不改 routine 或授权。

### 4.2 写入规则（与主对话相同）

- **版本前提。** 每次写入都带刚读到的 `expected_version`；对不上返回
  `memory-version-conflict`，这一份这次放弃，不重试、不整批失败，下次整理再看。
- **信任由引用推导。** maintainer 的写入 `source.kind = "maintenance"`；`trust` 仍按 §1.5
  从 `evidence` 推导。它不在用户回合里，因此 §1.3 的「回合来源必须是真实用户回合」
  对 maintainer 不适用；写 `user/` 的边界改为**至少一条引用按 §1.5 推导为 `user`**。
  没有用户引用时只能写 `agent/`。`maintenance` 只是来源，不是更高的信任等级。
- **索引上限。** 两份 `INDEX.md` 仍各 ≤ 1,500 scalar；超限的写入直接拒绝，不是截断。
- **单次改动量。** 一个批次最多改 **12 份文档**、最多写入 **24,000 scalar**（删除的文档
  计 0；同一路径多次写入按最后一个 live 版本计一次）。超过由 §4.4 的机械检查整批回滚。
- **标记矛盾（轻量入口）。** `UpdateMemory` 增加可选布尔参数
  `marked_contradiction=true`（`memory-write-request.schema.json`）。写入成功后宿主追加
  一条 durable `memory.review_requested`，data 为
  `{path, scope, version, evidence}`；写失败不记。这个标记只把路径排进候选，不改变
  本次写入的信任或内容。整理批次处理完这些路径后写 `memory.review_resolved`
  `{path, batch_id, outcome: resolved|uncertain|dropped}`；没有处理的继续留待下次。
- maintainer 写入 `user/` 只有主 Bot 的 maintainer 能做（§4.7）；非主 Bot 的 maintainer
  得到 `memory-scope-denied`。工具失败是终局：不重试、不换路径。
- `evidence` 指向已被 S6 物理抹除的事件时，`UpdateMemory` 返回 `record_erased`
  （[v1 §4.2](../v1/README.md#42-原始记录引用record-reference)），不写入、不降级 trust；
  机械检查也把该引用视为不可解析，整批回滚。

### 4.3 批次

一次运行是一个批次，批次 id 形如 `mm-<uuid 的前 32 位小写十六进制>`。

- 回合开始前写 durable `memory.maintenance_started`（`memory-maintenance-start.schema.json`）：
  批次 id、触发原因、maintainer session、候选和两条预算。
- 回合期间每次记忆写入事件把 `correlationId` 设为 `memory-maintenance:<batch_id>`；宿主
  由此按事件序号收集本批改动和写入前后的版本，不依赖模型自述。
- 回合结束后先跑 §4.4 的机械检查，再写 durable `memory.maintenance_finished`
  （`memory-maintenance.schema.json`）：状态、改动、检查结果、实际 token、本次改动量、
  失败码和是否发出 held 通知。检查不过时先把本批改动全部回滚，状态写
  `rolled_back` + 失败码；回滚本身冲突时写 `rollback_failed`，冲突路径保留在事件里。
- 用户在主对话开口时取消正在进行的回合：已提交的写入保留；宿主仍对已发生的改动跑
  §4.4 机械检查，通过则状态 `cancelled`（改动保留），不过则回滚后 `rolled_back`。
  被取消没有做完的候选留待下次，不补写“下一步”。
- 回滚使用 §1.2 的 `restore` 语义：每份文档恢复到批次开始时的 live 版本（批次开始时
  `expected_version=0` 的文档则删除），作为新版本写入，`author.kind = "ui"`，
  并写 `memory.maintenance_rolled_back`（`memory-maintenance-rollback.schema.json`）。
  批次开始后被其他写者改过的文档视为冲突：不覆盖，记 `conflicts`，状态
  `rollback_failed`；其他文档照常恢复。
- 回滚目标版本或整条路径已被 S6 物理抹除（载荷已清空）时，该路径**跳过并报告**：
  不写空内容、不复用相邻版本、不重建原文字节，记入 `conflicts`；其他路径照常恢复。
  这和其他写者冲突共用 §4.3 的 `memory.maintenance_rolled_back` 记录，但阅读正文的
  路径与 history 一样返回「不存在/已抹除」，不因回滚把原文复活。

### 4.4 宿主机械检查（不增加模型）

批次结束后宿主逐项检查；任一项不过，整批回滚，模型不参与判断：

1. **引用都能解析。** 本批每个写入版本的每一条 `evidence` 都能按 §1.5 解析、存在且属于
   这个 Bot，并按 §1.5 重新推导出与写入时一致的 trust。
2. **索引在上限内。** 检查结束时 `user/INDEX.md` 与 `agent/INDEX.md` 各自 ≤ 1,500 scalar。
   写入时的拒绝仍然生效，这一条是批次级的复核。
3. **文档不比它引用的原文长。** 对每个非删除的写入版本，如果 `evidence` 非空，正文
   Unicode scalar 数不得超过其**去重后**引用原文的 scalar 数之和；没有引用的文档不做
   这项比较（它是 agent 自己的推断）。原文按宿主记录的规范文本计：session 行取该行
   `data` 的可读文本（`data.content` 或 `data.message.content` 的文本块，其次
   `data.text`／`data.message.text`，都没有则取 `data` 的规范 JSON），event 取该事件
   `data` 的同一规则。
4. **单次改动量有上限。** 本批 live 改动路径去重后 ≤ 12，写入 scalar 之和 ≤ 24,000
   （§4.2 的定义）。

此外，宿主在运行前后各查一次预算（§4.6）：本次 token 超过单次上限的批次按
`maintenance-budget-exceeded` 整批回滚；日报消耗达到上限时不启动新批次。

### 4.5 可见、可回滚、给主对话让路

- 记忆页显示最近一次批次：状态、时间、候选数、改动路径和前后版本、检查结果、失败码，
  以及一个整批回滚按钮（见 `spec/ui/v1/pages/bot-info.md`）。被回滚的批次仍保留为历史，
  不删除事件。回滚入口只对最近一次仍可回滚的批次出现。
- 批次改变了 `user/INDEX.md`、`agent/INDEX.md` 或任一 `user/` 文档时，主对话下一回合
  开头收到**一行** held 通知：`记忆整理：<状态>，更改 N 份文档（path…）。`
  其余情况不打扰；通知文本按 v2 §2.1 的 held 字段转义规则转义。
- **给主对话让路。** 只在该 Bot 主对话空闲（没有进行中或已排队的回合）、没有
  `approval.requested` 待审批、且 App 前台时运行。主对话开始新的用户回合时取消正在
  运行的维护回合；已被取消的候选不算完成，下一次从当前状态重新评估。Task、routine
  和 verifier 的运行不阻止维护，但维护不与主对话争用同一个会话来“排队”。
- **时机（按可得性）。** ① 主对话安静下来且 App 仍存活时（回合结束后至少 60 秒没有
  新的主对话回合）；② App 下次打开且空闲时。充电时的 `processing` 后台窗口目前只登记
  为待 spike：本轮没有注册 `BGProcessingTask` 的宿主入口，WKWebView Worker 在 App 挂起
  后是否还能运行未验证，所以不声称可用，也不在后台启动维护。

### 4.6 触发、候选与预算

**触发**（任一成立；全部不成立不运行）：

- 上次批次结束后新增的 `memory.document_written` + `memory.document_deleted` 事件数
  **> 40**；
- 任一 `INDEX.md` ≥ **1,350 scalar**（硬上限 1,500 的 90%）；
- 有未处理的 `memory.review_requested`（`marked_contradiction` 留下）。

**候选由宿主给出，不全量扫。** 按以下顺序去重，最多 12 个：

| 原因 | 取法 |
| --- | --- |
| `inbox` | `agent/inbox/` 下存在的文档，每个提交会话取一条（Task/routine 的提交）。 |
| `contradiction` | 未处理的 `memory.review_requested` 指向的路径。 |
| `index` | 达到 1,350 scalar 的 `INDEX.md`。 |
| `most-read` | durable `conversation.tool_call` 里 `ReadMemory` 参数路径的调用次数最多的文档。 |
| `most-changed` | `memory.document_written` 次数最多的文档（最近一次批次之后也算）。 |
| `least-verified` | 带 evidence、但最近一次成功批次没有核验过、或最后更新时间最老的文档。 |
| `overlong` | 正文 > 4,000 scalar 的文档。 |

同一路径多个原因合并，最多保留 4 个原因。索引和 inbox 永远在候选里；候选不保证每次
都被修改。

**预算。** 单次运行 **32,000 token**、每个 UTC 自然日 **96,000 token**（输入 + 输出 +
cache read + cache write，以 LLM 账本为准）。维护回合的账本 `purpose` 是独立值
`memory-maintenance`；日报只统计这个 purpose。预算耗尽时触发条件再满足也不启动，
在记忆页显示“今日整理预算已用完”，不伪造一次运行。token 用量从 LLM 账本按
`sessionId = maintainer_session_id` 读取，不依赖模型自报。

### 4.7 多 Bot 分工

- 每个 Bot 有自己的 maintainer 会话和批次；它只整理自己的 `agent/`。
- 共享 `user/` **只由主 Bot 的 maintainer 整理**。非主 Bot 的 maintainer 候选里不出现
  `user/`，它的写入被 `memory-scope-denied` 拒绝；用户看到的批次也标出
  `user_scope_owner=false`。
- 多 Bot 同时空闲时，各 Bot 的维护互不阻塞；同一份 `user/` 仍由版本前提保证只有一个
  作者能写成功。

### 4.8 默认关闭，凭证据开启

- 设置开关默认 **关**。存储 key 为 `phone-dsh.bot.memory-maintenance.v1`，值为
  `{enabled, runTokenBudget, dailyTokenBudget}` 的 Codable JSON；缺失时
  `enabled=false`、预算取 §4.6 的值。所有 Bot 共享这一份开关。
- 开启条件写进契约，不在代码里自行放开：
  1. 评测场景「埋入一条与记录矛盾的记忆」运行后，该记忆被修正，或被标为不确定并同时
     保留两种说法和各自的引用；
  2. 既有 E01（压缩后回忆）和 E02（记忆更正）不因维护开启而退步；
  3. 每次运行的成本可从账本量化（purpose = `memory-maintenance`，单次与每日预算可见）。
- 没有满足三条证据前，生产默认保持关闭；本修订只提供 mock 自检和手动运行入口。

### 4.9 一致性向量

`memory-maintenance` golden 固化本节的批次形状、机械检查正反例、候选上限、跨 Bot
`user/` 拒绝、单次改动量上限和回滚记录。Python 校验器实现与宿主相同的检查规则；
`spec/bot/v1/tools/validate_vectors.py` 调用 v2 校验入口，因此 `phone-spec` 同时覆盖。

## 5. 一致性向量

`golden/` 覆盖 `memory-document`、`memory-write`、`memory-read`、`memory-recall`、
`memory-injection`、`memory-migration`、`memory-legacy-fact`、`memory-maintenance`、
`wake-routine`、`held-inbox` 及其合并覆盖文件；旧 fact 形状只保留为迁移输入
（`memory-legacy-fact`）。
`routine-notification` 是本目录新增的 phoneDSH-owned 向量，覆盖正常、安静时段延后、紧急绕过和
四类非法输入。
`held-inbox.phone.json` 的 `upstream` 字段仍指向 `held-inbox.json`，合并语义与
[v1 §8.1](../v1/README.md#81-上游导出与-phonejson-覆盖) 相同：对象按键合并，数组按
`name`／`id`／`nonce`／`action.nonce` 追加或替换，覆盖文件不能删除上游用例。

从仓库根运行：

```bash
python3 spec/bot/v2/tools/validate_vectors.py
```

`spec/bot/v1/tools/validate_vectors.py` 也会调用同一个 v2 校验入口，因此 `phone-spec`
阶段同时覆盖两棵树。重跑上游导出器不会再读写本目录；`--out spec/bot/v1` 的产物里
不包含上面这些文件名，manifest 也只列 v1 剩余的文件。
