# P27 Bot main-session lifecycle against DSH Remote

Status: **normative**, phone-owned (`P27`, delta `D11`, checkpoint `B7a`), frozen by
`PC-20261112-android-bot-w4`. This file is not an upstream `dsh-bot` export and is not covered by
`spec/bot/v1/dshbot-pin.json`.

Implementation of record: `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`,
`Sources/PhoneDSHBot/Gateway/BotTokenRegistry.swift`,
`Sources/PhoneDSHBot/Gateway/BotGateway.swift`, `Sources/PhoneDSHBot/Attachments/BotWorkspaceLayout.swift`.
The Swift code is the reference implementation, not the definition: a second host (Android) implements
this file and passes `spec/bot/v1/golden/session-lifecycle.phone.json`. Line references below are to
the phoneDSH tree at the freeze base `e477497b`.

The words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Scope

This contract freezes the Bot **main chat session** against the DSH Remote surface, i.e. the state
machine that decides:

1. which DSH session id a Bot talks to, and the directory it is created in;
2. which `session/create` / `session/page` / `session/list` / `workspace/*` calls are made, in which
   order, with which arguments, and what is a success;
3. the durable `runtime.started` / `runtime.exited` events that make an epoch switch recoverable;
4. the `session/prompt` / `session/cancel` calls of one turn and the `session/follow` live-frame
   stream that feeds the Bot page;
5. the `phone/botClaimSession` ownership claim and the host token registry that proves it.

It does **not** define the DSH Remote transport itself (P14), the Bot event envelope (P25), row
projection (`projection.md`, P27), card answers/approvals (P27, P26), Tasks (`MCP/BotDSHRemoteRuntime`
task section) or routine scheduling (P26). Where those contracts own a term, this file uses it.

Everything here is **phone-owned P27 delta**. An upstream `dsh-bot` consumer that does not implement
this file is not a P27 main-session implementation; it may not claim row parity with the phone.

## 2. Session ids and the Bot root

### 2.1 Safe path component

`BotWorkspaceLayout.safePathComponent(_:)` (`Attachments/BotWorkspaceLayout.swift:35-49`) is
normative. Given a Bot id `raw`:

1. Walk `raw.unicodeScalars` in order.
2. Keep a scalar when it belongs to Unicode General Category `L*`, `M*` or `N*`
   (`CharacterSet.alphanumerics` is the union of letters, combining marks and
   numbers) or is one of `.`, `_`, `-`; emit it unchanged.
3. Replace every other scalar with `_` (U+005F). One output scalar per input scalar.
4. If the result is empty, or is exactly `.`, or is exactly `..`, the result is `bot`.
5. Truncate to at most **64** characters (`String.prefix(64)` counts extended grapheme clusters).
   Because combining marks are kept, this is **not** necessarily 64 Unicode scalars: 64 decomposed
   `e` + combining-acute pairs are 64 characters and 128 scalars, and survive intact.

Consequences a second host must reproduce exactly:

- No trimming, no case folding, no Unicode normalization. Both a precomposed `é` and the decomposed
  `e` + combining acute survive unchanged (the combining mark is category `Mn`, which
  `CharacterSet.alphanumerics` includes).
- `/`, `\`, `:`, whitespace and every non-alphanumeric scalar become `_`; they are never dropped.
- The fallback applies **before** truncation, so a 65-character id truncates but an empty id becomes
  `bot`.
- The same Bot id always maps to exactly one root; the root is stable across launches.

### 2.2 Bot root

`botRoot` (`:26-33`) is:

```
<dataDirectory with trailing "/" collapsed>/agents/<safePathComponent(botId)>
```

`dataDirectory` defaults to `/dsh/workspace/.dshbot` (`:23`). Trailing `/` is collapsed while
`value.count > 1`, i.e. `/` stays `/` and `/a///` becomes `/a`. The production App passes its own
`BotSessionRegistry.botDataDirectory`, which must equal the default (documented in
`PC-20261109-bot-root`).

For `botId = "main"` the default root is `/dsh/workspace/.dshbot/agents/main`.

