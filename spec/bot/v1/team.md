<!-- SPDX-License-Identifier: MIT -->

# Bot Team 契约（Bot v1）

Status: normative. Contracts: P25 (durable events), P26 (BotToolSurface), P27 (BotRows).
Contract revision: `bot-team-d12-v1` (`PC-20261113-bot-team-d12`). Swift is `implemented`;
Kotlin B6 is `not started` and MUST implement this document, not the D12 outline.

This document owns `SendToAgent`, `CreateTeammate`, target resolution, hop/cycle limits,
agent-comm row ids, the `agent.comm` row/event shape, held replies, and the `SendToUser`/held
boundary. `tasks.md` owns `Task`/`AwaitTask`/`StopSubagent`. `tool-catalog.phone.json` owns the
advertised names/descriptions/input schemas; `tool-effects.phone.json` owns their effect
classification. This document does not add a second tool name, event type or wire field.

The reference implementation is Swift:
`Sources/PhoneDSHBot/Team/{BotTeamTools,BotTeamHost}.swift`,
`Sources/PhoneDSHBot/Rows/BotAgentComm.swift`, `Sources/PhoneDSHBot/MCP/BotToolCatalog.swift`,
`Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift` (`SendToUser`), and the read-only App composition
`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift`. Where the D12 outline differs,
§7 records the ruling.

## 1. Roster and caller identity

- The roster is the durable `agents-index.json` (`schemaVersion: 3`) plus the repaired
  `runtime-settings.json` `mainAgentId`. `bots` keeps insertion order and includes hidden Bots;
  `visibleBots` removes `hiddenByUser`.
- The caller is never supplied by the tool arguments. It is the `botId` of the authenticated
  gateway principal (`BotGatewayPrincipal.botId`); the sender display name is the matching roster
  name, or the id when the record is missing.
- `CreateTeammate` is advertised only to the main Bot when the caller is known. An unidentified
  caller (`nil`) keeps the historical two-tool list; execution still enforces §3. `SendToAgent`
  is advertised to every Bot.
- The model-facing roster line is
  `Available bots: <name> (id: <id>[, main Bot]); …`. It excludes the caller and every
  `hiddenByUser` Bot. Hidden Bots are **not advertised**, but they remain resolvable by id or name
  (§2.2). The target-not-found list uses the same entries with `", "` as the separator.

## 2. `SendToAgent`

Input schema (catalog): required `agent_id`, `message`; optional `priority` (boolean), `delivery`
(`now|queued`), `title`, and the compatibility aliases `target_id`, `bot_name`, `agentId`, `text`.

### 2.1 Arguments and fail-closed order

The handler validates in this order; the first failure wins and writes no row/delivery:

1. `arguments` MUST be a JSON object, else `invalid_arguments`
   `SendToAgent 的参数必须是一个对象`.
2. Delivery resolution (§2.1.1). A failure is `invalid_arguments` with the exact sentence below.
3. Target reference: first non-empty trimmed string among
   `agent_id`, `target_id`, `bot_name`, `agentId`. Missing → `SendToAgent 需要提供队友。`.
4. Message: first non-empty trimmed string among `message`, `text`. Missing →
   `SendToAgent 需要提供非空的消息。` (A whitespace-only message is missing.)
5. Roster load. A host failure is `execution_failed` with `String(describing:)`.
6. Target resolution (§2.2); not found → exact target-not-found sentence (§2.2).
7. Self check (§2.2).
8. Depth (§2.3).
9. Cycle (§2.3).
10. Idempotency lookup (§2.4); a hit returns the existing thread and delivers nothing.
11. Row id/thread id allocation (§2.5), outbound row write, then `queued` or `now` delivery.

`title` is the first non-empty trimmed `title`; an absent/empty title is omitted everywhere.

#### 2.1.1 `priority` / `delivery`

`priority` accepts a boolean or the strings `"true"`/`"false"`. `delivery` accepts only `"now"` or
`"queued"`. A value that is absent, `null`, `""`, `[]` or `{}` counts as absent.

