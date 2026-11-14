<!-- SPDX-License-Identifier: MIT -->

# PC-20261114-bot-activity-evidence

```yaml
change: PC-20261114-bot-activity-evidence
contracts: [P09]
status: frozen
breaking: false
version_decision: No wire or durable value shape change; existing BotActivity fields only.
base: 7a11fd5b7bfb136a67a9ed70ba2d4f67ffa35973
contract_revision: spec/ui/v1/bot/ui-state.md@daf322120c5b108b9a0590d8857c021477f9af82
```

## 1. Roles and trigger

- Trigger: activity line cycles through unsupported generic prose, accepts arbitrary tool `summary`/`label`, loses concurrent pending calls, and Android live projection mishandles string arguments and events.
- Current: P09 `BotActivity` is `{status, detail, category, startedAt}`. iOS projection tracks a single last call/step/stream; Android producer and consumer independently project partial events.
- Expected: one event-driven projection per platform, producing the same existing P09 value shape; only semantically supported inputs or safe tool/target derivations may populate detail. No invented progress, wire member, or model request.
- Owner / implementer: this task agent, both. Reviewer/integrator: parent coordinator.
- Owning spec: `spec/ui/v1/bot/ui-state.md`, `activity-phrases.json`, `strings.json`; shared vectors in `golden/activity-phrase-vectors.json`.
- Producers/consumers: Swift `BotRuntimePresentationFactory` + `BotActivityPhrases`; Android `AppBotChatDriver`, `BotChatModel`, `BotActivityPhrases`.

## 2. Delta

- Remove timer-driven semantic phrase rotation. Stable waiting states read “等待响应” or “等待操作结果”; actual tool/stream/approval/terminal events drive changes. Text deltas use “正在回复”. Approval remains higher priority. Turn end/cancel clears activity.
- Tool detail comes only from `bash.description` and Task short title/description (not prompt), otherwise from the allowlisted tool mapping. A short, natural query/task topic may be used; file names, paths, extensions, URLs, commands, internal IDs and credential-shaped text are rejected rather than truncated. Ignore generic `summary` and `label`.
- Track unresolved calls by call ID and event order. Latest visible pending call wins; completion restores the newest still-pending visible call. New steps do not complete calls. FishAction is not displayed and does not hide another call. A result without ID closes a call only if exactly one is unresolved. Unknown IDs are ignored.
- Parse call arguments whether JSON object or encoded JSON string, matching the observed DSH 0.2.2-rc.1 form.
- No P09 schema, BotActivity serialized shape, P01 wire, or P27 row changes. Existing persisted presentations remain readable.

## 3. Compatibility

| Producer → Consumer | Decision |
| --- | --- |
| old → new | Existing event payloads accepted; projection becomes more conservative. |
| new → old | Same event/value shape; no compatibility change. |
| new → new | Same `BotActivity` encoding. |
| old persisted values → new / rollback | Existing optional fields decode unchanged; rollback sees existing shape. |

No version bump. Android app/lib access must stay within existing module visibility; if impossible without widening public API, stop and issue CCR.

## 4. Verification and work ownership

- Swift: shared activity vectors through real `BotRuntimePresentationFactory` behavior and existing app tests.
- Android: same vectors through pure projector and app event handoff; `BotChatModelTest` and app projection tests.
- Vectors include string/object args, serial success/error, A/B completion in reverse order, unknown result ID, new step while pending, hidden FishAction, stream versus pending call, approval precedence, turn end/cancel, unsupported description/summary, and long/sensitive targets.
- Exact commands and outcomes will be recorded at closeout. Device/model E2E remains `NOT_RUN` unless run explicitly.

## 5. Revision history

| revision | owner | reason | notified |
| --- | --- | --- | --- |
| 654ac8308339dd8a5f33c3e68e05d7f29f5a3bdd | task agent | Initial freeze before implementation | parent coordinator |

## Final scope override — user-directed iOS first

The root agent owns final implementation after the user's takeover request. The subsequent
user instruction explicitly deferred Android adaptation. Android exploration was preserved
outside this change; no Android source, shared phrase data, or shared checker is changed.
The final authority is `spec/ui/v1/bot/ios/activity-evidence.md` and its 53 regression vectors.
The iOS factory and `BotActivityEvidence` policy consume existing events and existing vocabulary;
all product activities get a stable concrete detail before the legacy timing layer. Shared
legacy APIs remain available for Android and compatibility tests. Persona guidance is corrected
without repurposing business fields. Integration base is main 360147635 after the rebase (includes PRs #171–#176).

Protocol impact: P09; P26; P16: none — generated persona prose only, no bootstrap/profile keys change; P27: none — no store, row, authorization, or action shape changes.

## Final observed evidence

Root completed the iOS-only implementation after reviewing the Grok archive and DSH event
contracts. 36 Swift logic tests passed on the rebased head, including all 53 event vectors;
the real UI capture harness built earlier and produced 8 light/dark activity screenshots from
simulated events (local artifacts, not committed). The persona prompt check passed
(`node plugins/bot-runtime/scripts/check-prompt.mjs`), as did protocol-impact, cross-tree
invariants (8/8), `phone-spec` and the shared Bot UI checker (491 checks) after the rebase,
which refreshed the BotChatModel anchors without changing string values. Actual device/model/
Worker deployment remains NOT_RUN. Android code is unchanged.

Reproduction: `xcodegen generate --spec scripts/ci/bot-activity-evidence/project.yml`, then
`xcodebuild -project scripts/ci/bot-activity-evidence/BotActivityEvidence.xcodeproj -scheme
BotActivityEvidenceTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`.
The dedicated logic target uses the real application source, without requiring a Worker
bundle or the unrelated full BotChatModel UI-host test target.

## Spoken-label refinement

Activity labels now omit technical targets and use short natural phrases, while retaining the
same event/call correlation. Valid short semantic search topics can be used; file/URL/code-like
inputs and overlong intent labels use a tool-kind fallback. Returned-result labels contain no
filename or concatenated technical separator. This only prepares text for later speech; no TTS
service, automatic announcement, extra model call, or event field is introduced.

Spoken-label validation: iOS logic target PASS (36 tests including 53 lifecycle vectors and new speech-label cases); persona tests PASS (8). Earlier native capture screenshots predate this wording-only refinement; TTS and true-device validation remain NOT_RUN.
