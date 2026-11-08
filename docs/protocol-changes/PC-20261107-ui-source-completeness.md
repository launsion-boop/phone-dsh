# Require page source inventory in P0

```yaml
change: PC-20261107-ui-source-completeness
contracts: [P09]
status: frozen
breaking: false
version_decision: Preserve page-structure/1 and all existing checker/ratchet rules; make the existing raw-source inventory check mandatory.
base: 9e6dc24d
contract_revision: spec/ui/v1/page-completeness.md@sha256:eed733ccd3a003ef36d5b5a29fec585d90b64eade7dc946781dab84a395410a4
```

## Trigger and delta

`ui_check.py` only tests whether a source page name occurs anywhere in the
README. `page_structure_check.py` loads only existing JSON files and silently
continues when an entrance names a page without a contract. Consequently a new
page name in README can hide a missing structure contract. The existing
`extract_ios_pages.py --check` already detects this source/fixture drift, but P0
runs neither it nor its mutation suite. P09 now requires both. Protocol impact:
P09. No UI, wire field, feature flag, page schema, baseline or existing
checker/fixture is removed or changed.

The raw-source `--check` remains separate from production parity: the existing
extractor still sees both sides of Swift conditional compilation (GAP-19), and
its syntax heuristic can miss private editors, helper side effects and disabled
guards (GAP-21). A source inventory pass must not close either gap or be cited as
runtime evidence. Until the independently frozen profile/semantic contracts are
implemented, do not regenerate unreviewed target or inactive UI as if it were
production parity. This change intentionally leaves the current P0 gate red.

The shared valid and invalid cases are `spec/ui/v1/golden/page-completeness/`:
a real Swift input and exact existing `/1` JSON output; tests drive the real
extractor in check mode on those bytes and use `cases.jsonl` for a matching
pair, deleted JSON, changed source, added unregistered page, and deleted
hand-registered chrome. `cases.schema.json` defines the case shape. Additional
mutation tests must assert that the actual P0 stage invokes the extractor and
its own tests, with failures propagated; preserve every existing P0 stage and
baseline test. A missing checker is FAIL, not SKIP.

Old source/old checker and new source/new checker keep the same page `/1`
shape. An old checker may incorrectly report parity with a missing page; the new
P0 gate rejects that tree. New checker with older complete contracts works if
they match the corresponding source, otherwise fails closed. No user data or
wire migration exists. Rollback of the gate loses the completeness protection
and is not proof of parity.

## Roles and acceptance

Coordinator owns `spec/**`, this record, and extractor mutation tests.
Implementer exclusively owns `scripts/ci/check.sh` and
`scripts/ci/test_p0_completeness.py`; do not edit specs, pages or existing
baselines. The coordinator freezes these source, contract, case and schema
fixtures in the same commit as this record before implementation. Acceptance:
`python3 -m unittest discover -s spec/ui/v1/tools -p test_extract_ios_pages.py`;
`python3 -m unittest discover -s scripts/ci -p test_p0_completeness.py`;
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Run the real extract check on the current tree and report its actual missing or
stale pages; do not call the overall gate PASS unless every existing requirement
also passes. Android device, build-profile and UI runtime evidence remain open.

## Implementation evidence

`python3 -m unittest discover -s spec/ui/v1/tools -p test_extract_ios_pages.py`
→ PASS, 29 tests; the shared cases use the real extractor and demonstrate that
a page named in the README still fails when its structure contract is missing.
`python3 -m unittest discover -s scripts/ci -p test_p0_completeness.py` → PASS,
17 tests against the real stage in isolated fixture trees. On the combined head,
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
→ PASS / FAIL / PASS. P0 now runs all checks and exposes three missing README
pages, nine missing/stale page contracts and a stale existing page-checker test;
it does not hide any with a baseline entry. The source check does not resolve
GAP-19 or GAP-21, nor certify device/UI runtime behavior.
