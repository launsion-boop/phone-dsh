# Page source inventory completeness

Status: `implemented` for the source-inventory check only; it is not evidence of
Android parity or of the active iOS production build. The existing
`extract_ios_pages.py --check` must run as a mandatory part of
`phone-p0-conformance`, together with its own mutation suite. A discovered page
whose generated page contract is missing or stale, and a missing required
hand-registered chrome contract, must make the gate fail. Listing a name in the
README alone does not substitute for a structure contract. The existing
`page_structure_check.py` and all its provenance, parity, whitelist and
baseline checks remain mandatory and unchanged.

Page titles are subject to the owning-page and fail-closed ambiguity rules in
`page-title-ownership.md`; a title belonging to a destination cannot stand in
for its parent merely because its source occurs first.

The source inventory is deliberately broader than a production build: the
current extractor scans inactive conditional branches. A successful inventory
check therefore cannot prove that a feature is compiled, enabled, secure or
matched on Android. GAP-19 must be resolved by a separately frozen,
reproducible build-profile contract before claiming production parity; GAP-21
tracks additional semantic extraction limitations. Do not enable a target
feature, delete an existing fixture, extend the divergence baseline or suppress
an error to make this check pass.

`golden/page-completeness/FixturePage.swift`, its exact `fixture.json`, and
`cases.jsonl` are the shared source/contract scenarios. The real extractor's
`--check` must accept matching bytes and reject a missing page contract, a
changed source anchor, a newly declared unregistered page and a missing
hand-registered chrome contract. The real P0 stage must invoke both the
extractor's `--check` and its mutation tests, and retain every existing check.
