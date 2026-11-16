<!-- SPDX-License-Identifier: MIT -->
# iOS real Bot activity projection

Status: normative iOS-only refinement, revision `activity-evidence-v3` (2026-11-16).
This revision replaces the long-object policy of v2.3. It is grounded in the
`tool/call` and `assistant/message` events the pinned DSH already writes; it adds no wire
field, no extra model request, no second history, and no new `BotActivity` member. Android
adaptation remains deferred by the user.

The bubble shows a **short, real, task-related progress sentence** for the running turn:
usually 10–20 Chinese characters, at most about 28 when the sentence carries an interim
result. It is not a fixed status cycle, not a full path table, not a long public answer,
and not a transcript. The main model writes the sentence in the same turn; no summary
model, dedicated activity tool, history, expansion surface or tap target is added.

## Sources and priority

The projection resolves one sentence for the newest unresolved *visible* call.

1. **Per-call model intent** — only these existing fields:
   - `bash.description`;
   - phone `Task.task_title`, then `Task.description` (never `prompt`);
   - `create_goal.objective` / `update_goal.objective`;
   - a card/document/routine `title`, and `RequestApproval.detail`, used as the short
     object of that tool's action label.
   No other `description`, `summary`, `label` or business field may become activity text.
2. **Same-turn, same-step public progress** — the main model's latest meaningful public
   `assistant/stream` (channel `text`) or `assistant/message` text. It must be in the same
   turn and same step and must have arrived after the previous tool call/result boundary in
   that step; `step/start`, `tool/call`, `tool/result`, `turn/start` and `turn/end` clear
   the candidate. Text-channel deltas are accumulated; the durable `assistant/message` for
   that step replaces the accumulation. Reasoning, analysis channels, reasoning blocks,
   cross-turn text, earlier steps and earlier calls are never used.
   The sentence is the model's own short progress, e.g. "对比 #174 与 main 的冲突" or
   "冲突在 3 个文件里，在逐个看". A long public answer is shortened by the display rule
   below; it is never copied to the bubble whole.
3. **Short object fallback** — only when the call has no usable model sentence. Use the
   tool's action label plus a recognisable short object:
   `read`/`write`/`edit`: file **basename**; `glob`/`grep`: pattern (plus the path basename
   only when it fits); `web_search`: query; `web_fetch`: **host**;
   memory tools: path basename or query; `updateroutine`: title; cards: title;
   `sendtoagent`/`createteammate`: Bot name; unknown visible tool: no object.
4. **Concrete fallback** — the tool's short action label; unknown visible tools use
   "等待操作结果".

A model sentence is never extended with a full path or URL. Only when there is no model
sentence does the short object fallback run. A later step's model sentence replaces the
earlier one; the model's next sentence is what carries the previous real result forward
(e.g. "冲突在 3 个文件里，在逐个看"). The client does not invent a result sentence.

## Display shortening

- One line: first line, collapse whitespace, trim, strip sentence-final `。！？!?；;，,、.…`.
- Bound: 28 characters when the text contains CJK, otherwise 56 characters. Preferred
  action length is 10–20 Chinese characters; a sentence with an interim result may use up
  to about 28.
- If the text is longer than the bound, shorten at the last sentence/clause punctuation
  within the bound, else take `bound - 1` characters plus `…`. Never show the full long
  public answer.
- Keep the real task object in the sentence: filename, basename, `#174`, `PR 174`, `main`,
  a person/meeting/document name, a query, a quiet URL host. A full absolute path or a full
  URL is not required and is not appended; the short object fallback uses the basename or
  host.
- Reject only: empty text; fixed generic fillers (`思考中`, `整理思绪`, `准备下一步`,
  `马上就好`, `正在处理`, `处理中`, `等待响应`, `正在回复`, `好的`, `我来看看`,
  `我看一下`, `稍等`, `开始`, and the former `已收到…结果` receipts); a sentence that
  begins with a completion assertion (`已完成`, `已成功`, `已验证`, `已确认`, `已修复`,
  `已合并`, `已发送`, `已删除`, `已通过`, `已解决`, or English `completed`, `verified`,
  `done`, `all tests passed`); and credential shapes (`Bearer …`,
  `api_key=`/`token=`/`password=` style assignments, `sk-…`, `ghp_…`, `xox…-…`,
  `AKIA…`). A rejected sentence falls through to the next source; it is never cut into an
  ellipsis as a substitute.
- A public-progress candidate that is generic, a completion claim, credential-shaped, or
  not on the public text channel is discarded for that call; the projection does not scan
  another step or turn to replace it.

## Action labels and short objects

