<!-- SPDX-License-Identifier: MIT -->
# Bot activity sources (short-progress v3)

Pinned DSH: `66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db` (`0.2.2-rc.1`). This document records
where the iOS activity bubble gets its sentence. It adds no parameter, event, wire field,
database or model request: every source below is already in the `tool/call` event
(`data.name`, `data.arguments`) or in the main model's public assistant text.

> Frozen short-progress contract: lead `fba63d85938b8159f3e25da112374a1e27d56ef2`
> (81 vectors). One 10–20-Chinese-character progress sentence, at most about 28 when it
> carries a result; short object only (basename, host, `#PR`, title, person or meeting);
> no full paths, long URLs, commands, JSON, raw long answers or technical parameters; no
> long-detail budget and no full-text/expandable view. The four runtime prompt/test files
> are committed against this revision; the profile persona mirror is lead-synced.

`BotActivity` remains `{status, detail, category, startedAt}`. Lifecycle comes only from
`tool/call`, `tool/result`, `turn/*`, `step/*` and the existing approval/stream precedence;
model text only fills `detail`.

## Priority

1. **Per-call intent fields** (exact allow-list):
   - `bash.description`
   - phone `Task.task_title`, then `Task.description` (never `prompt`)
   - `create_goal.objective`, `update_goal.objective`
   - card/document/routine `title`, and `RequestApproval.detail`, used as the object of
     that tool's action label
   No other `description`, `summary`, `label` or business field may become activity text.
2. **Same-turn, same-step public progress**:
   - candidate: the latest meaningful public `assistant/stream` (`text` channel) or
     `assistant/message` text segment for the call;
   - it must be in the same turn and the same step and must arrive after the previous
     tool call/result boundary in that step;
   - `step/start`, `tool/call`, `tool/result`, `turn/start` and `turn/end` clear it;
   - reasoning/analysis channels, reasoning blocks, earlier steps, earlier calls and
     earlier turns are never used;
   - card/document tools do not take public text as their activity sentence (a final
     prose conclusion is not process), and generic acknowledgements, fillers,
     completion claims and credential text fall through.
3. **Real argument object** (existing keys only): the table below.
4. **Concrete fallback**: the action label for that tool; unknown visible tools show
   `等待操作结果`.

When a meaningful public sentence is chosen and the call has a primary object it does not
mention, the object is appended after ` · `. A later source never overwrites a known
sentence from an earlier source.

## Tool coverage on the pinned phone tool face

The native schemas are in the pinned DSH checkout under `packages/`; the phone MCP schemas
are in `Sources/PhoneDSHBot/MCP/BotToolCatalog.swift`. `bash` and `Task` carry required or
recommended free text; file/search tools carry their real object argument; job and todo
have no useful object and use a label only.

