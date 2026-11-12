<!-- SPDX-License-Identifier: MIT -->
# Android Bot runtime port plan (P25/P26/P27 and host seams)

Status: **plan for review — documents only, nothing implemented.**
Date: 2026-11-12 · Worktree branch `dsh/20261111-200540/02-03-bot-port-plan`, base `56e7b6ce`.
Owner decision already taken: port the Bot runtime to **Kotlin**, not KMP; both ends stay native and
share only the contract, the goldens and the acceptance commands (`docs/parity/android-parity-roadmap.md:9-11`).
This document is the port plan; the concrete spec additions it depends on are in
[`android-bot-spec-deltas.md`](android-bot-spec-deltas.md).

**Read this first:** §0 verdict and §2 status matrix. A subsystem marked `spec-ready` means a Kotlin
implementer can reproduce the observable behaviour from `spec/**` alone, without reading Swift. `iOS
source is reference and provenance, not authority` (`spec/README.md:27-29`): where Swift and the owning
contract disagree, the contract wins and a delta/CCR is raised instead of copying Swift.

## 0. Verdict

1. **Android has no Bot runtime at all.** `android/lib/src/main/kotlin/com/phonedsh/ui/nav/HomeTabBar.kt:6-7`
   says so in code; `spec/bot/v2/README.md:15` says Android and HarmonyOS have no implementation end.
   The roadmap puts the Bot runtime in wave 4 and gates it on “Bot spec 補齊後凍結”
   (`docs/parity/android-parity-roadmap.md:25`), with the capability row still “無 / 不夠”
   (`docs/parity/android-parity-roadmap.md:33`).
2. **The reference implementation is large but bounded.** `Sources/PhoneDSHBot/**` is 83 Swift files,
   1,009,828 bytes (≈986 KiB, 22,504 lines). The app-side `examples/probe-app/PhoneDSHProbe/Bot/**`
   is 36 Swift files, 619,160 bytes (≈605 KiB, 14,554 lines; 3,326 of those are `Bot/Fish`).
   The 93 Swift test files under `Tests/PhoneDSHBotTests/**` are 15,407 lines and are the behavioural
   oracle to be mirrored, not a port target.
3. **No subsystem is `spec-ready` in the strict sense.** 15 are `spec-partial`, 2 are `spec-missing`
   (§2). The envelope, row, memory-fact, wake and tool-catalog *shapes* are frozen with goldens; the
   state machines, timers, persistence layouts, retry/error rules and cross-process identities that
   make a port deterministic are mostly not.
4. **Two P25 contract defects must be resolved before B1** (CCR-1 and CCR-2 in the deltas document):
   required-null envelope members are omitted by Swift's synthesized `Codable`, and
   `authz.grant_snapshot` is required by `spec/bot/v1/README.md:66-67` but absent from the event-type
   enum. A Kotlin implementation written to the schema would produce different stored bytes from iOS.
5. **The Android host is missing five seams, not a Bot module.** The Bot runtime needs a second
   loopback listener, the P16 egress variable and placeholder semantics, a notification delivery with
   a deep link, a module-map row for `PhoneDSHBot`, and a selected-Bot preference key. Those are
   P05/P16/P08/P12/P18 changes owned outside this plan (B0, §10).
6. **Proposed shape:** one new Android library `:bot` (`com.phonedsh.bot.*`) for everything that is not
   pixels; the Bot HTTP listener stays in `:net` behind a `BotMcpServing` interface; the Bot pages,
   cards and fish canvas stay in the published `:lib` AAR (`com.phonedsh.ui.bot.*`); `:app` only wires.
   No KMP, no Room, no SQLDelight, no second JSON stack.

## 1. How the numbers and the citations were produced

- Sizes are `wc -c`/`wc -l` over the exact paths named in each subsection, measured in this worktree at
  `56e7b6ce`. The task brief's “~986 KB / 83 files” and “~605 KB” match the byte counts above; `du`
  rounds to 1.1M/680K because of block allocation.
- “Spec coverage today” names the owning file and the frozen cases. Golden case counts were read from
  the JSON: `event-envelope.json` 2 valid / 4 invalid, `event-envelope.phone.json` 2 valid / 1 invalid,
  `memory-fact.json` 4/2, `memory-injection.json` 2/2, `memory-recall.json` 1/0,
  `wake-routine.json` 8 valid keys / 3 invalid, `held-inbox.json` 4/2,
  `held-inbox.phone.json` 2/1, `watchdog.json` 3/1, `llm-ledger.json` 15/2,
  `tool-catalog.json` 2/6, `card-payload.json` 12/2, `card-payload.phone.json` 6/2,
  `row-projection.json` 20/1, `row-protocol.json` 5/2, `row-protocol.phone.json` 3 valid / 4 invalid
  actions / 1 projection, `mcp-egress.phone.json` 17/25, `volatile-context.json` 2/3,
  `fish-director.json` 1 vector (many steps) / 1 invalid, `bot-attachments.json` 4 parse / 8 kindFor.
  **Count convention:** when a golden’s `valid` is an object (not a list), `a/b` means “a top-level
  keys in one valid vector / b invalid cases”, not “a valid cases”. This applies to
  `memory-injection`, `tool-catalog`, `model-purpose-policy`, `context-profiles`, `watchdog`,
  `fish-director`, `volatile-context` and `wake-routine`; a list-valued `valid` is a case count.
- Spec status is `target` in both Bot READMEs (`spec/bot/v1/README.md:5`,
  `spec/bot/v2/README.md:5`), while several change records marked `implemented` claim Swift runtime
  tests (`docs/protocol-changes/PC-20261109-bot-team-tools.md:5-6`,
  `docs/protocol-changes/PC-20261111-bot-agent-comm-envelope.md:5-6`). That status mismatch is
  CCR-6; this plan does not use “implemented” as a synonym for “specified”.
- Every statement about Swift behaviour is a read of the named file and line range. Where a value is
  copied from Swift only to describe the gap, it is marked as a delta input and **not** proposed as a
  Kotlin constant until the delta is frozen.
- Path convention: a bare `BotX.swift` means `Sources/PhoneDSHBot/BotX.swift`; a subdirectory prefix
  (`Store/`, `Journal/`, `MCP/`, `Rows/`, …) is relative to `Sources/PhoneDSHBot/`. App-side names
  (`BotChatModel.swift`, `BotRuntimeComposition.swift`, `Fish/…`) are under
  `examples/probe-app/PhoneDSHProbe/Bot/`. Android paths start with `android/`; spec paths with
  `spec/`; change records with `docs/protocol-changes/`.

## 2. Subsystem status matrix

| # | Subsystem | iOS files / size | Spec today | Status | First checkpoint |
| --- | --- | --- | --- | --- | --- |
| S1 | Store / Journal / event envelope (P25) | 8 files, 1,767 lines, 78 KB | envelope schema + 2/4 + phone 2/1; v1 §1, §8.1 | `spec-partial` | B1 |
| S2 | Memory (P26 v2) | 8 files, 2,796 lines, 105 KB | fact/injection/recall schemas + 4/2, 2/2, 1/0; v2 §1 | `spec-partial` | B2 |
| S3 | Routines (P26 v2) | 7 files, 2,190 lines, 105 KB | routine schema (loose `run_state`); wake golden 8/3; v2 §2 | `spec-partial` | B3 |
| S4 | Wake / held inbox (P26 v2) | 4 files, 825 lines, 38 KB | held-inbox 4/2 + phone 2/1; wake-routine heldBlock; v2 §2, §2.1 | `spec-partial` | B3 |
| S5 | Proactive (P26 v2) | 6 files, 811 lines, 35 KB | prose only, v2 §3; no decision/settings schema | `spec-missing` | B4 |
| S6 | Watchdog / context lint (P26) | 6 files, 1,469 lines, 62 KB | watchdog 3/1, context-profiles 2/1, context-lint 1/0; v1 §6 | `spec-partial` | B4 |
| S7 | MCP endpoint / catalog / cards / volatile (P05/P26) | 11 files, 4,973 lines, 243 KB | mcp-endpoint.md; catalog 2/6, card 12/2 + 6/2, volatile 2/3 | `spec-partial` | B5 |
| S8 | Authz / grants / approval (P26) | 7 files, 1,527 lines, 75 KB | v1 §2.3 prose; approval-patterns 5/1; tool-effects 21/2 + phone | `spec-partial` | B5 |
| S9 | Gateway / tokens / attribution / session credentials (P05/P26) | 3 files, 652 lines, 30 KB | mcp-endpoint.md §1.1, §3; mcp-egress 17/25 | `spec-partial` | B5 |
| S10 | Team / SendToAgent / CreateTeammate (P26/P27) | 2 files, 738 lines, 32 KB | v1 §1.1; catalog.phone team; held-inbox agent-held; agent.comm 2/1 | `spec-partial` | B6 |
| S11 | Rows / UserAction / projection / display (P27) | 7 files, 2,357 lines, 107 KB | row/row-batch/row-projection/user-action/action-result + goldens | `spec-partial` | B7a |
| S12 | Profile / roster (P26) | 3 files, 1,068 lines, 43 KB | bot-profile vector schema/golden (seed + roster rules) | `spec-partial` | B7a |
| S13 | Attachments (P27) | 4 files, 248 lines, 11 KB | bot-attachments limits/parse/kindFor; user-action `attachments` | `spec-partial` | B7a |
| S14 | Ledger / model purpose (P26) | 3 files, 392 lines, 16 KB | llm-ledger 15/2; model-purpose 2/1; v1 §6 | `spec-partial` | B4 |
| S15 | Avatar / FishDirector / reactions (P26/P27) | 3 files, 626 lines, 27 KB | fish-director 1 vector/1 invalid; catalog.phone fish; PC-fish-react mapping | `spec-partial` | B8 |
| S16 | Bot UI pages / roster drawer / chat model (P09/P27) | 29 files, 11,228 lines, 470 KB | `spec/ui/v1/pages/bot-{chat,drawer,info}.md` (`target`) | `spec-partial` | B7b |
| S17 | BotFish renderer + assets (P09/P26) | 7 files, 3,326 lines, 134 KB + 2.4 MB assets | v1 §7 prose only; no renderer model | `spec-missing` | B8 |

Totals: 17 subsystems, 0 `spec-ready`, 15 `spec-partial`, 2 `spec-missing`; 119 runtime Swift files
(83 runtime + 36 app, of which 7 are Fish), 37,058 lines of Swift runtime/UI; ~2.4 MB of fish assets.

## 3. Per-subsystem analysis

Each entry answers: what the iOS code owns, where it persists, what it does outside the process, what
the contract freezes today, what it must add, and whether a Kotlin implementer can start.

### 3.1 S1 — Store / Journal / event envelope (P25) — `spec-partial`

**iOS files.** `Sources/PhoneDSHBot/BotEvent.swift` (4,528 B), `BotEventLog.swift` (3,513 B),
`Store/SQLiteDomainStore.swift` (16,859 B), `Store/SQLiteDomainStore+UserAction.swift` (3,612 B),
`Journal/BotEventEnvelopeCodec.swift` (8,519 B), `Journal/SQLiteDomainStore+BotEventLog.swift` (7,041 B),
`Journal/BotEffectOutbox.swift` (31,149 B), `Journal/BotEffectInbox.swift` (3,113 B). 1,767 lines total.

**Responsibilities.** One append-only durable log with store-assigned `commitSeq` and `eventId` dedupe;
a durable/ephemeral type split; canonical JSON payloads; per-event validation with frozen error codes
(`BotEventEnvelopeCodec.swift:72-157`); durable batch insert with contiguous `commitSeq`
(`SQLiteDomainStore+BotEventLog.swift:101-165`); an at-least-once effects outbox with leases, bounded
retry, dead-letter and `needs_reconciliation` (`BotEffectOutbox.swift:5-13`, `:117-193`, `:284-353`);
an inbox table for receiver-side dedupe (`SQLiteDomainStore.swift:267-277`); and a v2 nonce table used
by user actions (`SQLiteDomainStore.swift:278-285`).

**Persistence — exact.** `Application Support/PhoneDSHBot/domain.sqlite` plus `-wal`/`-shm`
(`SQLiteDomainStore.swift:320-324`). The database is opened with WAL, `synchronous=FULL`,
`foreign_keys=ON`, a 5 s busy timeout, `PRAGMA quick_check`, and `user_version=2`; a version above 2 is
refused (`SQLiteDomainStore.swift:73-90`). Tables: `bot_events(commit_seq INTEGER PRIMARY KEY,
event_id TEXT NOT NULL UNIQUE, event_type TEXT NOT NULL, payload BLOB NOT NULL)` with BEFORE UPDATE
and BEFORE DELETE triggers that abort (`:223-236`); `bot_effects` with 26 columns including lease,
attempt, generation and reconciliation fields (`:237-264`); `bot_effect_inbox` keyed by
`(receiver, effect_key, generation)` (`:267-277`); `bot_user_action_nonces` keyed by
`(bot_id, nonce)` with `event_id` unique and a foreign key to `bot_events` (`:278-285`). Event payloads
are encoded with sorted keys and no slash escaping (`BotEventEnvelopeCodec.swift:159-164`). Ephemeral
events live in a 256-entry ring and are never written (`SQLiteDomainStore.swift:295-296`,
`SQLiteDomainStore+BotEventLog.swift:9-16`). The default outbox lease is 30,000 ms
(`SQLiteDomainStore.swift:300-305`). Retry delay is exponential only for `network-idempotent`:
`min(1000 * 2^(attempt-1), 300000)` ms, otherwise 0 (`BotEffectOutbox.swift:534-540`); default
`maxAttempts` is 5/2/1 by retry policy (`BotEventLog.swift:49-56`).

**External effects.** The store itself has no network/file side effects beyond SQLite. The outbox is
the host-wide “do it later” lane; the app registers handlers by `kind` and runs a 250 ms tick
(`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeEffects.swift:65-140`). Routine delivery is the first
registered handler (`BotRuntimeEffects.swift:9-62`). Durable events are also the replay source for
memory, routines, grants, proactive accounting and rows.

**Spec coverage today.** `spec/bot/v1/event-envelope.schema.json` (type enum, required members,
principal/origin closed shapes), `golden/event-envelope.json` (2 valid / 4 invalid),
`golden/event-envelope.phone.json` (agent.comm 2 valid / 1 invalid), `spec/bot/v1/README.md:13-16`
(commitSeq authority, schema v2, nonce table), `:64-69` (grant snapshot), `:178-183` (merged golden
loading), and the P25 registry row (`spec/README.md:86`).

**Missing spec.** (a) The exact SQLite schema/pragmas are prose only; table/column names, triggers and
`user_version` are not normative. (b) Lease TTL, retry policy names, backoff formula, terminal-state
rules and error classes are absent. (c) The ephemeral envelope is undefined: the schema requires
`commitSeq` but the codec forbids it on ephemeral types (`BotEventEnvelopeCodec.swift:124-131` vs
`spec/bot/v1/event-envelope.schema.json#/required`). (d) `eventId` namespaces used for idempotency
(`evt:`, `routine-snapshot:`, `wake-inbox:`, `authz-snapshot-`, `created:`) are code-only. (e) The
`{botId, document}` snapshot envelope used by routines/wake/tasks is code-only
(`Routines/DurableSnapshot.swift:5-19`). (f) Required-null members are omitted by Swift and present in
the golden (CCR-1). (g) `authz.grant_snapshot` is required by §2.3 but not in the enum (CCR-2).

**Status.** `spec-partial`. The envelope shape is implementable; the store/outbox/identity semantics
are not. **Blocked before B1 on D1, D2 and CCR-1/CCR-2.**

