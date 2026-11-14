<!-- SPDX-License-Identifier: MIT -->

# Bot UI state seam (P09, normative for both ends)

Status: **normative for both ends** (frozen at PC-20261112-android-bot-w4, C4 / B7b / D15).
Contract: P09 (UI projection); consumes P27 row values (`spec/bot/v1/row.schema.json`,
`user-action.schema.json`, `action-result.schema.json`) and P26 presentation/info values.
iOS reference implementation: `examples/probe-app/PhoneDSHProbe/Bot/` (app code, not a SwiftPM
target). Android: **planned (wave 4 round 2)** — see `docs/design/android-bot-port-plan.md` B7b.

This file is the one authority for the boundary between the Bot runtime projection and a Bot page.
It freezes **values and intents**, **which side owns which derivation**, and the pure view-side rules
that until now existed only in Swift. It does not freeze pixels; geometry and copy placement stay in
`spec/ui/v1/pages/bot-chat.md`, `bot-drawer.md`, `bot-info.md` and `tokens.json`.

Normative terms are RFC 2119. Absent ≡ null (CCR-1): a reader must accept a missing optional member
as null; a writer omits nil. Integer times are Unix epoch **milliseconds**; `now` is always an input,
never read from the wall clock inside a rule. Strings are data (`strings.json`), not code.

## 0. The seam in one picture

```
projection (runtime side)                          view (page side)
─────────────────────────                          ─────────────────
BotProductionRowService ── BotUIRow / Batch ─────▶ rows, history, deletes, cursor
BotRuntimePresentationFactory ── presentation ───▶ fishState / activity / reaction / oneShot
BotProductionInfoService ── BotInfoSnapshot ─────▶ memory / routines / grants / presence / settings
BotProfileStore + runtime unit ── roster ────────▶ BotRosterEntry / BotRosterRuntimeState
                                                   │
                                                   ├─ derives: visible rows, card parse,
                                                   │  settlement, muted, counts, header phase,
                                                   │  activity-line text, drawer status, name cap
                                                   ▼
BotUIUserAction / drawer+info intents ◀────────── user taps
```

`bot-dock.md` remains a superseded proposal (CCR-4 option b) and is not revived by this contract; the
shipped four-column `HomeTabBar` is the only bottom bar.

The projection owns **what happened** (durable rows, director lifecycle, info snapshot, whether a
turn is running). The view owns **what is shown now** (local optimistic rows, action state, card
settlement, header phase, line text/timing, drawer status). A view MUST NOT invent an event, a
success, an approval state, or an item count; it renders the snapshot and shows failures as failures.

The reference implementation of the projection half currently lives beside the view
(`BotProductionRowService.presentation()` → `BotRuntimePresentationFactory.make`,
`examples/probe-app/PhoneDSHProbe/Bot/BotProductionServices.swift:317`). That placement is an iOS
implementation detail, not an ownership statement: a port MUST produce the same value types below
from the same durable events.

## 1. Driver and page surfaces

`BotChatDriver` (`BotUIModels.swift:464-476`) is the narrowest chat boundary. Its seven members are
the complete chat-facing projection surface; there is no second chat channel.

| Member | Type | Direction | Meaning |
| --- | --- | --- | --- |
| `history` | `(String?, Int) async throws -> BotUIHistoryPage` | view → projection | older rows before a row-id anchor, `limit` ≤ 50 in the reference view |
| `watch` | `(Int) async throws -> BotUIRowBatch` | view → projection | rows/deletes after a numeric cursor; a reset replaces non-local rows |
| `perform` | `(BotUIUserAction) async -> BotUIActionResult` | view → projection | one user intent; see §3 |
| `stopCurrentTurn` | `(String?) async -> Void` | view → projection | stop the named turn (nil = current) |
| `turnProcesses` | `() async -> [Int: BotTurnProcess]` | projection → view | tool steps of finished turns, keyed by DSH turn number; view-only, never a message row |
| `liveFrames` | `() async -> AsyncStream<BotLiveFrame>` | projection → view | `streamStart`, `textDelta(String)`, `event(JSON)` of the running main-chat turn |
| `presentation` | `() async throws -> BotRuntimePresentation` | projection → view | durable fish lifecycle, running turn id, current activity, reaction, one-shot |

`BotUIHistoryPage` = `{rows, nextCursor: String?, hasMore: Bool}` (`BotUIModels.swift:458`).
`BotInfoDriver` (`BotInfoPage.swift:140-158`) is the info-page intent surface in §3.6.
`BotDrawerActions` (`BotDrawer.swift:10-23`) is the drawer intent surface in §3.5.
Page callbacks (`BotChatPage.swift:47-62`) are provider/intent props in §3.7.

## 2. Presentation value types

JSON Schemas: `schema/row.schema.json`, `schema/row-batch.schema.json`,
`schema/presentation.schema.json`, `schema/roster.schema.json`, `schema/info.schema.json`,
`schema/intents.schema.json`. The row body is the P27 row body: `spec/bot/v1/row.schema.json`
already fixes `body.type` and `body.cardType`; this seam adds no wire field.

### 2.1 `BotUIRow` / `BotUIBody` / `BotUIRowBatch`

| Field | Type | Null | Rule |
| --- | --- | --- | --- |
| `id` | string | no | non-empty; `local-<nonce>` is the only view-created prefix |
| `botID` | string | no | non-empty |
| `seq` | int | no | ≥ 0; transcript order is ascending `seq` |
| `updatedSeq` | int | no | ≥ 0; a same-id row with a **larger** `updatedSeq` replaces the stored one |
| `kind` | enum | no | `message`, `sendMessage`, `event` |
| `role` | string | yes | renderable text rows require `user` or `assistant` |
| `body.type` | enum | no | `text`, `widget`, `attachment`, `approval`, `automation`, `notice`, `deleted` |
| `body.cardType` | enum | yes | `question`, `steps`, `task`, `document`, `progress`, `checklist`, `link`, `table`, `callout`, `info`, `payload`, `library`; the UI-only `attachment` value is accepted by the view but P27 never serializes attachment/approval/automation/notice in cardType |
| `body.cardKey` | string | yes | ≤ 64; a progress row with the same cardKey updates in place |
| `body.*` | any JSON | yes | type-specific payload, unchanged from P27 |
| `provenance.eventIDs` | string[] | no | source event ids; the local optimistic row carries `local:<nonce>` |
| `provenance.trust` | string | no | P27 value (`owner_direct`, `model`, …) |
| `provenance.tainted` | bool | no | P27 value |
| `streaming` | bool | no | durable streaming flag; the view does not fabricate it |
| `createdAt` | int (ms) | no | ≥ 0 |

`BotUIRowBatch` = `{rows: BotUIRow[], deletes: string[], cursor: int ≥ 0, reset: bool}`. `reset`
means the projection replayed its state: the view drops every non-`local-` row, adopts at most the
last 50 incoming rows and sets its history cursor from the first adopted row. `deletes` remove by id
before incoming rows are applied. A host error `notice` arriving in a **non-reset** batch is not a
transcript row: it arms the header problem line (§4.6). A reset batch never replays an old notice.

Absent `body.type` makes the body invalid and the row unrenderable (fail closed); the reference decoder
throws (`BotUIModels.swift:101-107`).

