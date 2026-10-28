# wal.md — write-ahead log (phone-dsh-v1, proto 1)

Status: normative. The in-memory VFS of the worker is the single authority while it runs; the WAL is
the recovery log of every committed mutation, and the materialized copy is derived from it. Binary
integers are big-endian; CRC32C is Castagnoli as fixed by [README.md](README.md). Frame layouts are
those of [channel.md](channel.md).

## 1. Workspace layout and segment names

`Library/xl/<workspace_id>/` (`workspace_id` validated by D6 before use in a path):

| Path | Contents |
|---|---|
| `wal/<epoch:08d>.<segment:06d>.xlwal` | WAL segments |
| `materialized/home/`, `materialized/workspace/` | materialized copy; the only persistent VFS state besides the WAL |
| `materialized.staging/` | reconcile output, exchanged with `materialized/` |
| `reconcile.inprogress` | staged-reconcile marker |
| `recovery-backup/` | workspace-private preimage records for the scoped §7.2 local repair; never part of the VFS or boot overlay |
| `manifest.json` | checkpoint, §7 |
| `steps/` | exec step records, owned by the App ([exec.md](exec.md) §4) |
| `exec/` | exec idempotency ledger ([exec.md](exec.md) §2) |

Segment names are `wal/<epoch:08d>.<segment:06d>.xlwal`: decimal epoch and segment numbers,
zero-padded, epoch from 1, segment from 0 within its epoch. At the start of an epoch the host creates
segment 0; a segment rolls before a mutation that would exceed 8 MiB, and a record never spans
segments, so a record larger than 8 MiB occupies a segment alone. The epoch-close record (§4) is tiny
and is always appended to the current (last) segment without a roll, so a segment may contain only
that record — the idle-epoch case of `golden/wal/segment-epoch-only.json`; empty segments (header
only) are legal. A process never appends to a segment of an earlier boot. After recovery the next
epoch is `max(last_durable_epoch, highest epoch of any existing segment) + 1`, with segment 0.

## 2. Segment header (40 bytes)

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 8 | `magic` | bytes `XLWAL1\0\0` (`58 4c 57 41 4c 31 00 00`) |
| 8 | 2 | `format` | `u16 = 1` |
| 10 | 2 | `reserved` | `u16 = 0` |
| 12 | 8 | `first_mseq` | `u64` = `next_mseq` at segment creation |
| 20 | 16 | `boot_id` | 16 raw bytes; the same boot identity as HELLO, without the hex text form |
| 36 | 4 | `header_crc32c` | `u32` CRC32C over bytes 0–35 |

`first_mseq` is the mseq the first mutation of the segment will receive, i.e. `next_mseq` at
creation (§7.2). A new epoch after recovery sets it to the effective tail + 1 (§7.2); an idle epoch
keeps `first_mseq = durable_upto + 1` and writes only the close record. A header is written once;
only §10's torn-tail rule truncates.

Hand-computed header for `first_mseq = 1`, 16 zero `boot_id` bytes and `header_crc32c = 0x0B0F9536` (CRC input = bytes 0–35):

```
584c57414c310000000100000000000000000001000000000000000000000000000000000b0f9536
```

## 3. Records

```
len u32 | crc32c u32 | payload
payload = mseq u64 | body
```

| Field | Encoding |
|---|---|
| `len` | `u32` = 8 + `body length`; it covers `mseq` and `body` and excludes `len` and `crc32c` |
| `crc32c` | `u32` CRC32C over `mseq ‖ body` only (not over `len`) |
| `mseq` | `u64`; mutation records are `≥ 1`, consecutive, and equal to the record's VFS mseq |
| `body` | mutation body, identical to the `0x10` VFS_MUT payload **without** its leading `mseq` (channel.md §3.1) |

Mutation body: `op u8`, `mode u32`, `mflags u8`, `append_from u64`, `path_len u16`, `path`,
`data_len u32`, `data`. The channel.md §3.1 invariants apply unchanged: op 1 write, 2 mkdir,
3 remove, 4 chmod; `mode ≤ 0o7777`; only a write may set `mflags` bit 1 `appended`, and then `data`
is the suffix from `append_from`; mkdir/remove/chmod carry no data. Mutation records are append-only
and ordered by mseq with no holes across segments (§7.2). Only mutations and the §4 close exist.

