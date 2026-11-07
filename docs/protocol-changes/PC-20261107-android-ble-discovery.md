# Freeze Android foreground BLE discovery slice

```yaml
change: PC-20261107-android-ble-discovery
contracts: [P07, P08, P09]
status: frozen
breaking: false
version_decision: Add local untrusted discovery UI and API only; no wire or persistence version change.
base: 46c4c57b9c40e87baa5b70cb37018e9abee6c6d4
contract_revision: spec/device/v1/android-ble-discovery.md@discovery-v7
```

Protocol impact: P07; P08; P09. The Android app has no production BLE
discovery, no settings entry, and no Bluetooth permissions. The existing
decoder is target code and must not be treated as a GATT adapter. Freeze an
explicitly partial user-initiated advertisement browser before implementation.
Its owning contract, public Kotlin interface, schema and ordered shared cases
are committed together. The user-facing page cannot claim iOS page parity,
connection, identity, authorization, Link, tools or device-task support.

The contract owner owns `spec/**`, this record and
`android/domain/src/main/kotlin/com/phonedsh/domain/connector/ble/BleScanSource.kt`.
The platform implementer owns app scanner, Android manifest, Activity and
host wiring, permission handling and app tests. The UI implementer owns the
Bluetooth discovery page, its settings/navigation entries and lib tests. They
implement the exact interface in the frozen revision and use the shared
scenarios through the real scanner state machine, with injected platform
events; an independent integrator reviews the combined head. UI may display a
missing source as unavailable, never mock discovery as a real device.

No BLE producer or other phone changes its wire messages: Android reads
existing advertisements without assuming support. Old app/new peripheral,
new app/old peripheral, and new/new retain existing connection behavior;
results are untrusted labels only. No data is migrated or persisted, and
rollback removes this local browser. The per-scan candidate retention is
different from iOS's cross-scan in-memory store; this partial slice is not a
P08 whitelist exemption or complete P09 parity. Fine location is only requested
where legacy Android scanning requires it. `neverForLocation` on API 31+
reflects the current app's non-location use and may filter advertisements;
it must be revisited before any future location derivation.

Test actual permission decisions, start/stop callback identity, system failure,
revocation, page/host lifecycle, delayed callbacks, duplicate/overflow and
name/privacy handling. The platform fake is not radio evidence. Contract
checks: `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree`; Android checks:
`cd android && ./gradlew :domain:testDebugUnitTest :app:testDebugUnitTest
:lib:testDebugUnitTest :app:processDebugMainManifest :app:assembleDebug`,
plus applicable repository Android structure/tests gates. Inspect the merged
manifest, not just its source. Run true Android permission/lifecycle/discovery
and failure tests with a physical Android device and an actual BLE advertiser;
until then they are NOT_RUN, not inferred from fake or simulator results.
Stop is unacknowledged by the OS and its failure remains unresolved as in the
contract. The baseline P0 failures, Android GATT GAP-20, secure session GAP-16
and legacy recovery remain open.

Revision v2: review found that start can block or throw after side effects,
Activity recreation could discard a quarantine, and an old permission result
could be misattributed. Add asynchronous starting/stopping states, process-wide
quarantine, single-flight permission ownership, and real callback identity and
failure observations. Address fields must never be output; arbitrary advertised
names may themselves contain address-like text. Implementers were paused
before they could rely on v1 and must use this revision.

Revision v3: the process-wide quarantine also applies to start exceptions.
Repeated start while the original permission request remains active is a no-op;
after invalidation a new action must not claim the old result. Ownership is
installed before registering result callbacks, which may deliver synchronously.
The 15-second monotonic deadline is recorded before invoking platform start;
candidate callbacks while starting are dropped and early failure is retained
until cleanup. Kotlin candidate and snapshot stringification redact values.

Revision v4: clarify that an attempt cancelled before platform start needs no
stop call, and that an invalidated generation's registered start/stop completion
may update only its own cleanup state. Late discovery data remains rejected.
Use sleep-inclusive elapsed realtime and check the absolute deadline again on
start completion and each result, even if the timer callback has not run.

Revision v5: platform stop, like platform start, runs on the serial worker.
Local invalidation is immediate; `STOPPING` continues until the stop call
returns or raises. Shared scenarios explicitly distinguish those events.

Revision v6: implementer CCR noted a sleep/frozen process cannot run a timer
at a guaranteed elapsed-realtime deadline. The deadline rejects late results;
stop is requested at the next relevant event including host start or screen-on.
No physical stop-time or background-power guarantee is inferred.

Revision v7: independent review found that an old Activity's onStop or a
page's delayed dispose could stop a newer owner's scan. The process coordinator
now issues host facades and non-reusable page sessions; all actions and
candidate snapshots are owner-scoped. Other owners see BUSY without candidates.
Host lifecycle and permission launch are bound to that host, never a global
last-attached Activity. New users or recreated Activities need a fresh action.
