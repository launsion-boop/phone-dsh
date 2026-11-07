# Freeze page-title ownership for source extraction

```yaml
change: PC-20261107-page-title-ownership
contracts: [P09]
status: frozen
breaking: false
version_decision: Preserve page-structure/1; reject ambiguous extraction instead of guessing.
base: 00402003f6efde6c5fdda3032053443dd5a7d76f
contract_revision: spec/ui/v1/page-title-ownership.md@sha256:e52cbb9bb1b9d449a2af393f84c71327c85469afffee74c79bb3981920408c6b
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
`30460a1373c549bc2c2b90580502101ca8bbb1c95f9b117fd75ebf53ecce54c0`;
`golden/page-title/cases.jsonl` has SHA-256
`88d5bdb4bb1d89be0e0b00ff6ab213b10856ed62fffcec0bf5c6bf0e9a9126c0`.
The 33 Swift source fixture manifest has SHA-256
`75d04e1bb2f970b2799847f2c51f2f94c1ce4b9c21a58fa3d30896789604c80e`,
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

## Revision 2 — raw-string, comment and dynamic-expression ownership

Independent Swift frontend and extractor tests found that raw Swift string
delimiters can expose fake titles and braces to the shared structural mask,
and title-argument comments can supply an incorrect label. Repair may change
`mask_comments` only as needed to correctly mask ordinary/raw single and
multiline strings and detect an unterminated raw string while preserving offsets
and newlines. Since this helper is shared, compare the complete repository
extraction, including rows, actions and provenance, and run all existing
extractor mutations; do not silently rewrite or delete contracts.

Shared cases also require interpolation and a ternary parent expression to
remain non-literal/null, an unsupported Unicode escape in a would-be static
title to fail rather than invent text, and `navigationDestination(item:)` to
be treated as a destination. The case schema only permits a successful title
or absent result for syntactically valid source; schema mutation tests cover
that restriction. These cases do not decide SwiftUI runtime preferences.

## Revision 3 — regex lexical boundaries

An independent valid Swift extended regex containing a fake title and brace
was previously misclassified by the shared structural mask. Add cases for
`#/.../#`, multiple hashes, an unterminated extended regex, and ordinary
division. When an unqualified slash could be a profile-dependent bare regex
with title-affecting syntax, the source extractor must fail rather than guess;
the bare-regex case is valid when the compiler's bare-slash flag is enabled.
This does not declare all Swift grammar supported or resolve GAP-19. The same
full-repository field comparison and existing regression requirements apply.

## Revision 4 — malformed delimiters and escapes

A real extractor probe found that unbalanced parentheses and invalid Swift
string escapes could still yield a guessed or absent title. Freeze negative
fixtures for a missing delimiter and invalid escapes inside and outside a title,
and a positive fixture for valid escapes with its rendered title and exact
source anchor. Shared lexical analysis must validate delimiter balance and
Swift string escapes, including valid Unicode and multiline continuation
forms; no other page fields or fixtures may be weakened. Run the full existing
extractor tests and compare all repository extraction fields after the fix.
