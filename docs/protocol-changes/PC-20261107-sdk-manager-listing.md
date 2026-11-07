# Freeze Android SDK package-listing adapter

```yaml
change: PC-20261107-sdk-manager-listing
contracts: [P23]
status: frozen
breaking: false for documented SDK listings; false-positive classifications are rejected
base: 529cbee4cc2a3352de8af2d4fcf179fe0607aa52
contract_revision: spec/toolchain/v1/sdk-manager.md@sha256:d1821bda494c9070f45284b3e7243805ccf0d3ca94a80e83224fc1bf6b5d8d34
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


## Revision 2 — reject unrecognized listing structure

Independent review of the unmerged first adapter draft found that a section
header with parentheses and a non-table text line could be ignored, allowing
rows from an untrusted or unknown section to satisfy the check; an embedded
CR was also erased instead of rejected. Freeze all three as negative cases.
Valid CRLF removes only the line-ending CR. Within the installed section,
the legacy column header/separator, numeric-version rows and the observed
`unknown -> <numeric version>` row are the supported syntax; unrecognized
nonempty lines invalidate the entire listing. This is fail-closed behavior for
unknown layouts, not a promise about future external manager versions.

The revision 2 owner contract SHA-256 is
`e9d2e2d45d8c3d8f13be2751a154083cef8b0439b4599b7fff53273f89e2d140`;
the 17-vector fixture SHA-256 is
`4fa0da65d54be2be37a0265c65eb636d27d65b906f0bb36feb61a66e865d6f11`;
and its updated schema SHA-256 is
`4305e312a56470cf0205c62c898db91c71836c26011d5f32eb00c97582842901`.
SDK output on stderr must remain visible but cannot supply package rows; the
fixture explicitly tests a forged stderr table. Package IDs and versions use
the contract’s ASCII grammar, independent of the host locale. Compatibility,
ownership and acceptance commands remain unchanged.
The earlier candidate is not merged; the external producer remains unchanged.

Revision 2 freeze checks: `python3 -m unittest discover -s spec/v1/tools -p
test_spec_golden.py` → PASS, 66 tests; `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS. These
are contract checks only; the adapter has not yet been implemented against
this revision, and P0 remains incomplete.


## Revision 3 — required versions and table structure

Independent review of the unmerged revision 2 candidate found that a
required package could appear with `unknown -> ...` as well as a numeric
version, and that malformed heading and separator lines were silently
ignored. Freeze negative cases for these and a non-ASCII package identifier;
only non-required IDs can use the observed `unknown -> version` form, and
the exact legacy heading/separator grammar is stated in the owner contract.
The contract SHA-256 is
`802d47187dacab0cc406990b1fe7b2c927ac6baf54980b44fb2c58c9085a0141`;
the 24-vector fixture SHA-256 is
`1e9e54155c4d4c0f359ff44e55168d39282533aeb7a7281a319ddb5db6bca2ae`.
A source without a terminal LF must still yield standalone `PACKAGE` lines;
a bare terminal CR remains invalid. Unknown section headings fail before as
well as after the installed section. Fixtures preserve exact stdout bytes
rather than appending a newline in the fake producer.
No production change was merged before this revision; compatibility and
acceptance remain as above.

Revision 3 freeze checks: `python3 -m unittest discover -s spec/v1/tools -p
test_spec_golden.py` → PASS, 66 tests; `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS. These
checks validate the contract, not its pending implementation.


## Revision 4 — capture failure and unknown section punctuation

Independent review of the unmerged revision 3 candidate reproduced a
parenthesized or slash-containing section heading before `Installed packages:`
being ignored, and a failed stdout capture returning success after dropping a
later unrecognized section. Freeze both classes as negative cases. Any
nonempty unknown colon-terminated heading before or after the section fails;
the adapter must also verify the capture process as well as the SDK manager
exit status. A capture failure is a failure even if the captured prefix looks
valid. No fake artifact or SDK data is installed by these controlled cases.

The revision 4 contract SHA-256 is
`bd93f624c958e161aedc4bf3626f5055f8f1bb173654bc08b6d1fee58014229b`;
the 27-vector fixture SHA-256 is
`3e3968b73cb0787776387ae8847a8d5adceee59ed040262a5f029849d1a7caf4`;
its updated schema SHA-256 is
`04b5e3f52656ccd4a2b52f4d915490ff277d26d0f3781415ffa7ecd7fbaf927c`.
The earlier implementation draft is not merged; ownership and compatibility
remain unchanged. The real SDK stdout-capture failure case must execute the
actual shell adapter with a controlled failing capture process that writes
the valid prefix and drops the later unknown section.

Revision 4 freeze checks: `python3 -m unittest discover -s spec/v1/tools -p
test_spec_golden.py` → PASS, 66 tests; `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS. This
validates fixture structure and registry consistency, not the pending adapter.


## Revision 5 — compare independent captured copies

A controlled capture process returned zero while silently omitting the
producer's later unknown section from the file; the revision 4 draft then
accepted the intact-looking prefix. Freeze a second independent capture and
byte-for-byte comparison; nonzero status or differing bytes fail. The new
fixture exercises a first capture that writes only the prefix while its
stdout retains the full producer output. The former unqualified claim that
any truncation is detectable was too strong: two identical copies cannot
prove absence of data lost before both or coordinated corruption, and this
revision records that limit rather than asserting it. This does not weaken
the failed-capture, missing package, invalid-layout or process-status checks.

The owner contract SHA-256 is
`d1821bda494c9070f45284b3e7243805ccf0d3ca94a80e83224fc1bf6b5d8d34`;
the 28-vector fixture SHA-256 is
`473b1589083b6dfd84cd4a8e4c1828af921f4a155b69a952c789bf0717db77e6`;
and its schema SHA-256 is
`79cfeb8ae86ae82728e5e5be1baab912ea71d8c89b992039a063e9fdfcfd50d2`.
The earlier draft remains unmerged. Both captured copies, cleanup and failure
paths must be exercised by the real adapter before claiming implementation.

Revision 5 freeze checks: `python3 -m unittest discover -s spec/v1/tools -p
test_spec_golden.py` → PASS, 66 tests; `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS. No
implementation or structure-gate pass is claimed by these contract checks.
