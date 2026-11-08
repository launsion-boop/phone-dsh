# Candidate: P09 page-title compiler evidence

Status: **candidate only; not a contract freeze or an implementation**. Protocol
impact: P09. This candidate does not authorize changing the extractor, a page
contract, the P0 gate, a baseline, or target
features. The current owner contract is
`spec/ui/v1/page-title-ownership.md`; the frozen title vectors are
`spec/ui/v1/golden/page-title/cases.jsonl`. See the build-profile and dynamic
page-title CCRs and baseline GAP-19, GAP-21 and GAP-27.

## Observations and limits

The existing source extractor chooses the first matching title literal in a
page's live lexical scope. It cannot establish that the receiver is a SwiftUI
view, a SwiftUI modifier, or a view reaching page output. Swift source alone
cannot rule out a different declaration in another file or imported module.
A separate read-only run of all 48 frozen fixture sources through the real
`Source` and `PageExtractor.run` matched 9 expected outcomes and mismatched
39 (16 expected title, 4 expected absent, 28 expected error in the complete
fixture set). This was a source-extraction experiment, not a compiler run,
real UI observation or cross-platform parity test. The existing spec-golden
fixture test validates schema and references; it does not exercise the real
extractor for these title outcomes.

The repository records earlier synthetic compiler experiments and their
limitations in `PC-20261107-page-title-ownership.md`: 42 valid fixture sources
were typechecked with individually recorded fixture-only context, some with
synthetic declarations or a flag; a real probe-module AST distinguished a
cross-file shadowing case but did not prove output reachability. Those past
experiments do not prove this candidate, current production title ownership,
a selected production profile, or runtime SwiftUI behavior. Preparing this
document performed no production build or target-function execution.

For local tool inventory only, Xcode reports 27.1 build 27A9275,
iphonesimulator SDK 27.1, and Apple Swift 6.4; `sourcekit-lsp` exists. Their
presence does not establish their behavior for this design, and these values
are not a selected or validated toolchain profile.

## Candidate scope and profile

Keep the raw source inventory covering both Swift conditional branches. Add a
separate, explicitly named compiler-context projection for a chosen actual app
target; it must not be used to hide inactive pages or bypass the existing raw
inventory, completeness, parity and mutation checks. A Release profile can be
an initial example: Xcode scheme and target `PhoneDSHProbe`, iOS Simulator,
arm64, minimum iOS 17.0, signing disabled, with target/task flags and shell
variables explicitly controlled. The project declares Swift 5 language mode
and iOS 17.0, but this proposal does not assume the effective target flags or
module graph from `project.yml` alone. Confirm exact resolved settings,
source files, Swift frontend arguments, dependencies, and command overrides
from the actual selected build. Simulator Release is a scoped test profile,
not proof of a physical-device or other configuration's behavior.

`Package.swift` changes its graph when `PDSH_WITH_XZSHELL` or `PDSH_WITH_SHELL`
is set and the shell XCFramework exists. Freeze the values and actual graph,
including whether the artifact is present. The Xcode workspace package-lock
separation described by P24 was frozen but its isolation implementation was
not established in the recorded review; current `git ls-files` lists only the
root `Package.resolved`. Do not claim a complete locked Xcode graph or allow a
resolver to rewrite the user's root lock without separately resolving P24.

## Proposed evidence production and consumption

Work in an isolated snapshot that includes the exact relevant tracked, edited,
untracked and generated inputs, without modifying the user's checkout or
locks. Resolve or verify dependencies according to an independently frozen
P24-compatible workflow. Capture the selected target's effective build
settings and actual Swift frontend invocations from the generated project, not
merely configuration defaults or a manually reconstructed command. Source
analysis/typecheck may compile source and inspect generated compiler artifacts;
it must not launch the app or invoke target page or task functionality.

A candidate reader can consume a version-specific typed compiler AST together
with exact source bytes. For each recognized navigation modifier and
presentation boundary, it must establish both:

1. The resolved declaration is the intended SwiftUI declaration and overload,
   including relevant closure labels, rather than a locally, cross-file or
   externally shadowing declaration.
2. The modified view reaches the owning page's returned output through a
   formally supported expression chain from its `body` (including a directly
   returned supported `some View` helper). Identifier occurrence, receiver
   type, or AST containment alone is insufficient.

This demands a conservative, explicitly frozen set of output-dataflow cases.
For an unsupported result builder, conditional, helper, method chain, recursion,
dynamic dispatch, multiple candidates, unknown declaration, incomplete module,
or malformed or ambiguous source, return an observable extractor error, not
`title: null` and not a guessed literal. A successfully resolved call to a
non-SwiftUI shadow is not evidence of a SwiftUI modifier. Separately, preserve
all frozen behavior for child destinations, dynamic expressions, lexical
boundaries, helper cases and exact provenance.

Swift's text AST dump is not a stable interchange format. If selected, pin the
exact toolchain, recognize only reviewed node/declaration shapes, verify source
ranges and context, and reject unknown formats. Evaluate a supported semantic
API only after proving the required overload identity and output-flow behavior;
the availability of `sourcekit-lsp` alone proves neither. Compiler symbol
resolution does not by itself prove SwiftUI runtime preference propagation.
UTF-8 byte offsets must be mapped to source lines and existing `anchor` values
without confusing bytes and Unicode scalars. Evidence must reject inconsistent
or ambiguous mappings.

