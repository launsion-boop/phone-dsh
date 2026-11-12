<!-- SPDX-License-Identifier: MIT -->

# Bot P0 tool contracts (Bot v1)

Status: normative for the P0 tool surface of the `phone` MCP endpoint. Contracts: P26
(BotToolSurface), P25 (durable events). Contract revision: `bot-mcp-d13-v1`
(PC-20261113-bot-mcp-d13).

This document owns the per-tool argument and result semantics that `mcp-endpoint.md` §7 does not.
`tool-catalog.json` and `tool-catalog.phone.json` own the advertised names, descriptions and input
schemas; this document MUST NOT re-type a description. Card payload rules live in
[cards.md](cards.md). Memory semantics (scopes, trust, evidence, versions) live in
[README §1.2 and v2 §1](../v2/README.md); this document only freezes the MCP argument and result
shapes.

## 1. Common result contract

- Every P0 tool except `BotVolatileContext` is in `BotToolCatalog.p0Names` and is registered by
  `BotToolCatalog.isRegistered` (`BotToolCatalog.swift:6-10`, `:236-238`). P1 card tools are not
  registered and return `unknown_tool` (§8).
- A call is attributed to a principal by the registration created on `tools/pre-execute`
  (`mcp-endpoint.md` §9). No registration, an expired one, another tool/session/generation or a
  non-current incarnation is `unattributed`.
- The per-caller catalog check runs before any effect (`mcp-endpoint.md` §2, §9): a tool hidden
  from `toolDefinitions(callerBotID:)` fails with `permission_denied` and the handler does not run.
- Success and failure are `BotMCPCallResult` values (`mcp-endpoint.md` §7.4). A failure always has
  `isError:true` and `structuredContent = {"ok":false,"error":{"code","message"}}`. The code map
  from a thrown `BotMCPError` is fixed (`BotMCPRuntime.swift:2073-2094`):
  `invalidRequest -> invalid_arguments`, `unknownTool -> unknown_tool`,
  `unauthorized -> unauthorized`, `unattributed -> unattributed`,
  `crossSessionDenied -> cross_session_read_denied`, `timeout -> timeout`,
  `unavailable -> unavailable`. Any other thrown error is `execution_failed` with
  `String(describing:)`; `BotCardPayloadError` is `invalid_arguments` with its exact message
  (`BotMCPRuntime.swift:1327-1336`).
- `inputSchema` is advertised metadata, **not** a generic validator. The runtime does not execute a
  JSON Schema engine: each handler validates the members it uses and ignores unknown members unless
  its own clause says otherwise. A Kotlin port MUST implement the handler rules below, not just the
  advertised schema. This is the frozen Swift behavior; the shared `tool-call-cases.phone.json`
  proves it for every tool.
- The default `content[0].text` is the canonical JSON of `structuredContent`; the per-tool
  exceptions are listed below (`BotMCPTypes.swift:39-50`).

## 2. Card tools (`ask_user`, `show_next_steps`, `show_attachment`, `show_document`, `show_progress`, `show_checklist`, `show_link`)

- **Arguments and result.** Exactly the rules in [cards.md](cards.md). The materialized result is
  `{"ok":true,"card":<card>}` with `isError` absent. The durable event is `card.presented` with
  `card`, host `id` (`card-<uuid>`), `tool` and `callId` added
  (`BotMCPRuntime.swift:1368-1396`).
- **Text and turn effect.** `ask_user` returns the fixed sentence
  `已显示提问卡；回合应在此结束，等待用户选择。`; `show_next_steps` returns
  `已显示建议下一步卡片；回合应在此结束，等待用户选择。`. Both suppress later assistant text and
  `SendToUser` for the rest of the turn. A successful content card with `final:true` does the same.
  The suppression is per session until the next `beginTurn`
  (`BotMCPRuntime.swift:1370-1395`, `:682-688`).
