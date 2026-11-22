# PC-20261122-bot-queued-send-replay

## 0. Summary

```yaml
change: PC-20261122-bot-queued-send-replay
contracts: [P25, P09]
status: implemented
breaking: false
version_decision: none — App replay policy only; no stored field, wire field or string changes
base: 7ad45d3b
contract_revision: this change (spec/bot/v1/store.md §10.5, spec/ui/v1/bot/ui-state.md)
```

## 1. Identity and roles

- Trigger → current → expected: on the device, a Bot send made while the engine was absent
  stayed 「待发送，引擎就绪后自动发出」 (`runtime.queuedSend`) forever.
  `spec/ui/v1/bot/ui-state.md` and `store.md` §10.5 say the row "is kept and replayed on unit
  start". But `BotPendingActionReplayPolicy.automaticReplay = false` (20574440, 11-14) had
  turned replay off: a stale pending row started an unsolicited turn at launch. Expected: a
  send the user just made is delivered once the unit starts, and old rows still never fire on
  their own.
- Coordinator / contract owner / implementer / reviewer: one agent (small task), decision by the
  user ("Replay recent queued", 2026-11-22).
- Owning contracts: P25 `spec/bot/v1/store.md` §10.5 (replay policy); P09
  `spec/ui/v1/bot/ui-state.md` ("Sending while the engine is absent").
- Producer / consumer: iOS only — `BotRuntimeComposition` schedules the replay,
  `BotProductionRowService.replayPendingActions` runs it. Android `:bot` has the v4 table but no
  replay and no queued-send state, so it is unchanged. HarmonyOS has no Bot.

## 2. Contract delta

| Item | Before → After |
| --- | --- |
| Replay scope | §10.5 "re-dispatches them" (all rows; disabled in code) → automatic replay re-dispatches only `chat` rows whose `created_at_ms` is no older than **15 minutes** (900 000 ms) at the start of the pass. Other kinds and older chat rows are not dispatched automatically and stay retained (unchanged retention rule). |
| Ordering / idempotency | unchanged (oldest first by `created_at_ms`, `nonce`; nonce de-dup returns `duplicate`) |
| UI | `runtime.queuedSend` copy unchanged; its promise now holds within the window. A row that is older than the window when the unit starts keeps today's behaviour (retained, no automatic turn). |
| Terminal outcome / TTL | unchanged: the `send-expired` notice and the TTL stay a follow-up (§10.5). |

Self-check: no new field, enum, string or second expression. The change narrows an existing
App-owned policy.

## 3. Compatibility

| Producer → Consumer | |
| --- | --- |
| old → new | old rows written before the upgrade are older than 15 min after any real gap, so they are not replayed. A row written within the last 15 min before an upgrade is replayed once. Nonce de-dup prevents a second turn. |
| new → old | an older build does not replay (flag off); rows stay retained as before. |
| persisted data / rollback | no schema change; rollback keeps rows untouched. |

## 4. Evidence

- iOS sim tests: `PhoneDSHSimTests/BotPendingActionReplayWindowTests`.
- Device: iPhone19,4, `pdsh-debug.py`; see the PR handoff block.

## 5. Revisions

| revision | by | reason | ends notified |
| --- | --- | --- | --- |
| 1 | Claude (session fix/boot-missing-session) | user decision on the conflict between ui-state.md / store.md §10.5 and 20574440 | iOS; Android recorded as unaffected |