## 4. Epoch-close record (D7)

| Field | Encoding |
|---|---|
| `op` | first body byte `u8 = 0xFF` |
| `wall_ms` | `u64`, Unix epoch milliseconds at close |
| `durable_upto` | `u64`, global maximum mutation mseq appended at the close (0 if none) |

The record's `mseq` field **is** `durable_upto`. It is not a mutation: it does not advance
`materialized_upto_mseq`, is skipped by materialization, and has no path. Because it describes the
whole WAL, its mseq may be smaller than the segment's `first_mseq`; the valid case is an idle epoch
(`first_mseq = durable_upto + 1`, §2, `golden/wal/segment-epoch-only.json`). A segment holds at most
one epoch-close record and it is its last record; after the close, the next mutation opens a new
epoch/segment.

## 5. Write path (D8)

For every accepted VFS_MUT the host order is fixed:

1. **Structural validation** — channel.md §8: path grammar and sink scope, expected `mseq`, length
   caps, op/mode/mflags/append_from consistency. Failure is `BAD_PATH`, `BAD_MSEQ` or `BAD_PAYLOAD`
   and closes the connection; nothing is appended.
2. **WAL append** — encode the record of §3 and append it to the current segment. The WAL records
   every mutation the VFS committed; materialization never suppresses or rewrites a record.
3. **Ack level 1** — send `VFS_ACK level 1` with the cumulative `upto_mseq` once `write()` of those
   bytes returned (group commit: at most 2 ms). Level 1 promises survival of **process death** (a
   kill or crash leaves the bytes in the kernel page cache). It does **not** promise survival of
   power loss; that is the level-2 epoch fsync of §5.2.
4. **Materialize** — apply to the copy of §6, in the same per-path order.

Materialization may lag behind append, but the watermark of §5.1 is solely a property of the
materialized copy. A materialization I/O failure is a host defect → state `Failed`, admission
closed; it is not a protocol error.

### 5.1 Base mismatch and repair (D8)

With `mflags` bit 1 (appended), the data is a suffix of the current file. When the base does not
match §6.2, and it is not the D9 skip case, the materialized copy and the WAL have diverged:

- send `0x13 VFS_RESYNC` for the path **at once**; at most one resync is outstanding per path.
- stop materialization of that path. Later mutations of other paths may still be applied, but
  `materialized_upto_mseq` is a **strictly contiguous watermark**: it does not advance past the
  first unapplied record, so it stays below the mismatching mseq until the repair is applied.
- keep the mismatching record and every later append of the path in the WAL. An accepted record is
  **never discarded** and never rewritten.
- the worker replies with a complete `op = 1` write (`mflags` bit 1 clear) of the current file at
  the **next normal mseq**; the worker's in-memory VFS is authoritative while it lives. The host
  applies that write as the new base, then re-applies the path's pending appended records in mseq
  order under §6.2 (skipping the bytes the complete write already contains) and settles them; only
  then does the watermark advance across every record it had held back.

No resync state is persisted in the manifest: `manifest.json` carries no per-path marker or
deferred list. After a boot, replay reaches the same unmaterializable record and requests the repair
again; after a live reconnect in the same process the host re-requests the path (channel.md §9). If
the repair has not arrived by the next epoch close (the Worker is dead or unresponsive), admission
closes and the state becomes `Failed`; a starting host then performs the full-tree reconcile of
§7.2. A path that is no longer a regular file is answered with `VFS_CONFLICT` (channel.md §10).
A materialization I/O failure is a host defect → `Failed`.

### 5.2 Epoch close (D18)

An epoch closes every 30–60 s, when the App enters the background, before a handoff and before a
planned WebContent restart. An unrepaired base mismatch at the close is a failure: admission closes
and the state becomes `Failed` (D8). Otherwise the close runs in this order:

1. **fsync the changed materialized copy**: every file materialized in the epoch (temp file fsynced
   before rename, or an fsync of the final file) and every changed directory (create, rename,
   remove, chmod, including the parent of a chmod), deepest first;
