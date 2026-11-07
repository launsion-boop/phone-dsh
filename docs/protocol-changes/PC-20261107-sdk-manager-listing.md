# Freeze Android SDK package-listing adapter

```yaml
change: PC-20261107-sdk-manager-listing
contracts: [P23]
status: frozen
breaking: false for documented SDK listings; false-positive classifications are rejected
base: 529cbee4cc2a3352de8af2d4fcf179fe0607aa52
contract_revision: spec/toolchain/v1/sdk-manager.md@sha256:ee003b03dd2749839f765561b03bef1caaeb300cf464b6df152c4dce1d163f8b
```

Protocol impact: P23. The real SDK command-line tools 23.0 produced slash
package paths under `Installed packages:` and the existing adapter reported
present platform and build-tools packages missing. Existing substring matching
can also accept diagnostics and similarly named packages. The owner freezes
exact row/section and version matching, the canonical emitted ID, process error
handling and the existing directory checks. Shared positive and negative
fixtures have SHA-256
`b126b1b0be5a260a47dca4d6bce789e677028063350760d7de174018dd79e394`;
their schema has SHA-256
`7d2c93a1b2f2a7c1d8c4da5728f2eccfb5e4b6fd595e04bf4af5e0a387421374`.
The external producer is not controlled by the repository; the newer output
is real version-23 evidence, while the legacy pipe form is represented by the
existing controlled test producer, not newly observed hardware evidence.

| Combination | Decision |
| --- | --- |
| old listing → new adapter | The documented legacy pipe rows continue to work; ambiguous diagnostic-only matches fail instead of being incorrectly accepted. |
| new slash listing → old adapter | The old adapter can report installed platform/build-tools missing; no compatibility is claimed. |
| supported listing → new adapter | Exact IDs and version-bearing rows inside the installed section are accepted; process failure, unknown/ambiguous layout, wrong or absent IDs fail closed. |
| existing SDK data → new / rollback | Existing installed directories and license files are not migrated or deleted. Rollback restores the previous parser, including its false positives and slash-format failure. |

No on-disk format, sdkmanager command, `PACKAGE` output vocabulary or version
number changes. Coordinator owns `spec/**`, the bootstrap adapter and its
shared tests. Only after this freeze is committed may implementation start;
review the combined diff and drive all fixtures through the actual shell
adapter and a controlled external producer, including nonzero exit and missing
directories. Acceptance: `python3 -m unittest discover -s android/tools -p
test_bootstrap_android_toolchain.py`; the real SDK manager listing check with
an isolated SDK copy; `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree`; and the affected Android
structure gate with its toolchain paths isolated. Record all failures and
skips. Listing recognition does not prove device, artifact or runtime behavior.

Freeze verification: `python3 -m unittest discover -s spec/v1/tools -p
test_spec_golden.py` → PASS (66 tests); `python3 -m unittest discover -s
spec/tools -p 'test_registry*.py'` → PASS (24 tests); `bash scripts/ci/check.sh
--only phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS.
The P0 failure predates this change. These checks validate the frozen cases and
registry, not the not-yet-implemented adapter.
