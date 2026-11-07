# Refresh five unchanged page contracts' source provenance

```yaml
change: PC-20261107-ui-page-provenance
contracts: [P09]
status: frozen
breaking: false
version_decision: Keep page-structure/1 and all semantic page behavior; refresh only locations and IDs derived from source lines.
base: 1b15d817
contract_revision: spec/ui/v1/pages/runtime-details.json@sha256:83dccd4b9db3f29d5b52ff595ef8e8a76c2cf1638ac05ef447260600a6144b4f; spec/ui/v1/pages/archived-sessions.json@sha256:40b0583674cb97556fb28ec02b2dfd553542c45028685a5e7b5cd424c616c1d5; spec/ui/v1/pages/font-size-settings.json@sha256:3bf70bc56046c4bbbbd72f2220de1fa9738821a119f15c2c603ecf6c4edf4d8c; spec/ui/v1/pages/conversation-settings.json@sha256:dcda83b3bbcedf38b67392a8b496eeb24c58e9095ffbc09f7a30e7831ea163c6; spec/ui/v1/pages/permission-defaults.json@sha256:55353490af0ab5068d62c9f72cd7e324779fda26a3f19dea884eccbac2b99aec
```

The current Swift sources moved five previously specified pages. Their owning
`spec/ui/v1/pages/{runtime-details,font-size-settings,conversation-settings,archived-sessions,permission-defaults}.json`
contracts were compared field by field with a fresh extractor run. This revision
updates source line numbers, line-derived IDs and cross-references, the
confirmation-dialog source span, and advisory render strings that embed line
numbers. The page titles, sections, rows, actions, states, conditions, targets,
write semantics and anchors are unchanged. The five full contract files are the
shared positive fixtures; the existing provenance and mutation checks remain the
negative fixtures. No UI or wire behavior, whitelist, unresolved entry or
baseline is modified. Protocol impact: P09.

The old contract with the new source and the new contract with the old source
fail the existing provenance checks; new/new aligns source anchors without a
runtime or on-disk application migration. Rollback restores these five files
with the corresponding source revision. The remaining nine stale/new pages are
not changed here: they include real UI changes, inactive conditional branches
and extractor defects tracked by GAP-19. This revision neither filters those
branches nor asserts Android parity.

Coordinator owns the five contract files and this record; no implementation or
other source is assigned. Acceptance: extract each named page with
`python3 spec/ui/v1/tools/extract_ios_pages.py --page <SwiftPage> --check`, run
existing UI checker/mutation tests and
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
Record each actual outcome; a successful per-page extraction cannot upgrade a
failing whole P0 gate to PASS.

## Verification

`python3 spec/ui/v1/tools/extract_ios_pages.py --page <SwiftPage> --check`
passed separately for RuntimeDetailsPage, FontSizeSettingsPage,
ConversationSettingsPage, ArchivedSessionsPage and PermissionDefaultsPage.
`python3 -m unittest discover -s spec/ui/v1/tools -p test_extract_ios_pages.py`
→ PASS, 28 tests. Other UI contracts and the full P0 gate remain open.
