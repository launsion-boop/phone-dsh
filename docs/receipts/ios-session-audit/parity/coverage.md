# iOS × 官方 DSH Session 基线扫描

> 生成时间：2026-11-01T01:55:10+00:00
> 官方：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`
> 官方 commit：`7be5505b0be06009d74891c869063c9cf19a0df0`
> iOS：`/Users/leilangsheng/Desktop/TonoTeam/phone-dsh`
> 脚本：`scripts/ios-parity/audit.py`（静态提取，不运行 Web/iOS 工程）

## 0. 快照

| 项 | 数量 |
|---|---|
| 官方 chat node kind | 20 |
| 官方 toolview key | 54 |
| 官方 conversation slot | 35 |
| 官方 projection key | 29 |
| 官方 surface 组件 | 23 |
| 解析出的 light token | 405 |
| 解析出的 dark token | 193 |
| iOS ChatItem.Kind | 12 |
| iOS tool variant | 7 |

## 1. 审计缺口（官方可见 surface 没有被 01–08 报告按名字或同义词提到）

### chat_node_kinds

- 无（全部被至少一份轴报告按名字或同义词覆盖）

### toolview_keys

- 无（全部被至少一份轴报告按名字或同义词覆盖）

### slots

- 无（全部被至少一份轴报告按名字或同义词覆盖）

### projection_keys

- 无（全部被至少一份轴报告按名字或同义词覆盖）

> 说明：只统计 `visible` 类；布局/子 seat 和 experimental projection 放在 §1.1，不当作审计缺口。

### 1.0.1 同义词覆盖（需人工确认是否真的覆盖）

#### slots

- `conversation.chat.assistant-actions`
- `conversation.chat.reasoning.body`
- `conversation.chat.reasoning.content`
- `conversation.chat.user.content`
- `conversation.hero.workspace`
- `conversation.images.content`
- `conversation.input.attachments`
- `conversation.input.model`
- `conversation.input.model.label`
- `conversation.input.permission`
- `conversation.input.plan`
- `conversation.session.header.corner`
- `conversation.session.header.utilities`
- `conversation.trajectory.images`
- `conversation.user.text.node`
- `conversation.view`

#### projection_keys

- `agentPreset`

### 1.1 已排除的非可见项（供确认）

- **slots**：`conversation.chat.flow`, `conversation.composer.bar`, `conversation.content`, `conversation.header`, `conversation.session`, `conversation.session.header`, `conversation.user.text`
- **projection_keys**：`agentTeam`, `harnessDevLegacyPrompt`, `llmRetry`, `sandboxMode`, `sessionListMetadata`, `subagentModelSelectionPolicy`, `timeContext`, `titleInput`, `tmuxContext`, `turnBoundary`, `workingDirectory`

## 2. 官方 session surface 清单

### 2.1 Chat node kinds

| key | iOS 等价 | 报告覆盖 |
|---|---|---|
| `assistant-step` | assistant / reasoning | 01-data-path.md, 05-timeline.md, 07-content-actions.md |
| `command` | None | 01-data-path.md, 02-plan-todo.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `command-input` | None | 01-data-path.md, 07-content-actions.md |
| `compaction` | systemEvent | 01-data-path.md, 07-content-actions.md |
| `context` | context | 01-data-path.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `manual-compaction` | None | 01-data-path.md, 07-content-actions.md |
| `model-retry` | systemEvent | 01-data-path.md, 05-timeline.md, 07-content-actions.md |
| `question-reply` | None | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 07-content-actions.md |
| `steering` | user (no distinct kind) | 01-data-path.md, 04-subagent-inbox.md, 05-timeline.md, 07-content-actions.md |
| `submitted-plan` | None | 01-data-path.md, 07-content-actions.md |
| `system-prompt` | None | 01-data-path.md, 05-timeline.md, 07-content-actions.md |
| `tool-call` | toolCall | 01-data-path.md, 02-plan-todo.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md |
| `turn-error` | turnError | 01-data-path.md, 05-timeline.md, 07-content-actions.md |
| `turn-max-tokens` | maxTokens | 01-data-path.md, 05-timeline.md, 07-content-actions.md |
| `turn-process` | None | 01-data-path.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md |
| `turn-tail` | None | 01-data-path.md, 05-timeline.md, 07-content-actions.md |
| `turn-trigger` | None | 01-data-path.md, 04-subagent-inbox.md, 05-timeline.md, 07-content-actions.md |
| `unknown` | unknown | 01-data-path.md, 07-content-actions.md |
| `user` | user | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `workflow-run` | None | 01-data-path.md, 07-content-actions.md |

### 2.2 Toolview keys

| key | iOS 专用 | 报告覆盖 |
|---|---|---|
| `ask_user_question` | ✅ | 01-data-path.md, 03-questions.md, 05-timeline.md, 06-tools.md |
| `bash` | ✅ | 01-data-path.md, 03-questions.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `cordis_define` | generic | 06-tools.md |
| `cordis_inspect_list` | generic | 06-tools.md |
| `cordis_inspect_query` | generic | 06-tools.md |
| `cordis_inspect_self` | generic | 06-tools.md |
| `cordis_run` | generic | 06-tools.md |
| `cordis_stop` | generic | 06-tools.md |
| `cordis_undefine` | generic | 06-tools.md |
| `create_goal` | generic | 05-timeline.md, 06-tools.md |
| `edit` | ✅ | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 05-timeline.md, 06-tools.md, 08-composer.md |
| `get_goal` | generic | 05-timeline.md, 06-tools.md |
| `glob` | ✅ | 05-timeline.md, 06-tools.md |
| `grep` | ✅ | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `interrupt_agent` | generic | 04-subagent-inbox.md, 06-tools.md |
| `job_kill` | generic | 06-tools.md |
| `job_list` | generic | 06-tools.md |
| `job_output` | generic | 06-tools.md |
| `list_agents` | generic | 04-subagent-inbox.md, 06-tools.md |
| `list_subagent_models` | generic | 06-tools.md |
| `lsp` | generic | 06-tools.md |
| `present` | generic | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `ralph` | generic | 06-tools.md |
| `read` | ✅ | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 08-composer.md |
| `read_image` | ✅ | 05-timeline.md, 06-tools.md |
| `schedule_create` | generic | 06-tools.md |
| `schedule_delete` | generic | 06-tools.md |
| `schedule_list` | generic | 06-tools.md |
| `schedule_update` | generic | 06-tools.md |
| `send_message` | generic | 04-subagent-inbox.md, 06-tools.md |
| `session_event_read` | generic | 06-tools.md |
| `session_event_search` | generic | 06-tools.md |
| `session_event_trace` | generic | 06-tools.md |
| `session_search` | generic | 06-tools.md |
| `session_trace` | generic | 06-tools.md |
| `skill` | generic | 01-data-path.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `spawn_teammate` | generic | 04-subagent-inbox.md, 06-tools.md |
| `subagent` | ✅ | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `team_task_create` | generic | 06-tools.md |
| `team_task_get` | generic | 06-tools.md |
| `team_task_list` | generic | 06-tools.md |
| `team_task_update` | generic | 06-tools.md |
| `terminal_close` | generic | 06-tools.md |
| `terminal_list` | generic | 06-tools.md |
| `terminal_open` | generic | 06-tools.md |
| `terminal_read` | generic | 06-tools.md |
| `terminal_signal` | generic | 06-tools.md |
| `todo_write` | ✅ | 01-data-path.md, 02-plan-todo.md, 05-timeline.md, 06-tools.md |
| `update_goal` | generic | 05-timeline.md, 06-tools.md |
| `wait_agent` | generic | 04-subagent-inbox.md, 06-tools.md |
| `web_fetch` | ✅ | 05-timeline.md, 06-tools.md |
| `web_search` | ✅ | 05-timeline.md, 06-tools.md |
| `workflow` | generic | 01-data-path.md, 06-tools.md, 07-content-actions.md |
| `write` | ✅ | 01-data-path.md, 02-plan-todo.md, 05-timeline.md, 06-tools.md, 08-composer.md |

- iOS 专用：**12** / 54
- iOS 通用：**42**：`cordis_define`, `cordis_inspect_list`, `cordis_inspect_query`, `cordis_inspect_self`, `cordis_run`, `cordis_stop`, `cordis_undefine`, `create_goal`, `get_goal`, `interrupt_agent`, `job_kill`, `job_list`, `job_output`, `list_agents`, `list_subagent_models`, `lsp`, `present`, `ralph`, `schedule_create`, `schedule_delete`, `schedule_list`, `schedule_update`, `send_message`, `session_event_read`, `session_event_search`, `session_event_trace`, `session_search`, `session_trace`, `skill`, `spawn_teammate`, `team_task_create`, `team_task_get`, `team_task_list`, `team_task_update`, `terminal_close`, `terminal_list`, `terminal_open`, `terminal_read`, `terminal_signal`, `update_goal`, `wait_agent`, `workflow`

### 2.3 Conversation slots

| slot | class | 覆盖 | 报告 |
|---|---|---|---|
| `conversation.approval.detail` | visible | exact | 01-data-path.md |
| `conversation.chat.assistant-actions` | visible | synonym | 01-data-path.md, 07-content-actions.md, 08-composer.md |
| `conversation.chat.flow` | structural | none | **无** |
| `conversation.chat.message.images` | visible | exact | 07-content-actions.md |
| `conversation.chat.node` | visible | exact | 07-content-actions.md |
| `conversation.chat.reasoning.body` | visible | synonym | 01-data-path.md, 05-timeline.md, 06-tools.md, 07-content-actions.md |
| `conversation.chat.reasoning.content` | visible | synonym | 01-data-path.md, 05-timeline.md, 06-tools.md, 07-content-actions.md |
| `conversation.chat.user.content` | visible | synonym | 01-data-path.md, 04-subagent-inbox.md, 07-content-actions.md |
| `conversation.chat.user.images` | visible | exact | 07-content-actions.md |
| `conversation.composer` | visible | exact | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 08-composer.md |
| `conversation.composer.bar` | structural | none | **无** |
| `conversation.composer.dock` | visible | exact | 01-data-path.md |
| `conversation.content` | structural | none | **无** |
| `conversation.header` | structural | none | **无** |
| `conversation.hero.workspace` | visible | synonym | 01-data-path.md, 02-plan-todo.md, 07-content-actions.md, 08-composer.md |
| `conversation.images.content` | visible | synonym | 01-data-path.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `conversation.input.activity` | visible | exact | 08-composer.md |
| `conversation.input.attachments` | visible | synonym | 07-content-actions.md, 08-composer.md |
| `conversation.input.dock` | visible | exact | 01-data-path.md, 02-plan-todo.md, 08-composer.md |
| `conversation.input.model` | visible | synonym | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `conversation.input.model.label` | visible | synonym | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `conversation.input.overlay` | visible | exact | 01-data-path.md |
| `conversation.input.permission` | visible | synonym | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 05-timeline.md, 07-content-actions.md, 08-composer.md |
| `conversation.input.plan` | visible | synonym | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 05-timeline.md, 07-content-actions.md, 08-composer.md |
| `conversation.plan-review.actions` | visible | exact | 03-questions.md |
| `conversation.session` | structural | exact | 08-composer.md |
| `conversation.session.header` | structural | exact | 08-composer.md |
| `conversation.session.header.actions` | visible | exact | 08-composer.md |
| `conversation.session.header.corner` | visible | synonym | 02-plan-todo.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `conversation.session.header.lineage` | visible | exact | 08-composer.md |
| `conversation.session.header.utilities` | visible | synonym | 08-composer.md |
| `conversation.trajectory.images` | visible | synonym | 01-data-path.md, 04-subagent-inbox.md, 06-tools.md, 07-content-actions.md |
| `conversation.user.text` | structural | none | **无** |
| `conversation.user.text.node` | visible | synonym | 06-tools.md, 07-content-actions.md, 08-composer.md |
| `conversation.view` | visible | synonym | 01-data-path.md |

### 2.3.1 Slot 贡献者（可见控件）

| slot | id / key / label | 文件 |
|---|---|---|
| `conversation.chat.reasoning.body` | `@deepseek-ai/dsh-experimental-cot-translation-bundle` | `packages/experimental/client-ui-cot-translation/src/client/mount.ts` |
| `conversation.input.activity` | `@deepseek-ai/dsh-experimental-voice-input-bundle` | `packages/experimental/client-ui-voice-input/src/client/mount.ts` |
| `conversation.session.header.actions` | `agent-team` | `packages/experimental/client-ui-agent-team/src/client/mount.ts` |
| `conversation.input.dock` | `claude-code-mods` | `packages/experimental/client-ui-claude-code-mods/src/client/mount.ts` |
| `conversation.composer.dock` | `my-decoration` | `packages/preset/agent-preset/skills/cordis-plugin-development/templates/decoration/client.js` |
| `conversation.session.header.utilities` | `session-log-download` | `packages/session-query/session-log-export/src/client/index.ts` |
| `conversation.session.header.utilities` | `open-in-app` | `packages/client/ui-open-in-app/src/client/index.ts` |
| `conversation.session.header.actions` | `—` | `packages/client/ui-sidebar-terminal/src/client/index.ts` |
| `conversation.input.model.label` | `—` | `packages/client/ui-deepseek-model-label-1017/src/client/index.ts` |
| `conversation.user.text.node` | `file` | `packages/client/ui-reference/src/client/index.ts` |
| `conversation.user.text.node` | `folder` | `packages/client/ui-reference/src/client/index.ts` |
| `conversation.chat.user.content` | `performance-usage` | `packages/client/ui-chat/src/client/apply.ts` |
| `conversation.chat.flow` | `chat` | `packages/client/ui-chat/src/client/apply.ts` |
| `conversation.view` | `chat` | `packages/client/ui-chat/src/client/apply.ts` |
| `conversation.composer.dock` | `activity` | `packages/client/ui-chat/src/client/apply.ts` |
| `conversation.composer.dock` | `usage` | `packages/client/ui-chat/src/client/apply.ts` |
| `conversation.approval.detail` | `—` | `packages/client/ui-chat/src/client/apply.ts` |
| `conversation.chat.reasoning.content` | `user` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.reasoning.body` | `user` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `user` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `steering` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `context` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `turn-trigger` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `system-prompt` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `assistant-step` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `command` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `manual-compaction` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `compaction` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `model-retry` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `turn-error` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `turn-max-tokens` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `turn-process` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `turn-tail` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.chat.node` | `unknown` | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts` |
| `conversation.input.model` | `—` | `packages/client/ui-model-selection/src/client/index.ts` |
| `conversation.plan-review.actions` | `—` | `packages/client/ui-plan/src/client/index.ts` |
| `conversation.input.plan` | `—` | `packages/client/ui-plan/src/client/index.ts` |
| `conversation.user.text.node` | `secret` | `packages/client/ui-secret-mask/src/client/index.ts` |
| `conversation.view` | `trajectory` | `packages/client/ui-trajectory/src/client/index.ts` |
| `conversation.input.overlay` | `slash-menu` | `packages/client/ui-input-trigger/src/client/index.ts` |
| `conversation.session.header.utilities` | `schedule-catalog` | `packages/client/ui-schedule/src/client/index.ts` |
| `conversation.images.content` | `—` | `packages/client/ui-attachment/src/client/index.ts` |
| `conversation.input.attachments` | `—` | `packages/client/ui-attachment/src/client/index.ts` |
| `conversation.chat.message.images` | `—` | `packages/client/ui-attachment/src/client/index.ts` |
| `conversation.chat.user.images` | `—` | `packages/client/ui-attachment/src/client/index.ts` |
| `conversation.trajectory.images` | `—` | `packages/client/ui-attachment/src/client/index.ts` |
| `conversation.session.header.lineage` | `subagent-catalog` | `packages/client/ui-subagent/src/client/index.ts` |
| `conversation.session.header.actions` | `subagent-catalog` | `packages/client/ui-subagent/src/client/index.ts` |
| `conversation.composer` | `—` | `packages/client/ui-subagent/src/client/index.ts` |
| `conversation.hero.workspace` | `workspace.row-toast` | `packages/client/ui-workspace/src/client/index.ts` |
| `conversation.composer` | `—` | `packages/client/ui-approval/src/client/index.ts` |
| `conversation.user.text` | `—` | `packages/client/ui-conversation/src/client/apply.ts` |
| `conversation.user.text.node` | `text` | `packages/client/ui-conversation/src/client/apply.ts` |
| `conversation.user.text.node` | `composer-enter` | `packages/client/ui-conversation/src/client/apply.ts` |
| `conversation.content` | `—` | `packages/client/ui-conversation/src/client/apply.ts` |
| `conversation.session` | `—` | `packages/client/ui-conversation/src/client/apply.ts` |
| `conversation.header` | `—` | `packages/client/ui-conversation/src/client/apply.ts` |
| `conversation.session.header` | `—` | `packages/client/ui-conversation/src/client/apply.ts` |
| `conversation.composer.bar` | `—` | `packages/client/ui-conversation/src/client/apply.ts` |
| `conversation.input.dock` | `todo` | `packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx` |
| `conversation.input.dock` | `queue` | `packages/client/ui-conversation/src/client/queue/QueueDock.tsx` |
| `conversation.input.overlay` | `command-popup` | `packages/client/ui-commands/src/client/index.ts` |
| `conversation.session.header.actions` | `mobile-menu` | `packages/client/ui-mobile/src/client/index.ts` |
| `conversation.input.permission` | `permission` | `packages/client/ui-permission-presets/src/client/index.ts` |
| `conversation.user.text.node` | `skill` | `packages/client/ui-skill/src/client/index.ts` |
| `conversation.session.header.actions` | `agent-preset` | `packages/client/ui-agent-preset/src/client/index.ts` |
| `conversation.chat.node` | `workflow-run` | `packages/client/ui-workflow-run/src/client/index.ts` |
| `conversation.session.header.actions` | `job-list` | `packages/client/ui-jobs/src/client/index.ts` |
| `conversation.composer` | `question-reply` | `packages/client/ui-user-questions/src/client/index.ts` |
| `conversation.chat.node` | `question-reply` | `packages/client/ui-user-questions/src/client/index.ts` |
| `conversation.session.header.corner` | `—` | `packages/client/ui-sidebar-right/src/client/index.ts` |
| `conversation.chat.assistant-actions` | `feedback` | `packages/client/ui-message-feedback/src/client/index.ts` |
| `conversation.input.overlay` | `feedback-dialog` | `packages/client/ui-message-feedback/src/client/index.ts` |
| `conversation.chat.node` | `tool-call` | `packages/client/ui-tool/src/client/apply.ts` |
| `conversation.user.text.node` | `command` | `packages/client/ui-goal/src/client/index.ts` |
| `conversation.chat.node` | `command-input` | `packages/client/ui-goal/src/client/index.ts` |
| `conversation.input.dock` | `goal` | `packages/client/ui-goal/src/client/index.ts` |

