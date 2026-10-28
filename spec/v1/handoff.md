# handoff.md — fence, handoff and reclaim (phone-dsh-v1, proto 1)

Status: normative. [budgets.md](budgets.md) fixes the host states that drive this file, [wal.md](wal.md) the WAL and materialized
copy, and [channel.md](channel.md) the FENCE frame, `mseq` and admission. Every `/v1/handoff/*` request is made by the phone to the
remote DSH host over TLS and carries the remote's Bearer credential (the credential of DSH Remote, never the model credential).
Binary integers are big-endian; JSON is canonical (channel.md §5).

## 1. Fence token and admission

The fence is `{owner, generation, wal_seq}` ([schema/fence.schema.json](schema/fence.schema.json)). `owner` is `phone` while the
phone holds execution authority and `remote` while the remote does; `generation` is monotonic and is the CAS value; `wal_seq` is the
VFS mseq through which the workspace is replicated — every mutation ≤ it is in the snapshot base or in the segments of §4. An
authority transfer adds one to `generation` and never lowers `wal_seq`.

Admission is closed at every authority change:

- the phone closes admission before any handoff preparation (`Running → HandingOff` or
  `Draining → HandingOff`), so no VFS_MUT, EXEC_REQ or JOURNAL is produced while a handoff is   prepared; once the remote's
generation is current, every phone side-effect frame is rejected   `FENCE_STALE` (channel.md §4.7);
- after a resume the phone keeps admission closed until the lease is verified in `Recovering`; only
  `Recovering → Running` opens it (budgets.md §1);
- the remote opens admission only when `applied_mseq == fence.wal_seq` (§4);
- after a successful reclaim the phone applies the returned segments, verifies that its applied mseq
  equals the returned `fence.wal_seq`, closes an epoch and enters `Recovering` with admission closed   until the lease is verified.

## 2. `POST /v1/handoff/fence` — generation CAS

Before this request the phone has closed admission and an epoch in the wal.md §5.2 order; `wal_seq`
is that epoch-close `durable_upto`, and no mutation exists above it.

Request: [schema/handoff-fence-request.schema.json](schema/handoff-fence-request.schema.json).

| Field | Type | Meaning |
|---|---|---|
| `expected_generation` | u64 | The phone's current generation; the CAS value. |
| `wal_seq` | u64 | Target WAL mseq this handoff must replicate. |

The remote compares `expected_generation` with its current generation and atomically installs `{owner:"remote", generation:
expected_generation + 1, wal_seq}`. It mints a fresh 128-bit `reclaim_token` (32 lowercase hex) bound to that generation. A mismatch
is `409` with `{"error":{"code":"fence_conflict", ...}}` and changes nothing.

Response: [schema/handoff-fence-response.schema.json](schema/handoff-fence-response.schema.json).

| Field | Type | Meaning |
|---|---|---|
| `fence` | object | `{owner:"remote", generation, wal_seq}` after the CAS. |
| `reclaim_token` | string | 32 lowercase hex; the only credential for §5. |

The phone keeps the token secret (never URL/log/channel/workspace/WAL) and stores it only through an explicit App-owned secure vault
(`HandoffReclaimTokenStore`, e.g. data-protection Keychain `ThisDeviceOnly` pinned with `kSecUseDataProtectionKeychain`); the in-process default is process-lifetime only.
A replacement updates an existing item in place (add only when absent, update again on a duplicate-add race), so a failed write never deletes the last token. The vault entry also carries the non-secret remote fence, endpoint and a workspace identifier (a hash of the canonical root).
A credential for another workspace or endpoint is refused before any request or segment apply; per-workspace vault accounts remain recommended because a shared account holds only the newest token.
If the replacement fails, the CAS-minted in-process credential wins over the stale vault value: only a strictly newer vault generation supersedes it, and a vault read failure falls back to the cached credential when one exists.
The handoff endpoint is `https` with a host and optional base path; URL userinfo, a query or a fragment is refused before any authority intent/request (the credential is `Authorization`).
Before the CAS the phone terminates the real page/Worker (`about:blank` navigation), shuts the engine bridge down (both hooks required) and waits for accepted inbound writes.
A missing hook, failure, caller cancellation or timeout sends no CAS and fails loud (`engineShutdownUnsupported`/`notQuiescent`), and a pre-request cancel clears the intent.
It then persists non-secret **authority-uncertain intent** (`handoff-intent.json`: `expected_generation`, `wal_seq`, endpoint, timestamp, optional `definite_rejection`; no token), which is not a fence.
Transport/`5xx`/`400`/malformed `2xx` leaves the unmarked intent: the remote may own generation + 1, so admission stays closed and a new process must not boot merely because `fence.json` says `phone`.
A definite pre-state rejection (`409 fence_conflict`, or `401`) rewrites the record with `definite_rejection: true`; the tokenless marker proves the remote changed nothing, so reset (also a fresh host after its D14 `hostFailed` start) removes it and boots, and a removal failure leaves it non-blocking with cleanup retried.
If that durable rewrite itself fails, the in-process definite outcome is retained and the stale unmarked intent is removed via that proof so the current process can reset;
if the cleanup also fails, reset reports the actionable storage error and a new process remains fail-closed on the unmarked file. Only an unmarked intent is unresolved authority.

