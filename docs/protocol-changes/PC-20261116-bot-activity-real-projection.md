<!-- SPDX-License-Identifier: MIT -->

# PC-20261116-bot-activity-real-projection

```yaml
change: PC-20261116-bot-activity-real-projection
contracts: [P09, P26, P27]
status: frozen
breaking: false
version_decision: No wire, event, durable-value or schema change. Existing BotActivity fields and existing DSH tool arguments only. Prompt text is packaged into the Worker image, so a prompt change still requires the supported packer and real-runtime evidence for that image.
base: 908d582b9ee91886ba197bebd54b863c8093cced
contract_revision: activity-evidence-v2.3
```

## 1. Roles and trigger

- Trigger (user ruling, 2026-11-16): the iOS Bot activity bubble mostly replays a fixed
  status cycle. `BotActivityEvidence.action` calls the shared phrase table with empty
  arguments, then a 30-entry fallback table overwrites every known tool with
  "读取相关资料 / 执行当前操作 / 已收到…结果". The real `tool/call` arguments already
  contain the file path, pattern, query, URL, task title and call IDs, but they never reach
  the bubble. The two system prompts additionally forbid file names, paths, URLs and
  PR-like objects in activity text. The user requires the current task's real content to
  reach the bubble; preset states, privacy expansion, Android, LED/voice/notifications,
  Fleet and a plan manager are out of scope.
- Current at base: `BotActivity` is `{status, detail, category, startedAt}`;
  `BotRuntimePresentationFactory.activity` tracks calls by `callId` but derives every label
  from tool kind only; `resultText` replaces the last real sentence with a receipt;
  `spokenIntent` rejects `#`, `/`, `.`, `:`, `@` and every sentence over 16 CJK characters.
- Expected: the existing event stream and existing arguments produce a real sentence for
  the current visible call; model intent only fills `detail`; lifecycle stays event-driven;
  a result keeps the call's own sentence instead of a receipt; paths, URLs, PR numbers and
  names remain recognisable; long text is truncated visually, not erased, and the bubble stays non-interactive.
- Contract owner / coordinator: lead (`session-02a9d7bf-ed67-4db8-b773-33efb3733f24`).
- Implementers: runtime lane (`plugins/bot-runtime/**` prompts + source-coverage doc),
  projection lane (`BotRuntimePresentation.swift`, shared vectors consumer tests), UI lane
  (`BotActivityBubble.swift`, `BotChatPage.swift`, tests). Reviewer: review lane, on the
  combined head only.
- Owning spec: `spec/ui/v1/bot/ios/activity-evidence.md` (this revision), plus
  `spec/ui/v1/bot/ios/activity-evidence-vectors.json` as the shared valid/invalid oracle.
  `spec/ui/v1/bot/ui-state.md` §10 points at it. `activity.schema.json`,
  `activity-phrases.json`, `strings.json` values and all P27 row/schema files stay unchanged.

## 2. Contract delta

| Item | Before → After |
| --- | --- |
| fields / encoding / limits / default / null | Unchanged `{status, detail, category, startedAt}`. `detail` now carries one real task sentence (bounded at 512 characters, 511 + `…`) instead of a category phrase or receipt. Priority is per-call intent > same-turn/same-step public task progress > real argument object + action > minimal fallback. |
| capability / version / unknown field / unknown method / unknown enum | No wire capability, version, event kind, tool method or enum added. Unknown visible tools still show "等待操作结果"; hidden `FishAction` still correlates only. |
| correlation / sequence scope / ordering / terminal outcome | Unchanged: `seq` + stable arrival, latest open turn, `callId` correlation, explicit old-turn isolation, duplicate call IDs ignored, ID-less result closes only a single unambiguous outstanding call. |
| error code / retryable / deadline / cancel / late response | No new code. A failed result shows "这步遇到问题"; a late/unknown/conflicting result closes nothing. Stop/turn-end behaviour unchanged. |
| idempotency / side effect / ACK / durability / recovery | Unchanged. `detail` is presentation-only and never proves execution, completion or business success. Durable and live projections consume the same events. |
| origin / auth / scope / path / redaction / backpressure | No new origin/auth surface. Only existing credential shapes are rejected from display text (Bearer, key assignments, `sk-`/`ghp_`/`xox`/`AKIA` tokens); file names, paths, URLs, `#PR`, names and normal punctuation are explicitly allowed. URLs drop userinfo and sensitive query parameters when displayed. |
| clause status change | `activity-evidence.md` moves from the 2026-11-14 category-only refinement to `activity-evidence-v2`; no target/draft clause is promoted. |
| structural plan / steps | Not added. No `stepIndex/stepCount`, no free-text "n/m" parsing, no extra model request, no activity tool. |

