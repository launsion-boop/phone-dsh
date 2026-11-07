# Freeze page-title ownership for source extraction

```yaml
change: PC-20261107-page-title-ownership
contracts: [P09]
status: frozen
breaking: false
version_decision: Preserve page-structure/1; reject ambiguous extraction instead of guessing.
base: 00402003f6efde6c5fdda3032053443dd5a7d76f
contract_revision: spec/ui/v1/page-title-ownership.md@sha256:0147368ae18bce4668d21e5c8e85a40a671c52b2d8624728db91a9016b4f7a65
```

## Trigger and delta

The existing P09 source extractor picks the first live `.navigationTitle`,
even when that title belongs to a `NavigationLink` destination. The real
`LicensesPage` is consequently identified as its SSH-license child page.
The title is owning-page metadata, not a list of every title in the body.
Protocol impact: P09. Freeze scope-aware selection and explicit failure for
unresolved ownership or precedence, as specified in the owning title contract.
Do not change the `/1` shape, Android UI, feature enablement, parity baseline,
or existing page contracts solely to conceal a failure.

Recognize the fixture-covered `NavigationLink` forms, `sheet`, and
`navigationDestination` as distinct ownership boundaries; an actual trailing
closure can be a label rather than a destination. A child-only title and a
dynamic parent title continue to produce null under the existing representation.
Conditional compilation, unsupported modal boundaries with titles, a title in
an unproven label/toolbar context, multiple possible parent titles and malformed
source must fail explicitly. Do not infer runtime SwiftUI preference behavior
from source heuristics. GAP-19 and GAP-21 remain open.

## Compatibility and evidence

Old extractor/old source behaves as before, including the possible incorrect
title; old extractor/new source can still guess incorrectly. New extractor with
supported old or new source uses the same JSON shape and more accurate source
anchors; ambiguous or malformed inputs fail instead of producing a false
contract. There is no user-data migration. Rolling back the extractor restores
the ambiguity and is not evidence of page parity.

Owning `spec/ui/v1/page-title-ownership.md` is frozen at the SHA above;
`spec/ui/v1/page-completeness.md@sha256:7c2226e5d1da39fb2bb65a38b19fcd925f324904f56aa29bd33192769aad64ec`
registers its requirement. `schema/page-title-cases.schema.json` has SHA-256
`a866581c8d40e3cbdb0cc469544ea56f50ac6d93a0070092538fe5182259cfe5`;
`golden/page-title/cases.jsonl` has SHA-256
`77af0b6e32e0267d23430016fedc7612088a42e3024f57129731f0ade67885b0`.
The 18 Swift source fixture manifest has SHA-256
`cf106652d52f52426e735763879fcbc428478a46beba7aa57833cc4025b256dc`,
calculated by concatenating sorted `<sha256>  <filename>\n` entries. Their
expected title text, source line and anchor are specified independently of the
extractor. The schema checker also rejects malformed fixture rows.

The coordinator owns all `spec/**` files, the extractor and its tests. A
reviewer may inspect or draft outside the repository, but must not edit those
files. After this freeze, drive all shared cases through the real `PageExtractor`
and at least one ambiguity through the real CLI `--check`; verify the current
repository's full extraction diff and existing mutation suite. Acceptance:
`python3 -m unittest discover -s spec/ui/v1/tools -p test_extract_ios_pages.py`;
`python3 -m unittest discover -s spec/v1/tools -p test_spec_golden.py`; and
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Record failures and skips exactly. Source-extraction results are not proof of
Android parity, a production build profile, or SwiftUI runtime behavior.
