<!-- SPDX-License-Identifier: MIT -->

# phoneDSH Bot v2 契约（记忆、唤醒标记、主动提醒）

状态：`target`。本目录冻结 P26 中由 phoneDSH 主导的三部分：记忆、唤醒标记和主动提醒。
静态 schema/golden 通过不等于 Swift、Worker、模型或真机已经实现。

**权威。** 从 2026-11-10 起，记忆、唤醒标记、主动提醒三部分以本目录为唯一权威，由 phoneDSH
维护，不再跟随 dsh-bot 钉版。记忆部分在 PC-20261112-bot-memory-v2 中从 fact 改为文档树；
唤醒标记和主动提醒仍是移交时的上游形状。`spec/tools/bot/export-vectors.mjs` 不再导出或
覆盖本目录的任何文件。

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

- 权威仍是 SQLite `bot_events`，不新增文件系统权威。每次写入是一条 durable 事件
  （`memory.document_written`），每次删除是一条 `memory.document_deleted`；事件携带作者
  （`principal`）、完整新版本和版本前提 `expected_version`。
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
| `delete` | — | 忘记一份文档；历史版本仍可回看，物理抹除是 S6。 |
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
  返回 `memory-scope-denied`。inbox 的合入由主对话或 S3 maintainer 负责。
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

推导结果写入文档版本的 `trust`，并保留规范化的 `evidence`。共享 `user/` 记忆的出处在其他
Bot 看来只能读到被引用的那句用户原话；本读取能力由宿主按引用实现，不扩大 v1 §4.4 的
`phone record` 检索范围。

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

## 2. 唤醒标记

routine、cron、run-attempt、安静时段、silent/held/interrupt、held inbox、隐藏唤醒和 `<automation_status>` 与上游一致。安静时段延后而不是丢弃；urgent 必须有理由；WebContent 不可用时常驻宿主排队，恢复后依次运行且错过的只补一次。

`HeldMessages.block` 的 `[agent]` 分支对 `fromAgentName`、`fromAgentId`、`title`、`text` 与 `msg id` 全部经 `escapedHeldField` 转义；agent-held 的回复仍是 held 数据与队友内容，不是用户授权，不能触发未经用户要求的动作。

设备任务终态另有一条只读 held 通知：`device-task-result` 只告诉 Bot 哪台设备、任务目标摘要和最终结果，不授予工具，也不提供把回复发回设备的路径。它来自 [device task-delegation](../../device/v1/task-delegation.md) 的终态记录，在 journal 落盘后、向设备回报前入队；投递至多一次（at-most-once）：Bot 未运行或落盘与入队之间崩溃时该通知丢失，journal 不受影响，不按 journal 补投或回放。`held-inbox-item.schema.json` 的该分支与 `golden/held-inbox.phone.json` 的 `deviceTaskResult` 是 phoneDSH 增量：上游 `held-inbox.json` 保持原样导出，例子放在覆盖文件，由合并加载器交付给真实 inbox codec。

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
`deliveryKinds` 内的类别投递，投递失败记 `delivery-failed` 且不消耗保险丝。

**已删除、不得重新接线的规则**（PC-20261111-bot-v2-unwired）：每日预算、分类配额、冷却、
TTL、去重窗口、模型 triage 和 idle-checkin 来源。它们没有 schema，也不再有 Swift 类型或
事件字段；重新引入需要新的 v2 变更单。

## 4. 一致性向量

`golden/` 覆盖 `memory-document`、`memory-write`、`memory-read`、`memory-recall`、
`memory-injection`、`memory-migration`、`memory-legacy-fact`、`wake-routine`、`held-inbox`
及其合并覆盖文件；旧 fact 形状只保留为迁移输入（`memory-legacy-fact`）。
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
