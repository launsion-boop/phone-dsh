<!-- SPDX-License-Identifier: MIT -->
# iOS real Bot activity projection

Status: normative iOS-only refinement, revision `activity-evidence-v2.1` (2026-11-16).
This revision replaces the 2026-11-14 label policy in this file. It is grounded in the
`tool/call` and `assistant/message` events the pinned DSH already writes; it adds no wire
field, no extra model request, no second history, and no new `BotActivity` member. Android
adaptation remains deferred by the user.

The bubble shows what the running turn is actually doing. Its sentence is built from the
main model's per-call intent and from the real objects of this call (file name, path, URL,
PR number, query, task/bot/document title, person or meeting name). It is not a fixed
status cycle, and a real object must not be replaced by a generic category such as
"读取相关资料".

## Sources and priority

The projection resolves one sentence for the newest unresolved *visible* call. Sources are,
in order:

1. **Per-call model intent** — only these existing fields:
   - `bash.description`;
   - phone `Task.task_title`, then `Task.description` (never `prompt`);
   - `create_goal.objective` / `update_goal.objective`;
   - a card/document/routine `title`, and `RequestApproval.detail`, used as the object of
     that tool's action label.
   No other `description`, `summary`, `label` or business field may become activity text.
2. **Associated public task progress** — the main model's latest meaningful public
   `assistant/stream` (channel `text`) or `assistant/message` text segment emitted for this
   call. It must be in the **same turn and same step** and must have arrived after the
   previous tool call/result boundary in that step; `step/start`, `tool/call`,
   `tool/result`, `turn/start` and `turn/end` clear the candidate. Reasoning, analysis
   channels, reasoning blocks, cross-turn text and text left over from an earlier step or
   an earlier call are never used. Text-channel deltas in one step are accumulated; a
   durable `assistant/message` for that step replaces the accumulated text, so a single
   streamed fragment is never treated as the whole sentence. The sentence explains *why*
   the Bot is reading or running this step and what it found, so it outranks a bare path
   label. A generic acknowledgement, a filler, a completion claim or credential text is
   not meaningful and falls through.
3. **Real argument object** — the call's own argument keys:
   `read`/`write`/`edit`/`str_replace_editor`: `file_path` (then `path`, `filePath`);
   `glob`: `pattern`; `grep`: `pattern` and, when present, `path`;
   `web_search`: `query` or `queries[0]`; `web_fetch`: `url`;
   memory tools: `path`; `recallmemory`: `query`; `updateroutine`: `title`;
   `show_attachment`: `path`; `show_document`: `title`, then `path`;
   `show_progress`/`show_checklist`: `title`; `show_link`: `links[0].url`, then `url`;
   `sendtoagent`: `bot_name`; `createteammate`: `name`.
   Paths and URLs stay recognisable: no basename-only or host-only rewrite.
4. **Concrete fallback** — the tool's short action label (see the table in
   `activity-evidence-v2.1` below); unknown visible tools use "等待操作结果".

When a meaningful public sentence is chosen and the call also has a real primary object
that the sentence does not already mention, the object is appended after ` · ` so the
viewer can tell which file/URL/pattern this step concerns. When the sentence already
contains the object, it is not repeated. A later source never overwrites a known sentence
from an earlier source.

## Display normalisation

- One line: take the first line, collapse whitespace, trim. Strip sentence-final
  `。！？!?；;，,、.…` from the end.
- Keep the sentence, do not rewrite it. Cap at 512 characters: 511 + `…` when longer.
- Reject only: empty text; the fixed generic fillers (`思考中`, `整理思绪`, `准备下一步`,
  `马上就好`, `正在处理`, `处理中`, `等待响应`, `正在回复`, `好的`, `我来看看`,
  `我看一下`, `稍等`, `开始`, and the former `已收到…结果` receipts); a sentence that
  begins with a completion assertion (`已完成`, `已成功`, `已验证`, `已确认`, `已修复`,
  `已合并`, `已发送`, `已删除`, `已通过`, `已解决`, or English `completed`, `verified`,
  `done`, `all tests passed`); and credential shapes (`Bearer …`,
  `api_key=`/`token=`/`password=` style assignments, `sk-…`, `ghp_…`, `xox…-…`,
  `AKIA…`).
- A public-progress candidate is the latest such segment; it is normalised the same way.
  A segment that is generic, a completion claim, credential-shaped, or not on the public
  text channel is discarded for that call; the projection does not scan further back into
  another step or turn to replace it.
- File names, extensions, absolute or workspace paths, URLs, `#174`, `PR 174`, `main`,
  `@name`, quoted titles, CJK names and normal punctuation are allowed. A rejected
  intent falls through to the next source; it is never cut into an ellipsis.
