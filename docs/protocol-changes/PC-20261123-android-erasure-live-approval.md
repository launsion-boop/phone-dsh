<!-- SPDX-License-Identifier: MIT -->

# Android session erasure and live write approval

```yaml
change: PC-20261123-android-erasure-live-approval
base: c6b20cf43
contracts: [P02, P05, P09, P25, P26, P27]
status: frozen
breaking: false
version_decision: retain WAL v1, session tombstones, existing P25 erasure records and durable approvals
contract_revision: c6b20cf43 for wal.md §5.3, Bot v2 memory erasure, Bot v1 egress approvals, and session epochs
```

The Android information page refuses physical erasure and an Android chat write returns pending immediately. Use the existing iOS contracts and fixtures on Android. Confirmed erasure covers the selected document, the Bot's agent scope or the explicitly selected shared user scope. Closed-session evidence is erased through parked-host WAL mutation, epoch close, compaction and derived-cache cleanup. The Bot store clears its payloads only after the session eraser succeeds. Keep unrelated documents, Bots and surviving session lines. Existing journals, third-party backups and device-level forensic erasure are outside the guarantee.

A connected chat request waits for its durable per-host/per-method decision for the iOS interactive window. A timely allow continues the original body once. Refusal, pending timeout, caller disconnect, revoked identity and a failed once-grant claim send nothing. Background jobs retain their durable retry path. Identity, Task capability, allow-list, redirect and credential rules remain binding. No new Worker headers, request IDs, token formats or wire fields. Old and new apps use the same stored tombstones and grants in both directions.

One implementer owns the Android host, gateway and Bot integration. Swift remains the reference. Verify with WAL and memory erasure vectors, approval tests covering rejection and disconnection, production surfaces on both simulators, and separate local test data. Do not infer hardware or power-loss evidence from these runs.
