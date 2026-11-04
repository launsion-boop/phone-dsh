## Problem and resulting behaviour

Concrete trigger, previous behaviour, and the resulting behaviour.

## Protocol impact

<!-- Required. Match your diff against the path → contract table in spec/README.md §4. -->

`Protocol impact:` P01; P09: none — <reason specific to P09>

List every triggered ID: bare IDs declare impact; each `ID: none — reason` only
justifies no impact for that ID. Use semicolons between clauses. A single global
`Protocol impact: none — reason` is allowed only when no IDs trigger.

For IDs declared as affected:

- [ ] Change record (contract freeze) filled in here or linked:
      [template](https://github.com/launsion-boop/phone-dsh/blob/main/docs/protocol-change-template.md)
- [ ] Owning spec/schema/golden or code-contract file changed **first**, at contract revision: `<sha>`
- [ ] Every producer and consumer listed in the registry is updated, or the record says why not
- [ ] Shared valid **and** invalid fixtures run through each end's real decoder
- [ ] Compatibility matrix (old→new, new→old, new→new, old data/rollback) answered
- [ ] No second envelope, alias field, duplicate error code, loosened schema or skipped check
- [ ] No `target` / `draft` / `[NEW]` clause claimed as implemented without runtime evidence

## Validation

Exact commands and results; distinguish spec checks, runtime tests and device
evidence. Preserve PASS / FAIL / SKIP / INCOMPLETE / NOT_RUN and remaining risks.
P01/P02 codec changes: include `cd shell && cargo test -p pdsh-wire -p pdsh-wal`.