- **Failures.** Every `BotCardPayloadError` becomes `invalid_arguments` with the message from
  cards.md §8; no `card.presented` event is written. Unknown/P1 names never reach the builder and
  are `unknown_tool`.
- **P1.** `show_table`, `show_callout`, `show_info`, `show_payload`, `show_library` are `target`;
  they are not advertised, not registered and MUST NOT be called.

## 3. Memory tools

### 3.1 `UpdateMemory`

- **Arguments.** Required: `action` ∈ `write|append|replace|move|delete|restore`, `path`,
  `expected_version` (integer ≥ 0; 0 means the document must not exist). Conditional:
  `content` for `write`/`append`; `find` + `replace` for `replace`; `to` for `move`;
  `restore_version` (integer ≥ 1) for `restore`. Optional: `evidence` (array of at most 8 strings)
  and `marked_contradiction` (boolean). Additional members are ignored.
- **Validation failures** are `invalid_arguments` with the stable sentences:
  `更新记忆需要指定动作：write、append、replace、move、delete 或 restore`,
  `更新记忆需要提供路径`, `更新记忆需要提供不小于 0 的版本号`,
  `更新记忆的 <action> 动作需要提供内容`, `更新记忆的替换动作需要提供要查找的原文`,
  `更新记忆的替换动作需要提供替换后的内容`, `更新记忆的移动动作需要提供目标路径`,
  `恢复记忆需要提供不小于 1 的版本号`. A malformed/foreign record reference is
  `memory-evidence-invalid`; an erased record is `record_erased`; a verifier principal is
  `permission_denied` (`BotMCPRuntime.swift:1425-1560`).
- **Result.** A successful call returns
  `{"ok":true,"action","path","scope"?,"version"?,"previous_version"?,"replaced"?}`. A memory
  business refusal is still a successful tool call (`isError` absent) with
  `{"ok":false,"code","error",...}` where `code` is one of `memory-path-invalid`,
  `memory-version-conflict`, `memory-not-found`, `memory-path-exists`,
  `memory-replace-not-found`, `memory-version-not-found`, `memory-index-too-long`,
  `memory-source-boundary`, `memory-evidence-required`, `memory-scope-denied`. `scope` is `user`
  or `agent`. A version conflict also carries `current_version`; an index overflow carries
  `limit` and `actual` (`BotMemory.swift:220-360`; `BotMCPRuntime.swift:1540-1590`).
- **Trust.** The source/trust/evidence rules are D10's and are not redefined here. The reserved
  evidence item `current-user-turn` resolves only on a real user turn observed by the host; a
  hidden, held, agent, routine, Task or maintainer turn fails closed. `marked_contradiction:true`
  on a successful write appends `memory.review_requested` keyed by bot+path+version
  (`BotMCPRuntime.swift:1560-1600`, `:1660-1700`).

### 3.2 `ReadMemory`

- **Arguments.** Required non-empty `path`; optional `version` (integer ≥ 1). No other member is
  used.
- **Result.** `{"ok":true,"kind":"document","path","scope","version","content","updated_at_ms","author","evidence"}`,
  plus `trust`, `deleted`, `deletion_reason` when present; or
  `{"ok":true,"kind":"directory","path","scope","entries":[{"path","name","kind","version"?,"updated_at_ms"?}]}`;
  or `{"ok":false,"code","error"}` for a memory-level refusal. Missing path is `invalid_arguments`
  (`BotMCPRuntime.swift:1612-1664`).
- **Bound.** `version` selects a historical version; `0`, negative or non-integer is
  `invalid_arguments`. The document store is the version authority.

### 3.3 `RecallMemory`

- **Arguments.** Optional `query` (string, default `""`), `limit` (integer 1–50, default 40),
  `scope` ∈ `agent|user|all` (default `all`). A limit outside the range is `invalid_arguments`;
  a bad scope is `invalid_arguments` with `invalid memory scope`; a non-string query is treated as
  absent.