| Input | Result |
| --- | --- |
| neither `priority` nor `delivery` (or both empty) | `invalid_arguments`, exact `SendToAgent 需要 priority：true 表示立即唤醒，false 表示等对方下一个回合。` |
| `priority` present but not bool/`"true"`/`"false"` | `invalid_arguments`, `priority must be a boolean (true = wake now, false = hold for their next turn)` |
| `delivery` present but not a string or not `now|queued` | `invalid_arguments`, `delivery must be "now" or "queued"` |
| both present and consistent (`true`+`now`, `false`+`queued`) | the implied delivery, success |
| both present and inconsistent | `invalid_arguments`, `priority <literal> implies delivery "<implied>" but delivery "<given>" was also given`; `<literal>` is `true`/`false` (the JSON literal, quoted for strings) |
| only `priority` | `true` → `now`; `false` → `queued` |
| only `delivery` | that value |

`priority` is the upstream name; `delivery` is the phone-friendly spelling. They are one
fail-closed decision, never two independent switches.

### 2.2 Target resolution

Given the trimmed reference, resolve against the **full** roster in this exact order:

1. exact `id` match;
2. case-insensitive `id` match;
3. case-insensitive `name` match (first in roster insertion order).

The result is a `BotAgentRef{id,name,kind:"agent"}`. Consequences:

- A hidden Bot is reachable by its exact id or name even though it is absent from the advertised
  line and from the available list. "Hidden" is a UI/advertising property, not an authorization
  boundary.
- A duplicate name resolves to the first roster record; callers that need determinism should use
  the id. The main Bot is not special during resolution.
- If the resolved id equals the caller's `botId`, fail with `invalid_arguments`
  `SendToAgent 不能发给自己；请直接回答当前请求。` (This also catches a caller targeting its own
  name.)
- If nothing resolves, fail with `invalid_arguments`:
  `没有找到队友「<reference>」。可选的 Bot：<list>。`
  `<list>` is the model-facing entries for **visible** Bots excluding the caller, joined with
  `", "`, or `(none)` when empty. The leading Chinese corner bracket, the full-width colon and the
  trailing full stop are part of the frozen string. Hidden Bots and the caller never appear.

### 2.3 Depth and cycle

The host supplies one `BotAgentCommContext` per caller:
`depth` (inbound hops; 0 for a user turn), `chain` (Bot ids already visited by the in-progress
hand-off, including the caller), `turn`, `existingRowIDs`.

- `depth = inbound depth + 1`. Reject when `depth > 2` with `invalid_arguments`
  `转交层数已经达到上限（最多 2 层）。不要再转给别人了，请直接回答当前请求。`
  Therefore A→B is hop 1, A→B→C is hop 2 and allowed; a further C→D is rejected.
- A cycle is `target.id ∈ chain`. It is checked after depth and before idempotency. The error is
  `invalid_arguments` `转交链已经走过 <path>，<targetName> 在这条链上，不能再转回去。请直接回答当前请求。`
  `<path>` is the chain's display names (roster name, or `对方` when the record is gone) joined with
  `" → "`, followed by the target name. Internal `agent-…`/`bot-…` ids MUST NOT leak into the
  user-facing sentence.
- On success the target's new chain is the old chain with the sender appended (if absent) and the
  target appended (if absent), preserving order. A `queued` held item carries that as
  `handOff{depth,chain}`. A `now` delivery request carries the same `hop`/`chain`.
- A teammate's reply is the end of the hand-off. The reply held item MUST have `handOff = nil`;
  installing a chain on the sender would make the sender's next message look like a cycle.
- A `now` delivery installs the active context on the target only for the delivery turn; the host
  clears it when the delivery returns. A `queued` delivery installs a one-shot pending context on
  the target; the target's next `SendToAgent` call consumes it (`agentCommContext`), independently
  of whether the held text has already been folded. The context is in-memory, not durable: a
  process restart drops an unconsumed chain. A host MUST NOT persist the chain as if it were task
  state.

### 2.4 Idempotency

- `requestId = "agent:" + callId`, where `callId` is the authenticated tool call id
  (`BotMCPRequestContext.callId`, `BotTurnOrigin.agentRequestId`).