### 2.1 Why no new metadata field (decision)

The runtime audit proposed an optional `activity` argument on every tool, shadowed through
a phone-owned wrapper and stripped before the handler. This revision **rejects** that
option:

- Pinned DSH `tool/call` arguments are the model's original JSON; the pinned `bash`
  `description` is already required and carries a real per-call sentence, and every
  native file/search/web tool already carries its real object argument
  (`file_path`, `pattern`, `url`, `queries[]`). The pinned agent loop appends the
  `assistant/message` for a step before that step's `tool/call`, so the same-turn,
  same-step public progress sentence is available without a new field. Live text
  deltas in the step are accumulated and the durable message replaces the
  accumulation; a single delta is not a sentence.
- Phone MCP `Task` already carries `task_title` / `description`, and card/memory tools
  already carry `title` / `path` / `query` / `detail`.
- Adding a field would create a second protocol surface, change argument digests in the
  identity/approval path, and require stripping in every handler. The user explicitly
  asked not to add metadata for form when real fields suffice.

The coverage fact is recorded in `plugins/bot-runtime/ACTIVITY-SOURCES.md` (runtime lane):
for each visible tool, the existing field that carries the real object; builtins with no
intent field rely on the same-turn/same-step public task progress first, then on their
object argument; this default applies to every visible work tool, including unknown MCP,
memory, routine, job and goal tools. Only card/messaging tools and hidden FishAction are
excluded. A public-progress candidate is cleared by `step/start`, `tool/call`,
`tool/result`, `turn/start` and `turn/end`; reasoning/analysis channels, earlier steps,
earlier calls and earlier turns are never reused.

## 3. Compatibility and release

| Producer → Consumer | Decision |
| --- | --- |
| old event stream → new projection | Full support. Only existing `tool/call`, `tool/result`, `turn/*`, `step/*` and `assistant/*` members are read; missing/legacy IDs keep the documented rules. |
| new projection → old UI / old client | Value shape is unchanged. Any client that renders `detail` shows the real sentence; any client that still uses the legacy phrase table is unaffected. |
| new → new | One reducer path for durable `make` and live frames; the same event set must produce the same `BotActivity`. |
| persisted old rows / rollback | No migration. Old rows contain the old strings; rollback renders them. No new key, column or schema. |

No wire or native-artifact version bump and no DSH pin change. The double-language prompts
are read from the plugin package at Worker build time, so the Worker image must be rebuilt
with the supported packer and the real runtime must be shown to use the new prompt before
this change is called integrated. If `plugins/node_modules` or the pinned DSH checkout is
missing, packing and runtime evidence are `NOT_RUN`, not `PASS`. No push, merge or deploy
is part of this task; the final head and PR draft are handed to the root operator.

## 4. Work ownership and evidence

Disjoint paths; only the lead edits `spec/**` and this record. Workers cherry-pick the
contract commit before implementing.

- runtime: `plugins/bot-runtime/prompts/system-prompt.zh-CN.md`,
  `plugins/bot-runtime/prompts/system-prompt.md`, `plugins/bot-runtime/ACTIVITY-SOURCES.md`,
  `plugins/tests/bot-persona.test.ts`. Scope: remove the "no file names/paths/URLs"
  prohibition, keep `bash.description` / `Task.task_title` guidance, align "等待响应",
  state that no extra status tool/metadata field is added, and record the real tool-source
  coverage from pinned DSH. Commands: `cd plugins && node scripts/run-tests.mjs
  tests/bot-persona.test.ts` (NOT_RUN if deps absent).
