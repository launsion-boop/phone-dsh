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