### 2.3.2 Session 视图 tab（`conversation.view`）

- `chat` — `packages/client/ui-chat/src/client/apply.ts`
- `trajectory` — `packages/client/ui-trajectory/src/client/index.ts`

### 2.4 Projection keys

| key | class | 覆盖 | iOS 现状 | 报告 |
|---|---|---|---|---|
| `agentPreset` | visible | synonym | not mapped in scanner | 01-data-path.md |
| `agentTeam` | experimental | none | not mapped in scanner | **无** |
| `contextBreakdown` | visible | exact | read (refreshNativeMetrics) | 01-data-path.md, 08-composer.md |
| `contextPressure` | visible | exact | read (refreshNativeMetrics) | 01-data-path.md, 08-composer.md |
| `goal` | visible | exact | read with wrong path values.goal.current.goal | 01-data-path.md, 02-plan-todo.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `harnessDevLegacyPrompt` | internal | none | not mapped in scanner | **无** |
| `imageLimits` | visible | exact | not mapped in scanner | 08-composer.md |
| `inbox` | visible | exact | not read | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 07-content-actions.md, 08-composer.md |
| `llmRetry` | internal | none | not mapped in scanner | **无** |
| `modelSelection` | visible | exact | not mapped in scanner | 01-data-path.md |
| `permissions` | visible | exact | read (refreshAccessModes) | 01-data-path.md |
| `plan` | visible | exact | read only in DSHManagementModel activity (unreachable) | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 07-content-actions.md, 08-composer.md |
| `sandboxMode` | internal | none | not mapped in scanner | **无** |
| `sessionListMetadata` | internal | exact | not mapped in scanner | 01-data-path.md |
| `sessionStats` | visible | exact | read (refreshNativeMetrics) | 01-data-path.md, 08-composer.md |
| `subagent` | visible | exact | not read | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `subagentCatalog` | visible | exact | read only in DSHManagementModel activity (unreachable) | 01-data-path.md, 02-plan-todo.md, 04-subagent-inbox.md, 08-composer.md |
| `subagentModelSelectionPolicy` | experimental | none | not mapped in scanner | **无** |
| `subagentTiming` | visible | exact | not read | 01-data-path.md, 04-subagent-inbox.md |
| `timeContext` | internal | none | not mapped in scanner | **无** |
| `title` | visible | exact | read with wrong path values.title.title | 01-data-path.md, 02-plan-todo.md, 03-questions.md, 04-subagent-inbox.md, 05-timeline.md, 06-tools.md, 07-content-actions.md, 08-composer.md |
| `titleInput` | internal | none | not mapped in scanner | **无** |
| `tmuxContext` | internal | none | not mapped in scanner | **无** |
| `todos` | visible | exact | read only in DSHManagementModel activity (unreachable) | 01-data-path.md, 02-plan-todo.md, 04-subagent-inbox.md, 06-tools.md, 08-composer.md |
| `tokenUsage` | visible | exact | read (refreshNativeMetrics) | 01-data-path.md, 04-subagent-inbox.md, 05-timeline.md, 07-content-actions.md, 08-composer.md |
| `turnBoundary` | experimental | none | not mapped in scanner | **无** |
| `turnOutline` | visible | exact | not mapped in scanner | 01-data-path.md, 05-timeline.md |
| `userQuestions` | visible | exact | not read | 01-data-path.md, 03-questions.md |
| `workingDirectory` | internal | exact | not mapped in scanner | 01-data-path.md |

