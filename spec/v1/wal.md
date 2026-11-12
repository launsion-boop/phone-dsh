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
| `blobs/sha256/<hh>/<sha256>` | content-addressed mutation payloads (§14); immutable, never part of the VFS |

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
| `body` | mutation body for `op` 1–4, identical to the `0x10` VFS_MUT payload **without** its leading `mseq` (channel.md §3.1); or the §14.2 blob-write body for `op = 0xFE`, which is not a VFS_MUT payload |

Mutation body: `op u8`, `mode u32`, `mflags u8`, `append_from u64`, `path_len u16`, `path`,
`data_len u32`, `data`. The channel.md §3.1 invariants apply unchanged: op 1 write, 2 mkdir,
3 remove, 4 chmod; `mode ≤ 0o7777`; only a write may set `mflags` bit 1 `appended`, and then `data`
is the suffix from `append_from`; mkdir/remove/chmod carry no data. Mutation records are append-only
and ordered by mseq with no holes across segments (§7.2). Three record kinds exist: a mutation, the
§4 close, and the §14 blob-write record (`op = 0xFE`) that carries a write's data by digest.

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
   every mutation the VFS committed; materialization never suppresses or rewrites a record. A write
   whose `data` is at or above the §14.2 threshold appends a blob-write record instead of an inline
   one, after its bytes are written to the §14.1 store; the rest of the order is unchanged and level
   1 covers both writes.
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
match §6.2, and it is not the D9 skip or superseded case, the materialized copy and the WAL have
diverged:

- send `0x13 VFS_RESYNC` for the path **at once**; at most one resync is outstanding per path.
- stop materialization of that path. Later mutations of other paths may still be applied, but
  `materialized_upto_mseq` is a **strictly contiguous watermark**: it does not advance past the
  first record that is neither applied nor settled, so it stays below the mismatching mseq until the
  repair is applied. A superseded record holds the watermark exactly like a mismatch until its
  covering record has been applied inside the prefix, but it is not a failure and needs no resync.
- keep the mismatching record and every later append of the path in the WAL. An accepted record is
  **never discarded by recovery** and never rewritten in place; §9 compaction and the §5.3
  closed-session rewrite may retire whole segments.
- the worker replies with a complete `op = 1` write (`mflags` bit 1 clear) of the current file at
  the **next normal mseq**; the worker's in-memory VFS is authoritative while it lives. The host
  applies that write as the new base, then re-applies the path's pending appended records in mseq
  order under §6.2 (skipping the bytes the complete write already contains) and settles them; only
  then does the watermark advance across every record it had held back.
- a complete write or remove of the path (or of an ancestor) that arrives after the mismatch and
  before the repair also settles every held append it covers under §6.2; no repair is needed for
  those records. Only the bytes a later record covers are let go: an uncovered mismatch stays held
  and still fails at the next epoch close, and a `VFS_CONFLICT` for a superseded path is not
  terminal (channel.md §10).

No resync state is persisted in the manifest: `manifest.json` carries no per-path marker or
deferred list. After a boot that leaves a resync, replay first performs the §7.2 materialized-copy
invariant: when the retained mutations start at mseq 1 and have no hole, a divergence rebuilds the
whole copy from the WAL; otherwise the host requests the repair after HELLO (channel.md §9, §10
step 4). After a live reconnect in the same process the host re-requests the path (channel.md §9).
If the repair has not arrived by the next epoch close (the Worker is dead or unresponsive),
admission closes and the state becomes `Failed`; a starting host then performs the full-tree
reconcile of §7.2. A path that is no longer a regular file is answered with `VFS_CONFLICT`
(channel.md §10), which is ignored only for a record superseded as above.

### 5.2 Epoch close (D18)

An epoch closes every 30–60 s, when the App enters the background, before a handoff and before a
planned WebContent restart. An unrepaired base mismatch at the close is a failure: admission closes,
the state becomes `Failed` (D8), and the recorded failure detail names the mismatch path and mseq.
Otherwise the close runs in this order:

1. **fsync the changed materialized copy**: every file materialized in the epoch (temp file fsynced
   before rename, or an fsync of the final file) and every changed directory (create, rename,
   remove, chmod, including the parent of a chmod), deepest first; every blob written in the epoch
   is fsynced here as well, before step 2, so a level-2 record never names a blob that is not
   durable;
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

### 5.3 Closed-session rewrite (session erasure)

A **closed session epoch** is a DSH session the Worker will never append to again: its last
turn has settled, it has been archived or detached, and the host has stopped admission. The
host may replace erased lines of that session's materialized JSONL log with tombstones. This
is the only exception to "committed events are never rewritten"; it is host-only and the
Worker never issues it. The rewrite runs in this order:

1. **Quiesce.** Park the Worker and wait until no append is in flight; close the current
   epoch in the §5.2 order. Require `materialized_upto_mseq` to equal the accepted tail.
