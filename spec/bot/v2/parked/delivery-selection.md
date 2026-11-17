# Parked reference: A04 delivery selection / suggested attachment

Status: **parked target**, not current. The original-scope host does not install the A04
delivery-selection host (draft/offer/confirm), does not accept the `deliverySelection` phone
action, and does not serve `delivery{...}` row projections or suggested-attachment candidates.
The content here is kept so a future implementation can reuse the frozen shapes; the current
validator and registry do not read this directory as a current capability.

## Removed phone action (was `spec/bot/v1/user-action.phone.schema.json`)

```json
{
  "type": "object",
  "required": ["nonce", "botID", "kind", "rowID", "draftID", "expectedRevision", "selectedResourceIDs"],
  "properties": {
    "nonce": {"type": "string", "minLength": 1, "maxLength": 128},
    "botID": {"type": "string", "minLength": 1, "maxLength": 128},
    "kind": {"const": "deliverySelection"},
    "rowID": {"type": "string", "minLength": 1, "maxLength": 200},
    "draftID": {"type": "string", "minLength": 1, "maxLength": 128},
    "expectedRevision": {"type": "integer", "minimum": 1},
    "selectedResourceIDs": {"type": "array", "maxItems": 12, "uniqueItems": true,
      "items": {"type": "string", "minLength": 1, "maxLength": 128}}
  },
  "additionalProperties": false
}
```

## Parked row projection / suggested attachment

- A delivery/approval row could carry `delivery{draft_id,revision,parameters[],resources[]}`;
  each resource `{id,name,detail?,reason?,selected,state,source}`. `source` is the G-1
  `source_statuses` UI projection; `revision` is host-monotonic.
- Suggested attachment candidate: `{suggestion_id,draft_id,revision,artifact_kind,
  resource{...},selected,created_at_ms,updated_at_ms,approval_digest}` with `artifact_kind`
  closed to `delivery|draft|notification`.
- Lifecycle/rebinding: `candidate -> selected/removed -> submitted`; one submission carries the
  whole selected set (idempotent), not incremental toggles. `approval_digest = "sha256:" +
  sha256(canonical JSON of [draft_id, revision, sorted(selected_resource_ids),
  parameters sorted by label])`; revision/digest monotonic; an old digest's allow/deny is
  rejected (`digest_mismatch`/`draft_changed`).
- Selectability: `revoked|erased|unavailable` resources are not selectable; `changed|unknown`
  are selectable but must be labelled historical/unknown.

Parked vectors: `spec/bot/v2/parked/decision-context.delivery-selection.json`;
schema: `spec/bot/v2/parked/suggested-attachment.schema.json`.