### 2.2 Card sub-values

`BotUICardContent.parse` (`BotUIModels.swift:654-717`) maps a row body to one of eleven card kinds:
`question`, `steps`, `task`, `attachment`, `document`, `progress`, `checklist`, `link`, `approval`,
`automation`, `notice`. `widget` bodies additionally require a registered `cardType`; `attachment`
accepts an absent or `attachment` cardType; `approval`/`automation`/`notice` need no cardType. The
per-kind data requirements are the `valid(kind:body:)` switch (`BotUIModels.swift:679-717`) and are restated as
normative in §4.2. P1 kinds (`table`, `callout`, `info`, `payload`, `library`) and unknown widget
kinds parse to `nil` — they are not rendered and are not an error.

Parsed sub-values (all view-side, all pure):

- `BotUIChoice` (`BotUIModels.swift:528-570`): object form needs a non-blank `label|text|title|value`. `id` is
  `id|optionID`, else `"<index>:<rawLabel>"`; a bare string is a choice with id `"<index>:<label>"`,
  value = label. `value` defaults to label; `description` is `description|detail`; `recommended` is
  `recommended == true || style == "primary"`, but never when `style == "danger"`; `danger` is
  `style == "danger"`. `parseList` stops at 4 and keeps only the **first** recommended non-danger
  choice recommended.
- `BotUIProgressStep` (`BotUIModels.swift:572-599`): plain strings become `step-<index>`/`pending`; object labels are
  `label|title|text`, ids `id` else `step-<index>`; state aliases `in_progress|running|working` →
  `active`, `complete|completed|success|ok|sent` → `done`, `error|failure|blocked` → `failed`;
  allowed states are `pending|active|done|failed|skipped`, anything else → `pending`; at most 8.
- `BotUIChecklistItem` (`BotUIModels.swift:601-622`): plain strings become `item-<index>` with `done=false`; object
  ids `id` else `item-<index>`, text `text|content|label|title`, `note` is `note|meta|due`,
  `synthetic` is the boolean `synthetic`; at most 12.
- `BotUILink` (`BotUIModels.swift:624-652`): only `http`/`https` with a non-empty host and ≤ 2048 characters; id `id`
  else `link-<index>`; site `site` else host without a leading `www.`; title `title|name|label` else
  site; description `description|summary|note`; kind default `other`; at most 4.
- `BotUIAttachment.parseList` (`BotUIModels.swift:270-283`): name `name|fileName` required, size
  clamped to ≥ 0, kind derived by `BotAttachmentPolicy.kind` when absent, at most 10.

### 2.3 `BotRuntimePresentation` / `BotActivity`

`BotRuntimePresentation` (`BotRuntimePresentation.swift:57-66`), every member optional at the JSON
edge, defaults on the Swift value:

| Field | Type | Absent means | Rule |
| --- | --- | --- | --- |
| `fishState` | `BotFishLifecycle` | `idle` | director's current lifecycle |
| `runningTurnID` | string | null | the durable running main-chat turn, if any |
| `activity` | `BotActivity?` | null | current phase of the running turn |
| `reaction` | `BotFishReaction?` | null | latest active one-shot reaction of this Bot |
| `oneShot` | `BotFishOneShot?` | null | director one-shot (celebration, failure, …) |

`BotFishLifecycle` is the 42-case enum in `Sources/PhoneDSHBot/Avatar/BotFishDirector.swift:5-14`.
`BotActivity` (`:39-55`) = `{status: thinking|tool-running|streaming, detail: string (default ""),
category: <12-case BotActivityCategory, default generic>, startedAt: int ms (default 0)}`. The categories are
`thinking, reading, searching, browsing, running, writing, memory, messaging, reviewing, waiting,
replying, generic` (`BotActivityPhrases.swift:10-27`). `detail` is display text only; `category`
always follows the tool name, never the model's prose. `startedAt` is the start of the phase in the
event clock and drives the `· N 分钟` suffix.

`BotFishReaction` = `{id, botID?: string|null, kind: action|expression, name: string, startedAt: int,
durationMs: int ≥ 1}`; `BotFishOneShot` = `{state: BotFishLifecycle, priority: int, startedAt: int,
endsAt: int}`. A reaction is active iff `startedAt <= now < startedAt + durationMs`; the view never
extends it on its own.

`BotHeaderPresence` (`BotHeaderPresence.swift:27-101`) is a **derived view value**, not an inbound
one: `{phase: idle|problem|working|waitingForYou, line: BotActivity?, fishState: BotFishLifecycle,
motion: standard|lively, workStyle: generic|reading|searching|running|writing, lineIsQuiet: bool,
lineIsProblem: bool}`. Its resolution is §4.6.

### 2.4 Roster values

`BotRosterRuntimeState` (`BotRosterModel.swift:10-22`) =
`{fishState, activity: BotActivity?, isRunning: bool, pendingApprovalCount: int ≥ 0,
reaction: BotFishReaction?, runtimeState: BotRuntimeState}`. Absent members take the value's defaults:
`fishState = idle`, `activity = null`, `isRunning = false`, `pendingApprovalCount = 0`,
`reaction = null`, `runtimeState = idle`.
`BotRosterEntry` (`:24-42`) =
`{id, name, description, appearance: BotFishAppearance, isMainBot, isHidden, unreadCount: int ≥ 0,
lastMessageAt: int|null, runtime: BotRosterRuntimeState}`. `appearance` =
`{color: <15 colors>, hairstyle: long|twin-tail|bob|side-braid, autoColor: bool, autoHairstyle: bool}`
(`Sources/PhoneDSHBot/Profile/BotFishAppearance.swift:10-25,72-76,101-105`). The roster entry's
`fishState|activity|isRunning|pendingApprovalCount|reaction` are pass-through accessors of `runtime`.

`BotRuntimeState` (`BotRuntimeState.swift:8-21`) is the UI-visible connection state:
`idle`, `preparing`, `connecting`, `ready`, `recovering`, `failed(String)`, `stopped`. JSON binding:
`{"kind": "<case>"}`, with `{"kind":"failed","message":"<non-empty>"}` for the associated value.
`recovering` and `failed` require a disconnect banner; the view must not present stale rows as live.
Order of the roster list is frozen: the main Bot first, then insertion order; `visibleEntries` only
removes `isHidden` entries and is what the drawer shows.

### 2.5 Info values

`BotInfoSnapshot` (`BotInfoPage.swift:125-138`) is one load result; the view never merges partial
sub-loads. Fields (dates are epoch ms at the JSON edge):