2. append the epoch-close record (§4) to the current segment, with `durable_upto` = highest mutation
   mseq appended so far;
3. `F_FULLFSYNC` every segment file written in this epoch, including the one that received the close
   record;
4. `fsync` the `wal/` directory;
5. atomically rewrite `manifest.json` (§7.1) with `last_mseq`, `last_durable_epoch`,
   `materialized_upto_mseq` and `segments`, and only then send `VFS_ACK level 2` for `durable_upto`.

Level 2 is emitted only here, after the materialized copy, the WAL and the manifest are all durable.
Compaction and truncation (§9) happen only after this order has completed (D18). A crash before
step 5 leaves the old manifest; replay from its watermark re-applies the durable prefix idempotently
(§6.2), so no level-2 state is lost or duplicated. An unlisted epoch-close segment is adopted by
§7.2 and the manifest repaired. Power loss loses at most the open epoch; the worker's memory is
gone then, so no side re-sends it, and the tool journal (channel.md §3.5, exec.md §4) shows.

## 6. Materialized copy (D8, D9)

`materialized/home/` and `materialized/workspace/` mirror `/dsh/home/**` and `/dsh/workspace/**`.
`/dsh/tmp/**` and every other root are never materialized. The copy is derived only from WAL
records; it is never the input to a WAL write and never edited by the worker.

### 6.1 Applying one mutation

| op | Rule |
|---|---|
| 1 write | write the full bytes to a temporary file in the target directory, set the mode, then `rename()` it over the target; create missing parents. A complete write always replaces the file; a crash leaves either the old or the new file, never a torn one |
| 1 write, appended | base check of §6.2, then append the suffix in place at `append_from` |
| 2 mkdir | create the directory (and missing parents) with `mode`; an existing directory is not an error |
| 3 remove | remove the file or the **whole directory subtree** at the path (the VFS collapses `rm -rf` into one remove); a missing path is a no-op (the tombstone replays idempotently). A rename appears as remove of the source plus `mkdir` for each moved directory and a complete `write` for each moved file |
| 4 chmod | set `mode` on the existing path; a missing path is a host defect → `Failed` |

The host removes a subtree under its own recursive delete, so no separate child removes are needed.

### 6.2 D9 idempotent appended replay

For an appended record with `append_from = A` and data length `L`, let `S` be the current size of the
materialized file:

- `S == A` → append the data (the record was not applied yet);
- `S >= A + L` and the bytes at `[A, A + L)` equal the record data → skip (already applied);
- anything else, including a missing file or a directory → base mismatch (§5.1).

The skip case makes consecutive appends replay-safe: base 6 bytes, append `A=6` of 6, then `A=12` of
6 — a 6-byte file appends both, an 18-byte file skips both, a 12-byte file skips the first and
appends the second. A later complete write replaces the file; §5.1 then settles its pending appends.

## 7. manifest.json (D11, D17)

JSON, UTF-8, validated by [schema/manifest.schema.json](schema/manifest.schema.json). Fields:

| Field | Type | Meaning |
|---|---|---|
| `format` | integer | 1 |
| `boot_id` | 32 lowercase hex | boot that wrote this manifest |
| `materialized_upto_mseq` | integer | highest mutation mseq such that every mutation ≤ it is applied to the materialized copy; a strictly contiguous watermark, 0 when none |
| `last_mseq` | integer | highest mseq ever allocated and accepted at level 1 (D17); it never decreases, truncation does not lower it; 0 when none |
| `last_durable_epoch` | integer | epoch number of the most recently closed (level-2 durable) epoch; 0 when no epoch has closed |
| `segments` | array | retained segments at the time of the write, in `<epoch,segment>` order |

`segments[]` entries are `{file, epoch, first_mseq, last_mseq}`: `file` is the relative segment name,
`first_mseq` equals the header's `first_mseq`, `last_mseq` is the highest mutation mseq in the segment
(0 when none). A manifest rewrite lists every segment that holds at least one record (a mutation or an
epoch-close record) at the time of the write, including an open-epoch segment that already received a
mutation. A header-only segment holds no record; it is legal on disk and is **not** listed. A listed
segment is therefore not necessarily epoch-closed: `last_durable_epoch` remains the sole marker of the
most recently closed (level-2 durable) epoch. A listed segment that is not epoch-closed is retained as
recorded; its epoch becomes durable only when a close record is present. Every present file that is not
listed is classified by §7.2. Neither the file nor the directory contains an absolute local path.