- **Result.** `{"ok":true,"hits":[<BotMemoryRecallHit>],"count","total","truncated"}`. Each hit
  carries `path`, `scope`, `snippet`, `score`, `relevance`, `recency`, `matched`, `updated_at_ms`,
  `version`, `evidence`. `truncated` is `total > count` (`BotMCPRuntime.swift:1666-1699`;
  `BotMemoryRecall.swift:5-37`).
- **Failure.** A store read failure is `memory_unavailable` with
  `记忆暂时读不出来，请稍后重试。` and never a hung turn.

## 4. Task tools

The durable lifecycle, `persistedTask` snapshot, restore and wake rules are owned by
[tasks.md](tasks.md). This section only freezes the tool arguments/results; where the two differ,
`tasks.md` and its shared fixture win.

### 4.1 `Task`

- **Arguments.** Optional `description`/`task_title` (title; default `委派的任务`) and
  `prompt`/`task_description` (one is required). Optional `async` (boolean, default false),
  `timeout_ms` (integer 1,000–300,000, default 180,000), `completion` (≤ 4,000 characters),
  `purpose` (≤ 2,000), `constraints` (≤ 8 non-empty strings, each ≤ 500 characters),
  `allowed_write_directories` (≤ 32 strings), and `budget` (object with only
  `max_duration_ms`, integer 1,000–300,000).
- **Accepted but unused in this revision:** `subagent_type`, `model`, `model_override`,
  `max_mode_override`, `default_expanded_while_running`, `agent_id`, `attachments`, `mode`,
  `responding_to_message_ids`, `environment`, `machine`. They are accepted as-is; the executor may
  read them, but this runtime does not validate them. `task_id` and `resume` are refused with
  `暂不支持从历史任务继续`.
- **Principal rules.** Only a `chat` or `task` principal may call. A `task` principal additionally
  needs the `task.delegate` capability; without it the result is `permission_denied` with
  `当前任务会话里不能再派发任务`. Other kinds are `invalid_arguments` with
  `只有聊天或任务会话可以派发任务`.
- **Result.** The task record (§4.4) plus `authorization`:
  `{"workspaceRoot","allowedWriteDirectories","canWriteOutsideWorkspace","canNetworkWrite","canDelegateTasks"}`
  (`BotMCPRuntime.swift:69-102`, `:1701-1805`). `task.created` is persisted by the production
  executor before work starts; the runtime appends `task.started` and, for an already terminal
  record, `task.settled` with `eventId:"settled:<taskId>"` (`BotMCPRuntime.swift:1775-1800`).
- **Validation errors** are `invalid_arguments` with the exact sentences in the handler:
  `派发任务需要说明要做什么`, `任务超时必须在 1000 到 300000 毫秒之间`,
  `任务的完成条件最多 4000 个字符`, `任务的用途说明最多 2000 个字符`,
  `任务约束最多 8 条，每条最多 500 个字符`, `任务预算只接受 max_duration_ms`,
  `任务预算的 max_duration_ms 必须在 1000 到 300000 毫秒之间`,
  `allowed_write_directories accepts at most 32 entries`.

### 4.2 `AwaitTask`

- **Arguments.** Required non-empty `task_id`; optional `timeout_ms` (integer 1,000–600,000,
  default 180,000). A timeout leaves the task running and returns the current record. Missing id is
  `invalid_arguments` with `等待任务需要提供任务编号`; an out-of-range timeout is
  `等待任务的超时必须在 1000 到 600000 毫秒之间`.
- **Result.** The task record; when the executor exposes `BotTaskAuthorizing`, `authorization` is
  added. A terminal record appends `task.settled` with the same deterministic event id
  (`BotMCPRuntime.swift:1806-1827`).
- **Ownership.** The executor resolves the task by the parent call; a task that belongs to another
  Bot or session fails in the executor, not by silently returning another record.

### 4.3 `StopSubagent`