## Binding and invalidation

The owner must define a versioned evidence format, canonicalization rules, and
exact independently verifiable input closure. At minimum bind actual invocation
arguments and ordering; target, scheme, module, platform, architecture, SDK and
language/compiler versions; all active conditions; XcodeGen inputs, generated
project, xcconfigs and effective settings; source membership, paths and bytes;
generated sources and declared generators; module interfaces and resolved
dependency graph and bytes; relevant macro/plugin inputs; include/search paths;
command-line overrides; and every relevant environment or filesystem input.
Resolve symbolic links and path identity under explicit rules. A newly added,
removed, renamed, untracked, generated, or changed source file can introduce a
shadow and must invalidate the evidence even when the original page file is
unchanged. Changes to toolchain, flags, profile, SDK, lock, dependency, source
membership or generator inputs must similarly invalidate it. Unknown flags,
unavailable inputs, stale or incomplete closure, changed toolchain, or unknown
evidence format must fail closed.

A digest only binds stated bytes; a hand-written result plus its own digest is
not proof that a compiler actually produced the result or that the input list
is complete. Specify who regenerates and verifies evidence, how all relevant
inputs are discovered and checked, what tool behavior is trusted, and whether
an authenticated or reproducible artifact may be consumed where Xcode is not
available. A non-macOS consumer that cannot verify the chosen proof must report
incomplete/failure rather than invent evidence or silently skip it. Prevent
validation/consumption time-of-check/time-of-use drift, for example by binding
both steps to the same immutable snapshot; details require review.

## Shared fixtures and acceptance proposal

The 48 existing frozen fixture cases contain 42 `syntax: valid` and 6
`syntax: invalid`. Their manifest does not yet freeze all compiler context.
Before making compiler evidence normative, independently review and freeze
per-fixture source companions and flags. Synthetic models, `NativeText`
companions, bare-regex flags or test-only overloads apply **only** to the
particular fixture context; they must never be supplied to the production app
or treated as proof of its compiler profile. Invalid syntax should be rejected
by the actual extractor; failure to locate an SDK or compiler is not a passing
negative case.

The real extractor test should iterate the entire manifest with isolated cases,
assert the case count and unique names, and call the real `Source`,
`PageExtractor` and `page_structs`. A `title` case compares the complete
`text`, `provenance` and `anchor` object; `absent` requires actual null; an
`error` case requires `ExtractError`, not an unrelated exception. Add real CLI
checks in an isolated minimal fixture tree: a known matching source and frozen
contract returns zero, while an ambiguous title returns the specified extraction
error (currently CLI uses status 2), not status 1 from a missing/stale JSON.

A future freeze should add shared valid and invalid cases proving at least:

- Cross-file and imported shadow declarations, including a same-named
  `navigationTitle` extension, contrasted with actual SwiftUI resolution.
- Directly returned helper versus unused, discarded, argument-only, chained or
  conditionally unproven views; unsupported paths fail closed.
- Active versus inactive build conditions, changed flags/profile, escaped and
  raw strings, regex ambiguity and UTF-8 source offsets.
- Changed source membership, generated input, dependency, compiler version,
  flags, missing context, malformed/untrusted evidence and unknown AST node.
- Negative proof that a fixture-only companion or compiler flag cannot enter
  the actual application profile.

Run existing extractor and checker mutation suites, the 48 scenarios through
the actual extractor, CLI positive/negative cases, and the full source
extraction field diff without regenerating or weakening stored contracts.
Run `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
and report each stage independently. Compiler/source cases do not prove
SwiftUI rendering, Android Compose output, OS/device behavior, security controls
or feature readiness. A successful profile analysis cannot close GAP-19,
GAP-21 or GAP-27 without their distinct required evidence.

## Decisions required before a freeze

- Which real target(s), configurations, SDK versions, architecture(s), flags,
  and fallback behavior constitute required coverage? Is Release simulator
  useful as an initial restricted profile, and how are other profiles tracked?
- How are the generated project, complete dependency graph and root/Xcode
  lock isolation obtained without conflicting with the unresolved P24 work?
- What exact compiler API, toolchain version, AST node grammar and bounded
  output-dataflow subset are normative? How are imported and cross-file
  overloads and unsupported language constructs treated?
- Who can create the evidence, how is full input closure established and
  authenticated, and what is allowed when an Xcode-capable verifier is absent?
- What schema/version and stale-evidence behavior are used, and how do old
  producer/new reader, new producer/old reader, old saved data and rollback
  interoperate? `/1` conflates absent and dynamic titles; it cannot silently
  be reinterpreted as proof of either.
- How will GAP-27 separately freeze state-dependent title values and compare
  actual iOS/Android behavior? `MCPEditorPage` and `FilesPage` have dynamic
  titles and cannot be refreshed to null merely to eliminate stale checks.
- How will raw source inventory and this profile-specific projection both run
  without calling target features or claiming inactive branches are production?

Until these decisions, a committed owner revision, reviewed shared valid and
invalid fixtures, implementation on all affected ends, and actual acceptance
results exist, this document remains a candidate and P0 remains failing.
