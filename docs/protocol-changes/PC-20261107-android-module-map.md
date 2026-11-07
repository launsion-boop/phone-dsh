# Android module mapping inventory and structural gate

```yaml
change: PC-20261107-android-module-map
contracts: [P08, P12]
status: frozen
breaking: false
version_decision: Add a version-1 repository inventory and validate the existing README projection; no application, package ABI or wire change.
base: 9b968ee054d504ae2af5dc26f6c2181a8bfeaa49
contract_revision: spec/platform/android-module-map.json@sha256:d997d82e1424c5b4bb4acd1bbc8bf5f4af63b70157777cff7174ba8899b7cc54; spec/platform/README.md@sha256:9460c4364a050d69eb292c15616b125c1788dbd9c4f9696e3815259871311aba
```

## Trigger and authority

The existing Android structure gate assumes exactly 11 Swift module directories
and validates only their first column in `android/README.md`; main already has
13 directories and this branch has 16. The machine-readable
`spec/platform/android-module-map.json`, its schema and platform README are the
single reviewed P08/P12 inventory authority; the Android README is its human
projection and the existing checker is the consumer. This is a repository
mapping contract, not an application capability or an authorization to call a
target feature. Protocol impact: P08, P12. The original 11 mappings remain;
BLE/LAN are explicitly unwired `target` code only, ADB/SSH/DeviceTasks are
`absent`. The inventory does not assert the existing `mapped` modules implement
every behavior.

The checker must parse the authority as a strict version-1 object with exactly
its documented fields, no duplicate JSON keys, duplicate module names, invalid
status or invalid/null package/module combination. It must compare the exact
set of Swift source directories, manifest entries and README rows in both
directions; reject missing, extra and duplicate rows or directories; compare
all four data cells against the manifest; require every non-absent Gradle
module to be included in `android/settings.gradle.kts` and have its build file;
and require the declared Kotlin package to exist in that module's production
source. An absent mapping has neither package nor module and must not be
presented as implemented. Exact metadata must be reviewed to add, remove or
rename a source module. The checker must not silently accept a new directory by
changing a count, grow a permissive allowlist, skip a row or remove any existing
structure check. No dynamic device discovery, GATT, identity, grant, journal,
app UI or library API is added.

## Compatibility and shared scenarios

Old README/old checker: unchanged prior behavior; old README/new checker fails
closed until the projection and inventory are updated. New README/old checker:
the old checker reports its obsolete expected count; new/new validates the
reviewed inventory and actual source. Application runtime, old user data and
rollback do not change. A rollback must restore README, checker and manifest
together; the old checker cannot validate a new mapping.

The manifest is the valid shared fixture. The real checker and tests must drive
`spec/platform/golden/android-module-map-cases.jsonl` and its vector schema,
not a copied decoder: baseline valid; remove, duplicate or add a README row;
change README package, module or status; claim a package for absent; remove/add
source directory; remove the declared Kotlin package or Gradle module; duplicate
a manifest entry; and use an invalid manifest status. Each mutated tree must
fail the real `readme-map` check, while unrelated checks and the existing
mutation suite remain effective. Include malformed or duplicate-key JSON,
unknown fields and nonexistent/incorrect module/package. Existing full
`android/tools/test_structure_check.py` scenarios must be retained.

## Ownership and verification

Coordinator owns `spec/**`, `android/README.md` and this change record.
Implementer exclusively owns `android/tools/structure_check.py` and
`android/tools/test_structure_check.py` and must not change spec, README,
fixtures, another gate, manifest, application or build configuration. The
contract revision is the hashes above and the schema/fixture committed with
this record. Acceptance: `python3 android/tools/structure_check.py --root .`;
`python3 -m unittest discover -s android/tools -p 'test_structure_check.py'`;
`bash scripts/ci/check.sh --only phone-android-structure,phone-spec,phone-p0-conformance,phone-cross-tree`.
No built Android 16 KB artifact is assumed; its absence is SKIP, not artifact
PASS. Android GATT, BLE device tasks, UI parity and physical devices remain
unimplemented or NOT_RUN as applicable.
