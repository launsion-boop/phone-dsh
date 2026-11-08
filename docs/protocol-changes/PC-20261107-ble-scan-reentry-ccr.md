# iOS BLE scan intent ordering (GAP-30 scan reentry)

```yaml
change: PC-20261107-ble-scan-reentry-ccr
contracts: [P07, P09]
status: frozen
breaking: false
version_decision: Preserve BLE wire, status texts, 15-second deadline and explicit restart; add a local scan intent so a superseded scan/stop/initialization frame cannot write after a newer one.
base: a379f2ba (codex/fix-pr59)
contract_revision: spec/device/v1/ble-link.md@scan-intent-v1 (freeze commit aed8634b)
```

Protocol impact: P07; P09; P18: none — no stored identity, grant or
preference changes; P10/P11: none — no Worker or task surface is touched.

## Problem (from the original request)

Global status-text intent ordering (`PC-20261107-ble-status-order`) does not
order the independent scan side effects. Four diagnostic XCTest cases against
the real store with synchronous Observation and the DEBUG physical adapter
reproduced: (1) `stopScan()` inside the start's status will-change still lets
the older start publish `正在扫描（15 秒）` and install its timer; (2)
`stopScan()` inside the start's `scanning` will-change is overwritten by the
older `true`; (3) `scan()` inside a stop's `scanning` will-change is
overwritten by the older `false`; (4) `stopScan()` inside the initialization
status will-change still lets the older call construct the (simulated)
manager. These are local simulated-edge results, not radio evidence.

## Frozen rule

The normative text is the *Scan intent (`scan-intent-v1`)* paragraph of
`spec/device/v1/ble-link.md`. In short: every admitted start, every stop
(including connect's and deadline expiry's) and all-owner unavailability take
a fresh non-reusable local scan intent before any Observation, physical
command or status evaluation; every later effect of that operation (manager
construction, `scanning` write rechecked inside the mutation, scan-status
eligibility, deadline installation, powered-on auto-start) is conditional on
that intent still being current. The deadline belongs to one intent and is
inert once that intent is superseded. First writer of a *newer* intent wins;
a stale frame never writes, never submits a further physical command, and
never retracts one already submitted. This is the same identity-first,
stale-is-inert-regardless-of-power order as `discovery-deadline-v1`.

Owner decisions taken here, kept deliberately narrow:

- A start rejected because an initialized manager is unavailable takes no
  intent and only publishes its rejection text (unchanged behaviour).
- `stopScan()` still publishes no status. A superseded start therefore leaves
  the earlier text (for example `蓝牙已就绪，请点击扫描`), never its own
  `正在扫描（15 秒）`. Whether a stop should publish its own text is not
  decided here.
- A repeated powered-on start still submits a new scan and replaces the
  deadline with its own 15-second one (unchanged).
- Initialization cancelled before construction does not construct the
  manager; a later matching powered-on callback does not start the cancelled
  scan. A later explicit start constructs it normally.
- Same-value `scanning` writes make no mutation; a will-change already
  delivered to an observer for a write that is then superseded is not
  retracted (only the committed value is pinned).

| Version relationship | Compatibility |
| --- | --- |
| Old app / any peripheral | Unchanged wire; old reentry weakness remains. |
| New app / any peripheral | Same wire, texts and deadline; a nested newer scan/stop wins over the older frame. |
| Persisted data / rollback | Nothing persisted; rollback restores old local ordering. |

Not changed: BLE wire, task capability, permission prompts, Android or
firmware behaviour, connection/discovery deadlines, status-v2 ordering.

## Shared cases and real-store setup

Cases: `spec/device/v1/golden/ble-scan-intent.jsonl` (14 rows, SHA-256
`3ea6ae6bee1154a91fa2b0e3a0474bd04c390446b8f3f4b37537978620322b02`), schema
`spec/device/v1/schema/ble-scan-intent.schema.json`, mutations
`spec/device/v1/golden/ble-scan-intent-mutations.jsonl` (7 malformed rows the
schema must reject, 15 schema-valid semantic mutations — including each of the
four original defects written as an expectation — that the real-store
comparator must reject).