### 2.3 Minting

`mintedSessionID(kind:)` (`BotDSHRemoteRuntime.swift:1923-1926`):

| kind | minted id |
| --- | --- |
| `chat` | `gb-<safePathComponent(botId)>` |
| every other `BotSessionKind` (`task`, `routine`, `verifier`, `team`, `proactive`, `watchdog`, `maintainer`) | `gb-<kind.rawValue>-<lowercase UUID v4 with dashes>` |

A rebuild always mints `gb-<safePathComponent(botId)>-<lowercase UUID with dashes>`
(`:1826-1828`), for the chat kind as well.

The minted id is a **request**. The effective session id of a create is the `sessionId` returned by
`session/create` (`:1900-1902`); a Worker MAY return a different id, and the host must then use the
returned value for `session/page`, `session/prompt`, claims and events. An empty or missing returned
id fails closed with `unavailable("session/create returned no sessionId")`.

## 3. `session/create`

`createSession` (`:1892-1918`) sends exactly one unary call:

```json
{
  "request": {
    "cwd": "<botRoot>",
    "sessionId": "<minted or requested id>",
    "agentPreset": "<preset>"
  }
}
```

Member order is not significant. The fields are normative; a host MUST NOT send a fourth member for
this contract. `agentPreset` comes from `requestedPreset(for:)` (`:1884-1890`):

| kind | `agentPreset` |
| --- | --- |
| `chat`, `task`, `routine`, `team`, `proactive`, `watchdog` | `phone-bot` |
| `verifier` | `pdsh-verifier` |
| `maintainer` | `phone-bot-maintainer` |

The response MUST carry a non-empty `sessionId`. It MUST also carry `agentPreset`; when it is absent
the host fails closed with
`unavailable("session/create did not report its composed agent preset (expected <preset> for <kind>); refusing to run the Bot turn")`,
and when it differs from the requested preset the host fails closed with
`unavailable("Bot <kind> session composed preset <composed> instead of <preset>; refusing to run the Bot turn")`
(`:1903-1915`). In both failure cases **no** `phone/botClaimSession` and no `session/prompt` is sent
for that session. The response `agentPreset` is the Worker's composed identity, not an echo the host
may ignore.

`session/create` is the only place the Bot root is established. A host MUST NOT create the directory
itself or widen `cwd` to the DSH workspace root.

## 4. Durable lifecycle events

### 4.1 `runtime.started`

`recordRuntimeStarted` (`:1730-1739`) appends one durable BotEvent:

```json
{
  "type": "runtime.started",
  "principal": {"botId": "<botId>", "sessionId": "<sessionId>", "kind": "chat", ...},
  "data": {"sessionId": "<sessionId>", "botId": "<botId>", "cwd": "<botRoot>"}
}
```

Exactly those three `data` members. `cwd` is always the current Bot root, never a stored value.
`principal.kind` is `chat` for the main session; the event is written for the chat epoch switch and
for the recovery refresh, not for Task/routine/verifier sessions. The event id and time are
host-assigned (`evt-runtime.started-<uuid>`, wall-clock ms) and are not part of the rule.

Recovery reads the **latest** such event: it scans the durable log in `commitSeq` order in 1000-event
pages and keeps the last event with `type == "runtime.started"`, `principal.botId == botId`,
`principal.kind == "chat"` (`:1712-1728`). The session id is `data.sessionId` when present and
non-empty, else `principal.sessionId`; an event where both are absent or empty is skipped. The
stored `cwd` is `data.cwd` when present.

### 4.2 `runtime.exited`

`switchMainSessionForErasure` (`:1587-1618`) appends one `runtime.exited` event for the old session
before `runtime.started` for the new one:

```json
{
  "type": "runtime.exited",
  "principal": {"botId": "<botId>", "sessionId": "<old>", "kind": "chat", ...},
  "data": {
    "sessionId": "<old>",
    "reason": "session-erased",
    "replacedBy": "<new>",
    "erasureId": "<erasureID>",
    "erasedRecords": ["<record ref>", "..."]
  }
}
```

