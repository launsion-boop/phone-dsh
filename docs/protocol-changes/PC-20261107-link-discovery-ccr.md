# Contract change request: Link discovery callback attribution

```yaml
change: PC-20261107-link-discovery-ccr
contracts: [P07, P09]
status: draft
breaking: false
version_decision: pending; this request does not authorize a production change.
base: 734b1573
contract_revision: pending
```

CONTRACT CHANGE REQUEST
Contract: P07 @ b969e4ac / `spec/device/v1/ble-link.md`, iOS GATT ordering
and Link service profile. Clause: attribution of service and characteristic
discovery events.

Problem: source review found that a connected owner with an active Link
channel can receive a second, incomplete Link characteristic-discovery result.
The implementation first replaces the endpoint table and then displays an
incomplete result without necessarily retiring the earlier channel, client or
identity. Same-UUID multiple services, duplicate callbacks, duplicate
characteristics, changed properties and callbacks without a matching current
request are not defined by the frozen contract. CoreBluetooth supplies object
identities but no application request token, so UUID equality alone cannot
prove physical callback provenance or freshness. The review does not prove
that any particular OS actually produces such an event.

Proposal: freeze the local attribution and failure policy for each submitted
service/characteristic discovery using actual peripheral, service and
characteristic object identities, including partial or failed results, same
UUID on different services, duplicates, retries and reconnects. Decide whether
an ambiguous or repeated result quarantines the entire connection or only
Link, what happens to standard reads and already submitted operations, when
old channels, authorization and identity are invalidated, and the compatibility
impact on existing peripherals. Do not infer OS epochs or re-enable task
access. Use shared valid/invalid fixtures and the real production callback
and admission paths with simulated physical objects, then separately seek
real device/OS evidence. Firmware wire format is unaffected; iOS and its UI
are affected. No implementation is approved by this draft.
