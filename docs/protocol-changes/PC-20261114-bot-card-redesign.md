# Bot card redesign / next-step refinement

Base: 8ab43b3d68c392a1ef51b33510c973683468ce66
Protocol impact: P09; P26; P16: none — only generated persona prose changes, profile keys and Worker bootstrap unchanged; P25: none — no event/store schema or journal behavior changes; P27: none — existing row storage, option IDs and authorization effects unchanged.

## Freeze

Owning contracts: spec/ui/v1/pages/bot-chat.md 2026-11-14 revision and
spec/bot/v1/cards.md §2. Shared vectors: card-payload.phone.json additions.

- Steps: exact non-action labels removed before recommendation and ID assignment, on both
  Swift and Kotlin. Existing raw/effective 2–4 limits and existing error unchanged.
- Input description remains accepted; only steps UI hides explanatory prose. Prompt tells
  the model to offer actual actions and not pad with skip/other/none. Question refusals remain.
- Card visual redesign follows approved local HTML; file previews use real existing metadata
  and bounded content only. No new transport fields, API methods or persisted shapes.
- Approval button highlight/copy does not widen grants. Scope session/none is explicit;
  none cannot authorize always. Receipts retain scope-specific semantics.
- Header redesign is a separate HTML proposal, not a native implementation in this change.

## Compatibility

Old producer → new host: unchanged shapes; exact filler steps are dropped; fewer than two
valid actions returns the existing effective-count error, allowing the model to retry.
New producer → old host: actionable labels already accepted; no new fields.
New → new: Swift/Kotlin share vectors. Stored old rows remain decodable and IDs unchanged;
no migration or rollback requirement. Old rows may still contain filler; do not reassign IDs.
No version bump: same schema and existing invalid-argument envelope, scoped normalization delta.

## Ownership and acceptance

- Root: spec/golden, Swift payload + prompt/catalog; integration review and header HTML proposal.
- Luna iOS: examples/probe-app/PhoneDSHProbe/Bot UI + associated UI tests.
- Luna Android: android UI + Kotlin payload (after freeze), Android tests.
- Checks: Swift BotCardPayloadTests using shared vectors; Kotlin BotCardPayloadGoldenTest;
  bot-runtime prompt check; affected native build/UI tests;
  scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree.

All runtime/device checks must be reported separately, including NOT_RUN/BLOCKED.

## Integration notes

- Contract additions committed at 47ea27e38 and 4791f1a6f; payload golden now covers
  recorded filler `暂停，稍后继续` plus case/whitespace normalization. Effective range stays 2–4.
- Persona assembly was stale in the base Worker profile. Regenerated only personaPrefix
  from the checked assembler; Chinese/English source prompts and profile now agree.
- Base 8ab43b3d6 had stale manifest hashes for mcp-rpc-cases.phone.json and
  tool-effects.phone.json. Their source bytes were verified unchanged against base;
  manifest digests were corrected, without changing fixtures or validation policy.
- Header work is available separately at docs/previews/bot-header-compare.html and is
  explicitly a simulated UI proposal using the user's current-header screenshot.

## Observed verification and limits

- PASS: `swift test --skip-update --filter BotCardPayloadTests` — 11 tests, including shared phone vectors.
- PASS: `node --test plugins/tests/bot-persona.test.ts plugins/tests/bot-team-persona.test.ts` — 8 tests; persona assembly check also passed.
- PASS: Android targeted Gradle `:bot:test --tests com.phonedsh.bot.cards.BotCardPayloadGoldenTest :lib:testDebugUnitTest --tests com.phonedsh.ui.bot.page.chat.BotChatPageTest` — 6 + 24 tests.
- PASS: iOS capture harness build and 24 UI interaction tests on the pre-polish revision. Final display-only changes rebuilt and captured steps/document/attachment/approval in light and dark (8 screenshots); final full interaction suite NOT_RUN.
- PASS: phone-spec and phone-cross-tree; protocol-impact declaration check; diff whitespace check.
- FAIL: phone-p0-conformance — baseline tokens.json references stale ChatPage.swift:5344; chat.json / phone-permissions.json have stale source references. Those contract/source files are unchanged from base. This is not an all-green gate.
- NOT_RUN: full production app/real-device/real-model end-to-end, deployed Worker image with the new prompt.
- Android previews consume existing row content/summary/TOC only; no new path-only file extractor was added. iOS text preview uses the existing bounded reader; PDF first-page preview is size-budgeted; unsupported/missing data stays explicit.
- Header/activity progress is HTML proposal only; native header behavior was not changed.

## Addendum: approved silver single-line activity UI

Base/head before addendum: eb42afc1c3ce53d6cc94c434e016b1dd85267bd6 (PR #171).
This supersedes the earlier header-proposal-only scope **only for** the subsequently
approved silver single passive line. The expanded activity-card prototype remains rejected.

Contract revision: spec/ui/v1/pages/bot-chat.md, silver activity subsection dated 2026-11-14.
P09 visual change; P27 has no data/state/permission/row semantics change. No version bump,
new fields, wire changes, persisted data, API signatures or dependencies. Existing producers,
consumers, stored rows and rollback all remain compatible.

Ownership: Luna edits iOS BotActivityLine.swift and headerStatus spacing in BotChatPage.swift;
Android activity renderer/spacing metrics plus focused tests. Root owns spec and PR metadata.

Acceptance: native build + targeted running/waiting light/dark screenshots; long-label and
single accessibility-label tests; quiet/problem/inactive/reduced-motion stop-animation checks;
Android targeted UI unit tests. Report unavailable device/animation evidence as NOT_RUN.
