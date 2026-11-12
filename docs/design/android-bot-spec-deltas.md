<!-- SPDX-License-Identifier: MIT -->
# Android Bot port — spec deltas the contract owner must write

Status: **proposal, documents only.** Date: 2026-11-12 · base `56e7b6ce`.
Companion: [`android-bot-port-plan.md`](android-bot-port-plan.md). This file is the ordered list of
contract additions that must be frozen **before** each Bot checkpoint. It does not edit `spec/**`.

How to read an entry:

- **Target** — the owning contract/document that must change (new file or existing section).
- **Why** — the behaviour a Kotlin implementer cannot reproduce today, with the Swift source that
  demonstrates it. Swift is provenance, not authority: the delta states the behaviour to freeze, not
  “copy this file”.
- **Section outline** — the clauses to write. Values are quoted with their source; the owner may change
  a value, but then it is a new decision, not a port.
- **Fixtures** — the shared JSON/schema/golden that both ends will run through their real codec.
- **Compatibility** — what old readers/writers and old on-disk data do.
- **Acceptance** — the concrete command/case that proves the clause.

Ordering is smallest-first within the Bot contract, but the dependency column is authoritative: D1/D2
must precede B1, D10 must precede B2, and so on. D0 is a prerequisite owned by other contracts.

Path convention: a bare `BotX.swift` is `Sources/PhoneDSHBot/BotX.swift`; a prefix such as `MCP/`,
`Rows/`, `Memory/` is relative to `Sources/PhoneDSHBot/`. App-side names are under
`examples/probe-app/PhoneDSHProbe/Bot/`. `android/`, `spec/` and `docs/` paths are from the repo root.

## 0. Order and mapping

| Delta | Contract(s) | Target checkpoint | Size (contract work) | Blocks |
| --- | --- | --- | --- | --- |
| D0 | P05/P08/P12/P16/P18 | B0 | S–M (five owners) | B0–B8 |
| D1 | P25 | B1 | S | B1 |
| D2 | P25 | B1 | L | B1 |
| D3 | P27 | B7a | S | B7a |
| D4 | P26 | B7a | M | B7a |
| D5 | P26 | B4 | S–M | B4 |
| D6 | P26 v2 | B4 | L | B4 |
| D7 | P26 | B4 | M | B4 |
| D8 | P26 v2 | B3 | L | B3 |
| D9 | P26 v2 | B3 | XL | B3 |
| D10 | P26 v2 | B2 | XL | B2 |
| D11 | P27 | B7a | XL | B7a |
| D12 | P26/P27 | B6 | XL | B6 |
| D13 | P05/P26 | B5 | XL | B5 |
| D14 | P09/P26 | B8 | XL | B8 |
| D15 | P09 | B7b | M | B7b |

`S` ≈ a page or two and a handful of vectors; `M` ≈ a new section plus 5–10 vectors; `L` ≈ a new
normative document plus 10–20 vectors; `XL` ≈ a state machine/persistence document plus a new golden
family. “Size” is contract effort, not Kotlin LOC (the plan’s §8 has LOC).

## 1. Contract change requests (resolve before writing the deltas)

These are defects/contradictions in the current contract, not gaps that a delta can quietly fill. Per
`AGENTS.md` §3.3 the implementer stops that part until the owner revises.

### CCR-1 — P25 envelope cannot represent nil required members or ephemeral events

```
CONTRACT CHANGE REQUEST
Contract: P25 @ event-envelope-v1
Clause: spec/bot/v1/event-envelope.schema.json#/required and #/properties/principal/required
Problem: the schema requires `botId`, `sessionId`, `causationId`, `correlationId`, and every event
requires `commitSeq`. Swift's synthesized Codable omits nil optionals (`BotEvent.swift:51-63`,
`:88-94`), so a stored event with a nil bot/session or a nil causation/correlation is emitted without
those keys. Observed with a standalone Swift 6.2 snippet on this machine (the shape of `BotPrincipal`:
`struct P: Codable { let botId: String?; let sessionId: String?; let kind: String }`, encoded with
`JSONEncoder`): `P(botId:nil, sessionId:nil, kind:"ipc")` yields `{"kind":"ipc"}`. The same encoder emits
durable events with `BotPrincipal(botId:nil, sessionId:nil, kind:"ipc")` (e.g. `authz.grant_snapshot`,
`effect.*`), so those payloads do not validate against the schema. Separately, ephemeral types must
not carry `commitSeq` (`BotEventEnvelopeCodec.swift:124-131`) while the only schema always requires it.
The golden `event-envelope.json` uses explicit `null` for `causationId`, which hides the divergence
because the test only compares selected fields, not schema validity
(`Tests/PhoneDSHBotTests/Journal/BotEventEnvelopeTests.swift:7-22`).
Proposal: (a) add a normative “presence” clause: every `required` member is present; a nullable
required member is encoded as explicit `null`, never omitted; (b) make the Swift encoder emit explicit
nulls for `principal.botId`, `principal.sessionId`, `causationId`, `correlationId` (and keep
`turnId`/`runId`/`attempt`/`batch`/`ignorable` omitted when nil because the schema does not require
them); or alternatively change the schema to allow omission for those four — choose one and test both
ends; (c) publish a separate ephemeral envelope schema (no `commitSeq`, no durable write) or state that
the existing schema is durable-only; (d) add positive/negative vectors for both.
Affects: Swift P25 writer, Kotlin P25 writer, every stored-event consumer, row/memory/routine replay
(which decode the stored bytes), and the `stored` mode validator.
```

### CCR-2 — `authz.grant_snapshot` is required by prose but absent from the event enum

```
CONTRACT CHANGE REQUEST
Contract: P25 @ event-envelope-v1
Clause: spec/bot/v1/README.md §2.3 (lines 64-67) vs spec/bot/v1/event-envelope.schema.json#/properties/type
Problem: §2.3 says “使用 `authz.grant_snapshot` durable 事件保存完整当前 Grant 集合”, and Swift writes it
(`Sources/PhoneDSHBot/Authz/BotGrantSnapshot.swift:13`, `:150-159`), but the `type` enum has no such
value and `BotEventEnvelopeCodec.durableEventTypes` has no such entry
(`Journal/BotEventEnvelopeCodec.swift:27-45`). The write only succeeds because unknown types are
allowed when `ignorable: true` (`:134-138`) and the snapshot sets `ignorable: true`
(`BotGrantSnapshot.swift:159`). A schema-validating reader therefore rejects the only record that can
restore grants; a Kotlin reader that follows the schema would silently lose standing grants.
Proposal: add `authz.grant_snapshot` to the type enum and the durable set, with the snapshot `data`
shape frozen in D8 (grants array, 11 entry fields, no unknown members). If the owner prefers not to
make it a BotEvent, move it to a dedicated `authz_store` record and say so explicitly; do not leave a
durable event type that the owning schema cannot describe.
Affects: Swift grant recovery, Kotlin B5, P25 golden/validator, any old-store reader.
```

### CCR-3 — `bot-chat.md` both forbids and requires agent-comm rows

```
CONTRACT CHANGE REQUEST
Contract: P09 @ bot-chat.md target
Clause: spec/ui/v1/pages/bot-chat.md:46 vs :11 and spec/ui/v1/pages/bot-drawer.md:40
Problem: §3 says “canvas、product、gift、Bot 间通讯行不实现”, while §1 and the drawer page define
agent-comm rows and their avatars; `spec/bot/v1/README.md:24` and
`PC-20261109-bot-team-tools` also freeze the row directions. The shipped iOS UI renders them
(`examples/probe-app/PhoneDSHProbe/Bot/BotAgentCommRendering.swift`). An Android implementer cannot
tell whether to build the rows.
Proposal: remove “Bot 间通讯行” from the not-implemented list (keep canvas/product/gift), or state
precisely which agent-comm surface is P0/P1. Add the row to the P0 card/row list if it is P0.
Affects: P09 page contract, P27 row projection, Android B6/B7b, iOS screenshots/capture scripts.
```

### CCR-4 — `bot-dock.md` describes a different bottom bar from the shipped `HomeTabBar`

```
CONTRACT CHANGE REQUEST
Contract: P09 @ bot-dock.md target
Clause: spec/ui/v1/pages/bot-dock.md:1-20 vs examples/probe-app/PhoneDSHProbe/HomeTabBar.swift:1-30
Problem: bot-dock specifies a 64 pt standalone Chat circle plus a 3-item capsule
(Chat/DSH/发现/个人). The shipped iOS `HomeTabBar` is four equal columns (Bot/DSH/发现/我的), and
`android/lib/.../HomeTabBar.kt:6-7` deliberately follows the shipped file (three columns minus Bot).
The Bot port cannot add a tab until the owner decides which design is the target.
Proposal: either (a) declare bot-dock the target and rewrite `HomeTabBar`/the Android bar in a later
P09 change, or (b) mark bot-dock as a superseded proposal and keep four equal columns. Record the
decision in bot-dock.md and the page contract; do not leave two authorities.
Affects: P09, Android B7b, iOS `HomeTabBar`, existing Android bottom-bar tests.
```

### CCR-5 — The attachment golden freezes the Mac sentence, not the phone sentence

```
CONTRACT CHANGE REQUEST
Contract: P27 @ bot-attachments golden + user-action schema
Clause: spec/bot/v1/golden/bot-attachments.json#/promptBlock vs
         Sources/PhoneDSHBot/Attachments/BotAttachmentPrompt.swift:9-11
Problem: the golden's `prompt` says “They are saved on this Mac”; the phone implementation uses
“They are saved in your workspace”. The Swift test synthesizes the phone prompt by replacing the Mac
sentence in the golden (`Tests/PhoneDSHBotTests/Attachments/BotAttachmentGoldenTests.swift:17-30`), so
the phone bytes are not frozen anywhere. `safeName` is only tested in Swift (`:70-86`), not in the
golden. A Kotlin implementation cannot know the exact phone block or the sanitizer vectors.
Proposal: add a phone-only overlay (e.g. `golden/bot-attachments.phone.json` with
`promptBlockPhone`, `safeNameCases`, and the `imports/attachments-<messageID>/` path rule), leave the
upstream file byte-identical, and have both the Swift and Kotlin tests read the merged overlay. Do not
edit the upstream golden.
Affects: P27, iOS attachment tests, Android B7a, any transcript replay that parses the block.
```

### CCR-6 — `target` vs `implemented` status is inconsistent across the Bot registry

```
CONTRACT CHANGE REQUEST
Contract: P25/P26/P27 @ spec/README.md §3.1 and spec/bot/v{1,2}/README.md
Clause: spec/bot/v1/README.md:5, spec/bot/v2/README.md:5 vs
         docs/protocol-changes/PC-20261109-bot-team-tools.md:5-6,
         PC-20261111-bot-agent-comm-envelope.md:5-6
Problem: both owning READMEs say `target`, while change records marked `implemented` say Swift runtime
tests passed (431 tests, a bot-e2e gate). `spec/README.md:34-46` defines `implemented` as every
registered end implemented with runtime evidence, and `target` as not callable. Android cannot decide
whether to treat the Swift behaviour as a reference or a target, and reviewers cannot cite a status.
Proposal: reconcile the status per contract part (P25/P26/P27 and v2 memory/wake/proactive) using §2’s
vocabulary, record the runtime evidence next to each row, and do not upgrade a part merely because a
schema/golden checker passes.
Affects: registry rows, Android plan statuses, future “parity” claims.
```

### CCR-7 — Routine snapshots omit required nullable members (same class as CCR-1)

```
CONTRACT CHANGE REQUEST
Contract: P26 @ spec/bot/v2/routine.schema.json
Clause: #/required (`run_state`, `quiet_defer`, `next_run_at`, `last_result`)
Problem: these four members are required and nullable, but Swift `Routine` declares them optional and
its synthesized Codable omits nil (`RoutineModels.swift:169-200`, `:275-390`). The full
`RoutineDocument` is JSON-encoded into a durable event (`RoutineStore.swift:87-95`;
`DurableSnapshot.swift:5-9`), so a new routine with no run yet stores a document that does not validate
against the routine schema. A Kotlin implementation that emits explicit nulls produces different
snapshot bytes (and a different replay hash) from iOS.
Proposal: apply the CCR-1 presence rule to the routine snapshot, and add a `RoutineDocument` schema (or
explicitly declare the document's encoding) so both ends produce the same bytes; include vectors for
“new routine”, “deferred”, “started”, “needs-reconciliation” and “deleted”.
Affects: P26 routine store, P25 event payload consumers, Android B3, old routine snapshots.
```

## 2. Deltas

### D0 — Host seams the Bot runtime cannot provide (P05/P08/P12/P16/P18)

**Target.** `spec/bot/v1/mcp-endpoint.md` is already the Bot listener contract; this delta adds the
Android host pieces it presumes, in their owning contracts:

- P05: a second `127.0.0.1` HTTP listener with its own bearer and origin, the exact-route egress gate,
  and SSE for long calls. The listener is not a route on the existing loopback origin.
