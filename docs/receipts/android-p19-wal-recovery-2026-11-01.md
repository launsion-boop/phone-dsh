# P19 — a 128 MiB workspace no longer bricks boot (WAL recovery)

Status: fixed and measured on a 2 GiB, API 35 arm64 emulator (`emulator-5582`,
`hw.ramSize=2048`, app heap growth limit 192 MiB / 201 326 592 B).

## Symptom

A contract-legal 128 MiB file in `/dsh/workspace` (the 8 GiB row of
`budgets.md` §4, written by the Worker as one complete write plus appended
suffixes of ≤ 15 MiB, `channel.md` §3.1) made **every** subsequent boot die in
recovery:

```
java.lang.OutOfMemoryError: Failed to allocate a 37748752 byte allocation
  with 25165824 free bytes and 34MB until OOM, target footprint 190723824,
  growth limit 201326592
    at java.util.Arrays.copyOf(Arrays.java:3585)
    at java.lang.AbstractStringBuilder.ensureCapacityInternal(AbstractStringBuilder.java:177)
    at java.lang.AbstractStringBuilder.append(AbstractStringBuilder.java:753)
    at java.lang.StringBuilder.append(StringBuilder.java:257)
    at com.phonedsh.agentcore.JsonParser.parseString(JsonValue.kt:209)
    at com.phonedsh.agentcore.JsonValue$Companion.parse(JsonValue.kt:21)
    at com.phonedsh.log.WalJson.parse(WalJson.kt:30)
    at com.phonedsh.log.WalScanner.records(RecoveryPlan.kt:156)      # removed
    at com.phonedsh.log.WorkspaceLog.readSegment$core(WorkspaceLog.kt:792)  # removed
    at com.phonedsh.log.WorkspaceLog.recoverLocked(WorkspaceLog.kt:467)
    at com.phonedsh.log.WorkspaceLog.recover(WorkspaceLog.kt:288)
    at com.phonedsh.log.WorkspaceLog(...) -> HostWal.recover -> PhoneDshHost.start boot job
```

The allocation that failed is a **36 MiB** `StringBuilder` for the `data_hex`
member of a 15 MiB record (hex is 2×, the builder doubles). The previous eight
records' decoded bodies (120 MiB) were still retained, which is why the ninth
one tipped over the 192 MiB heap after ~23 s of GC thrash.

## Root cause

All four P19 classes at once, in `WorkspaceLog.recoverLocked`:

| Class | Where | Cost |
|---|---|---|
| A. whole record/segment in memory | `Files.readAllBytes` in `scanWalDirectory` / `readSegment`, and `replay` holding every segment's `List<WalRecord>` | one segment (15 MiB) + **all mutation bodies** (128 MiB) retained |
| B. unbounded builder | `JsonParser.parseString` builds the `data_hex` string with a doubling `StringBuilder` (JsonValue.kt:209) | up to 2× the hex text = 4× the data for the largest string |
| C. parser copy | `NativeWal.records` returns hex JSON (2× data), `JsonValue.parse` copies it into a `JsonString`, `HexBytes.decode` copies it again into bytes | ~6× per record |
| D. missing record bound | `MutationBody.MAX_DATA_BYTES = Int.MAX_VALUE`; no per-record bound in recovery; `scanWalDirectory` read whatever size the file was | a single 128 MiB record was legal to write and impossible to recover |

