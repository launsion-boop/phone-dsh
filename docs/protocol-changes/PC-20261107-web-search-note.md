# Align the model-search explanatory note

```yaml
change: PC-20261107-web-search-note
contracts: [P09]
status: frozen
breaking: false
version_decision: Preserve page-structure/1; update the existing row, without changing any persisted setting or wire format.
base: b1b37d17
contract_revision: spec/ui/v1/pages/web-search-settings.json@sha256:12639a86120067429d694111748c4fd3dc46f60449a494559d765638a0ed0c97
```

The iOS source now says that following the model shares the official DeepSeek
model key for web search and fetch; the page contract and Android still display
the old note. Freeze the iOS text and its source anchor in the existing page
contract. Android must display that exact note in its existing notes section.
This changes one visible sentence and its derived row ID only; it does not add a
capability, enable independent search, change key storage, or assert that the
rest of the page is at parity. Android's host currently exposes follow-model
read-only while iOS can configure independent search.

Old apps keep displaying their old text, new apps display the new text; settings,
data and transport are unchanged. An old contract is stale against the new iOS
source; the new contract is stale against the old source. Rollback restores the
contract and Android text together. Existing provenance mutation tests exercise
rejection of stale source anchors. The full page JSON is the shared positive
fixture and the old sentence is the negative case: Android tests must obtain the
expected label from that JSON, drive the actual page, and demonstrate that the old
sentence is absent, instead of comparing a constant to itself. No duplicate
schema, whitelist, baselines, or platform conditions are changed.

Coordinator owns `spec/**` and this record. Android implementer owns only
`android/lib/src/main/kotlin/com/phonedsh/ui/UiStrings.kt` and the relevant
`android/lib/src/test/kotlin/com/phonedsh/ui/page/WebSearchSettingsPageTest.kt`.
Freeze this revision before implementation. Acceptance: the real extractor's
`--page WebSearchSettingsPage --check`, existing P09 provenance mutations, the
actual Android page test, and the standard contract gates. Report skipped Android
toolchains, stale unrelated pages, and remaining runtime/parity gaps explicitly.

## Verification at ba1b6947

`python3 spec/ui/v1/tools/extract_ios_pages.py --page WebSearchSettingsPage --check`
→ PASS. The Android source text matches the unique frozen JSON row; the actual
Compose test was started but its Gradle toolchain was still downloading, so its
runtime result is pending. `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS; P0 now
reports eight other missing or stale page contracts. This does not prove overall
Android page parity or any physical-device behavior.
