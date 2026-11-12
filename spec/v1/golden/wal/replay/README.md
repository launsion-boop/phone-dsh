<!-- SPDX-License-Identifier: MIT -->
# WAL replay semantics vectors — D9 superseded and recovery rebuild

Status: normative fixtures. Each file is one replay case: an initial materialized copy, the
manifest watermark, the retained mutation sequence and the expected per-record verdict, final
watermark, optional per-step watermarks, final tree and Failed outcome. The vectors are the oracle
for [wal.md](../../../wal.md) §5.1, §6.2, §7.2 and §10; they are judged by `spec_golden.py`, and the
Swift and Kotlin implementers must drive their real recovery code (`Materializer`, `WorkspaceLog`,
`RecoveryManager`) with these files, not with a hand-written copy of the rules.

The file shape is fixed by [wal-replay.schema.json](../../../schema/wal-replay.schema.json).
Phone-only shapes that no non-phone host produces (the S6 closed-session rewrite) live in
[`replay-phone/`](../replay-phone/README.md) and use the same schema.

## 1. Input

- `materialized_upto_mseq` — the manifest watermark at boot. A retained mutation at or below it is
  `already-materialized` and is not replayed.
- `copy` — the materialized files at boot, as `path -> {content_utf8}` or `{content_hex}`. A path
  absent from the object is absent from the copy; directories are implicit.
- `records` — retained mutations in ascending, contiguous mseq order. A record is
  `mseq`, `op` (`1` write, `3` remove of the whole subtree), `path`, `appended`, and for a write
  `append_from` plus `data`. Epoch-close records are excluded because they never advance the
  watermark.

## 2. Expected result

- `records` — one verdict per retained record, in input order:
  | Verdict | Meaning |
  |---|---|
  | `applied` | the record was applied during this replay |
  | `skipped-idempotent` | D9 skip: the bytes at `[append_from, append_from + data_len)` already equal the data |
  | `settled-superseded` | the fourth D9 verdict: a later retained complete write/remove covers this appended record, so it is not applied. It counts toward the watermark only once that covering record has been applied at or below the watermark |
  | `mismatch-held` | the base does not match and no later record covers it; the path is held and the host enters Failed |
  | `already-materialized` | `mseq <= materialized_upto_mseq`; the copy already owns the record and it is not replayed |

  For `settled-superseded`, `superseded_by_mseq` names the earliest later covering record and
  `cover` names its kind: `complete-write`, `truncate`, `remove`, `ancestor-remove` or `repair-write` (a repair write
  is a complete write delivered under §5.1).
- `materialized_upto_mseq` — the final watermark. It is strictly contiguous: it is the largest
  prefix in which every record is applied, skipped idempotently, already-materialized, or settled by
  a cover inside that prefix. A held mismatch or a settled record whose covering record is still
  above the prefix stops it; later records of other paths may still be applied.
- `watermark_steps` — optional checkpoints: after the record with that `mseq` is decided, the
  watermark must not exceed `materialized_upto_mseq`. Entries form a contiguous prefix of `records`,
  in order. The reference value is the highest legal watermark at that point; a runner may be lower
  if it deferred materialization, but a manifest that exceeds the step is invalid. On a
  `rebuilt_from_wal` vector the checkpoints describe the final rebuild and start at 0.
- `tree` — the final materialized files. A path absent from the object is absent.
- `failed` — true when at least one mismatch remains held after the final replay.
- `rebuilt_from_wal` — true when recovery performed the §7.2 invariant rebuild: retained mutations
  start at mseq 1 with no hole and the copy diverged, so the whole copy is rebuilt from the WAL.
  `records`, `tree`, watermark and `failed` then describe that rebuild, and `copy_replay` records
  the replay of the given copy that left the resync. A successful rebuild cannot stay Failed.

### 2.1 Conservative settlement and the watermark invariant

`settled-superseded` decides the record; it does not by itself let the watermark move. The
watermark is a claim about the materialized copy, and a settled record has not been applied. It
therefore blocks the contiguous watermark exactly like a held append until its covering record has
been applied and the prefix reaches it. Unlike a held append it does not cause Failed, does not
request `VFS_RESYNC`, and a `VFS_CONFLICT` for its path is ignored under wal.md §6.2/§10. Once the
cover is applied at its own mseq and the contiguous prefix reaches it, the watermark may pass the
settled record and the cover together. Every manifest write therefore satisfies: **if the watermark is at least a settled
record's `mseq`, the covering record's `mseq` is at most the watermark.**
`settled-watermark-waits-for-cover` encodes the check with `watermark_steps`. This is a runner
obligation, not only a fixture property: a runner that advances a manifest watermark past a settled
record before applying its cover is non-conformant even when its final tree is right.