## 3. 官方组件 metrics（解析值，light / dark）

> 只列 base rule 的关键字段；`var()` 已递归展开，`calc(px)` 已求值。

### assistant_body

`packages/client/ui-chat/src/client/chat/AssistantMarkdown.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.root` | `font-size` | `14px` | `14px` |
| `.root` | `line-height` | `24px` | `24px` |
| `.root` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.body` | `gap` | `16px` | `16px` |

### user_bubble

`packages/client/ui-chat/src/client/chat/MessageItem.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.userStack` | `gap` | `8px` | `8px` |
| `.userStack` | `min-width` | `0` | `0` |
| `.userStack` | `max-width` | `min(525.1px, 82%)` | `min(525.1px, 82%)` |
| `.bubble` | `max-width` | `100%` | `100%` |
| `.bubble` | `background` | `rgb(237, 243, 254)` | `rgb(44, 44, 46)` |
| `.bubble` | `border-radius` | `20px` | `var(--dsw-radius-xl)` |
| `.bubble` | `padding` | `10px 16px` | `10px 16px` |
| `.bubble` | `font-size` | `14px` | `14px` |
| `.bubble` | `line-height` | `22px` | `22px` |
| `.bubble` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.bubble` | `white-space` | `pre-wrap` | `pre-wrap` |
| `.referenceSummary` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.referenceSummary` | `font-size` | `min(13px, max(13px, 12px))` | `13px` |
| `.referenceSummary` | `line-height` | `calc(18px + calc(min(13px, max(13px, 12px)) - 13px))` | `18px` |

### tool_row

`packages/client/ui-tool/src/client/tool/components/ToolRow.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.root` | `font-weight` | `500` | `500` |
| `.title` | `font-weight` | `400` | `400` |
| `.summary` | `min-width` | `0` | `0` |
| `.summary` | `overflow` | `hidden` | `hidden` |
| `.summary` | `text-overflow` | `ellipsis` | `ellipsis` |
| `.summary` | `white-space` | `nowrap` | `nowrap` |
| `.summary` | `font-size` | `min(13px, max(13px, 12px))` | `13px` |
| `.summary` | `line-height` | `24px` | `24px` |
| `.sep` | `width` | `2px` | `2px` |
| `.sep` | `height` | `2px` | `2px` |
| `.sep` | `border-radius` | `1px` | `1px` |
| `.sep` | `margin` | `0 8px` | `0 8px` |
| `.sep` | `background` | `rgb(173, 178, 184)` | `rgb(129, 133, 140)` |
| `.summarySuffix` | `margin-left` | `4px` | `4px` |
| `.summarySuffix` | `white-space` | `nowrap` | `nowrap` |
| `.summarySuffix` | `font-size` | `min(13px, max(13px, 12px))` | `13px` |
| `.summarySuffix` | `line-height` | `24px` | `24px` |

### turn_process

`packages/client/ui-chat/src/client/chat/TurnProcessNodeView.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.root` | `width` | `100%` | `100%` |
| `.root` | `min-width` | `0` | `0` |
| `.root` | `height` | `33px` | `33px` |
| `.root` | `padding` | `0 0 8px` | `0 0 8px` |
| `.root` | `border` | `none` | `none` |
| `.root` | `border-bottom` | `0.5px solid rgba(0, 0, 0, 0.1)` | `0.5px solid rgba(255, 255, 255, 0.12)` |
| `.root` | `background` | `none` | `none` |
| `.root` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.root` | `font` | `inherit` | `inherit` |
| `.root` | `font-size` | `14px` | `14px` |
| `.root` | `transition` | `color 100ms ease` | `color 100ms ease` |
| `.label` | `min-width` | `0` | `0` |
| `.label` | `overflow` | `hidden` | `hidden` |
| `.label` | `font-size` | `inherit` | `inherit` |
| `.label` | `line-height` | `24px` | `24px` |
| `.label` | `text-overflow` | `ellipsis` | `ellipsis` |
| `.label` | `white-space` | `nowrap` | `nowrap` |
| `.chevron` | `width` | `14px` | `14px` |
| `.chevron` | `height` | `14px` | `14px` |
| `.chevron` | `margin-left` | `4px` | `4px` |
| `.chevron` | `color` | `inherit` | `inherit` |
| `.chevron` | `transition` | `transform 100ms ease` | `transform 100ms ease` |