`erasedRecords` preserves the caller's order and may be empty. The principal is the old session's
live credential when present; otherwise the host synthesizes one with `expiresAt = Int64.max`.

## 5. Main-session recovery

`ensureMainSession` (`:1650-1664`) is single-flight: concurrent first messages share one
`mainSessionTask`; a failure clears the task and propagates. Once `mainSessionId` is set, later
calls return it without touching the network or the log.

`recoverOrCreateMainSession` (`:1671-1710`) applies this decision table, in order:

| # | Observation | Action |
| --- | --- | --- |
| 1 | latest `runtime.started` exists; stored cwd (or `session/list` lookup when `cwd` is absent) equals the current Bot root; and `session/page` validates the id | issue a token for the id, claim it, append a fresh `runtime.started` with the current root, adopt the id. No create, no archive. |
| 2 | latest `runtime.started` exists but cwd differs from the root, or the lookup returned nil | rebuild (6.1) from that id. DSH has no session-delete Remote, so the old id is archived, never deleted. |
| 3 | latest `runtime.started` exists but `session/page` does not validate | rebuild (6.1) from that id. |
| 4 | no usable `runtime.started` | create (3) with `mintedSessionID(.chat)`, claim, `runtime.started`, adopt. |
| 5 | case 4 failed with `session/conflict`, and `session/list` reports the minted chat id (`gb-<safe botId>`) with any `cwd` | treat that old id as a legacy epoch and rebuild (6.1) from it. |
| 6 | anything else | propagate the error; do not invent a session. |

`validateRemoteSession` (`:1830-1852`) uses `session/page`:

```json
{"request": {"address": {"kind": "session", "sessionId": "<id>"},
             "throughSeq": -1, "maxMessages": 1}}
```

Success means the call returned without error; when the response names a session (`sessionId` at the
top level or under `session.sessionId`), that value MUST equal the validated id, otherwise the check
fails. Recovery uses `attempts = 100`; every other caller uses `attempts = 1`
(`:2037-2039`). Only `session/not-found` is retried, with a 50 ms sleep between attempts; every other
error stops the check as a failure. The 100 attempts bound is the host's cold-start budget; a second
host MUST use a bounded retry and MUST NOT turn a `not-found` into a rebuild on the first attempt.

`remoteSessionCwd` (`:1788-1802`) uses `session/list` with the reserved DSH argument:

```json
{"_request": {}}
```

It scans `items[]` for the id and returns that item's `cwd` string, or nil when absent. A thrown call
is not fatal: the host appends an **ephemeral** `runtime.stderr` event with
`source = "BotDSHRemoteRuntime.remoteSessionCwd"` and the error text (`:1804-1816`), and recovery
continues with cwd = nil. `runtime.stderr` is never durable and never a row.

### 5.1 Rebuild

`rebuildMainSession` (`:1746-1764`) MUST preserve this order:

1. notify the App session registry of the old id (host callback; see 8.3);
2. mint `gb-<safe botId>-<lowercase UUID>` and `session/create` it under the current root;
3. best-effort `workspace/archiveSession` the old id with
   `{"request": {"sessionId": "<old>", "stopActivity": false}}` (`:1766-1775`); a failure is swallowed
   and does not fail the rebuild;
4. `ensureSession` the new id (claim; see 8);
5. append `runtime.started` for the new id — this event is the durable commit point;
6. adopt the new id.

If step 2 fails, nothing was archived. If a step after 3 fails, the host MUST archive the replacement
and `workspace/unarchiveSession` the old id (request `{"request": {"sessionId": "<old>"}}`) and
rethrow. It MUST NOT delete the old id, write a `runtime.exited`, or reuse the old id for a new root.

### 5.2 Erasure epoch switch

`switchMainSessionForErasure` (`:1587-1618`) MUST preserve this order:

1. ensure the old session (recovery runs if needed) and cancel its active/queued turns with
   `includeQueued = true`; a cancel error is ignored;