| tool (bare, lowercased) | category | label / short object |
| --- | --- | --- |
| `bash` | running | model intent as-is; fallback `正在运行命令` |
| `read` | reading | `在翻文件 · <basename>` |
| `write` | writing | `在写文件 · <basename>` |
| `edit`, `str_replace_editor` | writing | `在改文件 · <basename>` |
| `glob` | searching | `在找文件 · <pattern>` |
| `grep` | searching | `在搜内容 · <pattern>` + ` · <basename(path)>` when it fits |
| `web_search` | searching | `在网上搜 · <query>` |
| `web_fetch` | browsing | `在开网页 · <host>` |
| `job_list` / `job_output` / `job_kill` | running | `看看进展` / `等待结果` / `停止任务` |
| `todo_write` | writing | `整理待办` |
| `create_goal` | writing | `定个目标 · <short objective>` |
| `get_goal` | reading | `看看目标` |
| `update_goal` | writing | `更新目标 · <short objective>` |
| `Task` | messaging | model intent as-is; fallback `启动子任务` |
| `AwaitTask` / `StopSubagent` | running | `等子任务结果` / `停止子任务` |
| `UpdateMemory` / `ReadMemory` | memory | `在记笔记 · <basename>` / `在翻记忆 · <basename>` |
| `RecallMemory` | memory | `回想一下 · <query>` |
| `UpdateRoutine` | writing | `修改例行任务 · <title>` |
| `ListRoutines` | reading | `看看例行任务` |
| `SendToUser` | messaging | `整理回复` |
| `ask_user` | messaging | `想问问你` |
| `show_next_steps` | messaging | `给你选项` |
| `show_attachment` | messaging | `送上附件 · <basename>` |
| `show_document` | reading | `打开文档 · <title or basename>` |
| `show_progress` / `show_checklist` | writing | `更新进度 · <title>` / `列个清单 · <title>` |
| `show_link` | messaging | `放上链接 · <host>` |
| `RequestApproval` | messaging | `请你确认 · <detail>` |
| `SendToAgent` / `CreateTeammate` | messaging | `给其他 Bot 发消息 · <bot_name>` / `创建协作 Bot · <name>` |
| `FishAction` | hidden | never displayed; correlation only |
| unknown visible tool | generic | `等待操作结果` |

`BotActivityPhrases` remains the legacy vocabulary for Android and for non-production
callers. The iOS production path uses this table and the real call arguments; it does not
call `BotActivityPhrases.toolActivity` with empty arguments and does not rotate synonyms.

Every visible work tool may use the same-step public progress when it has no usable model
intent/object — including unknown MCP tools, memory, recall, routine, job and goal tools.
Only card/messaging tools (send-to-user, questions, next steps, content cards, approvals,
teammate messages) and the hidden `FishAction` never use it.

## Lifecycle

Status, visibility and lifecycle come only from `tool/call`, `tool/result`, `turn/start`,
`turn/end`, step boundaries and the existing approval/stream precedence. Model text only
populates `detail`; it never starts, finishes, fails or approves a call.

Order events by `seq` with stable arrival order on ties; follow the latest open turn. An
explicit old-turn result/end cannot terminate a new turn. Missing turn IDs keep the legacy
compatibility rule, never overriding an explicit mismatched ID.

Track every unresolved call, including hidden `FishAction`, for correlation. Display the
newest unresolved visible call. Duplicate known call IDs do not reopen settled work.
Results with an ID close only that ID; without an ID they close only a single unambiguous
outstanding call (visible or hidden). Unknown IDs, invalid/conflicting ID fields and
ambiguous missing IDs close nothing. Step start and user steering do not cancel work.

After the last visible call returns, keep that call's own short sentence and its category
as `.reviewing` with `thinking` status; do not emit "已收到…结果". A subsequent step keeps
this context until actual public text, a new visible call, or the turn end. Receiving a
result does not assert business success. A failed result shows "这步遇到问题". If text is
actually streaming after the result, show "正在回复". Turn end or local stop clears the
activity; reconstruction uses the current open-turn history. Reasoning-only records never
count as public reply text.

## UI consumption and compatibility

`BotActivity` keeps exactly `{status, detail, category, startedAt}`. The existing timing
machine keeps the 800 ms latest-wins window, the `· N 分钟` suffix and the approval
precedence. The bubble stays non-interactive: the reserved band remains hit-transparent
and no tap target, sheet, expanded view, button or extra control is added. It renders one
line with tail truncation at the existing 86% width cap; the `detail` value and the
accessibility label carry the short real sentence. The UI does not re-sanitise, rewrite or
lengthen `detail`.

No transport, persistence, schema or Android change is required. Old persisted rows and
old clients keep the existing value shape. The shared `activity.schema.json`,
`activity-phrases.json` and `strings.json` values are unchanged by this revision; iOS
normalises before the display layer.

## Validation

`activity-evidence-vectors.json` is the shared oracle and is consumed by Swift tests that
run the real `BotRuntimePresentationFactory` and `BotActivityReducer` over
`BotDSHSessionEvent` values, plus real `BotLiveFishProjection.receive` frames. Cases cover:
short file basenames, long paths reduced to a basename, a model sentence that is not
extended with a path, a long public answer shortened to the short bound, a result
continuation ("冲突在 3 个文件里，在逐个看"), `#174` / person / meeting names, bash
descriptions, Task titles, completion assertions, generic fillers, credential intents,
public-text fallback (and its exclusion for card tools), concurrent reverse completion,
missing / unknown / conflicting IDs, hidden FishAction, duplicate replay, old-turn
isolation, failure, result-to-next-call continuity (no receipt), unknown MCP and memory
tools with public progress, live-vs-durable equality, and unknown-start-time. Passing
these tests is not a device, Worker, model or App claim; the real model-to-bubble chain is
recorded separately.