2. **Fresh segment.** The rewrite starts with a complete `op = 1` write in the segment of
   the epoch opened by step 1. No earlier record may share that segment.
3. **Tombstone records.** Append ordinary mutations whose bytes are the rewritten log:
   every erased line is a tombstone record, every other line is byte-identical, and an
   older generation is an ordinary `op = 3` remove. A file larger than one mutation is one
   complete write plus §3 appended suffixes; the host never writes the erased bytes. A
   tombstone is a `phone-dsh/session-erasure` event with `ignorable: true`, its original
   `seq` and `time`, and no original content. A line carrying a copy of an erased user/assistant message (DSH `agent/inbox/spliced`) is also an erased line and becomes a tombstone; line-for-line replacement and order are unchanged.
4. **Durability and compaction.** Close the epoch in the §5.2 order, then compact every
   segment older than the rewrite segment under §9. Those segments are droppable: their
   mutations are at or below the watermark, their epochs are durable and listed, and they
   are neither the open epoch nor the newest epoch-close segment.
5. **Proof.** Before returning success the host rescans `wal/` and requires that no older
   segment remains; it also requires the rewritten files to match the materialized copy and
   removes every derived copy: `overlay-cache.tar`, `overlay-*.tar`, `materialized.staging/`,
   `recovery-backup/` and `materialized/home/storages/session_projcache/sessions/<sessionId>.json`
   (rebuilt on demand). A pending `reconcile.inprogress` refuses the rewrite.

Crash windows preserve one of two states. Before step 3 the old session is intact (the
operation has not happened). After the first tombstone record is durable, recovery replays
it over the old prefix and ends in the tombstone state; a crash between steps 4 and 5 leaves
the durable manifest listing the rewrite segment, and the next compaction completes. There
is no window that restores the erased bytes after the operation returns success.

The rewrite adds no manifest field, changes `format` and never allocates an mseq twice.
`record://session/<sessionId>#<seq>` for a tombstoned seq is an erased record: readers must
report `record_erased` and must not return the tombstone's data as the original line. DSH
admits an unknown `ignorable` event and excludes it from the surface, so the closed session
stays loadable; `session/list` may still show it as archived. The guarantee is bounded to
host-accessible copies. Secure erase of filesystem blocks, snapshots, device backups and
flash wear-levelling is not promised.

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
| 0xFE blob write | the §6.1 rule of the write form it carries (`appended` clear = complete write, set = append at `append_from`), with the verified blob bytes as `data`; a missing or digest-mismatched blob is `WAL_CORRUPT` (§14.5) |

### 6.2 D9 idempotent appended replay

Before the base check, an appended record is **superseded** when a later retained record with a
greater mseq is a complete write of the same path (`op = 1`, `appended` clear; a shorter write
truncates the file), a remove of that path, or a remove of one of its ancestors, and no appended
record of the path between the two depends on this record's base unless it is also covered by that
same later record (a complete write or remove covers every earlier record of the path). A superseded
record is not applied and the later record establishes the final state. It is settled only once that
covering record has been applied to the materialized copy; until then it holds the contiguous
watermark below it exactly like a held append but triggers neither `Failed` nor a resync, and only
once the cover is applied and the contiguous prefix reaches the cover's mseq may the watermark pass
it. A repair write of §5.1 is such a complete write.

For an appended record that is not superseded, with `append_from = A` and data length `L`, let `S`
be the current size of the materialized file:

- `S == A` → append the data (the record was not applied yet);
- `S >= A + L` and the bytes at `[A, A + L)` equal the record data → skip (already applied);
- anything else, including a missing file or a directory → base mismatch (§5.1).

The skip case makes consecutive appends replay-safe: base 6 bytes, append `A=6` of 6, then `A=12` of
6 — a 6-byte file appends both, an 18-byte file skips both, a 12-byte file skips the first and
appends the second. A later complete write replaces the file; §5.1 then settles its pending appends.
A later complete write or remove also supersedes an earlier append under the first paragraph; only
the bytes it covers are let go, and an append it does not cover remains a base mismatch. Because
replay and materialization are in ascending mseq order, the cover's own mseq is the earliest point at
which the watermark may pass a superseded append.

## 7. manifest.json (D11, D17)

JSON, UTF-8, validated by [schema/manifest.schema.json](schema/manifest.schema.json). Fields:

| Field | Type | Meaning |
|---|---|---|
| `format` | integer | 1 |
| `boot_id` | 32 lowercase hex | boot that wrote this manifest |
| `materialized_upto_mseq` | integer | highest mutation mseq such that every mutation ≤ it is applied to the materialized copy, skipped idempotently, or settled-superseded by a later retained record whose cover is applied at or below this watermark; a strictly contiguous watermark, 0 when none |
| `last_mseq` | integer | highest mseq ever allocated and accepted at level 1 (D17); it never decreases, truncation does not lower it; 0 when none |
| `last_durable_epoch` | integer | epoch number of the most recently closed (level-2 durable) epoch; 0 when no epoch has closed |
| `segments` | array | retained segments at the time of the write, in `<epoch,segment>` order |

