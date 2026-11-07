# CCR: preserve dynamic page-title parity

```yaml
change: PC-20261107-dynamic-page-title-ccr
contracts: [P09]
status: draft
breaking: pending
version_decision: pending
base: e2cdcd6d
contract_revision: pending
```

The existing `page-structure/1` source extractor uses `title: null` for both
an absent page title and a dynamic title. `page_structure_check.compare_title`
returns `status: none` for null and performs no Android title comparison.
The title-ownership correction exposes this in real `FilesPage` and
`MCPEditorPage`: their iOS titles are conditional expressions, while the old
extractor guessed a single literal. Replacing their existing contracts with
null just to remove stale checks would silently discard a parity assertion.
The source changes and Android runtime parity have not been implemented here.

The existing `dynamic-both` comparison is also insufficient: it accepts an
Android dynamic expression on the basis that the Swift anchor looks dynamic,
without proving that their states produce matching labels. The Files pages use
different path operations, which disagree on some noncanonical inputs, and the
Android MCP editor includes an unreadable-target state absent from the iOS
title condition. These require explicit input-domain and platform decisions;
neither expression's mere presence establishes parity.

Before either page contract is refreshed, the owner must freeze how absent,
literal and dynamic titles are represented, their source provenance, state
dependencies, Android comparison, unknown/unsupported expressions, old reader
compatibility and rollback. Shared positive and negative fixtures must exercise
the real iOS extractor and actual Android title behavior across relevant states;
ambiguous or unmeasured cases fail closed. Do not extend an allowlist, suppress
the old assertion or call source-only extraction a runtime parity result. The
separate lexical/title-ownership contract remains valid but does not close
GAP-27 or the eight existing missing/stale P0 contracts.