### 3.2 S2 — Memory (P26 v2) — `spec-partial`

**iOS files.** `Memory/BotMemory.swift` (22,287 B), `BotMemoryFact.swift` (13,041 B),
`BotMemoryFactStore.swift` (3,854 B), `BotMemoryInjection.swift` (19,393 B),
`BotMemoryRecall.swift` (14,229 B), `BotMemoryReplayFeed.swift` (6,043 B),
`BotMemoryTokenizer.swift` (5,694 B), `SQLiteBotMemoryFactStore.swift` (20,473 B). 2,796 lines.

**Responsibilities.** Fact normalization (fold to one line, 2,000 code-point cap), scope/tier/source
validation, write/forget/erase with tombstones, per-Bot agent scope vs shared user scope, deterministic
injection rendering with per-scope budgets, BM25 + recency + importance recall over CJK tokenization,
and event-sourced replay with a shared incremental feed.

**Persistence — exact.** Facts are **not** stored in a `facts` table. The authoritative representation
is the durable event log: `memory.written` and `memory.forgotten` payloads are replayed into an
in-memory `ReplayState` (`SQLiteBotMemoryFactStore.swift:44-48`, `:305-390`, `:425-460`). The replay
page size is 500 and at most 256 skipped event IDs are retained (`:47-48`). Historical events with no
`botId` are read as `"main"`; user-scope facts are shared (`SQLiteBotMemoryFactStore.swift:100-125`).
The only filesystem string is the prompt-visible root: `<dataRoot>/agents/<botID>/memory` and
`<dataRoot>/memory-user` (`BotMemory.swift:555-567`). Live facts are held in the store actor; a restart
rebuilds them from the log.

**External effects.** None directly; the memory tools write durable events through the MCP runtime, and
the injection text is passed to the DSH prompt. `memory.forgotten` is the only deletion record; erase
must not resurrect a fact.

**Spec coverage today.** `spec/bot/v2/memory-fact.schema.json` + golden 4/2;
`memory-injection.schema.json` + golden 1 valid vector / 2 invalid (the valid vector freezes the entire Chinese injected text
verbatim, including `<FIXTURE_ROOT>` paths); `memory-recall.schema.json` + golden 1/0;
`spec/bot/v2/README.md:22-26` (single-line facts, verbatim injection, CJK + BM25 + recency +
importance, non-user-turn cannot write user/profile); v1 §4.1 turn-origin table and
`golden/turn-origin.phone.json` (9 valid / 32 invalid).

**Missing spec.** (a) Normalization is code-only: `foldFactLines`, 2,000 code-point fact cap,
80-code-point condition cap, single-line rule and the exact truncation/error strings
(`BotMemoryFact.swift:230-265`, `:286-345`). (b) The English injection template is not frozen; only the
Chinese case is (`BotMemoryInjection.swift:112-206`). (c) Budget arithmetic and clipping rules
(`2,000/1,000/1,500/4,000`, 12 inline log facts, minimum 3, per-scope shrinkage) are code-only
(`BotMemoryInjection.swift:18`, `:44-45`, `:47-110`). (d) Recall scoring is code-only: weights
0.72/0.18/0.10, 180-day half-life, BM25 k1=1.2/b=0.75, saturation 3.0, minimum matched IDF 0.85,
small-corpus threshold 8, exact-match floor 0.95, tokenizer/prefix expansion
(`BotMemoryRecall.swift:110-119`, `:310-341`). (e) Event payload fields for `memory.written` /
`memory.forgotten` and the replay conflict/skip rules are not schema'd
(`SQLiteBotMemoryFactStore.swift:335-390`). (f) Scope downgrade and tombstone semantics are prose only
(`spec/bot/v2/README.md:24`). (g) `memory.imported` is in the envelope enum but has no producer/contract
in v2.

**Status.** `spec-partial`. **Blocked before B2 on D10.**

### 3.3 S3 — Routines (P26 v2) — `spec-partial`

**iOS files.** `Routines/RoutineMachine.swift` (33,311 B), `RoutineModels.swift` (23,850 B),
`RoutineSchedule.swift` (20,687 B), `RoutineScheduler.swift` (16,308 B),
`RoutineSchedulerTypes.swift` (6,484 B), `RoutineStore.swift` (3,813 B), `DurableSnapshot.swift` (758 B).
2,190 lines.

**Responsibilities.** Routine CRUD and validation, schedule math (interval/daily/weekly/cron with IANA
timezone), quiet-hours deferral, due-tick scheduling, overlap skip, run lease/attempt, crash recovery
with idempotent retry or `needs-reconciliation`, delivery creation and leased delivery to the held
inbox/DSH, and automation status rendering.

**Persistence — exact.** A full `RoutineDocument {version:1, routines:[Routine], deliveries:{key:
RoutineDelivery}}` is written as the `data` of a `routine.defined` / `routine.updated` /
`routine.deleted` event, wrapped as `{botId, document}` (`RoutineStore.swift:49-97`,
`DurableSnapshot.swift:5-19`, `RoutineModels.swift:538-548`). The document is reconstructed by replaying
those event types in `commit_seq` order and taking the latest snapshot (`RoutineStore.swift:50-68`).
`runState`, `quietDefer`, `lastSkip`, `lastResult`, `nextRunAt`, `crashRetry` and the delivery map are
inside that snapshot. There is no separate routines table.

**External effects.** The scheduler calls `RoutineResultSink` to enqueue a `routine-delivery` effect;
the effect runner appends `conversation.automation_run` and acks (`BotRuntimeEffects.swift:9-62`). It
also uses the DSH remote to run the routine turn and the held inbox to stage/commit/revert results.

**Spec coverage today.** `spec/bot/v2/routine.schema.json` fixes the record fields but leaves
`run_state`, `last_result` and `last_skip` as unconstrained objects; `golden/wake-routine.json`
freezes the full Chinese wake prompt (8 valid keys / 3 invalid) plus quiet reply, held block,
`<automation_status>` and delivery flags; `spec/bot/v2/README.md:30` freezes the scheduling
invariants (quiet defer not drop, urgent needs a reason, queue while WebContent is unavailable, missed
runs caught up once).

**Missing spec.** (a) The run state machine: statuses, `started → terminal`, lease owner/TTL,
overlap, `needs-reconciliation`, `crashRetry`, resolution `retry|acknowledge`
(`RoutineModels.swift:44-61`, `RoutineMachine.swift:189-232`, `:249-315`, `:325-425`). (b) Scheduler
timers: 5,000 ms tick, 600,000 ms run timeout, 5,000 ms cancel grace, lease TTL
`runTimeout + grace + 60,000` (`RoutineScheduler.swift:44-45`, `:155`, `:177`, `:219-232`). (c) Skip
and deferral rules, including the `overlap` record and quiet-window arithmetic
(`RoutineScheduler.swift:114-166`). (d) Delivery claim lease 60,000 ms and `pending/delivering/
delivered/failed` transitions (`RoutineMachine.swift:442-470`, `RoutineModels.swift:424-470`). (e) Cron
parser semantics and the 5-minute minimum interval vs the 1-minute `everyMinutes` schema floor
(`RoutineSchedule.swift:5-165`, `:377`; `routine.schema.json#/properties/schedule/everyMinutes`).
(f) Snapshot event data shape/wrap and the document version rule (code-only). (g) The exact
`<automation_status>` text is frozen by golden for one case, but the “unreadable routine status”
fallback is code-only (`RoutineWake.swift:176-210`).

**Status.** `spec-partial`. **Blocked before B3 on D9.**

### 3.4 S4 — Wake / held inbox (P26 v2) — `spec-partial`

**iOS files.** `Wake/WakeInbox.swift` (18,903 B), `Wake/RoutineWake.swift` (11,652 B),
`Wake/BotTurnOrigin.swift` (4,849 B), `Wake/DeviceTaskResultNotice.swift` (2,827 B). 825 lines.

**Responsibilities.** Durable held queue with pending/staged states, request-id dedupe, bounded size,
staging/commit/revert/recover around a prompt, held-block rendering for routine/subagent/card/device/
agent items, escaping of every non-host field, the routine wake prompt and automation status, the
turn-origin prefix table, and the at-most-once device-task-result notice.

**Persistence — exact.** A full `WakeInboxDocument {version:1, items:[WakeInboxItem]}` is written as
the `data` of a `comm.inbound` / `comm.outbound` / `comm.reply` event, wrapped as `{botId, document}`
(`WakeInbox.swift:95-103`, `:147-190`). Max 200 items; stage at most 20; item text ≤1,200 characters
(`WakeInbox.swift:213-217`, `:60-90`). Staged items carry `stagedAt` and `stagedKey`; recovery resets
all staged items to pending (`:246-317`). Dedupe is by `requestId` (`:219-225`).

**External effects.** Staged items are prepended to the next DSH prompt and committed on success or
reverted on failure (`BotDSHRemoteRuntime.swift:201-247`); routine results are delivered as held items
or, for `interrupt`, through the proactive path.

**Spec coverage today.** `spec/bot/v2/held-inbox-item.schema.json` (oneOf agent-held vs
device-task-result) + `held-inbox.json` 4/2 and `held-inbox.phone.json` 2/1;
`wake-routine.json` freezes the routine wake text and a `heldBlock` containing `[routine]` and
`[subagent]` lines; `spec/bot/v2/README.md:28-34` and §2.1 (escaping rules, all five branches,
1,200-char subagent excerpt).

**Missing spec.** (a) The inbox state machine and recovery rule; the 200/20 limits; staging key format
and commit/revert event IDs (`WakeInbox.swift:213-317`). (b) Exact bullet grammar for `[agent]`,
`[card-dismissed]` and `[device-task]`; only `[routine]`/`[subagent]` appear in the frozen held block
(`WakeInbox.swift:326-384`). (c) The hidden-wake prompt template
`[SAND_HIDDEN_PROMPT][subagent] ...` and `[SAND_HIDDEN_PROMPT][SAND_TRUSTED_AUTOMATION_PROMPT]` is
code-only (`BotDSHRemoteRuntime.swift:534-540`, `:623-631`; `RoutineWake.swift:96-110`). (d) The
device-task-result at-most-once enqueue point and `requestId` derivation
(`DeviceTaskResultNotice.swift:13-60`; `BotRuntimeComposition.swift:472-526`). (e) `held:` prompt
prefix and prompt request-id derivation (`BotTurnOrigin.swift:22-120`). (f) The exact English block
header/grammar (only Chinese is frozen in the golden).

**Status.** `spec-partial`. **Blocked before B3 on D8.**

### 3.5 S5 — Proactive (P26 v2) — `spec-missing`

**iOS files.** `Proactive/ProactiveEngine.swift` (13,865 B), `ProactiveModels.swift` (6,514 B),
`ProactivePolicy.swift` (2,797 B), `ProactiveSettings.swift` (4,000 B),
`ProactiveSources.swift` (6,047 B), `UNUserNotificationProactiveDelivery.swift` (1,890 B). 811 lines.

**Responsibilities.** Candidate admission (only `interrupt`, non-quiet, successful routine/terminal
failure), DND and quiet-hour exceptions for explicit reminders, a per-Bot frequency fuse
(900,000 ms / 4), mode `off|would|on`, delivery to a `ProactiveDelivering`, a durable
`proactive.considered` record per decision, and fuse reconstruction from the durable log.

**Persistence — exact.** Decisions are durable `proactive.considered` events
(`ProactiveEngine.swift:213-225`) with `data` fields including `kind`, `botId`, `mode`, `decision`,
`fuseRecorded`, and the notification/dedupe fields. `restoreAccounting()` scans the durable log in
500-event pages inside the fuse window and replays `did`/`would` into the in-memory policy
(`ProactiveEngine.swift:69-130`). Settings are **not persisted by this module**: `ProactiveSettings` is
an injectable struct with defaults 23:00–08:00 and `.would` (`ProactiveSettings.swift:11-37`); no
production store or UI was found (grep over `Sources/` and `examples/probe-app/PhoneDSHProbe` finds
only tests and the scheduler default).

**External effects.** A notification through `ProactiveDelivering`, with a stable `dedupeKey` and the
iOS deep link `phonedsh://bot/<botID>/row/<rowID>` (`ProactiveModels.swift:73-125`); the iOS
`UNUserNotificationCenter` adapter posts it (`UNUserNotificationProactiveDelivery.swift:25-80`).

**Spec coverage today.** `spec/bot/v2/README.md:50-72` is prose: the three hard limits, the fuse
defaults, mode semantics, the notification interface and the deep link, plus the explicit list of
deleted rules. There is **no schema, no golden and no vector** for `proactive.considered`, settings,
candidate fields or delivery results.

**Missing spec.** (a) `ProactiveSettings` fields, defaults, validation and persistence location/key
(CCR candidate: P18). (b) Candidate fields and kinds (`task-done`, `routine-result`, `reminder`) and
the reminder exception predicate (`ProactiveModels.swift:5-70`). (c) Decision event `data` shape and
restore conflict rules (`ProactiveEngine.swift:180-230`). (d) Fuse accounting: which decisions consume
the fuse, how `mode == .would` is counted, failed delivery not consuming it
(`ProactiveEngine.swift:135-205`; `ProactivePolicy.swift:32-65`). (e) Notification delivery result
shape (`delivered|deduped|failed|disabled`), dedupe semantics and authorization status
(`ProactiveModels.swift:123-175`). (f) Quiet-hour arithmetic and weekend rule
(`ProactiveSettings.swift:40-100`). (g) There is no production caller today, so “iOS behaviour” has
test evidence only — a Kotlin port would be the first production implementation and must not be
described as parity.

**Status.** `spec-missing`. **Blocked before B4 on D6.** This is the highest-risk subsystem because
there is neither a contract nor production evidence.

### 3.6 S6 — Watchdog / context lint (P26) — `spec-partial`

**iOS files.** `Watchdog/BotWatchdog.swift` (6,361 B), `BotWatchdogChecks.swift` (4,062 B),
`BotWatchdogMonitor.swift` (12,895 B), `BotContextLint.swift` (17,024 B),
`BotContextLintRules.swift` (15,606 B), `BotContextProfiles.swift` (5,871 B). 1,469 lines.

**Responsibilities.** Observe-only watchdog over turn/task/routine/goal units: deadline, heartbeat,
repeated tool signature, repeated tool error, token/cost quota, and the three mobile signals
(WebContent terminated, thermal, battery). One `watchdog.flagged` per unit/check, durable and
deduplicated. Context lint is a deterministic diagnostic over a recent session (six rules) with
thresholds; context profiles expose the frozen default/conservative compaction parameters.

**Persistence — exact.** Flags are durable `watchdog.flagged` events written through the Bot event log
(`BotWatchdogMonitor.swift:250-275`); units and the `seen`/`pending` dedupe sets are in memory and
rebuilt per process (`:28-29`, `:205-260`). Context lint returns findings and does not persist them by
itself. Context profiles are pure values from the golden; no file/table.

**External effects.** Flags are appended to the event log and read by the UI/roster; the watchdog never
nudges or stops a turn (v1 §6). Mobile events are host signals: WebContent termination is observed by
the app; thermal/battery are not wired in this tree (grep finds no producer).

**Spec coverage today.** `spec/bot/v1/watchdog.schema.json` (config is an unconstrained object;
`flagged` checks enumerate deadline/heartbeat/repeated signature/repeated error/quota; `mobile` fixes
the three signals and once-per-unit) + `golden/watchdog.json` 3/1, whose config carries the exact
numbers 120,000/900,000/600,000/660,000/5/3/200,000/2/5,000/200/1,000;
`context-profiles.schema.json` + 2/1; `context-lint.schema.json` + 1/0; v1 §6 prose.

