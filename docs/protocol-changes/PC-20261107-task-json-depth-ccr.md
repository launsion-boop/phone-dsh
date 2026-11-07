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