- **Arguments.** Required `task_id`, or its alias `id`; both empty/missing is `invalid_arguments`
  with `停止任务需要提供任务编号`. The adapter passes the parent call; a task from another Bot is
  refused by the executor.
- **Result.** The stopped record (status `stopped`, partial retained). The runtime appends
  `task.stop_requested` with a generated event id and `task.settled` with
  `eventId:"settled:<taskId>"` (`BotMCPRuntime.swift:1829-1845`; the generated id is frozen in
  [tasks.md](tasks.md) §4).
- **Late results.** A result that arrives after the stop is dropped; the settled record is
  authoritative (`mcp-endpoint.md` §4; `BotDSHRemoteRuntime`).

### 4.4 Task record

`{"task_id","sessionId","status","title","result"?,"partial"?,"error"?,"completion"?,"purpose"?,"constraints"?,"budget"?,"verification"?}`
(`BotMCPTypes.swift:170-220`). `status` is one of `running|stopping|waiting_approval|completed|
failed|stopped|interrupted|denied`; there is no `cancelled` task status (a stop writes `stopped`).
`interrupted` is the replacement-Worker state with `error:"worker_restarted"`
(`mcp-endpoint.md` §4); `waiting_approval` is terminal for reads but survives a restart
([tasks.md](tasks.md) §1/§9). `budget` is `{"max_duration_ms"?}`; `verification` is the P26
verifier output. The mobile runtime MUST NOT invent a second field name or a second status
spelling for an existing member.

## 5. Routine tools

### 5.1 `UpdateRoutine`

- **Arguments.** Required `action` ∈ `create|update|delete|list|get|pause|resume`. `create`
  requires `title`, `prompt` and `schedule`; `update` requires `routine_id` and a non-empty patch;
  `delete`/`get`/`pause`/`resume` require `routine_id`. Optional: `enabled` (boolean), `urgent`
  (boolean), `urgent_reason`, `delivery` ∈ `held|interrupt`, `interrupt_reason`, `timezone`-bearing
  schedule forms below, `completion_criteria`, `constraints`.
- **Schedule forms.** A string (`@every 60m`, cron with optional `CRON_TZ=<zone>`, daily/weekly
  forms as parsed by `BotRoutineTool.schedule`) or an object
  `{"kind":"interval|daily|weekly|cron","everyMinutes","time","weekdays","expr","timezone"}` with
  `kind` required. An invalid schedule is `invalid_arguments` with `invalid routine schedule`
  (`BotRoutineTool.swift:91-156`).
- **Confirmation.** `RoutineAuthority.assess` marks `create`, a loosening `update`, and resuming a
  paused routine as requiring confirmation. On a non-user turn the runtime raises a structural
  approval card (durable for task/routine principals, interactive otherwise) with
  `alwaysScope:"none"`. On a user turn no card is raised. A denied/pending card returns
  `permission_denied` with `审批还在等待用户确认；任务已经停下，用户决定后会继续` or the coordinator
  message; the routine is not changed (`BotMCPRuntime.swift:1847-1885`;
  `RoutineAuthority.swift:115-178`).
- **Result.** The encoded routine (or `{"routines":[...],"count":<n>}` for `list`). The routine
  shape is the v2 `routine` schema; `created_at` is a millisecond timestamp. `create` appends
  `routine.defined`, `delete` `routine.deleted`, other mutations `routine.updated`; `get`/`list`
  append no event (`BotMCPRuntime.swift:1870-1886`; `BotRoutineTool.swift:6-68`).
- **Errors.** Missing action is `invalid_arguments` with `UpdateRoutine requires action`; missing
  required fields use `<field> is required`; an unknown action is
  `unsupported UpdateRoutine action: <action>`. A `RoutineError` (for example
  `routineNotFound`) is a generic error and surfaces as `execution_failed`, not
  `invalid_arguments` (`BotMCPRuntime.swift:1327-1336`).