- Before allocating an id or writing anything, the host looks up
  `(botId = caller, requestId)`. If that misses, it also looks up `(botId, callId)` for pre-WP4
  rows that stored the bare sender call id. The first hit wins.
- A hit is a replay: return success with the stored `threadId`, the canonical `requestId`
  (`agent:<callId>` even for a legacy bare-id hit), no new row, no delivery, no held item, and
  `"duplicated": true`. For a replayed `queued` call the response still says
  `"delivery":"queued","status":"held"` but MUST NOT invent a `heldId` (the original call was
  already acknowledged).
- A replay whose current caller/depth/cycle would now fail still fails at the earlier check; the
  idempotency lookup is step 10, not a bypass.
- The persistent lookup is the durable outbound `agent.comm` row map maintained by the host
  (`BotAgentCommThread`); an in-memory-only map is not conformant across process restart.

### 2.5 Row and thread identity

`seq` is a per-`BotTeamTools` monotonic counter, frozen as:

```
base  = nowMilliseconds * 1_000          (overflow fallback: nowMilliseconds)
seq   = base + (counter % 1_000)
counter += 1
```

`now()` is the injected millisecond clock; production uses wall time. `counter` starts at 0 for one
composition's `BotTeamTools` instance and never resets. The counter is not a durable sequence
domain and MUST NOT be used as a `commitSeq`.

```
input    = senderID + U+0000 + targetID + U+0000 + requestId + U+0000 + decimal(seq)
rowID    = "agent-outbound-" + lowercase_hex(SHA256(UTF-8(input)))
threadID = rowID + "@" + decimal(seq) + ":agent-comm"
```

The sender-side inbound row id is `t<turn>u`, with a decimal collision suffix starting at `2`
(`t<turn>u2`, `t<turn>u3`, …) while it is present in `existingRowIDs`; `turn` is normalized to
`max(0, turn)`. Every row of one exchange shares `threadID`. The target's own row ids come from its
transcript (`t<turn>u` family); the tool never reuses the sender's row id for the target.

`team-cases.phone.json` freezes a literal SHA-256/thread for a fixed clock; a Kotlin implementation
MUST reproduce the same bytes, including the NUL separators.

### 2.6 `queued` vs `now`

**`queued`** (explicit `delivery:"queued"` / `priority:false`):

1. Write the sender `outbound` row with `status:"held"` and `hop`.
2. Enqueue one target `agent-held` item:
   - `id` = `held-<base36(createdAt)>-<8 lowercase hex>`;
   - `fromAgentId`/`fromAgentName` = sender;
   - `title` / `text` = the (trimmed) message;
   - `requestId` = the canonical `agent:<callId>`;
   - `threadId` = the exchange thread;
   - `createdAt` = `now()`;
   - `state:"pending"`;
   - `handOff = {depth: newDepth, chain: newChain}`;
   - dedupe key is `requestId`.
3. Return without opening a target turn and without waking the target.

The item shape is the v2 `held-inbox-item.schema.json` `agent-held` object
([v2 §2.4](../v2/README.md)); title is omitted when absent. A host that cannot write the item
returns `execution_failed` (`held inbox write failed: <error>`), and the outbound row remains. The
`now`/`queued` decision never falls back to the other mode.

**`now`** (explicit `delivery:"now"` / `priority:true`):

1. Write the sender `outbound` row (`delivery:"now"`, no `status`).
2. Build the prompt (§2.7) and call the host's one delivery seam with `hop`, `chain`, `threadId`,
   `requestId`, `delivery:"now"`.
3. The host opens a visible target turn when idle. When the target is busy it queues the message
   behind the current turn (never interrupts, never steers) and may wake the target after that
   turn; this is still one `now` delivery and the caller still waits for the final text.
4. Wait at most **300,000 ms** (`BotTeamTools.defaultTimeoutMilliseconds`) for the final assistant
   text. The timeout is model-visible and changing it is a contract change.
5. On success, write the sender `inbound` row from the reply and write the held reply (§2.10).
6. On a timeout, write the sender `inbound` row with `text:""`, `error:"目标 Bot 未在时限内完成回合。"`,
   and return `timeout` with that exact message. On any other delivery failure, write the inbound
   row with `error` = the host failure description and return `execution_failed`
   `发送失败：<failure>`.

