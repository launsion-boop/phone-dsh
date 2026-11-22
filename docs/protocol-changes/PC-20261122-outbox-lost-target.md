# PC-20261122-outbox-lost-target

## 0. Summary

```yaml
change: PC-20261122-outbox-lost-target
contracts: [P06]
status: implemented
breaking: true
version_decision: host outbox entry stays v 1; additive state targetLost under the new section 10 unknown-state rule (an old consumer skips the file and never rewrites, delivers, deletes or GCs it)
base: af4d918b
contract_revision: this change (spec/host/v1/README.md section 10, schema/outbox-entry.schema.json, golden/outbox-entry-target-lost.json, tools/outbox_invalid_cases.json)
```

`breaking: true` because the closed `state` enum of a persisted, two-ended schema gains a value
(baseline §5.1 rule 4); the compatibility answer is in §3.

## 1. Identity and roles

- Trigger → current → expected. Device report (iPhone19,4, 2026-11-22): six outbox entries
  target `session-941c1a02…`, a session that only exists in the engine quarantined on 11-17
  (`Documents/chat-host.quarantine-2026-11-17…`). PR #224 stopped those entries from blocking
  the live session, but §10 has no edge out of `queued` for a target the engine no longer has,
  and an entry is deleted only after it is `durable`. So the six stay `queued` forever, still
  count toward the 排队中 badge, are invisible (their session cannot be opened) and cannot be
  sent or removed. Expected: the engine's own `session/not-found` verdict moves such an entry to
  a resting state that is not 排队中; the user sees it on the live page and either resends its
  content to the session on screen or discards it, both by an explicit tap.