2. mint `gb-<safe botId>-<lowercase UUID>` and create it under the root;
3. best-effort archive the old id;
4. ensure/claim the new id;
5. append `runtime.exited` (4.2) for the old id;
6. append `runtime.started` (4.1) for the new id;
7. adopt the new id and drop the old session credential.

On a failure after step 2 the host archives the replacement and unarchives the old id, then rethrows.
Events already appended in steps 5–6 are not rolled back; recovery is still defined by the latest
`runtime.started`.

### 5.3 Worker replacement

`attachTransport` (`:232-252`) invalidates the Worker's in-memory credentials without rotating the
host tokens: it increments the claim generation, cancels every active and queued turn best-effort,
and clears `mainSessionId`. The next `ensureMainSession` runs the full recovery table again, so a
Worker restart cannot silently keep using a session that the new Worker never acknowledged.
`workerRestarted` (`:1096-1131`) does the same generation bump for Task states and re-claims each
session with its current token before its next turn.

## 6. One turn

### 6.1 `session/prompt`

`sendPrompt` (`:2206-2212`) sends:

```json
{
  "request": {
    "requestId": "<id>",
    "sessionId": "<id>",
    "mode": "queue" | "steer",
    "content": [{"type": "text", "text": "<prompt>"}]
  }
}
```

`content` is always exactly one `text` block for this contract. The prompt text is the user text with
the attachment block appended when attachments are present (`:266-271`), and with the one-shot
continuation seam prepended when staged (`:272-276`). Held-inbox items are folded in front of the
body when the turn is not a steer and a wake inbox is configured (`:279-294`).

`requestId` selection (`:278`):

- an explicit id from the caller (a user-action nonce, a held delivery, a routine/task id) is used
  as given;
- otherwise the host mints `BotTurnOrigin.visibleRequestId()` = `bot-<lowercase UUID with dashes>`
  (`Wake/BotTurnOrigin.swift:107-109`).

Every request id is a DSH idempotency key: replaying the same logical delivery MUST reuse the same
`requestId` so the Worker does not open a second turn.

`mode` is `steer` only when **all** of the following hold (`canSteer`, `:2053-2057`): there is no
queued turn for the session, an active coordinator exists, its prompt was already accepted, it has
not been cancelled, it is a `chat` turn, and it is not hidden. Otherwise the prompt uses `mode =
queue` and waits behind the predecessor. A second visible user message while a turn is active is the
canonical `steer` case; a Task/routine/hidden turn never steers.

### 6.2 `session/follow`

A coordinated turn opens one mux (`:2163-2173`) and sends exactly:

```json
{
  "type": "open", "streamId": "follow", "endpoint": "session/follow",
  "payload": {"args": {"request": {
    "address": {"kind": "session", "sessionId": "<id>"},
    "maxMessages": 64,
    "assistantStream": true
  }}}
}
```

While waiting for the snapshot, an `item` frame on `streamId == "follow"` whose `value.type` is
neither `snapshot` nor `end` is **skipped**; it does not fail the turn (`waitForSnapshot`,
`:2214-2230`). An `item` on that stream whose `value.type == "end"`, or a closed socket, fails
before `session/prompt` with `unavailable("session/follow ended before its snapshot")`; an `error`
frame fails with `unavailable(message)`. Frames for other stream ids are ignored.

`collectTurn` (`:2232-2417`) consumes frames until `turn/end`. A non-item frame, a foreign
`streamId`, or a record without numeric `seq` is ignored. A `type == "assistant-stream"` item with
`frame.type == "start"` publishes `streamStart`; a chunk with `chunk.type == "text-delta"` and a
non-empty `chunk.text` publishes `textDelta(text)` and records the first delta time for TTFT. Live
frames are published only for a visible main-chat turn (`kind == .chat`, not hidden); hidden,
routine, task and maintainer turns publish nothing. `user/message` never publishes a live frame.
Cancellation suppresses all later frames except the terminal `turn/end`.