### chat_flow

`packages/client/ui-chat/src/client/chat/ChatView.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.scroll` | `min-height` | `0` | `0` |
| `.scroll` | `padding` | `16px calc(var(--dsh-composer-side-clearance) + 16px)` | `16px calc(var(--dsh-composer-side-clearance) + 16px)` |
| `.column` | `max-width` | `var(--dsh-chat-content-width)` | `var(--dsh-chat-content-width)` |
| `.column` | `width` | `100%` | `100%` |
| `.column` | `margin` | `0 auto` | `0 auto` |
| `.running` | `color` | `color-mix(in srgb, rgb(65, 118, 230) 70%, rgb(23, 37, 84))` | `color-mix(in srgb, rgb(86, 134, 254) 55%, rgb(173, 178, 184))` |
| `.running` | `font-size` | `12px` | `12px` |
| `.running` | `line-height` | `22px` | `22px` |
| `.runningContent` | `min-width` | `0` | `0` |
| `.runningContent` | `gap` | `6px` | `6px` |
| `.runningDivider` | `width` | `100%` | `100%` |
| `.runningDivider` | `height` | `0.5px` | `0.5px` |
| `.runningDivider` | `margin` | `8px 0 10px` | `8px 0 10px` |
| `.runningDivider` | `background` | `color-mix(in srgb, rgba(0, 0, 0, 0.04) 75%, rgba(0, 0, 0, 0.1))` | `color-mix(in srgb, rgba(255, 255, 255, 0.06) 75%, rgba(255, 255, 255, 0.12))` |
| `.toBottom` | `width` | `34px` | `34px` |
| `.toBottom` | `height` | `34px` | `34px` |
| `.toBottom` | `margin-top` | `-34px` | `-34px` |
| `.toBottom` | `padding` | `0` | `0` |
| `.toBottom` | `border` | `0` | `0` |
| `.toBottom` | `border-radius` | `100px` | `100px` |
| `.toBottom` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.toBottom` | `background` | `rgb(255, 255, 255)` | `rgb(44, 44, 46)` |
| `.toBottom` | `box-shadow` | `0 0 0 0.5px rgba(0, 0, 0, 0.16), 0 3px 8px 0 rgba(0, 0, 0, 0.03), 0 0 16px 0 rgba(0, 0, 0, 0.02)` | `var(--dsw-elevation-panel)` |

### group_seat

`packages/client/ui-chat/src/client/chat/ChatGroupSeat.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.label` | `min-width` | `0` | `0` |
| `.label` | `overflow` | `hidden` | `hidden` |
| `.label` | `text-overflow` | `ellipsis` | `ellipsis` |
| `.label` | `white-space` | `nowrap` | `nowrap` |
| `.body` | `max-height` | `min(400px, 50vh)` | `min(400px, 50vh)` |
| `.content` | `margin-top` | `6px` | `6px` |

### todo_panel

`packages/client/ui-conversation/src/client/skeleton/TodoPanel.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.root` | `overflow` | `hidden` | `hidden` |
| `.root` | `margin` | `0 auto` | `0 auto` |
| `.root` | `width` | `calc( 100% - var(--dsh-composer-side-clearance) - var(--dsh-composer-side-clearance) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) )` | `calc( 100% - var(--dsh-composer-side-clearance) - var(--dsh-composer-side-clearance) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) )` |
| `.root` | `max-width` | `calc( var(--dsh-composer-card-max-width) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) )` | `calc( var(--dsh-composer-card-max-width) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) )` |
| `.root` | `border` | `0` | `0` |
| `.root` | `border-radius` | `16px` | `var(--dsw-radius-lg)` |
| `.root` | `background` | `rgba(248, 249, 250, 0.94)` | `rgba(48, 49, 54, 0.94)` |
| `.root` | `backdrop-filter` | `blur(40px) saturate(150%)` | `var(--dsw-menu-backdrop-filter)` |
| `.root` | `box-shadow` | `0 0 0 0.5px rgba(0, 0, 0, 0.16), 0 3px 8px 0 rgba(0, 0, 0, 0.03), 0 0 16px 0 rgba(0, 0, 0, 0.02)` | `var(--dsw-elevation-panel)` |
| `.header` | `gap` | `10px` | `10px` |
| `.header` | `width` | `100%` | `100%` |
| `.header` | `padding` | `0` | `0` |
| `.header` | `border` | `none` | `none` |
| `.header` | `background` | `transparent` | `transparent` |
| `.title` | `font-size` | `13px` | `13px` |
| `.title` | `line-height` | `24px` | `24px` |
| `.title` | `font-weight` | `500` | `500` |
| `.title` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.progress` | `min-width` | `0` | `0` |
| `.progress` | `overflow` | `hidden` | `hidden` |
| `.progress` | `font-size` | `13px` | `13px` |
| `.progress` | `line-height` | `20px` | `20px` |
| `.progress` | `font-weight` | `400` | `400` |
| `.progress` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.progress` | `text-overflow` | `ellipsis` | `ellipsis` |
| `.progress` | `white-space` | `nowrap` | `nowrap` |
| `.list` | `gap` | `8px` | `8px` |
| `.list` | `margin` | `0` | `0` |
| `.list` | `padding` | `0` | `0` |
| `.list` | `max-height` | `180px` | `180px` |
| `.item` | `gap` | `10px` | `10px` |
| `.item` | `min-width` | `0` | `0` |
| `.item` | `font-size` | `13px` | `13px` |
| `.item` | `line-height` | `20px` | `20px` |
| `.item` | `color` | `rgb(97, 102, 107)` | `rgb(207, 211, 214)` |

### plan_chip

`packages/client/ui-plan/src/client/PlanModeControl.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.chip` | `gap` | `4px` | `4px` |
| `.chip` | `height` | `28px` | `28px` |
| `.chip` | `min-width` | `34px` | `34px` |
| `.chip` | `padding` | `0 8px` | `0 8px` |
| `.chip` | `border` | `none` | `none` |
| `.chip` | `border-radius` | `8px` | `var(--dsw-radius-sm)` |
| `.chip` | `background` | `rgb(228, 237, 253)` | `rgb(52, 65, 91)` |
| `.chip` | `color` | `rgb(65, 118, 230)` | `rgb(122, 170, 255)` |
| `.chip` | `font-size` | `13px` | `13px` |
| `.chip` | `font-weight` | `500` | `500` |
| `.chip` | `line-height` | `20px` | `20px` |

### plan_review

`packages/client/ui-user-questions/src/client/PlanReviewPanel.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.card` | `overflow` | `hidden` | `hidden` |
| `.card` | `width` | `100%` | `100%` |
| `.card` | `max-width` | `var(--dsh-chat-content-width)` | `var(--dsh-chat-content-width)` |
| `.card` | `border` | `0` | `0` |
| `.card` | `border-radius` | `20px` | `var(--dsw-radius-xl)` |
| `.card` | `background` | `rgb(255, 255, 255)` | `rgb(44, 44, 46)` |
| `.card` | `box-shadow` | `0 0 0 0.5px rgba(0, 0, 0, 0.16), 0 3px 8px 0 rgba(0, 0, 0, 0.03), 0 0 16px 0 rgba(0, 0, 0, 0.02)` | `var(--dsw-elevation-panel)` |
| `.card` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.strip` | `gap` | `8px` | `8px` |
| `.strip` | `padding` | `12px 16px` | `12px 16px` |
| `.strip` | `background` | `rgb(254, 245, 231)` | `rgb(39, 36, 31)` |
| `.strip` | `color` | `rgb(245, 158, 11)` | `rgb(245, 158, 11)` |
| `.strip` | `font-size` | `14px` | `14px` |
| `.strip` | `line-height` | `20px` | `20px` |
| `.summary` | `min-width` | `0` | `0` |
| `.summary` | `padding` | `14px 16px 12px` | `14px 16px 12px` |
| `.footer` | `gap` | `12px` | `12px` |
| `.footer` | `padding` | `8px 16px 12px` | `8px 16px 12px` |