**Missing spec.** (a) Watchdog config field schema (the golden has the values but the schema says only
`type: object`, so a Kotlin implementation cannot validate or default from the schema). (b) Evaluation
tick and flag payload beyond `check`/`evidence` (`BotWatchdogMonitor.swift:214-266`). (c) Which unit
kinds get which deadline and how overrides work (`BotWatchdog.swift:63-110`). (d) Context-lint
thresholds: 20,000/32,000 chars, 4,096/12,000 result tokens, 8,000/16,000 tool-def tokens, 40 tools,
2 runtime contexts, 500-char repeated text, 20 findings (`BotContextLint.swift:38-75`), plus the
per-rule evidence strings. (e) Who calls context lint (no production caller in this tree) and whether
it is a Bot-runtime feature or a diagnostic job. (f) Thermal/battery producers and the platform
mapping (Android has `PowerManager` thermal/battery APIs but no contract).

**Status.** `spec-partial`. **Blocked before B4 on D7.**

### 3.7 S7 — MCP endpoint / tool catalog / cards / volatile context (P05/P26) — `spec-partial`

**iOS files.** `MCP/BotMCPHTTPServer.swift` (28,804 B), `BotMCPHandler.swift` (15,220 B),
`BotMCPRuntime.swift` (44,927 B), `BotMCPTypes.swift` (7,839 B),
`BotDomainVolatileContextProvider.swift` (11,221 B), `BotVolatileContext.swift` (4,612 B),
`BotToolCatalog.swift` (17,460 B), `BotCardPayloads.swift` (18,312 B),
`BotApprovalCoordinator.swift` (13,608 B), `BotRoutineTool.swift` (8,889 B),
`BotDSHRemoteRuntime.swift` (72,191 B). 4,973 lines.

**Responsibilities.** The one `phone` MCP server the Worker sees: IPv4-loopback HTTP listener with
exact routes and bearer/origin checks, JSON-RPC `initialize|ping|tools/list|tools/call` plus native
forwarding, Bot tool catalog (P0 + team + volatile + fish), card builders, per-caller catalog
filtering, identity registration and approval endpoints, the long-call SSE switch, and the DSH remote
runtime that actually opens the Bot session, sends prompts, follows frames, runs routines/tasks and
stops turns.

**Persistence — exact.** The listener and handler are stateless across process death: token, port,
MCP session id and identity registrations are in memory (`BotMCPHTTPServer.swift:47-73`,
`BotMCPRuntime.swift:32-42`). Identity registrations live in `registrations` with an expiry of
approval timeout + 30,000 ms (`BotAttributionRegistry.swift:40-42`). Card presentation, approval
decision, task lifecycle and routine execution are durable Bot events (`card.presented`,
`approval.requested/decided`, `task.created/updated/settled`, `conversation.*`) in
`domain.sqlite`. Task snapshots are embedded in `task.updated` as `persistedTask` and restored by
scanning the log (`BotDSHRemoteRuntime.swift:645-760`). The listener prefers the previous port and
falls back to any port on rebind (`BotMCPHTTPServer.swift:15-16`, `:129-253`), with a 1.5 s probe
(`:328-348`). The JSON body limit is 1 MiB (`:45`). Long-call timing is 5 s to stream and 15 s
keepalive (`:61-73`).

**External effects.** Opens the DSH session (`session/create`, `session/follow`, `session/prompt`,
`session/cancel`, `session/list`/archive via the generic transport —
`BotDSHRemoteRuntime.swift:175-420`), writes durable events, approves/denies tool executions, and
serves the Worker's MCP calls. Native tools (ADB/BLE) are forwarded to the native MCP handler unchanged
(`BotMCPHandler.swift:196-236`). The Bot listener is also the only `phone` server in Bot mode; it must
not be replaced by `/mcp/native` (`spec/bot/v1/mcp-endpoint.md:16-22`).

**Spec coverage today.** `spec/bot/v1/mcp-endpoint.md` is the strongest Bot document: one owner for the
Worker env, `PDSH_MCP_EGRESS_TOKEN`, exact routes, POST-only, origin/bearer rules, 1 MiB body, SSE
long-call timing, identity/session credential ordering, restart and prompt idempotency, and a
compatibility matrix. `tool-catalog.json` 2/6 + `tool-catalog.phone.json`; `card-payload.json` 12/2 +
`card-payload.phone.json` 6/2; `volatile-context.json` 2/3; `mcp-egress.phone.json` 17/25;
`spec/bot/v1/README.md:43-62`.

**Missing spec.** (a) The JSON-RPC surface: `initialize` result fields (`protocolVersion`,
`capabilities`, `serverInfo{name,version}`, merged `instructions`), `ping`, `tools/list` result,
`tools/call` result (`content[]`, `structuredContent`, `isError`), and error codes
`-32601/-32602/-32603` (`BotMCPHandler.swift:55-140`; `BotMCPTypes.swift:5-45`). (b) The
`/identity/register`, `/identity/cancel` and `/approval` request/response bodies and their failure
strings (`BotMCPHandler.swift:141-205`). (c) Per-tool argument contracts and error messages for
`UpdateMemory`, `RecallMemory`, `Task`, `AwaitTask`, `StopSubagent`, `UpdateRoutine`, `ListRoutines`,
`RequestApproval`, `SendToUser` (`BotMCPRuntime.swift:542-780`). (d) Card-builder rules beyond the
goldens: 2–4 options, synthetic “其他/其它/other” filtering, style normalization, recommendation
move, `o0…o3` assignment, per-card required fields (`BotCardPayloads.swift:11-120`). (e) Volatile
context block assembly: default persona string, `<teammates>` 999-scalar cap, 200-char teammate
description, 300-char Bot description, 3,900-scalar automation cap
(`BotDomainVolatileContextProvider.swift:20-100`). (f) Listener recovery/port policy (the change record
`PC-20261110-bot-mcp-listener-recovery` has no owning spec). (g) DSH remote session/turn contract:
`gb-` session ids, cwd, live frame shape, stop/cancel, task wake prompt and `requestId` derivation
(`BotDSHRemoteRuntime.swift:201-420`, `:503-640`). (h) Native forwarding limits and GAP-36: the
`/mcp/native` route returns one buffered body, so a forwarded native call over 60 s still fails
(`spec/README.md:228`).

**Status.** `spec-partial`. **Blocked before B5 on D13; task persistence part blocked on D12.**

### 3.8 S8 — Authz / grants / approval (P26) — `spec-partial`

**iOS files.** `Authz/BotGrants.swift` (19,440 B), `BotGrantSnapshot.swift` (8,210 B),
`BotExecutionAuthorizer.swift` (9,689 B), `BotToolEffects.swift` (24,855 B),
`BotApprovalPatterns.swift` (6,675 B), `BotAudit.swift` (4,965 B),
`BotArgumentsDigest.swift` (976 B). 1,527 lines.

**Responsibilities.** Grant scopes `once|session|until` with TTLs 2 min / 24 h / 30 d and a 500-grant
cap (`BotGrants.swift:70-73`), full-snapshot recovery from `authz.grant_snapshot` (last snapshot wins,
fail-closed on missing/invalid/unsupported), resource canonicalization, once-grant atomic consumption,
standing deny, auto-policy vs ask, approval pattern detection for bash (`rm`, `git reset --hard`,
`find -delete`, `curl` POST, network egress), argument digest, audit events, and the approval
coordinator with a 300 s card lifetime (`BotApprovalCoordinator.swift:31-115`).

**Persistence — exact.** The authority is the durable `authz.grant_snapshot` event (type string at
`BotGrantSnapshot.swift:13`), whose `data` is exactly `{"grants":[entry…]}` with 11 frozen entry fields
and no unknown members (`BotGrantSnapshot.swift:12-175`). `recover()` scans the durable log; if any
event exists but no snapshot does, it throws `missingSnapshot`; on a fresh log it appends an empty
snapshot (`BotGrants.swift:148-175`). Grants are held in memory after recovery. Audit events
(`grant.added|consumed|revoked|migrated`) carry summaries, not full parameters
(`BotGrants.swift:200-230`, `:440-470`). Approval events carry `approvalID`, `status`, `action`,
`detail`, `digest`, `command`, `alwaysScope`, `deferConsumption`, and `effects[]`
(`BotApprovalCoordinator.swift:80-115`).

**External effects.** Approval cards are resolved by the UI through `BotApprovalCoordinator.resolve`,
which writes `approval.decided` and may add a grant; `once` grants are consumed before execution when
the effect has no deferred execution (`BotApprovalCoordinator.swift:118-172`). A Worker restart cancels
all pending cards with `approval.decided` + `ui.notice` (`:186-235`). The authorizer is called by both
the MCP execution path and the approval path (`BotExecutionAuthorizer.swift:65-170`).

**Spec coverage today.** `spec/bot/v1/README.md:64-69` (snapshot authority, ordering, incarnation,
digest, UI trust), `:54-60` (identity before approval, 300 s), `approval-patterns.json` 5/1,
`tool-effects.json` 21/2 and `tool-effects.phone.json` 3/0 + `nativeMcp`, and `spec/bot/v1/README.md:37`
for the team/FishAction classifications.

**Missing spec.** (a) The grant snapshot is not a schema and is not in the event enum (CCR-2); its
`data` shape exists only in Swift. (b) TTLs, max grants, entry canonicalization and duplicate/expiry
rules (`BotGrantSnapshot.swift:90-148`). (c) The grant matching specificity/ordering and the
`"*"` deny rule (`BotGrants.swift:225-260`). (d) Once-grant atomicity and the exact failure codes
(`once-grant-consumed`, `standing-deny`, `missing-grant`, `uncertain-attribution`,
`grant-recovery-failed`, `invalid-arguments-digest`) (`BotExecutionAuthorizer.swift:90-170`).
(e) Approval request/response JSON, `alwaysScope` allowed values and the expected-scope rule
(`BotMCPRuntime.swift:427-476`). (f) Approval card cancellation/expiry event shapes and reason strings
(`BotApprovalCoordinator.swift:186-255`). (g) The tool-effect classification table is partly in
`tool-effects.json`; the code adds labels/details and many tool names
(`BotToolEffects.swift:56-220`), which the golden does not enumerate. (h) `BotArgumentsDigest` is
SHA-256 over canonical JSON (`BotArgumentsDigest.swift:7-15`); the canonicalization rule is not in the
Bot contract (it is the P01/P06 canonical JSON rule, cited nowhere in Bot).

**Status.** `spec-partial`. **Blocked before B5 on D13; snapshot shape on D1/CCR-2.**

### 3.9 S9 — Gateway / tokens / attribution / session credentials (P05/P26) — `spec-partial`

**iOS files.** `Gateway/BotGateway.swift` (9,760 B), `BotTokenRegistry.swift` (11,249 B),
`BotAttributionRegistry.swift` (8,506 B). 652 lines.

**Responsibilities.** Issue `dshg_`-style Bot session tokens with a 12 h default TTL and 4,096-token
cap, store only SHA-256 digests, rotate/revoke per token/session/Bot, resolve a bearer or a session to
a `BotGatewayPrincipal` with an `incarnation`, attribute a `tools/call` to runtime+session+call+name+
argument digest, and expire registrations.

**Persistence — exact.** **Nothing persists.** Tokens, digests, current incarnations and attributions
are in-memory actors; the spec says the session credential is never an environment variable, file,
`UserDefaults`, Keychain, BotEvent, log or UI notice (`spec/bot/v1/mcp-endpoint.md:158-162`). A restart
loses every token and registration, which is the contract's fail-closed behaviour (`:165-174`).
Token TTL is 12 h (`BotTokenRegistry.swift:51`), max 4,096 (`:52`); attribution TTL is approval
timeout + 30 s (`BotAttributionRegistry.swift:40-42`).

**External effects.** Issues bearer/session tokens to the host, resolves the principal for MCP requests,
and binds the runtime generation to a tool call. It does not itself make network calls.

**Spec coverage today.** `mcp-endpoint.md` §1.1 (egress token), §3 (session credential, claim, host
lifecycle, registration ordering, 300 s window, allowed tool set, binding) and §4 (restart);
`mcp-egress.phone.json` 17/25 across `egress`/`identity`/`tools-call`; v1 §2.3 (incarnation, token
digest, principal construction), and `spec/bot/v1/README.md:60` (Android/HarmonyOS not started).

**Missing spec.** (a) Token format/prefix/length and the exact `Authorization` grammar
(`BotTokenRegistry.swift:114-150`). (b) TTL, capacity and eviction (`:51-52`, `:211-228`).
(c) Incarnation creation/rotation and the `scopedRuntimeID` encoding (`BotMCPRuntime.swift:270-272`).
(d) Attribution fields, the `runtimeId@generation` key and claim/cleanup rules
(`BotAttributionRegistry.swift:66-150`). (e) Error strings (`unattributed`, `unauthorized`,
`unknown_tool`, `permission_denied`, `cross_session_denied`, `timeout`, `unavailable`) and their
mapping to JSON-RPC/MCP results (`BotMCPHandler.swift:236-250`). (f) `tools/list` caller header
`x-pdsh-bot-session` (`BotMCPHandler.swift:28-34`) is code-only.

**Status.** `spec-partial`. **Blocked before B5 on D13.**

### 3.10 S10 — Team / SendToAgent / CreateTeammate (P26/P27) — `spec-partial`

**iOS files.** `Team/BotTeamTools.swift` (22,568 B), `Team/BotTeamHost.swift` (9,579 B). 738 lines,
plus the app-side implementation in `BotRuntimeComposition.swift:841-1010` and the row model in
`Rows/BotAgentComm.swift` (10,454 B).

**Responsibilities.** `SendToAgent` (id or name target, aliases, priority/delivery conflict, self-target
rejection, depth ≤2, cycle rejection, request-id idempotency, `now` vs `queued`), `CreateTeammate`
(main-Bot only, name 1–60, description 300, 15 colors, 4 hairstyles, `section_id` ignored), the exact
prompt `[agent] <name> (id: <id>)[ — <title>]: <message>`, the sender outbound/inbound rows and target
incoming/reply rows, the 300 s wait, the 1,200-char held reply, thread/hop tracking, and unread
counters.

**Persistence — exact.** `agent.comm` is a durable P25 event type added by
`PC-20261111-bot-agent-comm-envelope`; outbound/inbound rows are also written through
`recordAgentComm` and projected by the row store. The receiver-side `agent-held` item is a
`WakeInboxItem` in the held-inbox snapshot. Thread ids are `<rowID>@<seq>:agent-comm`; the outbound
row id is `agent-outbound-<sha256(sender\0target\0requestId\0seq)>`; target rows are `t<turn>u` with a
numeric collision suffix (`BotAgentComm.swift:142-170`). Hops/threads are in memory in the app
composition (`BotRuntimeComposition.swift:121-124`).

**External effects.** Opens a visible target turn (or queues behind one), waits for the final assistant
text, writes rows and held replies, and bumps unread counts for non-selected Bots
(`BotTeamHost.swift:205-240`; `BotRuntimeComposition.swift:871-963`).

**Spec coverage today.** `spec/bot/v1/README.md:18-26` (multi-Bot, `SendToAgent`, `CreateTeammate`,
row directions, `agent.comm`, out-of-scope list), `tool-catalog.phone.json` team block (required
properties, descriptionContains, roster line), `tool-effects.phone.json` (external-send/write +
auto), `held-inbox.phone.json` agent-held, `event-envelope.phone.json` 2/1, and the change records
`PC-20261109-bot-team-tools` + `PC-20261111-bot-agent-comm-envelope`.