- A URL shown as an object drops its scheme and leading `www.`, drops userinfo and
  sensitive query parameters (`token`, `access_token`, `api_key`, `key`, `password`,
  `secret`, `signature`, `sig`); host, path and other query parameters remain.

## Action labels

| tool (bare, lowercased) | category | label / object |
| --- | --- | --- |
| `bash` | running | intent as-is; fallback `正在运行命令` |
| `read` | reading | `在翻文件 · <file_path>` |
| `write` | writing | `在写文件 · <file_path>` |
| `edit`, `str_replace_editor` | writing | `在改文件 · <file_path or path>` |
| `glob` | searching | `在找文件 · <pattern>` |
| `grep` | searching | `在搜内容 · <pattern>` + ` · <path>` when present |
| `web_search` | searching | `在网上搜 · <query>` |
| `web_fetch` | browsing | `在开网页 · <url>` |
| `job_list` / `job_output` / `job_kill` | running | `看看进展` / `等待结果` / `停止任务` |
| `todo_write` | writing | `整理待办` |
| `create_goal` | writing | `定个目标 · <objective>` |
| `get_goal` | reading | `看看目标` |
| `update_goal` | writing | `更新目标 · <objective>` |
| `Task` | messaging | intent as-is; fallback `启动子任务` |
| `AwaitTask` / `StopSubagent` | running | `等子任务结果` / `停止子任务` |
| `UpdateMemory` / `ReadMemory` | memory | `在记笔记 · <path>` / `在翻记忆 · <path>` |
| `RecallMemory` | memory | `回想一下 · <query>` |
| `UpdateRoutine` | writing | `修改例行任务 · <title>` |
| `ListRoutines` | reading | `看看例行任务` |
| `SendToUser` | messaging | `整理回复` |
| `ask_user` | messaging | `想问问你` |
| `show_next_steps` | messaging | `给你选项` |
| `show_attachment` | messaging | `送上附件 · <path>` |
| `show_document` | reading | `打开文档 · <title or path>` |
| `show_progress` / `show_checklist` | writing | `更新进度 · <title>` / `列个清单 · <title>` |
| `show_link` | messaging | `放上链接 · <url>` |
| `RequestApproval` | messaging | `请你确认 · <detail>` |
| `SendToAgent` / `CreateTeammate` | messaging | `给其他 Bot 发消息 · <bot_name>` / `创建协作 Bot · <name>` |
| `FishAction` | hidden | never displayed; correlation only |
| unknown visible tool | generic | `等待操作结果` |

`BotActivityPhrases` remains the legacy vocabulary for Android and for non-production
callers. The iOS production path uses this table and the real call arguments; it does not
call `BotActivityPhrases.toolActivity` with empty arguments and does not rotate synonyms.

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

After the last visible call returns, keep that call's own sentence and its category as
`.reviewing` with `thinking` status; do not emit "已收到…结果". A subsequent step keeps
this context until actual public text, a new visible call, or the turn end. Receiving a
result does not assert business success. A failed result shows "这步遇到问题". If text is
actually streaming after the result, show "正在回复". Turn end or local stop clears the
activity; reconstruction uses the current open-turn history. Reasoning-only records never
count as public reply text.

## UI consumption and compatibility

`BotActivity` keeps exactly `{status, detail, category, startedAt}`. The existing timing
machine keeps the 800 ms latest-wins window, the `· N 分钟` suffix and the approval
precedence. The bubble renders one line with tail truncation at the existing 86% width
cap; tapping the bubble opens a readable full-sentence view. Truncation is visual only:
the `detail` value and the accessibility label keep the real object. The UI does not
re-sanitise, shorten or replace `detail`.

No transport, persistence, schema or Android change is required. Old persisted rows and
old clients keep the existing value shape. The shared `activity.schema.json`,
`activity-phrases.json` and `strings.json` values are unchanged by this revision; iOS
normalises before the display layer.

## Validation

`activity-evidence-vectors.json` is the shared oracle and is consumed by Swift tests that
run the real `BotRuntimePresentationFactory` and `BotActivityEvidence` over
`BotDSHSessionEvent` values. Cases cover: real file paths, long paths, grep pattern+path,
URLs and credential-shaped URLs, `#174` / person / meeting names, bash descriptions,
Task titles, completion assertions, generic fillers, credential intents, public-text
fallback (and its exclusion for card tools), concurrent reverse completion, missing /
unknown / conflicting IDs, hidden FishAction, duplicate replay, old-turn isolation,
failure, result-to-next-call continuity (no receipt), long input, and unknown-start-time.
Passing these tests is not a device, Worker, model or App claim; the real model-to-bubble
chain is recorded separately.