### plan_card

`packages/client/ui-plan/src/client/PlanPreview.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.card` | `gap` | `10px` | `10px` |
| `.card` | `min-width` | `0` | `0` |
| `.card` | `width` | `100%` | `100%` |
| `.card` | `height` | `60px` | `60px` |
| `.card` | `padding` | `8px 10px` | `8px 10px` |
| `.card` | `margin` | `0` | `0` |
| `.card` | `border` | `0.5px solid rgba(0, 0, 0, 0.04)` | `0.5px solid rgba(255, 255, 255, 0.06)` |
| `.card` | `border-radius` | `16px` | `var(--dsw-radius-lg)` |
| `.card` | `background` | `var(--plan-card-fill)` | `var(--plan-card-fill)` |
| `.card` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.card` | `font` | `inherit` | `inherit` |
| `.card` | `transition` | `background-color 120ms ease` | `background-color 120ms ease` |
| `.cards` | `gap` | `10px` | `10px` |
| `.cardIcon` | `width` | `40px` | `40px` |
| `.cardIcon` | `height` | `40px` | `40px` |
| `.cardIcon` | `border` | `0.5px solid rgba(0, 0, 0, 0.04)` | `0.5px solid rgba(255, 255, 255, 0.06)` |
| `.cardIcon` | `border-radius` | `10px` | `10px` |
| `.cardIcon` | `background` | `color-mix(in srgb, rgb(255, 255, 255) 50%, transparent)` | `color-mix(in srgb, rgb(255, 255, 255) 50%, transparent)` |
| `.cardDetails` | `gap` | `2px` | `2px` |
| `.cardDetails` | `min-width` | `0` | `0` |
| `.cardTitle` | `overflow` | `hidden` | `hidden` |
| `.cardTitle` | `text-overflow` | `ellipsis` | `ellipsis` |
| `.cardTitle` | `white-space` | `nowrap` | `nowrap` |
| `.cardTitle` | `font-size` | `13px` | `13px` |
| `.cardTitle` | `font-weight` | `500` | `500` |
| `.cardTitle` | `line-height` | `20px` | `20px` |
| `.cardDescription` | `overflow` | `hidden` | `hidden` |
| `.cardDescription` | `text-overflow` | `ellipsis` | `ellipsis` |
| `.cardDescription` | `white-space` | `nowrap` | `nowrap` |
| `.cardDescription` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.cardDescription` | `font-size` | `10px` | `10px` |
| `.cardDescription` | `line-height` | `16px` | `16px` |
| `.cardOpen` | `height` | `28px` | `28px` |
| `.cardOpen` | `padding` | `4px 8px` | `4px 8px` |
| `.cardOpen` | `border` | `0.5px solid rgba(0, 0, 0, 0.12)` | `0.5px solid rgba(255, 255, 255, 0.16)` |
| `.cardOpen` | `border-radius` | `8px` | `var(--dsw-radius-sm)` |
| `.cardOpen` | `background` | `rgb(255, 255, 255)` | `rgb(44, 44, 46)` |
| `.cardOpen` | `font-size` | `12px` | `12px` |
| `.cardOpen` | `line-height` | `18px` | `18px` |

### question_composer

`packages/client/ui-user-questions/src/client/QuestionComposer.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.card` | `width` | `100%` | `100%` |
| `.card` | `max-width` | `var(--dsh-chat-content-width)` | `var(--dsh-chat-content-width)` |
| `.card` | `max-height` | `min(60vh, 520px)` | `min(60vh, 520px)` |
| `.card` | `padding` | `0 0 10px` | `0 0 10px` |
| `.card` | `border` | `0` | `0` |
| `.card` | `border-radius` | `20px` | `var(--dsw-radius-xl)` |
| `.card` | `background` | `rgb(255, 255, 255)` | `rgb(44, 44, 46)` |
| `.card` | `box-shadow` | `0 0 0 0.5px rgba(0, 0, 0, 0.16), 0 3px 8px 0 rgba(0, 0, 0, 0.03), 0 0 16px 0 rgba(0, 0, 0, 0.02)` | `var(--dsw-elevation-panel)` |
| `.card` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.card` | `overflow` | `hidden` | `hidden` |
| `.header` | `gap` | `16px` | `16px` |
| `.header` | `padding` | `20px 16px 0 24px` | `20px 16px 0 24px` |
| `.title` | `margin` | `0` | `0` |
| `.title` | `font-size` | `16px` | `16px` |
| `.title` | `line-height` | `22px` | `22px` |
| `.title` | `font-weight` | `500` | `500` |
| `.option` | `gap` | `8px` | `8px` |
| `.option` | `width` | `100%` | `100%` |
| `.option` | `min-height` | `40px` | `40px` |
| `.option` | `padding` | `8px 12px 8px 8px` | `8px 12px 8px 8px` |
| `.option` | `border` | `1px solid transparent` | `1px solid transparent` |
| `.option` | `border-radius` | `12px` | `var(--dsw-radius-md)` |
| `.option` | `background` | `transparent` | `transparent` |
| `.option` | `color` | `inherit` | `inherit` |
| `.option` | `transition` | `background-color 120ms ease, border-color 120ms ease` | `background-color 120ms ease, border-color 120ms ease` |
| `.footer` | `gap` | `12px` | `12px` |
| `.footer` | `margin-top` | `12px` | `12px` |
| `.footer` | `padding` | `0 10px 0 18px` | `0 10px 0 18px` |
| `.body` | `min-height` | `0` | `0` |

### question_reply

`packages/client/ui-user-questions/src/client/QuestionReplyView.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.row` | `gap` | `6px` | `6px` |
| `.row` | `padding` | `4px 0` | `4px 0` |
| `.bubble` | `max-width` | `72%` | `72%` |
| `.bubble` | `padding` | `10px 16px` | `10px 16px` |
| `.bubble` | `border-radius` | `20px` | `var(--dsw-radius-xl)` |
| `.bubble` | `background` | `rgb(237, 243, 254)` | `rgb(44, 44, 46)` |
| `.bubble` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.bubble` | `font-size` | `14px` | `14px` |
| `.bubble` | `line-height` | `22px` | `22px` |
| `.bubble` | `white-space` | `pre-wrap` | `pre-wrap` |
| `.actions` | `gap` | `8px` | `8px` |
| `.actions` | `height` | `28px` | `28px` |
| `.actions` | `padding-right` | `4px` | `4px` |
| `.actions` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |

### turn_trigger

