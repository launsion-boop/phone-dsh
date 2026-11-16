<!-- SPDX-License-Identifier: MIT -->
# Bot activity real projection (iOS)

Status: implemented on the isolated iOS branch; real-model acceptance is recorded in the
task handoff. Contract revision: `activity-evidence-v3.1`, change record
[PC-20261116-bot-activity-real-projection](../protocol-changes/PC-20261116-bot-activity-real-projection.md).

## Problem

The Bot activity bubble used to replay a fixed vocabulary: the projection called the
shared phrase table with empty arguments, then a category table replaced every known
tool with "读取相关资料 / 执行当前操作 / 已收到…结果". The real `tool/call` arguments
already contained the file, pattern, query, URL, task title and call ID, but they never
reached the bubble. The result receipt also hid the last real sentence. The user's ruling
is a short, real progress sentence from the same main-model turn — not a preset status
cycle, not a complete path/URL table, not a long public answer, and not a second model or
activity tool.

## One event chain

```
main model turn
  → DSH tool/call (name, callId, raw JSON arguments) and assistant/message
  → durable session log / live frames (existing events only)
  → BotActivityReducer (one deterministic fold)
  → BotActivity {status, detail, category, startedAt}
  → BotHeaderPresence → BotActivityLineState (800 ms latest-wins)
  → one non-interactive one-line bubble
```

`BotRuntimePresentationFactory.make` (durable) and the live frame path both call the same
reducer. A call is tracked by `callId`; the newest unresolved visible call is displayed.
Results close only the matching ID; an ID-less result closes only a single unambiguous
outstanding call; unknown/conflicting IDs close nothing. Hidden `FishAction` participates
in correlation but is never displayed. Step start and steering do not cancel work. An old
turn cannot terminate a new one. A result keeps the call's own sentence and changes the
phase to `.reviewing`; it never emits a receipt. Turn end/stop clears the activity.

## Sentence sources

1. Per-call model intent: `bash.description`, phone `Task.task_title` then
   `Task.description`, goal `objective`, card/document/routine `title`,
   `RequestApproval.detail` as the object of that tool's action label. `prompt`,
   `summary`, `label` and other business fields are not activity text.
2. Same-turn, same-step public progress: the latest meaningful public assistant text
   before the call, after the previous tool boundary. Text-channel deltas accumulate;
   the durable `assistant/message` replaces the accumulation. Reasoning/analysis
   channels, earlier steps, earlier calls and earlier turns are excluded.
3. Short object fallback only when no model sentence exists: file basename for
   read/write/edit, pattern for glob/grep (path basename only when the assembled sentence
   still fits), query for web search, host for web fetch, basename/query for memory,
   title/name for cards and team tools. Unknown visible work tools may use the same-step
   public progress; only card/messaging tools and hidden `FishAction` opt out.
4. Concrete label (`在翻文件`, `正在运行命令`, …), then `等待操作结果` for an unknown tool.

A model sentence is never extended with a full path or URL. The final assembled fallback
is shortened after joining, so a long basename or query cannot exceed the bound through
the action prefix. There is no separate 42-character target allowance.

## Short display rule

- One line, first line, collapsed whitespace, sentence-final punctuation trimmed.
- Preferred progress: 10–20 Chinese characters; with an interim result up to about 28.
- Hard bound: 28 characters when the text contains CJK, else 56.
- Longer text is shortened at the last sentence/clause punctuation within the bound,
  else `bound - 1` characters plus `…`. Long public answers and full paths/URLs never
  reach the bubble whole.
- Rejected: generic fillers, completion claims and credential shapes. A rejected
  candidate falls through to the next source.
- The model's next short sentence carries the previous real result forward; the client
  does not invent a result sentence.

## UI

`BotActivity` keeps `{status, detail, category, startedAt}`. The bubble is the existing
32pt band with one line, tail truncation and the 86% width cap. It is non-interactive:
the band keeps `allowsHitTesting(false)`, and there is no tap target, sheet, full-text
view, history, button or extra control. The accessibility label carries the short real
sentence. The 800 ms latest-wins timing and `· N 分钟` suffix are unchanged. UI does not
re-sanitise or lengthen `detail`.

## Prompt and Worker image

The double-language system prompts teach the main model to write one natural 10–20
character progress sentence with the task's short object and to carry the previous real
result into the next sentence. They explicitly forbid full paths, long URLs, whole
commands/JSON, raw long answers, credentials and internal IDs, and forbid a dedicated
activity tool or extra model request. The stable `personaPrefix` in
`plugins/profile/phone.worker.cordis.patch.yml` is regenerated from the assembled prompt
and must stay byte-identical (persona test). Prompts are packaged into the Worker image,
so a prompt change requires the supported packer and real-runtime evidence; a source-only
change is not proof that the image uses it.

## Compatibility

No wire, event, persisted-value or schema change. `BotActivity` and the shared
`activity.schema.json`, `activity-phrases.json` and `strings.json` values are unchanged.
Old rows and old clients keep the shape. Android is out of scope by the user's ruling.
No DSH pin, production default or profile key changes. No metadata argument is added:
pinned DSH `tool/call` arguments are the model's original JSON, and the existing
`bash.description` / `Task.task_title` / argument object / same-step public text suffice.