- P16: `PDSH_MCP_EGRESS_TOKEN` (≥128 bits, lowercase hex, per host start) and the non-secret
  `PDSH_PHONE_MCP_TOKEN` placeholder, separate from the launch token.
- P08: a Bot notification delivery surface with a deep link (`phonedsh://bot/<botID>/row/<rowID>`) and
  the permission/availability result.
- P18: the selected-Bot preference key and its default.
- P12: the `PhoneDSHBot` module-map row and the 14-module structure inventory.

**Why.** `WorkerEnvironment.pageParam` currently writes `PDSH_PHONE_MCP_TOKEN = launchToken`
(`android/engine/src/main/kotlin/com/phonedsh/engine/WorkerEnvironment.kt:66-79`), which is exactly the
“real Bot bearer in the Worker” that `mcp-endpoint.md:23-35` forbids. `GatewayHttpEgress` has no
`X-PDSH-MCP-Egress` check (`android/net/src/main/kotlin/com/phonedsh/gateway/GatewayHttpEgress.kt:26-45`).
`Notifier` has no deep link (`android/platform/src/main/kotlin/com/phonedsh/platform/Notifier.kt:20-55`).
`LoopbackServer` is documented as the one origin (`android/net/src/main/kotlin/com/phonedsh/loopback/LoopbackServer.kt:1-3`).
The module map has no `PhoneDSHBot` row (`spec/platform/android-module-map.json:1-101`).

**Section outline.**

1. P05 §“Android second listener”: bind IPv4 loopback only; one bearer per listener; exact paths
   `/mcp`, `/identity/register`, `/identity/cancel`, `/approval`; POST only; origin check; 1 MiB body;
   SSE at 5 s/15 s; no query/trailing slash; 405/404/400/401/403 mapping; listener recovery (prefer
   last port, probe 1.5 s, rebind, announce the new URL).
2. P05 §“Egress gate”: before credential resolution, test the target against the exact scheme/host/
   effective-port/normalized-path predicate; require `X-PDSH-MCP-Egress` equal to the current token in
   constant time; 403 with `mcp_egress_forbidden` and the frozen body; strip the header before the
   upstream request; cover user connector routes.
3. P16 §“Bot Worker environment”: `PDSH_PHONE_MCP_URL` is the listener URL; `PDSH_PHONE_MCP_TOKEN` is
   the placeholder; `PDSH_MCP_EGRESS_TOKEN` is the per-start secret; rotation on host restart, not on
   Worker restart; the page URL and Worker never see the bearer.
4. P08 §“Bot notification”: stable notification id, title/body, deep link, dedupe key, permission
   result (`ENABLED|DISABLED`), and what the UI shows when disabled.
5. P18 §“Bot selection”: key `phoneDSH.bot.selectedBotID`, value is a Bot id or absent; default to the
   roster main Bot; no migration needed (new key).
6. P12 §“Module map”: `PhoneDSHBot → com.phonedsh.bot → :bot`, status `target` until B1, then
   `mapped`; update `android/README.md` and the `structure_check.py` inventory to 14 modules.

**Fixtures.** No Bot JSON. Keep `spec/platform/golden/android-module-map-cases.jsonl` in sync for the
new row; add a case for an absent/`target` Bot row. P05 egress has shared vectors already
(`spec/v1/golden/gateway/*`); add the exact Bot route to the existing route table if the owner wants
one table.

**Compatibility.** The second listener is new surface, no old data. The egress gate fails closed for an
old Worker (no header), which is the documented new-App/old-Worker pair
(`mcp-endpoint.md:235-245`). The selection key is new; an absent key falls back to the main Bot.

**Acceptance.**
```bash
python3 android/tools/structure_check.py --root .          # 14 modules; only the known PCLink/Venus readme rows may remain
bash scripts/ci/check.sh --only phone-spec,phone-cross-tree
grep -R "PDSH_MCP_EGRESS_TOKEN" android/engine android/net # must find the P16 wiring, not a test-only constant
```
A real 403/SSE test is device/desktop-host evidence, not a JVM mock.

---

### D1 — P25 envelope presence, ephemeral envelope, grant-snapshot and memory-document types (S) — FROZEN

**Status.** Frozen. The presence rule, ephemeral envelope and `authz.grant_snapshot` type were frozen by
[PC-20261112-bot-contract-repairs](../../docs/protocol-changes/PC-20261112-bot-contract-repairs.md)
(`contract_revision c48f5f13831bc17d53afc5a6552ae813520394bb`). The two `memory.document_*` durable types were
added by PC-20261112-android-bot-w4 lane C2 under `P25-store-v3`. This section is now a record of what is
frozen and where; it is not a proposal, and the original “explicit null writer” outline is superseded.

**Frozen decisions (normative).**

1. **Presence.** For `principal.botId`, `principal.sessionId`, `causationId`, `correlationId` and the routine
   snapshot members, **absent ≡ null**. A reader MUST accept absent and explicit `null` as the same nil value.
   A writer MUST omit a nil member; it MUST NOT write explicit `null` for them. The one exception is each
   `authz.grant_snapshot` grant entry, whose 11 fields are all required and whose `sessionId`/`expiresAt` are
   written as explicit `null` when nil. See `spec/bot/v1/README.md` §1.2.
2. **Optional members.** `turnId`, `runId`, `attempt`, `batch`, `ignorable` stay optional and omitted when
   absent; `ignorable` may only be `true` or omitted. Other required members are always present.
3. **Canonical encoding.** UTF-8 JSON, sorted object keys, `/` not escaped, no insignificant whitespace.
   The stored payload bytes and the digest over them are the canonical bytes (the store profile is
   `spec/bot/v1/store.md` §5).
4. **Durable vs ephemeral.** `event-envelope.schema.json` is durable-only (`commitSeq >= 1`). Ephemeral
   events never carry `commitSeq`, are never stored, and use the closed
   `event-envelope.ephemeral.schema.json`. The closed type lists are
   `BotEventEnvelopeCodec.durableEventTypes` / `ephemeralEventTypes`.
5. **Type registration.** `authz.grant_snapshot` is a durable type; its data is frozen by
   `authz-grant-snapshot.schema.json` (11 fields per entry, no unknown members). `memory.document_written`
   and `memory.document_deleted` are durable types (already present in
   `Sources/PhoneDSHBot/Journal/BotEventEnvelopeCodec.swift:27-48`) and are now also in
   `event-envelope.schema.json`'s `type` enum. Their `data` is the memory write/delete object owned by the
   bot/v2 memory contract; the envelope does not open it.
6. **Unchanged.** The origin and principal closed sets, non-empty `eventId`/`traceId`, the batch rules and the
   frozen validation error codes (`INVALID_EVENT`, `SCHEMA_TOO_NEW`, `EPHEMERAL_HAS_COMMIT_SEQ`,
   `UNKNOWN_REQUIRED_EVENT`, `COMMIT_SEQ_ASSIGNED_BY_STORE`, `MISSING_COMMIT_SEQ`) stay as they are.

**Where frozen.**

- **Location decision.** The `type` enum lives in `spec/bot/v1/event-envelope.schema.json`. That file is
  phone-owned, not an upstream export: `export-manifest.json` lists only `golden/*.json`, and earlier
  contract repairs already edited the schema. The phone addition therefore goes in the schema's enum and in
  the `event-envelope.phone.json` overlay; no upstream-pinned file is touched and no contract change request
  is needed for the location.
- `spec/bot/v1/README.md` §1.2; `spec/bot/v1/event-envelope.schema.json`;
  `spec/bot/v1/event-envelope.ephemeral.schema.json`; `spec/bot/v1/authz-grant-snapshot.schema.json`.
- Shared vectors: `spec/bot/v1/golden/event-envelope.phone.json` (13 valid / 4 invalid, plus one valid and
  one invalid ephemeral case). The two memory-document cases are `memory-document-written` and
  `memory-document-deleted`; the invalid pair removes `commitSeq` from the written event
  (`MISSING_COMMIT_SEQ`) and replaces the deleted event's `data` with an array (`INVALID_EVENT`, field
  `data`).
- Swift conformance: `Tests/PhoneDSHBotTests/Journal/BotEventEnvelopeTests.swift` reads the merged golden
  through the real `BotEventEnvelopeCodec`; it asserts the two types are durable and that the canonical
  writer bytes equal the golden bytes.

**Compatibility.** Old iOS rows omit the nullable members and the new reader decodes them as nil; explicit
`null` in the upstream golden also decodes. A new writer still omits nil, so old readers (`decodeIfPresent`)
accept new rows. The enum repair only accepts events Swift already wrote; an old schema-only validator that
rejects unknown enum values would reject those rows, and the repair makes the schema match the writer. No
`schemaVersion` bump and no data rewrite. Rollback to an old writer is allowed; it omits again.

**Remaining.** Kotlin has no Bot runtime yet, so the Kotlin encoder/decoder has not run these vectors
(Android B1/A1). The memory document `data` shape has its own v2 owner and validators; this delta does not
freeze its field semantics. If a future upstream export starts writing a different enum, the upstream golden
must be re-exported, not hand-edited.

**Acceptance.**
```bash
python3 spec/bot/v1/tools/validate_vectors.py     # schema-validates every envelope case
swift test --filter PhoneDSHBotTests.BotEventEnvelopeTests
```

---

### D2 — P25 store/outbox persistence profile (L) — FROZEN

**Status.** Frozen by `spec/bot/v1/store.md` at contract revision `P25-store-v3`
(PC-20261112-android-bot-w4 lane C2). This supersedes the original outline’s `user_version=2` and
single `bot_events` table: the implemented and frozen profile is **`user_version=3`** with
`bot_event_headers` + `bot_event_payloads` + the read-only `bot_events` view. The file is the owning
description of what runs in `Sources/PhoneDSHBot/{Store,Journal}` today.

**Frozen decisions.** The short form; `store.md` is authoritative:

1. **File and open.** `<app-private support root>/PhoneDSHBot/domain.sqlite` plus `-wal`/`-shm`; one
   database per App. `journal_mode=WAL` (confirmed `wal`), `synchronous=FULL`, `foreign_keys=ON`,
   `secure_delete=ON`, 5,000 ms busy timeout, `quick_check=ok`; `user_version` 1/2 migrates, 3 opens,
   `>3` is `schemaTooNew` without touching the file.
2. **Schema.** Exact DDL in `store.md` §3: `bot_event_headers` (append-only triggers), `bot_event_payloads`
   (erasure-only UPDATE, no DELETE), the four-column `bot_events` view (JSON1), `bot_effects` (26 columns,
   lease candidate index), `bot_effect_inbox` (`receiver, effect_key, generation` PK) and
   `bot_user_action_nonces` (`bot_id, nonce` PK; unique `event_id` FK to `bot_event_headers(event_id)`).
3. **commitSeq.** Assigned only inside the store’s `BEGIN IMMEDIATE`, starting at 1, `+1` per durable
   event, contiguous per batch. Caller supply is `COMMIT_SEQ_ASSIGNED_BY_STORE`. A single duplicate
   `eventId` returns the committed sequence and appends nothing; a batch with a committed or repeated
   `eventId` is `invalidTransition`. A gap is `commitGap(expected:actual:)`/`corrupted`.
4. **Payload bytes.** `bot_event_payloads.payload` is canonical JSON of `data` only; `payload_digest` is
   SHA-256 over those exact bytes; `payload_size` is their byte length; `header_meta` is the canonical full
   envelope with `data:{}`. Erasure replaces bytes with `NULL`, keeps digest/size and writes an `erasure`
   event; the view returns the `$erased` sentinel.
5. **Migration.** v1/v2 → v3 decodes each old full-envelope payload, checks `commit_seq`/`event_id`/`type`,
   splits, copies nonces, sets `user_version=3` in one transaction; idempotent on reopen. The reference
   migrates before its contiguous scan; a v2 gap therefore becomes a v3 file that is refused at open (the
   vector asserts the refusal, not the post-failure version).
6. **Effects outbox.** States, enqueue generation idempotence, lease candidate order
   `(not_before, enqueued_commit_seq, effect_key)`, lease TTL (default 30,000 ms), attempt/attempts
   semantics, expiry takeover (`generation+1`), terminal states, permanent/exhausted dead-letter, unknown
   outcome `needs_reconciliation` with reason `unknown-outcome`, retry delay only for
   `network-idempotent` = `min(1000*2^(attempt-1), 300000)` ms, reconciliation/cancel rules, and inbox
   dedupe by `(receiver, effect_key, generation)` returning the stored result without re-executing.
7. **User action.** One transaction appends the action event, every `effect.enqueued` event and the
   `(bot_id, nonce)` row. Result codes are exactly `accepted`/`duplicate`/`stale`/`rejected`; a replay
   returns `duplicate` with the original `eventID`; validation rejects/stales without consuming the nonce;
   an event-id conflict or duplicate/used effect key is `invalidTransition` and consumes no nonce.
8. **Integrity.** Open and `verifyIntegrity()` check `quick_check`, `foreign_key_check`, contiguous
   `commit_seq`, header/metadata agreement, payload size/digest, erasure references and nonce references;
   any failure is `corrupted`/`commitGap` and the store does not open.