`packages/client/ui-chat/src/client/chat/TurnTriggerNodeView.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.root` | `min-width` | `0` | `0` |
| `.root` | `border` | `0.5px solid rgba(0, 0, 0, 0.04)` | `0.5px solid rgba(255, 255, 255, 0.06)` |
| `.root` | `border-radius` | `20px` | `var(--dsw-radius-xl)` |
| `.root` | `background` | `rgb(249, 250, 251)` | `rgba(255, 255, 255, 0.08)` |
| `.root` | `transition` | `background-color 100ms ease` | `background-color 100ms ease` |
| `.header` | `gap` | `10px` | `10px` |
| `.header` | `width` | `100%` | `100%` |
| `.header` | `padding` | `12px 16px` | `12px 16px` |
| `.header` | `border` | `0` | `0` |
| `.header` | `background` | `none` | `none` |
| `.header` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.header` | `transition` | `color 100ms ease` | `color 100ms ease` |
| `.header` | `font` | `inherit` | `inherit` |
| `.title` | `font-size` | `14px` | `14px` |
| `.body` | `padding` | `0 16px 12px 40px` | `0 16px 12px 40px` |

### composer

`packages/client/ui-conversation/src/client/skeleton/InputBar.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.card` | `gap` | `12px` | `12px` |
| `.card` | `width` | `100%` | `100%` |
| `.card` | `max-width` | `var(--dsh-composer-card-max-width)` | `var(--dsh-composer-card-max-width)` |
| `.card` | `padding-top` | `8px` | `8px` |
| `.card` | `border` | `0` | `0` |
| `.card` | `border-radius` | `28px` | `var(--dsw-radius-panel)` |
| `.card` | `background` | `rgb(255, 255, 255)` | `rgb(44, 44, 46)` |
| `.card` | `box-shadow` | `0 0 0 0.5px rgba(0, 0, 0, 0.16), 0 4px 16px 0 rgba(0, 0, 0, 0.03), 0 0 24px 0 rgba(0, 0, 0, 0.03)` | `var(--dsw-elevation-soft)` |
| `.card` | `font-size` | `14px` | `14px` |
| `.card` | `line-height` | `24px` | `24px` |
| `.row` | `gap` | `12px` | `12px` |
| `.row` | `padding` | `2px 8px 6px` | `2px 8px 6px` |
| `.row` | `min-width` | `0` | `0` |
| `.input` | `min-height` | `36px` | `36px` |
| `.input` | `padding` | `4px 8px 0 14px` | `4px 8px 0 14px` |
| `.input` | `font-size` | `inherit` | `inherit` |
| `.input` | `line-height` | `inherit` | `inherit` |
| `.input` | `white-space` | `pre-wrap` | `pre-wrap` |
| `.input` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.primary` | `width` | `34px` | `34px` |
| `.primary` | `height` | `34px` | `34px` |
| `.primary` | `border` | `none` | `none` |
| `.primary` | `border-radius` | `999px` | `999px` |
| `.primary` | `background` | `rgb(65, 118, 230)` | `rgb(122, 170, 255)` |
| `.primary` | `color` | `#fff` | `#fff` |
| `.primary` | `transition` | `background-color 100ms ease` | `background-color 100ms ease` |
| `.primary` | `transform` | `translateY(-2px)` | `translateY(-2px)` |
| `.add` | `width` | `28px` | `28px` |
| `.add` | `height` | `28px` | `28px` |
| `.add` | `border` | `none` | `none` |
| `.add` | `border-radius` | `999px` | `999px` |
| `.add` | `background` | `rgb(245, 246, 247)` | `rgb(53, 54, 56)` |
| `.add` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.select` | `max-width` | `220px` | `220px` |
| `.select` | `height` | `28px` | `28px` |
| `.select` | `padding` | `0 20px 0 8px` | `0 20px 0 8px` |
| `.select` | `border` | `none` | `none` |
| `.select` | `border-radius` | `8px` | `var(--dsw-radius-sm)` |
| `.select` | `background-color` | `transparent` | `transparent` |
| `.select` | `color` | `rgb(97, 102, 107)` | `rgb(207, 211, 214)` |
| `.select` | `font-size` | `13px` | `13px` |
| `.select` | `line-height` | `20px` | `20px` |
| `.select` | `font-weight` | `500` | `500` |
| `.select` | `white-space` | `nowrap` | `nowrap` |

### header

`packages/client/ui-conversation/src/client/skeleton/ConversationRoot.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.header` | `min-height` | `76px` | `76px` |
| `.header` | `padding` | `10px 28px 0 20px` | `10px 28px 0 20px` |
| `.header` | `border-bottom` | `0.5px solid rgba(0, 0, 0, 0.12)` | `0.5px solid rgba(255, 255, 255, 0.16)` |
| `.titleRow` | `gap` | `0` | `0` |
| `.titleRow` | `min-height` | `30px` | `30px` |
| `.crumb` | `max-width` | `220px` | `220px` |
| `.crumb` | `overflow` | `hidden` | `hidden` |
| `.crumb` | `padding` | `4px 8px` | `4px 8px` |
| `.crumb` | `border` | `none` | `none` |
| `.crumb` | `border-radius` | `12px` | `var(--dsw-radius-md)` |
| `.crumb` | `background` | `transparent` | `transparent` |
| `.crumb` | `font-size` | `14px` | `14px` |
| `.crumb` | `line-height` | `20px` | `20px` |
| `.crumb` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.crumb` | `text-overflow` | `ellipsis` | `ellipsis` |
| `.crumb` | `white-space` | `nowrap` | `nowrap` |
| `.crumbCurrent` | `font-weight` | `500` | `500` |
| `.crumbCurrent` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.headerActions` | `gap` | `8px` | `8px` |
| `.headerUtilities` | `gap` | `8px` | `8px` |
| `.headerUtilities` | `margin-left` | `20px` | `20px` |
| `.tabs` | `gap` | `36px` | `36px` |
| `.tabs` | `margin-top` | `10px` | `10px` |
| `.tabs` | `padding-left` | `8px` | `8px` |
| `.tab` | `padding` | `0 0 9px` | `0 0 9px` |
| `.tab` | `border` | `none` | `none` |
| `.tab` | `background` | `transparent` | `transparent` |
| `.tab` | `font-size` | `13px` | `13px` |
| `.tab` | `line-height` | `16px` | `16px` |
| `.tab` | `font-weight` | `500` | `500` |
| `.tab` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.tabActive` | `color` | `rgb(65, 118, 230)` | `rgb(122, 170, 255)` |

### turn_tail

`packages/client/ui-chat/src/client/chat/TurnTailNodeView.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.root` | `gap` | `16px` | `16px` |
| `.actions` | `margin-top` | `4px` | `4px` |
| `.actions` | `margin-left` | `-6px` | `-6px` |

### message_actions

`packages/client/ui-chat/src/client/chat/MessageIconActions.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.actions` | `gap` | `8px` | `8px` |
| `.actions` | `height` | `28px` | `28px` |
| `.action` | `width` | `28px` | `28px` |
| `.action` | `height` | `28px` | `28px` |
| `.action` | `padding` | `6px` | `6px` |
| `.action` | `border` | `none` | `none` |
| `.action` | `border-radius` | `8px` | `var(--dsw-radius-sm)` |
| `.action` | `background` | `transparent` | `transparent` |
| `.action` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.timeStart` | `padding-right` | `12px` | `12px` |
| `.timeStart` | `font-size` | `min(13px, max(13px, 12px))` | `13px` |
| `.timeStart` | `line-height` | `24px` | `24px` |
| `.timeStart` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.timeStart` | `white-space` | `nowrap` | `nowrap` |
| `.timeEnd` | `font-size` | `calc(min(13px, max(13px, 12px)) - 1px)` | `12px` |
| `.timeEnd` | `line-height` | `24px` | `24px` |
| `.timeEnd` | `color` | `inherit` | `inherit` |
| `.timeEnd` | `white-space` | `nowrap` | `nowrap` |

### stats_pills

