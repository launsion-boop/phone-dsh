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