## 3. Assertion algorithm

1. Replay the retained mutations with `mseq > materialized_upto_mseq` in ascending order.
2. Check supersession **before** the D9 base check. An appended record `m` on path P is superseded
   when a later retained record has a greater mseq and is a complete write of P, a remove of P, or a
   remove of an ancestor of P, provided every appended record of P between `m` and that cover depends
   on `m`'s base only when it is itself covered by the same record. A complete write or remove
   covers every earlier record of P, so an intervening append of P is covered by the same record;
   the boundary the rule really protects is an append that still assumes `m`'s base **after** the
   cover, which that cover does not include. `dependent-append-not-covered-stays-held` exercises
   that boundary.
3. For an appended record that is not superseded, apply the D9 rule: append when the current size
   equals `append_from`; skip when the size is at least `append_from + data_len` and the target
   range already equals the data; otherwise hold the path (`mismatch-held`).
4. Stop materializing a held path until a repair. Records of other paths may still be applied; the
   watermark never advances past an unresolved record, and step 5 adds that a settled record's
   cover must be inside the same prefix. The per-record verdicts are the rule's decision log:
   `applied` says the record is not held, while a runner may defer the physical write of a later
   other-path record while the watermark is blocked (wal.md §5.1 says "may still be applied"). The
   final tree, watermark and Failed flag remain the observable assertions.
5. **Watermark checkpoints.** After each record's verdict is decided, compute the highest legal
   watermark: a candidate is legal only when every record at or below it is applied, skipped
   idempotently, already-materialized, or settled by a cover whose `mseq` is also at or below the
   candidate. A settled record therefore cannot be passed until its cover is inside the prefix; a
   cover applied ahead of an unresolved intervening record does not unlock it. For every declared
   `watermark_steps` entry, the declared value must equal this reference value. The final watermark
   must satisfy the same invariant. `settled-watermark-waits-for-cover` is the positive case; the
   mutation suite raises one of its steps to prove the checker rejects the illegal pass.
6. If the replay leaves a resync and the retained mutations start at 1 with no hole, run the §7.2
   invariant and rebuild from the WAL. Otherwise the resync is not repaired and the result is Failed.

Only covered bytes are let go. An append that is not covered by a later complete write/remove is
still a base mismatch, even when the path was settled earlier or the later record targets another
path.

## 4. Vectors

| File | What it proves |
|---|---|
| `append-full-write-settles` | a later complete write of the same path settles the append |
| `append-truncate-settles` | the cover may be a shorter complete write (truncation) |
| `append-remove-settles` | a later remove of the same path settles the append |
| `append-ancestor-remove-settles` | a later remove of an ancestor settles the descendant append |
| `live-repair-write-settles` | the §5.1 repair write is itself a complete write and settles; a later append then applies |
| `recovery-rebuilds-from-wal` | a boot resync with retained mseq 1 rebuilds the copy from the WAL; the pre-rebuild copy replay is recorded in `copy_replay` |
| `append-already-applied-skips` | the D9 byte-range skip still exists when no cover applies |
| `intervening-append-covered-settles` | a dependent append between `m` and the cover is also covered by the same complete write and settles with `m` |
| `settled-watermark-waits-for-cover` | a settled record holds the watermark below it (0, 0) even while an unrelated path applies, then the watermark passes the settled record and its cover together (3); the `watermark_steps` oracle |
| `append-only-stays-held` | appends with no complete write/remove cover stay held and Failed |
| `cover-before-append-stays-held` | a complete write with a smaller mseq is not a later cover |
| `cover-other-path-stays-held` | a complete write of another path is not a cover |
| `dependent-append-not-covered-stays-held` | an append still depending on the old base is not covered by the same write and stays held |
| `retained-not-from-one-stays-failed` | retained mutations above mseq 1 are never rebuilt from an incomplete root |

## 5. Validation

```sh
python3 spec/v1/tools/spec_golden.py --full
python3 -m unittest discover -s spec/v1/tools -p 'test_spec_golden.py' -v
```

`spec_golden.py` validates the schema, recomputes every verdict, watermark, tree and Failed flag
from the input, and requires the vector set, all five verdicts, all five cover kinds, both Failed
and non-Failed outcomes, at least one `watermark_steps` checkpoint and at least one settled record
that holds the watermark before its cover. A runner that only re-asserts the stored JSON is not
conformance: it must feed `copy`, `materialized_upto_mseq` and `records` to the real recovery code
and compare the observable result, including the manifest watermark after each record.
