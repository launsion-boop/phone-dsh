<!-- SPDX-License-Identifier: MIT -->

# PC-20261121-engine-first-launch-followups — timer retry, queued Bot sends and connector cadence

## 0. 摘要

```yaml
change: PC-20261121-engine-first-launch-followups
contracts: [P06, P09, P26]
status: frozen
breaking: false
version_decision: No version bump and no wire/durable format change. P06 gains one caller-rule clarification for
  expiry-only decision vectors. P09 freezes the Bot queued-send visibility that PC-20261120 already claimed.
  P26 has no value/schema change; the connector scan step now honours its existing WakeDemand cadence.
base: 09a3db1f5e330fed3ee3a85d7e6151d4aa057465
contract_revision: docs/protocol-changes/PC-20261121-engine-first-launch-followups.md@1
```

## 1. 识别

- **Trigger → current → expected.**
  - Resident timer: `WakeScheduler.refresh()` re-arms `residentTimerAtMs`, which is `now` for an
    overdue demand. A wake that cannot consume the demand (explicit stop, `needsReset`, a failed
    boot, a gated/failed ReadySweep step) therefore re-arms at zero delay. A hostless harness that
    mirrors `EngineLaunchOrchestrator.performWake` measured 89,409 wakes in 600 ms. Expected: the
    first attempt stays immediate; retries of the same overdue set are spaced.
  - Bot send: when the unit is not up, the dispatcher writes the durable pending-action row and
    the unavailable planner returns the internal sentence `Bot 大脑 planner 尚未接入，消息和审批动作未执行。`.
    `BotChatModel.perform` marked the action failed and removed the optimistic row, so the user saw
    the message disappear and an internal error, contradicting `ui-state.md` §1.1's "queued" claim.
    Expected: the row stays, a quiet queued line is shown, the internal reason never reaches the
    header, and unit-start replay delivers it.
  - Connector scan: the step ran on every wake and the 30-minute `connectorScan` demand only
    scheduled wakes. A sign-out left a stale demand because the connector wiring was installed
    before the WakeDemand sink. Expected: the step honours its demand; unauthorized connectors lose
    their demand; a connector without a demand is scanned once for its baseline.
  - Silent resume: `resumeForWake` had no silent depth, so the resume watchdog, one automatic
    rebuild and `needsReset` fallback could write a status line or raise a user error from an
    orchestrator-owned resume. Expected: the whole resume/recovery path is silent; only the
    terminal `needsReset` state surfaces a restart affordance.
- **Roles.** Coordinator/contract owner: this change unit. iOS implementer: same unit. Android:
  reads the clarification; no code change required.
- **Owning contracts / fixtures.**
  - P06: `spec/host/v1/README.md` §10.2.4 caller-rule paragraph; `spec/host/v1/golden/engine-launch.json`
    `notes` only. No new vector.
  - P09: `spec/ui/v1/bot/ui-state.md` §1.1; `spec/ui/v1/bot/strings.json` `runtime.queuedSend`.
  - P26: no schema or value change. The connector demand table already owns the cadence
    (`spec/host/v1/README.md` §10.3.2, `spec/bot/v2/README.md` §3.3).
- **Producer/consumer.**
  - iOS host/Bot (Swift): timer, silent scope, queued send, Bot page banner, connector gate.
  - Android (Kotlin): no change in this PR; the caller rule is recorded in the handoff.
  - Cloud/Worker/Rust: no change.

## 2. Delta

| Item | Before → After |
| --- | --- |
| Resident timer retry | A due demand is still attempted immediately the first time. Retries of the same overdue set are spaced by an app-internal 60 s window; a changed overdue set or a consumed demand is immediate again. This is app-internal scheduling, not a contract constant. |
| Bot queued send | A durable pending-action row whose planner reports a retryable reason is `queued`, not `failed`. The optimistic row stays and shows `runtime.queuedSend`; the internal planner reason is never header copy. Terminal rejections keep the existing failure copy and rollback. |
| Bot page engine state | A terminal `engineNeedsReset` or an explicit user stop shows a restart/start banner on the Bot page. A silent boot/resume remains silent while in progress. |
| Silent resume/recovery | `resumeForWake` and the automatic recovery it schedules carry the same silent scope as `startForWake`; `resumeSlowNotice`, `restartEngine` status and `rebuildEngine` status are suppressed while that scope is active. |
| Connector cadence | `connectorScan` runs only when at least one authorised connector has no demand (baseline) or a due/overdue demand. Signing out removes the demand. The first scan still only establishes the cursor. |
| Connector main-Bot unit | The composition binds the main Bot's unit (not only the selected/routine-owner units), so a metadata update can be considered by the proactive policy without waiting for the user to open that Bot. |
| Host retry durability | `engineBoot`/`outboxSettle` demands are awaited before the in-process sleep starts; a kill between the two no longer loses the deadline. |
| Expiry-only vectors | Clarification only: the golden's `bgProcessing`/`bgAppRefresh` timed-lease vectors pin the pure function; a conforming caller passes a null lease. No vector changed. |
| UI catalog | The stale `runtime.connecting` entry is removed (the banner was deleted by PC-20261120 but its catalog row survived); the Bot message-row and push interaction anchors are refreshed to the code they describe. `runtime.queuedSend` and the two engine-state strings are added. |

No new field, enum value, route, payload, durable byte or threshold. The retry window is an
app-internal scheduler value, deliberately not a shared golden constant.

## 3. Compatibility

- Old → new: a new build writes the same wire, durable rows and ledger shape. Existing Bot pending
  actions, connector demands and routine demands are read unchanged.
- New → old: no new durable format. A `queued` action state exists only in the app's UI model; the
  durable pending-action row is the existing v4 format. A rollback replays it through the old path.
- Data: a stale `connectorScan` demand is removed by the new wiring on the next prepare. A demand
  that is left due by a failure is retried with the new spacing; it is not dropped.

## 4. Verification

- `python3 spec/host/v1/tools/test_engine_launch.py`
- `python3 spec/ui/v1/bot/tools/check_bot_ui.py`
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
- `xcodebuild test -scheme PhoneDSHSim -only-testing:PhoneDSHSimTests/EngineLaunch…`
  (the new waiter/connector/queued-send regressions)
- Not verified: physical-device APNs/BGTask scheduling and the offscreen background anchor; those
  remain the `ios-wake-spike` evidence item from PC-20261120.