- Coordinator / contract owner / implementer (iOS, Android) / reviewer: one agent (small task,
  started from the PR #224 session).
- Owning contract: P06 `spec/host/v1/README.md` §10 (state machine, delete condition) and
  `spec/host/v1/schema/outbox-entry.schema.json`. Shared fixtures: `golden/outbox-entry-*.json`,
  `tools/outbox_invalid_cases.json`, judged by `tools/test_outbox_contract.py`.
- Producers / consumers of the entry file:
  - iOS `examples/probe-app/ProbeKit/Outbox/SendOutbox.swift` (store + codec), driven by
    `ChatModel.drainSendOutbox` / `activateSessionForOutbox` (producer of the new edge) and the
    chat page (consumer of the new user actions).
  - Android `android/app/.../outbox/SendOutbox{,Entry}.kt` (store + codec), driven by
    `ChatSendQueue`. See §4 for why Android has no producer of the new edge.
  - External admission journal (`external-admission.md`): reads the outbox only through
    `rpcId = downstreamId`; unchanged (§2 last row).

## 2. Contract delta

| Item | Before → After |
| --- | --- |
| `state` enum | `queued, submitting, accepted, durable, outcomeUnknown` → adds **`targetLost`**. No new member: the entry keeps every existing field; the producer writes `lastError: "session_not_found"` (internal diagnostic, never shown). |
| New edge | **`queued → targetLost`**, and only on proof: the engine answered `session/not-found` when the host opened or resumed the entry's `sessionId` for delivery. A transport failure, timeout, absent/parked/starting engine, a missing local cache, an inconclusive read-back or a guess is not proof. |
| Edges not added | No edge out of `submitting`, `accepted` or `outcomeUnknown` into `targetLost`: those may already be in the lost session's history, and a read-back of a missing session cannot prove absence. They keep today's rules (tracked as a remaining risk, §4). No edge out of `targetLost` exists in the state machine. |
| Resting semantics | `targetLost` is never submitted, never read back, never resumed by the startup scan, never moved to another session, never counted as 排队中 and never deleted automatically. |
| Delete condition | Was: only `durable` after the authoritative `user_message`. Adds two **user-initiated** deletions of a `targetLost` entry (entry file first, then `attachments/<rpcId>/`): **discard** (the user removes it), and **resend**, which first enqueues a *new* entry (new `rpcId`, the live session the user is on, same text, attachment bytes copied and digest-verified through the ordinary enqueue) and only after that entry is committed deletes the `targetLost` one. Resend is an explicit tap, never automatic. |
| `rpcId` | Unchanged for every existing entry. Resend mints a new `rpcId` because it is a new user message to a different session; the old `rpcId` never reached any live authority (it was `queued`: never submitted, or proven absent before requeue), so this cannot duplicate a delivered message. |
| Unknown-state rule (new, §5.1 rule 4) | A consumer that reads an entry whose `state` it does not know leaves the file untouched: it does not deliver, rewrite, delete or migrate it, and startup GC keeps its `attachments/<rpcId>/` because the entry file exists. This is exactly what both pre-change consumers already do (Swift `entries()` skips an undecodable file; Kotlin `read()` returns null; both GCs key on the entry file's existence). |
| UI | The 排队中 projection excludes `targetLost`. The live chat page shows lost entries (any session) as one notice: 「N 条消息的原对话已不在引擎中」 with per-row 「发到当前对话」 and 「删除」. No banner/prompt for any other state changes. |
| External admission | A `dsh-session` record whose downstream entry is discarded or resent can no longer be attributed by `downstreamId`; the existing `linked → unknown` edge ("the downstream owner can no longer attribute it", or the 14-day rule) applies. No change to that contract. |

Self-check against baseline §5.1: one expression per meaning (no alias of `queued`, no second
error code — `session_not_found` is the existing provider mapping of `session/not-found`); no new
member; the only widening is the enum value, covered by the new unknown-value rule; nothing
removed or renamed; persisted old entries stay valid.

## 3. Compatibility and release

| Producer → Consumer | Behaviour; test |
| --- | --- |
| old → new | Old builds never write `targetLost`; every old entry decodes unchanged. A `queued` entry for a lost session written by an old build becomes `targetLost` only when the new build's engine says `session/not-found` for it (the Duo's six entries migrate by proof, not by guess). Tests: all pre-existing goldens still validate and round-trip (`test_positive_goldens_validate`, `SendOutboxContractTest`, `SendOutboxTests`). |
| new → old (rollback) | An old build skips a `targetLost` file (unknown enum → undecodable → skipped), never rewrites or deletes it, and its startup GC keeps the attachment directory. The row disappears from the old UI and the badge drops — the same user-visible result as discard, but reversible: re-upgrading shows it again. Test: Swift/Kotlin "unknown state is skipped and kept" cases use the `unknown-state` invalid case. |
| new → new | `queued → targetLost` on `session/not-found` only; resend/discard are the only exits. Tests: shared golden `outbox-entry-target-lost.json`, invalid transitions `target-lost-to-queued`, `target-lost-to-submitting`, `outcome-unknown-to-target-lost`, `submitting-to-target-lost`, `accepted-to-target-lost` on both ends. |
| persisted old data → new / rollback | Covered by the two rows above; no migration step, no version bump (a `v: 2` would make old builds skip *all* new entries, not just lost ones). |

- Version decision: entry stays `v: 1` per §10's new unknown-state rule; the schema-diff
  exemption is this record (`breaking: true`, frozen at `base`).
- Release order: none required; each platform's store is local to the device.
- Removal of old paths: none.

## 4. Division of work and evidence

- Paths:
  - contract: `spec/host/v1/README.md` §10, `schema/outbox-entry.schema.json`,
    `golden/outbox-entry-target-lost.json`, `tools/outbox_invalid_cases.json`,
    `tools/test_outbox_contract.py`, this record;
  - iOS: `ProbeKit/Outbox/SendOutbox.swift`, `PhoneDSHProbe/ChatModel.swift`,
    `PhoneDSHProbe/ChatSessionBoot.swift`, `PhoneDSHProbe/ChatPage.swift`,
    `PhoneDSHSimTests/{SendOutboxTests,OutboxActivationHoldsTests}.swift`;
  - Android: `android/app/.../outbox/{SendOutbox,SendOutboxEntry,ChatSendQueue}.kt`,
    `android/app/src/test/.../outbox/{SendOutboxContractTest,SendOutboxTest}.kt`.
- Android producer: **not wired, recorded.** Android's `ChatSendQueue` never activates another
  session for an entry; it only delivers into `activeSessionId()`. When the Worker answers
  `session/not-found`, `ChatTurnRunner` opens a new Worker session for the same chat and tells
  the user (「上一段上下文已丢失…」); that is the existing P06 context-lost path and is not an
  outbox proof. So Android has no place that holds the proof this edge needs. Its codec,
  transition table, store operations (`markTargetLost`, `discardTargetLost`, `resendTargetLost`)
  and its 排队中 projection implement the contract and are driven by the shared fixtures, so a
  future producer needs no contract work. Follow-up tracked in GAP-51.
- Commands and results: see the PR handoff block.
- Remaining risks (GAP-51): `submitting`/`accepted`/`outcomeUnknown` entries of a lost session
  still have no exit (read-back of a missing session is inconclusive); a crash between the resend's
  enqueue and the old entry's delete leaves both rows, so the lost row is offered again — a second
  resend needs another explicit tap, never an automatic one; Android producer not wired; no
  device run of the resend tap yet.

## 5. Revision record

| revision | by | reason | ends notified |
| --- | --- | --- | --- |
| 1 | coordinator | initial freeze after PR #224 (device report iPhone19,4) | iOS, Android |