**Fixtures and shared evidence.**

- `spec/bot/v1/golden/store.phone.json`: 17 valid / 11 invalid cases (140 executable steps), covering
  sequence assignment/dedupe/batch/ephemeral, canonical payload bytes + digests (27-byte v2 example), the
  v1/v2→v3 split rows and nonce copy, gap/future-version refusal, and outbox enqueue/lease/expiry/renew/
  retry/dead-letter/reconciliation/cancel/inbox/crash-rollback.
- `spec/bot/v1/golden/user-action-transaction.phone.json`: 5 valid / 9 invalid cases (70 steps), covering
  accepted event+effects+nonce atomicity, duplicate after reopen, before/after-commit crash behavior,
  per-Bot nonce isolation, event-id conflict, and the rejected/stale reasons.
- `python3 spec/bot/v1/tools/validate_vectors.py` recomputes the canonical payloads/digests and runs a
  reference state model with mutation self-checks for the sequence, digest, effect state, backoff,
  duplicate and nonce values.
- Swift `Tests/PhoneDSHBotTests/Store/BotStoreVectorTests.swift` and
  `BotUserActionTransactionVectorTests.swift` run the same JSON through the real `SQLiteDomainStore`,
  `BotEffectOutbox` and `performAndRecord`.

**Compatibility.** v1/v2 files migrate in place; no event bytes of existing rows are rewritten except the
v3 split (same event identity, same `data`). A v1/v2-only App opening a v3 file refuses it with
`schemaTooNew`; no downgrade. The table/column names are the on-disk contract: a reader may add indexes,
not rename/drop columns; a new column needs a backfill or an optional default. Old rows without the
`erasure` markers keep their payloads. The store vectors are phone-only (`"upstream": []`); the upstream
`event-envelope.json` remains byte-identical.

**Remaining / not frozen.**

- Android implementation (`:bot` B1) and its real SQLite build: `Context.filesDir`, WAL,
  `synchronous=FULL`, `foreign_keys`, `secure_delete`, JSON1 availability and the 5 s timeout are not yet
  verified on a device. If a pragma cannot be honoured, report it; do not claim Level 2 durability.
- Power-loss/kill/reopen (`SqliteRecovery`) is not in this repository; no repository test cuts power.
- Erasure has DDL/triggers and reference tests but no dedicated shared vector yet.
- Two Swift-path divergences are recorded as contract change requests in the wave-4 handoff and are **not**
  frozen here: the v2-gap migration-order asymmetry (`store.md` §7 item 8, CCR-W4-C2-2) and the App runner’s
  second lease ordering (`store.md` §9.7, CCR-W4-C2-1). The Android port must not copy either until the owner rules.
- `store.md` is not yet linked from `spec/README.md` §3.1/§4 (P25 row) or `spec/bot/v1/README.md` §1; those
  registry edits belong to the contract owner.

**Acceptance.**
```bash
python3 spec/bot/v1/tools/validate_vectors.py
swift test --filter 'BotStoreVectorTests|BotUserActionTransactionVectorTests'
python3 spec/tools/bot/check_golden.py --root .
```

---

### D3 — Attachments: phone prompt, safe names, import layout (S)

**Target.** `spec/bot/v1/README.md` §“Attachments” (new), plus a phone-only overlay
`spec/bot/v1/golden/bot-attachments.phone.json`; register it in `export-manifest.json` as
`upstream: []` / `phoneOverlays`.

**Why.** CCR-5. The upstream golden freezes “saved on this Mac” (`bot-attachments.json#/promptBlock`);
the phone uses a different sentence (`Sources/PhoneDSHBot/Attachments/BotAttachmentPrompt.swift:9-11`),
and the Swift test synthesizes it (`Tests/PhoneDSHBotTests/Attachments/BotAttachmentGoldenTests.swift:17-30`).
`safeName` exists only in Swift and a unit test (`BotAttachment.swift:66-95`). A Kotlin implementer
cannot reproduce the exact prompt/parse bytes or the sanitizer from the owning contract.

**Section outline.**

1. **Limits.** `maxAttachments = 10`, `maxBytes = 26,214,400` (25 MiB), one message may carry both text
   and attachments; an empty list is valid (`bot-attachments.json#/limits`;
   `BotAttachmentPolicy`, `BotAttachment.swift:24-30`).
2. **Prompt block.** Empty list → `""`. Otherwise append `\n\n` then:
   `[dshbot-attachments]`, one sentence, one `- {json}` line per item, `[/dshbot-attachments]`.
   For phoneDSH the sentence is exactly
   `The user attached these files. They are saved in your workspace; read them with your file tools when the task needs their contents.`
   The JSON line key order is `name,path,size,mimeType,kind`; only JSON control escapes are used;
   `/` is not escaped (`BotAttachmentPrompt.swift:13-70`). The upstream Mac sentence stays in the
   upstream file and is not edited.
3. **Parse.** Find the first open marker and the next close marker; visible text is everything before
   the open marker, trimmed; text after the close marker is dropped (matching upstream); missing
   marker returns the input unchanged; lines that are not valid `- {json}` are skipped
   (`BotAttachmentPrompt.swift:30-55`; four parse vectors in the golden).
4. **Kinds.** The 10 values and the exact case-sensitive MIME prefix / extension fallback order
   (`BotAttachment.swift:33-64`; eight `kindFor` vectors). Unknown → `file`; `.HEIC` is `image` via
   the extension fallback.