A settled record is counted only when its covering record has been applied to the copy. Every
manifest write therefore satisfies: if the watermark is at least a settled record's `mseq`, the
cover's `mseq` is at most the watermark. The field never crosses a settled record whose cover is
still above it.

`segments[]` entries are `{file, epoch, first_mseq, last_mseq}`: `file` is the relative segment name,
`first_mseq` equals the header's `first_mseq`, `last_mseq` is the highest mutation mseq in the segment
(0 when none). A manifest rewrite lists every segment that holds at least one record (a mutation or an
epoch-close record) at the time of the write, including an open-epoch segment that already received a
mutation. A header-only segment holds no record; it is legal on disk and is **not** listed. A
zero-length segment holds neither a header nor a record; §7.2 allows it to be dropped. A listed
segment is therefore not necessarily epoch-closed: `last_durable_epoch` remains the sole marker of the
most recently closed (level-2 durable) epoch. A listed segment that is not epoch-closed is retained as
recorded; its epoch becomes durable only when a close record is present. Every present file that is not
listed is classified by §7.2. Neither the file nor the directory contains an absolute local path.

### 7.1 Atomic write

Write `manifest.json.tmp`, `fsync` it, `rename()` it over `manifest.json`, then `fsync` the
directory: a reader sees the old or the new file, never a mix. Rewrites happen at every epoch close,
during reconcile and before a segment is deleted, and only after §5.2 step 1 has made every applied
mutation durable. A manifest write records only the strictly contiguous watermark: it never names an
applied position that the materialized copy has not reached, and it names a settled position only
when the covering record is retained **and has been applied at or below the recorded watermark**. A
settled record whose cover is still above the watermark is not yet named.

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
    applied, so replay is a no-op) and then **stale**. A stale segment is **retained and re-listed**
    at the next manifest write, and the materialized copy is verified against it; recovery MUST NOT
    unlink it. Unlinking a stale segment is what silently lost the G2-A09 class of acknowledged
    writes — the manifest had lagged, the records were real, and the unlisted segment was the only
    surviving history. A newer epoch-close (filename epoch > `last_durable_epoch`) is retained and
    adopted on the same rules;
  - *unlisted with a mutation above the watermark*: **adopted tail**; its first mutation must equal
    the attested tail + 1, where the attested tail is `max(last_mseq, highest listed mutation mseq,
    materialized_upto_mseq)`; later segments of the same epoch must continue it (only the first is
    bounded by `materialized_upto_mseq + 1`), and recovery re-lists and replays the whole tail;
  - unlisted header/CRC failure, mseq hole, or a record above the watermark that cannot continue
    the attested tail: `WAL_CORRUPT` → `Failed`.
- **Zero-length segment.** A `wal/*.xlwal` of length 0 has no header and no record. Unlisted,
  recovery **drops it** after the manifest that omits it is durable and logs
  `WAL_EMPTY_SEGMENT_DROPPED segment=<n>` (`<n>` = the segment file name); it is never
  `WAL_CORRUPT`. Listed, its recorded mutations are gone and the listed-and-missing rule above
  applies: dropped only when every recorded mutation has `mseq <= materialized_upto_mseq`, otherwise
  `WAL_CORRUPT`. A non-zero segment whose header magic, format, reserved, length or CRC is wrong is
  **not** this case: its header may have been overwritten, so `WAL_CORRUPT` stands.
- **Tail below materialized.** After truncation the retained WAL tail may be **below**
  `materialized_upto_mseq`; that is legal. The effective tail is
  `max(last_mseq, highest mutation mseq in the retained WAL)`. Host HELLO carries `acked_mseq` =
  effective tail and `next_mseq` = `max(last_mseq, WAL tail) + 1` (D17); mseq is never reused.
- **Host-side writes.** An App-lane write (`appendMutation`, not a `VFS_MUT`) advances this allocator
  like any record: `next_mseq` is read from the log when a HELLO is sent and when the sink checks a
  frame (never cached from recovery), and a Worker frame at that number is `BAD_MSEQ` (channel.md §8).
- **Manifest range versus file range.** A segment file may hold fewer records than `segments[]`
  records for it only when all three hold: it is the newest segment, recovery truncated it under
  D19, and the recorded range lies at or below `materialized_upto_mseq`. A short file in any other
  position means records above the watermark are gone: `WAL_CORRUPT` → `Failed`.
