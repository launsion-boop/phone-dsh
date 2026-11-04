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
   It also checks local Markdown links in the protocol index (`spec/README.md`)
   and `AGENTS.md`, including source/test paths and directories. These entrypoints
   must exist, links must stay within the repository, and `CLAUDE.md` must be a regular file
   whose first nonempty line is `@AGENTS.md` (symlinks and copied rules fail). External URLs and section anchors are not fetched or
   validated. This prevents a stale index or two diverging agent rulebooks; it
   does not prove that the linked implementation conforms to its contract.
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

## Protocol registry (same CI stage)

`spec/README.md` §3/§4 修改後，執行 `python3 spec/tools/registry_build.py --write`，
並把生成的 registry 一起提交。`phone-cross-tree` 執行 `registry_build.py --check`：
重新生成的 UTF-8、縮排、key 順序與結尾換行必須和 `spec/registry.json` 逐字節相同。
`--check` 不寫檔；正式生成器不讀現有 registry 作為輸入，也不依賴 evidence 目錄。

Sections 3/4 supply source cells, roles and trigger predicates. Reviewed expansions
of abbreviated paths/language groupings and explicit status assertions live in
`registry_build.py`'s `PATH_PROJECTIONS`; update that metadata when changing a
row's path meaning or adding/removing IDs. The builder does not infer runtime
implementation status or prove that a path is the semantic authority.

`phone-cross-tree` also runs `registry_check.py --root .` and discovers its mutation
tests with the existing tool suite. The embedded schema in `spec/registry.json`
validates each entry; all references must exist, each glob must reach a file, and
IDs, owner roles, source cells and structured triggers must agree with baseline
sections 3/4. Brace alternatives and segment-aware `**` are supported. Exclusions
and bridge content predicates remain explicit. Empty `status` means the row makes
no implementation-status assertion; it does not mean `implemented`. Source cells
preserve qualifiers such as draft authority, non-runtime evidence and partial ends.
This verifies transcription and reachability; it cannot prove semantic conformance
of a linked implementation. No runtime message/schema/golden is changed.

## Local protocol impact check

```sh
python3 scripts/ci/protocol_impact.py --base origin/main --body-file pr-body.md
```

Both diff tools first resolve `git merge-base <base> HEAD`, matching the left
endpoint of a three-dot PR diff. The merge-base-to-worktree diff includes
staged/unstaged/untracked files and both paths
of renames. Conditional bridge triggers inspect both old and new content, so
removing a call is still covered. A single `Protocol impact: P01, P02` line must
cover all triggered IDs. `Protocol impact: P01; P09: none — UI comments only`
declares P01 affected and justifies no impact for P09 only. Every triggered ID must
have its own declaration; IDs inside reasons do not count. A global
`Protocol impact: none — reason` is accepted only with zero triggered IDs. The tool
cannot judge whether a reason is truthful. Missing lines/IDs, unknown IDs, bare
none and duplicate/contradictory declarations fail. Tests run in `phone-gate-contracts`; this
checker is local-only until a caller supplies a real PR body. No hosted workflow
is added.

## Structural schema compatibility

`phone-cross-tree` runs `schema_diff.py --base origin/main`; set `CI_PROTOCOL_BASE`
to another locally available base ref when appropriate. Missing/invalid bases fail.
Direct use: `python3 spec/tools/schema_diff.py --base <ref> --root .`. It compares
all files under `spec/**/schema/*.json` with that merge-base, including deleted
paths. Changes only on an advanced base branch are not part of the current delta.
Required/type/enum/domain changes in either direction, removed properties, changed
unknown-member policy and other changed validation/default/reference keywords are
conservatively breaking. Optional property additions and annotation-only edits are
not automatically breaking; the owner still checks documented defaults and peer
policy. This is structural evidence, not a complete JSON Schema theorem prover.

A breaking change needs a new/modified `docs/protocol-changes/*.md` using the
change template's YAML summary: `breaking: true`, covered `contracts`, a matching
comparison merge-base (`base` is resolved with the same rule), frozen-or-later `status`, and concrete `version_decision`. An
unchanged historical record cannot authorize a new delta. Unknown ownership fails.
No protocol schema or GAP is changed by this enforcement work.