### 5.2 `ListRoutines`

- **Arguments.** None. The advertised schema closes the object; the runtime ignores any supplied
  members and never validates them, so an unknown member does not fail. A non-object `arguments`
  is still caught by the JSON-RPC layer (`-32602`) before dispatch.
- **Result.** `{"routines":[<routine>...],"count":<n>}` for the caller Bot only; read-only, no
  event (`BotRoutineTool.swift:64-67`). A caller without a catalog entry is `permission_denied`;
  no registration is `unattributed`.

## 6. `RequestApproval`

- **Arguments.** Required non-empty string `action`; optional `detail` and `command` (a non-string
  `detail`/`command` is treated as absent, a non-string `action` is refused). Missing action is
  `invalid_arguments` with `请求审批需要说明要申请什么`
  (`BotMCPRuntime.swift:1887-1925`).
- **Effects.** A non-empty `command` is classified by the same frozen destructive-command analyzer
  as `bash`; the tool then always adds one unknown effect
  `{"tool":"RequestApproval","operation":"approval.weak-action","mutability":"destructive","policy":"ask","known":false}`.
  `alwaysScope` is `until` when any effect is known, otherwise `session`. Standing grants are
  checked first; a matching grant returns immediately without a card.
- **Result.** `{"allowed","decision":"allowed"|"denied","approvalId"|null,"message"|null,"pending","expiresAt"?,"approvalDecision"?,"scope"?}`.
  `approvalDecision` is `allowOnce|always|deny` and `scope` is `once|session|until` when the user
  decided; both are omitted for pending/auto outcomes. The model-facing text is one plain Chinese
  sentence followed by `\n` and the canonical JSON of the result
  (`BotMCPRuntime.swift:1887-1953`).
- **Persistence.** A task/routine principal gets a durable `pending:true` todo; a chat principal
  waits up to the 300 s approval timeout. The tool does not execute the requested action; it only
  records the decision (`BotApprovalCoordinator.swift:289-389`).

## 7. `SendToUser`

- **Arguments.** Required non-empty `message`; non-string is absent. No other member is used.
- **Principal rules.** Only `kind == chat`; a hidden turn or a turn already suppressing text
  (ask_user/show_next_steps/final content card) is refused. These are `invalid_arguments` with
  `只有主聊天可以主动发消息`, `这一回合的正文输出已被卡片收尾`, or
  `主动发消息需要提供内容` (`BotMCPRuntime.swift:1955-1985`).
- **Result.** `{"ok":true,"rowId":"message-<uuid>"}`; the runtime appends `ui.send_to_user` with
  `id`, `type:"text"`, `role:"assistant"`, `text` and `content`. The row projection owns display.

## 8. `BotVolatileContext`

### 8.1 Request and response

- **Arguments.** Exactly one member: `sessionId`, a string of 1–200 Unicode scalars. Any other
  member, a missing member or an empty/oversized value is `invalid_arguments`
  (`BotVolatileContext.swift:17-23`).
- **Scope.** `sessionId` MUST equal the attributed principal's `sessionId`; a mismatch is
  `cross_session_read_denied`. The tool can never read another session's snapshot
  (`BotVolatileContext.swift:24`).
- **Result.** `{"schemaVersion":1,"sessionId":<same>,"revision":<n>,"blocks":{"variant"?,"persona"?,"memory"?,"automation"?}}`.
  Blocks are omitted when empty; an empty provider yields `blocks:{}`. `revision` starts at 1 and
  increases by one per successful or attempted snapshot on that producer instance
  (`BotVolatileContext.swift:25-31`; `BotMCPTypes.swift:118-150`). Schema:
  [volatile-context.schema.json](volatile-context.schema.json).