A durable `event` item (`value.type == "event"`) is used for turn state. `turn/start` sets the
current turn and resets the step/TTFT clocks. `assistant/message` text is accumulated; its usage
fields feed the LLM ledger (P26), and only visible, non-suppressed text becomes
`conversation.assistant_message`. `tool/call` and `tool/result` append `conversation.tool_call` /
`conversation.tool_result` with `eventId = "dsh:<sessionId>:<seq>:<type>"` and
`origin = .dsh(sessionId:seq:)`. `turn/end` terminates the turn.

Terminal mapping: `turn/end.reason.kind == "completed"` → `completed`; `aborted`, `interrupted`, or a
cancel requested by the host → `cancelled`; any other reason → `failed` with
`error = reason.error.message ?? reason.kind`. A socket end before `turn/end`, an `error` frame, or
a stale attempt id returns a non-completed result (`failed`, `cancelled`). The turn result text is
the concatenation of visible assistant text; `finalText` is the last non-empty assistant message.

The `session/follow` snapshot is a **history read**: it never opens the session writer
(`spec/v1/exec.md:185`; `Sources/PhoneDSH/PhoneDSHHost.swift:5007-5010`).

### 6.3 Cancel

`cancelTurn` (`:2059-2084`) marks the coordinator cancelled, sends

```json
{"request": {"sessionId": "<id>", "cause": {"kind": "user"}}}
```

to `session/cancel`, and waits up to 5 s for the turn task to finish. If it does not, the task is
cancelled and the coordinator removed. `includeQueued` also cancels queued turns and removes them.
`stopMainTurn(turnID:)` rejects a mismatched turn with `invalidRequest("stale_turn")` when the caller
supplies an id and a coordinator exists but the runtime's current turn id differs (`:404-411`);
`cancelMainTurn()` passes no id.

## 7. Where the session log comes from

The projection (`projection.md`) consumes an **ordered list of DSH session log records**, not a file
path. Each record carries at least `type`, `seq`, `time`, `data`, and optionally `surfaceOp` and
`eventId`; the record format is the DSH session JSONL line (`projection.md` §2).

The Swift App currently obtains that list from disk:

```
<workspaceRoot>/materialized/home/sessions/**/session.v*.jsonl
```

`BotSessionLogLocator.latestFile` (`examples/probe-app/PhoneDSHProbe/Bot/BotProductionServices.swift:189-213`)
enumerates the tree, keeps files whose name starts with `session.v` and ends in `.jsonl` and whose
parent directory is exactly the session id, and picks the newest by modification date.
`BotProductionRowService.rebuild` (`:297-317`) reads that file with `BotDSHSessionEvent.parseJSONL`.

**The file path is a host detail, not normative.** The materialized-home layout belongs to P02/P16
and may differ on another host. What is normative is that the host supplies the same ordered record
list for the epoch, with the same `type`, `seq`, `time`, `data`, `surfaceOp` and `eventId` values
DSH recorded. The Bot row contract does not depend on `session.v4` header placement, file naming, or
materialization timing.

A host without that file path MUST reconstruct the records from DSH Remote history reads, which the
repo documents as the full journal (not a messages-only window):

1. open `session/follow` with the request from 6.2 only to read `value.cursor` from the first
   snapshot, then close it;
2. call `session/page` with
   `{"request": {"address": {"kind": "session", "sessionId": "<id>"}, "throughSeq": <cursor>, "maxMessages": <n>}}`;
3. while `hasMore` is true, page again with `beforeSeq` = the smallest `seq` already collected and
   the same `throughSeq`;
4. concatenate pages oldest-first and drop duplicates by `seq`.

`Sources/PhoneDSHAgentCore/DSH/DSHRemoteHarness.swift:332-346` implements exactly this fallback, and
the audit receipts record that `session/page` returns the full event journal
(`docs/receipts/ios-session-audit/01-data-path.md:76,138`;
`docs/receipts/ios-session-audit/07-content-actions.md:290`). A host MUST NOT project a
messages-only transcript in place of the journal, and MUST NOT synthesize `surfaceOp` from message
text. If a transport cannot return `surfaceOp` for a `user/message`, that record is treated as "not
surface-appended" (projection §4) rather than guessed.

