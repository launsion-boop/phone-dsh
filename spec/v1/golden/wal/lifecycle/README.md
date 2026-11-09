<!-- SPDX-License-Identifier: MIT -->
# WAL segment lifecycle vectors — §7.2 placement, §9 droppable, §10 fast path

Status: normative fixtures. Each file is one boot shape: the durable manifest, the segment files
present in `wal/`, and the expected classification after recovery. They are the shared oracle for
the reading of [wal.md](../../../wal.md) §9 that a listed segment at or below
`last_durable_epoch` is durable even when it carries no close record of its own. The Python checker
recomputes the expected values; the Swift runner drives the real `RecoveryManager`, and the Rust
runner drives the real `pdsh-wal` recovery planner.

## File shape

```json
{
  "id": "unclosed-epoch-below-watermark",
  "title": "...",
  "manifest": { "format": 1, "boot_id": "...", "materialized_upto_mseq": 4,
                "last_mseq": 4, "last_durable_epoch": 217, "segments": [ ... ] },
  "segments": [
    { "file": "wal/00000215.000000.xlwal", "file_hex": "...",
      "first_mseq": 1, "last_mseq": 2, "has_epoch_close": false }
  ],
  "expected": {
    "fast_path": true,
    "verification_pass": false,
    "has_unclosed_history": false,
    "replay_records": 0,
    "materialized_upto_mseq": 4,
    "newest_close_segment": "wal/00000217.000000.xlwal",
    "dropped_segments": ["wal/00000215.000000.xlwal", "wal/00000216.000000.xlwal"],
    "retained_segments": ["wal/00000217.000000.xlwal"],
    "relisted_segments": [],
    "adopted_tail_segments": []
  }
}
```

`manifest` is a real §7 checkpoint (validated against `schema/manifest.schema.json`). `segments[]`
lists every present non-empty file with its full bytes; the checker decodes the 40-byte header,
every record CRC and the record order independently. A file present in `segments` but not in
`manifest.segments[]` is unlisted, exactly like the real crash window.

## Expected fields

| Field | Meaning |
|---|---|
| `fast_path` | the recovery does not run the full `checkAndRepair` pass: no unclosed history and no crash tail |
| `verification_pass` | the full materialized-copy verification runs (`!fast_path` in these vectors) |
| `has_unclosed_history` | a retained segment holds records and either is unlisted or has `epoch > last_durable_epoch`; a listed epoch at or below the marker is **not** unclosed history |
| `replay_records` | mutations above the manifest watermark that are replayed |
| `materialized_upto_mseq` | the strict contiguous watermark after recovery |
| `newest_close_segment` | the retained segment carrying the newest epoch-close record; never dropped |
| `dropped_segments` | segments unlinked after the shorter manifest is durable |
| `retained_segments` | non-empty files that stay (and are listed by the next manifest) |
| `relisted_segments` | retained files that were unlisted at boot (stale or adopted tail) |
| `adopted_tail_segments` | unlisted files with a mutation above the watermark |

Droppable means: listed in the boot manifest, `epoch <= last_durable_epoch`, every mutation in the
segment's own verified records at or below the **boot** manifest watermark, not the current open
segment and not the newest close segment. Recovery judges against the boot watermark so a segment
that contributed a replayed crash-tail record waits for the next manifest write. An unlisted
segment is replayed and **retained/re-listed**, never unlinked by the recovery that first sees it
(§7.2's G2-A09 rule); it may be dropped on a later boot once it is listed and every mutation is
below the durable watermark.

## Vectors

| File | What it proves |
|---|---|
| `unclosed-epoch-below-watermark` | a listed unclosed epoch at or below the durable marker is droppable; the fast path runs and the newest close segment stays |
| `unclosed-epoch-above-watermark` | the same shape with a mutation above the watermark is retained; the crash tail is replayed and verified |
| `crash-tail-epoch-above-durable` | a listed open epoch above `last_durable_epoch` is the real crash tail, not durable history |
| `unlisted-stale-relisted` | an unlisted segment with no new mutation is replayed, retained and re-listed, never unlinked by that recovery |
| `unlisted-adopted-tail` | an unlisted segment with a mutation above the watermark is adopted, replayed and re-listed |

## Validation

```sh
python3 spec/v1/tools/spec_golden.py --full
python3 -m unittest discover -s spec/v1/tools -p 'test_spec_golden.py' -v
swift test --disable-sandbox --filter RecoveryDurableEpochTruncationTests
cd shell && cargo test -p pdsh-wal --test lifecycle_golden
```