`packages/client/ui-chat/src/client/chat/StatsPills.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.anchor` | `min-width` | `0` | `0` |
| `.anchor` | `font-size` | `calc(min(13px, max(13px, 12px)) - 1px)` | `12px` |
| `.anchor` | `line-height` | `calc(20px + calc(min(13px, max(13px, 12px)) - 13px))` | `20px` |
| `.pill` | `gap` | `6px` | `6px` |
| `.pill` | `max-width` | `100%` | `100%` |
| `.pill` | `padding` | `1px 8px` | `1px 8px` |
| `.pill` | `border` | `none` | `none` |
| `.pill` | `border-radius` | `8px` | `var(--dsw-radius-sm)` |
| `.pill` | `background` | `transparent` | `transparent` |
| `.pill` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.pill` | `font` | `inherit` | `inherit` |
| `.pill` | `line-height` | `inherit` | `inherit` |
| `.pill` | `white-space` | `nowrap` | `nowrap` |
| `.label` | `min-width` | `0` | `0` |
| `.label` | `overflow` | `hidden` | `hidden` |
| `.label` | `text-overflow` | `ellipsis` | `ellipsis` |

### queue_dock

`packages/client/ui-conversation/src/client/queue/QueueDock.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.dock` | `width` | `calc( 100% - var(--dsh-composer-side-clearance) - var(--dsh-composer-side-clearance) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) )` | `calc( 100% - var(--dsh-composer-side-clearance) - var(--dsh-composer-side-clearance) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) )` |
| `.dock` | `max-width` | `calc( var(--dsh-composer-card-max-width) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) )` | `calc( var(--dsh-composer-card-max-width) - var(--dsh-composer-dock-inset) - var(--dsh-composer-dock-inset) )` |
| `.dock` | `margin` | `0 auto calc(0px - var(--dsh-composer-stack-gap) - 3px)` | `0 auto calc(0px - var(--dsh-composer-stack-gap) - 3px)` |
| `.dock` | `padding` | `0 var(--dsh-composer-dock-inset)` | `0 var(--dsh-composer-dock-inset)` |
| `.panel` | `overflow` | `hidden` | `hidden` |
| `.panel` | `width` | `100%` | `100%` |
| `.panel` | `padding` | `2px 0` | `2px 0` |
| `.panel` | `border-radius` | `16px 16px 0 0` | `var(--dsw-radius-lg) var(--dsw-radius-lg) 0 0` |
| `.header` | `gap` | `10px` | `10px` |
| `.header` | `width` | `100%` | `100%` |
| `.header` | `height` | `36px` | `36px` |
| `.header` | `padding` | `4px 12px` | `4px 12px` |
| `.header` | `border` | `none` | `none` |
| `.header` | `border-radius` | `12px` | `var(--dsw-radius-md)` |
| `.header` | `background` | `transparent` | `transparent` |
| `.header` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.row` | `gap` | `10px` | `10px` |
| `.row` | `width` | `100%` | `100%` |
| `.row` | `min-height` | `36px` | `36px` |
| `.row` | `padding` | `4px 5px 4px 12px` | `4px 5px 4px 12px` |
| `.row` | `border-radius` | `12px` | `var(--dsw-radius-md)` |

### approval_panel

`packages/client/ui-approval/src/client/ApprovalPanel.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.root` | `padding` | `8px calc(var(--dsh-composer-side-clearance) + 16px) 12px` | `8px calc(var(--dsh-composer-side-clearance) + 16px) 12px` |
| `.card` | `overflow` | `hidden` | `hidden` |
| `.card` | `width` | `100%` | `100%` |
| `.card` | `max-width` | `var(--dsh-chat-content-width)` | `var(--dsh-chat-content-width)` |
| `.card` | `border` | `1px solid rgb(247, 173, 49)` | `1px solid rgb(247, 173, 49)` |
| `.card` | `border-radius` | `20px` | `var(--dsw-radius-xl)` |
| `.card` | `background` | `rgb(255, 255, 255)` | `rgb(44, 44, 46)` |
| `.card` | `box-shadow` | `0 4px 12px 0 rgba(0, 0, 0, 0.02), 0 2px 8px 0 rgba(0, 0, 0, 0.04)` | `var(--dsw-shadow-lv2)` |
| `.strip` | `gap` | `8px` | `8px` |
| `.strip` | `padding` | `10px 16px` | `10px 16px` |
| `.strip` | `background` | `rgb(254, 245, 231)` | `rgb(39, 36, 31)` |
| `.strip` | `color` | `rgb(245, 158, 11)` | `rgb(245, 158, 11)` |
| `.strip` | `font-size` | `13px` | `13px` |
| `.strip` | `line-height` | `18px` | `18px` |
| `.actionRow` | `gap` | `8px` | `8px` |
| `.actionRow` | `padding` | `14px 16px` | `14px 16px` |

### subagent_menu