- **Failure.** A provider timeout is `timeout`; a block over its cap, a total over the cap, or
  credential-shaped content is `unavailable` with the specific message. There is **no stale or
  partial snapshot**: a failed provider call returns a tool failure and never reuses the previous
  revision. The only empty snapshot is a provider that deliberately returned empty blocks
  (`BotVolatileContext.swift:34-66`; `EmptyBotVolatileContextProvider`). D13's “empty snapshot on
  failure” is superseded by this frozen behavior.

### 8.2 Caps and content rules

- Caps are Unicode scalars, counted per block and summed: `variant` 12,000, `persona` 12,000,
  `memory` 4,000, `automation` 4,000, total 24,000. Whitespace-only blocks are treated as absent by
  the domain provider (`BotVolatileContext.swift:53-66`; `BotDomainVolatileContextProvider.swift:
  106-147`).
- The producer rejects credential-shaped content before returning it: `Bearer <token>`, `sk-…`,
  PEM private keys, `api_key`/`access_token`/`auth_token`/`secret`/`password` assignments, and
  GitHub token prefixes. This is a defense-in-depth check, not a licence to put secrets in
  memory (`BotVolatileContext.swift:68-78`).
- Default provider timeout is 5 s (`BotVolatileContext.swift:6`).

### 8.3 Assembly (App provider)

- `variant`: the default empty string for a chat session; the fixed task variant text for
  `kind == task`; the fixed routine variant text for `kind == routine`. Custom variant closures may
  replace it. A block that trims to empty is omitted
  (`BotDomainVolatileContextProvider.swift:68-104`, `:106-110`).
- `persona`: the default string is exactly `你的名字是大肥鱼。用户问起名字时如实回答。`. A custom
  persona is used verbatim after trimming. When the Bot has a description, the trimmed description
  is appended after two newlines and truncated to 300 Unicode scalars; an empty description adds
  nothing (`BotDomainVolatileContextProvider.swift:150-160`, `:38-41`).
- `memory`: `BotMemory.promptBlock(language:)` for the same Bot, trimmed; omitted when empty. The
  document store, scopes and index caps are D10's.
- `automation`: `AutomationStatus.block(routines:now:lang:)` for the same Bot. A routine read
  failure uses `AutomationStatus.unreadable`, never a silent “no routines”
  (`BotDomainVolatileContextProvider.swift:122-135`; `RoutineWake.swift:116-147`).
- `teammates`: appended to `automation` after a blank line, never emitted as a fifth block. The
  rendered sub-block is `<teammates>\n- <name>（id: <id>[, 主 Bot]）[：<description>]\n…</teammates>`
  in Chinese (the English punctuation is used when `language == "en"`). The caller is excluded,
  as are entries with an empty id. Fields are XML-escaped (`&`, `<`, `>`) and whitespace-collapsed;
  name ≤ 60, id ≤ 120, description ≤ 200 scalars. The sub-block is at most 999 scalars and its cap
  is further reduced to `3,900 - len(automation_status)`; lines that do not fit are dropped whole.
  The automation block, including teammates, must stay within its 4,000-scalar cap
  (`BotDomainVolatileContextProvider.swift:25-31`, `:163-204`).
- `sessionId`, `schemaVersion` and `revision` are owned by the producer, not by the domain
  provider. The domain provider never sees a client-supplied Bot id.

## 9. Non-P0 names and native/team tools

- `SendToAgent`, `CreateTeammate` and `FishAction` are registered outside `p0Names`. Their names,
  descriptions and effects are frozen by `tool-catalog.phone.json` and `tool-effects.phone.json`;
  their execution stays in the team/fish handlers. `CreateTeammate` is advertised only to the main
  Bot and its non-user-turn confirmation is an additional check
  (`BotToolCatalog.swift:17-24`, `:145-235`).
- A name that is not a Bot/team tool is forwarded to native (§7.6) and never appears in this
  document. A native tool keeps its own arguments, result and authorization.
- `BotVolatileContext` is a Bot tool even though it is not in the upstream P0 catalog; it is
  advertised by `BotToolCatalog.allDefinitions` and is covered by §8.