5. **safeName.** Basename on `/` and `\`; replace every UTF-16 unit outside
   `[A-Za-z0-9._\- ()U+4E00–U+9FFF]` with `_`; strip leading dots; cap 120 UTF-16 units; empty → `file`;
   a non-BMP scalar becomes two underscores (the upstream JS behaviour)
   (`BotAttachment.swift:66-95`; Swift test `:70-86`). Add 10 vectors including `🐟.png → __.png`.
6. **Import layout.** Write each accepted file to
   `<botDataDirectory>/agents/<safeBotID>/imports/attachments-<messageID>/<unique safeName>`, where
   `botDataDirectory` defaults to `/dsh/workspace/.dshbot`; the path the model sees is the import
   commit path, never a local constant (`BotWorkspaceLayout.swift:18-60`;
   `BotAttachmentImporting.swift:17-26`; app `BotProductionServices.swift:518-540`).
7. **Partial success.** Per-item failure is reported as `(name, reason)`; accepted items still send;
   over-limit files are rejected before reading; empty/unreadable files are errors
   (`BotProductionServices.swift:464-520`). The exact user-visible strings are UI strings, not wire;
   the code/field names are.
8. **Count/size enforcement.** The UI limits at selection time; the runtime re-checks before import and
   rejects a non-`chat` action with attachments (`BotUserAction.swift:234-248`).

**Fixtures.** New `bot-attachments.phone.json` with `promptBlockPhone` (the exact phone bytes for the
two golden items), `safeNameCases` (10), `importPathCases` (bot id with `/`, unicode, `..`), and
`partialSuccessCases` (4). The upstream `bot-attachments.json` must remain byte-identical and its
`promptBlock` keeps the Mac sentence. The Swift test changes from “replace the Mac sentence” to “read
the phone overlay”; the Android test does the same.

**Compatibility.** Additive overlay; an old reader ignores it. The upstream export check must still
pass with no diff (`spec/bot/v1/README.md:169-176`). The prompt sentence is model-visible, so changing
it later is a contract change, not a copy-edit.

**Acceptance.**
```bash
python3 spec/tools/bot/check_golden.py --root .       # manifest includes the new overlay, upstream unchanged
python3 spec/bot/v1/tools/validate_vectors.py         # schema/negative cases
```
Kotlin: `:bot:testDebugUnitTest --tests '*Attachment*'`; the test must compare the whole prompt string
and every safeName vector.

---

### D4 — Profile/roster store: files, records, repair, cascade (M)

**Target.** New `spec/bot/v1/profile-store.md`; extend `bot-profile.schema.json` with a
`record`/`agentsIndex` definition (the current schema is a vector, not the record), or add
`profile-store.schema.json`.

**Why.** The record keys, atomic write, corrupt quarantine, name/description limits, color normalization
and selection key are only in Swift (`Profile/BotProfile.swift:1-130`, `:707-767`, `:790-858`;
`Profile/BotFishAppearance.swift:101-168`; `examples/probe-app/PhoneDSHProbe/Bot/BotProfileStorage.swift:8-20`).
`bot-profile.schema.json` freezes the seed/roster rules but not the file format, so a Kotlin port could
write a file the desktop app cannot read.

**Section outline.**

1. **Files.** `agents-index.json` `{ "schemaVersion": 3, "agents": [record…] }` and
   `runtime-settings.json` `{ "version": 1, "mainAgentId": "<id>"|null, "updatedAt": <ms> }` under the
   app’s private support root in a `PhoneDSHBot/` directory (`BotProfile.swift:118-125`).
2. **Record.** Keys and types exactly: `schema` (number 3), `id` (non-empty string), `name` (trimmed
   1–60), `fish_color` (enum or null), `fish_hairstyle` (enum or null), `name_explicit` (bool),
   `created_at`/`updated_at` (ms int), `description` (≤2,000 UTF-16 units), `hidden_by_user` (bool),
   `pinned` (bool), `unread_count` (≥0), `last_message_at` (ms int or null)
   (`BotProfile.swift:728-753`). Unknown members are preserved on write (`:1-10`, `:728-753`).
3. **Read.** Missing file = empty; unreadable/invalid JSON is moved to `<name>.corrupt-<ms>` and read
   as empty; if the backup fails, writes are refused (`BotProfile.swift:124-127`, `:838-858`). An
   invalid record is skipped, not fatal (`makeProfile`, `:707-726`).
4. **Write.** Pretty-printed, sorted keys, trailing newline, temp sibling + atomic replace, 0600/0700
   and complete-until-first-auth protection on iOS (`BotProfile.swift:790-850`). Android uses
   `Durability.atomicReplace` and app-private files; do not claim iOS file protection on Android.
5. **Name/description.** Name trim + 1–60 UTF-16; description truncated to 2,000 UTF-16 units; the
   error strings are `invalidName`/`invalidID`/`lastBot`/`unknownBot` (`BotProfile.swift:83-105`,
   `:229-250`).
6. **Appearance.** Colors are the 15 ids + hex from the golden; hairstyles are the 4 ids; `null`,
   `""`, `"auto"` mean automatic; no trimming; unknown → automatic; explicit values win per field;
   missing both fall back to `seed(id)`, then `seed(name)`, then `"fish"`
   (`BotFishAppearance.swift:10-100`, `:101-168`; golden `bot-profile.json` seed cases).
7. **Main pointer.** Empty/dangling/unknown → first Bot in insertion order, written back; empty roster →
   null; deleting the main Bot moves the pointer to the first remaining (`bot-profile.json`
   `rosterRules`; v1 §1.1). The last Bot cannot be deleted (`BotProfile.swift:83-105`).
8. **Deletion cascade.** Order: revoke tokens, revoke grants, archive the Bot’s DSH sessions, clear held
   inbox, delete memory (including user-scope? only this Bot’s agent scope), delete routines, remove the
   profile, then select the next Bot (`BotRuntimeComposition.swift:690-760`). The exact “user-scope
   memory is shared and is not erased by deleting a Bot” rule must be stated.
9. **Selection.** `phoneDSH.bot.selectedBotID` in `UserDefaults`/`SharedPreferences`; a missing or
   unknown id falls back to the main Bot; the key is P18-owned (`BotProfileStorage.swift:18-20`; D0).
10. **Roster stream.** Current roster on subscribe, then one snapshot per successful write; unbounded,
    no intermediate drop (`BotProfile.swift:184-210`). This is a host-internal contract; the Android UI
    can consume `StateFlow` with conflation only if the spec allows it (choose one).
11. **Ordering.** `bots` keeps on-disk insertion order including hidden; `visibleBots` filters
    `hidden_by_user`; the main Bot is a pointer, not a flag (`BotRoster.swift:1-25`).

**Fixtures.** New `golden/profile-store-cases.jsonl` (phone-only): new roster, add/rename/hide/pin/
setMain/deleteMain/deleteLast, corrupt index (backup path), corrupt settings (write refused), unknown
member preserved, unicode name 60/61, description 2,000/2,001, color `"AUTO"`/`" blue"`/unknown,
seed for emoji. Keep `bot-profile.json` as the seed/roster-rule authority.

**Compatibility.** The desktop file remains the authority; new fields are additive and unknown members
are preserved. Old desktop readers ignore the new selection key (it is not in the file). Deleting a Bot
is destructive and must not be reversible; document that rollback cannot restore erased memory.

**Acceptance.**
```bash
python3 spec/bot/v1/tools/validate_vectors.py
```
Kotlin: `:bot:testDebugUnitTest --tests '*Profile*' --tests '*Roster*'`; the corrupt-file test must
assert the original bytes are still on disk when the backup fails.

---

### D5 — Ledger and model-purpose policy: formula, tiers, enforcement (S–M)

**Target.** New `spec/bot/v1/ledger.md`; add `description`/`examples` to
`llm-ledger.schema.json` and `model-purpose-policy.schema.json` where they clarify the formula; do not
change field shapes.

**Why.** The schema requires `cacheHitRatio` but not its formula; the tier classification and error
codes are code-only (`Ledger/BotLLMLedgerRecord.swift:60-90`;
`Ledger/BotModelPurposePolicy.swift:82-130`); and nothing in production calls the policy, so “only
front/worker may use a large model” is currently unenforced.

**Section outline.**

1. **Record.** The 14 fields, types and requiredness of `llm-ledger.schema.json`; token counts are
   non-negative; four classes are separate counts (`inputTokens`, `outputTokens`, `cacheReadTokens`,
   `cacheWriteTokens`); `ttftMs` omitted when unavailable; `status` is a non-empty free string
   (production writes `ok`); `errorKind` is omitted/nil on success. Do not invent a closed enum
   without a vector.
2. **Cache ratio.** `cacheHitRatio = cacheReadTokens / (inputTokens + cacheReadTokens +
   cacheWriteTokens)`; if the denominator is 0, the ratio is 0; it is a number in `[0,1]` and is
   rounded/encoded as a JSON number (`BotLLMLedgerRecord.swift:60-66`).
3. **Timestamp.** `ts` is an ISO-8601 instant in UTC with fractional seconds (at least millisecond
   precision), length ≥20 (`BotLLMLedgerRecord.swift:72-90`). The event `time` is the same instant in
   epoch milliseconds.
4. **Purpose mapping.** `front-turn|worker-turn` → principal kind `chat|task` respectively;
   `watchdog` → `watchdog`; all others → `chat` (`BotLLMLedger.swift:29-35`). The event type is
   `ledger.usage_recorded`, origin `local/runtime`, `traceId` `trace:<eventId>`.
5. **Model tiers.** `small` if the model equals `deepseek-flash` or starts with `deepseek-flash-`;
   `large` if it is `deepseek-v4-pro`, `deepseek-pro`, `deepseek-reasoner`, `deepseek-chat`, or matches
   the suffix regex `(^|[-_/])(pro|reasoner|max|opus)($|[-_.:/])`; otherwise `unknown`
   (`BotModelPurposePolicy.swift:101-114`). Only `front-turn`/`worker-turn` may use `large`; a
   non-large purpose with a non-small model fails with `EPURPOSE_MODEL_DENIED`; an empty model fails
   with `EPURPOSE_MODEL_REQUIRED` (`:82-99`).
6. **Defaults.** The 8 purposes and their `model/maxTokens/temperature` are exactly the golden
   `model-purpose-policy.json`; do not re-type them in Kotlin.
7. **Enforcement point.** State whether the host or the Worker enforces the policy, and at which call
   (model request, worker turn, compaction, watchdog). Today the Swift policy has no production caller;
   if Android is the first enforcement point, say so and add a runtime test. Do not claim parity.
8. **Observability.** A ledger append failure must not fail the model step? Choose and state. Today
   `BotDSHRemoteRuntime` ignores the append error (`_ = try await ledger.append`, `:1364-1376`); that
   is a semantic decision.

**Fixtures.** Add to `llm-ledger.json` (phone overlay if the owner wants upstream untouched): ratios
0/0.5/1, negative token invalid, missing ttft, timestamp forms; to `model-purpose-policy.json`: tier
classification cases (`deepseek-flash-2026`, `deepseek-v4-pro`, `my-opus-model`, `unknown`) and the two
error codes.

**Compatibility.** Additive vectors; no field change. If the owner adds enforcement, old callers that
used a large model for a non-large purpose start failing — that is a behaviour change and needs a
compatibility note and a rollout decision.

**Acceptance.**
```bash
python3 spec/bot/v1/tools/validate_vectors.py
```
Kotlin: `:bot:testDebugUnitTest --tests '*Ledger*' --tests '*ModelPurpose*'`.

---

### D6 — Proactive: settings, decisions, delivery, fuse (L)

**Target.** New `spec/bot/v2/proactive.md`; new schemas
`proactive-settings.schema.json`, `proactive-candidate.schema.json`,
`proactive-decision.schema.json`, `proactive-notification.schema.json`; new golden
`proactive-cases.json`.

**Why.** S5 is prose only (`spec/bot/v2/README.md:50-72`); the fields, the fuse accounting and the
delivery result exist only in Swift (`Proactive/ProactiveSettings.swift:11-37`;
`Proactive/ProactiveEngine.swift:38-130`, `:135-230`; `Proactive/ProactivePolicy.swift:10-65`;
`Proactive/ProactiveModels.swift:5-175`). There is no production caller, so this is also the first
runtime evidence for both ends.

**Section outline.**

1. **Settings.** `mode ∈ {off,would,on}` (default `would`), `dnd` (bool, false), `quietStart`/`quietEnd`
   (`HH:mm`, default `23:00`/`08:00`), `routineQuietWeekends` (false), `timeZone` (IANA id, default the
   device zone). Invalid time strings fall back to the defaults; an invalid zone falls back to the
   current zone (`ProactiveSettings.swift:11-37`). Persistence: the P18 JSON/preferences location and
   key (new; propose `phoneDSH.bot.proactive` with a versioned object); absent = defaults.
2. **Candidate.** `kind ∈ {task-done,routine-result,reminder}`; `botId`, `dedupeKey?`, `delivery`
   (`interrupt|held`; only `interrupt` can notify), `quiet`, `reminderId?`, `allowDuringDnd`,
   `rowId?`, `createdAt`, plus the optional `id/trigger/sourceEventId/channel/title/body/taskId/
   taskTitle/summary/status/routineId/runId/attempt/resultExcerpt/deliveryKey` fields used to build
   the notification (`ProactiveModels.swift:11-70`). Freeze the required subset and the optional
   fields; do not let a Kotlin implementation invent them.
3. **Admission order.** (a) for `kind == routine-result`, a `delivery != interrupt` is `routine-held`
   and a `quiet` result is `routine-quiet`, both skip before anything else; (b) non-empty bot;
   (c) mode: `off` records `mode-off` and never delivers; (d) `would` records `would` and never
   delivers; `on` only for `deliveryKinds` (default `task-done|routine-result`); (e) DND, unless the
   explicit-reminder exception (`kind == reminder && allowDuringDnd && reminderId non-empty`);
   (f) quiet hours, same exception; (g) fuse. A held result never notifies
   (`spec/bot/v2/README.md:52-61`; `ProactivePolicy.swift:40-70`;
   `ProactiveEngine.swift:126-175`).
4. **Fuse.** Window 900,000 ms, max 4 `did`/`would` decisions per Bot; a `skip` does not consume; a
   failed delivery does not consume; a decision with `fuseRecorded:true` is restored from
   `proactive.considered` in time order (`ProactivePolicy.swift:14-16`, `:56-66`;
   `ProactiveEngine.swift:69-130`).
5. **Decision record.** `proactive.considered` data fields observed in the current writer:
   `decision` (`did|would|skip`), `reason`, `kind`, `category`, `botId`, `mode`, `channel`,
   `fuseRecorded`, `dedupeKey`, optional `trigger`. The current reason strings are
   `routine-held|routine-quiet|mode-off|dnd|quiet-hours|fuse|delivery-unavailable|delivery-failed|
   delivered|would-mode|would-only-kind` plus the policy reasons; freeze the exact set and stop a
   Kotlin implementation from inventing new ones (`ProactiveEngine.swift:130-230`). The event is
   durable; the restore path tolerates unknown kinds (skip, do not throw).
6. **Delivery.** `ProactiveDelivering.deliver(notification) -> ProactiveDeliveryResult`
   `{delivered: Bool, channel: String, error: String?}`; `delivered:false` or a thrown error records
   `delivery-failed`/`skip` and does **not** consume the fuse (`ProactiveModels.swift:123-140`;
   `ProactiveEngine.swift:150-180`). `dedupeKey` replaces the same notification, not a suppression
   window; the iOS deep link is `phonedsh://bot/<botID>/row/<rowID>`; a push relay is out of scope;
   `WakeSignalSource` remains an interface (`ProactiveModels.swift:73-175`;
   `UNUserNotificationProactiveDelivery.swift:25-90`).
7. **Modes.** `off` records `mode-off`; `would` records `would`; `on` delivers for `deliveryKinds`;
   `delivery-failed` does not consume the fuse (`spec/bot/v2/README.md:67-68`).
8. **Deleted rules.** Daily budget, category quotas, cooldown, TTL, dedupe window, model triage and
   idle-checkin stay deleted; reintroducing any needs a new v2 change (`spec/bot/v2/README.md:70-72`).
9. **Android specifics.** Notification channel id/importance, permission state, `PendingIntent`
   immutability flags, deep link cold-start handling, and the `Notifier` availability result from D0.
10. **No production caller caveat.** Until a host calls `consider`, the contract is `target`; the first
    implementation must add a runtime test (a scheduler-triggered routine that produces a notification)
    and record it as new behaviour, not parity.

**Fixtures.** `golden/proactive-cases.json` with 10 cases: allowed interrupt, held skip, DND skip,
quiet skip, reminder during DND, fuse 4→skip, failed delivery not consuming, mode off/would, restore
across restart (event time ordering), unknown kind ignored. Add invalid settings cases.

**Compatibility.** New target surface; no old data. If settings are persisted, a versioned object with
unknown fields ignored; absent = defaults. The `proactive.considered` event type already exists in the
envelope enum; its `data` is currently open, so old readers ignore new fields.

**Acceptance.**
```bash
python3 spec/bot/v2/tools/validate_vectors.py
```
Kotlin: `:bot:testDebugUnitTest --tests '*Proactive*'`; device notification test is `NOT_RUN` unless a
device grants `POST_NOTIFICATIONS`.

---

### D7 — Watchdog config, flag payload, context lint (M)

**Target.** Tighten `spec/bot/v1/watchdog.schema.json` `config` into named properties with defaults;
new `spec/bot/v1/observability.md` for lint; keep `context-profiles.schema.json` as data.

**Why.** The watchdog golden has the numbers but the schema says `config: {type: object}`, so a Kotlin
implementation cannot validate/default from the contract. The evaluation, flag data and lint thresholds
are code-only (`Watchdog/BotWatchdog.swift:21-60`; `BotWatchdogMonitor.swift:214-266`;
`BotContextLint.swift:38-75`). Context lint has no production caller.

**Section outline.**

1. **Config fields.** `heartbeatTimeoutMs=120000`, `turnDeadlineMs=900000`, `taskDeadlineMs=600000`,
   `routineDeadlineMs=660000`, `repeatedToolCalls=5`, `repeatedToolErrors=3`,
   `maxUnitTokens=200000`, `maxUnitCostUsd=2`, `goalMaxTotalTokens=0`, `goalMaxTotalCostUsd=0`,
   `tickMs=5000`, `historyLimit=200`, `maxUnits=1000` (golden `watchdog.json#/valid/config`;
   `BotWatchdog.swift:21-33`). All optional with those defaults; a non-positive deadline/limit is
   rejected or coerced exactly as the owner decides.
2. **Units.** Kinds `turn|task|routine|goal`; `deadlineAt = startedAt + deadline` (goal has no default
   deadline); `startUnit` is idempotent for the same `(kind,id)`; `finishUnit` removes the unit and its
   seen set (`BotWatchdog.swift:63-110`; `BotWatchdogMonitor.swift:66-90`).
3. **Evaluation.** Every `tickMs` plus on each observed event; one flag per `(unit,check)`; a flag is
   written as `watchdog.flagged` with `check`, `unitKind`, `unitId`, `botId?`, `sessionId?`, `at`,
   `evidence` (`BotWatchdogMonitor.swift:214-266`).
4. **Checks.** deadline, heartbeat (last event + threshold), repeated tool signature (same name+digest
   5×), repeated tool error (same error 3×), quota (tokens or cost), and the three mobile signals
   (WebContent terminated, thermal, battery), each observe-only and once per unit
   (`watchdog.json#/valid/mobile`; `BotWatchdogChecks.swift:1-120`).
5. **Mobile source.** WebContent termination is a host event; thermal/battery are host signals. Android
   maps them to `PowerManager`/`ThermalService`/`onTrimMemory` as available; if a signal is unavailable,
   the unit is not flagged and the UI must not show a fake reading.
6. **Context lint.** Six rules and thresholds: persona 20,000 warn / 32,000 error chars; tool result
   4,096/12,000 tokens; tool definition 8,000/16,000 tokens; 40 tools warn; 2 runtime contexts per turn;
   repeated text 500 chars, max 20 findings (`BotContextLint.swift:38-75`). Evidence strings are
   diagnostic, not a wire contract; freeze their fields (`rule`, `severity`, `evidence`, `location`)
   and the `location` keys used by each rule.
7. **Context profiles.** These are DSH compaction data, not Bot behaviour; the Bot runtime only reads
   the golden if it displays/validates them. No Android compaction implementation is required. Say this
   explicitly so a port does not reimplement DSH.