The App-level epoch chain is also host logic, not a wire rule
(`BotProductionSessionEpochs.load`, `:224-259`): read every durable `runtime.started` for the Bot and
`kind == "chat"` in `commitSeq` order, deduplicate by session id keeping the first occurrence,
append the current session id if unseen, read each id's log, and drop an older epoch only when its
log is empty. This is the algorithm a second host must reproduce to show the same conversation
across an erasure switch; the file names remain free.

## 8. `phone/botClaimSession` and the token registry

### 8.1 Ownership claim

The host issues the registry token **first**, then claims
(`issueAndClaimSession`, `:1979-1988`; the reverse order would leave the first turn unauthenticated):

```json
{"request": {"sessionId": "<id>", "sessionToken": "<dshg_...>"}}
```

`sessionToken` is omitted only when the value is empty, which a registry token never is
(`:1993-1998`). The response MUST be an object with `ok == true`. The response `sessionId` is not
compared; the request id is the identity evidence (`mcp-endpoint.md:159-195`).

Fail-closed rules (`:1993-2014`):

- For an id beginning with `gb-`, a thrown call or `ok != true` is **tolerated as unacknowledged**:
  the create/turn still proceeds, but `ensureSession` re-claims before the session's next turn and
  identity registration at the Worker fails closed until a claim is acknowledged. An unacknowledged
  `gb-` claim must never be cached as authenticated.
- For a non-`gb-` id (legacy/recovered), a thrown call propagates, and `ok != true` raises
  `unavailable("Bot session ownership was not acknowledged for <id>")`; no turn runs.

A claim is re-attempted before the next turn when the Worker generation changed or the previous claim
was unacknowledged (`ensureSession`, `:2016-2051`). If the host still holds the current incarnation
(`tokens.lookup(token)?.sessionId == sessionId` and
`tokens.lookupSession(sessionId)?.incarnation == token.principal.incarnation`), the host re-claims
with that **same** token; otherwise it issues a fresh one. A revoke, rotate or expiry in that window
therefore yields a fresh token rather than reusing a dead one. The Worker replacement protocol is in
`mcp-endpoint.md` §3.

The App-side session registry callback (`onSessionRegistered`) is invoked for every id the runtime
creates, recovers or claims (`:1993-1996`), so a host UI can hide legacy non-`gb-` ids. The callback
is host policy, not wire.

### 8.2 Token shape

A registry token is `dshg_` followed by the unpadded URL-safe base64 of 32 CSPRNG bytes
(`BotTokenRegistry.swift:119,292-306`): exactly 43 characters from `[A-Za-z0-9_-]`. The
`BotGatewayPrincipal.incarnation` is 16 CSPRNG bytes as 32 lowercase hex characters (`:120`).
Tokens and incarnations are opaque; consumers MUST NOT parse or extend them.

### 8.3 Registry lifecycle

`BotTokenRegistry` (`Gateway/BotTokenRegistry.swift`) is the authoritative model. Its observable
rules:

**Issue.** `issue(botId:sessionId:kind:capabilities:expiresAt:ttlMilliseconds:)` (`:98-128`):

- `botId` and `sessionId` are trimmed of leading/trailing whitespace and MUST be non-empty and at
  most 256 characters; otherwise `invalidInput("botId"|"sessionId")`.
- `capabilities` is trimmed per entry, drops duplicates keeping the first occurrence and the input
  order, accepts at most 64 entries, and each entry MUST be non-empty and at most 128 characters;
  otherwise `invalidInput("capabilities")` (`:264-276`).
- expiry is `expiresAt` when supplied, else `now + (ttlMilliseconds ?? defaultTTL)`; the addition
  MUST NOT overflow (`invalidInput("expiresAt")`), `ttlMilliseconds` MUST be positive when used
  (`invalidInput("ttlMilliseconds")`), and the resulting expiry MUST be strictly greater than `now`
  (`invalidInput("expiresAt")`). A token is valid while `expiresAt > now`, never at equality.
- after pruning expired records, the registry MUST hold fewer than 4096 tokens; otherwise
  `registryFull`.