| Field | Type | Rule |
| --- | --- | --- |
| `botName` | string | non-empty profile/display name |
| `memories` | `BotMemoryDocumentInfo[]` | document tree rows; `scope` is `agent` or `user`; `versions` keeps the projection's order and the view renders that order |
| `routines` | `BotRoutineInfo[]` | schedule/timezone/delivery/quiet/urgent/lastResult/enabled plus optional creator, criteria, constraints, runStatus, runID, nextDue, quietDeferredFrom/Until, creatorDetail, lastResultDetail |
| `approvals` | `BotApprovalRecord[]` | `{id, parameterSummary, decision, decidedAt}`; the decision is already human-readable |
| `grants` | `BotGrantInfo[]` | standing grants only (`scope != once`); `{id, tool, operation, resource, scope, sessionID?, createdAt, source}` |
| `reconciliations` | `BotReconciliationInfo[]` | `{routineID, routineTitle, attempt, runID, error?, effectSummary?, effectDetail?}` |
| `presence` | `RoutinePresence` | `{level: foreground|backgroundKeepAlive|scheduledNotification, deferred: [{routineId,title,scheduledFor,deferredUntil}], scheduledNotificationCount ≥ 0}` |
| `proactiveSettings` | `ProactiveSettings` | `{mode: off|would|on, dnd, quietStart "HH:mm", quietEnd "HH:mm", routineQuietWeekends, timeZone}` |
| `maintenance` | `BotMaintenanceBatchInfo?` | last real batch or null; never fabricated |
| `maintenanceEnabled` | bool | persisted P18 switch |
| `maintenanceDailyTokens` | int ≥ 0 | today's usage |
| `maintenanceDailyBudget` | int ≥ 0 | 0 renders `—`, never a divide-by-zero |

Absent optional members take the Swift value's default: `grants = []`, `reconciliations = []`,
`presence = {level: foreground, deferred: [], scheduledNotificationCount: 0}`,
`proactiveSettings = {mode: on, dnd: false, quietStart: "23:00", quietEnd: "08:00",
routineQuietWeekends: false, timeZone: <device zone>}`, `maintenance = null`,
`maintenanceEnabled = false`, `maintenanceDailyTokens = 0`, `maintenanceDailyBudget = 0`.

`BotInfoModel` exposes three independent load states (`BotInfoPage.swift:160-164`):
`loading | loaded | failed(String)`. All three data sections start `loading` when a driver exists and
no snapshot was injected; a failed load sets all three to `failed` and never to empty. A snapshot
injected by a fixture is `loaded`. The page shows `读取失败` plus the reason, not zero counts.
`BotMemoryDocumentInfo` = `{id, path, scope, content, version, updatedAt, author, evidence[],
versions[]}`; `BotMemoryVersionInfo` adds `deleted` and `deletionReason?`.
`BotMaintenanceBatchInfo` = `{batchID, status, trigger, startedAt, finishedAt, changedDocuments,
changes[] ({path, scope, beforeVersion, afterVersion, deleted}), failureCode?, checksPassed,
rolledBack, canRollback, tokensUsed, notification}`.

### 2.6 Deep link value

`BotDeepLink` (`BotUIModels.swift:496-521`) parses `phonedsh://bot/<botID>/<row|routine>/<id>`:
scheme `phonedsh`, host `bot`, exactly three non-empty path components; middle component `row` or
`routine`; anything else is invalid. The value is `{botID, destination: {kind: row|routine, id}}`.
Only a row destination scrolls the chat; a routine destination is handed to the info page (§4.13).

## 3. Intents

Intents are the only view → projection writes. The row actions are already normative in P27:
`spec/bot/v1/user-action.schema.json` and `action-result.schema.json`. This section fixes the UI
mapping, the local duplicate rules, and the drawer/info/appearance surfaces that P27 does not cover.

### 3.1 `BotUIUserAction` / `BotUIActionResult`

| Intent | Required fields | Forbidden locally | Local effect on acceptance |
| --- | --- | --- | --- |
| `chat` | `nonce`, `botID`, `text` (may be `""`), optional `attachments` | — | local row's `provenance.eventIDs` becomes `[eventID]`; any row with `chatActionNonce == nonce` replaces the local row |
| `cardAnswer` | `nonce`, `botID`, `cardID`, `optionID` (non-empty) | `text`, `customText`, `attachments` | inserts the `local-<nonce>` choice echo and sets the key `pending` (§4.3.2); remembers `answeredOptionIDs[cardID] = optionID`; the durable `card-answer:<nonce>` user row retires the echo |
| `cardDismiss` | `nonce`, `botID`, `cardID` | — | adds `cardID` to `dismissedCardIDs`; the settled line is 「已关闭」 |
| `approval` | `nonce`, `botID`, `approvalID`, `decision: allowOnce|always|deny`, `digest` (non-empty) | — | sets the approval row's `body.status` to `allowed` / `always` / `denied` and bumps `updatedSeq`; a deny issued as part of a send is also remembered in `autoDeclinedApprovalIDs` |
| `stopTask` | `nonce`, `botID`, `threadID` | — | stop is a transport action; it does not create a message row |

`BotUIActionResult` is exactly P27: `accepted(eventID)`, `duplicate(eventID)`, `stale(reason)`,
`rejected(reason)`. Local action state is `pending | accepted | failed(reason)` keyed
`"card:<rowID>"`, `"approval:<rowID>"`, `"dismiss:<rowID>"` or `"chat:<localRowID>"`. Rules:

- A second tap while the key is `pending` or `accepted` is ignored by the view (no duplicate intent).
- A `failed` `chat`, `cardAnswer`, `cardDismiss` or `approval` key is retryable; `pending` and
  `accepted` are not. A failed dismiss therefore leaves the question card full with the dismiss
  action available again (§4.3). `answer`, `dismiss` and `beginApproval` use the same guard
  (`state == nil || state == .failed`).
- `accepted`/`duplicate` set `accepted`; any other result sets `failed` and clears the awaiting-turn
  window.
- A failing `chat` removes its local row; a failing `cardAnswer` rolls back its `local-<nonce>`
  choice echo; a failing attachment import is reported per file and never blocks the remaining
  files/text.
- Sending the next `chat` implicitly denies every approval still awaiting a decision (id+digest
  present). The view marks those approvals `pending` synchronously, then performs deny actions in
  order **before** the chat action. This is the existing `approval` deny path; there is no new action
  and no new error code.
- A card answer/dismiss is only allowed on a card that parses (§4.2) and is not muted; `steps` does
  not support dismiss (`cardDismiss` is rejected for steps).

### 3.2 `BotDrawerActions`

`BotDrawerActions` is a closure bag (`BotDrawer.swift:10-23`); the frozen intent vocabulary and
parameters are:

| Intent | Parameters | Contract |
| --- | --- | --- |
| `select` | `botID` | persist selection, mark read, switch the page model; the drawer closes |
| `create` | `name`, `color`, `hairstyle` | returns the created `BotProfile`; trims and validates §4.10 first |
| `rename` | `botID`, `name` | async throws; the store re-validates the same §4.10 rule |
| `setMain` | `botID` | async; moves the crown and the roster order |
| `setHidden` | `botID`, `hidden` | async; hidden Bots leave `visibleEntries` only |
| `delete` | `botID` | async throws; full cascade, last-Bot refusal is surfaced verbatim |
| `appearance` | `botID` | opens that Bot's info appearance section |
| `manage` | — | opens the management list |
| `retry` | — | retries the roster load |
| `close` | — | closes the drawer (host may do extra work first) |

### 3.3 Appearance

`BotProfileCenter` is the single in-memory profile view (`BotProfileCenter.swift:83-141`). Intents:
`select(color:)`, `select(hairstyle:)`, `rename(_:)`. Selecting applies **immediately** to the local
`appearance` (clearing `autoColor`/`autoHairstyle`) and then persists only the changed field; a write
failure is surfaced as `外观保存失败：…` and is **not** rolled back. `rename` trims, refuses empty,
writes the durable profile and mirrors a successful `renamed` event; a profile-write failure still
updates the display name and reports `名字已写入对话，但资料同步失败：…`.

