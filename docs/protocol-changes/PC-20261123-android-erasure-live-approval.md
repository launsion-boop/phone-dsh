<!-- SPDX-License-Identifier: MIT -->

# Android session erasure and live write approval

```yaml
change: PC-20261123-android-erasure-live-approval
base: c6b20cf43
contracts: [P02, P05, P09, P25, P26, P27]
status: implemented
breaking: false
version_decision: retain WAL v1, session tombstones, existing P25 erasure records and durable approvals
contract_revision: c6b20cf43 for wal.md §5.3, Bot v2 memory erasure, Bot v1 egress approvals, and session epochs
```

The Android information page refuses physical erasure and an Android chat write returns pending immediately. Use the existing iOS contracts and fixtures on Android. Confirmed erasure covers the selected document, the Bot's agent scope or the explicitly selected shared user scope. Closed-session evidence is erased through parked-host WAL mutation, epoch close, compaction and derived-cache cleanup. The Bot store clears its payloads only after the session eraser succeeds. Keep unrelated documents, Bots and surviving session lines. Android compares complete numeric event references when selecting a derived copy; a reference to event 20 survives erasure of event 2. Existing journals, third-party backups and device-level forensic erasure are outside the guarantee.

A connected chat request waits for its durable per-host/per-method decision for the iOS interactive window. A timely allow continues the original body once. Refusal, pending timeout, caller disconnect, revoked identity and a failed once-grant claim send nothing. Background jobs retain their durable retry path. Identity, Task capability, allow-list, redirect and credential rules remain binding. No new Worker headers, request IDs, token formats or wire fields. Old and new apps use the same stored tombstones and grants in both directions.

One implementer owns the Android host, gateway and Bot integration. Swift remains the reference. Verify with WAL and memory erasure vectors, approval tests covering rejection and disconnection, production surfaces on both simulators, and separate local test data. Do not infer hardware or power-loss evidence from these runs.

## Interrupted multi-record file

A log larger than the mutation limit cannot replace its surviving lines in one WAL record. A crash after the first complete-write record could otherwise truncate an unrelated surviving suffix. For each affected log, before its first mutation Android atomically publishes and fsyncs its survivor-only JSONL file in the private host root under `pending-session-rewrite/<original SHA-256>/<replacement SHA-256>/<path relative to home/sessions>`. A different digest or an unrecognized path fails closed. Input for recovery is the original digest (not started), the verified replacement (finished), or a byte-identical prefix of the verified replacement (finish the existing write). No command, identity, original payload or change to the WAL codec is stored. A cold boot or parked resume completes interrupted work before starting the Worker. After a committed prefix, recovery also completes removal of older generations and derived copies. The writer drops its private copy after durable close and cleanup. Finish an interrupted erase on the producing version before rolling back; older versions do not have this recovery reader. After success there is no pending state for older versions to read.


## Runtime evidence

The implementation reuses the existing P02 mutation codec, P25 physical-erasure transaction, P26 memory and authorization fixtures, P27 epoch switch and the P09 confirmation sheets. The Android loopback server uses Netty's peer channel at the pinned Ktor version. Only the host supplies this connection observation. The original request retains its body and consumes its once grant only after an affirmative decision. Android's HTTP client continues to use CIO.

On the iOS and Android simulators, the document start state included two stored versions, a separate surviving document, a closed session with an evidence row and its inbox splice, and an older generation. Both products returned erased-session receipts for sequences 1 and 3, kept sequence 2 and changed the main chat epoch. After an application restart the old generation was absent and the selected marker was absent from the inspected SQLite, WAL and session files. The simulator network stimulus used a local HTTP receipt server. Denial returned 403 with zero delivered denied bodies. An allowed original request returned 200 with one matching body. Android additionally rejected a new request after the single-use grant had been spent.

Android regressions include `ClosedSessionRewriteTest`, `DisconnectedWriteTest`, the shared memory-erasure and approval vectors, and the real-socket `BotNetworkApprovalDeviceTest`. iOS used its existing production erasure UI. A temporary simulator-only stimulus initiated the iOS network requests at the authenticated loopback entry. No iOS product change or test endpoint is shipped. Physical devices, power loss, device backups and raw flash blocks were not tested.
