# Freeze page-title ownership for source extraction

```yaml
change: PC-20261107-page-title-ownership
contracts: [P09]
status: frozen
breaking: false
version_decision: Preserve page-structure/1; reject ambiguous extraction instead of guessing.
base: 00402003f6efde6c5fdda3032053443dd5a7d76f
contract_revision: spec/ui/v1/page-title-ownership.md@sha256:db7d7ce2ccd74cb3181dc9f495b2ff77337b73888baf0a0410494641c44f3fc8
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
`cad429862dacfaa0c55cdcbe960ad1029390ad296373fbc7c57f31743e22ef51`.
The 34 Swift source fixture manifest has SHA-256
`64e4e8bc78d03d3e9e0604c017a269c3b81ba314f07f6722b016a9e2b9fa758c`,
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

## Revision 5 — regex after an operator

The revision 3 rule already requires a profile-dependent bare regex that can
affect ownership to fail closed. Add a shared case where such a regex follows
an operator; a scratch extractor had incorrectly treated its contents as a
parent title. The contract is unchanged. The fixture is syntactically valid
when Swift's bare-slash-regex flag is enabled and does not infer the active
product build profile.

## Implementation review — receiver ownership remains open

An independent iOS Simulator SDK typecheck confirmed that a regular method
named `navigationTitle` on a non-View value is valid Swift. A scratch extractor
incorrectly treated `String("value").navigationTitle("Fake")` inside a local
binding as a page modifier. A second typechecked example binds a real
`Text(...).navigationTitle("Fake")` to an unused local variable, then returns
another view; even a View receiver does not prove that it reaches page output.
Other false accepts included an ordinary
`Model.navigationTitle` call used as an argument and a profile-dependent bare
regex after `where`. Passing the existing fixture suite and comparing all 40
repository pages did not detect every one of these cases. The scratch patch is
not merged; implementation must establish receiver, expression and returned-view
ownership or fail closed for unsupported forms. No dynamic page contracts were
refreshed.


## Revision 6 — prove the receiver reaches page output

The original owner clause required failure when ownership cannot be proved;
this revision makes explicit that an identically named method, a View-valued
local binding or a call used as another expression's argument does not prove
a page modifier reaches the returned view. Add four shared error cases for
non-View receiver, unused local view, non-View argument and bare regex after
`where`. All four parse and typecheck with the iOS Simulator SDK; the bare
regex uses `-enable-bare-slash-regex`, which is not evidence of the product
profile. The current real extractor incorrectly selects `Fake` for all four.

The owning title contract is now SHA-256
`4c112455a386e6425f41389dc67eaae6779aff0056a7d96d17c3b4b009550cfe`;
the 38-case manifest is SHA-256
`709e036a078f840f079d99f38938494ab628953bff81958e8dbfc8a4fb0f0c8e`;
the sorted Swift fixture hash manifest is SHA-256
`8a5e3156c05f7dd83e868a43c3720022bd6cf78b076a974144305d50fdc18e7b`.
No stored schema, reader compatibility, rollback decision, runtime parity or
file ownership changes. The coordinator still owns the spec, extractor and
tests; independent reviewers may investigate in isolation. Acceptance remains
the actual extractor and CLI on all shared cases, mutation tests, whole-tree
field comparison and the three required repository gates.

Revision 6 freeze verification: the real extractor returned the incorrect
literal `Fake` on all four new negative inputs; this is a known pre-existing
implementation failure, not a passing conformance result. `python3 -m unittest
discover -s spec/v1/tools -p test_spec_golden.py` → PASS, 65 tests after updating
the exact expected fixture count from 34 to 38. `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS; P0
remains incomplete for the previously recorded missing and stale contracts.


## Revision 7 — helper reachability is output reachability

Independent review of the unmerged revision 6 draft found three valid and
Simulator-SDK-typechecked programs where a titled `some View` helper is only
referenced by an unused binding, passed into `String(describing:)`, or
discarded. A reference-based reachability heuristic incorrectly reported its
title in all three. Freeze those as error cases and a directly returned helper
as a positive case. Output provenance must be established across the helper
call path; neither identifier occurrence nor a View type proves mounting.
Unresolved ownership remains an error, not absence. The incomplete draft was
not committed; existing row and action reachability is not changed by this
revision. No schema, compatibility, rollback or role change.

The contract hash is
`56960870d55c307fc67fc822d91059d5c276ee8d6462578da968abcb2fdd560b`;
the 42-case JSONL hash is
`4eddde699720fdfc527bd0a9390f3102abc4da28567d7fce4d9028c004fcdcfa`;
the sorted Swift fixture manifest hash is
`2e7ef1a02a02f9116346cd8f087706fe23763e895e386710e9ef1739e522a238`.
All four new sources parse and typecheck against the iOS Simulator SDK. The
prior runtime, mutation, CLI, full-extraction comparison and gate acceptance
requirements remain in force.

Freeze verification: `python3 -m unittest discover -s spec/v1/tools -p test_spec_golden.py` → PASS, 65 tests after updating the exact case count to 42;
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
→ PASS / FAIL / PASS. This verifies fixture structure, not implementation of
these cases. P0 and the extractor implementation remain incomplete.


## Revision 8 — presentation-name shadowing

Independent review typechecked a SwiftUI View named `NavigationLink` that
renders its trailing closure directly. Treating this spelling as the standard
SwiftUI navigation destination silently drops the displayed child's title.
A second typechecked example uses a same-named `Text.navigationTitle`
extension that returns the view without setting a title; the compiler AST
resolves the call to that extension. Freeze both as errors: local shadowing or
unresolved symbol identity cannot establish a destination or a title modifier. Cross-file and imported shadowing
cannot be excluded by reading one file alone; this revision does not invent a
module-resolution proof, broaden successful claims, or certify runtime
preferences. The incomplete extractor draft remains unmerged.