### 3.4 Page callbacks (`BotChatPage.swift:47-62`)

`onOpenInfo`, `onOpenInfoSection(BotInfoSection)`, `onSelectBot(botID)`, `openDrawer`,
`onConnectDevice`, `handleExternalDeepLink(URL) -> Bool`, `openDocument(BotUIRow)`, plus the provider
props `peerAppearance(botID)`, `peerIsMainBot(botID)`, `peerReaction(botID)`, `hasOnlineDevices`.
Providers are reads, never writes. A deep link routes: row → `model.openDeepLink`; routine/unknown →
`handleExternalDeepLink` (the hub, §4.13).

### 3.5 `BotInfoDriver`

`BotInfoDriver` (`BotInfoPage.swift:140-158`) intents, all view → projection:

| Intent | Parameters | Result/effect |
| --- | --- | --- |
| `load` | — | `BotInfoSnapshot` (throws) |
| `rename` | `name` | throws; mirrors the profile |
| `forget` | document (`path`, `version`) | logical delete of the live version |
| `eraseDocument` | document | physical erase of one document and all versions |
| `erase` | — | physical erase of this Bot's `agent/` root |
| `eraseShared` | — | physical erase of the shared `user/` root (separate confirmation) |
| `setRoutineEnabled` | `routineID`, `enabled` | throws |
| `revokeGrant` | `grantID` | throws |
| `cancelRoutine` | `routineID` | throws |
| `resolveReconciliation` | `routineID`, `decision` (`acknowledge|retry`) | throws |
| `saveProactiveSettings` | `ProactiveSettings` | returns the normalized persisted value |
| `setMaintenanceEnabled` | `enabled` | async |
| `rollbackMaintenance` | `batchID` | throws |

After any successful mutation the page re-reads the authority (`load`); it never applies an item
count it did not read. A failed mutation shows the failure and leaves the previous snapshot visible.

### 3.6 Error/notice intent rules

The view-local notice channel (`runtimeNotice`) is display-only. It is armed by a live/watch/history
failure, an action failure, an attachment failure, or a **new** renderable error notice in a non-reset
batch, and cleared by the next send, by success, or by the 6 s timer (§4.11). It is never persisted
and never becomes a row. `notice` rows themselves never enter the transcript (§4.1).

## 4. Derived-state rules (view-owned, pure)

Every rule in this section is a pure function of the named inputs. `now` is an explicit input in
milliseconds. The machine-readable vectors are `golden/ui-state-vectors.json`,
`golden/card-parse-vectors.json`, `golden/activity-phrase-vectors.json` and
`golden/invalid-vectors.json`; the checker recomputes them with an independent implementation.

### 4.1 Transcript visibility and display

Input: `rows`, `live: {turn: int|null, ended: bool}|null`, `lineSuppressed`, `display` flags.
- `visibleRows` = rows where `BotUIRendering.isRenderable` is true **and** `body.type != "notice"`
  (`BotChatModel.swift:239-250`). Notices are not transcript rows, even when renderable.
- `isRenderable` (`BotUIModels.swift:719-732`): `deleted` → false; `text` → `kind` is
  `message|sendMessage` **and** `role` is `user|assistant` **and** (trimmed `text` non-empty **or**
  (`role == user` and parsed attachments non-empty)); anything else → card parse non-nil (§4.2).
- `surface` (`:735-750`): text → `bubble`; question/steps → `widget-card`; task →
  `agent-thread-row`; attachment → `attachment-card`; document → `document-card`; progress →
  `progress-card`; checklist → `checklist-card`; link → `link-card`; approval → `approval-card`;
  automation → `automation-row`; notice → `notice`; unrenderable → `hidden`.
- `displayRows` = `visibleRows`, except that while a live turn `t` is non-nil it removes assistant
  **text** rows whose `body.turn == t` (the live frames already show that answer; `:257-261`).
- `copyText` = first non-empty `body.text`, else `title|question|prompt|name|fileName|path|summary`,
  else the row id (`:752-755`).

### 4.2 Card parsing (fail closed)

A card parses iff its `body.type` is as follows (`BotUIModels.swift:654-717`):
- `widget`: `cardType` is one of the seven registered widget kinds and the kind's data check passes;
- `attachment`: cardType absent or `attachment`, and `fileName|name|path` non-empty;
- `approval`: id+digest+action rule below;
- `automation`: `title|name|automationId` or `automation.name|automationId` non-empty;
- `notice`: `tone` (default `error`) in `error|denied|denial` and trimmed `text` non-empty;
- any other type or unregistered widget kind → `nil`; the row is not rendered, no placeholder card.

Per-kind data checks:
- `question`: parsed `options` non-empty **or** `question|prompt|helpText|help` non-empty.
- `steps`: parsed `steps` non-empty **or** `question|prompt|helpText|help` non-empty.
- `task`: `title|text|question` non-empty **or** `tasks|steps` array non-empty.
- `document`: `title|name|fileName|path|url|summary|content` non-empty.
- `progress`: `title|name` non-empty.
- `checklist`: `title` non-empty **and** parsed `items` non-empty.
- `link`: parsed `links` non-empty.
- `approval`: `status` = `body.status|ask.status`, default `pending`; `action` =
  `body.action|title|text` or `ask.action`, default `""`. If `status == pending`, the card needs a
  non-empty `approvalID|requestId|id` (or `ask.requestId`), a non-empty `digest`, **and** a non-empty
  `action`; otherwise it does not parse and is not rendered. For every non-pending status a non-empty
  `action` is required.
- `automation`: as above; `notice`: as above.

### 4.3 Settlement (one rule for interactive cards)

`settlement(for:)` (`BotChatModel.swift:460-585`) returns `nil` (keep the full card) or
`BotCardSettlement{glyph, title, detail: String?, tone: neutral|success, monospacedDetail: bool}`.
`glyph` is a semantic id (`xmark.circle`, `checkmark.circle`, `checkmark.circle.fill`,
`minus.circle`); the platform maps it to its icon. `task/document/progress/link/attachment/
automation/notice` never settle.

Common gates:
- Unparseable card → `nil`.
- Question/steps: the durable status settles first (see the table); only then does the local
  action state matter, and `pending|failed` → `nil`.
- Checklist: `interactive == false` → `nil`; progress `sending == true` → `nil`.
- Approval: action state for `"approval:<id>"` is `pending|failed` → `nil`.

Priority and copy (first match wins):