**Missing spec.** (a) The exact error strings and codes for missing priority/delivery, self-target,
depth, cycle, target-not-found, held-full (`BotTeamTools.swift:60-240`). (b) The prompt template and
`requestId = agent:<callId>` binding (`:177-180`; `BotTurnOrigin.swift:100-120`). (c) Row/thread id
formulas, the `inbound` reply row and the 1,200-char cap (`BotAgentComm.swift:142-170`;
`BotTeamTools.swift:200-240`). (d) The 300 s timeout and busy-target queueing rule
(`BotTeamTools.swift:14`; `BotTeamHost.swift:31-60`). (e) `CreateTeammate` defaults and the color/
hairstyle enums (the enums are in `bot-profile`/`BotFishAppearance`, not in the tool contract).
(f) Unread-counter and selection-side-effect rules (`BotTeamHost.swift:205-240`). (g) The
`summarizeCommRows` single/fanout/thread rule (`BotAgentComm.swift:171-260`).

**Status.** `spec-partial`. **Blocked before B6 on D12.**

### 3.11 S11 — Rows / UserAction / projection / display (P27) — `spec-partial`

**iOS files.** `Rows/BotRow.swift` (5,610 B), `BotSessionLogProjection.swift` (49,018 B),
`BotUserAction.swift` (10,856 B), `BotRemoteActionPlanner.swift` (13,876 B),
`BotDisplayContract.swift` (14,358 B), `BotAgentComm.swift` (10,454 B),
`BotStreamingRowLimiter.swift` (2,742 B). 2,357 lines.

**Responsibilities.** Convert the DSH session log (JSONL events) and the durable `ui.*`/`card.*` events
into ordered `BotRow`s; maintain cursor/watch batches and tombstones; apply `surfaceOp` append/replace;
collapse progress by `cardKey`; project each row through the display contract (bubble, widget-card,
attachment-card, approval-card, automation-row, notice, agent-comm, hidden); plan and commit user
actions (`chat`, `cardAnswer`, `cardDismiss`, `approval`, `stopTask`) with nonce dedupe and stale/
rejected outcomes; and throttle streaming text to 10 updates/s.

**Persistence — exact.** There is **no rows table**. Rows are a pure projection of (a) the DSH session
JSONL file for the Bot's session and (b) durable `ui.*`, `card.*`, `approval.*`, `agent.comm` and
`task.*` events in `domain.sqlite` (`BotSessionLogProjection.swift:280-330`, `:500-530`). The
projection cursor, rows, tombstones and `updatedSeq` are in memory and rebuilt at launch
(`:225-250`, `:664-730`). User actions commit one durable event + zero or more effects + a nonce row in
one `BEGIN IMMEDIATE` transaction (`SQLiteDomainStore+UserAction.swift:11-60`). The streaming overlay
is never durable (v1 §5; `BotStreamingRowLimiter.swift:6`).

**External effects.** A committed `chat`/`cardAnswer` action sends a `session/prompt` to DSH with the
derived request id; `cardDismiss` writes `card.dismissed`; `approval` resolves the approval coordinator;
`stopTask` cancels a task (`BotRemoteActionPlanner.swift:8-200`; `BotDSHRemoteRuntime.swift:201-420`).

**Spec coverage today.** `row.schema.json` (id/botID/seq/updatedSeq/kind/body/provenance/streaming/
createdAt), `row-batch.schema.json` (rows/deletes/cursor/reset), `row-projection.schema.json` (input/
surface/renderable/wire), `user-action.schema.json` (`nonce,botID,kind` + text/cardID/optionID/
approvalID/decision/digest/threadID/attachments), `action-result.schema.json`, `row-protocol.json` 5/2,
`row-protocol.phone.json` 3 valid + 4 invalid actions + 1 projection, `row-projection.json` 20/1, and
v1 §5 (`spec/bot/v1/README.md:107-122`).

**Missing spec.** (a) The DSH→row mapping table: event type → row kind/body/role, `rowID =
e-<sessionID>-<seq>(-approval)`, `entrySeq = time*1000 + seq%1000`, `surfaceOp` append/replace and
invalid-record skip semantics (`BotSessionLogProjection.swift:280-530`, `:847-865`). (b) Tombstone and
`history(before:)`/`watch(after:)` cursor/reset rules (`:664-830`). (c) `cardKey` progress collapse and
the “latest wins” rule (`:676-690`). (d) The display contract table: hidden `tool-call`/`deleted`,
notice only error/denied/denial, agent-comm direction collapse, P1 cards protocol-visible but not
phone-renderable, separator upstream-only (`BotDisplayContract.swift:78-230`). (e) Card expiry and
answer semantics: old open question/steps expire when a new card appears; answered/closed/expired →
stale; `cardDismiss` on steps → rejected; close doesn’t create a model turn (`BotRemoteActionPlanner.swift:73-150`;
`spec/bot/v1/README.md:120`). (f) Action validation and reason codes (`invalid_action`,
`unexpected_attachments`, `too_many_attachments`, `invalid_attachment`, `missing_text`,
`missing_card_id`, `unexpected_card_answer_field`, `missing_card_answer`, `invalid_approval`,
`digest_mismatch`, `missing_thread_id`) (`BotUserAction.swift:231-268`). (g) `chatActionNonce`, the
`agent-comm` row projection and `summarizeCommRows` (`BotAgentComm.swift:171-260`). (h) Streaming
limiter quantisation and `nextFlushAt` (`BotStreamingRowLimiter.swift:6-90`).

**Status.** `spec-partial`. **Blocked before B7a on D11.**

### 3.12 S12 — Profile / roster (P26) — `spec-partial`

**iOS files.** `Profile/BotProfile.swift` (35,342 B), `BotFishAppearance.swift` (7,059 B),
`BotRoster.swift` (869 B), plus `examples/probe-app/PhoneDSHProbe/Bot/BotProfileStorage.swift`
(1,186 B), `BotProfileCenter.swift` (5,334 B), `BotRosterModel.swift` (11,013 B). 1,068 lines in the
runtime module.

**Responsibilities.** Read/write the desktop-compatible roster and per-Bot profile, preserve unknown
JSON members, repair the main-Bot pointer, enforce names (trimmed, 1–60), description 2,000 UTF-16
units, color/hairstyle normalization, seed fallback, hidden/pinned/unread fields, atomic writes,
corrupt-file quarantine, and a roster update stream.

**Persistence — exact.** `Application Support/PhoneDSHBot/agents-index.json`
(`{schemaVersion:3, agents:[record…]}`) and `Application Support/PhoneDSHBot/runtime-settings.json`
(`{version:1, mainAgentId:<id>|null, updatedAt:<ms>}`) (`BotProfile.swift:118-125`,
`examples/probe-app/PhoneDSHProbe/Bot/BotProfileStorage.swift:8-16`). Record keys are `schema`,
`id`, `name`, `fish_color`, `fish_hairstyle`, `name_explicit`, `created_at`, `updated_at`,
`description`, `hidden_by_user`, `pinned`, `unread_count`, `last_message_at`
(`BotProfile.swift:728-753`). Writes go to a hidden temp sibling then `replaceItemAt`, with
`0o600`/`0o700` and `completeUntilFirstUserAuthentication` protection (`:790-850`). A corrupt file is
moved to `<name>.corrupt-<ms>`; if that fails, writes are refused (`:124-127`, `:838-858`). The
selection key is `phoneDSH.bot.selectedBotID` in `UserDefaults`
(`BotProfileStorage.swift:18-20`).

**External effects.** Only file writes and the roster stream. Deletion cascades: revoke tokens and
grants, archive DSH sessions, clear held inbox, delete memory and routines, then remove the record
(`BotRuntimeComposition.swift:690-760`). The last Bot cannot be deleted
(`BotProfile.swift:83-105`).

**Spec coverage today.** `bot-profile.schema.json` + `golden/bot-profile.json` freeze the 15 color
hexes, 4 hairstyles, the FNV-1a seed mapping and the roster pointer/deletion rules
(`rosterRules.mainPointerRepair` 4 cases, `deleteMainMigration` 3 cases); v1 §1.1 (main pointer, delete
moves to first remaining, hidden still in roster); P26 registry.

**Missing spec.** (a) The record schema is not a schema: `bot-profile.schema.json` is a vector schema
(`source`, `recordSchemaVersion`, `colors`, …), not the `agents-index` record object. (b) File names,
envelope keys, unknown-member preservation, atomic write and corrupt quarantine are code-only.
(c) Name/description limits and the exact normalization (`BotProfile.swift:89-105`, `:229-250`,
`:707-753`). (d) Color/hairstyle value normalization including `null|""|"auto"` and no trimming
(`BotFishAppearance.swift:153-168`). (e) Selection key and P18 ownership (the key is a persisted
protocol per `spec/README.md:79`). (f) Deletion cascade order and the last-Bot rule
(`BotRuntimeComposition.swift:690-760`). (g) The roster-stream contract (initial snapshot, one per
write, unbounded) (`BotProfile.swift:184-210`).

**Status.** `spec-partial`. **Blocked before B7a on D4; selection key needs a P18 delta.**

### 3.13 S13 — Attachments (P27) — `spec-partial`

**iOS files.** `Attachments/BotAttachment.swift` (3,589 B), `BotAttachmentPrompt.swift` (3,620 B),
`BotAttachmentImporting.swift` (1,131 B), `BotWorkspaceLayout.swift` (2,304 B), plus the app importer in
`BotProductionServices.swift:449-540`. 248 lines in the runtime module.

**Responsibilities.** Classify files into `image|audio|video|pdf|markdown|table|json|document|archive|
file`, sanitize names, cap 10 files / 25 MiB each, assemble/parse the model-visible
`[dshbot-attachments]` block, resolve the per-Bot workspace root, and import files into
`imports/attachments-<messageID>/`.

**Persistence — exact.** Attachments are **files in the Bot's DSH workspace**, not rows in the Bot DB:
the importer writes through the Worker directory-import service into
`<botDataDirectory>/agents/<botID>/imports/attachments-<messageID>/<safeName>`
(`BotAttachmentImporting.swift:17-26`; `BotProductionServices.swift:449-540`). The default
`botDataDirectory` is `/dsh/workspace/.dshbot` (`BotWorkspaceLayout.swift:18-32`), and the safe path
component keeps `[A-Za-z0-9._-]`, caps at 64, and falls back to `bot` (`:36-60`). Attachment metadata
is carried in the user-action `attachments` array and in the prompt block; no separate table.

**External effects.** A VFS write into the Bot workspace; per-item failures are reported and the
successful items still send (`BotAttachmentImporting.swift:17-26`). The prompt block is appended to the
user prompt (`BotDSHRemoteRuntime.swift:209-215`).

**Spec coverage today.** `golden/bot-attachments.json` freezes `maxAttachments=10`,
`maxBytes=26,214,400`, four parse cases, eight `kindFor` cases and the upstream prompt block;
`user-action.schema.json` has optional `attachments`; `PC-20261109-bot-attachments` freezes the
additive field; `spec/bot/v1/README.md:39` describes the card/attachment rules.

**Missing spec.** (a) The phoneDSH prompt sentence is **not** in the golden: the golden says “saved on
this Mac” while `BotAttachmentPrompt.explanation` says “saved in your workspace”, and the Swift test
synthesizes the phone variant by string substitution
(`Tests/PhoneDSHBotTests/Attachments/BotAttachmentGoldenTests.swift:17-30`;
`BotAttachmentPrompt.swift:9-11`). (b) `safeName` is tested only in Swift, not in the golden
(`BotAttachmentPolicy.safeName`, `BotAttachment.swift:66-95`; test `:70-86`). (c) The `imports/
attachments-<messageID>/` layout and unique-name collision rule are code-only
(`BotProductionServices.swift:518-540`). (d) Import failure messages/partial-success contract are not
normative. (e) The 25 MiB/10-file limits are in the golden but the per-item failure behaviour is not.

**Status.** `spec-partial`. **Blocked before B7a on D3.**

### 3.14 S14 — Ledger / model purpose (P26) — `spec-partial`

**iOS files.** `Ledger/BotLLMLedger.swift` (2,865 B), `BotLLMLedgerRecord.swift` (7,897 B),
`BotModelPurposePolicy.swift` (4,914 B). 392 lines.

**Responsibilities.** Append one `ledger.usage_recorded` event per model step with four token classes,
cache-hit ratio, TTFT/duration, status/error; read records back by cursor; and define which purposes may
use a large model plus per-purpose model/max-tokens/temperature defaults.

**Persistence — exact.** Durable `ledger.usage_recorded` events in `domain.sqlite`; the event `data` is
the JSON encoding of `BotLLMLedgerRecord` with sorted keys (`BotLLMLedger.swift:14-50`). No table, no
file. Records are read by paging the event log and filtering by type (`:53-68`).

**External effects.** Appends events; the DSH remote also feeds the same usage into
`watchdog.observeUsage` (`BotDSHRemoteRuntime.swift:1360-1380`).

**Spec coverage today.** `llm-ledger.schema.json` (all 14 fields required, token minimums, purpose
enum) + `golden/llm-ledger.json` 15 valid / 2 invalid; `model-purpose-policy.schema.json` +
`golden/model-purpose-policy.json` 2/1 (8 purposes, 2 large-model purposes, default model
`deepseek-flash`, max tokens/temperature per purpose); v1 §6 (four token classes, cache-hit formula,
TTFT optional, only front/worker may use a large model).

**Missing spec.** (a) `cacheHitRatio = cacheRead / (input + cacheRead + cacheWrite)` is in Swift
(`BotLLMLedgerRecord.swift:60-66`) and only implied by golden values. (b) Timestamp format (ISO-8601
with fractional seconds, UTC) and `ts` validation (`:72-90`). (c) Purpose → principal-kind mapping
(front/worker→chat/task, watchdog→watchdog) (`BotLLMLedger.swift:29-35`). (d) Model-tier
classification (small prefix, large allowlist, `pro|reasoner|max|opus` regex) and the
`EPURPOSE_MODEL_REQUIRED` / `EPURPOSE_MODEL_DENIED` errors
(`BotModelPurposePolicy.swift:82-130`). (e) Where the policy is enforced — no production caller exists
in this tree, so the answer must be “host” or “Worker”, not both.

**Status.** `spec-partial`. **Blocked before B4 on D5.**

### 3.15 S15 — Avatar / FishDirector / reactions (P26/P27) — `spec-partial`

**iOS files.** `Avatar/BotFishDirector.swift` (12,391 B), `BotFishEventMapping.swift` (5,338 B),
`BotFishReactions.swift` (9,004 B). 626 lines.

**Responsibilities.** A deterministic priority/debounce/one-shot TTL director that turns real DSH and
durable Bot events into a `BotFishLifecycle`; a mapping table from raw DSH event names to director
event names; the 16-action/8-expression `FishAction` vocabulary and its one-shot reaction overlay (a
4 s expression or one clip); and the rule that `FishAction` never appears in the transcript/process
rows.

**Persistence — exact.** **None.** Director state and one-shot TTLs are in memory; `fish.action` is an
ephemeral event type (`BotEventEnvelopeCodec.swift:47-51`) and the durable source is the DSH
`tool/call` record. A reaction id is the tool call id, so replaying the same call does not play twice
(`BotFishReactions.swift:74-135`).

**External effects.** None beyond UI presentation; every avatar of the same Bot consumes the same
reaction id (`BotRuntimePresentation.swift:42-120`).

**Spec coverage today.** `fish-director.schema.json` + `golden/fish-director.json` (1 vector with
step-by-step director state/command, 1 invalid), `tool-catalog.phone.json` fish block (16 actions,
8 expressions, description/result constraints), `tool-effects.phone.json` `FishAction` read+auto,
`spec/bot/v1/README.md:132-136` (real events only, priority/one-shot/TTL/dedupe, crown from principal),
and `PC-20261109-bot-fish-react` §3 (the raw→director mapping table, currently only in the change
record).