| Visible tool | Activity source (existing field) | Action label / notes |
| --- | --- | --- |
| `bash` | `description` (required) | intent as-is; fallback `正在运行命令`; never the command text |
| `read` | `file_path` | `在翻文件 · <basename>` (`packages/fs/tool-fs/src/read.ts:78-87`) |
| `write` | `file_path` | `在写文件 · <basename>` (`packages/fs/tool-fs/src/write.ts:74-86`) |
| `edit` | `file_path` | `在改文件 · <basename>` (`packages/fs/tool-fs/src/edit.ts:86-97`) |
| `str_replace_editor` | `path` | `在改文件 · <basename>`; `command` is not the object and must not create a second verb mapping (`packages/fs/tool-str-replace-editor/src/index.ts:430-470`) |
| `glob` | `pattern`, optional `path` | `在找文件 · <pattern>` (`packages/fs/tool-fs-search/src/glob.ts:322-334`) |
| `grep` | `pattern`, optional `path`/`include` | `在搜内容 · <pattern>` + ` · <basename>` when present (`packages/fs/tool-fs-search/src/grep.ts:287-300`) |
| `web_search` | `queries[0]` (schema key is `queries`) | `在网上搜 · <query>` (`packages/web/tool-web/src/search.ts:363-373`) |
| `web_fetch` | `url` | `在开网页 · <host>` (`packages/web/tool-web/src/fetch.ts:459-467`) |
| `job_list` | none | `看看进展` (`packages/jobs/tool-jobs/src/index.ts:541-545`) |
| `job_output` | none (the `job_id` is an internal handle) | `等待结果` |
| `job_kill` | none | `停止任务` |
| `todo_write` | none for the bubble (the list contents are not a single object) | `整理待办` (`packages/todo/tool-todo/src/index.ts:137-159`) |
| `create_goal` | `objective` | `定个目标 · <objective>` (`packages/goal/tool-goal/src/index.ts:208-224`) |
| `get_goal` | none | `看看目标` (`packages/goal/tool-goal/src/index.ts:196-200`) |
| `update_goal` | `objective` | `更新目标 · <objective>` (`packages/goal/tool-goal/src/index.ts:235-250`) |
| `Task` | `task_title`, then `description` (never `prompt`) | intent as-is; fallback `启动子任务` (`Sources/PhoneDSHBot/MCP/BotToolCatalog.swift`, `tool("Task", ...)`) |
| `AwaitTask` | none (`task_id` is internal) | `等子任务结果` |
| `StopSubagent` | none (`task_id` is internal) | `停止子任务` |
| `UpdateMemory` | `path` | `在记笔记 · <basename>` |
| `ReadMemory` | `path` | `在翻记忆 · <basename>` |
| `RecallMemory` | `query` | `回想一下 · <query>` |
| `UpdateRoutine` | `title` | `修改例行任务 · <title>` |
| `ListRoutines` | none | `看看例行任务` |
| `SendToUser` | none | `整理回复` |
| `ask_user` | none | `想问问你` |
| `show_next_steps` | none | `给你选项` |
| `show_attachment` | `path` | `送上附件 · <basename>` |
| `show_document` | `title`, then `path` | `打开文档 · <title or basename>` |
| `show_progress` | `title` | `更新进度 · <title>` |
| `show_checklist` | `title` | `列个清单 · <title>` |
| `show_link` | `links[0].url`, then `url` | `放上链接 · <host or title>` |
| `RequestApproval` | `detail` | `请你确认 · <detail>` |
| `SendToAgent` | `bot_name` | `给其他 Bot 发消息 · <bot_name>` |
| `CreateTeammate` | `name` | `创建协作 Bot · <name>` |
| `FishAction` | hidden | never displayed; correlation only |
| unknown visible tool | none | `等待操作结果` |

## Explicit non-sources

- `Task.prompt`; `CreateTeammate.description`; `show_document.summary`; any `label` or
  business summary not listed above.
- The raw `bash.command`, raw JSON arguments, tool output, reasoning/analysis channels.
- Cross-turn or cross-step public text, text left over after a result, and text from a
  different call.
- Credentials (`Bearer …`, key assignments, `sk-…`, `ghp_…`, `xox…`, `AKIA…`) and
  internal ids/handles.

## Display

The visible line is one short sentence: about 10–20 Chinese characters, at most about 28
when it carries a previous result. Objects are short: basename, host, `#PR`, title, person
or meeting name. Do not paste full paths, long URLs, commands, JSON, raw long answers or
technical parameters. There is no long-detail budget and no full-text/expandable view; the
client normalises to one line and never replaces a real object with a category. URLs used
as a short object drop userinfo and sensitive query parameters (`token`, `access_token`,
`api_key`, `key`, `password`, `secret`, `signature`, `sig`), but a full URL is not the
display object.

## What the prompt must say

The system prompts in both languages must teach the model to use `bash.description` and
`Task.task_title` for one short progress sentence: about 10–20 Chinese characters, at most
about 28 when it carries a previous result, made of action + this task's short object
(basename, host, `#PR`, title, person or meeting). The next sentence must carry the real
result. Full paths, long URLs, whole commands, JSON, raw long answers and technical
parameters stay off the line; credentials and internal ids are not allowed. Keep
`等待响应` as the no-evidence state, and state that the client uses real events and that no
extra status tool, summary model, extra request or metadata field exists. The final answer
stays brief; at a meaningful progress, result or direction-change node the same main model
may write the one short progress sentence, without command-by-command narration or a
tool/model call made only to refresh the bubble.