| Kind | Condition | `glyph` | `title` | `detail` | Other |
| --- | --- | --- | --- | --- | --- |
| question/steps | `status == "superseded"` | `minus.circle` | `已过期，用最新那张` | `promptDetail` | durable truth; settles even when `"card:<id>"` is `pending`/`failed` |
| question/steps | `dismissedCardIDs` contains id **or** `status == "dismissed"` | `xmark.circle` | `已关闭` | `promptDetail` | |
| question/steps | `status == "answered"` | `checkmark.circle` | `已选择：<label>` when the option label resolves, else `已送出` | `promptDetail` | durable answer outranks the local action state |
| question/steps | action state `pending` or `failed` | — | `nil` (keep the full card) | — | `.pending` shows 「正在送出…」; `failed` stays retryable |
| question/steps | action accepted | `checkmark.circle` | `已选择：<label>` when the option label resolves, else `已送出` | `promptDetail` | |
| checklist | progress `sent == true` | `checkmark.circle` | `已发送勾选结果` | `<title> · 已完成 <done>/<total>` | |
| checklist | id ∈ `mutedCardIDs` | `minus.circle` | `已略过` | same | |
| approval | (`status == pending` **or any status**) and id ∈ `autoDeclinedApprovalIDs` | `xmark.circle` | `已略过，视为拒绝` | `command` else `action` | monospaced iff command non-empty |
| approval | status `allowed` | `checkmark.circle.fill` | `已允许一次` | same | `tone = success` |
| approval | status `always` | `checkmark.circle.fill` | `本次对话都允许` if scope `session`, else `已总是允许` | same | `tone = success` |
| approval | status `denied`/`never` | `xmark.circle` | `已拒绝` | same | |
| approval | status `timed-out` | `xmark.circle` | `已超时，视为拒绝` | same | |
| approval | status `expired` | `xmark.circle` | `已过期，视为拒绝` | same | |
| approval | any other settled status | `xmark.circle` | `已处理` | same | |

`promptDetail` = trimmed `question|prompt` if non-empty, else `建议下一步` for `steps`, else null.
The chosen label resolves from `body.answeredOptionID` (durable) **or** the local
`answeredOptionIDs[rowID]`, matched against the parsed `options` (question) / `steps` (steps) list;
an unknown option id yields `已送出` (never the raw id). `scope` = `body.alwaysScope|ask.alwaysScope`,
default `until`. `command` = `body.command|target` or `ask.target`, default `""`. Auto-declined
applies to a pending approval and to any later durable status; it is a local truth that survives the
round-trip.

#### 4.3.1 Superseded choice cards

A `question`/`steps` card is superseded by the P27 rule (projection.md §6.4): once a newer
question/steps card is presented in the same Bot stream, every older still-open choice card is
permanently stale, and the projection writes `status:"superseded"` + `supersededBy:"<newer id>"`.
The view does not recompute that rule. A superseded card always settles to the `minus.circle`
line above — even while its own tap key is `pending` or `failed` — because the planner would refuse
the tap with `card_expired`; keeping its buttons would only produce a second refusal. If the full
card is ever drawn for a superseded row, its options are disabled and it shows the same
`已过期，用最新那张` line (`BotCardView.swift:85,102,180-181`). A tap on a locally
`superseded` card is refused before any action is sent: the view marks the key
`.failed("card_expired")` and renders the refusal copy below.

#### 4.3.2 Pending tap and the optimistic choice echo

A tap is local, immediate and reversible (`BotChatModel.answer(row:optionID:)`,
`BotChatModel.swift:727-770`). It:

1. refuses locally when `body.status == "superseded"` (step above);
2. parses the choice and generates a nonce;
3. appends the optimistic user row `local-<nonce>` — `id = local-<nonce>`,
   `provenance = ["local:<nonce>"]`, `kind = sendMessage`, `role = user`, trust `owner_direct`,
   body `{type:"text", text:<option value, falling back to label>}`, `seq = max(seq)+1`;
4. records `answeredOptionIDs[cardID] = optionID` and sets `"card:<id>"` to `pending`;
5. performs `cardAnswer` with the same nonce.

While `pending`, the card stays full (settlement `nil`), the tapped option keeps its checkmark and
the status line under the options is a spinner plus `正在送出…` (`BotChoiceCardUI.pendingStatus`,
`BotCardView.swift`). The host sends the option value as an ordinary chat message with
`rpcId = card-answer:<nonce>`; P27 projects that nonce onto the durable user row's in-memory
`chatActionNonce` (projection.md §4.4 step 15), so the same nonce-keyed `upsert` rule that retires a
typed composer echo retires this one — the choice never appears twice. On failure the echo is
rolled back (`BotChoiceCardUI.echoDisposition`; a failed action still leaves the card full and
retryable). In a fixture/preview model (`driver == nil`) an accepted tap drops the echo directly,
because no durable row will arrive.

#### 4.3.3 Refusals stay on the card

The planner's refusal codes are normal stale-card outcomes, not app failures: the card names them
and they never arm `runtimeNotice` (§3.6). The copy is `BotChoiceCardUI.refusalCopy`
(`Sources/PhoneDSHBot/UI/BotChoiceCardUI.swift`) and is mirrored in `strings.json`:

| `reason` | card copy |
| --- | --- |
| `card_expired` | `这张卡片已经过期，用最新那张` |
| `already_answered` | `已经选过了` |
| `answer_in_flight` | `正在送出，稍等` |
| `card_dismissed` | `这张卡片已经关闭` |
| `unknown_card` | `这张卡片已失效` |
| `unknown_option` | `这张卡片已失效` |

Any other failure keeps the full card and shows `未能送出：<reason>`; the raw reason code never
reaches the screen. The header problem line still receives real transport/runtime failures
(§3.6).

`settledRowIDs` = ids of `displayRows` whose settlement is non-nil; the transcript scrolls to the
bottom once after a collapse animation when this set changes (`BotChatModel.swift:274-280`).

### 4.4 Muted cards

`mutedCardIDs` (`BotChatModel.swift:442-455`) is **checklist-only**: find the **last**
`visibleRows` index with `role == "user"` and `body.type == "text"`. No such row → empty set. For
each earlier row, if it parses to `checklist`, its `"card:<id>"` action state is absent (never
attempted), progress is neither `sending` nor `sent`, and `interactive != false`, the id is muted.

Question and steps cards are deliberately **not** muted: their staleness is the durable P27
`status:"superseded"` (§4.3, projection.md §6.4), computed from the same event stream the planner
refuses with `card_expired`. A second local "before the last user text" rule could only disagree
with it — that disagreement was the defect fixed by `PC-20261114-card-superseded-and-pending` (a
card that looked active was expired, and a card that looked stale was still answerable). A
checklist has no durable expiry — sending its result is an ordinary chat message — so the
send-time guidance stays app-owned. Muting is not dismissal: a muted checklist keeps its data and
settles to `已略过`. Approvals are not muted; they are auto-denied on send (§3.1).

### 4.5 Counts

Inputs: `visibleRows`, `actionStates`, `dismissedCardIDs`, `answeredOptionIDs`,
`autoDeclinedApprovalIDs`, `checklistProgress`, `context.followingCount: int|null`.

- `pendingApprovalCount` (`BotChatModel.swift:302-304`): visible rows with `body.type == approval`,
  status (`body.status|ask.status`, default `pending`) equal to `pending`, and
  `"approval:<id>"` not `pending|accepted`. A failed approval action counts again (retryable).
- `needsAttentionCount` (`:306-321`) = `pendingApprovalCount` +
  - question/steps: `"card:<id>"` not `pending` and settlement is nil;
  - checklist: `interactive != false`, progress `sending != true`, settlement is nil.
- `followingCount` (`:323-345`): if `context.followingCount` is non-null, return it verbatim (no local
  computation); otherwise count visible rows: automation status (`body.status|automation.status`,
  default `sent`) in `running|confirming`; progress state (`body.state`, default `running`) equal to
  `running`; task status (`body.status|task.status`, default `""`) in
  `running|active|in_progress|working`.