**Missing spec.** (a) The event-mapping table belongs in the owning P26 document, not only a PC
(`BotFishEventMapping.swift:17-95`; `PC-20261109-bot-fish-react.md:39-70`). (b) One-shot TTLs and
priority values for each reaction/action (`BotFishReactions.swift:8-135`). (c) The `FishAction`
argument → reaction mapping and the “once per reply” rule (`BotFishReactions.swift:137-210`).
(d) The `celebrate/sad/alerting/idle` transitions and the 60 s sleeping clock, which live in the app
(`BotChatModel.swift:237-250`) and are described in `spec/ui/v1/pages/bot-chat.md:11`. (e) The
`BotFishLifecycle` enum is not schema'd at all; the golden uses strings.

**Status.** `spec-partial`. **Blocked before B8 on D14 (renderer) and D12 (mapping table).**

### 3.16 S16 — Bot UI pages / roster drawer / chat model (P09/P27) — `spec-partial`

**iOS files.** `BotChatPage.swift` (46,987 B), `BotChatModel.swift` (33,268 B),
`BotDrawer.swift` (34,304 B), `BotInfoPage.swift` (29,738 B), `BotCardKit.swift` (14,126 B),
`BotCardView.swift` (14,711 B), `BotWorkCardView.swift` (21,725 B), `BotUIModels.swift` (32,270 B),
`BotProductionPage.swift` (21,337 B), `BotProductionServices.swift` (24,077 B),
`BotProductionUIAdapters.swift` (9,337 B), `BotRuntimeComposition.swift` (49,753 B),
`BotRuntimeUnit.swift` (10,298 B), `BotRosterModel.swift` (11,013 B), `BotProfileCenter.swift` (5,334 B),
`BotActivityLine.swift` (7,075 B), plus fixtures and smaller views. 29 files, 11,228 lines (excluding
Fish).

**Responsibilities.** The Bot tab's chat page, composer (send/stop/steer/attachments), card rendering,
activity line, roster drawer and add/manage dialogs, info page (appearance, memory, routines, approvals),
deep links, the per-Bot view model (rows, streaming overlay, live fish projection, idle clock), and the
production composition root that binds one Bot unit to DSH/MCP/effect runner.

**Persistence — exact.** The UI owns no database. It reads rows from the projection and profile from
`BotProfileStore`; it writes the selected Bot to `UserDefaults["phoneDSH.bot.selectedBotID"]`
(`BotProfileStorage.swift:18-20`), profile edits to `agents-index.json`, user actions through the
durable dispatcher, and attachments through the workspace importer. Draft text, scrolling, pending
action state and card dismissal hide-state are in memory (`BotChatModel.swift:71-110`).

**External effects.** Sends prompts/steering/stops to DSH, commits user actions, imports attachments,
writes profile files, and opens external links (HTTP/HTTPS only). Deletion cascades as in S12.

**Spec coverage today.** `spec/ui/v1/pages/bot-chat.md` (82 lines, `target`), `bot-drawer.md`
(45 lines, `target`), `bot-info.md` (25 lines, `target`), plus `spec/ui/v1/tokens.json`,
`spec/ui/v1/interaction.md` and the `ui_check.py`/`page_structure_check.py` machinery.
`PC-20261109-bot-grok-layout`, `PC-20261109-bot-drawer` and `PC-20261109-bot-multi-app` record the
implemented iOS wiring.

**Missing spec.** (a) A contradiction: `bot-chat.md:46` says “Bot 间通讯行不实现” while
`bot-chat.md:11` and `bot-drawer.md:40` define agent-comm rows and render their avatars, and
`spec/bot/v1/README.md:24` freezes them (CCR-3). (b) A second contradiction: `bot-dock.md` specifies a
64 pt Chat circle + 3-item capsule, while the shipped `HomeTabBar.swift` is four equal columns and
`HomeTabBar.kt:6-7` follows it (CCR-4). The Bot tab placement must be decided before B7b. (c) The roster
view-model state machine: selection, unread counters, main-pointer repair, hidden rows, deletion
cascade (`BotRosterModel.swift:1-286`). (d) Card rendering rules per card type and the exact
`optionID`/recommended/close behaviour (`bot-chat.md:44-46`; `BotCardKit.swift:1-200`). (e) Activity
line text rotation/geometry and the fish projection (`bot-chat.md:50-56`; `BotActivityLine.swift:1-180`).
(f) Deep-link parse/expiry and `BotDeepLink` (`BotUIModels.swift:496-510`). (g) Composer/attachment
geometry is in `tokens.json` only where a token exists; several values are local constants
(`BotChatPage.swift`).

**Status.** `spec-partial`. **Blocked before B7b on D15 (P09 reconciliation) and D11 (rows).**

### 3.17 S17 — BotFish renderer + assets (P09/P26) — `spec-missing`

**iOS files.** `Bot/Fish/BotFishRenderer.swift` (56,379 B), `BotFishModel.swift` (22,523 B),
`BotFishEngine.swift` (20,822 B), `BotFishAssets.swift` (13,217 B), `BotFishGallery.swift` (11,208 B),
`BotFishView.swift` (7,875 B), `BotFishImageCache.swift` (5,587 B). 3,326 lines. Assets:
`examples/probe-app/BotFish/**` 36 files, 2.4 MB (base 284 K, crowned 880 K, expressive 336 K,
hair 692 K, overlays 244 K) plus `atlas.json` (20 K).

**Responsibilities.** A native Core Graphics port of the upstream Canvas fish: body/hair/face layers,
LUT recolouring, eye/mouth sprite cross-fade, 8 px head-slice motion, springs, gaze/blink/poke,
decorations (dots, sleep, tears, hearts), crown layers, deterministic per-state sampling, 15/20 fps
frame scheduling, pause on hidden/background/reduce-motion/low-power, and a static `still` mode.

**Persistence — exact.** Assets are read-only bundle resources under `BotFish/…` (`SOURCES.md:22-60`);
raster caches (base by hairstyle/color/crown/size; face by quantised signature) are in memory only
(`BotFishRenderer.swift:5-19`, `:203-360`). No database, no files written.

**External effects.** None. It consumes `BotFishAppearance` + `BotFishLifecycle` + `BotFishReaction`.

**Spec coverage today.** v1 §7 prose (“512×512 RGBA PNG and manifest, no placeholders; deterministic
state machine only, no JS/Canvas runtime”), `fish-director` vectors for the lifecycle, and
`spec/ui/v1/pages/bot-chat.md:11`, `:52-56` for the visual/interaction description. **There is no
renderer contract**: no layer list, no palette/LUT rule, no crop/anchor, no clip periods, no spring
constants, no sampling formula, no fps/pause rule, no numeric vector.

**Missing spec.** (a) Asset inventory + checksums + license and the `atlas.json` role
(`SOURCES.md` is outside `spec/`). (b) Layer/compositing order and the 416/448 crop, pivot
(256,350), design-space and ink colour (`BotFishRenderer.swift:89-135`, `:368-450`, `:1149-1210`).
(c) Per-state clip periods/durations and sampling (`BotFishModel.swift:118-170`, `:171-430`).
(d) Spring constants and controller stepping (`BotFishEngine.swift:61-100`, `:233-300`).
(e) Face-sprite atlas order and quantisation (`BotFishModel.swift:31-60`;
`BotFishRenderer.swift:44-88`). (f) Frame-rate/pause policy (`BotFishView.swift:60-100`).
(g) The numeric trajectory golden proposed in §8.

**Status.** `spec-missing`. **Blocked before B8 on D14.**

## 4. Dependency graph

The Bot runtime is one process with one SQLite authority. The arrows below are **compile/runtime
dependencies**, not ownership; a cycle is a design error unless it is an actor reference (the MCP
runtime owns the memory/routine stores and the team host calls back into the composition root).

```text
                       ┌──────────────────────────────────────────────┐
                       │ host seams (B0, other owners)                │
                       │ P05 /v1/http + exact MCP route gate          │
                       │ P16 PDSH_PHONE_MCP_URL/TOKEN, egress token   │
                       │ P08 Notifier + deep link + Clock             │
                       │ P14 DSH session/prompt/follow/cancel         │
                       │ P02 VFS writes for attachments               │
                       └───────────────┬──────────────────────────────┘
                                       │
                 ┌─────────────────────▼─────────────────────┐
                 │ S1 Store / Journal / event envelope (P25)  │
                 │  domain.sqlite, outbox, nonces             │
                 └───┬───────┬───────┬───────┬───────┬───────┘
                     │       │       │       │       │
        ┌────────────▼─┐ ┌───▼────┐ ┌▼──────┐ ┌▼─────┐ ┌▼─────────┐
        │ S2 Memory    │ │ S3 Rout│ │ S4    │ │ S5   │ │ S6 Watch │
        │  (replay)    │ │ ines   │ │ Wake  │ │ Proac│ │ dog/Lint │
        └──────┬───────┘ └───┬────┘ └┬──────┘ └┬─────┘ └────┬─────┘
               │             │       │         │            │
               │       ┌─────▼───────▼─────────▼────────────▼────┐
               │       │ S8 Authz / grants / approval (P26)      │
               │       │ S9 Gateway / tokens / attribution       │
               │       └─────────────────┬───────────────────────┘
               │                         │
               │       ┌─────────────────▼───────────────────────┐
               │       │ S7 MCP listener/handler/runtime (P05)   │
               │       │ catalog, cards, volatile, DSH remote    │
               │       └───────┬───────────────┬─────────────────┘
               │               │               │
               │       ┌───────▼──────┐ ┌──────▼────────┐
               │       │ S10 Team     │ │ S14 Ledger    │
               │       └───────┬──────┘ └───────────────┘
               │               │
        ┌──────▼───────────────▼──────────┐
        │ S11 Rows / UserAction / display │
        │ S12 Profile / roster            │
        │ S13 Attachments                 │
        └──────────────┬──────────────────┘
                       │
        ┌──────────────▼──────────────────┐
        │ S16 Bot UI pages / roster drawer│
        │ S15 FishDirector / reactions    │
        │ S17 BotFish renderer + assets   │
        └─────────────────────────────────┘
```

Key edges and why:

| From → To | Why | Evidence |
| --- | --- | --- |
| S1 → everything durable | Every durable subsystem appends/reads Bot events and some use the effect outbox. | `BotEventLog.swift:5-9`, `BotEffectOutbox.swift:54-95` |
| S2 → S1 | Facts are replayed from `memory.written`/`memory.forgotten`, not a table. | `SQLiteBotMemoryFactStore.swift:305-390` |
| S3 → S1, S4, S5, S7 | Routine snapshots are events; results are held-inbox items or proactive candidates; the run itself is a DSH turn. | `RoutineStore.swift:49-97`, `RoutineScheduler.swift:99-166` |
| S4 → S1, S3, S10 | Held items are snapshots; routine/agent/device branches feed the same block. | `WakeInbox.swift:147-190`, `:318-384` |
| S5 → S1, S3 | `proactive.considered` is durable; routine results are the main candidate. | `ProactiveEngine.swift:69-130`, `:180-230` |
| S6 → S1 | Flags are durable; units are in memory. | `BotWatchdogMonitor.swift:214-266` |
| S7 → S1, S8, S9, S14 | MCP execution authorizes, attributes, logs usage, and appends events. | `BotMCPRuntime.swift:477-540` |
| S8 → S1 | Grant recovery/audit are events; approvals are events. | `BotGrants.swift:148-235` |
| S9 → S7 | Tokens/attribution resolve the principal the MCP runtime executes as. | `BotTokenRegistry.swift:81-160`, `BotAttributionRegistry.swift:66-150` |
| S10 → S1, S4, S7, S11 | Team sends a target turn, writes `agent.comm`/rows and held items. | `BotTeamTools.swift:60-240` |
| S11 → S1, S7, S13 | Rows project durable/DSH events; actions send prompts/import attachments. | `BotSessionLogProjection.swift:280-330` |
| S12 → S1 | Profile deletion cascades into memory/routines/inbox/tokens. | `BotRuntimeComposition.swift:690-760` |
| S13 → host VFS | Attachments are files in the Bot workspace, not DB rows. | `BotAttachmentImporting.swift:17-26` |
| S16 → S11, S12, S13, S15 | UI reads rows/profile/appearance and sends actions. | `BotChatModel.swift:71-110` |
| S17 → S12, S15 | Renderer consumes appearance + lifecycle/reaction only. | `BotFishView.swift:18-40` |

Host/MCP/gateway edges that are easy to get wrong:

- **The Bot listener is a second loopback origin.** `LoopbackServer` is documented as “the one loopback
  origin” and carries the launch page, channel and `/mcp/native` (`android/net/src/main/kotlin/com/phonedsh/loopback/LoopbackServer.kt:1-3`;
  `LoopbackService.kt:139-215`). The Bot listener must be a separate Ktor CIO server with its own port
  and bearer, not a route on the existing origin: the spec requires its own origin check and token
  (`spec/bot/v1/mcp-endpoint.md:93-114`). A `BotMcpServing` seam in `:net` + implementation in `:bot`
  avoids a `:net → :bot` cycle, mirroring `NativeMcpServing` (`android/net/.../NativeMcp.kt:25-31`).
- **The Worker must reach the Bot listener through `/v1/http` egress, not a LAN route.** The egress
  gate is `GatewayHttpEgress` (`android/net/.../GatewayHttpEgress.kt:26-45`); it currently has no
  `X-PDSH-MCP-Egress` validation and no Bot-bearer injection. The exact-route predicate and the 403
  body are fixed by `spec/bot/v1/mcp-endpoint.md:28-91`.
- **P16's env builder conflates the Bot bearer with the loopback launch token.** `WorkerEnvironment`
  writes `PDSH_PHONE_MCP_TOKEN = launchToken` whenever a URL is passed
  (`android/engine/.../WorkerEnvironment.kt:66-79`); Bot mode needs the non-secret placeholder and a
  separate `PDSH_MCP_EGRESS_TOKEN` (`spec/bot/v1/mcp-endpoint.md:23-35`, `:87-91`).
- **The DSH transport is generic.** `DshTurnClient.call(endpoint,args)` can drive
  `session/cancel`/`session/archive`/`session/list` even though typed helpers exist only for
  create/prompt/follow (`android/dsh/.../DshTurnClient.kt:177-227`, `:302-331`, `:373-394`). No new
  wire method is needed; the Bot runtime must reuse `call`.
- **Do not mix P03 and P25.** `:dsh/journal/JournalStore` is the P03 `jseq` domain; the Bot log has its
  own `commitSeq` domain (`spec/bot/v1/README.md:13`; `android/dsh/.../JournalStore.kt:13-40`).
- **GAP-36 is a real B5 risk.** `/mcp/native` returns one buffered body, so a native tool forwarded by
  the Bot listener that runs over 60 s fails even though the Bot listener streams SSE
  (`spec/README.md:228`). The Bot listener can stream its own call, but it cannot make the native
  receiver stream; B5 must either fix `NativeMcpServing` or record a failed native long-call case.

## 5. Android baseline to build on

The Android tree is not empty: 13 Gradle modules, 104,603 Kotlin main lines at the 2026-11-01 snapshot
(`android/README.md:5-12`), JVM tests in every test-bearing module, and a Compose `:lib` that already
generates its tokens from `spec/ui/v1/tokens.json` (`android/lib/build.gradle.kts:100-140`).