The target turn itself may still finish after the caller's timeout; cancelling the wait does not
cancel the target turn. A late result is not written as a second inbound row by this call.

### 2.7 Prompt

Exactly:

```
[agent] <sender name> (id: <sender id>)[ — <title>]: <message>
```

The ` — <title>` segment is present only when `title` is non-empty. `<message>` is the trimmed
message; it is the model-visible body. The prompt is a **visible** target chat turn with the
`agent:` request id, not a hidden wake and not `SendToUser`.

### 2.8 Result

Success (no `isError`):

```json
{"ok":true,"threadId":"…","requestId":"agent:<callId>",
 "target":{"id":"…","name":"…"},"delivery":"now|queued"}
```

Optional members: `"status":"held"` only for `delivery:"queued"`; `"heldId":"held-…"` only when the
call actually enqueued (or the host reports an already-present item for the same key);
`"duplicated":true` when the thread lookup hit a replay **or** the host's held enqueue reported the
same key (the outbound row is still the idempotency authority for the normal replay path). `structuredContent` is the object above;
`content[0].text` is:

- now: `已发送给 <name>，回复稍后以 agent-comm 消息送达。`
- queued: `已扣住给 <name>：消息会在对方下一个回合开头交付，不会唤醒对方。`

Failure (always `isError:true`):

```json
{"ok":false,"error":{"code":"…","message":"…"}}
```

`content[0].text` equals `message`. Codes: `invalid_arguments` (all argument/target/self/depth/cycle
failures), `timeout` (300 s delivery timeout), `execution_failed` (roster/row/held/enqueue/host
failure), and `permission_denied` is not produced by `SendToAgent`.

### 2.9 Rows and `agent.comm`

The sender's two rows are `BotTeamAgentCommRecord` values:

| direction | role | text | peer | extra |
| --- | --- | --- | --- | --- |
| `outbound` | `assistant` | the message | `toAgent{id,name,kind:"agent"}` | `delivery`, `status:"held"` for queued, `title`, `hop`, `callID` |
| `inbound` | `user` | the reply, or `""` on failure | `fromAgent{id,name}` (`kind` optional; the team tool omits it) | `turn`, `replyEntryID` on success, `error` on failure |

Both carry `rowID`, `botID` = sender, `threadID`, `requestID`. The target-side records use the
same type: `incoming` (`role:"user"`, `fromAgent`, `message`, `hop`) and `reply`
(`role:"assistant"`, `toAgent` = the peer the reply is for, `message`). phoneDSH's current App
composition writes the sender-side rows through `agent.comm`; the target's visible turn remains a
normal transcript. If a host writes the target-side rows, it MUST use these directions and MUST NOT
invent a second row model. The frozen record/event projection is `team-cases.phone.json`
`rowCases`.

Each row becomes one durable P25 `agent.comm` event (the only event type; no second type):

- `eventId = "agent.comm:" + rowID`;
- `principal = {botId: row.botID, sessionId: nil, kind:"team", capabilities: []}`;
- `origin = local(source:"comm-service")`;
- `traceId = "agent-comm:" + threadID`; `correlationId = requestID`;
- `data` = the record's `eventData`:

```json
{"id":"<rowID>","rowID":"<rowID>","role":"user|assistant","text":"…",
 "direction":"outbound|inbound|incoming|reply","threadId":"…","requestId":"…",
 "agentComm":{"direction":"…", …},
 "fromAgent":{…}?,"toAgent":{…}?,"delivery":"…"?,"status":"…"?,"title":"…"?,
 "hop":1?,"turn":1?,"callId":"…"?,"replyEntryId":"…"?,"error":"…"?}
```