The header menu line is `跟进中 <followingCount> · 需要你处理 <needsAttentionCount>`
(`BotChatPage.swift:242`).

### 4.6 Header phase

`BotHeaderPresence.resolve(turnActive:lineActivity:pendingApprovals:fishState:problem:)`
(`BotHeaderPresence.swift:48-80`) is the only header rule. Order:

1. `problemText(problem)` non-nil → `problem`: line = `BotActivity(thinking, text, generic,
   startedAt 0)`, fishState = input, motion `standard`, workStyle `generic`.
2. `turnActive == true` **and** `lineActivity != nil` → `working`: line = `lineActivity`, fishState =
   `workingFish(input)`, motion `lively`, workStyle = workStyle(category).
3. `pendingApprovals > 0` → `waitingForYou`: line = `BotActivity(thinking, "", waiting, 0)` when the
   count is 1, else `BotActivity(thinking, "<N> 项等你确认", waiting, 0)`; fishState = input, motion
   `standard`, workStyle `generic`.
4. otherwise `idle`: line nil, fishState = input, motion `standard`, workStyle `generic`.

`problemText` (`:84-92`) splits on newlines, trims each part, drops empties and joins with `；`; an
empty result is nil. `workingFish` (`:94-101`) maps `idle|sleeping|standby|waking|done` → `thinking`;
every other state is unchanged. `lineIsQuiet` = `phase == problem || line?.category == waiting`;
`lineIsProblem` = `phase == problem`. Unanswered question/steps cards never hold the header.

### 4.7 Fish lifecycle — normative

There is exactly one fish-lifecycle projection. The pure function is
`BotFishLifecycleProjection.resolve` in `Sources/PhoneDSHBot/UI/BotUIProjection.swift`.
`BotRuntimeUnit.statusSnapshot` computes it for the roster and `BotChatModel.fishState` consumes the
same function for the header (§4.6) and the empty state, so the page and the roster drawer render the
same value on the same inputs. The header's `workingFish` mapping (§4.6) still applies on top of this
base value.

Inputs (all explicit; `now` is never read from the wall clock inside the rule):

| Input | Type | Meaning |
| --- | --- | --- |
| `pendingApprovalCount` | int ≥ 0 | §4.5 |
| `running` | bool | `liveRunning ∨ remoteBusy ∨ routineRunning`; the page's local equivalent is `runningTurnID != nil ∨ live != nil` |
| `idleSleeping` | bool | the 60 s idle clock (§4.11) |
| `livePresentation` | `{fishState, oneShot?}?` | the live turn's presentation (§2.3); absent/null means none |
| `durablePresentation` | `{fishState, oneShot?}` | the durable presentation; absent members default to `idle`/null |
| `liveTurn` | bool | a live turn exists |
| `now` | int ms | pinned input |

Priority, first match:

1. `pendingApprovalCount > 0` → `alerting`.
2. An unexpired one-shot → that one-shot's `state`. The live presentation's one-shot is checked first,
   then the durable presentation's; "unexpired" is `now < endsAt`. The last live one-shot is still
   honoured after the live turn settles, until the durable projection catches up.
3. Base presentation: when `liveTurn` is true **and** `livePresentation` exists, its `fishState`; else
   `durablePresentation.fishState` (absent → `idle`). This is the live-over-durable precedence.
4. `running` → `base == idle ? working : base`. Running never coerces a non-idle state.
5. Not running **and** `idleSleeping` → `sleeping`.
6. Otherwise `base` (so a Bot with no presentation state is `idle`).

Pending approval outranks everything, including an unexpired one-shot. An expired one-shot is ignored.
Running outranks idle sleep, so a Bot with a live turn, a remote turn or a routine running is never
shown asleep. The views MUST NOT add a local precedence or a fallback state of their own; they pass
these inputs and render the result.

### 4.8 Activity line

Inputs: `awaitingTurn`, `runningTurnID`, `live`, `lineSuppressed`, `pendingDelta`,
`streamingText`, `liveBuffer`, `pendingApprovalCount`, `livePresentation?`, `runtimePresentation`.

`showsActivityLine` (`BotChatModel.swift:386-394`) = `awaitingTurn` **or** `runningTurnID != nil`
**or** (`live != nil && !live.ended && !lineSuppressed`). When false, the line is hidden.

`isStreamingNow` (`BotChatModel.swift:376-384`) = `pendingDelta` non-empty **or** `streamingText` non-empty **or**
(`live != nil` and `liveBuffer` trimmed non-empty). Committed paragraphs do not count.

`lineActivity` (`BotChatModel.swift:396-410`), first match:
1. `pendingApprovalCount > 0` → `(thinking, "", waiting, 0)`.
2. `isStreamingNow` → `(streaming, "", replying, 0)`.
3. factory = `live != nil ? livePresentation?.activity : runtimePresentation.activity`; if non-nil,
   return it.
4. fallback `(thinking, "", thinking, 0)`.

The **rendered** line is `BotHeaderPresence.line`, not `lineActivity` directly: `headerStatus` passes
`presence.line` to `BotActivityLine` (`BotChatPage.swift:216-231`). In `working` it is `lineActivity`;
in `problem`/`waitingForYou` it is the header's own static line; in `idle` it is nil. The vectors'
`activityLine` is computed from `header.line`.

Text and timing (`BotActivityPhrases.swift:295-451`):
- If `activity.detail` is non-empty, base = `detail`. Otherwise base = the category's phrase; for
  `thinking`, `reviewing`, `replying`, `generic` the rotation list has three entries (below); every
  other category has one primary phrase.
- `waiting` never rotates (`等你确认`). `replying` rotates `正在回复…`, `组织语言…`, `写回复中…`;
  `thinking` rotates `思考中…`, `整理思绪…`, `准备下一步…`; `reviewing` rotates `看看结果…`,
  `检查一下…`, `整理结论…`; `generic` rotates `处理中…`, `正在处理…`, `马上就好…`.
- `sustainedMinutes` = 0 when `startedAt == 0` or `now < startedAt` or elapsed `< 60_000`; else
  `max(1, elapsed / 60_000)`. A positive value appends ` · <N> 分钟`.
- Timing machine (`BotActivityLineState`, `:358-492`): a new activity is shown immediately from an
  empty state, at a random rotation start (the reference passes `Int.random`; fixtures/vectors use
  index 0). While an activity stays visible, a **different** activity arriving within 800 ms of the
  last display is held as the latest pending one and shown at `displayedAt + 800 ms`; the same
  activity refreshes the minute suffix/rotation and drops obsolete pending. A nil activity hides the
  line immediately. Rotation advances every 2 400 ms through the category list; `nextDeadline` is the
  earliest future rotation boundary and/or the next whole-minute boundary of `startedAt`, or nil.
- The line is 13/18 medium, one line, centered; no avatar (the header fish carries motion);
  shimmer/breathing only when not quiet; reduce-motion and `botPageActive == false` freeze animation
  and stop the clock (`BotActivityLine.swift:18-55,79-93`).

### 4.9 Drawer status