| Need | What exists | Reuse / gap | Evidence |
| --- | --- | --- | --- |
| JSON value model | `com.phonedsh.agentcore.JsonValue`/`JsonObject`/`JsonArray`, manual parse/encode | Reuse; add a Bot-specific canonical encoder and codecs (no kotlinx.serialization dependency). | `android/core/src/main/kotlin/com/phonedsh/agentcore/JsonValue.kt` |
| SQLite | `:domain` `DomainStoreCore` + `SqliteConnection` for a key/value table; **no WAL, no arbitrary SQL** | Do **not** reuse as the Bot store. Add a `BotSql` seam in `:bot` over `android.database.sqlite`; JVM tests use a fake, device/Robolectric tests use real SQLite. | `android/domain/src/main/kotlin/com/phonedsh/domain/sqlite/SqliteConnection.kt:1-20` |
| Loopback HTTP | Ktor CIO `LoopbackServer`/`LoopbackService`, `NativeMcpServing`, 1 MiB egress body cap | Add a second listener in `:net`; reuse Ktor and the header/route discipline. | `android/net/.../LoopbackServer.kt:68-130`, `LoopbackService.kt:139-215` |
| Gateway/egress | `GatewayHttpEgress`, allowlist/credential/redaction rules, `x-pdsh-*` headers | Add the exact MCP-route gate + Bot bearer injection; do not create a second egress path. | `android/net/.../GatewayHttpEgress.kt:26-96` |
| Worker env | `WorkerEnvironment` builds `?env=`; launch token, `PDSH_PHONE_MCP_URL/TOKEN` | Add `PDSH_MCP_EGRESS_TOKEN` and a separate placeholder; P16 change. | `android/engine/.../WorkerEnvironment.kt:37-90` |
| DSH remote | `DshTurnClient` create/prompt/follow/call; `HostChannel`/`HostApi`; `HostEventProjection` | Reuse `call` for cancel/archive/list; map live frames to `BotDSHSessionEvent`-equivalent Kotlin types. | `android/dsh/.../DshTurnClient.kt:149-394`; `android/core/.../hostevents/` |
| Platform SPI | `Clock`, `Durability`, `Notifier`, `SecureStore`, `LifecycleSignals` | Use `Clock` for all timers; `Durability.atomicReplace` for profile JSON; `Notifier` lacks a deep link (gap). | `android/platform/.../Clock.kt`, `Durability.kt`, `Notifier.kt` |
| Preferences | `SharedPreferences` stores used by app settings | Add the Bot selection key through a typed store; P18 owns the key. | `android/app/.../PreferenceStore.kt` |
| Attachments | App writes chat attachments through `WorkspaceLog.appendMutation` into `/dsh/workspace/<name>` | Reuse the VFS mutation lane with the Bot `imports/attachments-<id>/` path; respect the `VfsSink` counter caveat already documented for chat. | `android/app/.../ProbeEngineViewModel.kt:3679-3701` |
| UI | Compose `:lib`, token codegen, 44 `*Page.kt`, card/composer primitives | Add Bot pages under `com.phonedsh.ui.bot`; reuse tokens and existing `ApprovalCard`/`Bubble`/`Composer` primitives where possible. | `android/lib/src/main/kotlin/com/phonedsh/ui/page/`, `ui/surface/` |
| Composition root | `:app` `ProbeEngineViewModel`, `HostShell`, `ChatTurnRunner` | Add a `BotHost` that owns one `BotRuntime` and binds it to the engine/host; do not put Bot logic in `:app`. | `android/app/.../ProbeEngineViewModel.kt:1540-1570` |

**What is deliberately absent.** No Android `BotRuntime`, no `BotMCP` listener, no Bot preferences, no
Bot pages, no Bot fish assets, no `agents-index.json`, no Bot SQLite schema, no Bot golden loader. The
module map has no `PhoneDSHBot` row at all (`spec/platform/android-module-map.json:1-101`), and
`structure_check.py` currently fails `readme-map` for `PhoneDSHBot`, `PhoneDSHPCLink`, `PhoneDSHVenus`
— a pre-existing red recorded in `docs/parity/lessons.md:11-12`; this plan must not “fix” it by adding
whitelist rows.

## 6. Proposed Kotlin modules and package layout

### 6.1 Modules

| Module | Type | Packages | Why |
| --- | --- | --- | --- |
| `:bot` (new) | Android library (`minSdk 26`, `targetSdk 35`) | `com.phonedsh.bot.{store,journal,memory,routines,wake,proactive,watchdog,authz,gateway,mcp,team,rows,profile,attachments,ledger,fish,host}` | One runtime module mirroring `Sources/PhoneDSHBot`; the only module that owns the Bot SQLite DB and the Bot MCP handler. |
| `:net` (existing) | JVM library | `com.phonedsh.loopback` | Owns the second loopback listener and the `BotMcpServing` interface (P05), so `:bot` does not open sockets directly. |
| `:lib` (existing) | Android library / published AAR | `com.phonedsh.ui.bot.*` + `assets/botfish/**` | P09 surfaces; keeps the published AAR the one UI entry point and reuses the token generator. |
| `:app` (existing) | probe app | `com.phonedsh.probe.BotHost` | Composition root only: construct `:bot`, start/stop it with the engine, inject platform services. |

Dependency direction (no cycles):

```text
:app ──► :lib ──► :bot ──► :dsh ──► :net ──► :core ──► :platform
  │                  │        │        │
  └──────────────────┴────────┴────────┴──► :platform-android (runtime only)
```

`:bot` uses `api(:core)`, `api(:platform)`, `api(:net)`, `api(:dsh)` so its public types (`BotEvent`,
`BotRow`, `BotProfile`, `BotFishLifecycle`) are visible to `:lib` without `:lib` re-declaring the
internal modules. `:lib` adds `api(project(":bot"))`; this changes the published POM, so it is a P12
change (module map + `android/README.md` + `structure_check.py` inventory). `:bot` must not depend on
`:lib` or `:app`.

### 6.2 Package tree

```text
android/bot/src/main/kotlin/com/phonedsh/bot/
├── BotJson.kt                 # JsonValue helpers, canonical encode, SHA-256 digest
├── BotClock.kt                # Clock wrapper, Long milliseconds, ISO-8601 formatting
├── store/
│   ├── BotDomainStore.kt      # open/pragmas/quick_check/user_version, transactions
│   ├── BotSql.kt              # prepare/bind/step seam; Android + fake implementations
│   ├── BotEventLog.kt         # append/batch/events(after:)/head, ephemeral ring
│   ├── BotEffectOutbox.kt     # states, leases, retry, dead-letter, reconciliation, inbox
│   └── BotUserActionNonce.kt  # performAndRecord in one BEGIN IMMEDIATE
├── journal/
│   ├── BotEventEnvelopeCodec.kt
│   ├── BotEventModels.kt      # BotEvent, BotPrincipal, BotEventOrigin, batch
│   └── GoldenOverlayLoader.kt # merge .phone.json per spec/bot/v1/README.md §8.1
├── memory/                    # fact, normalizer, tokenizer, injection, recall, store, replay
├── routines/                  # models, schedule math, machine, scheduler, store
├── wake/                      # item/document, inbox actor, held block, routine wake, turn origin
├── proactive/                 # models, policy, settings, engine, delivery seam
├── watchdog/                  # config, monitor, checks, context lint, profiles
├── authz/                     # grants, snapshot, authorizer, effects, patterns, audit, digest
├── gateway/                   # token registry, attribution, gateway resolver
├── mcp/                       # handler, runtime, catalog, card payloads, volatile, approval, routine tool
├── team/                      # team tools + host seam
├── rows/                      # row models, session-log projector, user action, display contract, limiter
├── profile/                   # profile store, roster, fish appearance
├── attachments/               # policy, prompt block, workspace layout, importer seam
├── ledger/                    # record, ledger, model purpose policy
├── fish/                      # lifecycle, director, event mapping, reactions, model/controller
└── host/                      # BotRuntime, BotRuntimeUnit, BotHost (composition)
```

`android/bot/src/test/kotlin/...` mirrors the packages for JVM tests; `src/androidTest/...` holds the
real-SQLite/listener/notification tests. `:lib` gets
`android/lib/src/main/kotlin/com/phonedsh/ui/bot/{BotChatPage,BotDrawer,BotInfoPage,BotCards,BotActivityLine,BotFishView,BotTheme}.kt`
and `android/lib/src/main/assets/botfish/`.

### 6.3 Rejected alternatives

- **Put everything in `:dsh`.** `:dsh` is the PhoneDSH facade (P06/P14); Bot is a separate Swift
  module and a separate protocol surface. Mixing it would make P25 events and P06 host events share one
  module and blur the `commitSeq`/`jseq` boundary (`spec/bot/v1/README.md:13`).
- **Put everything in `:lib`.** `:lib` is the UI AAR; a runtime with SQLite/listener/notification code
  does not belong in every consumer, and `:lib` is already large. The AAR should depend on `:bot`, not
  absorb it.
- **Split `:bot` into `:bot` (JVM) + `:bot-android`.** This is the `:platform`/`:platform-android`
  precedent, but here only one implementation exists and the SQLite/HTTP code is small. A `BotSql`
  seam plus Robolectric/instrumented tests gives the same JVM testability with one module fewer.
- **Room/SQLDelight.** The existing tree explicitly chose the framework helper over both
  (`android/domain/.../SqliteConnection.kt:1-8`); adding one now would be a second SQL dialect and a
  code generator for four tables.
- **KMP for `BotFish`.** The roadmap already rejected KMP: assets + Canvas + lifecycle would force an
  iOS rewrite (`docs/parity/android-parity-roadmap.md:9-11`).

## 7. Swift → Kotlin mapping table

| Swift construct (example) | Kotlin construct | Rule / risk |
| --- | --- | --- |
| `actor BotGrantStore` (`BotGrants.swift:69`) | `class BotGrantStore` + `kotlinx.coroutines.sync.Mutex` | All public methods `suspend`; no blocking inside the lock; one dispatcher for ordering. |
| `Task {}` / `Task.detached` | `CoroutineScope.launch` / `async` | Structured concurrency: the Bot runtime owns one `SupervisorJob` scope; cancellation must propagate to timers. |
| `Task.sleep(nanoseconds:)` | `delay(ms)` | Use `Clock` for deadlines and `delay` for ticks; never `Thread.sleep`. |
| `AsyncStream` / `AsyncThrowingStream` | `Flow` / `SharedFlow` (replay 1) | Roster/live-frame streams are hot; expose `StateFlow` for UI. |
| `CheckedContinuation` (`BotApprovalCoordinator`) | `CompletableDeferred<T>` | A pending approval is a map id→deferred; `resolve` completes it exactly once. |
| `Codable` + `JSONEncoder(.sortedKeys, .withoutEscapingSlashes)` | `BotJson` manual encoder over `JsonValue`, sorted keys | Do **not** use `org.json` key order; canonical bytes matter for digests and goldens. |
| `UserDefaults.standard.string(forKey:)` | `SharedPreferences.getString` | Selection key is `phoneDSH.bot.selectedBotID` (P18). |
| `FileManager.default.url(for: .applicationSupportDirectory…)` | `Context.filesDir` + `File("PhoneDSHBot/…")` | Android has no Application Support; the logical subtree must match (`PhoneDSHBot/domain.sqlite`, `agents-index.json`, `runtime-settings.json`). |
| `FileManager.replaceItemAt` + `0o600` | `Durability.atomicReplace` + `File.setReadable/Writable` | Reuse `:platform-android` `AndroidDurability`; do not hand-roll fsync. |
| `SQLite3` C API + `BEGIN IMMEDIATE` | `SQLiteDatabase` + `beginTransactionNonExclusive()` | Set WAL/synchronous explicitly; `PRAGMA user_version`; append-only triggers. |
| `NWListener` / `NWConnection` | Ktor CIO `embeddedServer` + `ServerSocket` probe | Bind `127.0.0.1` only; one port per listener; SSE needs `respondOutputStream`/`write` with flush. |
| `URLSession`/`URLRequest` | `HttpURLConnection` / existing `GatewayHttpEgress` transport | Do not add OkHttp; the tree has one blocking HTTP client. |
| `UNUserNotificationCenter` | `NotificationManagerCompat` + channel + `PendingIntent` | Needs `POST_NOTIFICATIONS` on API 33+; deep link must survive cold start (P08 gap). |
| `CryptoKit.SHA256` | `java.security.MessageDigest("SHA-256")` | Hex lowercase; digest input must be canonical UTF-8/JSON bytes. |
| `NSLock`/`OSAllocatedUnfairLock` | `ReentrantLock` or `Mutex` | Never hold a lock across `suspend`. |
| `Timer`/`Task` tick (`RoutineScheduler`) | `CoroutineScope.launch { while (isActive) { tick(); delay(5_000) } }` | One ticker per Bot unit; stop joins the job; no `GlobalScope`. |
| `CGContext`/`CGImage`/`UIImage` | `android.graphics.Bitmap`/`Canvas`/`Paint` | Render base/face layers into reusable bitmaps; `Canvas.drawBitmap` with `Matrix`. |
| `TimelineView(.animation)` | `withFrameNanos` in a `LaunchedEffect` or `Animatable` | Cap at 20 fps (15 fps ≤40 pt); pause on `Lifecycle.State` not RESUMED, reduce-motion, power-save. |
| `SwiftUI` `@Published`/`ObservableObject` | `ViewModel` + `MutableStateFlow` | UI state is immutable data classes; no Compose state in the runtime module. |
| `UTType`/`PhotosPicker`/`fileImporter` | `ActivityResultContracts.PickVisualMedia` / `OpenMultipleDocuments` + `ContentResolver` | SAF URI → bytes with a hard size cap before reading; persist permission not needed for one-shot import. |
| `ISO8601DateFormatter` / `Calendar` | `java.time.Instant`/`OffsetDateTime` + `ZoneId` | Millisecond timestamps are `Long`; format with `Locale.US` and the routine timezone. |
| `Locale.preferredLanguages` | `Locale.getDefault().language` | Used for zh/en prompt selection; must be captured at startup, not per call. |
| `ProcessInfo.isLowPowerModeEnabled` | `PowerManager.isPowerSaveMode` | Renderer pause only; no behavioural claims. |
| `Bundle.main.url(forResource:…)` | `context.assets.open("botfish/…")` | Assets are immutable; verify SHA-256 at startup in debug/golden tests. |
| `XCTest` + `@testable import` | JUnit 4 + Robolectric (JVM), `AndroidJUnit4` (device) | Goldens are read from `spec/**` via `-Dpdsh.repo.root` (same pattern as `:lib`). |

## 8. Ordered checkpoints

Rules for every checkpoint:

- A checkpoint starts only when its delta(s) are frozen by the contract owner; “write the code and
  adjust the spec later” is not allowed (`AGENTS.md` §3.1–3.2).
- Tests must drive the **real** Kotlin codec/state machine against the shared JSON on disk, never a
  hand-copied fixture (`docs/parity/lessons.md:13`).
- Owned paths are disjoint from other workers. A path not listed is not touched.
- Size is Kotlin LOC **including tests**, estimated as iOS lines × 0.7–0.9 plus a 0.5–0.7 test ratio;
  it is an estimate, not a measurement. The basis is the Swift line count in §2.
- `PASS` requires the command to exit 0 and the test XML to show the named cases. A simulator run is
  never a device claim; a JVM run is never a WebView/notification claim.

### B0 — Host seams and module registration (prerequisite, other owners)

**Goal.** Make the Kotlin module buildable and give the runtime the five host seams it cannot
provide itself.

