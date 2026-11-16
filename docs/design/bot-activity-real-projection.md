<!-- SPDX-License-Identifier: MIT -->
# Bot activity real projection (iOS)

Status: implemented on the isolated iOS branch; real-model acceptance is recorded in the
task handoff. Contract revision: `activity-evidence-v3.6`, change record
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

1. Declared required `activity` for the exact five read/search tools (`read`, `glob`,
   `grep`, `web_search`, `web_fetch`).
2. Per-call model intent: `bash.description` (the Bot-scope parameter prose asks for the
   user-language task object/progress and a known prior result), phone `Task.task_title` then
   `Task.description`, goal `objective`, card/document/routine `title`,
   `RequestApproval.detail` as the object of that tool's action label. `prompt`,
   `summary`, `label` and other business fields are not activity text.
3. Same-turn, same-step public progress: the latest meaningful public assistant text
   before the call, after the previous tool boundary. Text-channel deltas accumulate;
   the durable `assistant/message` replaces the accumulation. Reasoning/analysis
   channels, earlier steps, earlier calls and earlier turns are excluded.
4. Short object fallback only when no model sentence exists: file basename for
   read/write/edit, pattern for glob/grep (path basename only when the assembled sentence
   still fits), query for web search, host for web fetch, basename/query for memory,
   title/name for cards and team tools. Unknown visible work tools may use the same-step
   public progress; only card/messaging tools and hidden `FishAction` opt out.
5. Concrete label (`在翻文件`, `正在运行命令`, …), then `等待操作结果` for an unknown tool.

A model sentence is never extended with a full path or URL. The final assembled fallback
is shortened after joining, so a long basename or query cannot exceed the bound through
the action prefix. There is no separate 42-character target allowance.

## Short display rule

- One line, first line, collapsed whitespace, sentence-final punctuation trimmed.
- Generate about 10 characters; at most 19 including spaces, digits, punctuation and
  any interim result. The five-tool model-facing activity schema also caps length at 19.
- Existing 28 CJK / 56 non-CJK projection bounds remain only as old-log/noncompliant-output
  safeguards; the UI cleaner can further truncate. They are not generation allowances.
- Longer text is shortened at the last sentence/clause punctuation within the bound,
  else `bound - 1` characters plus `…`. Long public answers and full paths/URLs never
  reach the bubble whole.
- Rejected: generic fillers, completion claims and credential shapes. A rejected
  candidate falls through to the next source.
- The model's next short sentence carries the previous real result forward; the client
  does not invent a result sentence.

## UI

`BotActivity` keeps `{status, detail, category, startedAt}`. The bubble is the existing
38pt default band with one line, 16pt medium text, tail truncation and a 94% width cap.
Text and band scale together with Dynamic Type. Waiting and replying show only three
dots; task progress, approval and errors keep their text. Changes use a restrained
220ms transition; Reduce Motion disables ambient motion. It is non-interactive:
the band keeps `allowsHitTesting(false)`, and there is no tap target, sheet, full-text
view, history, button or extra control. The accessibility label carries the short real
sentence. Normal progress retains 800 ms latest-wins timing; approvals and errors
bypass pending dwell. UI does not re-sanitise or lengthen `detail`. See the
[UI receipt](../receipts/bot-activity-ui-20261116/README.md) for native screenshots,
recordings, four UI tests and the final 49-test logic run (91 shared vectors).

## Prompt and Worker image

The double-language system prompts teach the main model to write one natural roughly 10-character progress sentence (maximum 19) with the task's short object and to carry the previous real
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
No DSH pin, production default or profile key changes. The Bot-scoped wrapper adds
model-facing required `activity` only to read/glob/grep/web_search/web_fetch, using a
cloned schema. It strips that field before invoking the original handler; original
validators and required arrays remain unchanged, so old calls without activity still
execute. `bash.description` and `Task.task_title` retain their existing argument shapes.
No DSH source, global tool or Workbench tool is changed.

The macOS eval host compiles the same production `BotRuntimeComposition`. Its App-side
vision bridge (`BotWorkspaceModelImage`) is guarded by `#if canImport(UIKit)`; on macOS the
existing optional `BotModelImageReader` is passed as `nil` instead of introducing an image
stub. Text/path attachments and the iOS behavior are unchanged. This is a Bot module
compile boundary for the eval host, not a product capability change; image/vision is not
part of this task's acceptance.

## Verification

The following initial run is historical; final natural-model evidence is below and
final UI/logic results are in the linked UI receipt.

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

- `abf3d3c5a1c1777b1d9f596262b015750e5de19e` — final code head / tree
  `9bad81f77ebb1ff4dff30871d0a13905ad9a8af6`; the earlier `cff5dd149` and `cefff6a2`
  runs are retained as `previousGuidedRun` in the receipt.
- Each scenario `PASS`; 5/5/5 model requests; every session's
  `request/header.data.header.config` is `deepseek-official` / `deepseek-flash` /
  `reasoningEffort=max`.
- ACT-01 `#174`: `在查 #174 的合并笔记，先读分支侧记录` (21) →
  `#174 记录显示 3 个冲突文件，接着核对主干侧` (25, after the read result).
- ACT-02 meeting: `我会先读周三例会的纪要` (11) →
  `这次会上登记了 3 项待办，负责人是李光浩` (21, after the first result).
- ACT-03 email: `我先读李光浩那封邮件的内容` (13) →
  `李光浩问周五发布能不能按清单走` (15, after the first result).
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

### Natural-request control: PASS with required activity (v3.5)

On head `7ef72269b` the real first `request/header` declares `activity` on read/glob/grep
with `required` including it and `minLength: 1`; bash keeps its existing `description`
field with Bot-only model prose; web tools were absent. All three natural scenarios pass
(5/6/7 requests, every header Flash/max). ACT-04:
`查看工作区与 pr 资料目录` (14), `读取 #174 的资料笔记` (13), `读取 main 侧的笔记` (12).
ACT-05: `先看工作区里 notes 资料有哪些` (18), `在读周三例会纪要原文` (10),
`在读 actions 清单核对待办项` (18). ACT-06:
`查看 inbox 和 notes 目录内容` (21), `在读李光浩的来信内容` (10),
`在读发布背景笔记` (8), `在写文件 · draft-reply-liguangh…` (28), `打开文档 · 给李光浩的回复草稿`
(16). Every read uses activity, with no read filename fallback. The first bash bubble is a
real directory-stage description, and not every sentence explicitly carries the previous
result (ACT-05’s todo check is a partial reference); the ACT-06 write uses a short file
object because write is outside the five-tool activity coverage. These are recorded quality
observations, not perfect or zero-fallback claims. The directory-stage first bash is a real
stage description, not a preset cycle; the write short-object fallback is an honest boundary.
Root’s adjacent Bot regressions at the final code head (bot-runtime-mounts,
bot-preset-narrowing, bot-tool-surface, bot-identity-approval) passed **44/44**
(`lead/.activity-work/final-adjacent-checks.log`).

The earlier full plugin suite reported 2648 passes, 21 skips and two unrelated timing
failures (shell-ext timeout and workflow-worker); this is not a full-suite PASS. Final
affected activity/persona tests passed 19/19 with typecheck; adjacent Bot tests passed
44/44. Known hygiene and P0 UI provenance failures remain documented.

Not run: physical iPhone, full App live-model end-to-end, Android, deployment. Those are not inferred
from the simulator or harness evidence.