The macOS eval host compiles the same production `BotRuntimeComposition`. Its App-side
vision bridge (`BotWorkspaceModelImage`) is guarded by `#if canImport(UIKit)`; on macOS the
existing optional `BotModelImageReader` is passed as `nil` instead of introducing an image
stub. Text/path attachments and the iOS behavior are unchanged. This is a Bot module
compile boundary for the eval host, not a product capability change; image/vision is not
part of this task's acceptance.

## Verification

Run on the isolated worktree with Xcode 26.5 / Swift 6.3.2 and the iPhone 17 simulator.

- `xcodebuild -project scripts/ci/bot-activity-evidence/BotActivityEvidence.xcodeproj
  -scheme BotActivityEvidenceTests -destination 'platform=iOS Simulator,name=iPhone 17'
  test` → PASS, `Executed 45 tests, with 0 failures` including the 83 shared vectors and a
  real `BotLiveFishProjection.receive` regression (streamStart + multiple textDelta +
  continuously numbered real events; complete accumulated sentence, real order preserved,
  records do not grow with tokens, live == durable).
- `cd plugins && node scripts/run-tests.mjs tests/bot-persona.test.ts` → PASS 9/9,
  including the profile persona mirror and the 10–20-character progress guidance in both
  languages.
- `python3 -B spec/tools/registry_build.py --root . --check`,
  `registry_check.py`, `schema_diff.py --base 908d582b9`, `cross_check.py` → PASS.
- `bash scripts/ci/check.sh --only phone-license` → PASS.
- `phone-hygiene` and `ui_check` fail on pre-existing baseline findings in
  `spec/v1/tono-account.md` and stale `Components/ChatPage/NativeShell` provenance
  anchors; the same failures reproduce on a base+contract worktree without this diff.
### Accepted real-model evidence

The three controlled tasks in `scripts/ci/bot-e2e/activity/catalog.json` (inline local
seeds for #174, the Wednesday meeting and a local email draft; no network, mail account or
send tool) passed on the production Bot composition with the packed Worker:

- `cefff6a288a3a2a2a40c14f86aa37ac7619d026b` — final code head / tree
  `5ec4a847f67f519f73856b440e99464ff7aaf2ff`; the earlier `cff5dd149` run is retained as
  `previousGuidedRun` in the receipt.
- Each scenario `PASS`; 6/5/5 model requests; every session's
  `request/header.data.header.config` is `deepseek-official` / `deepseek-flash` /
  `reasoningEffort=max`.
- ACT-01 `#174`: `List workspace and pr directory` (31, English `bash.description`; the
  Chinese public sentence `正在读 #174 的笔记。` was not selected because per-call intent
  ranks first) → `在翻文件 · 174-notes.md` (19, short object fallback) →
  `#174 显示冲突 3 个文件，接着看 main 侧笔记` (28, after the read result).
- ACT-02 meeting: `我先读周三例会的笔记` (10) →
  `例会里 3 项待办已经看到，接下来核对责任人清单` (24, after the first result).
- ACT-03 email: `我先看看李光浩那封邮件的原文` (14) →
  `李光浩在问周五能否发布，接着看发布背景` (19, after the first result).
- `BotActivityReplayTests` (in the existing Bot eval harness) replayed the real ACT-01
  session through the production decoder + reducer and passed, printing the max header and
  the same short details.
- The exact sequences, source seq/tool, lengths and failed-attempt boundaries are in
  `scripts/ci/bot-e2e/activity/receipt.json`. Raw session logs and Worker bundles stay
  local.

Earlier attempts are retained as failed/limited evidence: a temporary macOS image shim
and a high-effort header were rejected; several macOS compile-boundary errors were fixed
in `cff5dd149`; an empty session copy was replaced by the real session path and a hard
failure in the replay entry.

### Natural-request control: PASS on the clock-fixed head

`scripts/ci/bot-e2e/activity/catalog-natural.json` removes all progress/read/output
guidance from the user prompt. On head `cefff6a2` all three natural scenarios passed; each
session read its seeds with `bash`/`read` and every `request/header` is Flash/max. The
observed sequence has 16 unique activity details: 6 short basename fallbacks (37.5%),
8 model/tool-description details and 2 card labels. ACT-06 shows a real post-result
Chinese continuation (`资料很少，就只有他的来信和一条发布背景；我现在来拟草稿` after the
two seeds). The default prompt still produced several English `bash.description` lines
and object fallbacks because the per-call description ranks first; the final guided rerun
shows the same effect on ACT-01. This is recorded as a quality observation, not a hidden
failure; short/real/result-continuation criteria are met.

Earlier natural attempts on head `91a26c50c` were blocked by the wall-clock gateway/expiry
bug (bash identity registration). The meeting run was temporarily a weak-regex false PASS
on refusal text and the email run was stopped; both are retained in
`receipt.json.failedAttempts`. The clock fix is `cefff6a2`; no identity bypass and no
loosened assertion was used.

Not run: physical iPhone, full App UI run, Android, deployment. Those are not inferred
from the simulator or harness evidence.