The title contract hash is
`865e0a5dfbf7d4212fba31d1231832574a9e8eca9376b41ba3a1d3f6a705e575`;
the 44-case JSONL hash is
`d6041cb515fd3ab9c89d1b6e596c4b8ea9d219b5903cb4a90df100b83be42863`;
the sorted Swift fixture manifest hash is
`dd4faba22a37d414d59166205cc3d6380a05a92dd6c2953eaa1110dfdd0b087c`.
Existing acceptance, compatibility, rollback and ownership remain unchanged.

Freeze verification: `python3 -m unittest discover -s spec/v1/tools -p test_spec_golden.py`
→ PASS, 65 tests with the exact case count at 44; `bash scripts/ci/check.sh
--only phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS.
This checks fixture structure only. The title extractor is not yet implemented
against the frozen cases, and the P0 gate remains incomplete.


## Revision 9 — conditional, chained and shadowed output

The unmerged candidate passed the previous 44 shared cases but independent
Simulator-SDK typechecks produced false ownership claims in conditional
children, multiline unused bindings, multiple root views and a locally
shadowed `sheet`. Freeze those four cases as errors. The owner contract is
SHA-256 `db7d7ce2ccd74cb3181dc9f495b2ff77337b73888baf0a0410494641c44f3fc8`;
the 48-case manifest is
`0304c0f205185bc9fc77426c1f2d1e236f4d805f59d42a98a8e46d03a987165f`;
the sorted Swift fixture manifest is
`14372fd5bffc864f6e2a7dfcb6cb9e02d1eba617a647a653b671f73ce87a766f`.

A further two-file typechecked example resolves `.navigationTitle` to a
custom extension defined in the other file; the source-only candidate instead
reported its literal as a SwiftUI title. The same page file alone cannot
prove which declaration the compiler selects. This is evidence for the
existing unresolved-symbol rule, not a claim that the single-file fixture
format tests a full build graph. The candidate remains unmerged. A compatible
implementation needs verified build/symbol context or must fail closed, and
must not erase existing dynamic-title assertions to obtain a passing gate.

Revision 9 freeze checks: `python3 -m unittest discover -s spec/v1/tools -p
test_spec_golden.py` → PASS, 66 tests; `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS. These
checks validate fixture structure and registry consistency; the extractor
implementation and P0 gate remain incomplete.

## Revision 10 — fixture license headers

The license gate found that the 48 Swift source fixtures lacked their MIT SPDX
headers. Add the header to each source, and advance each successful title's
expected provenance line by exactly one; source anchors, expected outcomes and
all parser behavior are unchanged. The owner contract remains at revision 9.
The updated 48-case manifest SHA-256 is
`50a09827c5a4e8e181433b34375d5fcadca9b72d5fafc07c51854a42106f0d2e`;
the sorted Swift fixture manifest SHA-256 is
`3df8d887095e48de332d68d7bb80cfb7904b643bc02aa468875c940ca9abd305`.
The candidate extractor remains unmerged and P0 remains incomplete.

Revision 10 verification: the exact source line and anchor were checked for all
16 title-result cases; `bash scripts/ci/check.sh --only
phone-license,phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / PASS /
FAIL / PASS. The P0 failure remains open and these checks do not establish
extractor runtime conformance.

## Revision 11 — typecheck the item-destination fixture

The `navigation_item` fixture referenced `$selection` without declaring its
backing state. Add a `String?` `@State` property on the existing struct line;
the fixture still exercises the same `navigationDestination(item:)` child
and parent title, and its expected source line and anchor do not move. With
the iOS Simulator 27.1 SDK and arm64 iOS 18.4 target, the actual Swift compiler
now typechecks this fixture and its diagnostic AST selects SwiftUI's
`navigationDestination(item:destination:)` and `navigationTitle` methods.
This single compiler observation does not establish SwiftUI runtime behavior
or fix the other fixtures' missing build context.

The 48-case JSONL manifest is unchanged; the sorted Swift fixture hash manifest
is now `819f79f0efa38eef5e2217a0b08583d4280998999da4a16b60b939e03d0a430c`.
The owner contract remains at revision 9, and the extractor is still pending.

Revision 11 validation: `swiftc -typecheck` and `-dump-ast` against the stated
Simulator SDK → PASS for this fixture; `bash scripts/ci/check.sh --only
phone-license,phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / PASS /
FAIL / PASS. P0 and extractor implementation remain incomplete.

## Compiler-context feasibility, not conformance

A separate iOS Simulator 27.1 / Swift 6.4 typecheck experiment used the exact
48 fixture source files and individually recorded their bytes and arguments.
All 42 cases marked syntactically valid typechecked with their documented
fixture-only context; the six invalid-syntax cases were not typechecked in that
run. Three cases required synthetic model/directory values, one used the real
`NativeChatPreferences.swift` for `NativeText`, and one regex case required a
fixture-only `Int + Regex` overload. That overload changes symbol resolution;
the source without it failed typecheck and must not be presented as production
operator behavior. Three bare-regex cases required an explicit compiler flag.
The repaired `navigation_item` case typechecked without a companion.

A separate real probe-module AST experiment distinguished SwiftUI methods
from cross-file shadowing but did not prove which views reach output. The
compiler labels its AST dump format unstable; byte offsets require explicit
UTF-8-to-source mapping, and an AST for one build profile cannot represent
other conditional-compilation profiles. These observations do not freeze a
compiler-evidence format, authorize synthetic production context, establish
SwiftUI runtime behavior, or make the P0 gate pass. Any implementation needs
reviewed per-fixture context, complete build-profile inputs, proven output
dataflow and a versioned compatibility decision.