### 7.1 Atomic write

Write `manifest.json.tmp`, `fsync` it, `rename()` it over `manifest.json`, then `fsync` the
directory: a reader sees the old or the new file, never a mix. Rewrites happen at every epoch close,
during reconcile and before a segment is deleted, and only after §5.2 step 1 has made every applied
mutation durable. A manifest write records only the strictly contiguous watermark: it never names an
applied position that the materialized copy has not reached.

### 7.2 Ordering discipline and truncation

- **Manifest before deletion.** Delete a segment only after a durable manifest that no longer lists
  it (`fsync` file, rename, `fsync` directory); unlisted files left by a crash are placed below.
- **One segment-placement rule.** The manifest `segments[]` list serves truncation only: recovery
  scans the `wal/` directory. Every `wal/*.xlwal` present at recovery, listed or not, is parsed and
  placed in mseq order:
  - *listed and present*: used as recorded;
  - *listed and missing*: dropped silently only when all of its recorded mutations have
    `mseq <= materialized_upto_mseq`; otherwise `WAL_CORRUPT` → `Failed`;
  - *unlisted and no mutation above the watermark*: replayed as usual (its records are already
    applied, so replay is a no-op) and then **stale** — unless a newer epoch-close (filename epoch >
    `last_durable_epoch`) is adopted to repair the durable point, in which case it is retained and
    re-listed at the next manifest write; otherwise recovery unlinks it after the durable manifest
    and fsyncs `wal/`;
  - *unlisted with a mutation above the watermark*: **adopted tail**; its first mutation must equal
    the attested tail + 1, where the attested tail is `max(last_mseq, highest listed mutation mseq,
    materialized_upto_mseq)`, and recovery adds it to `segments[]` at the next manifest write and
    replays the tail (open epoch or close/manifest crash);
  - unlisted header/CRC failure, mseq hole, or a record above the watermark that cannot continue
    the attested tail: `WAL_CORRUPT` → `Failed`.
- **Tail below materialized.** After truncation the retained WAL tail may be **below**
  `materialized_upto_mseq`; that is legal. The effective tail is
  `max(last_mseq, highest mutation mseq in the retained WAL)`. Host HELLO carries `acked_mseq` =
  effective tail and `next_mseq` = `max(last_mseq, WAL tail) + 1` (D17); mseq is never reused.
- **Staged reconcile.** Reconcile runs only when the manifest and the WAL tail disagree, when the
  marker exists, when the manifest is missing/corrupt, or after a `Failed` close left an unrepaired
  base mismatch. Its inputs are the **materialized copy plus the WAL tail — never the WAL alone**.
  Steps: write `reconcile.inprogress` (with boot id, target tail and materialized position; fsync) →
  copy the materialized tree to `materialized.staging/` → replay the tail → fsync staging → exchange
  `materialized/` and `materialized.staging/` by rename → write the manifest with the effective tail
  → delete the marker; a boot that sees it redoes the reconcile.
- **Missing-manifest rule.** If `manifest.json` is missing, unreadable or schema-invalid: when the
  earliest retained segment has `first_mseq == 1`, rebuild from the empty tree by replaying the
  whole WAL and write a fresh manifest whose `last_mseq` is the WAL tail; else (a truncation must
  have happened) recovery is `Failed` and the worker must provide a fresh full snapshot before
  admission opens. With no manifest or WAL, the workspace is new (manifest at 0).
