# PC-20261114-bot-activity-call-lifecycle

```yaml
change: PC-20261114-bot-activity-call-lifecycle
contracts: [P09]
status: frozen
breaking: false
version_decision: Existing BotActivity value shape and event encoding; no wire or persistence change.
base: eb42afc1c3ce53d6cc94c434e016b1dd85267bd6
contract_revision: pending-own-document-commit
```

## 1. Trigger and roles

- Trigger → current → expected: event consumers infer one last call/step/stream; Android producer and consumer independently project incomplete event subsets → one event lifecycle authority per platform maintains unresolved calls by call ID within turn/session, restores the newest still-pending visible call after out-of-order results, and applies identical semantics at producer and consumer.
- Contract owner and implementer: this task agent. Reviewer/integrator: parent coordinator.
- Owning contract: P09 `spec/ui/v1/bot/ui-state.md` §4.8 and this frozen change record. Shared lifecycle vectors: `spec/ui/v1/bot/golden/activity-call-lifecycle.phone.json`.
- Ends: iOS app runtime projection and ChatModel live-stream priority; Android `:lib` consumer and `:app` event producer. Both Android paths call one pure projector in `:lib`.

## 2. Delta

| Item | Frozen behavior |
| --- | --- |
| Fields/encoding | No event field, wire field, or serialized `BotActivity` shape change; remains `{status,detail,category,startedAt}`. |
| Correlation/order/terminal | Keep visible unresolved calls keyed by call ID in event order, scoped to session and turn. The newest unresolved visible call supplies activity. Only its matching result completes it; an ID-less result may complete only when exactly one call is unresolved and there is no known unmatched ID. Unknown IDs are ignored. A new step does not clear calls. Turn end, cancellation, or session change clears that scope. |
| Concurrent calls | With A then B outstanding, completion of B restores A. Reconstruct from available event history on re-entry/reconnect, using the same projector. |
| Inputs | `tool/call.arguments` accepts a JSON object or a JSON-encoded string. `tool/result.message.isError` determines failure; non-empty result content does not assert task success. A call denotes a request in flight, not successful device execution. |
| Visibility/priority | Hidden `FishAction` never replaces or masks a visible call. Approval presence remains highest priority. Genuine assistant text delta/stream is replying; pending tool activity has precedence over generic `isStreamingNow` fallback. `step/start` with no pending tool waits for model response, not replying. |
| API | Android adds a public pure projector helper in `:lib` so existing `:app` and `:lib` consumers share one authority. This is an additive source API within the existing module dependency; no new dependency. Any short neutral lifecycle labels are private stable literals and documented here. |

No changes to phrase data, strings, UI renderers, or event serialization. P09 remains implemented at the value-shape boundary; this lifecycle rule is implemented by the changed app projections once regression evidence passes.

## 3. Compatibility

| Producer → Consumer | Decision |
| --- | --- |
| old → new | Accept existing events and shapes; object and encoded-string arguments are supported. |
| new → old | Same event and activity shapes; older consumers continue decoding, though they may retain prior projection defects. |
| new → new | Shared semantics, same value encoding. |
| persisted old data → new / rollback | Existing presentation values remain decodable; no migration. Rollback reads the same shape. |

No version bump. There is no separate deployed producer protocol: app/lib revisions ship as one application. Re-entry projection uses the existing event history; no extra persisted lifecycle record is introduced.

## 4. Work ownership and acceptance

- Exclusive implementation paths: `examples/probe-app/PhoneDSHProbe/Bot/BotRuntimePresentation.swift`, `BotChatModel.swift`; `android/lib/src/main/kotlin/com/phonedsh/ui/bot/driver/BotChatModel.kt`; `android/app/src/main/kotlin/com/phonedsh/probe/bot/AppBotChatDriver.kt`; new projector/test/golden files dedicated to lifecycle.
- Excluded paths: phrase implementations/data, existing phrase goldens/checker, UI renderers, persona/profile, shared research and A's freeze document.
- Shared golden scenarios: object/string arguments; A/B and B-before-A completion; unknown/missing result ID; step during pending; hidden FishAction; stream/pending precedence; approval; error result; turn end/cancel/new turn isolation; history reconstruction.
- Runtime checks: Swift pure projection harness and Android targeted unit tests must execute the real projector against the shared JSON. Android producer and consumer must call the same helper. Exact commands/results and unavailable environments are recorded at closeout. Device/model E2E remains `NOT_RUN` absent execution.

## 5. Revision history

| revision | owner | reason | notified |
| --- | --- | --- | --- |
| pending-own-document-commit | task agent | Freeze lifecycle projection before implementation | parent coordinator |

## User scope override (final)

The later user instruction supersedes the Android implementation/API scope above: **iOS only**.
No Android public helper or producer change is included. Root owns the final implementation;
`spec/ui/v1/bot/ios/activity-evidence.md` is the current normative refinement and
`spec/ui/v1/bot/ios/activity-evidence-vectors.json` is its executable fixture set. Existing
shared phrase/data schemas and Android contracts are retained, not weakened or skipped.