**Owned paths (not this plan’s files).**
`android/settings.gradle.kts`, `android/bot/build.gradle.kts` (new), `android/README.md`,
`spec/platform/android-module-map.json`, `android/tools/structure_check.py` (inventory only, not the
pre-existing readme-map red), `android/engine/src/main/kotlin/com/phonedsh/engine/WorkerEnvironment.kt`,
`android/net/src/main/kotlin/com/phonedsh/loopback/BotMcpListener.kt` (new),
`android/net/src/main/kotlin/com/phonedsh/loopback/BotMcpServing.kt` (new),
`android/net/src/main/kotlin/com/phonedsh/gateway/McpEgressPolicy.kt` (new/decorator),
`android/platform/src/main/kotlin/com/phonedsh/platform/Notifier.kt` (deep-link extension) plus its
Android implementation, and the P05/P08/P12/P16/P18 contract updates they follow.

**Gate.** `spec/platform/android-module-map.json` gets a `PhoneDSHBot` row with `status: "target"`
(not `mapped` until B1 lands); `android/README.md` gets the corresponding row; `structure_check.py`’s
hardcoded 13-module inventory becomes 14. The pre-existing `readme-map` failure for
`PhoneDSHPCLink`/`PhoneDSHVenus` is **left as is** and reported, not fixed (`docs/parity/lessons.md:11-12`).

**Goldens to pass.** No Bot behaviour yet; the module-map vector golden
(`spec/platform/golden/android-module-map-cases.jsonl`) must cover the new `PhoneDSHBot` row and its
`target` status, and `structure_check.py` must not report a Bot-specific failure.