- **Materialized-copy invariant and scoped local repair.** Before a segment is unlinked, recovery
  compares every path whose last base mutation is retained against `materialized/` (bytes and POSIX
  mode). When the retained mutations start at `mseq` 1, a divergence rebuilds the whole copy from
  the WAL. When they start above 1, the copy is never rebuilt from an incomplete root. The only
  exception is a divergence confined to `/dsh/home/AGENTS.md` and
  `/dsh/home/capabilities.json` when every existing one of those two paths still has its complete
  full-write base and every global mutation mseq from that base through
  `materialized_upto_mseq` is retained with no hole: the divergent one(s) among those two files are
  rewritten in place to the WAL-derived bytes/mode. If either existing derived file cannot be proven,
  the whole local repair is refused rather than booting with one unproven metadata file. Their
  preimage (bytes, mode or recorded absence) is first made durable under the workspace-private
  `recovery-backup/` tree; a failed backup aborts before any overwrite. The WAL, mseq, manifest
  watermark, Session JSONL and every other materialized path are unchanged. Any other divergence, a
  missing base, a gap, a symlink/non-regular target or any path outside that two-path set remains
  `WAL_CORRUPT` → `Failed`. The repair does not infer content from the image or the filename.

## 8. Boot overlay

After recovery, reconcile and tail replay, the host packs the materialized tree as an **uncompressed**
ustar archive (the boot overlay) whose entries are only `home/...` and `workspace/...`; the loopback
service hands it to the worker at boot. It contains no `tmp`, WAL, manifest or step files; `/dsh/tmp`
is volatile and recreated empty. The overlay is rebuilt for each boot and is an input, not an authority.

Image shards `lazy/<sha256>.tar.gz` are produced by the packaging tooling, served with
`Cache-Control: no-store`, and fetched by the worker VFS on first read. They are never persisted by the
host and are not in the boot overlay; a mutation of a lazy-loaded path is an ordinary VFS_MUT once the
worker has the bytes.

## 9. Quotas and compaction

- The host WAL is limited to **256 MiB**, the sum of the segment files including headers. The
  response log (128 MiB) and the journal (64 MiB) follow the same rule — compact droppable data
  first, then fail loud — in their own components; budgets.md (W1) fixes their behaviour.
- A segment is **droppable** only when every mutation in it has `mseq <= materialized_upto_mseq` and
  its epoch is durable (closed in the D18 order, `F_FULLFSYNC`ed, listed). The newest epoch-close
  segment, the open epoch and any segment with a mutation above the watermark are never droppable.
- **Compaction** is truncation in the order of §7.2. It runs only after the D18 close order has
  completed, then fsyncs the materialized files and directories produced by the segments to be
  dropped, writes the shorter manifest, and unlinks whole segment files. A segment is never
  partially truncated except by the torn-tail rule of §10.
- If the WAL still exceeds 256 MiB after compaction, the host fails loud: admission closes and the
  state becomes `Failed`. Data is not silently evicted.

## 10. Recovery (D19)

1. Read the manifest; parse and place every segment — listed, missing or unlisted — by §7.2. A listed
   segment whose header magic, format, reserved, length or CRC is wrong follows the missing-segment
   rule using its recorded mseq range; an unlisted unreadable segment is `WAL_CORRUPT`.
2. Verify every record's `len` and `crc32c` in mseq order. A **torn tail** — an incomplete or
   mismatching `len`/`crc32c` with no complete record after it — is **truncated to the last complete
   record and the truncation is logged** (boot id, segment, byte offset, dropped bytes); it is not an
   error, because power loss may lose the open epoch. A CRC failure that is **not at the tail**, or an
   invalid record followed by a valid one, is `WAL_CORRUPT` → `Failed` with admission closed.
   Acknowledged level-1 records are never truncated.
3. Replay mutations with `mseq > materialized_upto_mseq` in ascending order using §6. A base
   mismatch joins §5.1: send `VFS_RESYNC` and hold the watermark below it; the repair write settles
   the deferred appends. Epoch-close records never advance the watermark.
4. If the manifest `boot_id` differs from the current process boot — every process start is a cold
   recovery — nothing in memory is trusted: the worker is seeded from the freshly packed overlay (§8)
   and any path still waiting for a resync is re-requested after HELLO. `durable_mseq` for HELLO is
   the largest `durable_upto` among valid retained epoch-close records (the newest is retained, §9),
   or 0.
5. A live WebSocket reconnect in the same process is not recovery: the WAL tail is in memory and
   channel.md §9 applies; no file changes.