`BotDrawerRow.statusText` (`BotDrawer.swift:388-416`), first match:
1. `pendingApprovalCount > 0` → `<N> 项待审批`; colour = warning.
2. `isRunning == true`:
   - `activity != nil` and `activity.detail` non-empty → `detail`;
   - `activity != nil` and detail empty → `primaryPhrase(activity.category)` (§4.8 strings), **not**
     the fish fallback;
   - `activity == nil` → `thinking → 思考中`, `working → 执行工具中`,
     `speaking|streaming → 回复中`, `alerting → 等待确认`, `sleeping → 休息中`, anything else →
     `运行中`.
3. `lastMessageAt != nil` → relative time: `lastMessageAt == 0` or absent → `还没有消息`;
   `< 60 s → 刚刚`, `< 3 600 s → <N> 分钟前`, `< 86 400 s → <N> 小时前`, else `M月d日`
   (local calendar).
4. otherwise `还没有消息`.

Colour is warning only for pending approvals, otherwise secondary. `isRunning` is the projection's
truth (live turn, remote busy, or a routine run); the drawer never derives it from fish state.

Unread badge (`BotDrawer.swift:438-449`): shown iff `unreadCount > 0`; text `99+` when `> 99`, else the number;
accessibility `<N> 条未读`; id `bot.drawer.unread.<botID>`. Row id `bot.drawer.row.<botID>`; the
selected row carries the selected trait; accessibility text is `name，主 Bot，<status>，<N> 条未读`
with the main/unread parts present only when true.

### 4.10 Name cap

`BotAddValidation` (`BotDrawer.swift:35-73`): the limit is **60 UTF-16 code units**, not grapheme
clusters. `trimmed` trims whitespace/newlines. `problem(for:)` returns `名称不能为空。` for an empty
trimmed value, `名称最多 60 个字符，当前 <n> 个。` when `utf16.count > 60`, else nil. `capped(_:)`
walks `Character`s and appends a whole character only while `units + character.utf16.count <= 60`, so
emoji/combining sequences are never split. The dialogs cap on input/paste and disable 创建/保存 while
`problem != nil`; they do not render validation text. The model layer (`BotProfileStore.validateName`)
must reject the same two cases; a client-side cap never weakens the store rule.

### 4.11 Timers and page activity

| Timer | Value | Trigger/effect |
| --- | --- | --- |
| awaiting turn | 120 000 ms | armed by a local send when no turn is running; cleared by any live frame, turn start, send failure, stop, or expiry (`BotChatModel.swift:772-783`) |
| runtime notice | 6 000 ms | armed whenever `runtimeNotice` becomes non-nil; a repeated failure re-arms; cleared by the next send (`BotChatModel.swift:142-147, BotChatModel.swift:252-262`) |
| idle sleep | 60 000 ms | armed when no running turn/live/approval; any touch/send/turn start cancels it; expiry sets `idleSleeping` (`BotChatModel.swift:832-850`) |
| stream coalescer | 100 ms | at most one flush per 100 ms while text is pending; `finish` delivers the final text immediately and cancels (`BotChatModel.swift:9-52`) |
| live text flush | 80 ms | `textDelta` accumulates and flushes into the live buffer at most every 80 ms (`BotChatModel.swift:1067-1075`) |
| watch poll | 800 ms | one `watch` + `turnProcesses` + `presentation` per poll while the page is active (`BotChatModel.swift:933-956`) |
| activity min visible | 800 ms | §4.8 |
| activity rotation | 2 400 ms | §4.8 |
| minute suffix | 60 000 ms | §4.8 |

Page activity (`NativeShell.swift:379-382`): `botPageActive = selectedTab == .bot && sceneActive`.
While false, the page MUST cancel watch/live/line-clock/expiry/sleep tasks, drop `live`,
`livePresentation`, `reaction` and pending deltas, and resume with a durable read on becoming active
(`BotChatModel.setPageActive`, `:946-965`). The Bot tab is the first `HomeTab`
(`HomeTabBar.swift:9-21`); the app opens on `.tasks` (`NativeShell.swift:97`); selecting `.bot`
activates the page.

### 4.12 Info-page rules

- Memory tree: group by `scope` into `agent` (「本 Bot 的记忆」) and `user` (「所有 Bot 共享的记忆」);
  render directories/leaf documents in the order supplied; a document row shows file name, current
  version, update time and evidence count; a detail shows content, author label, evidence and the
  version list. `forget` removes only the live version; `eraseDocument`/`erase`/`eraseShared` are
  physical and require explicit scope text + confirmation.
- Maintenance: the switch defaults off; the last-batch card shows status/time/changed count/names and
  checks result, with paths/failure code/token counts behind 查看详情. Daily budget is displayed as a
  percentage once; total 0 renders `—`. Rollback is offered only while `canRollback`.
- Routines: main row uses human-readable schedule/timezone/delivery/creator/result/next due/deferred
  values; raw ids, IANA zone, run id and effect records stay in 详情. A `started` run shows
  「取消运行」; `needs-reconciliation` shows exactly one reconciliation block with 「确认完成」 and
  「重试」. Free-text criteria/constraints are never rewritten or summarized; if they contain prompt
  markers the main row says 原文包含执行提示 and the original stays in 详情.
- Grants: only `scope != once`; each row can revoke; unknown state shows the read failure, not zero.
- Approvals: human-readable parameter summary + actual decision; never raw ids/digests/secret values.
- Presence: `foreground` = app active; `backgroundKeepAlive` = not active with the silent-audio
  keep-alive; else `scheduledNotification`. The scheduled count is the number of notifications the
  host actually registered, not the routine count. Deferred rows come only from `quiet_defer`.
- Disturbance: `dnd` + quiet start/end (`HH:mm`, default 23:00–08:00), persisted immediately to
  `phone-dsh.bot.proactive-settings.v1`; no save button; a read failure keeps the old value and shows
  the error.

### 4.13 Deep link resolution

`BotDeepLink` accepts only the §2.6 form. Row destination: if the link's `botID` is not this page's
Bot, or the row id is not in `visibleRows`, report `这条消息不可用或已过期。` and do **not** scroll or
switch sessions; otherwise set `scrollRequestID = rowID`. A routine destination is not a chat row: the
hub selects the Bot and opens the info routine section and highlights the routine; an unknown/deleted
routine shows unavailable and does not jump to another page. `phonedsh://bot/main/...` resolves
`main` through the roster's main pointer, never as a literal id
(`BotProductionPage.swift:105-125`).

## 5. Localized strings and phrase data

`strings.json` and `activity-phrases.json` are the normative data for the strings named by this
contract. Every entry carries `source` = `File.swift:line` and `expect`, a literal snippet that must
still occur on that line; `check_bot_ui.py` resolves every anchor. A probe-app path is relative to
`examples/probe-app/PhoneDSHProbe/Bot/`; an entry whose `source` contains `/` (for example
`Sources/PhoneDSHBot/UI/BotChoiceCardUI.swift:56`, where the shared choice-card copy lives) is
repo-relative. The source is evidence, not authority: **this file and the JSON values are the
contract**; changing a value is a contract change, and the Swift literal must change with it.

