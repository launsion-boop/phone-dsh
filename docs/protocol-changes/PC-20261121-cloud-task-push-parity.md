# PC-20261121-cloud-task-push-parity

```yaml
change: PC-20261121-cloud-task-push-parity
contracts: [P05, P06, P08]
status: frozen
breaking: false
version_decision: cloud-tasks-v1.7 adds an FCM address only to Android registrations and a data-only wake envelope. Release the server first. Phones retry old servers with a null address.
base: 85caf8c071f7b5acfac09fc1496cf6b23d1ca441
contract_revision: spec/v1/cloud-tasks.md@cloud-tasks-v1.7
```

## Change

Android cloud task registration could only send a null address. iOS already
receives the APNs hint, but the deployed cloud repository had no phone-task
routes or dispatcher at cloud base `64a3d2098ca282ef16fc287fab96a979858fbd7a`.
Publish both ends of the existing queue with APNs and FCM adapters. The owning
contract is spec/v1/cloud-tasks.md, with the shared cases and Python oracle
imported together into phone-dsh-cloud.

The Android address has a closed provider and opaque token. FCM data members
are version and kind only. The authenticated queue, lease, expiry, encrypted
body and idempotent acknowledgments retain their previous encodings and
ordering. Provider failure preserves the queue. The callback may schedule
native admission before returning; it grants no measured engine window.

## Compatibility

Old clients can use the new server with the APNs or null address. An Android
client retries an old server's invalid-request registration with null once.
Without a configured or reachable push provider, normal pull continues.
Existing queue data needs no migration at the client. The previously missing
server queue requires new tables alongside the existing account tables.

## Ownership and verification

The coordinator owns the freeze, integrates the Swift registration codec,
Android token registration and native callback, and the cloud queue/migration
and provider senders. Acceptance covers the shared vector oracle, Swift and
Kotlin cloud-task tests, the service's offline checks, and real push delivery
with separately provisioned secrets and devices. For live rollout deploy the
server and configure provider credentials before advertising tested device
delivery.
