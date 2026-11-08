# Correct the source page inventory

```yaml
change: PC-20261107-ui-inventory-correction
contracts: [P09]
status: frozen
breaking: false
base: bce526a3
contract_revision: spec/ui/v1/README.md@sha256:3043f88c2422ec022f3585264951630c02c2577de3fa828900dc511c5b3178df
```

`SettingsPage.swift:79-86` actually opens MCP, SSH, Bluetooth and Android ADB
settings. Correct the erroneous unreachable MCP entry and list the other three
source pages with their real entry points. These reachable settings pages are
required for parity; this inventory does not claim Android implements them.
Bluetooth device tasks remain disabled by default. The three added rows explicitly
say their complete machine-readable structures are still missing. In particular,
the SSH private editor, Bluetooth build profile, and ADB network/key side effects
must be reviewed before generating those contracts (baseline GAP-19 and GAP-21).

No page-structure/1 schema, baseline, allowlist, UI code, or device protocol is
changed. Existing old inventories omit real pages; this inventory names them,
and the source-completeness gate continues to reject absent or stale page JSON.
New inventory with an old checker may therefore still miss absent contracts;
new inventory with the current checker fails closed. There is no user data to
migrate or rollback. The shared matching/missing/changed-source cases and real
extractor tests in `spec/ui/v1/golden/page-completeness/` remain authoritative;
they were frozen at `6f8c209e` and exercised at `c8bfc93c`.

The coordinator owns this README and record; no implementation is delegated.
Acceptance: `python3 spec/ui/v1/tools/ui_check.py --root .`; and
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Report each actual outcome: the inventory correction does not resolve the
missing structures or prove build-profile, Android, or device runtime parity.

## Verification at 366720c8

`python3 spec/ui/v1/tools/ui_check.py --root .` → PASS (47 documented
source pages, 345/345 lines). `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS. P0
still reports the three absent structures and six other stale structures; its
page-structure test also fails on stale Chat provenance. This is an incomplete
acceptance, not evidence of UI parity. The README is an inventory correction,
not a substitute for those page contracts or their Android implementations.