8. **Production caller.** State whether lint runs on demand, per turn, or not at all in P0. Today there
   is no caller; if Android adds one, it is new behaviour and needs a budget/limit.

**Fixtures.** Add `watchdog.json` invalid config cases (missing/negative/too-large), a flag-payload
case per check, and a lint case per rule at warn/error boundaries. Add `context-lint.phone.json` if the
upstream file is left untouched.

**Compatibility.** Widening `config` from an unconstrained object to named optional properties is
additive for valid existing documents; a document with an unknown config key must still be accepted or
must fail with a stated rule. The flag payload is `data`, an open object, so new fields are additive.

**Acceptance.**
```bash
python3 spec/bot/v1/tools/validate_vectors.py
```
Kotlin: `:bot:testDebugUnitTest --tests '*Watchdog*' --tests '*ContextLint*'`. A real thermal/battery
signal is `NOT_RUN` without a device.

---

### D8 — Wake / held inbox: state machine, block grammar, hidden prompts (L)

**Target.** New `spec/bot/v2/wake.md`; extend `held-inbox-item.schema.json` only if a field is missing
(it already covers agent-held and device-task-result); extend the `wake-routine.json` held-block cases
with the other branches; add `golden/held-block-cases.json` if the owner wants a separate family.

**Why.** The item shape is frozen, but the document/state machine, 200/20 bounds, staging keys, commit/
revert/recover, dedupe, and the `[agent]`/`[card-dismissed]`/`[device-task]` bullet grammar are code-only
(`Wake/WakeInbox.swift:95-317`, `:318-390`). The hidden-wake prompt templates are code-only
(`MCP/BotDSHRemoteRuntime.swift:534-540`, `:623-631`; `Wake/RoutineWake.swift:96-110`). Only the
`[routine]` and `[subagent]` bullets appear in the frozen held block.

**Section outline.**

1. **Item.** The schema’s two shapes; `kind ∈ {agent-held,subagent-result,routine-result,
   card-dismissed,device-task-result}`; `text ≤ 1200`; `state ∈ {pending,staged}`; staged requires
   `stagedAt` + non-empty `stagedKey`; `requestId` is the dedupe key (`held-inbox-item.schema.json`;
   `WakeInbox.swift:60-90`).
2. **Document.** `WakeInboxDocument {version:1, items:[…]}` stored in the `data.document` of
   `comm.inbound|outbound|reply` with the `{botId,document}` envelope; latest event wins; unknown
   version fails closed (`WakeInbox.swift:95-103`, `:147-190`; D2 §10).
3. **Bounds.** Max 200 items; `enqueue` on a full inbox fails with `heldInboxFull(200)`; stage at most
   20; `limit` is clamped to 0…20 (`WakeInbox.swift:213-217`, `:246-270`).
4. **Dedupe.** `enqueue` with an existing `requestId` returns the existing item and `duplicate:true`,
   writes no event. The dedupe key is the request id, not the item id (`:219-225`).
5. **Staging.** `stage(limit,key?,kind?)` selects pending items by `(createdAt,id)`, marks them
   `staged` with the same key, and writes one `comm.outbound` snapshot with event id
   `wake-inbox:stage:<key>`; `commit` removes them (`comm.reply`, `wake-inbox:commit:<key>`); `revert`
   returns them to pending (`wake-inbox:revert:<key>`); `recover` returns **all** staged items to
   pending (`wake-inbox:recover:<uuid>`) (`WakeInbox.swift:240-317`).
6. **Held block.** Header exactly:
   `<held_agent_messages>` / one sentence / bullets / `</held_agent_messages>`. Bullet forms:
   - `- [routine] <title> · <minute> · msg <id>: <text>`
   - `- [subagent] task <taskId> · <status>: <text>`
   - `- [card-dismissed] <title>: <text>`
   - `- [device-task] <title> · task <taskId> · <status>: <text>`
   - `- [agent] <name> (id: <id>)[ — <title>] · <minute> · msg <id>: <text>`
   The header’s optional clauses for card/device are present only when such an item exists
   (`WakeInbox.swift:318-390`; the existing `heldBlock` golden freezes the first two bullets).