`agentComm` maps the record exactly: outbound `{targetId,targetName,message,requestId,threadId,
delivery,status?,title?,hop,callId}`; inbound `{fromAgentId,fromAgentName,replyText,requestId,
threadId,replyEntryId?,error?}`; incoming `{fromAgentId,fromAgentName,message,requestId,threadId,
hop}`; reply `{targetId,targetName,message,requestId,threadId}`. Omit nil members; never write an
explicit `null` (README §1.2). Rows written before this revision may omit `agentComm` (the existing
`event-envelope.phone.json` cases do); readers MUST accept those and fall back to the top-level
`direction`/`toAgent`/`fromAgent`/`text`/`replyText`/`threadId`/`requestId` fields. New writers
MUST include `agentComm`. `BotAgentRef.kind` is optional on `fromAgent`; an old/upstream row
may carry `kind:"agent"` (the existing `event-envelope.phone.json` case does), so a reader MUST
accept both. The team tool itself writes no `kind` on `fromAgent`.

Projection: only sender-side `outbound`/`inbound` collapse into the `agent-comm` row; the target's
`incoming` user row and `reply` assistant row stay normal bubbles. Unread rules: `outbound` bumps
the target; `inbound`/`incoming`/`reply` bump the row owner; never bump the selected Bot.

### 2.10 Held reply

After a successful `now` reply the sender receives a second `agent-held` item (not an inbound
`ui.send_to_user` and not a wake):

- `kind:"agent-held"`, `fromAgentId`/`fromAgentName` = target;
- `title` = `回复：<title>` when the original title was non-empty, else `回复`;
- `text` = the reply's first **1,200 Unicode characters** (Swift `String.prefix`, grapheme
  boundaries; the v2 schema maxLength is 1200);
- `requestId = "reply:" + requestId`; `threadId` = the exchange thread; `createdAt = now()`;
- `state:"pending"`; **no `handOff`** (a reply is not a new hop);
- it does not wake the sender; it enters the sender's next visible turn through the existing held
  block (v2 §2.4). The sender's next turn may be an ordinary user turn, a held turn, or an
  `agent:` turn; the item is not consumed by a Task wake (`tasks.md` §7).

Failure to enqueue the reply item is reported as `execution_failed`
`reply was received but the held inbox write failed: <error>` after the inbound row has been
written: the reply happened, but the sender will not see it in its next turn.

## 3. `CreateTeammate`

Input schema: required `name`; optional `description`, `color`, `hairstyle`, `section_id`.

### 3.1 Validation and result

Validated in order:

1. `arguments` object, else `CreateTeammate 的参数必须是一个对象`.
2. `name` present as a string and non-empty after whitespace/newline trimming, else
   `CreateTeammate 需要提供名字。`.
3. `name.utf16.count <= 60`; otherwise
   `CreateTeammate 的名字太长了（<count> 个字符，最多 60 个）。` The count is UTF-16 units
   (Kotlin: `String.length` on the UTF-16 string), not Unicode scalars or graphemes. The bound is
   1–60 after trimming.
4. `description`: optional string, truncated to 300 UTF-16 units on a grapheme boundary (never split
   a surrogate pair); absent becomes `""`.
5. `color` / `hairstyle`: optional enum. A non-empty value is trimmed, lowercased and matched
   exactly; empty/absent means automatic. Invalid values fail with the exact lists below.
6. Roster load; `roster.mainBotID == caller` is required. Otherwise `permission_denied`
   `CreateTeammate 只能由主 Bot 调用；当前 Bot <name>（id: <id>）不是主 Bot。`
7. Runtime path only: the turn must carry authority. A non-user turn without an approval id fails
   `permission_denied` `创建队友需要你在当前回合确认`; the runtime first raises the structural
   approval card and records the author after confirmation. A direct tool call without the runtime
   authority skips this check and passes `author:nil`.
8. Host `createBot`; failure is `execution_failed` `创建队友失败：<error>`.
9. `section_id` is accepted and ignored (not stored, not validated beyond being present).

Success:

```json
{"ok":true,"agent_id":"<created id>","name":"<created name>"}
```

`content[0].text` is
`已创建队友「<name>」（agent_id: <id>）` + (` — <description>` when non-empty) +
(`；外观：颜色=<color>、发型=<hairstyle>` / one of them / `；外观：按 Bot ID 自动组合`) + `。`.
The description stored is the truncated one that appears in the text.

Error strings:

- `CreateTeammate 需要提供名字。`
- `CreateTeammate 的名字太长了（<count> 个字符，最多 60 个）。`
- `CreateTeammate 的 color 只能是这些值之一：white、brown、red、orange、amber、green、teal、blue、purple、magenta、gray、black、silver、peach、sky`
- `CreateTeammate 的 hairstyle 只能是这些值之一：long、twin-tail、bob、side-braid`
- `CreateTeammate 只能由主 Bot 调用；当前 Bot <name>（id: <id>）不是主 Bot。`
- `创建队友需要你在当前回合确认`
- `创建队友失败：<error>`

The order of the color/hairstyle lists is the enum declaration order and is part of the string.

### 3.2 Author audit

The production host records `ui.system_event{event:"teammate.created"}` with
`{agentId,name,description,author}`; `author` is
`{rpcId,turnId,sessionId,origin,authorization,approvalID}` where `authorization` is `user-turn`
(no approvalID) or `user-confirmed` (approvalID required). The event is best-effort after the Bot
exists: a failed audit write must not roll back the Bot and must not claim the audit was recorded.
The main Bot check happens before creation; a non-main caller creates nothing.

## 4. `SendToUser` and the held boundary

`SendToUser` is the human-chat tool, not a team transport:

- Arguments: non-empty `message` after presence check (the value is **not** trimmed; a
  whitespace-only string is accepted and sent as-is). Missing/empty → `invalid_arguments`
  `主动发消息需要提供内容`.
- Only `principal.kind == chat` may call. Routine/task/verifier/maintainer callers get
  `invalid_arguments` `只有主聊天可以主动发消息`.
- A hidden turn (any `[SAND_HIDDEN_PROMPT]` task/routine wake, including
  `task-settled:`/`task-interrupted:`) and a turn already suppressed by a card or a content-card
  `final` both get `invalid_arguments` `这一回合的正文输出已被卡片收尾`. The phoneDSH verifier
  prompt's advice to "use SendToUser" from a hidden wake is therefore not executable in this
  revision; the wake must report through its hidden turn, not through `SendToUser`.
- Success writes one durable `ui.send_to_user` event and returns
  `{"ok":true,"rowId":"message-<uuid>"}`. The event data is
  `{id:"message-<uuid>",type:"text",role:"assistant",text:<message>,content:<message>}`;
  `content[0].text` is the canonical JSON of the result (no custom text).
- `SendToUser` always targets the **user**. In an `agent:` turn it is allowed (that turn is a
  visible chat turn, `hidden=false`) but the message still goes to the user, never to the peer.
- Held items are not `SendToUser`: a queued team message and a team reply are `agent-held` inbox
  items written by `SendToAgent`; `SendToUser` never writes held, and `SendToAgent` never writes
  `ui.send_to_user`. A Task settlement/interrupted wake is hidden and never consumes held items
  (`tasks.md` §7).

## 5. Catalog, unread and selection

- `BotToolCatalog.teamDefinitions(roster:callerBotID:)` appends the same available-roster line to
  both descriptions and removes `CreateTeammate` for a known non-main caller. `allDefinitions`
  is the full P0 list; `SendToAgent`/`CreateTeammate` remain in `tool-catalog.phone.json` as the
  phone-only additions.
- The per-caller catalog check runs before the handler (`tool-contracts.md` §1): a caller that
  cannot see `CreateTeammate` receives `permission_denied` without running it.
- Unread: on each row write, the recipient is the target for `outbound`, and the row owner for
  `inbound`/`incoming`/`reply`. The host increments the counter only when that Bot is not the
  selected Bot (`BotSelectionStore` / `rosterModel.selectedBotID`). Selection is host/UI state;
  a Bot tool never reads or writes it.
- The sender's `outbound` row is written before delivery; the target's held/turn work starts after
  it. A crash between the outbound row and the held item leaves a duplicate-detection row with no
  delivery; a replay returns `duplicated:true` and does not deliver. This is the accepted
  at-most-once delivery outcome; the row is the idempotency authority.

## 6. Compatibility and version

- No new wire field, endpoint, header, event type or environment variable. `agent.comm` is the
  existing additive P25 event and P27 row projection. `SendToAgent`/`CreateTeammate` are the
  existing phone-only catalog additions; their input schemas and effect classes are unchanged.
