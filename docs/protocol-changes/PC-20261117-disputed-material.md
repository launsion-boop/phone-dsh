# PC-20261117-disputed-material — disputed-only correction and material review_state

- status: frozen
- base: `9a373adeac0e10f2d3b61c9136a70107778bbc5b`
- owning: `spec/bot/v2/decision-context.md` §3.2/§1、`decision-material.schema.json`

## Delta

- `correct` has two legal forms:
  1. applied correction: `applied.memory` present and `target.version == applied.memory.version`;
  2. disputed-only: `applied` omitted, `target.kind=memory`, `target.version` is an existing version,
     tool `disputed_refs` non-empty and written as event `subjects`; no memory body/version change.
     Host appends existing `memory.review_requested` (disputed) and `feedback.recorded`; otherwise
     `correction-not-applied`.
- Undo references the feedback id; disputed-only undo writes reverse event + existing
  `memory.review_resolved` outcome `dropped`, no body/history change, no fabricated verified.
- R material: active disputed feedback for a memory artifact → `state=unknown` + optional
  `review_state:"disputed"`; never current. Undo/expiry clears; only new grant/review changes it.
  `suppress`/`adopt` preferences stay in F delivery gate; not material, no second preference system.
- `decision-material` item gains optional `review_state` enum verified|unverified|disputed|unknown;
  no feedback schema field/wire change (uses existing `subjects`).

## Owners / verification

- F: disputed-only caller (existing version+real refs, no body change, undo clears).
- R: consume disputed into material (refs/scope/version; unknown+disputed).
- C: inject composition; E: memory disputed→next decision non-current→undo; UI user-scope→other Bot
  consumes and other goals not stopped.
- `validate_decision_context.py` PASS (feedback 15, material 6/21, mutations 26).

## Not done

- F caller/R/C/E runtime; no model/device evidence; A05/A03/A08 not signed.
