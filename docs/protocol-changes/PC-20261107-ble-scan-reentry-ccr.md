# CCR: iOS BLE scan lifecycle reentry

```yaml
change: PC-20261107-ble-scan-reentry-ccr
contracts: [P07, P09]
status: draft
breaking: pending
version_decision: pending — no new scan ordering is approved by this request
base: 9e313f84526918c5bf52d3b54e56a80f04785796
contract_revision: pending
```

Protocol impact: P07; P09. Source review found that global status-text intent
ordering does not order the independent scanning side effects. A status
will-change callback can synchronously stop a just-started scan, after which
the older scan invocation can still publish its old text and install a timer.
A scanning will-change callback can similarly stop a scan before an older
setter writes `true`, or start a scan before an older stop setter writes
`false`. The resulting displayed state can disagree with the actual local
physical submission order. A stop during manager initialization can also be
followed by the older invocation constructing a manager. These are
source-derived cases, not physical OS or radio evidence.

The owner must freeze start/stop/initialization intent ordering, timer ownership,
pre- and post-Observation revalidation, power loss and status compatibility,
and the effect of a new start during an older stop before implementation. A
candidate is a separate non-reusable scan intent, independent of the status
revision, with later eligible user intent winning. Its exact admission, manager
creation, cancellation and no-op semantics require shared valid/invalid
fixtures and review. The real store, Observation and physical submission seam
must be tested with one-shot nested start/stop at status and scanning changes,
including old timer after a new scan and manager-off; no fake OS acknowledgment
may be invented. Device power behavior and actual BLE radio sequencing remain
independently unverified. This request does not authorize an implementation or
change any wire format, task capability or permission.