`activity-phrases.json` freezes the complete tool → category/phrase table (70 entries), the 12
categories, primary and rotation phrases, work-style mapping, text-cleaning policy (trim; strip
trailing `。！？!?；;，,、.…`; cap 20 characters including `…` → 19 + `…`), target policy (first
matching key; arrays use the first non-empty string; URL target renders the host without `www.`; path
target renders the last `/`-or-`\` component; cap 42 → 39 + `…`), reviewing text, and the §4.8 timing
constants. A model-written `description|summary|label` always wins over the table phrase but never
changes the category.

## 6. Fixtures for Android round 2

`golden/fixtures.json` is the pure-data export of `BotFixtures.swift`. It pins `now` and all
timestamps; the Swift fixture uses `Date()` for some relative values, so the export freezes the
instant it was transcribed and says so. Each exported scenario is `{scenario, rows, notes?}` and is
validated against `schema/row.schema.json`; `composerAttachments` and `composerLongDraft` also carry
their draft data. Imperative scenarios (live frames, model actions, view-only root wiring) are listed
in `fixtures.json.skipped` with the exact reason; they are **not** silently dropped. The fixture file
is a convenience for round 2, not conformance evidence.

## 7. Vectors and checker

- `golden/ui-state-vectors.json` — input `{context, rows, actionStates, dismissedCardIDs,
  autoDeclinedApprovalIDs, answeredOptionIDs, checklistProgress, pendingApprovalCount, running,
  runtimePresentation, livePresentation, live, runningTurnID, awaitingTurn, lineSuppressed,
  idleSleeping, streaming, problem, now, drawer}` → expected `{visibleRowIDs, displayRowIDs,
  mutedCardIDs, settledRowIDs, settlements, pendingApprovalCount, needsAttentionCount,
  followingCount, fishState, header, lineActivity, activityLine, drawerStatus, unreadBadge}`. Cases
  are labeled `source` with the Swift lines that define the expectation; the projection cases also
  carry `covers` labels, and the checker requires every §4.7 priority branch. Settlement cases cover
  the durable `superseded` status winning over a pending tap, the `.pending` card staying full, the
  durable `answered` status winning over a local tap, `question`/`steps` **not** being muted by the
  before-the-last-user-text heuristic, and `checklist` keeping that mute. `input.pendingApprovalCount`
  must equal the count derived from rows/actionStates. `now` is pinned.
- `golden/ui-state-vectors.json#intentCases` — `{action, cardKind, state, accepted}`; recomputes the
  §3.1 retry policy. It covers an absent key, a failed dismiss retry, pending/accepted rejection and
  the steps-card refusal.
- `golden/card-parse-vectors.json` — body → `{parses, kind?, choices?, steps?, checklist?, links?,
  attachments?}`; includes fail-closed cases.
- `golden/activity-phrase-vectors.json` — tool name + arguments → `{category, text}`; includes
  `mcp__` prefix, model-description override/trim/cap, target path/URL cap, unknown tool, hidden
  `FishAction` (no line), reviewing text, and rotation/minute samples.
- `golden/invalid-vectors.json` — values that MUST be rejected, each with `validator`
  (`schema:row`, `schema:presentation`, `schema:info`, `schema:intents`, `rule:user-action`,
  `rule:action-retry`, `rule:name-cap`, `rule:deep-link`) and a `reason`.
- `tools/check_bot_ui.py --root .` validates every schema/vector/data file, recomputes the expected
  derived values including every fish-lifecycle priority branch and the retry policy, checks the
  60-unit cap, deep-link parser, and every `source` anchor. Its unittest lives in
  `tools/test_check_bot_ui.py` and mutates the projection/retry expectations, so a checker that
  stopped recomputing them fails.

## 8. Conformance status

| End | Status | Evidence |
| --- | --- | --- |
| Python contract checker | implemented | `tools/check_bot_ui.py`, `tools/test_check_bot_ui.py` |
| iOS projection (pure function) | implemented | `Sources/PhoneDSHBot/UI/BotUIProjection.swift`; `Tests/PhoneDSHBotTests/UI/BotUIProjectionVectorTests.swift` reads `golden/ui-state-vectors.json` and runs every projection/retry vector through the real Swift function. The head-slice golden is read by the same test class. |
| iOS app wiring | **NOT_RUN** | `BotRuntimeUnit.statusSnapshot`, `BotChatModel.fishState` and `BotFishRenderer` are app code (`examples/probe-app/PhoneDSHProbe/Bot/**`); no SwiftPM target compiles them. The app build is a compile check, not vector conformance: `scripts/ci/bot-ui/capture.sh` is an XCUITest capture app that does not read these JSON vectors. |
| Android | not started (wave 4 round 2) | `android/bot` / `android/lib/.../ui/bot` do not exist yet |

## 9. Contract change requests

Both CCRs below were decided by the owner in `PC-20261112-android-bot-w4` §7. They stay in the
record with their decision; the clauses above are now normative.

```
CONTRACT CHANGE REQUEST
Contract: P09 @ PC-20261112-android-bot-w4 (C4)   Clause: ui/v1/bot/ui-state.md §4.7
Status: DECIDED (PC-20261112-android-bot-w4 §7, UI-1)
Problem: The page and the roster derived the fish lifecycle with different functions
  (BotChatModel.swift:347-364 vs BotRuntimeUnit.swift:278-301). They disagreed on
  idle->working coercion while a turn/remote/routine is running, on whether
  remoteBusy/routineRunning participate, on durable-vs-live precedence, on the
  unexpired oneShot fallback, and on the idleSleeping guard. Both draw the same
  Bot avatar on the same screen, so the divergence is visible, not cosmetic.
Decision: One shared lifecycle projection with explicit inputs
  {pendingApprovalCount, running (liveRunning|remoteBusy|routineRunning), idleSleeping,
  livePresentation?, durablePresentation?, liveTurn?, now} and the §4.7 priority:
  pending approval -> alerting; unexpired one-shot; live over durable presentation;
  running coerces idle to working; idleSleeping -> sleeping; else idle.
  `BotRuntimeUnit` computes it and `BotChatModel` consumes the same function.
Affects: iOS Bot page header/empty state/roster drawer; Android B7b; future Harmony.
```

```
CONTRACT CHANGE REQUEST
Contract: P09 @ PC-20261112-android-bot-w4 (C4)   Clause: ui/v1/bot/ui-state.md §3.1
Status: DECIDED (PC-20261112-android-bot-w4 §7, UI-2)
Problem: The failed-action retry policy was inconsistent in the reference view.
  `BotChatModel.answer`/`beginApproval` accepted a key whose state was `.failed`, but
  `BotChatModel.dismiss` accepted only an absent key. A failed `cardDismiss` therefore
  left the question card permanently undismissable until the row identity changed; the
  UI showed the failure as a runtime notice.
Decision: A failed `dismiss` is retryable like `answer` and `approval`; all three use
  `state == nil || state == .failed`. Pending and accepted keys stay ignored.
Affects: iOS BotChatPage question card; Android B7b question card.
```

## 10. Acceptance

```bash
python3 spec/ui/v1/bot/tools/check_bot_ui.py --root .
python3 -m unittest discover -s spec/ui/v1/bot/tools -p 'test_*.py'
python3 spec/ui/v1/tools/ui_check.py --root .
python3 spec/ui/v1/tools/extract_ios_pages.py --root . --check
bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance
```
