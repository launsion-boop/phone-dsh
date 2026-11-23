<!-- SPDX-License-Identifier: MIT -->

# Android Bot information, card actions, lost sends and network approval

```yaml
change: PC-20261123-android-bot-interactions
contracts: [P05, P06, P09, P18, P26, P27]
status: implemented
breaking: false
base: b01d626530
version_decision: reuse the existing settings keys, row intents, outbox v1 states and durable approval events
contract_revision: b01d626530 for host/v1 section 10, UI v1, Bot v1/v2 and gateway-security section 5.1
```

The Android host had no consumer for the information-page intents or card destinations, and no producer or user controls for lost sends. The ordinary network settings route admitted anonymous reads only. The iOS implementation, the existing shared fixtures and the registered contracts at the revision above own the semantics. No Worker change or migration is needed. Local settings and presentation changes apply to subsequent opens. Older apps can still read the same settings, grants, memory history and outbox entries.

- P09, P18, P26, P27. The Bot page reads the selected profile's real memory, routine, grant, approval and maintenance data. The host persists disturbance and maintenance preferences at their existing keys. A document card opens the workspace preview, a web link launches the system browser and a teammate action selects the corresponding roster entry. The dedicated Android P02 closed-session erasure writer is absent. Physical erasure reports that the data has been retained.
- P06. Before dispatch, the queue checks each target once per pass with the same empty historical page as iOS. Only an explicit Worker `session/not-found` moves a queued entry to `targetLost`. Errors of unknown outcome stay subject to authoritative read-back. The local DSH page shows entries from every lost session. Resend verifies the current session at action time and uses the store's fresh request identity and attachment verification. The commit-before-delete crash window remains tracked in GAP-51.
- P05, P26. An ordinary write needs both host admission and an independently attributed principal. Missing identity, ambiguous ownership and a Task missing its host-issued network-write capability produce a refusal before any approval or transport. The existing coordinator records a durable per-host/per-method decision. Android's buffered loopback does not carry client-disconnect notifications into the approver. It returns pending promptly. A newly authorized retry can consume a once grant once. Approved writes do not follow redirects or use the model endpoint's retry budget. Model, exact MCP, search and diagnostic routes retain their independent policies.
- P25: none — existing event producers and consumers use the same stored event shape and sequence domain. P08: none — link opening uses the platform browser. P16: none — the identity service uses the existing host-issued registrations and token generation.

Verification includes the P06 store and queue regressions, P05 route and Task-subset cases, real Android settings read-back, and a chat approval test with a counting upstream transport. Simulator comparisons used test Bot cards and local outbox entries. Pending entries came from the shared outbox format. The Android queue also converted never-submitted entries naming missing Worker sessions. On iOS, replayed persistent approval requests were answered in the product chat. The approve and deny decisions were checked in the domain event log. Device power loss, a live external write and background maintenance model execution were not tested.
