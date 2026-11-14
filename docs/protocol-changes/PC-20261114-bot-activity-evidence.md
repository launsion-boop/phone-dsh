<!-- SPDX-License-Identifier: MIT -->

# PC-20261114-bot-activity-evidence

```yaml
change: PC-20261114-bot-activity-evidence
contracts: [P09]
status: frozen
breaking: false
version_decision: No wire or durable value shape change; existing BotActivity fields only.
base: eb42afc1c3ce53d6cc94c434e016b1dd85267bd6
contract_revision: 654ac8308339dd8a5f33c3e68e05d7f29f5a3bdd
```

## 1. Roles and trigger

- Trigger: activity line cycles through unsupported generic prose, accepts arbitrary tool `summary`/`label`, loses concurrent pending calls, and Android live projection mishandles string arguments and events.
- Current: P09 `BotActivity` is `{status, detail, category, startedAt}`. iOS projection tracks a single last call/step/stream; Android producer and consumer independently project partial events.
- Expected: one event-driven projection per platform, producing the same existing P09 value shape; only semantically supported inputs or safe tool/target derivations may populate detail. No invented progress, wire member, or model request.
- Owner / implementer: this task agent, both. Reviewer/integrator: parent coordinator.
- Owning spec: `spec/ui/v1/bot/ui-state.md`, `activity-phrases.json`, `strings.json`; shared vectors in `golden/activity-phrase-vectors.json`.
- Producers/consumers: Swift `BotRuntimePresentationFactory` + `BotActivityPhrases`; Android `AppBotChatDriver`, `BotChatModel`, `BotActivityPhrases`.

## 2. Delta

- Remove timer-driven semantic phrase rotation. Stable waiting states read “等待模型响应” or “等待工具返回”; actual tool/stream/approval/terminal events drive changes. Text deltas use “正在回复”. Approval remains higher priority. Turn end/cancel clears activity.
- Tool detail comes only from `bash.description` and Task short title/description (not prompt), otherwise from the allowlisted tool mapping and safe target metadata (filename/domain/query/task title). Ignore generic `summary` and `label`; redact commands, tokens, internal IDs, and URL query.
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
The final authority is `spec/ui/v1/bot/ios/activity-evidence.md` and its 43 regression vectors.
The iOS factory and `BotActivityEvidence` policy consume existing events and existing vocabulary;
all product activities get a stable concrete detail before the legacy timing layer. Shared
legacy APIs remain available for Android and compatibility tests. Persona guidance is corrected
without repurposing business fields. Integration base is main 203c29bcb (including PR #171).

Protocol impact: P09; P26; P16: none — generated persona prose only, no bootstrap/profile keys change; P27: none — no store, row, authorization, or action shape changes.
