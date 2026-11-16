# PC-20261117-workspace-file-provenance — workspaceFile artifact + eligibility

- status: frozen
- base: `9a373adeac0e10f2d3b61c9136a70107778bbc5b`
- owning: `spec/bot/v2/derivation.schema.json`、`derivation-view.schema.json`、
  `spec/bot/v2/provenance.md` §3.3、`spec/bot/v2/decision-context.md` §1（G-2 r8）
- additive optional `derivation` on successful workspace write/edit tool result; no new event/store.

## Delta

- New artifact kind `workspaceFile`; id = normalized bot-root-relative path; no monotonic version
  (omit `version`). Not memory/draft/file-attachment semantics.
- Carrier: successful workspace `write`/`edit` `conversation.tool_result` data.derivation. Sources are
  the real user turn/memory record (evidence/creator); producer records on write success, no manual
  append, no filename/content heuristics.
- New resource kind `workspace-file` (key = normalized relative path, owner=botID, scope=agent) when a
  source resource must be explicit.
- Eligibility: C/R call L `status(forWorkspacePath:botID:)`; L finds the workspaceFile artifact and
  computes worst state from its derivation sources; only `current` may become a material. nil
  (untracked), erased/revoked/unavailable/unknown are not injected, not shown current. The R2 seam
  returns nil in that case (old behavior), never a fabricated current.
- No new wire code/field beyond the optional derivation already defined; old writer omits, old reader
  ignores.

## Owners

- L: `status(forWorkspacePath:botID:)` over existing index, worst state, nil when untracked.
- C/P: production write/edit success records derivation with real sources; no manual append.
- R2: eligibility seam + stub tests; only current material.
- E: real user → memory + derived workspace file → erase/revoke → next turn auto retrieval; no
  filename/content special cases; assert no material for non-current.

## Verification

- `validate_provenance.py` PASS (33 cases / 66 mutations), incl. workspaceFile current + erased.
- Golden cases `workspace-file-from-memory-current`, `workspace-file-memory-erased`.
- Not done: L API/C producer/R2 seam/E cross acceptance; A03/A08 still NOT READY.
