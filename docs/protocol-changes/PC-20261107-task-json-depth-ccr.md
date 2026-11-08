# CCR: task JSON nesting and compatibility

```yaml
change: PC-20261107-task-json-depth-ccr
contracts: [P06, P07]
status: draft
breaking: pending
version_decision: pending
base: 8dfb82a6
contract_revision: pending
```

The task contract ignores unknown members but does not set a common nesting
limit. An isolated local comparison of the real Swift, Python and C validators
with nested arrays in an unknown task member accepted 511 array levels on all
three, but Swift rejected 512 and 800 where C and Python accepted; near 1,000,
Python hit its recursion limit while C and Swift differed. These measurements
are specific to the tested runtimes and include the enclosing task structure;
they are not a hardware memory measurement or an approved new protocol limit.

Before changing behavior, the owner must select a defensible common nesting
policy with exact counting rules, transport and parser limits, producer and
consumer compatibility, old persisted data and rollback behavior, and shared
boundary/invalid fixtures. It must be supported by real end-to-end parser and
device-resource evidence. In particular, do not silently pick a lower limit
or silently discard unknown data to make a platform pass. The current raw
number, Unicode and journal checks do not resolve this gap and do not imply
agreement for arbitrary JSON depth.

## Local recovery and projection candidate

The iterative raw-key walk used by the read-only inspector avoids its prior
stack overflow, but `DeviceTask.decode` and journal recovery still hand full
objects to Foundation decoders. A candidate is to validate the complete
original bytes, then construct a temporary shallow projection of recognized
scalar fields for decoding. It must never replace the original bytes, change
the persisted record, or skip validation of unknown content. This is not yet
an approved contract change: Foundation's depth behavior means projection can
accept inputs that the old decoder rejected, even if both preserve unknown
fields. It could therefore change interoperability and rollback semantics.

Before freezing, decide the depth policy and its counting against Swift,
Python, C and real device resources, and distinguish stored parent records,
tasks, outcomes and BLE intents. Specify known-field wrong types, inactive
outcome fields, null versus absent, duplicate known and unknown keys, Unicode
scalar-equivalent key spellings, NUL, invalid numbers, UTF-8/16/32 and BOM
handling. Known fields containing an unexpected deeply nested value must not
be passed unbounded to Foundation. Preserve task fingerprint and existing
post-decode checks; original task validation and persistence remain governed
by their current raw-byte clauses. Test every real decoder and failure path,
including unknown deep values, old valid records and rollback, rather than
comparing a copied validator. DeviceTaskJournal's separate unbounded file read
and BLE intent decoders also require an explicit scope decision. The candidate
is not implemented and does not close GAP-23.