**Commands → expected.**
`python3 android/tools/structure_check.py --root .` → all checks except the known PCLink/Venus
readme-map rows pass; `settings-includes` and `module-inventory` say 14.
`bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS (contract edits belong to the
owners of those files).

**Size.** 400–700 Kotlin LOC + ~100 lines of spec/README edits. No Bot behaviour.

### B1 — Store / Journal / event envelope + goldens

**Goal.** `domain.sqlite` with the exact schema/pragmas, append-only event log, commitSeq assignment,
ephemeral ring, outbox leases/retry/dead-letter/reconciliation, nonce transaction, and the merged
golden loader.

**Owned paths.**
`android/bot/src/main/kotlin/com/phonedsh/bot/{BotJson.kt,BotClock.kt,store/**,journal/**}`;
`android/bot/src/test/kotlin/com/phonedsh/bot/{store,journal}/**`;
`android/bot/src/androidTest/kotlin/com/phonedsh/bot/store/**`;
`android/bot/build.gradle.kts` (test wiring, `pdsh.repo.root`).

**Depends on.** B0, D1, D2, CCR-1, CCR-2.

**Goldens to pass.**
`spec/bot/v1/golden/event-envelope.json` (2 valid / 4 invalid; frozen error codes),
`event-envelope.phone.json` (2 valid / 1 invalid; `agent.comm` + `comm-service`),
plus the new store vectors from D2: append assigns 1..n, duplicate eventId returns the original
sequence, commit gap fails, ephemeral has no commitSeq, lease expiry re-leases, permanent fail
dead-letters, unknown outcome needs reconciliation, nonce duplicate is a duplicate, crash before/after
commit.

**Acceptance commands.**
```bash
bash android/tools/with-android-toolchain.sh ./gradlew \
  :bot:testDebugUnitTest --tests 'com.phonedsh.bot.journal.*' --tests 'com.phonedsh.bot.store.*'
python3 spec/bot/v1/tools/validate_vectors.py
python3 spec/tools/bot/check_golden.py --root .
```
Expected: PASS, and the JUnit XML contains the event-envelope phone cases by name (not just a total).
`check_golden.py` without a dsh-bot checkout validates the manifest/overlays; it does not re-export
upstream, so a pass is not “upstream byte-identical” (`spec/bot/v1/README.md:185`).

**Size.** 2,800–3,400 LOC.

**Exit criteria.** A Kotlin-only reader can decode every valid envelope and reject every invalid one
with the same code; a killed process reopens the DB and `quick_check` passes; no event is updated or
deleted (trigger test); all timers are injectable (`Clock`), no `Thread.sleep`.

### B2 — Memory

**Goal.** Fact normalization, write/forget/erase, injection rendering (zh + en), recall scoring, and
event-sourced replay with per-Bot isolation.

**Owned paths.** `android/bot/src/main/kotlin/com/phonedsh/bot/memory/**` and its tests; the memory
branches of the MCP runtime are **not** in this checkpoint (B5 wires them).

**Depends on.** B1, D10.

**Goldens to pass.** `memory-fact.json` 4/2 (normalization + invalid), `memory-injection.json` 2/2
(verbatim text; `<FIXTURE_ROOT>` substitution), `memory-recall.json` 1/0 (score within 1e-6), plus the
new vectors from D10: 2,000-code-point cap, 80-code-point condition, single-line folding, user-scope
downgrade, forget exact-match, erase tombstone, agent isolation, English injection.

**Commands.**
```bash
bash android/tools/with-android-toolchain.sh ./gradlew \
  :bot:testDebugUnitTest --tests 'com.phonedsh.bot.memory.*'
python3 spec/bot/v2/tools/validate_vectors.py
```
Expected: PASS; the injection test compares the **whole** rendered string, not a substring.

**Size.** 3,000–4,000 LOC.

### B3 — Routines and Wake/Held inbox

**Goal.** The routine state machine/scheduler and the durable held inbox are one checkpoint because
they share the snapshot envelope, the quiet-hours rules and the run→delivery path.

**Owned paths.** `android/bot/src/main/kotlin/com/phonedsh/bot/{routines/**,wake/**}` and tests.

**Depends on.** B1, D8, D9.

**Goldens to pass.** `wake-routine.json` 8/3 (wake text, quiet reply, held block, automation status,
delivery flags), `held-inbox.json` 4/2 + `held-inbox.phone.json` 2/1 (agent-held and device-task-result),
plus new vectors from D8/D9: tick/timeout/lease, overlap skip, quiet defer, crash retry vs
needs-reconciliation, retry/acknowledge resolution, staging commit/revert/recover, request-id dedupe,
200/20 bounds.

**Commands.**
```bash
bash android/tools/with-android-toolchain.sh ./gradlew \
  :bot:testDebugUnitTest --tests 'com.phonedsh.bot.routines.*' --tests 'com.phonedsh.bot.wake.*'
python3 spec/bot/v2/tools/validate_vectors.py
```
Expected: PASS; a fake clock advances a due routine exactly once and a killed run becomes
`needs-reconciliation` (not silently re-run).

**Size.** 4,500–5,500 LOC.

### B4 — Proactive / Watchdog / Ledger

**Goal.** Admission/fuse/notification accounting, observe-only watchdog flags, context lint,
usage ledger and the model-purpose policy (with an explicit enforcement point).

**Owned paths.** `android/bot/src/main/kotlin/com/phonedsh/bot/{proactive/**,watchdog/**,ledger/**}` and
tests.

**Depends on.** B1, B3 (routine results), D5, D6, D7, and B0’s Notifier deep link.

**Goldens to pass.** `watchdog.json` 3/1 (config, five flags, three mobile signals),
`context-profiles.json` 2/1, `context-lint.json` 1/0, `llm-ledger.json` 15/2,
`model-purpose-policy.json` 2/1, plus new vectors from D5–D7: fuse restore, DND/quiet exceptions,
mode off/would/on, delivery failure not consuming the fuse, one flag per unit/check, lint thresholds,
cache-hit formula, model-tier rejection.

**Commands.**
```bash
bash android/tools/with-android-toolchain.sh ./gradlew \
  :bot:testDebugUnitTest --tests 'com.phonedsh.bot.proactive.*' \
  --tests 'com.phonedsh.bot.watchdog.*' --tests 'com.phonedsh.bot.ledger.*'
python3 spec/bot/v1/tools/validate_vectors.py
```
Expected: PASS. **Not verified by this command:** a real Android notification (needs a device and
`POST_NOTIFICATIONS`), thermal/battery signals, and any model call. Record them as `NOT_RUN`.

**Size.** 2,800–3,600 LOC.

### B5 — MCP endpoint + Authz / egress / session credentials

**Goal.** The Bot listener and JSON-RPC surface, the tool catalog/cards/volatile context, grant
recovery/authorization/approval, token/attribution, and the `/v1/http` egress gate.

**Owned paths.**
`android/net/src/main/kotlin/com/phonedsh/loopback/{BotMcpListener,BotMcpServing}.kt`,
`android/net/src/main/kotlin/com/phonedsh/gateway/McpEgressPolicy.kt`,
`android/net/src/test/kotlin/com/phonedsh/loopback/BotMcp*`,
`android/bot/src/main/kotlin/com/phonedsh/bot/{mcp/**,authz/**,gateway/**}` and tests.

**Depends on.** B0, B1, B2, D1, D13 + CCR-2.

**Goldens to pass.** `mcp-egress.phone.json` 17/25 (three suites: egress/identity/tools-call),
`approval-patterns.json` 5/1, `tool-effects.json` 21/2 + `tool-effects.phone.json` 3/0 + `nativeMcp`,
`tool-catalog.json` 2/6 + `tool-catalog.phone.json` (team/fish entries),
`card-payload.json` 12/2 + `card-payload.phone.json` 6/2, `volatile-context.json` 2/3,
plus new vectors from D13: JSON-RPC method results/errors, `/identity/register|cancel`,
`/approval` request/response, approval expiry/cancel, per-caller catalog denial, long-call SSE
timing, token TTL/rotation/incarnation, grant snapshot recovery failure.

**Commands.**
```bash
bash android/tools/with-android-toolchain.sh ./gradlew \
  :net:test --tests 'com.phonedsh.loopback.BotMcp*' \
  :bot:testDebugUnitTest --tests 'com.phonedsh.bot.mcp.*' \
  --tests 'com.phonedsh.bot.authz.*' --tests 'com.phonedsh.bot.gateway.*'
python3 spec/bot/v1/tools/validate_vectors.py
```
Expected: PASS. The HTTP listener test must use a real socket on `127.0.0.1` and assert 401/403/405/404
plus the exact SSE headers; a mock that bypasses the socket is not evidence.

**Size.** 7,500–9,500 LOC. This is the largest checkpoint; if it must be split, split
`authz/approval` from `MCP listener/handler` at the same contract revision.

### B6 — Team / SendToAgent / tasks

**Goal.** `SendToAgent`/`CreateTeammate`, agent-comm rows, held replies, hop/cycle limits, idempotency,
and durable task snapshots/restore/interrupted wakes.

**Owned paths.** `android/bot/src/main/kotlin/com/phonedsh/bot/team/**`,
`android/bot/src/main/kotlin/com/phonedsh/bot/mcp/BotDSHRemoteRuntime.kt` (task branch only),
`android/bot/src/main/kotlin/com/phonedsh/bot/rows/BotAgentComm.kt`, and tests.

**Depends on.** B1, B3, B5, B7a (agent-comm row model), D12.

**Goldens to pass.** `tool-catalog.phone.json` team block (roster line, required properties),
`tool-effects.phone.json` team entries, `held-inbox.phone.json` agent-held,
`event-envelope.phone.json` 2/1 (`agent.comm` outbound/inbound),
`row-protocol.phone.json` projection vector, plus new vectors from D12: prompt text, thread/row ids,
depth 2, cycle, self-target, duplicate call id, queued vs now, 300 s timeout, interrupted task wake,
`persistedTask` restore.

**Commands.**
```bash
bash android/tools/with-android-toolchain.sh ./gradlew \
  :bot:testDebugUnitTest --tests 'com.phonedsh.bot.team.*' \
  --tests 'com.phonedsh.bot.mcp.*Task*' --tests 'com.phonedsh.bot.rows.*AgentComm*'
```
Expected: PASS. A real two-Bot turn is `NOT_RUN` unless a Worker/model is available; the deterministic
test drives a fake `BotTeamHost`.

**Size.** 1,800–2,400 LOC.

### B7a — Rows / UserAction / projection / Profile / Attachments

**Goal.** The projector and display contract, the durable user-action transaction, the roster/profile
store, attachment import, and the exact display surface rules the UI consumes.

**Owned paths.** `android/bot/src/main/kotlin/com/phonedsh/bot/{rows/**,profile/**,attachments/**}`,
`android/bot/src/main/kotlin/com/phonedsh/bot/store/BotUserActionNonce.kt`, and tests.

**Depends on.** B1, B6 (agent-comm), D3, D4, D11.

**Goldens to pass.** `row-protocol.json` 5/2, `row-protocol.phone.json` 3 valid + 4 invalid actions +
1 projection, `row-projection.json` 20/1, `bot-attachments.json` (limits, 4 parse, 8 kindFor),
`bot-profile.json` (15 colors, 4 hairstyles, seed cases, 4 pointer-repair + 3 delete-main rules),
`user-action.schema.json`, `action-result.schema.json`, plus new vectors from D11: row ids/entrySeq,
surfaceOp replace, tombstones, cursor reset, progress cardKey, card expiry/stale, display hidden/
notice/agent-comm/P1 rules, `chatActionNonce`.

**Commands.**
```bash
bash android/tools/with-android-toolchain.sh ./gradlew \
  :bot:testDebugUnitTest --tests 'com.phonedsh.bot.rows.*' \
  --tests 'com.phonedsh.bot.profile.*' --tests 'com.phonedsh.bot.attachments.*'
python3 spec/bot/v1/tools/validate_vectors.py
```
Expected: PASS. The projection test reads the real golden JSON from `spec/bot/v1/golden/` and asserts
`BotRow` fields, not a re-serialized approximation.

**Size.** 3,800–4,800 LOC.

### B7b — Bot UI pages, cards, roster drawer

**Goal.** The Bot tab (chat, composer, cards, activity line), the roster drawer/add/manage dialogs, the
info page (appearance/memory/routines/approvals), deep links, and the Compose screenshots.

**Owned paths.** `android/lib/src/main/kotlin/com/phonedsh/ui/bot/**`,
`android/lib/src/test/kotlin/com/phonedsh/ui/bot/**`,
`android/lib/src/androidTest/kotlin/com/phonedsh/ui/bot/**`,
`android/lib/src/main/assets/botfish/**` (shared with B8),
`android/app/src/main/kotlin/com/phonedsh/probe/BotHost.kt` (wiring only).

**Depends on.** B7a, B8 (fish view can land behind a placeholder), D15.

**Goldens/contracts to pass.** `spec/ui/v1/pages/bot-chat.md`, `bot-drawer.md`, `bot-info.md` (target;
accessibility ids and geometry), `spec/ui/v1/tokens.json` (all values via the generated accessors),
`spec/ui/v1/interaction.md` (44 pt targets, drawer), plus the new page JSON contracts from D15 if the
owner converts them to the machine-checked format. **No Bot page JSON exists today**, so
`page_structure_check.py` does not compare these pages; do not claim it as evidence.

**Commands.**
```bash
bash android/tools/with-android-toolchain.sh ./gradlew \
  :lib:testDebugUnitTest --tests 'com.phonedsh.ui.bot.*'
bash android/tools/with-android-toolchain.sh ./gradlew :app:assembleDebug
```
Screenshots (only with an emulator): `:lib:connectedDebugAndroidTest --tests '*BotScreenshot*'`.
`python3 -B spec/ui/v1/tools/page_structure_check.py --root .` is **NOT_RUN for Bot pages** until the
page JSON exists; its current 12-divergence result is a pre-existing red (GAP-35 and friends), not a
B7b result.

Expected: JVM Compose tests PASS; `assembleDebug` PASS; screenshots `NOT_VERIFIED` on this machine if
no emulator is started. The five states in `bot-chat.md` §5 (light/dark, narrow, long title, dynamic
type, 44 pt) must be listed with what was actually captured.

**Size.** 7,000–9,000 LOC.

### B8 — BotFish renderer + numeric trajectory

**Goal.** The pure fish model/controller in `:bot` and the Canvas/Bitmap renderer in `:lib`, plus the
numeric trajectory golden and the asset checksum gate.

**Owned paths.** `android/bot/src/main/kotlin/com/phonedsh/bot/fish/**`,
`android/lib/src/main/kotlin/com/phonedsh/ui/bot/fish/**`,
`android/lib/src/main/assets/botfish/**`,
`android/bot/src/test/kotlin/com/phonedsh/bot/fish/**`,
`android/lib/src/test/kotlin/com/phonedsh/ui/bot/fish/**`.

**Depends on.** B7a (appearance), D14.

**Goldens to pass.** `fish-director.json` 1 vector / 1 invalid (step-by-step state/command),
`tool-catalog.phone.json` fish block (16 actions, 8 expressions), `tool-effects.phone.json`
`FishAction`, plus the new `fish-trajectory.json` from D14: 10 lifecycle states × 6 times, 4 one-shots,
crowned/non-crowned pose, 15×4 appearance signatures, 3 seeded controller replays; tolerance 1e-6 for
params and pose.

**Commands.**
```bash
bash android/tools/with-android-toolchain.sh ./gradlew \
  :bot:testDebugUnitTest --tests 'com.phonedsh.bot.fish.*' \
  :lib:testDebugUnitTest --tests 'com.phonedsh.ui.bot.fish.*'
python3 spec/bot/v1/tools/validate_vectors.py
```
On macOS, the reference half:
```bash
swift test --filter PhoneDSHBotTests.BotFishDirectorTests
swift test --filter PhoneDSHBotTests.BotFishReactionTests
```
The cross-end trajectory comparison is a new tool from D14:
`python3 spec/bot/v1/tools/fish_trajectory_compare.py --golden … --android … [--ios …]`. Until that
tool exists, the Kotlin test compares against the golden only; the iOS half is `NOT_RUN`.

Expected: PASS for director/reaction/model/pose; a rendered screenshot comparison is a **secondary**
gate and never the cross-end parity proof.

**Size.** 4,500–6,000 LOC.

**Total estimate.** ~38,000–48,000 Kotlin LOC including tests, against 37,058 lines of Swift
runtime/UI. The range is wide because the contract deltas may add vectors and because Compose tends to
be shorter than SwiftUI for the same layout but longer for custom Canvas work.

## 9. BotFish: iOS rendering and the Compose port

### 9.1 How iOS renders today

1. **Assets.** `BotFish/base/{body,fixed,face-mask,eyes-open,eyes-white,iris-left,iris-right,blush}.png`,
   three hair variants, `expressive/{eyes,mouths}.png` (3×4 cells of 256×128), `overlays/crown*.png`,
   and `atlas.json`; 512×512 RGBA, `body.png` is greyscale and tinted by the Bot colour LUT
   (`examples/probe-app/BotFish/SOURCES.md:8-30`).
2. **Two cached layers.** `BotFishRenderer.prepare` builds a **base** layer (body/fixed/crown/blush/
   eye whites) and a **face** layer (eyes/iris/brows/mouth/tears/decoration) at display resolution,
   with keys over `(hairstyle, colour, crowned, size)` and a quantised face signature; the layers are
   reused until the signature changes (`BotFishRenderer.swift:5-19`, `:203-260`, `:368-450`).
3. **Pose on the GPU.** The whole-fish translate/rotate/scale is **not** rasterised; SwiftUI applies it
   with `scaleEffect`/`rotationEffect`/`offset` around the source pivot (0.5, 320/416 normal or
   340/448 crowned) (`BotFishView.swift:142-158`). Pose is quantised: offset 0.25 output px, roll 0.1°,
   scale 0.5/target, alpha 1/64 (`BotFishEngine.swift:519-541`).
4. **Head slicing.** At sizes >40 pt the base/face are sliced into 8 px head rows and displaced per row
   for head motion; the slice quantum is 0.1 source units (`BotFishRenderer.swift:131-165`,
   `:1149-1190`).
5. **Frame clock.** `TimelineView(.animation(minimumInterval:))` at 20 fps, 15 fps for ≤40 pt; paused
   when the Bot tab is off-screen, app backgrounded, `still`, reduce-motion or low-power; a paused view
   paints one frame and keeps it (`BotFishView.swift:60-100`, `:166-180`).
6. **State model.** `BotFishStateMachine` holds springs (gaze/head/body/morph omega 23/8/5/13, face 22),
   blink/poke/idle timers, a one-shot reaction overlay, and `BotFishModel.sample(state,time)` produces
   all animated parameters (`BotFishEngine.swift:61-100`, `:233-300`; `BotFishModel.swift:118-430`).

### 9.2 Compose port approach

- **Same two-layer cache, different pixels.** `BotFishAssets` decodes `Bitmap`s from
  `assets/botfish/**`, builds the colour LUT once per (hair, colour, crowned) and caches the base/face
  `Bitmap`s in an `LruCache` keyed like iOS. `BotFishRenderer` draws into two `Bitmap`s sized
  `size * displayScale` using `android.graphics.Canvas`; `BotFishView` composes them with
  `Image(bitmap.asImageBitmap())` and a `Modifier.graphicsLayer { scaleX/scaleY/rotationZ/
  translationX/translationY }` around the same pivot. The renderer never scales a 512 px image per
  frame.
- **Frame clock.** A `LaunchedEffect(state, reaction, still, size)` loop uses `withFrameNanos` and
  skips frames to hit 20/15 fps. Pause conditions come from `LocalLifecycleOwner` (RESUMED),
  `PowerManager.isPowerSaveMode`, `LocalAccessibilityManager`/`Settings.Global.ANIMATOR_DURATION_SCALE`
  for reduce-motion, `still`, and a `botFishPaused` composition local fed by the selected tab (the
  equivalent of the iOS environment key, `BotFishView.swift:185-196`). On pause, draw the last frame
  once and cancel the loop.
- **Poke and reaction.** A `pointerInput` tap calls `machine.poke()` only when `allowsPoke && !still`.
  A reaction is keyed by its id so recomposition does not replay it; the one-shot overlay expires by
  model time, not wall-clock.
- **Head slicing.** Port `sliceImage` with the same 8 px/0.1-unit quantisation; skip at `size <= 40` as
  iOS does. This is CPU work on the two cached bitmaps, not per-pixel Compose work.
- **Assets.** Copy `examples/probe-app/BotFish/**` into `android/lib/src/main/assets/botfish/**` with
  the directory structure preserved (`base/`, `hair/…`, `crowned/…`, `expressive/`, `overlays/`,
  `atlas.json`). The copy is a build-time/Gradle task or a reviewed commit; either way, the asset tree
  gets a SHA-256 manifest and a test that fails on a missing/changed layer. Licensing stays the
  upstream `SOURCES.md` provenance; the Android copy must carry the same notice.

### 9.3 Numeric-trajectory golden proposal

The renderer cannot be compared pixel-for-pixel across Core Graphics and Android Canvas (different
rasterisers, fonts, colour management). The **model and pose** can: they are pure functions of state,
time and appearance. Freeze those.

**Files (owned by P26/P09, to be created by D14):**
`spec/bot/v1/golden/fish-trajectory.json`, `spec/bot/v1/fish-trajectory.schema.json`,
`spec/bot/v1/tools/fish_trajectory_compare.py`.

**Shape.**

```json
{
  "schemaVersion": 1,
  "vector": "fish-trajectory",
  "source": {"checkout": "bf4075b0a2e8092b04b726c59a7b085d5a37e6f6"},
  "viewport": {"sizePt": 64, "displayScale": 2, "crowned": false},
  "cases": [
    {
      "name": "idle-64",
      "state": "idle",
      "reaction": null,
      "timesMs": [0, 250, 500, 1000, 2000, 4000],
      "frames": [
        {
          "timeMs": 0,
          "params": {
            "eyeL": 1, "eyeR": 1, "joy": 0, "browL": 0, "browR": 0,
            "anger": 0, "sorrow": 0, "smile": 0.55, "mouth": 0, "mouthWidth": 1,
            "round": 0, "blush": 0, "tears": 0, "love": 0, "gazeX": 0, "gazeY": 0,
            "x": 0, "y": 0, "sx": 1, "sy": 1, "alpha": 1,
            "finL": 0, "finR": 0, "finWave": 0, "finFold": 0, "hairSway": 0,
            "breath": 0, "puff": 0, "decoration": "", "progress": 0, "phase": 0,
            "eyeArt": null, "mouthArt": null, "headX": 0, "headY": 0
          },
          "pose": {"offsetX": 0, "offsetY": 0, "roll": 0, "scaleX": 1, "scaleY": 1},
          "alpha": 1,
          "static": false
        }
      ]
    }
  ]
}
```

`params` is the full `BotFishParams` struct (`examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishModel.swift:63-115`):
the fragment above is illustrative, and the fixture must also carry `bodyX`, `bodyY`, `blink`,
`morphX`, `morphY`, `artMix`, `earFlutter`, `eyeArtPrev`, `mouthArtPrev`, `finFold`, `breath`, `puff`
and `motionScale` where the renderer consumes them. A missing key is a fixture error, not “default”.

**Cases required.**
1. The ten P0 lifecycles from `bot-chat.md:52-56` (`idle`, `thinking`, `streaming`, `working`,
   `sleeping`, `alerting`, `listening`, `speaking`, `happy`, `sad`) at the six times above.
2. Four one-shots: `celebrate`, `poke`, `waving`, `bowing` (first frame, mid-clip, end, after TTL).
3. Crowned vs non-crowned at `idle`, t=0 (the crop and pivot change).
4. The 15 colours × 4 hairstyles at `idle`, t=0: freeze the resolved `BotFishAppearance`, the seed and
   the layer keys; not the pixels.
5. Three seeded controller replays: fixed `dt` sequence (16.67 ms), a fixed `random` array, and
   `blink`/`poke`/reaction events at named times; freeze every `step()` output. The random array is in
   the fixture, so neither end calls a system RNG.

**Comparison rules.**
- `params` are compared with absolute tolerance `1e-6`; enum/art names and `static` exactly.
- `pose` is computed by each end at the fixture’s fixed viewport using the documented quantisation
  (0.25 px, 0.5/target scale, 0.1°, 1/64 alpha) and compared with `1e-6` after quantisation.
- A missing/extra frame or case is a failure; ordering is by `timeMs`, then case name.
- Both ends must emit the same normalized JSON shape. The Swift side writes
  `/tmp/fish-trajectory-ios.json`; the Kotlin side writes `build/reports/fish-trajectory-android.json`;
  `fish_trajectory_compare.py` diffs both against the golden and prints the first divergent path.
- CI without macOS runs the Kotlin→golden half only and records the iOS half as `NOT_RUN`. A simulator
  screenshot set remains a regression gate, not a substitute.

**Why this is enough for the port.** The risky part of BotFish is not “does Canvas draw a circle”, it is
whether the Kotlin model produces the same spring/blink/gaze/slice parameters as Swift at the same
instant. The trajectory freezes exactly that, with numbers both ends can reproduce, and it does not
depend on GPU, font or colour profile.

## 10. Risks, unknown or unverified items, and needed outside my scope

### 10.1 Risks

| Risk | Why it matters | Mitigation / owner |
| --- | --- | --- |
| P25 required-null and `authz.grant_snapshot` defects (CCR-1/2) | A Kotlin encoder written to the schema produces different stored bytes and cannot replay iOS snapshots (or vice versa). | Freeze the presence rule and register the event type before B1; add both-end vectors. Owner: P25 contract owner. |
| Proactive has no production caller | The “parity” target would be the first implementation; no runtime evidence exists. | Treat S5 as new behaviour; freeze D6 and require a device notification test. Owner: P26. |
| Bot listener is a second loopback origin | The Android tree documents “the one loopback origin”; a second listener can bypass the existing token/egress assumptions. | B0 adds an explicit second-listener contract with its own token/origin, and the egress gate remains the only path from the Worker. Owner: P05/P08. |
| `/mcp/native` cannot stream (GAP-36) | A native tool forwarded by the Bot listener can hit the 60 s idle limit. | Fix `NativeMcpServing` streaming or add a negative vector; do not lengthen timeouts. Owner: P05 (`spec/README.md:228`). |
| SQLite durability claims | Robolectric/JVM tests do not prove WAL/power-loss behaviour; Android `SQLiteDatabase` may override `synchronous`. | Device test with kill/power-cut; report only measured level (`spec/v1/wal.md`/`:platform` `DurabilityLevel`). Owner: P02/P08. |
| Profile JSON path differs | iOS uses Application Support; Android has no such directory. A path mismatch breaks “same roster on both ends”. | Freeze the logical subtree, not the absolute path; migrate/import is out of scope. Owner: P18. |
| Compose animation vs SwiftUI | Frame pacing and Canvas text/anti-aliasing differ; pixel parity is not achievable. | Numeric trajectory + a small screenshot regression set; never claim pixel parity. |
| No Bot page JSON | `page_structure_check.py` cannot check `bot-chat.md`/`bot-drawer.md` as pages. | D15 converts the three pages to the machine-checked format or records the gap. Owner: P09. |
| iOS-only status | `v1`/`v2` READMEs still say `target` while change records say `implemented`; Android cannot cite either as runtime proof. | CCR-6: reconcile status with evidence per `spec/README.md:34-46`. Owner: P25/P26. |

### 10.2 Not verified by this plan

- No Kotlin code exists; every size is an estimate, and no checkpoint command has been run for a Bot
  module (the module does not exist yet).
- No device measurement: SQLite WAL durability, notification delivery, thermal/battery signals,
  background execution, memory pressure and 15/20 fps rendering are all `NOT_RUN`.
- No cross-end BotFish trajectory exists; the proposal in §9.3 is not a golden until D14 lands.
- The upstream dsh-bot checkout is not present; `check_golden.py` can validate the manifest/overlays
  but cannot re-export and compare upstream bytes (`spec/bot/v1/README.md:185`).
- `structure_check.py` currently fails `readme-map` for `PhoneDSHBot`, `PhoneDSHPCLink`,
  `PhoneDSHVenus` — pre-existing (`docs/parity/lessons.md:11-12`); it is not a Bot-port result and must
  not be “fixed” by widening the inventory.

### 10.3 Needed outside my scope

1. **P25 contract owner:** CCR-1 (required-null presence + ephemeral envelope) and CCR-2
   (`authz.grant_snapshot` enum/durable membership); D1/D2.
2. **P26 contract owner:** D5–D10, D12–D14 (ledger enforcement, proactive, watchdog/lint, wake,
   routines, memory, team/tasks, fish renderer).
3. **P27 contract owner:** D11 (projection/display/action rules), D3 (attachments phone delta).
4. **P09 contract owner:** CCR-3 (agent-comm sentence), CCR-4 (bot-dock vs HomeTabBar), D15 (Bot page
   JSON).
5. **P05/P08/P12/P16/P18 owners:** B0 listener/egress/env/notification/module-map/selection-key
   changes; `spec/platform/android-module-map.json` + `android/README.md` + `structure_check.py`
   inventory.
6. **P14/P06 owner:** confirm `session/cancel`/`session/archive`/`session/list` are supported by the
   packaged Worker and add typed helpers or document the `call()` path.
7. **P02 owner:** the Bot attachment write path shares `WorkspaceLog.appendMutation` with chat; the
   `VfsSink` counter caveat documented in `ProbeEngineViewModel.kt:3700-3715` must be addressed before
   Bot attachments use it at scale.