7. **Escaping.** Every non-host field in the block is escaped by `escapedHeldField`: `\`→`\\`, newline/
   CR/tab → `\n`/`\r`/`\t`, `<`/`>`/`&` → `\u003c`/`\u003e`/`\u0026`, U+2028/U+2029 and control/format
   chars → `\uXXXX` (uppercase hex). This is already in `spec/bot/v2/README.md:36-48`; the delta only
   makes the bullet grammar match it (`WakeInbox.swift:390-430`).
8. **Hidden wakes.** Freeze the two templates:
   - task settled: `[SAND_HIDDEN_PROMPT][subagent]\n<title> | <status> | <taskId>\n<excerpt≤1200>`
   - task interrupted: `[SAND_HIDDEN_PROMPT][subagent]\n` + the interrupted title/id/status (no result).
   The `session/prompt.requestId` is derived from the task id; a replay must reuse it
   (`BotDSHRemoteRuntime.swift:534-540`, `:614-640`; `BotTurnOrigin.swift:100-130`).
9. **Device-task result.** Enqueue after the device journal commits and before the device receipt; at
   most once; no replay from the journal; fields are device display name, task id, terminal status, and
   a ≤1,200-char result text; `requestId` is stable per settlement (`DeviceTaskResultNotice.swift:13-60`;
   `BotRuntimeComposition.swift:472-526`; `spec/bot/v2/README.md:34`).
10. **Prompt request ids.** A held delivery derives the prompt id from the staged item ids; a user
    action keeps its nonce; a routine uses the run id; a task uses the task id; a parent wake uses the
    task id. State the derivation and the “no random id when a durable identity exists” rule
    (`BotTurnOrigin.swift:22-120`; `mcp-endpoint.md:221-228`).
11. **Automation status.** The `<automation_status>` block and its “unreadable” fallback are frozen by
    `wake-routine.json` for one case; add the unreadable case and the paused/deferred/needs-
    reconciliation lines (`RoutineWake.swift:176-230`).
12. **Host-inserted text only.** The escaping rule applies to host-inserted held blocks/hidden prompts,
    not to a normal user message or another Bot’s message body (`spec/bot/v2/README.md:48`).

**Fixtures.** Extend `heldBlock` (or a new `held-block-cases.json`) with: all five bullet kinds, each
optional header clause, a title/text containing newline/`</held_agent_messages>`/`- [agent]`/emoji,
an agent item with/without title, a device item with each terminal status, an empty inbox (block
absent). Add staging state vectors (stage/commit/revert/recover/dedupe/full) to a phone-only golden.

**Compatibility.** The document is version 1; adding fields is additive. An old reader that ignores
unknown `kind`s must keep the rest of the block; a reader that does not know `device-task-result` must
not mis-render it as agent-held (the schema’s `oneOf` already separates it). Old staged items from a
crash are reset to pending by `recover`; do not drop them.

**Acceptance.**
```bash
python3 spec/bot/v2/tools/validate_vectors.py
```
Kotlin: `:bot:testDebugUnitTest --tests '*WakeInbox*' --tests '*HeldMessages*' --tests '*TurnOrigin*'`.

---

### D9 — Routines: state machine, scheduler, persistence, cron (XL)

**Target.** New `spec/bot/v2/routines.md`; tighten `routine.schema.json` (`run_state`, `last_result`,
`last_skip`, `delivery`); add `golden/routine-run-cases.json`.

**Why.** The record schema leaves the run state and result as loose objects; the scheduler timers,
skip/defer, leases, crash recovery, delivery and cron parsing are code-only
(`Routines/RoutineModels.swift:44-61`, `:169-200`, `:424-470`;
`RoutineMachine.swift:189-232`, `:249-315`, `:325-425`, `:442-470`;
`RoutineScheduler.swift:44-45`, `:99-166`, `:219-232`; `RoutineSchedule.swift:5-165`, `:377`).
The wake prompt is already frozen; what is missing is when it fires and what happens when it does not.

**Section outline.**

1. **Record/validation.** `id`, `agentId`, `title` non-empty; `prompt` non-empty; schedule `kind` and
   timezone IANA; interval `1…525600` minutes (schema) but scheduler cron minimum 5 minutes — reconcile
   the two values explicitly; `phaseMinutes < everyMinutes`; daily/weekly `HH:mm`; weekly ISO 1–7,
   unique sorted; cron 5-field parse; `delivery=interrupt` requires a non-empty reason; `urgent`
   requires a non-empty reason; reasons collapse whitespace and cap 500 (`RoutineModels.swift:63-156`,
   `:393-422`; `spec/bot/v2/README.md:30`).
2. **Schedule math.** `nextRunAt(schedule, now, createdAt, lastRunAt)` for each kind; timezone/DST
   handling; missed runs catch up once, not N times; an on-demand run does not move the schedule
   (`RoutineSchedule.swift:166-330`; `RoutineWake.swift:32-110`).
3. **Run state.** `scheduled|started|succeeded|failed|timed-out|cancelled|needs-reconciliation`;
   `attempt` increments at `begin`; `runId` unique; `scheduledFor` resolves from a quiet defer, then
   the argument, then `nextRunAt`, then `startedAt`; `leaseOwner`/`leaseExpiresAt`; a second `begin`
   while `started` is a skip with reason `overlap`, not a crash; `needs-reconciliation` blocks new runs
   (`RoutineModels.swift:44-61`, `:169-200`; `RoutineMachine.swift:189-232`).
4. **Scheduler.** 5,000 ms tick, 600,000 ms run timeout, 5,000 ms cancel grace, lease TTL
   `runTimeout + grace + 60,000`, a single tick at a time, skip all active routines if a tick is still
   running (`RoutineScheduler.swift:41-60`, `:114-166`, `:219-232`).
5. **Quiet hours.** If the routine is not urgent-with-reason and now is inside quiet hours, defer to
   `nextEnd` (not drop), store `quietDefer{until,scheduledFor,at}`, set `nextRunAt=until`; urgent with
   a valid reason bypasses; the notification path may still reject a quiet candidate (D6)
   (`RoutineScheduler.swift:140-150`; `ProactiveSettings.swift:61-100`).
6. **Overlap/skip.** A `RoutineSkip{reason,at,triggerAt?,runningAttempt?,runningRunId?}` plus
   `skipCount`; reasons include `overlap`; a skip does not change the schedule (`RoutineMachine.swift:233-247`).
7. **Finish.** Terminal status; `text` prefix 4,000; `durationMs`, `lateByMs`, quiet flag (empty text
   on success is quiet); `nextRunAt` advances by schedule unless `needs-reconciliation`; `crashRetry`
   cleared; a terminal run writes a `routine.run_finished` event and a `RoutineDelivery` (`RoutineMachine.swift:249-315`).
8. **Crash recovery.** On start/tick, `recover` finds `started` runs whose lease expired; if
   `idempotent && !crashRetry && maxAutoRetries>0`, mark `failed` and retry once now; otherwise mark
   `needs-reconciliation`; both write a delivery and a `routine-crash` audit event; recovery is
   idempotent (`RoutineMachine.swift:325-395`).
9. **Reconciliation.** `retry` sets `nextRunAt=now`; `acknowledge` advances to the next scheduled
   attempt; both clear the flag and record the user decision; an unknown decision is rejected
   (`RoutineMachine.swift:397-425`).
10. **Delivery.** `RoutineDelivery` fields (deliveryKey, runId, attempt, status, resultStatus, text,
    error, quiet/urgent, notified, heldInbox, quietDefer, scheduledFor, lateByMs, timestamps, lease);
    `pending|delivering|delivered|failed`; claim lease 60,000 ms; a second claimant while leased is
    `busy`; `completeDelivery` releases the lease (`RoutineModels.swift:424-470`;
    `RoutineMachine.swift:428-490`).
11. **Snapshot.** The full `RoutineDocument` is the `routine.*` data; the event type is chosen by
    routine-count change (`defined`/`deleted`) else `updated`; the snapshot event id is
    `routine-snapshot:<uuid>` unless the caller supplies one; the mutation event batch is atomic
    (`RoutineStore.swift:70-97`). Apply CCR-7 presence.
12. **Automation status.** The line format and fields are frozen by `wake-routine.json`; add
    `needs-reconciliation`, `quiet-deferred until`, `paused`, `last running`, `last <status> <time>`
    (`RoutineWake.swift:176-230`).
13. **Errors.** The `RoutineError` messages are model-visible; freeze the code/field and keep the
    strings in one table (invalidSchedule, invalidRoutine, routineNotFound, urgentReasonRequired,
    interruptReasonRequired, invalidQuietTarget, invalidHeldItem, heldInboxFull, deliveryNotFound,
    unsupportedDecision) (`RoutineModels.swift:5-37`).

**Fixtures.** `routine-run-cases.json` (phone-only) with: interval/daily/weekly/cron next-run vectors
(including DST), quiet defer + nextEnd, overlap skip, run timeout→timed-out, cancel, crash retry,
crash no-retry→needs-reconciliation, retry/acknowledge, delivery claim/busy/complete, snapshot
defined/updated/deleted, new routine with null run fields (CCR-7). Add invalid schedule cases.

**Compatibility.** The snapshot document is version 1; a new field is additive. If `run_state` is
tightened, old snapshots must still decode; add a migration only if a required field was previously
omitted (CCR-7 says it was). A routine that is `started` at upgrade is recovered by the new code, not
silently marked failed.

**Acceptance.**
```bash
python3 spec/bot/v2/tools/validate_vectors.py
```
Kotlin: `:bot:testDebugUnitTest --tests '*Routine*'`; a fake clock must prove exactly-once catch-up and
that a skipped overlap does not advance the schedule.

---

### D10 — Memory: normalization, write/forget/erase, injection, recall, replay (XL)

**Target.** New `spec/bot/v2/memory.md`; add `description`/`maxLength` to the three memory schemas where
they encode a rule; add `memory-write.schema.json` (request/result) and the `memory.written` /
`memory.forgotten` event `data` shapes.

**Why.** v2 §1 is one paragraph. The fact normalization, the 2,000/80 caps, write/forget/erase,
the full injection template (only Chinese is frozen), the budgets, the BM25/recency weights, the
tokenizer and the replay rules are code-only (`Memory/BotMemoryFact.swift:230-345`;
`BotMemoryInjection.swift:18-110`, `:112-206`; `BotMemoryRecall.swift:110-119`, `:310-341`;
`SQLiteBotMemoryFactStore.swift:305-390`, `:425-460`; `BotMemory.swift:234-500`).

**Section outline.**

1. **Fact.** `fact_id`, `text`, `learned_at_ms`, `tier ∈ {profile,log,note}`, `scope ∈ {agent,user}`,
   optional `key`, `trust`, `sensitivity`, `importance`, `last_used_ms`, `extractor`, `source`,
   `superseded_by`, `expires_at`, `applicable_when`, `not_applicable_when`, `extract_run_id`,
   `archived`, `archived_at_ms`, `archive_reason`, `l2` (`memory-fact.schema.json`;
   `BotMemoryFact.swift:88-208`). Source kinds `user-turn|hidden-wake|agent-message|routine|task`.
2. **Normalization.** Fold every line: trim, collapse runs of whitespace to one space, join with a
   single space; an empty result is `empty` and writes nothing; >2,000 Unicode code points is
   `too-long` and writes nothing; conditions cap 80; the error strings are bilingual
   (`BotMemoryFact.swift:230-285`; `BotMemoryText`, `:286-345`). Exact code points, not UTF-16 units.
3. **Write.** `UpdateMemory` action `write`: `fact` required; default tier `log`, scope `agent`;
   `key` folded/capped 200; `importance` default 0.5 and clamped; `source` from the turn origin;
   non-`user-turn` cannot write `scope:user` or `tier:profile` (source only downgrades); a duplicate
   `key` in the same scope updates/replaces according to the owner’s rule; the result reports the
   fact id and text (`BotMemory.swift:234-340`; `spec/bot/v2/README.md:24`).
4. **Forget/erase.** `forget` deletes all facts in the same scope whose normalized text exactly
   matches; no implicit replacement; `erase(factID)` and `eraseAll(scope)` write a tombstone and a
   `memory.forgotten` event; an erased fact id must not be reused (generate a new id and reject a
   tombstoned one) (`BotMemory.swift:342-476`; `SQLiteBotMemoryFactStore.swift:420-470`).
5. **Injection.** The header, section titles, empty-section text, profile/notes/log formatting, date
   format, budget clipping and per-scope order are exactly the golden’s Chinese text; publish the
   English template as a second golden (the Swift `Texts` struct is the source:
   `BotMemoryInjection.swift:112-206`). Budgets 2,000/1,000/1,500/4,000, 12 inline log facts, minimum
   3 log facts, shrink 250 at a time (`:18`, `:44-45`, `:47-110`). The two scopes render separately;
   `<FIXTURE_ROOT>` is a test substitution, not a runtime value.
6. **Recall.** Score = `0.72*relevance + 0.18*recency + 0.10*importance`; recency =
   `0.5^(ageDays/180)`; relevance = `bm25/(bm25+3.0)`, exact match floor 0.95; BM25 k1=1.2, b=0.75;
   IDF `ln(1+(N-df+0.5)/(df+0.5))`; a candidate with less than 0.5 of query-term hits is dropped when
   the corpus is ≥8 and matched IDF <0.85; tokenizer/prefix expansion for CJK and Latin; ties by
   `learnedAtMS` desc then `fact_id`; both scopes merged, top N, at least one from each scope when both
   exist (`BotMemoryRecall.swift:109-341`; `BotMemoryTokenizer.swift:1-120`).
7. **Replay.** `memory.written` data is the full `BotMemoryFact` JSON (snake_case); the Bot id is
   in `principal.botId`, not duplicated in `data`; `memory.forgotten`
   carries `fact_id`, `at`, `reason`, `scope`, `textDigest?`; replay applies in `commit_seq` order,
   ignores unknown optional fields, detects conflicting writes for the same fact id and fails closed;
   page size 500; at most 256 skipped ids kept (`SQLiteBotMemoryFactStore.swift:305-390`, `:425-460`).
   Historical events with no `botId` are `"main"`; user scope is shared (`:100-125`).
8. **Isolation.** Agent-scope facts are filtered by `principal.botId`; user-scope facts are shared;
   `RecallMemory` with `scope` searches only that scope; the `MCP/BotMCPMemoryRecallScopeTests` case is
   the reference (`BotMemory.swift:480-550`).
9. **Not in v1.** No automatic extraction, no MemoryPolicy decision, no L2 reflection, no decay; the
   fields are reserved but not written (`spec/bot/v2/README.md:26`).
10. **Errors.** `empty`, `too-long`, `not-found`, `scope-denied`, `tombstoned`, `conflict`; the model
    sees a human-readable string and never a fabricated success.

**Fixtures.** English `memory-injection` case; recall score cases at t=0/180d/forever and exact-match;
normalization vectors for CRLF/tabs/full-width spaces/2,000/2,001 code points, 80/81 conditions;
write/forget/erase/tombstone/replay-conflict; agent isolation and shared user scope.

**Compatibility.** The fact JSON keys are already snake_case and frozen; adding optional fields is
additive. Old events without `botId` read as `"main"`. A tombstone must survive a rollback; if the old
app does not know tombstones, it may resurrect a forgotten fact — state this limitation rather than
claiming safety.

**Acceptance.**
```bash
python3 spec/bot/v2/tools/validate_vectors.py
```
Kotlin: `:bot:testDebugUnitTest --tests '*Memory*'`; the injection test compares the full string and
the recall test asserts the score within `1e-6`.

---

### D11 — Rows, projection, display contract, user actions (XL)

**Status after B7a (PC-20261112-android-bot-w4).** The session-lifecycle and log→row halves are
**frozen** as phone-owned P27 contracts with shared vectors. The row JSON shapes remain the upstream
exports; `row-projection.json`, `row-protocol.json` and `row-protocol.phone.json` are byte-identical.
The display table, card expiry/answer, user-action validation and the user-action transaction are
**not yet frozen** and stay in this delta for a later checkpoint.

**Frozen in B7a** (worktree base `e477497b`; contract files are normative and are not dsh-bot
exports):

- [session-lifecycle.md](../../spec/bot/v1/session-lifecycle.md): `gb-<safeBotID>` minting and the exact
  `safePathComponent` alphabet (Unicode `L*`, `M*`, `N*` plus `._-`, fallback `bot`, 64 grapheme
  clusters), the Bot root, `session/create` (`agentPreset`, cwd, response checks), `runtime.started` /
  `runtime.exited`, the recovery decision table (reuse vs archive+rebuild vs create-conflict legacy
  path), erasure epoch switch ordering, `session/prompt` (`requestId` `bot-<uuid>`, queue/steer),
  `session/follow` snapshot/live-frame semantics, cancel, `phone/botClaimSession` and the
  `BotTokenRegistry` issue/rotate/revoke/expiry rules. The session-log file path is recorded as a
  host detail; the normative input is the ordered DSH record list, and §7 states the
  `session/follow` + `session/page` fallback for a host without the materialized file.
- [projection.md](../../spec/bot/v1/projection.md): JSONL decoding and skipped diagnostics, the DSH and
  durable-event→row tables, `rowID` / `entrySeq`, `surfaceOp` append/replace handling, progress
  collapse, tombstones, `watch(after:)`, cursor/reset, reconciliation, epoch chains, the 10 updates/s
  limiter and its `nextFlushAt`, the display-contract bridge, and App history paging (P09 consumer,
  iOS conformance NOT_RUN because `examples/probe-app/**` is outside the SwiftPM targets).
- [golden/session-lifecycle.phone.json](../../spec/bot/v1/golden/session-lifecycle.phone.json): 23
  workspace (17 valid + 6 fallback), 20 token-registry (7 valid + 13 invalid) and 19 session
  request/response (12 valid + 7 fail-closed) vectors. Each case carries a `source` (`file:line`);
  invalid cases freeze composed-preset mismatch, missing `sessionId`/`agentPreset`, non-conflict
  create errors, unacknowledged legacy claims, claim errors and a follow stream without a snapshot.
- [golden/projection.phone.json](../../spec/bot/v1/golden/projection.phone.json): 15 DSH mapping, 8 UI
  mapping, 7 invalid-record, 3 history cases (8 rebuild/watch steps) and 2 streaming cases. `origins` lets the Python
  validator re-check `rowID`/`entrySeq`; `display` freezes the `BotDisplayContract` composition for
  the projected rows; `chatActionNonces` freezes the in-memory-only nonce.
- Swift conformance: `Tests/PhoneDSHBotTests/MCP/BotSessionLifecycleGoldenTests.swift` and
  `Tests/PhoneDSHBotTests/Rows/BotProjectionGoldenTests.swift` read the JSON from disk and drive the
  real `BotWorkspaceLayout`, `BotDSHRemoteRuntime`, `BotTokenRegistry`, `BotDSHSessionEvent.parseJSONL`,
  `BotSessionLogProjector`, `BotRowHistory` and `BotStreamingRowLimiter`.
- `validate_vectors.py` / `check_golden.py` / `export-manifest.json`: both files are registered as
  explicit phone-only vectors (`upstream: []`) and validated by the same `phone-spec` stage. The
  Python side is an oracle for the arithmetic and invariants, not runtime conformance.

**Remaining in D11 (not frozen; do not implement from Swift alone):**

1. `spec/bot/v1/display-contract.md` (or an equivalent normative table). `row-projection.json` still
   freezes input kind → surface; the phone-P0 hidden rules, `hiddenToolNames`, agent-comm
   summarisation and the card-data requirements are only code. `projection.phone.json` freezes the
   display composition for the rows it produces, not the whole table.
2. Card expiry/answer/close semantics: stable `o0…o3` option ids, newer-card expiry, the `stale`
   reasons, "a dismissed question creates no model turn" and "steps has no dismiss"
   (`BotRemoteActionPlanner.swift`, `card-payload.phone.json` only covers ids).
3. User-action validation (the 11 reason codes, nonce/botID/kind rules, `chat` text-or-attachments,
   `cardAnswer` field restrictions, approval id/digest, `stopTask` threadID) and the
   `BEGIN IMMEDIATE` nonce/event transaction (`BotUserAction.swift`,
   `SQLiteDomainStore+UserAction.swift`). These remain code-only; no new vectors in B7a.
4. Agent-comm rows and `summarizeCommRows` (`BotAgentComm.swift`) beyond the generic `agent.comm`
   mapping frozen in projection.md §6.
5. A `row-display-cases.json` golden with one case per surface/hidden rule. `projection.phone.json`
   covers the rows produced by the log and durable-event tables; it is not a replacement for the
   full display table.
6. History paging conformance. The rule is frozen in projection.md §12, but it lives in
   `examples/probe-app/**`; no SwiftPM test target can reach it, so its iOS conformance is NOT_RUN.

**Fixtures.** The new vectors are listed above. The earlier plan for `row-display-cases.json` stays
open (remaining item 5). Card stale/expired/answered/closed, action reason codes and agent-comm
summary vectors are still missing; `row-protocol.phone.json` and `row-projection.json` remain
untouched and byte-identical.

**Compatibility.** Old DSH session logs replay through the same table; an invalid `surfaceOp`
(`start`/`end` spelling), unknown record type or damaged JSON line is skipped with diagnostics, not
fatal. The projection cursor is in memory, so an app restart rebuilds from the log and the durable
events; no migration. A tombstone is reconstructed from the durable delete event after a cold
rebuild. Changing a display surface remains a breaking P09 UI change even when the row JSON is
unchanged.

**Acceptance (B7a).**
```bash
python3 spec/bot/v1/tools/validate_vectors.py
python3 spec/tools/bot/check_golden.py --root .
swift test --filter 'BotSessionLifecycleGoldenTests|BotProjectionGoldenTests'
```
Kotlin (round 2): `:bot:testDebugUnitTest --tests '*Row*' --tests '*Projection*' --tests '*UserAction*'`;
the golden test must assert `BotRow` fields directly, including `updatedSeq`, tombstones and
`chatActionNonce` (in-memory only).

---

### D12 — Team tools and durable task lifecycle (XL)

**Target.** New `spec/bot/v1/team.md` and `spec/bot/v1/tasks.md`; extend
`tool-catalog.phone.json`/`tool-effects.phone.json` only if a case is missing; extend
`held-inbox.phone.json` if the agent-held reply case is incomplete.

**Why.** v1 §1.1 is a good summary but not an implementable contract: the exact prompt, ids, timeout,
error strings, delivery/queue and hop tracking are code-only (`Team/BotTeamTools.swift:11-240`;
`Rows/BotAgentComm.swift:142-260`; app `BotRuntimeComposition.swift:841-1010`). Task snapshots,
restore, interrupted wakes and request-id derivation are code-only
(`MCP/BotDSHRemoteRuntime.swift:416-640`, `:645-760`).

**Section outline — team.**

1. **SendToAgent arguments.** `agent_id` required (aliases `target_id|bot_name|agentId`); `message`
   required (alias `text`); `title?`; exactly one of `priority:bool` or `delivery:"now"|"queued"`;
   both/neither/illegal fails closed with the upstream sentence
   `SendToAgent requires priority (true = wake now, false = hold for their next turn).`
   (`BotTeamTools.swift:60-100`).
2. **Target resolution.** Accept id or exact/visible name; hidden Bots are not targets; the caller
   cannot target itself; target-not-found returns
   `agent not found: "<x>". Available bots: <list>.` with the visible roster minus caller/self and
   hidden (`:82-120`; `BotToolCatalog.availableBotEntries`).
3. **Depth/cycle.** `depth = inbound depth + 1`; `depth > 2` rejects with the depth message; a target
   already in the chain rejects with the cycle message listing the chain (`:100-118`).
4. **Idempotency.** `requestId = "agent:<callId>"`; a replay of the same call id returns the existing
   `threadId` and does not deliver again; the compatibility lookup also accepts the pre-WP4 bare
   callId (`:118-130`).
5. **IDs.** Outbound row id `agent-outbound-<sha256(sender\0target\0requestId\0seq)>`; thread id
   `<rowID>@<seq>:agent-comm`; target rows `t<turn>u` with a numeric collision suffix; `seq` is a
   per-composition monotonic counter (`BotAgentComm.swift:142-170`).
6. **Prompt.** `[agent] <name> (id: <id>)[ — <title>]: <message>`; the message is the model-visible
   body; the title is optional (`BotTeamTools.swift:177-180`).
7. **Delivery.** `queued` writes only a target `agent-held` item and does not wake; `now` opens a
   visible target turn, queues behind a busy turn (never interrupts), and waits up to 300,000 ms for
   the final assistant text (`:14`, `:150-240`; `BotTeamHost.swift:31-60`).
8. **Rows.** Sender `outbound` before delivery and `inbound` after the reply; target `incoming` user row
   and `reply` assistant row; all share the thread id and carry `toAgent`/`fromAgent`/`direction`/
   `hop`/`requestId` (`:180-240`; `spec/bot/v1/README.md:24`).
9. **Held reply.** The target’s last assistant text is capped at 1,200 chars and written back to the
   sender as an `agent-held` reply; it does not wake the sender; it enters the next turn’s held block
   (`BotTeamTools.swift:200-240`; v1 §1.1).
10. **CreateTeammate.** Main Bot only (`permission_denied` otherwise); `name` trimmed 1–60;
    `description` truncated to 300; `color` one of 15; `hairstyle` one of 4; `section_id` accepted and
    ignored; hidden Bots are not in the model-visible description (`:240-320`).
11. **Errors.** Freeze the code and the model-visible string for: missing/ambiguous delivery, self,
    not-found, depth, cycle, held-full, not-main, invalid name/color/hairstyle, duplicate name if the
    owner chooses. The tool returns `isError:true` with `structuredContent.error.code`.
12. **Unread/selection.** The host bumps the sender/target unread counter when that Bot is not
    selected; the selected Bot is read from `BotSelectionStore` (`BotRuntimeComposition.swift:936-990`).

**Section outline — tasks.**

13. **Record.** `task_id`, `sessionId`, `status`, `title`, `result?`, `partial?`, `error?`; statuses
    include `running|stopping|completed|failed|cancelled|interrupted` (`BotMCPTypes.swift:170-201`).
14. **Create/start.** `Task` creates a new DSH session (`kind: task`), a durable `task.created`, and a
    background work item; `AwaitTask` returns the record after a bounded wait; `StopSubagent` requests
    stop and returns the stopped record (`BotDSHRemoteRuntime.swift:416-500`).
15. **Snapshot.** `task.updated` carries `persistedTask` with taskId, sessionId, parentSessionId,
    parentBotId, parentIncarnation, parentKind, title, prompt, asynchronous, timeoutMs, status,
    result/partial/error, createdAt, wakeDelivered (`:645-690`).
16. **Restore.** Scan `task.updated`/`task.settled` from commit 0, apply the latest snapshot, prefer
    `task.settled`, and map `running|stopping` to `interrupted` + `worker_restarted` (`:690-760`).
17. **Wake.** An interrupted asynchronous task wakes its parent exactly once; the durable wake marker
    is part of the snapshot; the hidden prompt request id derives from the task id; a crash between the
    turn and the marker must not open a second turn (`:614-640`; `mcp-endpoint.md:216-219`).
18. **Request ids.** Task turn `task-turn:<taskId>`; settled wake `task-settled:<taskId>`; interrupted
    `task-interrupted:<taskId>`; these are the same prefixes as the turn-origin table
    (`BotTurnOrigin.swift:22-120`; `spec/bot/v1/README.md:92-94`).
19. **Timeout/cancel.** `AwaitTask` timeout is a caller argument; the task keeps running; `StopSubagent`
    cancels the turn and records `cancelled`; a late result after stop is dropped
    (`BotDSHRemoteRuntime.swift:448-500`).
20. **Durability.** `task.created|updated|settled` are P25 durable events; the task record is not a
    separate table. The `persistedTask` field is additive to `data`; old readers ignore it
    (`:645-660`).

**Fixtures.** New `team-cases.json`: missing priority, both priority+delivery, queued/now, self,
not-found, depth 3, cycle, duplicate call id, held-full, non-main CreateTeammate, hidden target, name
60/61, description 301, color/hairstyle invalid. New `task-cases.jsonl`: create/start/settle/stop,
interrupted restore, wake once, duplicate request id, await timeout. Reuse `event-envelope.phone.json`
for the `agent.comm` rows.

**Compatibility.** `agent.comm` is already additive; `persistedTask` is additive inside `data`. Old
task records without `persistedTask` are read as legacy and not restored; state that they become
`interrupted` or are ignored (choose one). The 300 s delivery timeout is a model-visible bound; changing
it is a contract change.

**Acceptance.**
```bash
python3 spec/bot/v1/tools/validate_vectors.py
```
Kotlin: `:bot:testDebugUnitTest --tests '*Team*' --tests '*AgentComm*' --tests '*Task*'`; a fake host
drives the two-Bot path; a real model/Worker E2E is `NOT_RUN` in CI without the harness.

---

### D13 — MCP JSON-RPC, identity/approval bodies, tool contracts, cards, volatile (XL)

**Target.** Extend `spec/bot/v1/mcp-endpoint.md` with §“JSON-RPC surface”, §“Identity/approval bodies”,
§“Tool contracts”; new `spec/bot/v1/tool-contracts.md` and `spec/bot/v1/cards.md`; extend
`volatile-context.schema.json` descriptions only.

**Why.** `mcp-endpoint.md` fixes HTTP/auth/ordering but not the JSON bodies. The method results/errors,
`/identity/register|cancel`, `/approval`, per-tool argument rules, card-builder rules and volatile
assembly are code-only (`MCP/BotMCPHandler.swift:55-205`; `MCP/BotMCPTypes.swift:5-45`;
`MCP/BotMCPRuntime.swift:427-780`; `MCP/BotCardPayloads.swift:11-340`;
`MCP/BotDomainVolatileContextProvider.swift:20-120`). A Kotlin port would invent a second JSON shape.

**Section outline.**

1. **JSON-RPC.** `initialize`: requested protocol version is echoed if it is one of
   `2025-11-25|2025-06-18|2025-03-26`, else the first; `capabilities.tools = {}`;
   `serverInfo = {name:"phone", version:"1.0.0"}`; native `instructions` merged when a forwarder is
   attached (`BotMCPHandler.swift:55-70`). `ping` → `{}`. `tools/list` → `{tools:[{name,description,
   inputSchema}]}`; native tools appended, Bot names win on collision. `tools/call` → the
   `BotMCPCallResult` shape: `content:[{type:"text",text}]`, optional `structuredContent`, optional
   `isError:true`; a failure has `structuredContent.error.{code,message}` and `isError:true`
   (`BotMCPTypes.swift:17-45`). Errors: `-32601` method not found, `-32602` invalid params/name,
   `-32603` internal; notifications/batches follow JSON-RPC (`BotMCPHandler.swift:120-140`).
2. **Identity.** `/identity/register` body `{runtimeId, sessionId, callId, name, arguments?,
   argsDigest?, sessionToken}`; success `{ok:true,id}`; failure `{ok:false,error}` with
   `unauthorized|unknown_tool|invalid_request|unattributed|cross_session_denied|timeout|unavailable|
   identity registration refused`; body `sessionId` is not evidence; token-resolved principal must match
   (`BotMCPHandler.swift:141-175`; `mcp-endpoint.md:138-195`). `/identity/cancel` body `{id}` → `{ok}`.
3. **Approval.** `/approval` body `{sessionId, callId, tool, argsDigest, alwaysScope, action?, detail?,
   command?, effects?, askAction?}`; response `{ok,allowed,approvalId?,message?}`; validation:
   registered call/tool, digest match, bash command match, `alwaysScope ∈ {until,session,none}` and the
   expected-scope rule (`until` for known effects, `session` for all-unknown, `none` for sandbox
   escalation), sandbox effect shape (`BotMCPRuntime.swift:427-476`). Pending card timeout 300,000 ms;
   a `once` grant is consumed at resolution unless consumption is deferred
   (`BotApprovalCoordinator.swift:31-172`).
4. **Session credentials.** `issueSession` revokes the previous token for the session and issues a new
   one; TTL 12 h default; 4,096 tokens max; token is `dshg_`-prefixed URL-safe random; only a digest is
   stored; `revoke|revokeSession|revokeBot|rotate|prune` semantics; incarnation is 16 random bytes hex
   and changes on rotation (`BotTokenRegistry.swift:51-125`, `:165-230`; `mcp-endpoint.md:138-195`).
5. **Attribution.** A `tools/call` resolves runtime+session+call+name+argsDigest; the bare name strips
   `mcp__<server>__`; the registration lives from `pre-execute` through `execute`; cleanup on deny/
   throw/abort/restart; TTL = approval timeout + 30,000 ms; a registration for another tool/generation
   never claims (`BotAttributionRegistry.swift:66-150`; `mcp-endpoint.md:175-195`).
6. **Tool contracts.** For each P0 tool: name, description (from `tool-catalog.json`), input schema,
   required/optional fields, bounds, defaults, result `structuredContent`, error codes. At minimum:
   `UpdateMemory`/`RecallMemory` (D10), `Task`/`AwaitTask`/`StopSubagent` (D12), `UpdateRoutine`/
   `ListRoutines` (D9), `RequestApproval` (below), `SendToUser`, and the seven card tools (D9/cards).
   The tool names/descriptions are frozen by the catalog golden; do not re-type them.
7. **Cards.** `ask_user`/`show_next_steps` require 2–4 options/steps; drop synthetic “其他/其它/other”
   after normalization; style only `primary|default|danger` (unknown → default); move the single
   recommended (recommended:true or style:primary, never danger) to index 0 and set recommended:true;
   all others lose recommended and primary→default; assign `o0…o3` after ordering; question requires
   `question`, optional `helpText`; steps accept string or object; other cards require their stated
   fields (`path`, `title`, `items`, `links`, etc.); unknown tool/type or missing data fails closed with
   `invalid_arguments` (`BotCardPayloads.swift:11-340`; `golden/card-payload*.json`).
8. **Volatile context.** Response `{schemaVersion:1,sessionId,revision,blocks}`; block caps
   variant/persona 12,000, memory/automation 4,000, total 24,000; the producer builds text from memory
   + routines + persona + `<teammates>`; `<teammates>` ≤999 scalars, each description ≤200, Bot
   description ≤300, automation with teammates ≤3,900; default persona is
   `你的名字是大肥鱼。用户问起名字时如实回答。`; a failed/slow/invalid/session-mismatched response
   yields an empty snapshot, never a stale one (`MCP/BotDomainVolatileContextProvider.swift:20-120`;
   `MCP/BotVolatileContext.swift:5-80`; `mcp-endpoint.md` §2.1).
9. **Listener recovery.** Prefer the previous port; if bind fails, try `.any`; probe the origin within
   1.5 s; on success publish the new URL; the token does not rotate on a Worker restart; a host restart
   rotates it (`BotMCPHTTPServer.swift:15-16`, `:129-253`, `:328-348`;
   `PC-20261110-bot-mcp-listener-recovery` is the only record today; move it into the owning spec).
10. **Native forwarding.** Non-Bot tools are forwarded unchanged with headers; `tools/list` merges
    native tools; `initialize` merges native instructions; the native server keeps its own auth/
    receipts/cancellation. The Bot listener's SSE covers the Bot call only; `/mcp/native` still buffers
    (GAP-36, `spec/README.md:228`) — state the failure and do not hide it.
11. **1 MiB body, POST-only, exact paths, origin/bearer.** Already in `mcp-endpoint.md:93-129`; repeat
    the error bodies/status in the new section so Kotlin does not invent them.

**Fixtures.** New `mcp-rpc-cases.json` (initialize/ping/list/call success/failure/batch/notification),
`identity-approval-cases.json` (register success/unauthorized/digest mismatch, cancel, approval
allow/deny/expiry/alwaysScope, sandbox escalation), `tool-call-cases.json` (every P0 tool, invalid
arguments, unknown tool, per-caller denial), card-builder negatives, volatile assembly cases. The
existing `mcp-egress.phone.json` stays the egress/identity/tools-call authority; do not duplicate it.

**Compatibility.** The wire is MCP Streamable HTTP; the new bodies are the App↔Worker contract, not a
new transport. The session token remains memory-only. Old Worker + new App fails closed on the missing
egress header (documented). The `x-pdsh-bot-session` header is additive; a standard MCP client without
it keeps the static catalog.

**Acceptance.**
```bash
python3 spec/bot/v1/tools/validate_vectors.py
```
Kotlin: `:net:test --tests 'com.phonedsh.loopback.BotMcp*'` and
`:bot:testDebugUnitTest --tests '*MCP*' --tests '*Grant*' --tests '*Card*' --tests '*Volatile*'`.
A real Worker E2E is `NOT_RUN` unless the packaged Worker + model are available.

---

### D14 — BotFish renderer contract and numeric trajectory (XL)

**Target.** New `spec/bot/v1/fish-renderer.md`; new `fish-trajectory.schema.json` +
`golden/fish-trajectory.json`; a new `fish-assets.json` manifest with SHA-256 per file; new
`spec/bot/v1/tools/fish_trajectory_compare.py`.

**Why.** S17 is entirely `spec-missing`: the layer list, palette/LUT, crop/pivot, clip periods, spring
constants, sprite order, quantisation and fps/pause exist only in Swift
(`examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishRenderer.swift:89-135`, `:203-260`, `:368-450`,
`:1149-1210`; `BotFishModel.swift:31-170`, `:171-430`; `BotFishEngine.swift:61-100`, `:233-300`,
`:519-541`; `BotFishView.swift:60-100`). The director/reaction part is already frozen; the pixels are
not, and pixel parity is not a valid gate across two rasterisers.

**Section outline.**

1. **Assets.** Inventory under `BotFish/` with dimensions, RGBA, SHA-256, license/provenance
   (`SOURCES.md` moves under `spec/` or is linked normatively). `body.png` is greyscale; the LUT uses
   the 15 color hexes from `bot-profile.json`; hair variants map `long→base/`, others→`hair/<style>/`;
   crown variants map `crowned/<style>/` + `overlays/crown*.png`; `expressive/eyes.png` and `mouths.png`
   are 3×4 cells of 256×128 with the exact name order (`BotFishModel.swift:31-60`;
   `examples/probe-app/BotFish/SOURCES.md:8-60`).
2. **Layers.** Base = body+fixed+crown+blush+eye whites; face = eyes/iris/brows/mouth/tears/
   decoration; compositing order and the “crown is in the flat base, then head-sliced” rule
   (`BotFishRenderer.swift:5-19`, `:368-450`).
3. **Crop/pivot.** Normal crop 416 px at `(48,30)`, crowned 448 px at `(32,10)`; pivot source
   `(256,350)`; design size 512; ink `#211919` (`BotFishRenderer.swift:89-135`; `BotFishView.swift:142-160`).
4. **Model.** Per-state clip period/duration, phase/progress, and every parameter assignment for all
   P0 states/one-shots (`BotFishModel.swift:118-430`). This is the part the trajectory freezes.
5. **Controller.** Springs: gaze 23, head 8, body 5, morph 13, face 22; blink/poke/idle timers;
   expression cross-fade/clip sampling; reaction overlay priority and TTL (`BotFishEngine.swift:61-100`,
   `:233-300`; `BotFishReactions.swift:8-135`).
6. **Pose.** Offset 0.25 output px, scale 0.5/target, roll 0.1°, alpha 1/64; the pivot and the
   `size × displayScale` target (`BotFishEngine.swift:519-541`).
7. **Frame policy.** 20 fps, 15 fps at ≤40 pt; pause on hidden/background/still/reduce-motion/low-power;
   paint one frame when paused; head slicing only >40 pt with 0.1-unit quantum
   (`BotFishView.swift:60-100`; `BotFishRenderer.swift:131-165`).
8. **Trajectory format.** The schema in the plan §9.3: viewport, cases, frames, params, pose, alpha,
   static, art names; tolerances 1e-6; ordering; seeded controller replays.
9. **Comparison tool.** `fish_trajectory_compare.py --golden --android [--ios]`; a missing case/frame
   or an out-of-tolerance number fails; prints the first JSON path. The iOS side is optional on
   non-macOS CI and must be reported `NOT_RUN`, not skipped silently.
10. **Screenshots.** A small set (idle/thinking/working/alerting/celebrate, light/dark, 32/96 pt) is a
    regression gate only; state explicitly it is not cross-end pixel parity.

**Fixtures.** `fish-trajectory.json` as described; `fish-assets.json` with one SHA-256 entry per asset file
(33 PNGs + `atlas.json` + `expressive/atlas.json`; `SOURCES.md` is provenance, not an asset);
`fish-director.json` stays unchanged. Add a mutation test that changes one parameter by 1e-3 and
expects the comparator to fail.

**Compatibility.** New target; no old data. Asset files are copied byte-identically from the pinned
upstream commit; a missing/changed file fails the checksum gate. A future style/color addition is a new
case, not a schema change.

**Acceptance.**
```bash
python3 spec/bot/v1/tools/validate_vectors.py
swift test --filter PhoneDSHBotTests.BotFishDirectorTests    # reference, macOS
bash android/tools/with-android-toolchain.sh ./gradlew \
  :bot:testDebugUnitTest --tests 'com.phonedsh.bot.fish.*'
```
Cross-end: run the comparator with both JSON files; without a macOS run, record the iOS half `NOT_RUN`.

---

### D15 — P09 Bot page reconciliation (M)

**Target.** `spec/ui/v1/pages/bot-chat.md`, `bot-drawer.md`, `bot-info.md`, `bot-dock.md`; add
machine-readable page JSON under `spec/ui/v1/pages/` if the P09 checker is to cover Bot pages; update
`spec/ui/v1/pages/_baseline.json` only under the P09 owner’s rules.

**Why.** CCR-3 and CCR-4 are contradictions in the current page contract. The Bot pages are `target`
and are not in the 48 machine-checked page contracts (`page_structure_check.py` reports 48 page
contracts / 44 Android screens; Bot is absent). Android cannot implement “the page contract” while two
authorities disagree, and cannot use the page checker as evidence until the pages are machine-readable.

**Section outline.**

1. **Bottom bar.** Decide four equal columns (shipped `HomeTabBar.swift`, `HomeTabBar.kt:6-7`) or the
   bot-dock Chat circle + capsule; update `bot-dock.md`/`HomeTabBar` accordingly. The Bot tab is the
   Chat/Personal Agent surface; its accessibility label and selected trait are frozen.
2. **Agent-comm.** Remove the “not implemented” sentence or define the P0/P1 surface; if P0, add the
   row/avatar/crown rule to `bot-chat.md` §3 and the row list; if P1, say it is not rendered and keep
   the data protocol-visible.
3. **Machine-readable pages.** Convert the three Bot markdown pages to the same JSON page contract
   shape as the other 48 (sections/actions/titles/android block), or state that Bot pages are
   intentionally outside `page_structure_check.py` and add a Bot-specific checker. Do not lower the
   checker’s floor or add whitelist rows.
4. **Geometry.** Every fixed value must be a `tokens.json` leaf or a named constant with a source; no
   new hand-typed colors/radii. The Bot card surface 16 pt / content 12 pt / option 44 pt are already
   in `bot-chat.md:22-42`; move the numbers that are missing into tokens or componentMetrics.
5. **Accessibility ids.** Freeze the ids already listed in `bot-chat.md` §6 and `bot-drawer.md` §2-4;
   add the ones the Android implementation needs (card option ids are `optionID`, not new UI ids).
6. **Deep link.** `phonedsh://bot/<botID>/row/<rowID>`: parse, select the Bot, load history, scroll to
   the row; unknown/expired row shows unavailable and does not jump to another session
   (`bot-info.md:25`; `BotUIModels.swift:496-510`).
7. **Evidence.** Add the Bot pages to the screenshot/capture plan only after the pages exist; do not
   reuse the iOS `scripts/ci/bot-ui/capture.sh` as Android evidence.

**Fixtures.** Three page JSON files (or a documented exclusion), a token mapping for every Bot geometry
value, and a screenshot fixture list (light/dark, 32/96 pt fish, card states). If the page JSON is
added, `page_structure_check.py` must report the Bot pages with zero divergences; if not, the exclusion
must be explicit and the Bot-specific UI test is the evidence.

**Compatibility.** P09 is a UI contract; changing a tab/row is a breaking visual change for iOS and
Android. Add the new pages without editing the existing 48 contracts; update `_baseline.json` only for
entries the owner agrees are obsolete, never to hide a new divergence.

**Acceptance.**
```bash
python3 -B spec/ui/v1/tools/page_structure_check.py --root .
```
Expected after D15: the Bot pages are either checked with 0 divergences or explicitly excluded with a
recorded reason; the pre-existing 12 divergences are not made worse. Android:
`:lib:testDebugUnitTest --tests 'com.phonedsh.ui.bot.*'` and the screenshot suite on an emulator.

## 3. Delta → checkpoint matrix

| Checkpoint | Deltas that must be frozen first | What cannot start without them |
| --- | --- | --- |
| B0 | D0 | Listener/egress/env/notification/module registration |
| B1 | D1, D2 (+ CCR-1, CCR-2) | Stored bytes, schema validity, outbox semantics |
| B2 | D10 | Normalization, injection bytes, recall score, replay |
| B3 | D8, D9 (+ CCR-7) | Routine state machine/timers, held-block grammar, hidden prompts |
| B4 | D5, D6, D7 | Proactive rules/vectors, watchdog config, lint thresholds, enforcement |
| B5 | D13 (+ D1/CCR-2 for the snapshot type) | JSON-RPC bodies, approval/identity, cards, volatile, listener |
| B6 | D12 | Team prompt/ids/errors, task restore/wake |
| B7a | D3, D4, D11 | Projection/display/actions, profile files, attachment phone bytes |
| B7b | D15 (+ D11) | Tab/agent-comm decisions, page JSON/tokens, deep link |
| B8 | D14 | Renderer model/pose/trajectory/assets |

## 4. Guardrails for the contract owner

1. **Do not copy Swift constants into the spec without deciding they are the contract.** A value copied
   from `BotFishModel.swift` or `RoutineScheduler.swift` is a proposal; if the owner freezes it, both
   ends change together.
2. **Do not widen a schema to make an implementation pass.** Adding `additionalProperties: true`,
   deleting a `required`, or allowing a second error code for the same meaning is a contract change that
   needs its own delta and compatibility answer (`AGENTS.md` §2.3).
3. **Keep upstream goldens byte-identical.** Phone additions go in `.phone.json` overlays with
   `upstream`/`delta`; `check_golden.py` enforces the manifest and append-only merge
   (`spec/bot/v1/README.md:167-185`).
4. **Every new golden needs a real decoder on both ends.** A Python validator passing is not runtime
   conformance (`spec/bot/v1/README.md:165`); the Kotlin test must load the same file from disk, and
   the Swift test must still pass or be reported `NOT_RUN`.
5. **Do not loosen a gate.** No new whitelist row, no raised cap, no skipped case, no lengthened timeout
   to hide a failure (GAP-36, `docs/parity/lessons.md:8-10`).
6. **State status honestly.** A new contract piece is `target` until both ends have runtime evidence;
   a JVM test is not a device test; a schema/golden check is not runtime conformance
   (`spec/README.md:34-46`, `:246-247`).
7. **When the contract is wrong, stop.** If a delta cannot be written because two clauses contradict
   (as in CCR-1–CCR-7), issue the CCR and leave the checkpoint blocked; do not add a platform-only
   branch.
