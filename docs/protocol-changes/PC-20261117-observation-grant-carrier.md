# PC-20261117-observation-grant-carrier — optional grant_id on observation carriers

- status: frozen
- base: `9a373adeac0e10f2d3b61c9136a70107778bbc5b`
- owning: `spec/bot/v2/provenance.md` §3.1 carrier table、`spec/bot/v2/context-observation.schema.json`
- additive optional field; no new event/storage/endpoint.

## Delta

- `conversation.tool_result` data root may carry optional `grant_id` string 1..128: the real `BotGrant.id`
  that authorized that tool read, written at observation time by C's authorize→producer path keyed by
  callId.
- `context.observed` flat data may carry optional `grant_id` (same value semantics).
- P reads it into `BotSourceState/BotSourceBaseline.grantId`; memory write only passes it through.
  **Never** infer from current grants, approval, time or `authorization_ref`.
- No real grant → omit; old writer omits, old reader ignores; read view treats as no grant information.
  Re-authorization needs a new grant id/generation (G-1 r18).

## Compatibility

| combination | behavior |
| --- | --- |
| old writer → new reader | no grant_id → nil, no revoked claim |
| new writer → old reader | unknown data field ignored |
| new writer → new reader | real grant bound; revoked gate can fire |
| rollback | no schema version bump; field optional |

## Verification

- `validate_context_sources.py` PASS (calendar-os valid with grant_id); `validate_provenance.py` PASS
  (31/62); registry PASS.
- P seam `66d236ea9` 2/2; L gate 41/41; R HTTP counting 3/3 — these cover already-bound grants, not
  production binding until C writes the carrier.

## Not done

- C authorize→producer mapping, P sourceState read, C updateMemory passthrough, E runtime evidence;
  A03/A08 still NOT READY.