- projection: `examples/probe-app/PhoneDSHProbe/Bot/BotRuntimePresentation.swift`,
  `scripts/ci/bot-e2e/app/TestsChatModel/BotActivityLineTests.swift`,
  `scripts/ci/bot-e2e/app/TestsChatModel/BotChatModelTests.swift` and any existing
  projection test in that target. Scope: real-object reducer, per-call sentence memory,
  public-text fallback, no receipt, no new `BotActivity` field. Commands:
  `xcodegen generate --spec scripts/ci/bot-activity-evidence/project.yml` → `xcodebuild
  -project scripts/ci/bot-activity-evidence/BotActivityEvidence.xcodeproj -scheme
  BotActivityEvidenceTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`.
- ui: `examples/probe-app/PhoneDSHProbe/Bot/BotActivityBubble.swift`,
  `examples/probe-app/PhoneDSHProbe/Bot/BotChatPage.swift`, and the capture/UI tests that
  own the bubble. Scope: keep one 32pt band, one-line tail truncation, the band hit-transparent and the
  bubble non-interactive; accessibility label keeps the full sentence. No tap target,
  sheet or extra control.
  Commands: the evidence target above plus `bash scripts/ci/bot-ui/capture.sh
  --appearance light` (XCUITest runner may be NOT_RUN in the sandbox; do not report PASS).
  The only UI acceptance is a non-interactive one-line bubble with the real object in
  its text/accessibility label; no expansion surface is exercised.
- review: own evidence/reproducers only; no source edits. Validates the combined head:
  a real model task's session log (`request/header` provider/model/reasoningEffort,
  `tool/call` arguments with real objects, matched `tool/result`) is replayed through the
  real reducer and the visible-text path, with a second differing task to reject
  hard-coding.

Shared fixtures: `spec/ui/v1/bot/ios/activity-evidence-vectors.json`. The Swift test must
load it and run `BotRuntimePresentationFactory.live`/`make` plus
`BotActivityEvidence.lineActivity`, not a hand-written copy. Invalid cases (credential,
completion claim, generic filler, unknown/conflicting IDs) are in the same file.

Gates: `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
for the contract; `phone-plugins` for prompt/test changes; `phone-hygiene` and
`phone-license` for the final tree. The Xcode evidence target is the runtime projection
gate. Missing toolchains are `SKIP`/`NOT_RUN`, never `PASS`. `strings.json` source anchors
will be refreshed by the lead at integration if UI edits shift them; values do not change.

## 5. Revision history

| revision | owner | reason | notified |
| --- | --- | --- | --- |
| activity-evidence-v2 (this commit) | lead | Initial freeze after four lane audits; real-object projection with no new metadata field | runtime / projection / ui / review sessions |
| activity-evidence-v2.1 | lead | Clarify that public text is accumulated from text-channel deltas and replaced by the step assistant/message; no interface or vector-shape change | runtime / projection / ui sessions |
| activity-evidence-v2.2 | lead | User ruling: the bubble stays non-interactive; remove the tap/full-view requirement. No reducer, vector or transport change | runtime / projection / ui / review sessions |
| activity-evidence-v2.3 | lead | Coverage ruling: public same-step progress is the default for every visible work tool, including unknown MCP and memory tools; card/messaging/hidden tools are explicit exclusions. Adds two vectors | runtime / projection / review sessions |

## 6. Protocol impact

`Protocol impact: P09; P26; P27; P01: none — no channel frame or HELLO change; P02: none — no WAL/manifest/durable format change; P04: none — no bridge message; P05: none — no gateway route or credential surface; P06: none — consumes existing host events without changing their kinds or schema; P16: none — no bootstrap or Worker URL/env key; P18: none — no persisted setting key.`