The remote's authority record is provisioned when DSH Remote is paired (it copies the phone's current fence); a record provisioned
before any handoff is `{owner:"phone", generation:0, wal_seq:0}`, so the first handoff uses `expected_generation = 0`.

## 3. `POST /v1/handoff/snapshot` — full tree

The request body is a frame fixed by this section: `meta_len u32 | metadata JSON | payload`, with `1 ≤ meta_len ≤ 65536`. `payload`
is an **uncompressed** ustar archive of the materialized copy. The archive contains only `home/...` and `workspace/...` (no `tmp`,
WAL, manifest, `steps/` or `exec/`) and preserves permission bits. It is taken at `materialized_upto_mseq`: the WAL tail above that
base is not pre-applied, because it travels as segments in §4. Metadata schema:
[schema/handoff-snapshot-request.schema.json](schema/handoff-snapshot-request.schema.json).

| Field | Type | Meaning |
|---|---|---|
| `generation` | u64 | Must equal the generation installed by §2. |
| `materialized_upto_mseq` | u64 | Base: the snapshot's strictly contiguous watermark. |
| `wal_seq` | u64 | The fence target; must equal §2's `wal_seq`. |
| `payload_bytes` | u64 | Tar length; at most 272 MiB. |
| `payload_sha256` | string | Lowercase sha256 of the tar bytes. |

The remote verifies length and hash, unpacks into a fresh directory, exchanges it atomically and sets its applied mseq to
`materialized_upto_mseq`. Response: [schema/handoff-snapshot-response.schema.json](schema/handoff-snapshot-response.schema.json).

| Field | Type | Meaning |
|---|---|---|
| `materialized_upto_mseq` | u64 | The stored base (echo of the request). |
| `fence` | object | The installed fence; `fence.wal_seq` is the replication target. |
| `snapshot_sha256` | string | Hash of the stored tar. |

A retry of the same generation with the same hash is accepted and returns the same coordinates; a
different hash for that generation is `409 snapshot_conflict`.

## 4. `POST /v1/handoff/segments` — WAL tail

Same frame shape as §3; `payload` is an uncompressed ustar archive whose only entries are complete WAL
segment files named `wal/<epoch:08d>.<segment:06d>.xlwal`. Metadata schema:
[schema/handoff-segments-request.schema.json](schema/handoff-segments-request.schema.json).

| Field | Type | Meaning |
|---|---|---|
| `generation` | u64 | The generation installed by §2. |
| `base_mseq` | u64 | The snapshot base; segments must cover `(base_mseq, wal_seq]`. |
| `wal_seq` | u64 | The fence target. |
| `segments` | array | Ordered `{file, first_mseq, last_mseq, bytes}` descriptors. |
| `payload_bytes` | u64 | Tar length; at most 272 MiB. |
| `payload_sha256` | string | Lowercase sha256 of the tar bytes. |

A set is valid only when the mutation ranges of its segments, in ascending mseq order, are contiguous from `base_mseq + 1` to
`wal_seq`, with no gap and nothing above `wal_seq`; an empty set is legal only when `base_mseq == wal_seq`. A segment may begin at
or below the base; the remote skips every mutation with `mseq ≤ applied` (D15), so a straddling segment replays idempotently. `tmp`
is never sent, so the WAL has no holes. The remote validates every segment header and record CRC (wal.md §2, §3, §10), applies only
mutation records with the wal.md §6 rules in mseq order, and never applies an epoch-close record. A gap is `409 segments_gap`; a
corrupt segment or hash mismatch is `400`; nothing past the first gap is applied.

Response: [schema/handoff-segments-response.schema.json](schema/handoff-segments-response.schema.json).

| Field | Type | Meaning |
|---|---|---|
| `base_mseq` | u64 | The snapshot base. |
| `applied_mseq` | u64 | Highest contiguous applied mseq. |
| `wal_seq` | u64 | The fence target. |
| `admission` | string | `open` only when `applied_mseq == wal_seq`, else `closed`. |

The remote opens admission only on the `open` response; until then the phone stays `HandingOff`. Segments wholly at or below the
remote's applied mseq are accepted and skipped, so resending after a timeout is safe.

## 5. `POST /v1/handoff/reclaim` — return path

Request ([schema/handoff-reclaim-request.schema.json](schema/handoff-reclaim-request.schema.json)):
`{"reclaim_token": <32 lowercase hex>}`. No generation is required; the token alone authorises the
call. An unknown, expired or malformed token is `401` and changes no state.

On a valid token the remote:

1. closes admission and waits for in-flight work, aborting it after the 20 s drain deadline; 2. closes an epoch in the wal.md §5.2
order and freezes `wal_seq` = its highest mutation mseq; 3. returns the segments covering `(base_mseq, wal_seq]`, where `base_mseq`
is the phone watermark it    retained from §2/§4, in the same frame shape as §4; 4. installs `{owner:"phone", generation:
current_generation + 1, wal_seq}`: the returned `owner` is    the literal `phone` and the generation is the remote's current
generation + 1; 5. keeps admission closed and serves no new side effect.

Response metadata: [schema/handoff-reclaim-response.schema.json](schema/handoff-reclaim-response.schema.json).

| Field | Type | Meaning |
|---|---|---|
| `fence` | object | New authority: `{owner: phone, generation + 1, wal_seq}`. |
| `base_mseq` | u64 | Phone watermark; segments cover `(base_mseq, fence.wal_seq]`. |
| `segments` | array | Ordered `{file, first_mseq, last_mseq, bytes}` descriptors. |
| `payload_bytes` | u64 | Tar length. |
| `payload_sha256` | string | Lowercase sha256 of the tar bytes. |

Reclaim is idempotent: the remote caches the complete response per `reclaim_token` for 24 h and returns the cached bytes for a
repeat, even after the generation advanced. After the cache expires the token is invalid (`401`). The phone applies the returned
segments with the §4 applier rules, skips segments and mutations at or below its own applied mseq, sets `last_mseq = max(last_mseq,
fence.wal_seq)` (D17), closes an epoch, persists the fence and enters `Recovering`. It never reuses an mseq and opens admission only
after the lease is verified. The persisted fence is authoritative: the next host HELLO carries it and a later FENCE frame may repeat
it (channel.md §4.1, §4.7).

### Cold recovery after a process death

A new host/process has no in-memory `HandoffCoordinator` or token. It may reclaim only with verifiable evidence:

1. the persisted fence is remote and the token is loaded from the App secure vault; or 2. the §2 authority-uncertain intent exists
and the vault entry carries the non-secret remote fence    it was bound to (the token proves the CAS only after the remote returns
`200`; the phone records    the remote fence only after that proof).

The reclaim `200` is the proof of an uncertain CAS; the phone never guesses a generation. If an unmarked intent exists but no token is available, the host stays
**BLOCKED** in manual recovery: it returns a `manualReclaimRequired` error, clears no evidence and boots no local Worker. An App that already holds a token may use
the complete `reclaim(using:)` credential (token plus non-secret endpoint, workspace identifier and
CAS remote fence); a bare `reclaim(usingRemoteToken:)` is accepted only when the injected vault holds
that exact bound credential. Both check the binding before any request/apply and handle an interrupted
cleanup (`current.generation == intent.expected_generation + 2`) through the remote predecessor and
cached `200`, never a guessed generation. A marked definite rejection is not an uncertain CAS:
it is never used to derive a remote fence, and the normal start/reset path removes it before opening local admission. A successful reclaim removes the token
and clears the intent before `Recovering -> Running`. Before booting after a definite marker, the host
re-reads the intent after cleanup and fails closed if a concurrent host replaced it with an unmarked CAS.

Cold reclaim persists a bootable recovery state before it consumes the vault token or installs the reclaimed fence: `Remote` follows the D14 `reclaimRequested` edge to `Reclaiming`, and a persisted `HandingOff`/`Failed` controller (the normal mapping of a lost CAS response or interrupted handoff) follows the explicit `userReset` edge to `Recovering`. Neither transition opens admission: if the reclaim then fails, the unmarked intent or the persisted remote fence still keeps local start closed. If the process dies after the reclaimed phone fence was written but before the intent/token cleanup completed, the next attempt recognises `current.phone.generation == stored.remote_fence.generation + 1` from the remote's cached `200`, retries the idempotent fence install (clearing the stale intent), and does not advance the generation or replay old segments. At that installed generation the local `wal_seq` may legitimately exceed the stored CAS fence because the remote appended before reclaim (`current.wal_seq >= stored.remote_fence.wal_seq`); before install the direction is the reverse (`stored.remote_fence.wal_seq >= current.wal_seq`). Intent removal fsyncs the containing directory, and a persisted `Remote` controller with a phone fence and no unmarked intent is treated as a completed reclaim and booted through `Recovering`; an unresolved unmarked intent still keeps every local admission path closed.

## 6. Errors and limits

Every error is `{"error":{"code": ..., "message": ...}}` ([schema/handoff-error.schema.json](schema/handoff-error.schema.json));
`Cache-Control: no-store` is set on every response. `401` means a missing or invalid Bearer credential, or an invalid reclaim token;
`409` means a CAS, generation, snapshot or segment-coverage conflict; `400` means malformed metadata, length, hash or segment; `500`
is a remote failure (retry with backoff). A cleartext request, a redirect or a payload above 272 MiB is rejected without a state
change. The phone's handoff never sends `/dsh/tmp`, never compresses the tar, and never puts a local absolute path into a
descriptor.