Each row uses a fresh real `BLEDeviceStore` with a DEBUG `TestAdapter`
substituting only the physical edges (manager construction, scan/stop
submission, power bit). No test sets `status`, `scanning`, intent, pending
start or deadline directly.

- `ready`: real `testRadioOn()` (shared manager-state dispatcher); status
  `ready`; physical log cleared.
- `scanning`: `ready` plus real `scan()`; capture the real production deadline
  probe as the *setup deadline* and assert it active; log cleared.
- `uninitialized`: adapter manager not constructed, power off, state unknown;
  status `prompt`.

`action`/`then`: `start` = `scan()`, `stop` = `stopScan()`,
`fire-setup-deadline` = invoke the captured production deadline handler
(including after cancellation), `manager-powered-on` = `testManagerState(.poweredOn)`.
`injection` installs one one-shot `withObservationTracking` registration on
`status` or `scanning` immediately before the action; the nested event runs
synchronously in the will-change callback, and the test asserts it fired
exactly once.

Expectations after the whole row: `status` maps `prompt` → `点击扫描以请求蓝牙权限`,
`init` → `正在初始化蓝牙`, `ready` → `蓝牙已就绪，请点击扫描`, `scan` →
`正在扫描（15 秒）`; `scanning` is the store's published value; `commands` is
the complete physical scan/stop submission suffix after setup; `deadline` is
whether the store's current scan deadline probe is active; `setup_deadline`
the captured setup probe state; `manager_constructions` the count of entries
into the (substituted) manager constructor during the row.

## Acceptance

- `PYTHONPATH=spec/v1/tools PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_spec_golden.BLEScanIntentFixtureTests`
- `swift test --filter 'BLEScanIntentTests|BLEStatusOrderingTests|StandardGatt'` (all 14 rows,
  15 semantic mutations rejected by the same comparator, the four named
  regression scenarios, and existing status/deadline/grant suites).
- `swift build -c release --target PhoneDSHBLE`.
- `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree`.

Ownership for this task: one agent holds coordinator, implementer
(`Sources/PhoneDSHBLE/BLEDeviceStore.swift`,
`Tests/PhoneDSHBLETests/BLEScanIntentTests.swift`) and reviewer roles.

Not verified by any of the above: real CoreBluetooth scan/stop sequencing,
permission prompt timing, physical power loss, device runtime.

## Implementation handoff

Freeze committed at `aed8634b` (spec, schema, cases, mutations, shape test).
The implementation adds `scanIntent`/`pendingScan` and a per-intent
`ScanDeadline` to `BLEDeviceStore.swift`, routes every `scanning` write
through an intent-checked mutation, and adds the DEBUG-only
`testCaptureScanDeadline` probe and `TestAdapter.managerConstructions` counter.
The four diagnostics became `Tests/PhoneDSHBLETests/BLEScanIntentTests.swift`.

Evidence (isolated scratch/TMPDIR/module cache under `/Volumes/dream/pdsh59-scratch-scan`):

- The unmodified diagnostic file run against the fixed store: all 4 old-bug
  assertions FAIL (expected — the defects no longer reproduce).
- `swift test --filter 'BLEScanIntentTests|BLEStatusOrderingTests|StandardGatt|BLEDeviceMCPTests|BLEIdentityTests|PDSHLinkTests|LegacyIdentityObservationTests|StandardBLETests|BLETrustedIdentitiesTests'` → PASS, 94 tests.
- Mutant check: dropping the in-mutation intent recheck in `publishScanning`
  makes `BLEScanIntentTests` FAIL (3 tests, 7 failures); source restored.
- Full `--filter PhoneDSHBLETests` → 97 tests, only the two pre-existing
  `BLETaskCrossRuntimeTests` C-bridge cases FAIL ("C task bridge build failed",
  missing pinned cJSON component).
- `swift build -c release --target PhoneDSHBLE` → PASS.
- `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS / PASS.

NOT_RUN: real CoreBluetooth radio, device, simulator UI, power loss.
