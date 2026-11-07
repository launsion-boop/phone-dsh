# Page title ownership

Status: frozen contract; extractor implementation and runtime parity pending.
The `page-structure/1` title describes the owning page's navigation title,
not a title belonging to a pushed destination, presented sheet, or nested
screen. Its existing shape and provenance rules are unchanged.

For supported Swift source forms, the source extractor must distinguish the
page's own title modifier from modifiers inside a `NavigationLink` destination,
`navigationDestination`, or `sheet` content. In particular, a trailing closure
can be either a destination or a label depending on the call form. A child
title must never be selected merely because it appears first or is a literal
while the parent's title is dynamic. A page without a supported literal parent
title remains `title: null` under the existing `/1` representation.
An interpolated literal, ternary or other nontrivial dynamic expression is not
a static title merely because it contains a string literal; the existing
supported `NativeText` form keeps its established source representation. If a
literal's escaping cannot be decoded reliably, fail rather than invent text.

Lexical classification must ignore fake syntax in ordinary and Swift raw
strings (including multiple-hash and multiline delimiters) and comments,
preserving source offsets and line numbers. A comment inside a title argument
cannot supply its label. Unterminated raw strings fail visibly. Because the
structural mask is shared by the extractor, a change to it must also be checked
against the existing row, action and source-provenance fixtures and the full
repository extraction diff; it is not confined to title metadata.
Unbalanced structural delimiters and invalid Swift string escapes anywhere in
the analyzed source must fail rather than yielding a partial page title;
supported escapes must preserve the rendered title and original anchor.

Swift extended regex literals (`#/.../#` and multiple-hash variants) are also
lexical boundaries, including embedded fake title syntax; an unterminated
extended regex fails. Bare-slash regex interpretation depends on compiler
profile and cannot be assumed from raw source alone: when that ambiguity can
affect title ownership, fail rather than guess. Ordinary arithmetic division
must not be treated as a regex. This does not resolve GAP-19's build-profile
problem or claim a complete Swift parser.

When source ownership or precedence is not established, including multiple
potential page titles, conditional compilation ambiguity, title modifiers in
label/toolbar contexts, unrecognized presentation boundaries containing a
title, or malformed source, the extractor must fail visibly instead of guessing
a title or silently returning null. This raw-source check does not determine an
active build profile, runtime SwiftUI preference propagation, Android parity,
or the presence of security controls. GAP-19 and GAP-21 remain open.

`golden/page-title/cases.jsonl` and its referenced Swift sources are the shared
positive and negative cases; `schema/page-title-cases.schema.json` defines
their shape. A successful title case requires the exact existing `text`,
`provenance` and `anchor` values. Tests must run the real extractor over each
source and must demonstrate through its real CLI check that ambiguous input
fails. Existing page contracts, fixtures, parity checks and baselines may not
be deleted, hidden or relaxed to make this rule pass.