- Pre-WP4 outbound rows stored the bare `callId` as `requestId`. The compatibility lookup in §2.4
  keeps those rows deduplicating; the response still reports the canonical `agent:<callId>`
  request id. A new writer MUST write only `agent:<callId>`.
- Hidden Bots remain resolvable; removing that would be a breaking behavior change for existing
  rosters and is not this revision.
- The 300,000 ms delivery timeout, the 1,200-character held reply cap and the 60/300 UTF-16 bounds
  are model-visible contract values; changing any of them needs a new P26 revision and a new PC.
- Old persisted rows are read, not rewritten. This document adds no migration.

## 7. Freeze rulings (D12 outline vs Swift/golden)

D12 is a proposal. Per the task rule, Swift behavior plus the existing golden wins. Kotlin B6 MUST
follow these rulings:

1. **Missing priority is Chinese, not the English outline sentence.** Swift returns
   `SendToAgent 需要 priority：true 表示立即唤醒，false 表示等对方下一个回合。`; the D12 outline
   and README §1.1 quoted the upstream English sentence. The Chinese string is frozen; README is
   corrected to point here.
2. **Target-not-found is Chinese with `「」` and `", "`.** The outline's
   `agent not found: "<x>". Available bots: <list>.` never appears in Swift. The exact string is
   §2.2; the available list uses `", "` (not `"; "`) and excludes hidden/caller.
3. **Hidden Bots are reachable.** The outline says hidden Bots are not targets; Swift resolves the
   full roster (hidden included) and only hides them from the advertised list. Freeze Swift; a
   hidden target case in the vector proves it.
4. **`requestId` is `agent:<callId>`, not the bare call id.** The outline's idempotency line is
   imprecise; the bare call id is only a compatibility lookup for pre-WP4 rows.
5. **The sender's inbound row is `user`/`inbound`, and the target rows are `incoming`/`reply`.**
   The outline groups them loosely; the four-direction record is the frozen shape.
6. **A teammate reply does not install a chain.** The reply held item has no `handOff`; only a new
   outbound hop installs/extends the chain. Otherwise every round trip would become a false cycle.
7. **`CreateTeammate` bounds are UTF-16 units.** `name.utf16.count <= 60`; description is
   truncated to 300 UTF-16 units on a grapheme boundary. Kotlin's UTF-16 `String.length` matches;
   a Unicode-scalar count does not.
8. **No held-full error exists in Swift.** The outline lists `held-full`; the v2 held inbox has no
   capacity error. A host enqueue failure is `execution_failed` with the exact strings in §2.6/
   §2.10. Do not invent a new code.
9. **The 300 s timeout is the delivery wait, not a target-turn cancel.** A timed-out caller writes
   the inbound error row and returns `timeout`; the target turn may finish later. Late text is not
   appended by that call.
10. **`SendToUser` in a hidden wake is refused.** The hidden `task-settled`/`task-interrupted`
    prompt is not a visible chat turn. The verifier instruction's `SendToUser` advice is not
    executable; this is recorded as a remaining owner decision in the PC, not silently relaxed.

## 8. Shared fixtures

`golden/team-cases.phone.json` (phone-only; `upstream: []`):

- `contract`: the values/strings above, checked for exact equality by the Python validator.
- `valid` / `invalid`: 13/20 `SendToAgent` and `CreateTeammate` cases, including exact error
  strings, target resolution, hidden/self, depth 2/3, cycle, duplicate call id, pre-WP4 bare id,
  held reply cap, timeout and enqueue failures.
- `rowCases`: one exact `BotTeamAgentCommRecord` + `eventData` for each direction.
- `sendToUserCases`: visible chat, agent turn, task principal, hidden wake, card suppression and
  empty message.

`Tests/PhoneDSHBotTests/Team/BotTeamCasesTests.swift` reads the file and drives the real
`BotTeamTools`/`BotAgentCommIdentity`/`BotTeamAgentCommRecord`; it does not restate a vector.
`tools/validate_vectors.py` checks shape, exact contract values, row hashes, held items against the
v2 `held-inbox-item.schema.json`, and nine mutations. `export-manifest.json` records the digest.