- one new token record and one new `currentIncarnations[sessionId]` are stored.

**Issue for a session.** `issueSession` (`:87-95`) revokes every existing token for the (trimmed)
session id first, then issues. Therefore at most one token per session is current, and a re-sign or
recovery rotates the incarnation. The gateway supplies the TTL: `30 days` for `kind == .chat`,
`12 hours` for every other kind (`Gateway/BotGateway.swift:40-58`). The registry's own default of
`12 hours` (`:57`) applies only to direct registry construction.

**Lookup.** `lookup(token)` (`:130-143`) rejects an empty token and a token longer than 512
characters, compares the SHA-256 digest in constant time over all records, prunes an expired match,
and returns the principal only while `expiresAt > now`. `lookupSession(sessionId)` (`:154-168`)
returns the principal only when the session has a current incarnation and that exact record is
unexpired; a missing current record clears the mapping. `lookupBearer` accepts exactly
`Bearer <token>` with ASCII case-insensitive scheme (`:145-152`).

**Rotate.** `rotate(oldToken:capabilities:expiresAt:ttlMilliseconds:)` (`:214-235`) returns nil for
an empty/oversized/unknown token; for an expired one it removes it and returns nil. Otherwise it
issues a replacement with the same bot, session and kind, the supplied capabilities (or the old
ones), and in priority order: explicit `expiresAt`, else `ttlMilliseconds` relative to now, else the
old exact `expiresAt`; then it removes the old record. The old token is never valid after a
successful rotate.

**Revoke.** `revoke(token)` returns whether an exact digest match was removed; `revokeSession(id)`
and `revokeBot(id)` remove all matching records and return the count; ids are trimmed. Removing a
record also clears `currentIncarnations[sessionId]` only when that record owned the mapping
(`:243-254`). `prune()` removes all records with `expiresAt <= now` (`:237-241`).

**Non-persistence.** The token exists only in the registry's memory and the Worker plugin's
owned-session map (`mcp-endpoint.md` §3). It MUST NOT be written to an environment variable, a
`/dsh/home` file, `UserDefaults`, Keychain, a BotEvent, a log entry, a UI notice or the page URL.
The App passes it only in `phone/botClaimSession` and in the identity registration body.

## 9. Failure classes

| condition | result |
| --- | --- |
| `session/create` returns no `sessionId` | `unavailable`, no claim, no turn |
| `session/create` omits `agentPreset` | `unavailable`, no claim, no turn |
| composed `agentPreset` differs | `unavailable`, no claim, no turn |
| `session/create` `session/conflict` and legacy chat id exists | archive + rebuild (§5.1) |
| `session/create` other error | propagate; nothing archived |
| recovery `session/page` not-found (100 attempts) | rebuild |
| recovery `session/page` other error | rebuild |
| rebuild create fails | propagate; old id untouched |
| rebuild commit fails | archive new, unarchive old, propagate |
| non-`gb-` claim fails | error; no turn |
| `gb-` claim unacknowledged | proceed unauthenticated; re-claim before next turn |
| `session/follow` ends before snapshot | `unavailable`; no prompt |
| `session/prompt` fails | propagate; staged held inbox is reverted |
| cancel: turn does not finish in 5 s | task cancelled, coordinator removed |

The corresponding valid and invalid fixtures are in
`spec/bot/v1/golden/session-lifecycle.phone.json`. The Swift conformance test drives the real
`BotDSHRemoteRuntime` and `BotTokenRegistry`; the Python validator re-checks the vector's arithmetic
and invariants (it is not a runtime).

## 10. Compatibility

- Old Bots with a `gb-<id>` session under `/dsh/workspace` are migrated by archive+rebuild; no Bot
  domain data is deleted. Old readers of `runtime.started` see only the three documented members.
- A Worker that predates `phone/botClaimSession` keeps working for `gb-` ids only, with identity
  registration failing closed until a claim succeeds; non-`gb-` ids fail closed immediately. This is
  the same rule as `mcp-endpoint.md` §3 and is not re-negotiated here.
- The session log path may change on another host; only the record list is contractual (§7).