`packages/client/ui-subagent/src/client/SubagentHeaderLineage.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.trigger` | `min-height` | `28px` | `28px` |
| `.trigger` | `padding` | `3px 2px` | `3px 2px` |
| `.trigger` | `border` | `0` | `0` |
| `.trigger` | `border-radius` | `8px` | `var(--dsw-radius-sm)` |
| `.trigger` | `background` | `transparent` | `transparent` |
| `.trigger` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.trigger` | `font-size` | `12px` | `12px` |
| `.trigger` | `line-height` | `18px` | `18px` |
| `.switcherTrigger` | `min-height` | `28px` | `28px` |
| `.switcherTrigger` | `padding` | `3px 2px` | `3px 2px` |
| `.switcherTrigger` | `border` | `0` | `0` |
| `.switcherTrigger` | `border-radius` | `8px` | `var(--dsw-radius-sm)` |
| `.switcherTrigger` | `background` | `transparent` | `transparent` |
| `.switcherTrigger` | `color` | `rgb(129, 133, 140)` | `rgb(173, 178, 184)` |
| `.switcherTrigger` | `font-size` | `12px` | `12px` |
| `.switcherTrigger` | `line-height` | `18px` | `18px` |
| `.menu` | `width` | `336px` | `336px` |
| `.menu` | `max-width` | `min(400px, calc(100vw - 32px))` | `min(400px, calc(100vw - 32px))` |
| `.menu` | `max-height` | `min(560px, calc(100vh - 140px))` | `min(560px, calc(100vh - 140px))` |
| `.menu` | `padding` | `4px` | `4px` |
| `.menu` | `overflow` | `hidden` | `hidden` |
| `.menu` | `border-radius` | `16px` | `var(--dsw-radius-lg)` |
| `.menu` | `box-shadow` | `0 0 0 0.5px rgba(0, 0, 0, 0.16), 0 3px 8px 0 rgba(0, 0, 0, 0.04), 0 0 20px 0 rgba(0, 0, 0, 0.05)` | `var(--dsw-elevation-prominent)` |
| `.row` | `gap` | `6px` | `6px` |
| `.row` | `width` | `100%` | `100%` |
| `.row` | `min-height` | `44px` | `44px` |
| `.row` | `padding` | `6px 7px 6px 9px` | `6px 7px 6px 9px` |
| `.row` | `border` | `0` | `0` |
| `.row` | `border-radius` | `12px` | `var(--dsw-radius-md)` |
| `.row` | `background` | `transparent` | `transparent` |
| `.row` | `color` | `rgb(15, 17, 21)` | `rgb(249, 250, 251)` |
| `.row` | `font-size` | `12px` | `12px` |
| `.row` | `line-height` | `17px` | `17px` |

### code_card

`packages/client/ui-primitives/src/CodeCard.module.css`

| class | 属性 | light | dark |
|---|---|---|---|
| `.body` | `padding` | `6px 22px 20px` | `6px 22px 20px` |
| `.body` | `font` | `11px / 19px 'SF Mono', 'JetBrains Mono', 'Fira Code', Consolas, 'Liberation Mono', Menlo, Courier, 'PingFang SC', 'Microsoft YaHei', 'SF Mono', 'JetBrains Mono', 'Fira Code', Consolas, 'Liberation Mono', Menlo, Courier, 'PingFang SC', 'Microsoft YaHei'` | `var(--dsw-font-markdown-code-block)` |

## 4. iOS 当前关键探针

### transcript_horizontal_padding

- `ChatPage.swift:154` — `.padding(.horizontal, 104)`
- `ChatPage.swift:204` — `.padding(.horizontal, 16)`
- `ChatPage.swift:332` — `.padding(.horizontal, 16)`
- `ChatPage.swift:568` — `.padding(.horizontal, 16)`
- `ChatPage.swift:691` — `.padding(.horizontal, 4)`
- `ChatPage.swift:719` — `.padding(.horizontal, 16)`
- `ChatPage.swift:731` — `.padding(.horizontal, 16)`
- `ChatPage.swift:925` — `.padding(.horizontal, 12)`
- `ChatPage.swift:1080` — `.padding(.horizontal, 16)`
- `ChatPage.swift:1122` — `.padding(.horizontal, 10)`
- `ChatPage.swift:1170` — `.padding(.horizontal, 10)`
- `ChatPage.swift:1325` — `.padding(.horizontal, 16)`
- `ChatPage.swift:1509` — `.padding(.horizontal, 5)`
- `ChatPage.swift:1612` — `.padding(.horizontal, 5)`
- `ChatPage.swift:1622` — `.padding(.horizontal, 4)`
- `ChatPage.swift:1966` — `.padding(.horizontal, 12)`
- `ChatPage.swift:2019` — `.padding(.horizontal, 12).padding(.vertical, 8)`
- `ChatPage.swift:2034` — `.padding(.horizontal, 12).padding(.vertical, 8)`
- `ChatPage.swift:2467` — `.padding(.horizontal, 16)`
- `ChatPage.swift:2825` — `.padding(.horizontal, 16)`
- `ChatPage.swift:2834` — `.padding(.horizontal, 16)`
- `ChatPage.swift:3010` — `.padding(.horizontal, 12)`
- `ChatPage.swift:3086` — `.padding(.horizontal, 16)`

### header_frame_height

- `ChatPage.swift:181` — `.frame(height: 44)`
- `ChatPage.swift:209` — `.frame(height: 0.5)`
- `ChatPage.swift:838` — `.frame(height: 1)`
- `ChatPage.swift:1039` — `.frame(height: 50)`
- `ChatPage.swift:1123` — `.frame(height: 40)`
- `ChatPage.swift:1171` — `.frame(height: 28)`
- `ChatPage.swift:1300` — `.frame(height: 32)`
- `ChatPage.swift:1510` — `.frame(height: 28)`
- `ChatPage.swift:1613` — `.frame(height: 28)`
- `ChatPage.swift:1623` — `.frame(height: 32)`
- `ChatPage.swift:2532` — `.frame(height: 28)`
- `ChatPage.swift:3065` — `.frame(height: 48)`
- `ChatPage.swift:3078` — `.frame(height: 44)`

### composer_corner_radius

- `ChatPage.swift:792` — `.background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))`
- `ChatPage.swift:929` — `.background(Self.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))`
- `ChatPage.swift:930` — `.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)`
- `ChatPage.swift:1013` — `.background(Self.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))`
- `ChatPage.swift:1040` — `.background(ChatPage.accent, in: RoundedRectangle(cornerRadius: 12))`
- `ChatPage.swift:1125` — `in: RoundedRectangle(cornerRadius: 10, style: .continuous))`
- `ChatPage.swift:1173` — `in: RoundedRectangle(cornerRadius: 8, style: .continuous))`
- `ChatPage.swift:1976` — `in: RoundedRectangle(cornerRadius: 14, style: .continuous))`
- `ChatPage.swift:2043` — `.background(NativeChatTheme.selector, in: RoundedRectangle(cornerRadius: 14, style: .continuous))`
- `ChatPage.swift:2323` — `.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))`
- `ChatPage.swift:2880` — `.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))`
- `ChatPage.swift:2973` — `.background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 9))`
- `ChatPage.swift:3012` — `.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))`
- `ChatPage.swift:3066` — `.background(ChatPage.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))`
- `ChatPage.swift:3085` — `.background(ChatPage.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))`

### font_17_semibold

- `ChatPage.swift:999` — `.font(.system(size: 17, weight: .semibold))`
- `ChatPage.swift:1010` — `.font(.system(size: 17, weight: .semibold))`
- `ChatPage.swift:1027` — `.font(.system(size: 17, weight: .semibold))`
- `ChatPage.swift:1036` — `.font(.system(size: 17, weight: .semibold))`
- `ChatPage.swift:3062` — `.font(.system(size: 17, weight: .semibold))`

### font_14_body

- `ChatPage.swift:2418` — `.font(NativeChatTheme.bodyFont())`
- `ChatPage.swift:2459` — `.font(NativeChatTheme.bodyFont())`

### line_spacing

- `ChatPage.swift:1275` — `.lineSpacing(NativeParityTokens.composerLineSpacing)`
- `ChatPage.swift:2421` — `.lineSpacing(NativeChatTheme.bodyLineSpacing)`
- `ChatPage.swift:2460` — `.lineSpacing(NativeParityTokens.userBubbleLineSpacing)`

### max_width_296

- 0 命中

### min_height_36

- `ChatPage.swift:1278` — `.frame(minHeight: 36, maxHeight: 336)`
- `ChatPage.swift:1284` — `.frame(minHeight: 36)`

### max_height_336

- `ChatPage.swift:1278` — `.frame(minHeight: 36, maxHeight: 336)`

### enter_key_hint

- `ChatPage.swift:1188` — `onSubmit: { submitQuestion($0) },`

### todo_terms

- 0 命中

### plan_terms

- `ChatPage.swift:1421` — `if let plan = model.planModeState, plan.isPlanTarget {`
- `ChatPage.swift:1422` — `NativePlanChip(mode: plan,`
- `ChatModel.swift:234` — `/// page consumes `todos/plan/inbox/userQuestions/subagentCatalog/goal/title``
- `ChatModel.swift:258` — `var planModeState: NativePlanModeState? {`
- `ChatModel.swift:264` — `/// `/plan off` through the live command registry, then refresh the folded`

### turn_process_terms

- 0 命中

### trigger_terms

- `ChatPage.swift:2372` — `// inbox/spliced: the official turn-trigger notice, not a raw`
- `ChatModel.swift:1773` — `// rendered as a turn-trigger/context row, never as a user bubble.`

### inbox_terms

- `ChatPage.swift:2372` — `// inbox/spliced: the official turn-trigger notice, not a raw`
- `ChatModel.swift:234` — `/// page consumes `todos/plan/inbox/userQuestions/subagentCatalog/goal/title``
- `ChatModel.swift:239` — `var projectedInbox: JSONValue? { projectionValues?["inbox"] }`
- `ChatModel.swift:1638` — `"llm/retry", "request/header", "agent/inbox/spliced": category = .requestBoundary`
- `ChatModel.swift:1776` — `case .inboxSpliced(let messages):`
- `ChatModel.swift:1783` — `event: event, idSuffix: "inbox-\(index)")`
- `DSHManagementModel.swift:471` — `(values["inbox"]?[lane]?.arrayValue ?? []).compactMap { item in`

### subagent_terms

- `ChatPage.swift:111` — `/// Official `subagentCatalog` projection → the header catalog view model.`
- `ChatPage.swift:124` — `parentID: row["parentSessionId"]?.stringValue,`
- `ChatModel.swift:234` — `/// page consumes `todos/plan/inbox/userQuestions/subagentCatalog/goal/title``
- `ChatModel.swift:241` — `var projectedSubagents: JSONValue? { projectionValues?["subagentCatalog"] }`
- `DSHManagementModel.swift:575` — `subagents = (values["subagentCatalog"]?.arrayValue ?? []).compactMap { row in`
- `DSHManagementModel.swift:663` — `"childSessionId": .string(row.id), "parentSessionId": .string(parentSessionID), "mode": .string("continuable"),`
- `DSHManagementModel.swift:921` — `parentSessionID: item["parentSessionId"]?.stringValue,`

## 5. iOS theme token

| name | light | dark |
|---|---|---|

字体：

## 6. 建议人工复核

1. 优先看 §1 的“未被报告提到”清单；把真实漏项补进对应轴报告。
2. 看 §2.2 的 generic toolview 清单；确认是否有高价值 key 需要专用卡。
3. 看 §2.4 的 projection：`todos/plan/subagentCatalog` 已能读但只在不可达活动页；`inbox/userQuestions` 未读。
4. 对照 §3 的 base metrics 与 iOS 探针，确认 master §6 的数值没有被实现漂移。
5. 官方 402pt 截图仍然缺失；本脚本不能替代 golden 截图。