- **Staged reconcile.** Reconcile runs only on a §10 damage condition: the marker exists, the
  manifest is missing/corrupt, a **listed** segment is missing above the watermark, or a `Failed`
  close left an unrepaired base mismatch. A manifest that merely trails the WAL tail is **not** a
  trigger — that is the ordinary crash-before-manifest case, repaired by replaying the tail onto
  the materialized copy and verifying it. Reading this rule as "any disagreement" turns every
  unclean shutdown into a full staging copy for a case the tail replay already handles.
  Its inputs are the **materialized copy plus the WAL tail — never the WAL alone**; the mseq-1
  rebuild of the next bullet is the invariant check, not staged reconcile, and may use the WAL alone.
  Steps: write `reconcile.inprogress` (with boot id, target tail and materialized position; fsync) →
  copy the materialized tree to `materialized.staging/` → replay the tail → fsync staging → exchange
  `materialized/` and `materialized.staging/` by rename → write the manifest with the effective tail
  → delete the marker; a boot that sees it redoes the reconcile.
- **Missing-manifest rule.** If `manifest.json` is missing, unreadable or schema-invalid — and
  "schema-invalid" here means a **required member is missing or a known member is out of range**,
  never "an unknown member appeared", which README §2 requires a decoder to ignore —: when the
  earliest retained segment has `first_mseq == 1`, rebuild from the empty tree by replaying the
  whole WAL and write a fresh manifest whose `last_mseq` is the WAL tail; else (a truncation must
  have happened) recovery is `Failed` and the worker must provide a fresh full snapshot before
  admission opens. With no manifest or WAL, the workspace is new (manifest at 0).
- **Materialized-copy invariant and scoped local repair.** Before a segment is unlinked, recovery
  compares every path whose last base mutation is retained against `materialized/` (bytes and POSIX
  mode). When the retained mutations start at `mseq` 1 and are contiguous with no hole, a divergence
  rebuilds the whole copy from the WAL; this is the rebuild a boot performs when replay leaves a
  resync, before it would otherwise request a repair after HELLO. When they start above 1, the copy
  is never rebuilt from an incomplete root. The only
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

After recovery, reconcile and tail replay, the host packs the materialized tree as a **ustar archive**
(the boot overlay) whose entries are only `home/...` and `workspace/...`; the loopback service hands it
to the worker at boot. The archive **format** is plain ustar; the **transport envelope** is a single
gzip member around it (`1f 8b …`), because the pinned runtime's `readImage` accepts only gzip bodies and
the overlay shares that reader with the image shards. Sending a bare ustar is not "tolerated" — it fails
to boot. This has no unpacking consequence: both the packer and the loader admit only `home/` and
`workspace/` as a first segment and refuse symlinks and special files outright, so the envelope changes
neither the entry set nor the traversal rules. It contains no `tmp`, WAL, manifest or step files; `/dsh/tmp`
is volatile and recreated empty. The overlay is rebuilt for each boot and is an input, not an authority.

Image shards `lazy/<sha256>.tar.gz` are produced by the packaging tooling and fetched by the worker
VFS on first read. They are never persisted by the host and are not in the boot overlay; a mutation of
a lazy-loaded path is an ordinary VFS_MUT once the worker has the bytes.

