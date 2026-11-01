# CROSS.md — cross-tree consistency gate

`spec/tools/cross_check.py` checks the seams between `spec/v1`, `spec/host/v1`,
`spec/platform` and `spec/ui/v1`. Each tree already has its own checker; this gate adds
only the invariants that need two trees at once. It is read-only: it reports, never repairs.

```
python3 spec/tools/cross_check.py --root .
python3 -m unittest discover -s spec/tools -p 'test_*.py' -v
```

Output is one line per invariant (`[n/8] ... ok|fail`), then detail lines, then a summary.
Exit code 0 means all eight hold; 1 means at least one failed; 2 is a usage/root error.

## Invariants

1. **Reference reachability.** Every `spec/...` path in a README or JSON file must exist.
   A reference may end in `.md`, `.json`, `.jsonl` or `.py` (`REF_EXTENSIONS`); the extension
   is matched longest-first behind a non-extension lookahead, so `expected.jsonl` stays
   `expected.jsonl` instead of being truncated to `expected.json` (a path that never exists).
   Catches a renamed/deleted contract file that another tree still cites by path.
2. **Platform whitelist ↔ contract.** Every `spec_ref` target exists, and every
   `platform.<id>` mention in the host/UI trees is a whitelist id. Catches an invented or
   misspelled platform divergence name before an Android owner implements it.
3. **Bridge registry ↔ golden vectors.** Every method in the `bridge.md` registry appears
   in a non-negative `golden/bridge` vector and every such vector method is registered.
   Catches a method added to prose without a wire example, or a wire example with no rule.
4. **Event-kind closure.** Event kinds declared by `trajectory.md` and used by the
   trajectory fixtures must exist in the host `harness-event` kind enum. Catches a
   trajectory/UI vocabulary that a Kotlin host cannot emit or map.
5. **Signature-surface closure.** The six keys of `tokens.json.signatureSurfaces`, the six
   rows of the UI README signature table, and the six names in `trajectory.md` must be the
   same set; the README token composition must also equal each `tokens` list. Catches a
   missing surface and a surface documented with fewer tokens than the single source.
   The same equality is enforced inside the UI tree by `ui_check.py` rule 10, in both
   directions and with a header column required per token family; its projection-row check
   is a **subset** test instead, because one projection row renders only part of a surface.
6. **Capability vocabulary.** Every capability name used by `golden/device-*.json` is
   declared by `device-capabilities.schema.json` (or its `vehicle.*` wildcard). Catches a
   typo such as `render.pixl` that schema validation alone accepts because the map is open.
7. **No orphan fixtures.** Every `golden/**/*.json` is covered by a checker's glob or file
   name, and every registered checker glob matches at least one file. Catches a fixture
   nobody validates and an empty directory that would otherwise pass silently.
8. **Schema basenames.** `*.schema.json` basenames are unique across all trees. Catches a
   duplicate name that makes `validate_json` errors impossible to attribute to a tree.

## Deliberate canonicalisations and exceptions

- The generic field-format placeholder in the platform README is ignored by invariant 1;
  it is a syntax example, not a repository path.
- The bridge negative vector intentionally names an unregistered method. Invariant 3 turns
  that into a positive assertion: the method must stay out of the registry, or the vector
  no longer tests `BRIDGE_METHOD_UNKNOWN`.
- The three documents spell signature surfaces as camelCase (`tokens.json`), kebab-case
  (`trajectory.md`) and Chinese display labels (UI README). `SURFACE_ALIASES` maps those
  spellings case-sensitively; an unknown spelling is a failure, not a silent alias.
- A `.jsonl` reference is a legal reference, not a JSON file with a suffix: `REF_EXTENSIONS`
  keeps the longest extension and the lookahead refuses to half-match an unknown one, so
  `.jsonnet` is left alone rather than being truncated to `.json`.
- The UI README signature table writes bare geometry names (`bubblePadding`), so they
  canonicalise to `geometry.<name>`; a family with its own column (`spacing.*`) is written in
  full. `ui_check.py` rule 10 requires a column for every family any surface uses, and the
  projection golden may name only tokens its surface declares (subset, not equality).
- `trajectory.schema.json` closes event `type` with a pattern, not an enum. Invariant 4
  therefore uses the event tokens declared in `trajectory.md` plus the types present in
  `golden/trajectory/**/*.jsonl`; the detail line says when the fallback is active.
- Fixture readers are registered in `GOLDEN_READERS`: a new golden directory is an orphan
  until its owning checker is added there, which keeps the coverage claim executable.
- When an invariant fails, the finding is for the tree owner. This tool does not choose a
  side or edit a contract to make itself green.