Peak ≈ `Σ retained bodies` + `~6 × D_current` (D = one record's data). With
nine 15 MiB records that is `120 MiB + ~200 MiB ≈ 320 MiB`; a single 128 MiB
record needs `128 + 768 MiB` and can never fit any phone heap.

## Fix

1. **Streaming frame reader** (`WalSegmentReader`): recovery reads one frame at
   a time (`len | crc32c | mseq | body`), decodes it with the same
   `MutationBody.decodeBody` the write path inverts, and drops it after it is
   applied. No `data_hex`, no JSON tree, no `Files.readAllBytes` for records.
2. **Replay is a stream, not a list**: `replayInto` applies each mutation as it
   arrives, records only per-segment metadata, and keeps at most
   `WorkspaceLog.RETAINED_RECORD_BYTES` (4 MiB) of diagnostic bodies. Epoch
   closes are always retained because `HostWal` derives `durable_mseq` from
   them. `Recovered.recordCount` and the per-segment metadata are complete.
3. **Stale verification is streaming** (`MaterializedInvariant`): compares each
   record's bytes with the copy at the record's offset through one 64 KiB
   buffer instead of rebuilding the file with `bytes + body.data`.
4. **A record above the mutation bound fails loud**: `MutationBody.MAX_DATA_BYTES`
   is 15 MiB (`channel.md` §3.1/§6; `wal.md` §3 applies those invariants
   unchanged). The append path refuses a larger body with `BAD_PAYLOAD` and
   spends no mseq; recovery refuses a larger record with
   `WAL_RECORD_TOO_LARGE` **before allocating it** (frame length check, plus a
   segment-size guard before `readAllBytes`). The refusal reason is emitted as
   `WalLogEvent.RecoveryFailed` so the App logs and shows it.

Why not only (ii) "pre-allocate by the 15 MiB bound": that bounds one record but
not the *retained set*. A 128 MiB file is nine records, so the retained list was
still 128 MiB. Why not (iii) direct memory/mmap: the peak was the decoded
`List<WalRecord>` and the hex JSON, not the file read; streaming removes both
without a new allocation regime.

## Measurements (2 GiB AVD, before → after)

| | before | after |
|---|---|---|
| boot result on the 128 MiB fixture | `OutOfMemoryError`, process dead (2/2 launches) | `Recovered`, `next_mseq=10, acked_mseq=9, durable_mseq=9`, `wal/1: on` |
| peak Dalvik PSS | 165.1 MiB / heap size 192 MiB | 61.4 MiB / heap size 73.9 MiB (manifest present) |
| peak Dalvik PSS, full WAL rebuild | out of memory | 83.4 MiB / heap size 88.9 MiB |
| peak TOTAL PSS | 274.6 MiB | 169.9 / 186.4 MiB (WebView included) |
| recovery source | manifest + materialized copy | also proven from **WAL only** (no manifest, no copy): 128 MiB rebuilt, SHA-256 `3e9cb1eb…6ee1` on both sides |

The recovery target is `a + k·MB` = `3 + 0.05 × 128 = 9.4 s` (`budgets.md` §4);
the observed boot-to-HELLO was 6.7 s on the final build (process start
13:09:06.752 → `host ready` 13:09:13.408, full 128 MiB rebuild from the WAL
only).

## Contract gap (reported, spec is read-only)

- `wal.md` §3 encodes `data_len` as a `u32` and never states a maximum record
  size. The only explicit bound is `channel.md` §3.1 ("`op = 1` data is at most
  15 MiB") and §6 ("the host rejects a `data_len` above 15 MiB with
  `BAD_PAYLOAD`"). `wal.md` §3 says "the channel.md §3.1 invariants apply
  unchanged", which this implementation now takes literally. A single sentence
  in `wal.md` §3 fixing the record bound would remove the ambiguity; until then
  a direct (non-channel) WAL writer can produce a record the spec's `u32`
  allows and this host refuses.
- `budgets.md` §4 allows a 128 MiB single file at 8 GiB while the app process is
  capped at 230 MB. That is satisfiable only with streaming (this fix); a
  full-record decode is over budget by construction, not by device choice.
- Android does not select the `budgets.md` tier from `MemoryInfo.totalMem`
  today and `:dsh` still marks the host `single_file_limit` / `VFS_REFUSED`
  budget refusal "not-implemented", so a 2 GiB device can receive a 128 MiB
  file that its ≤ 3 GiB row (16 MiB single file) would not allow. Out of this
  lane's file scope; reported as an open question.

## Tests

- A `chain_error` from the kernel now marks the segment corrupt
  (`WalScanner.scan`), so the streaming replay cannot silently stop at an
  in-segment mseq hole; a hole is `WAL_CORRUPT` (`aHoleInsideOneSegment...`).
- `BigWorkspaceRecoveryTest`:
  - 128 MiB as one complete write + eight appended suffixes (15 MiB each):
    recovery keeps every byte (SHA-256), 10 verified records, 9 segments,
    `nextMseq = 10`, retained diagnostic bodies ≤ 4 MiB;
  - the same workspace recovered in a **child JVM with `-Xmx128m`** (the device
    condition as a test);
  - a forged 16 MiB record → `WAL_RECORD_TOO_LARGE` with the 15 MiB bound in
    the detail, not an OOM;
  - a declared 20 MiB frame in a small file → refused before the allocation;
  - `appendMutation` with 15 MiB + 1 → `BAD_PAYLOAD`, no mseq spent.
- Existing WAL suites (golden recovery, torn tails, stale segments, quota,
  zero-length segments) pass unchanged; `recordCount` is asserted against the
  golden vectors.