**Cacheability of immutable resources.** Only content-addressed resources may leave the `no-store`
rule: `/image/lazy/<sha256>.tar.gz` and `/blobs/sha256/<hash>` (the §14 store and the §8.1 target
overlay). They are served as `Cache-Control: private, max-age=31536000, immutable`; the version key is
the sha256 in the path, so their URL carries no per-launch token (they authenticate with the
same-origin launch cookie or a bearer header) and they never send `Vary: Cookie`. Every other route —
the page, `/static/*`, `/image/base`, `/image/overlay/*`, `/channel`, `/v1/*` and `/mcp*` — stays
`no-store`. A cache hit needs a stable origin: the loopback host and port are fixed for the
installation, with an ephemeral port as the fallback when the fixed port cannot be bound; the fallback
is a cache miss, never a correctness or security change, and the per-launch token remains required on
every request. A fixed origin is still bound to `127.0.0.1` only and keeps the same `Origin`, cookie
and main-frame checks; making the port predictable changes discoverability, not authorization. The
cache holds only immutable build assets, never user, model or session data. At
budgets.md §9 level 2 and above the host serves even these two routes with `no-store` (the "stop
creating new caches" action); entries the platform already stored are outside the app's accounting and
are reclaimed by the operating system.

### 8.1 Overlay manifest (W6, `target`)

Status: `target`; **not callable**. The archive above remains the only boot overlay until the pinned
runtime can read a manifest. `readImage` lives in the pinned DSH checkout, not in this repository, and
the repository may not patch it (AGENTS.md §6); a host that sent a manifest today would fail the boot.

The target replaces the per-boot archive with a host-generated manifest served at
`/image/overlay/<boot_id>.json`:

```json
{"format":1,"boot_id":"<32 hex>","materialized_upto_mseq":42,
 "entries":[{"path":"home/AGENTS.md","sha256":"<64 hex>","mode":420,"size":1024}],
 "tombstones":["workspace/old.txt"]}
```

`entries` are `home/...` and `workspace/...` only, never symlinks or special files, and `sha256` is the
§14.1 digest of the file's bytes; `tombstones` exists only if the runtime can delete a path inherited
from an earlier layer, and is empty otherwise. The worker fetches `/blobs/sha256/<hash>` on the first
read and caches nothing itself. Regardless of when this becomes callable, these invariants hold: the
in-memory VFS is still the runtime authority and a mutation is an ordinary VFS_MUT once the bytes are
present; `VFS_RESYNC` is unchanged because the host's materialized copy is still the replay source; the
quota counts each blob once; a missing or digest-mismatched blob fails the boot loudly and is never a
silently empty file. The one-time manifest build is background and re-entrant, and W1's read-only
projection serves browsing while it runs. Open question Q1 (owner) and GAP-41 track the upstream
reader; until it exists, recovery time stays O(materialized bytes) because every boot repacks the
overlay once per changed watermark.

## 9. Quotas and compaction

- The host WAL is limited to **512 MiB**, the sum of the segment files including headers and, since
  §14, every *live* blob file (one that a retained record references); an orphan blob is not
  counted and is reclaimed by the §14.5 pass. The response log (128 MiB) and the journal (64 MiB)
  follow the same rule — compact droppable data
  first, then fail loud — in their own components; budgets.md (W1) fixes their behaviour.
- A segment is **droppable** only when every mutation in it has `mseq <= materialized_upto_mseq` and
  its epoch is durable (closed in the D18 order, `F_FULLFSYNC`ed, listed). The newest epoch-close
  segment, the open epoch and any segment with a mutation above the watermark are never droppable.
- **Compaction** is truncation in the order of §7.2. It runs only after the D18 close order has
  completed, then fsyncs the materialized files and directories produced by the segments to be
  dropped, writes the shorter manifest, and unlinks whole segment files. A segment is never
  partially truncated except by the torn-tail rule of §10.
- A **closed-session rewrite** (§5.3) closes a fresh epoch and then compacts: every segment older
  than its rewrite segment is droppable under this section, including segments whose records
  predate the rewrite. The rewrite segment is the newest epoch-close segment and is retained.
- If the WAL still exceeds 512 MiB after compaction, the host fails loud: admission closes and the
  state becomes `Failed`. Data is not silently evicted.

**Readings the wording leaves open, decided here** (a port stopped on each of these):

- "runs only after the D18 close order has completed" applies **per segment that is dropped**, not to
  the whole log: a segment may be dropped while another epoch is still open, provided that segment's
  own epoch is durable and listed. §7.1 already allows rewriting `manifest.json` "before a segment is
  deleted", and §7 allows listing an open epoch's segments — so a global "only at an epoch boundary"
  reading would contradict both.
- "the newest epoch-close segment" means the segment holding the newest close record among the
  segments that stay. Because it is never dropped, it is always the close segment of
  `last_durable_epoch`.
- "its epoch is durable (closed in the D18 order, `F_FULLFSYNC`ed, listed)" is proven by
  `last_durable_epoch` plus `segments[]` in the manifest — §7 calls `last_durable_epoch` the one
  marker D18 step 5 writes. Keeping the newest close record readable is a backstop, not a second
  requirement. A listed segment whose epoch is at or below `last_durable_epoch` is therefore
  durable even when it has no close record of its own (or that record is no longer retained), and
  it is droppable when every other condition of this section holds. It is not "unclosed history"
  for §10's recovery fast path; only an epoch above `last_durable_epoch`, or a retained unlisted
  segment that holds records, is.
- For a path the epoch removed, there is no file to fsync: fsync its **parent directory**, the same
  rule D18 step 1 uses for removes.
- The close record itself is **not** charged against the limit before it is written. Refusing to close
  an epoch to save 33 bytes would trade the D18 order for a byte count, which is the wrong trade; the
  next append enforces the limit instead.
- "Compact droppable data first" means **drop oldest first and stop as soon as
  `used + reserve <= limit`**.
- The 512 MiB limit is **per workspace log** (one `manifest.json`), not a sum over every workspace on
  the host.
## 10. Recovery (D19)

1. Read the manifest; parse and place every segment — listed, missing or unlisted — by §7.2.
   Classify each present file by its own bytes before applying the placement rule: **length 0** is
   §7.2's zero-length case (no header, no record; dropped and logged, never `WAL_CORRUPT`); **a
   complete 40-byte header whose record region fails only at the tail** is step 2's torn tail; **a
   non-zero file whose header magic, format, reserved, length or CRC is wrong** is header damage. A
   listed segment with header damage follows the missing-segment rule using its recorded mseq range;
   an unlisted one is `WAL_CORRUPT`.
2. Verify every record's `len` and `crc32c` in mseq order. A **torn tail** — an incomplete or
   mismatching `len`/`crc32c` with no complete record after it — is **truncated to the last complete
   record and the truncation is logged** (boot id, segment, byte offset, dropped bytes); it is not an
   error, because power loss may lose the open epoch. A legal record cut short whose declared length
   agrees with its body header is a torn tail regardless of size; for it, a tail-search work budget
   is not evidence of a record after it. A CRC failure that is **not at the tail**, or an
   invalid record followed by a valid one, is `WAL_CORRUPT` → `Failed` with admission closed.
   Acknowledged level-1 records are never truncated. A blob-write record is not decoded further here:
its digest and length are checked when it is replayed (§14.5).
3. Replay mutations with `mseq > materialized_upto_mseq` in ascending order using §6. A base
   mismatch joins §5.1: send `VFS_RESYNC` and hold the watermark below it; the repair write settles
   the deferred appends. A superseded append likewise holds the watermark below it until its cover
   is replayed and applied, but that is not a failure. Epoch-close records never advance the
   watermark.
4. If the manifest `boot_id` differs from the current process boot — every process start is a cold
   recovery — nothing in memory is trusted: the worker is seeded from the freshly packed overlay (§8)
   and any path still waiting for a resync is re-requested after HELLO. `durable_mseq` for HELLO is
   the largest `durable_upto` among valid retained epoch-close records (the newest is retained, §9),
   or 0.
5. A live WebSocket reconnect in the same process is not recovery: the WAL tail is in memory and
   channel.md §9 applies; no file changes.

## 11. Read-only projection of `materialized/home/sessions` (P02/P18, W1)

The worker's in-memory VFS remains the single authority (§6). This section registers the one
exception the app's browse path needs: a **read-only projection** of the materialized session
copies. It is a view of §6's copy, not a second authority.

- **Who may read.** Only the App process: the UI/model layer that lists sessions, opens any
  session and pages backwards (the `ProbeKit/Transcript` reader), and the existing Bot
  `phone record` path of bot/v1 §4.4. The worker, a device, a remote host and an arbitrary
  process never read it through this exception.
- **What may be read.** `materialized/home/sessions/**` only. The reader opens files read-only
  (`O_RDONLY`/equivalent), never holds a write handle, and performs no create, write, append,
  truncate, delete, move, rename, chmod or metadata rewrite anywhere under `materialized/`.
  `materialized/workspace/**` and every other tree are outside this exception.
- **Freshness.** The projection is the state of the materialized copy, so it may lag the WAL and
  the worker's memory by up to the open epoch plus the materialization lag. It is a snapshot for
  display and paging only: it never decides whether a turn is running, whether a send is
  admitted, whether a step is finished, or which session is the active engine session. A line
  that is not complete (a torn final line) is ignored; a file renamed or removed by the host
  may make an open fail, and the reader then retries or falls back to the engine. The reader never
  repairs, reconciles or "fixes" a file.
- **Alignment.** Once the engine is ready, the reader aligns incrementally with the existing
  `session/list` and `session/page` RPCs and the engine wins on any disagreement. An engine that
  is `starting`, `failed` or absent does not block the projection; the UI may show the projected
  copy until the engine answers.
- **Not an input.** A write path may not read this projection to reconstruct a VFS mutation,
  a WAL record or a journal decision. The projection is not a replay source and is not hashed
  into any durable marker.

## 12. Reclaiming droppable data (P02, W3)

§9 defines which segment is droppable and the decided readings fix the conditions. This section
fixes **when** the reclamation runs; it does not widen any condition.

- **Every successful epoch close.** After the D18 order of §5.2 has completed (manifest durable,
  level-2 ACK emitted), the host reclaims every segment that is droppable under §9: all mutations
  `mseq <= materialized_upto_mseq`, the segment's epoch at or below `last_durable_epoch` and listed
  in `segments[]`, and not the newest epoch-close segment or the open epoch. Reclaiming is not
  limited to the quota path; the 512 MiB limit remains the fail-loud backstop, not the trigger.
- **Order.** Drop oldest first and stop as soon as `used + reserve <= limit` is no longer needed
  for quota; on the epoch-close path, drop all currently droppable segments. Manifest first, then
  unlink (§7.2), fsync the materialized files and directories the dropped segments produced
  (§9), and keep the newest close record.
- **Crash.** A kill between the level-2 ACK and the reclaim leaves droppable segments on disk;
  the next boot reclassifies them by §7.2 and reclaims them again. No acknowledged mutation and
  no durable state is lost. A kill between the shorter manifest and the unlink leaves an unlisted
  segment, which §7.2 replays as stale and re-lists, never drops silently.
- **Idle close.** An epoch close that made no new mutation durable has nothing to reclaim; the
  host may skip the close entirely under §13. Skipping is not a failure and does not lower
  `last_durable_epoch`.
- **Blobs.** The same pass runs the §14.5 GC: after the shorter manifest is durable and the
  referencing segments are unlinked, every blob that no retained record references is deleted.
- The response-log body deletion trigger at the same epoch-close point is fixed by
  [gateway-security.md](gateway-security.md) §11; this section only fixes the WAL segment timing.
- The absolute WAL quota is unchanged at 512 MiB (§9).

## 13. Materialized watermark and idle epochs (P02/P03, W4)

**Watermark timing.** Advancing `materialized_upto_mseq` in `manifest.json` only at epoch close
**is compliant** with §7.1 and D18, and is the required write-path behaviour:

- §7.1 requires a manifest rewrite at every epoch close, during reconcile and before a segment is
  deleted, and requires §5.2 step 1 to have made every applied mutation durable first. It does not
  require a manifest rewrite per mutation; the field is a property of the materialized copy (§5),
  and §5.2 step 5 writes it after the copy is fsynced.
- The **in-memory** watermark still advances per applied record; the persisted value may lag until
  the next close. A crash replays every record above the persisted watermark with §6 idempotence
  (§6.2 apply/skip and §5.1 repair), so the lag is safe. A manifest write before step 1 would
  name an un-fsynced position and is forbidden.
- Consequence: a segment is not droppable until the close that persists a watermark covering it.
  This is exactly §9's "its epoch is durable" condition; advancing the manifest per mutation would
  not make the segment droppable any earlier.
- A host may still rewrite the manifest during reconcile and before a deletion; those writes carry
  the same contiguous watermark and the same "after §5.2 step 1" rule.
- **Contract conclusion.** "Only at epoch close" is allowed; a per-mutation `recordMaterializedUpto`
  rewrite is an implementation choice that the contract neither requires nor forbids, but it must
  not lower the durability order. The `WorkspaceLogService` per-change manifest rewrite is
  therefore an optimisation defect, not a contract violation.

**Idle epoch.** The periodic 30–60 s close may be skipped when, since the last successful close,
no mutation was appended, no new segment was created, no materialization is pending, and no
`VFS_RESYNC` is outstanding. The `durable_upto` of HELLO is the largest retained close record's
`durable_upto` (§10 step 4); skipping does not change it. A close that is required for a handoff,
a drain, a teardown seal or a planned restart still runs its §5.2 order when it has something to
make durable, and may use `sealEpochCoveringTail` where the existing rule requires recording the
current tail. Skipping an idle close performs no `F_FULLFSYNC`, writes no segment and sends no
level-2 ACK.

## 14. Single-copy blob store (P02/P03, W6)

This section adds a second storage form for mutation **data**. It does not change the wire
(channel.md §3.1 is byte-identical), the manifest schema, mseq, the ACK levels or the two durability
promises; it changes only what the host writes to disk for a write's bytes. Its limits are stated in
§14.4: a complete write becomes one physical copy through a clone, an appended chunk chain is one copy
only after compaction, and the §8 per-boot archive is untouched until §8.1.

### 14.1 Store layout and immutability

`Library/xl/<workspace_id>/blobs/sha256/<first two hex digits>/<sha256>`, mode `0600`, no extension.
Blobs are authoritative while a retained record references them: they are never moved to
`Library/Caches` and never written under `/dsh/tmp`. A blob is named by the lowercase SHA-256 of its
exact bytes and is **immutable**: never rewritten in
place, never truncated, never chmod-ed, and only ever renamed from a temporary file in the same shard
directory. A crash therefore leaves either no file or a complete one; a temporary name that never got
renamed is an orphan and is removed by §14.5. An existing blob is never overwritten: a second write of
the same bytes verifies its length (and, when this process did not create it in this boot, its
digest) and reuses it — that is the single-copy property.

### 14.2 Blob-write record (`op = 0xFE`)

A write whose `data` is at or above **65 536 bytes** is appended as this record; a smaller write stays
an inline §3 record. A reader accepts either form at any length. The threshold is a writer policy,
not a wire rule, and it keeps small metadata-heavy trees on the single-append path.

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 1 | `op` | `u8 = 0xFE` (write-by-reference) |
| 1 | 4 | `mode` | `u32`, permission bits `≤ 0o7777` |
| 5 | 1 | `mflags` | `u8`: bit0 `entryChanged`, bit1 `appended`; bits 2–7 are 0 |
| 6 | 8 | `append_from` | `u64`; 0 unless bit1 is set |
| 14 | 4 | `blob_len` | `u32`, the mutation's `data` length; `1 .. 15 MiB` |
| 18 | 32 | `blob_sha256` | SHA-256 of the `data` bytes |
| 50 | 2 | `path_len` | `u16` |
| 52 | `path_len` | `path` | UTF-8 absolute path, channel.md §6 |

The record's own `crc32c` covers `mseq ‖ body` exactly as §3 fixes. `blob_sha256` and `blob_len`
describe the mutation's `data`, not the whole file: for `appended` the blob is the suffix at
`append_from`, so a file larger than one mutation is a chain of blob records, one copy of each chunk.
mkdir/remove/chmod are never stored by reference and never carry a digest. There is no new `format`
value: the kind is self-describing, old inline records are read forever, and a decoder that does not
know `op = 0xFE` treats it as an unknown op and fails loudly (§3); it never applies a guessed record.

### 14.3 Write order

1. Structural validation (unchanged, §5 step 1).
2. Write the blob: temporary file in the shard directory, `write()` the data, rename to the final
   digest name.
3. Append the §14.2 record (or the inline record below the threshold).
4. Level-1 ACK once the record `write()` returns. The blob's `write()` returned before it, so both
   are in the kernel page cache: level 1 covers the pair exactly as it covered one inline record.
5. Materialize (§14.4).

At the epoch close, §5.2 step 1 fsyncs every blob written in the epoch **before** the close record of
step 2, so a durable record never names a blob that power loss could remove.

### 14.4 Materialized copy

A blob-backed write materializes exactly like its inline form, with the verified blob bytes as
`data`: a complete write uses the temp-then-rename rule of §6.1 (and may use an APFS `clonefile` of
the blob), an appended write uses the §6.2 base check and append. A clone is a copy-on-write
optimisation: the materialized file is an independent inode, later in-place appends and chmods affect
only it, and deleting the blob later leaves the file's blocks intact. **Hard links are forbidden** for
the materialized copy: a hard link shares the inode, so a later in-place append or chmod would mutate
the blob and corrupt every other reference. Where cloning is unavailable (Android, non-COW
filesystems) the host copies; that keeps the same bytes and modes but is a correctness fallback, not
a space win, and the implementation report must say so.

The single-copy claim is therefore exact only for a **complete** write, whose materialized file can be
the blob's clone: one physical copy, where the inline form held one in the WAL and one in the copy. A
file larger than one mutation is a chain of *appended* chunks, and a clone cannot name a byte range;
the host appends the blob bytes, so the file has the chunk blobs plus the materialized bytes until
those records are compacted, after which §14.5 deletes the blobs and the materialized file is the only
copy. Steady state is therefore the same single copy as before for such files; what W6 removes is the
inline WAL copy during the open epoch (smaller WAL append, faster scan, more quota headroom) and, for
repeated identical chunks, the duplicate itself. The per-boot overlay archive of §8 stays a transient
third copy until §8.1 is callable.

### 14.5 Recovery, reference and reclamation

- **Verify before apply.** A retained blob record is resolved in mseq order: the blob must exist with
  exactly `blob_len` bytes and the recorded digest. Anything else is `WAL_CORRUPT` → `Failed` with
  admission closed; unverified bytes are never applied and the materialized copy is not used as a
  fallback authority.
- **Live set.** After the §7.2 placement (listed, stale or adopted), the live set is the digest of
  every retained blob record. No manifest member and no separate reference-count file is added: the
  WAL is the single reference source, so a count cannot diverge from it.
- **GC.** After startup placement and after a close that dropped segments, delete every blob in the
  store that is not in the live set. Manifest-before-deletion (§7.2) applies: only after the manifest
  that no longer lists the referencing segment is durable may the blob be unlinked, and the shard
  directory is fsynced afterwards. A crash leaves an orphan for the next GC; it never leaves a
  referenced record without its blob (that is the fail-loud case above).
- **Startup safety.** The startup GC is read-only with respect to every authoritative store: it
  derives the live set from the WAL after placement and unlinks only files in `blobs/`. It does not
  need a VFS authority and does not conflict with a `Recovering` host.

### 14.6 Quota

§9's 512 MiB limit applies to the sum of WAL segment files and **live** blobs; orphan blobs are
excluded because they are reclaimed. If close + compaction + GC cannot bring the sum under the limit,
§9's fail-loud branch runs. The number does not change; only what it covers grows. budgets.md §9's
aggregate view counts the blob store once and the materialized copy once, so clone sharing makes that
sum an upper bound — the safe direction for a budget.

### 14.7 Handoff

The `/v1/handoff` wire and schemas are unchanged. A blob record never crosses the boundary. In the
phone→remote direction the snapshot is taken at `base_mseq == wal_seq`: the phone materializes the
retained tail and closes the epoch before packing, so §4's segment set is empty. If an implementation
needs a non-empty tail, it expands every blob record in the **transferred copy** to the pre-W6 inline
form with the same mseq (a transfer encoding; the local WAL is still never rewritten), so an old
remote sees only records it knows. The remote→phone set never carries a blob record; the phone refuses
such a set as corrupt because the referenced bytes are not in the transfer.

### 14.8 Migration: none is required, and why

No pre-W6 record is rewritten (§5.1). Old segments with inline records stay readable forever and old
materialized files are untouched until their path is written again. There is deliberately **no**
adoption of existing materialized bytes into the blob store: a blob that no retained record references
would need a second durable reference source (a clone ledger), whose crash consistency would duplicate
the WAL's discipline and whose divergence could delete a referenced blob. Dedupe therefore accrues as
writes arrive; the first rewrite of an old path already becomes one copy. The only one-time migration
in W6 is the §8.1 overlay manifest (`target`): built in the background, re-entrant, verified before
the old archive is retired, and W1's read-only projection serves browsing while it runs.
