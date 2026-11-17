# PC-20261116-memory-evidence-length — memory write pre-write evidence length guard

- status: frozen
- base: `9a373adeac0e10f2d3b61c9136a70107778bbc5b`
- contract_revision: `5105355783858ce6c6a21508eb8b601f351f3d4e`（tree `db2f1e070bb3137cfd7686ef0e276f9f89a31b36`）
- owning: `spec/bot/v2/memory-write-result.schema.json` enum、`spec/bot/v2/README.md` §1.3/§1.5 addendum
- no request field/wire change; existing `limit`/`actual` reused.

## Delta

- New write-result code `memory-document-longer-than-evidence`.
- Only when `BotMemory` has a real `BotMemoryMaintenanceRecordReading`, the write carries evidence/review
  refs, and (`authorKind == .maintainer` or context trust == `observation`): content Unicode scalars >
  de-duplicated full canonical cited readable text scalars → reject before writing, return
  `{ok:false,code,error,limit,actual}`; no event/version. Same turn may retry shorter.
- Ordinary user write (trust user) and evidence-less trigger-only write untouched; no batch rollback
  relaxation, budget change, trust/fail-closed change.
- `BotRecordService.recordText` returns full canonical text for this check only; model-facing record
  commands stay 8k bounded.
- Schema: enum entry; `limit`/`actual` conditional (`memory-index-too-long` limit stays 1500; new code
  integer limit=sum cited scalars, actual=content scalars).

## Wiring

- C: both `BotMCPRuntime` memory constructions pass
  `recordReading: recordEvidence as? any BotMemoryMaintenanceRecordReading`; nil keeps old behavior.
- P implementation/tests already return code; M judge/gate don't depend on it.

## Verification

- P: `MemoryEvidenceLengthGuardTests` 4/4; full `swift test --filter Memory` 156/0.
- G: v2 vectors PASS (writes 20, guard valid/invalid), schemas/registry/cross_check PASS.
- Not done: C integration/App composition, M two batches, real model/device; A04/A05 etc. not opened.


## Android compatibility correction（CI run43903927538）

- The two maintenance evidence-length cases were incorrectly placed in the shared base
  `golden/memory-write.json`, which Android's `MemoryWriteGoldenTest` consumes; Android has no
  `BotMemoryMaintenance` guard yet, so `cases[18]` failed (`ok=false` vs actual true).
- Corrected: base golden restored to the original 18 cases; the two cases moved to
  `golden/memory-write.next.json` (`status: next-unenabled`), validated by
  `tools/validate_memory_evidence_length.py` and the v2 vector runner. Schema/README/negative coverage
  remain; no test deleted, no Android behavior implemented, no decoder loosened.
- Only these two iOS/Swift-only maintenance cases were added by this change; no other shared base
  memory case was added. Android base reader sees the same old cases. CI rerun is C/root's step.


## Final baseline split (K-L1)

- `memory-write.json` is back to the 17-case shared baseline (908 merge-base): the review case
  `write-with-verified-verification` now lives only in `memory-write.phone.json`, and the two
  maintenance evidence-length cases only in `memory-write.next.json` (next-unenabled). Android's
  `MemoryWriteGoldenTest` therefore sees 17 cases; iOS/TS merged consumers see 17+1 phone cases and
  the Swift write path tests remain.
