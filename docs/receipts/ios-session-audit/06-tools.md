# Axis 06 — 工具行 / 工具卡 / 嵌套调用 —— iOS Session 对齐审计

> 审计对象：官方 DSH（commit `7be5505b0b`，`0.2.1-rc.2`）与 iOS PhoneDSH 在 **session 会话页 transcript 里工具调用的全部呈现**。
> 视觉基准宽度 402pt（CSS px ≈ iOS pt）。所有结论只基于源码静态阅读 + 截图观察，**未运行任何构建/测试**。

## 0. 结论摘要

1. **官方 shipped web-app composition 实际注册了 54 个 `tool.call.toolview` key**（不是 BRIEF 里估的 51；精确清单见 §2.1）。iOS 只有 7 个 `NativeToolCallModel.Variant` + 6 条标题特判（`NativeToolCallModel.swift:19-63`），**其中 37 个 `DetailsRow` key、`skill`、`present`、4 个 `cordis_*` key 在 iOS 完全没有专用标题、图标与卡片，一律落到通用「工具调用」行**。
2. **⚠ 最严重的不是 UI，而是数据**：iOS 的 `ChatItem.toolMetadata` **只在历史投影路径写入**（`NativeTranscriptProjector.swift:95,107` ← `data["meta"]`），**实时事件路径 `ChatModel.handle(.toolResult)` 完全不写 `meta`**（`ChatModel.swift:1731-1752`），`DSHEventMapper.map` 也不搬 `meta`（`DSHEventMapper.swift:108-116`）。后果：会话进行中的 terminal / read / search / web / diff 卡片**全部降级为通用 IN/OUT 卡**，只有重新加载会话（走 projector）后才"变回"卡片。这是 P0。
3. **嵌套 subcall 完全不存在**：官方 `ToolCallTree` 递归渲染 `subCalls`，数据来自 `tool/ptc-dispatch-start` / `tool/ptc-dispatch`（`ui-chat/.../conversation-nodes/tool.ts:199-216`，`MAX_DEPTH=256`，`:19`）。iOS 源码里 `ptc-dispatch` / `parentCallId` / `subCalls` **零命中**（§6 给了穷尽搜索命令）。P0。
4. **preparing（参数还没齐就先出现一行）完全不存在**：官方由 `assistant/live-chunk` 的 `tool-call-delta` 建 `phase:'preparing'` 行；iOS 的 `NativeToolState.preparing` 是**死枚举值**（全仓库无任何赋值），且 `DSHRemoteHarness` 的 `assistant-stream` 分支只转 `text-delta` / `reasoning-delta`，`tool-call-delta` 被 `default: break` 丢弃（`DSHRemoteHarness.swift:352-363`）。P0。
5. **折叠行骨架的几何其实已经对了**（16px 图标盒 + 6 + 13/24 标题 + 2×2 圆点 + 8/8 + 13/24 省略号 summary + 24pt 行高），但**状态语义、颜色 token、后缀（exit code 胶囊 / `+N -M` / `{KB}`）、卡片几何（圆角 12 vs 16、描边 `#E4E4E8` vs `rgba(0,0,0,.04)`、代码 12pt vs 11pt）全部不同**。P1/P2 密集。
6. 统计：**P0 = 4，P1 = 16，P2 = 9，P3 = 4**（共 33 条，全量在 §4；§2/§3 是两个仓库的分面基线）。

## 1. 审计范围与方法

### 1.1 读过的官方文件（`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`）

- 组合与注册：`packages/bundle/web-app/package.json`（shipped 客户端包清单）、`packages/client/ui-tool/src/client/apply.ts`、`src/client/index.ts`、`src/client/contract/slots.ts`
- toolview 注册点（全 12 个文件）：`tool/toolviews/{bash-sample,read-row,read-family-row,read-image-row,file-mutation-row,search-row,web-row,todo-row,details-row,ask-question-row,GenericToolCard}.tsx`；`packages/client/ui-skill/src/client/index.ts`；`packages/client/ui-deliverables/src/client/index.ts`；`packages/extensions/ui-cordis/src/client/index.ts`
- 行与树：`tool/ToolCallTree.tsx` / `.module.css`、`tool/components/ToolRow.tsx` / `.module.css`、`ToolDetails.tsx` / `.module.css`、`AskQuestionCard.tsx` / `.module.css`、`QuestionToolRow.tsx` / `.module.css`、`ExitCodeBadge.tsx` / `.module.css`
- 模型：`tool/models/{tool-call-model,terminal-card-model,read-card-model,diff-card-model,search-card-model,web-card-model,image-card-model,details-card-model,control-details-model,inspection-details-model,todo-diff-model,todo-history,auto-review-denial,primitive-labels,raw-tool-call,recorded-path}.ts`
- 投影：`packages/client/ui-chat/src/client/conversation-nodes/tool.ts`、`contract/records.ts`（`ToolResultNode`）
- primitives：`DisclosureRow.tsx`/`.module.css`、`TextShimmer.tsx`/`.module.css`、`TerminalBlock.tsx`/`.module.css`、`ReadBlock.tsx`/`.module.css`、`DiffBlock.tsx`/`.module.css`、`SearchBlock.tsx`/`.module.css`、`WebBlock.tsx`/`.module.css`、`CodeCard.module.css`、`Tag.module.css`、`CommandText.module.css`
- token：`ui-theme/src/styles/{design-platform,base,gradient-shadow-text,corner-shape,focus}.css`
- 文案：`ui-conversation/src/client/locales.ts`、`ui-chat/src/client/locale.ts`、`ui-tool/src/client/locale.ts`
- 移动端：`ui-mobile/src/client/mobile.module.css`、`ui-conversation/src/client/skeleton/ConversationRoot.module.css`、`ui-chat/src/client/chat/ChatView.module.css`
- 协议：`packages/core/session/src/types.ts`（`tool/result` 的 `meta`）、`packages/shell/tool-bash/src/index.ts`、`packages/web/tool-web/src/{search,fetch}.ts`、`packages/core/tools/src/presentation.ts`

### 1.2 读过的 iOS 文件（`/Users/leilangsheng/Desktop/TonoTeam/phone-dsh`）

`examples/probe-app/PhoneDSHProbe/` 下：`NativeToolCallModel.swift`、`NativeToolDetailCards.swift`、`NativeMessageRows.swift`、`NativeChatTheme.swift`、`NativeChatTimelineChrome.swift`、`ChatPage.swift`、`ChatModel.swift`、`NativeConversationModels.swift`、`NativeTranscriptProjector.swift`、`ToolWording.swift`、`DSHComponents.swift`、`NativeShell.swift`、`Assets.xcassets/DSH*.imageset/*.svg`；
`Sources/PhoneDSHAgentCore/DSH/DSHEventMapper.swift`、`DSHRemoteHarness.swift`；`examples/probe-app/PhoneDSHSimTests/NativeChatPresentationTests.swift`。

### 1.3 用到的检索（全部实际执行过）

```
# 官方：全量 toolview 注册
grep -rn "name: 'tool.call.toolview'" packages/client packages/extensions --include=*.ts --include=*.tsx \
  | grep -v tests/ | grep -v ".d.ts" | awk -F: '{print $1}' | sort | uniq -c
# → ui-deliverables 1 / ui-skill 1 / ask-question-row 1 / bash-sample 1 / details-row 37 /
#   file-mutation-row 2 / read-image-row 1 / read-row 1 / search-row 2 / todo-row 1 / web-row 2 / ui-cordis 4  = 54

# iOS：嵌套 / preparing / 元数据
grep -rn "ptc-dispatch\|parentCallId\|subCalls" --include=*.ts --include=*.swift --include=*.mjs \
  Sources/ examples/probe-app/PhoneDSHProbe plugins/*/src        # → 0 命中
grep -rn "live-chunk\|liveChunk" --include=*.ts --include=*.swift --include=*.js .  # → 0 命中（排除 node_modules/.build）
grep -rn "\.preparing" --include=*.swift .                        # → 只有 MemoryProbe 的无关 phase + 1 处读取，0 处赋值
grep -rn "summarySuffix\|diffTotals" --include=*.swift examples/probe-app/PhoneDSHProbe  # → 0 命中
grep -rn "inspect" --include=*.swift examples/probe-app/PhoneDSHProbe                    # → 无工具行 Inspect 入口
grep -rn '"skill"\|"present"\|cordis_define\|cordis_run' --include=*.swift …             # → 仅 cordis_*_inspect 变体归类
grep -rn "todo_write" --include=*.swift …                                                # → 仅 1 条标题特判
```

### 1.4 截图对照（**截图观察**，不是源码事实）

- `docs/receipts/ios-baseline-screens/ios-chat-assistant.png`（1206×2622 @3x = 402×874pt）：工具行渲染为「✦ 工具调用 · Read · Package.swift」——icon=sparkle、title=「工具调用」、summary=「Read · Package.swift」。可确认 iOS 未知工具走 `others` 变体、且 summary 用「args 第一个字符串值」兜底（与 `NativeToolCallModel.swift:104-105` 一致），**没有官方的 `toolName · ` 前缀**。行文字色明显浅于官方（对应 §4/T-11 的 tertiary 偏差）。
- `ios-chat-official.png` 实为 iOS 原生壳截图（含自绘页头「新会话 / 未启动 / •••」+ 抽屉按钮），**不含工具行**，不能作为官方工具行视觉基线；本报告未把它当官方证据。

## 2. 官方基线（按 surface 列）

### 2.1 全量 `tool.call.toolview` key（54 个，shipped composition）

组合证据：`packages/client/ui-tool/src/client/apply.ts:36-54` 逐个 `ctx.plugin(...)` 装载 9 组 toolview；`web-app/package.json` 的 dependencies 含 `dsh-client-ui-tool` / `ui-skill` / `ui-deliverables` / `ui-cordis`（**`ui-cordis` 来自 `packages/extensions/ui-cordis`，随 web-app 发布**）。`tool.call.toolview` 在 `apply.ts:39` 声明为 `{ kind: 'keyed', scope: 'session' }`。

| # | key | 注册文件:line | 组件 | 行变体 / 图标（14px 内 16px 盒） | 折叠标题（zh） | summary 来源 | 展开卡 | 可嵌套 | iOS 现状 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `bash` | `toolviews/bash-sample.tsx:176` | `BashRow` | `bash` / `IconApiOutlineRegular` | 运行命令 | `toolRowModel`：args `description`→`command`（`tool-call-model.ts:216-224`），有 terminal 卡后改用 `terminal.description`（`bash-sample.tsx:74`） | TerminalBlock（`bash-sample.tsx:126-134`） | 是 | 专用卡（但几何/图标/退出码错） |
| 2 | `read` | `toolviews/read-row.tsx:28` | `ReadRow`→`readFamilyRow` | `read` / `IconBrowseOutlineRegular`（`read-family-row.tsx:48`） | 读取 | args `path`/`file_path`/`url`，文件类 summary 是可点开的路径（`ToolRow.tsx:216-224`） | ReadBlock（`read-card-model.ts:17` 上限 8 行） | 是 | 专用卡（无 banner、无 8 行折叠、依赖 `meta.lines`） |
| 3 | `read_image` | `toolviews/read-image-row.tsx:53-58` | `ReadImageRow`→`readFamilyRow` | `read` / `IconBrowseOutlineRegular` | 读取图片 | 同上（`FILE_PATH_VARIANTS` 含 read→read_image，`tool-call-model.ts:55,247`） | 图库 slot `tool.call.images` + 路径/尺寸行（`ToolRow.tsx:275-305`） | 是 | 无图库；`metadata["lines"]` 不存在时退化成 IN/OUT |
| 4 | `grep` | `toolviews/search-row.tsx:49` | `SearchRow` | `search` / `IconSearchOutlineRegular` | **搜索文件内容** | args `query`/`pattern`/`url` + `queries` 数组逗号拼接（`tool-call-model.ts:231-234`） | SearchBlock（上限 8 行，`search-card-model.ts:12`） | 是 | 通用卡；标题退化为「搜索」 |
| 5 | `glob` | `toolviews/search-row.tsx:50` | `SearchRow` | `search` / `IconSearchOutlineRegular` | **查找文件** | 同上 | SearchBlock（paths 形态） | 是 | 同上 |
| 6 | `web_search` | `toolviews/web-row.tsx:49` | `WebRow` | `search` / **`IconGlobeOutlineRegular`**（`web-row.tsx:21`） | **网页搜索** | args `query`/`queries` | WebBlock（sources / answer / status） | 是 | 图标错（用 search 图标）+ 依赖 `meta` |
| 7 | `web_fetch` | `toolviews/web-row.tsx:50` | `WebRow` | `read` / `IconBrowseOutlineRegular` | **网页获取** | args `url`；summary 渲染为外链（`ToolRow.tsx:225-235`） | WebBlock fetch 形态（`WebBlock.module.css:104-128`） | 是 | 依赖 `meta.url` |
| 8 | `edit` | `toolviews/file-mutation-row.tsx:65` | `FileMutationRow` | `edit` / `IconEditOutlineRegular` | 编辑 | 文件路径；preparing 期间追加 `{KB}` 后缀（`file-mutation-row.tsx:36-37,47`） | DiffBlock（上限 9 行，`diff-card-model.ts:8`） | 是 | 有 diff 卡（无行号/无 hunk/无 +N −M） |
| 9 | `write` | `toolviews/file-mutation-row.tsx:66` | `FileMutationRow` | `write` / `IconEditOutlineRegular` | 写入 | 同上 | DiffBlock | 是 | 同上 |
| 10 | `todo_write` | `toolviews/todo-row.tsx:86-89` | `TodoRow` | `others` / `IconChecklistOutlineRegular` | **更新任务清单** | `{done}/{total} 已完成` + ` · ` + 当前进行中项（`todo-row.tsx:46-62`）；suffix = todo diff 摘要 + `+n` 并行数（`:80-83`） | ToolDetails（todo diff 模型，`todo-diff-model.ts`） | 是 | 仅 1 条标题特判；无 checklist 图标、无 `{done}/{total}`、无 diff 卡 |
| 11 | `ask_user_question` | `toolviews/ask-question-row.tsx:375-386` | `AskQuestionRow` | `others` / `IconQuestionOutlineRegular` | **提问** | 未答：`等待回答` / `已继续工作，仍可回答` / `已结束` / `已取消` / `已中断`；已答：`{answered}/{total} 已回答`（`locales.ts:290-303`） | AskQuestionCard（未答=verdict+问题列表；已答=问答 dl） | 是 | 标题「向你提问」错；无卡、无行内「回答/查看回答」按钮 |
| 12 | `create_goal` | `toolviews/details-row.tsx:80` | `DetailsRow` | `others` / `IconGoalOutlineRegular`（`details-row.tsx:38`） | 创建目标 | 见 §2.2 | ToolDetails | 是 | 通用「工具调用」 |
| 13 | `get_goal` | `details-row.tsx:81` | `DetailsRow` | 同上 | 查看目标 | 同上 | ToolDetails | 是 | 通用 |
| 14 | `update_goal` | `details-row.tsx:82` | `DetailsRow` | 同上 | 更新目标 | 同上 | ToolDetails | 是 | 通用 |
| 15 | `schedule_create` | `details-row.tsx:83` | `DetailsRow` | `others` / `IconClockOutlineRegular` | 创建定时任务 | — | ToolDetails | 是 | 通用 |
| 16 | `schedule_list` | `details-row.tsx:84` | `DetailsRow` | 同上 | 查看定时任务 | — | ToolDetails | 是 | 通用 |
| 17 | `schedule_delete` | `details-row.tsx:85` | `DetailsRow` | 同上 | 删除定时任务 | — | ToolDetails | 是 | 通用 |
| 18 | `schedule_update` | `details-row.tsx:86` | `DetailsRow` | 同上 | 修改定时任务 | — | ToolDetails | 是 | 通用 |
| 19 | `cordis_inspect_list` | `details-row.tsx:87` | `DetailsRow` | `others` / `IconCordisPluginOutlineRegular` | 检查提供方 | — | ToolDetails | 是 | 通用 |
| 20 | `cordis_inspect_query` | `details-row.tsx:88` | `DetailsRow` | 同上 | 查询运行时 | — | ToolDetails | 是 | 通用 |
| 21 | `cordis_inspect_self` | `details-row.tsx:89` | `DetailsRow` | 同上 | 检查动态插件 | — | ToolDetails | 是 | 通用 |
| 22 | `workflow` | `details-row.tsx:90` | `DetailsRow` | `others` / `IconBranchOutlineRegular` | 运行工作流 | — | ToolDetails | 是 | 通用 |
| 23 | `ralph` | `details-row.tsx:91` | `DetailsRow` | 同上 | 运行循环工作流 | — | ToolDetails | 是 | 通用 |
| 24 | `session_event_read` | `details-row.tsx:92` | `DetailsRow` | `others` / `IconSearchOutlineRegular` | 读取事件 | — | ToolDetails | 是 | 通用 |
| 25 | `session_event_search` | `details-row.tsx:93` | `DetailsRow` | 同上 | 搜索事件 | — | ToolDetails | 是 | 通用 |
| 26 | `session_event_trace` | `details-row.tsx:94` | `DetailsRow` | 同上 | 追踪事件 | — | ToolDetails | 是 | 通用 |
| 27 | `session_search` | `details-row.tsx:95` | `DetailsRow` | 同上 | 搜索会话 | — | ToolDetails | 是 | 通用 |
| 28 | `session_trace` | `details-row.tsx:96` | `DetailsRow` | 同上 | 追踪会话 | — | ToolDetails | 是 | 通用 |
| 29 | `list_subagent_models` | `details-row.tsx:97` | `DetailsRow` | `others` / `IconAgentPresetOutlineRegular`（默认分支） | 查看可用模型 | — | ToolDetails | 是 | 通用 |
| 30 | `subagent` | `details-row.tsx:98` | `DetailsRow` | 同上 | **创建子智能体** | — | ToolDetails | 是 | 标题「子 Agent」；无卡 |
| 31 | `list_agents` | `details-row.tsx:99` | `DetailsRow` | `others` / `IconUsersOutlineRegular` | 查看子智能体 | — | ToolDetails | 是 | 通用 |
| 32 | `send_message` | `details-row.tsx:100` | `DetailsRow` | 同上 | 发送消息 | — | ToolDetails | 是 | 通用 |
| 33 | `interrupt_agent` | `details-row.tsx:101` | `DetailsRow` | 同上 | 中断智能体 | — | ToolDetails | 是 | 通用 |
| 34 | `job_list` | `details-row.tsx:102` | `DetailsRow` | `others` / `IconChecklistOutlineRegular` | 查看后台任务 | — | ToolDetails | 是 | 通用 |
| 35 | `job_output` | `details-row.tsx:103` | `DetailsRow` | 同上 | 读取任务输出 | — | ToolDetails | 是 | 通用 |
| 36 | `job_kill` | `details-row.tsx:104` | `DetailsRow` | 同上 | 取消后台任务 | — | ToolDetails | 是 | 通用 |
| 37 | `terminal_open` | `details-row.tsx:105` | `DetailsRow` | `others` / `IconCodeOutlineRegular` | 创建终端 | — | ToolDetails | 是 | 通用 |
| 38 | `terminal_read` | `details-row.tsx:106` | `DetailsRow` | 同上 | 读取终端 | — | ToolDetails | 是 | 通用 |
| 39 | `terminal_list` | `details-row.tsx:107` | `DetailsRow` | 同上 | 查看终端 | — | ToolDetails | 是 | 通用 |
| 40 | `terminal_signal` | `details-row.tsx:108` | `DetailsRow` | 同上 | 发送终端信号 | — | ToolDetails | 是 | 通用 |
| 41 | `terminal_close` | `details-row.tsx:109` | `DetailsRow` | 同上 | 关闭终端 | — | ToolDetails | 是 | 通用 |
| 42 | `lsp` | `details-row.tsx:110` | `DetailsRow` | `others` / `IconSearchOutlineRegular` | 查询代码符号（按 `args.operation` 可切换 查找定义/查找引用/查找实现/查看符号信息，`details-row.tsx:21-26,58-60`） | — | ToolDetails | 是 | 通用 |
| 43 | `spawn_teammate` | `details-row.tsx:111` | `DetailsRow` | `others` / `IconUsersOutlineRegular` | 创建队友 | — | ToolDetails | 是 | 通用 |
| 44 | `team_task_create` | `details-row.tsx:112` | `DetailsRow` | `others` / `IconChecklistOutlineRegular` | 创建团队任务 | — | ToolDetails | 是 | 通用 |
| 45 | `team_task_get` | `details-row.tsx:113` | `DetailsRow` | 同上 | 读取团队任务 | — | ToolDetails | 是 | 通用 |
| 46 | `team_task_update` | `details-row.tsx:114` | `DetailsRow` | 同上 | 更新团队任务 | — | ToolDetails | 是 | 通用 |
| 47 | `team_task_list` | `details-row.tsx:115` | `DetailsRow` | 同上 | 查看团队任务 | — | ToolDetails | 是 | 通用 |
| 48 | `wait_agent` | `details-row.tsx:116` | `DetailsRow` | `others` / `IconUsersOutlineRegular` | 等待子智能体 | — | ToolDetails | 是 | 通用 |
| 49 | `skill` | `packages/client/ui-skill/src/client/index.ts:89-91` | `SkillRow` | 由插件自定 | — | — | 插件自带 | 是 | 通用 |
| 50 | `present` | `packages/client/ui-deliverables/src/client/index.ts:82-84` | `PresentRow` | 由插件自定 | — | — | 交付物行 | 是 | 通用 |
| 51 | `cordis_define` | `packages/extensions/ui-cordis/src/client/index.ts:117-122` | `CordisDefineRow` | `others` / — | — | — | Cordis 卡片 | 是 | 通用 |
| 52 | `cordis_run` | `ui-cordis/src/client/index.ts:124-137` | `CordisRunRow` | `others` / — | 运行 Cordis 插件 | args 包 id | Cordis 运行卡（声明子 slot `tool.view.cordis`） | 是 | 通用 |
| 53 | `cordis_stop` | `ui-cordis/src/client/index.ts:138-142` | `CordisActionRow` | 同上 | 停止 Cordis 插件 | — | — | 是 | 通用 |
| 54 | `cordis_undefine` | `ui-cordis/src/client/index.ts:143-146` | `CordisActionRow` | 同上 | 移除 Cordis 插件 | — | — | 是 | 通用 |

> 另有 2 个只存在于测试/未注册进 shipped 的 key：`mystery`（`ui-tool/tests/toolview-slot.client.spec.ts:248`）与 `probe`，**不计入随附清单**。

### 2.2 ToolRow 折叠行像素规格（402pt，官方）

来源：`ui-primitives/src/DisclosureRow.module.css:30-105`、`ui-tool/.../ToolRow.module.css:9-114`、`ToolRow.tsx:211-257`。

| 元素 | 规格 |
|---|---|
| 行高 | `calc(24px + var(--dsh-content-font-delta, 0px))` → 默认 **24px**（`DisclosureRow.module.css:36`；`bash-sample.module.css:96` 对 bash 逐字复制） |
| 排版顺序 | `[16 图标盒]` gap **6** `[标题 13/24, flex:none]` `[2×2 圆点, margin 0 8]` `[summary 13/24, flex:1, ellipsis]` `[suffix]` `[±totals]` `[退出码胶囊]` |
| 图标 | 盒 16×16（`calc(16px + delta)`），glyph **14**（`DisclosureRow.module.css:50-72`）；`stroke-width: 1`（`icons/index.tsx:22`） |
| 标题 | `font-size: 13px`、`line-height: 24px`、`font-weight: 400`；`data-tool^='cordis_'` 时 **500**（`ToolRow.module.css:18-24`）、`flex: none`、不折行不省略 |
| 分隔圆点 | 2×2、`border-radius: 1px`、`margin: 0 8px`、底色 `--dsw-alias-label-caption` = light `#ADB2B8` / dark `#81858C`（`ToolRow.module.css:26-33`） |
| summary | 13/24、`white-space: nowrap`、`text-overflow: ellipsis`、`overflow: hidden`、`flex: 1 1 auto; min-width: 0`（`ToolRow.module.css:35-43`） |
| summarySuffix | 13/24、`flex: none`、`margin-left: 4px`、nowrap（`:50-56`） |
| diff ±totals | `margin-left: 10px`、`font-family: var(--ds-font-family-code)`、`font-size: calc(13px - 2px)` = **11px**、`translateY(0.5px)`；`+` 用 `state-success-primary`、`−` 用 `state-error-primary`，**仅 hover / 展开时上色**（`:64-77`、`ToolRow.tsx:251-255`） |
| 行文字色 | `label-tertiary`：light `#81858C` / dark `#ADB2B8`；hover → `label-secondary`：light `#61666B` / dark `#CFD3D6`，`transition: color 100ms ease`（`DisclosureRow.module.css:38-48`） |
| running | 整行 `TextShimmer active`，色转 secondary（`ToolRow.tsx:181,382`） |
| error 摘要 | `--dsw-alias-state-error-primary`：light `#EC1313` / dark `#F25A5A`（`ToolRow.module.css:107-109`） |
| stopped 摘要 | `--dsw-alias-state-warn-label` = `#DD8629`（两主题相同，`design-platform.css:256,374`） |
| 退出码胶囊 | `Tag tone="neutral"`：`padding 1px 8px`、`border-radius 999px`、`font 11px/17px w500`、bg `#F5F6F7`(dark `#353638`)、字 `#61666B`(dark `#CFD3D6`)、`margin-left 8px`、`gap 5px`、前置 **4px** 红点 `#EC1313`（`ExitCodeBadge.module.css:1-14` + `Tag.module.css:5-15`） |
| 链接化 summary | 文件路径是 `<button>`，`text-decoration: underline dotted`、`thickness 1px`、`offset 3px`、`color: inherit`（`ToolRow.module.css:84-104`）；URL 是 `<a target=_blank>`（`ToolRow.tsx:225-235`） |
| 展开 leading | `IconChevronUpOutlineRegular`（`DisclosureRow.tsx:82-84`）；折叠时 hover 才 crossfade 成 down chevron（`:74-80`、`.module.css:84-98`，`100ms`） |
| 命中区 | `expandOnRowClick` → 整行 `role="button"` + `tabIndex=0` + `aria-expanded`（`DisclosureRow.tsx:89-98`）；Enter/Space 触发（`:69-73`） |
| 屏幕阅读器 | 视觉隐藏的 `正在准备调用/运行中/失败/已停止`（`ToolRow.tsx:107-116,375`） |

### 2.3 展开体像素规格（402pt，官方）

| 卡族 | 几何 | 字号/颜色 | 折叠/上限 |
|---|---|---|---|
| IN/OUT 通用卡 | `margin: 4px 0 4px 4px`、`border: 0.5px solid border-l1`、`border-radius: var(--dsw-radius-lg)` = **16px**、bg `--dsw-alias-markdown-code-block` = light `#F9FAFB` / dark `#1B1B1C`（`ToolRow.module.css:181-189`） | `font: var(--dsw-font-markdown-code-block-small)` = **11px/16px mono** | 每段 `padding: 12px 16px`、`max-height: 150px`、独立滚动；`IN/OUT` 标签 `label-caption` 且 sticky top 0；段间 0.5px `border-l2`（`:193-247`） |
| TerminalBlock | 卡左内衬 `--dsl-terminal-gutter: 30px`（跑状态点在 x=8）；banner `padding: 9px 14px 9px 30px`，`max-height: 150px`；输出区 `padding: 12px 14px 12px 0`、`max-height: 224px`、`white-space: pre` + 横向滚动（`TerminalBlock.module.css:1-27,32-48,152-183`） | `--dsl-terminal-font` 默认 `11px/22px mono`，工具行覆写为 `11px/18px`（`ToolRow.module.css:304-310`、`bash-sample.module.css:15-22`） | 工具行传 `maxLines={Infinity}`（`ToolRow.tsx:266`、`bash-sample.tsx:130`）；banner 内有复制按钮 + 状态 pill（`terminal.exitCode` = 「退出码 {code}」） |
| ReadBlock | 行号 gutter `width: var(--dsl-read-gutter)` + `margin-right: 12px`、右对齐、`label-tertiary`；每行 `min-height: 1lh`、`white-space: pre`（`ReadBlock.module.css:1-19`） | 代码 `11px/19px mono`（`--dsw-font-markdown-code-block`） | banner 显示 `read.window` = 「显示 {shown} / {total} 行」+ 复制 + 换行开关（`primitive-labels.ts:60-72`，header 几何见 `CodeCard.module.css:10-21`：`padding: 10px 18px 8px 22px`、`font: 11px/18px`）；`CHAT_READ_MAX_LINES = 8`、head/tail 各半、`… 其余 {count} 行`（`read-card-model.ts:17`、`locales.ts:340-343`） |
| DiffBlock | `padding: 6px 0 20px`；每行 `padding: 0 22px`、`min-height: 1lh`、`white-space: pre`；`add` 前置 `+ `、`del` 前置 `- `、`context` 前置两空格（`DiffBlock.module.css:5-64`） | `11px/19px mono`；`add` 字 `#22C55E` + bg `rgb(34 197 94 / 8%)` + `box-shadow: inset 3px 0 0`；`del` 字 `#EC1313` + bg `rgb(236 19 19 / 8%)` + 同款 3px 左侧条；`path` 行 `label-secondary` w500（`:29-64`） | `CHAT_DIFF_MAX_LINES = 9`（`diff-card-model.ts:8`）、`… 其余 {count} 行` |
| SearchBlock | banner `padding: 9px 14px`、bg `markdown-code-block-banner`（light 与正文同 `#F9FAFB`，dark `#353638`）；body `padding: 8px 14px 12px 0`；行 `min-height: 22px`、`padding-left: 14px`、`white-space: pre`；文件组头 `font-weight: 600` + 命中数（`SearchBlock.module.css:12-90`） | `11px/22px mono`；组头 `label-primary` w600；行号 `label-tertiary`；banner summary `13px/20px` `label-secondary` | `CHAT_SEARCH_MAX_LINES = 8`；`search.matches` = 「{shown} 处匹配 · {files} 个文件」、`search.paths` = 「{shown} 个路径」（`locales.ts:344-349`） |
| WebBlock | `margin: 16px 0`（工具行覆写 4/0/4/4）、`padding: 12px 14px`、radius 16、bg `#F9FAFB`/`#1B1B1C`（`WebBlock.module.css:1-9`） | 来源链接 14/20 w500 `--dsw-alias-link` = light `#4176E6` / dark `#7AAAFF`；snippet 13/19 `label-secondary`；fetch URL 13/19 mono w500 `word-break: break-all`（`:54-84,110-118`） | sources `padding-left: 2.5em`、`gap: 10px`、`max-height: 320px`；answer 底部 8px |
| ImageBody | 图库（`tool.call.images` slot）+ 路径与每张图尺寸行（`row.imageSize` = 「{width}x{height}px，{bytes} 字节」），`font: 11px/16px mono`、`label-tertiary`（`ToolRow.module.css:283-289`、`locales.ts:315-316`） | 同上 | — |
| ToolDetails（37 key 的卡） | `margin: 4px 0 4px 4px`、`border: 0.5px l1`、radius 16、bg `#F9FAFB`/`#1B1B1C`、`font: var(--dsw-font-xs-13)` = **13px/20px**；`list max-height: 320px`；每项 `padding: 10px 14px`，项间 0.5px `l2`（`ToolDetails.module.css:1-27`） | 字段 `grid-template-columns: 5.5em minmax(0,1fr); gap: 12px`，`dt` = `label-caption`（`:133-151`）；状态徽章 12px + 5px 圆点，tone 色（`:153-174`）；`subtitle`/`statusText`/`caption` 12px；状态符号 `+`/`−`/✓/▷/10×10 空框（`ToolDetails.tsx:48-73`） | `groups` / `unchanged` 用原生 `<details>`，展开旋转 90°（`:199-219`）；空态 `detail.empty` = 「暂无结果」，有结果时 caption `detail.recordedResult` = 「调用结果」（`locales.ts:180-181`） |
| AskQuestionCard | `margin: 4px 0 4px 4px`、`padding: 16px 20px`、`gap: 16px`、`max-height: 360px`、radius 16、border 0.5 `l1`、bg `--dsw-alias-bg-base`（`AskQuestionCard.module.css:1-14`） | 问题/答案 **14px/24px**；`dt`（问题）`label-tertiary`、`dd`（答案）`label-primary`、题内 gap 2px；未答形态：verdict 14/24 `label-primary` + `ul` `padding-left: 20px`/`gap: 8px` 的 `label-tertiary` 问题列表（`:16-50`） | 未答 = `ask.pendingDetail`「等待中的问题仍可在输入框中回答」/ `ask.closedDetail`；已答 = 每题答案块；跳过 = `ask.skipped`「未回答」 |
| Inspect 药丸 | hover 才显形（`opacity 0→1, 100ms`）：`padding: 2px 8px`、`border: 0.5px l3`、radius 999、`font 11px/16px`、`gap 4px`、`margin: 4px 0 2px 4px`；Details 卡内绝对定位 `top: 12px; right: 12px`（`ToolRow.module.css:126-167`） | `label-secondary` → hover `label-primary` + `interactive-bg-hover-solid` | `IconInspectOutlineRegular` + 「查看」（`locales.ts:314`），跳 trajectory |
| 嵌套 subcall 轨 | `margin: 4px 0 2px 22px`、`padding-left: 8px`、`border-left: 0.5px solid border-l2`、`gap: 4px`（`ToolCallTree.module.css:5-12`） | 子行与父行同一套 ToolRow 规格 | **不折叠**，始终可见；`MAX_DEPTH = 256`（`tool.ts:19`）；`preparing` 阶段不渲染子调用（`ToolCallTree.tsx:82`） |

### 2.4 状态机（官方 `ToolRowState`）

`tool-call-model.ts:19`：`'preparing' | 'running' | 'ok' | 'error' | 'stopped'`。

| 迁移 | 触发 | 官方证据 |
|---|---|---|
| ∅ → preparing | `assistant/live-chunk` 的 `tool-call-delta` 带 `id`+`name` | `ui-chat/conversation-nodes/tool.ts:64-88` |
| preparing → running | 收到 `tool/call`（`rootCall`，`args.settle`） | `tool.ts:44-57`；`:96-105` |
| preparing/running → ok/error | `tool/result`，`isError` | `tool.ts:108-119`；`tool-call-model.ts:314-316` |
| → stopped | `block.error.code === 'interrupted'`（含投影合成的 `{name:'Interrupted',code:'interrupted'}`） | `tool-call-model.ts:315`；`tool.ts:246-263` |
| ok → error（仅 bash） | 终态退出码非 0 / 有 signal，但 `isError:false` | `bash-sample.tsx:55-57`、`terminal-card-model.ts:100-104` |
| 子调用 | `tool/ptc-dispatch-start` 建行、`tool/ptc-dispatch` 定稿 | `tool.ts:199-225` |
| 自动审核拒绝 | `error.name='AutoReviewDeniedError' && code='AUTO_REVIEW_DENIED'` → 强制走 `GenericToolCard`，summary=「Auto review 已拒绝」、OUT=「工具未执行。原因：{reason}」 | `tool-call-model.ts:165-172`、`ToolCallTree.tsx:40-55`、`auto-review-denial.ts:29-34`、`locales.ts:334-336` |

### 2.5 手机宽度特化（402pt）

- `ui-mobile/src/client/mobile.module.css:13` 的 `@media (max-width: 639px)` 块**没有任何工具行覆盖**：24px 行高、13px 字号、16px 图标盒全部沿用桌面值。真正变化的是外壳（抽屉、composer `position: fixed`、输入框 16px 防缩放 `:170-175`、`touch-action: manipulation` `:178-180`）。
- 因此工具的"手机特化"只有两条副作用：①`[role='tooltip']` 一律 `display:none`（`:53-55`）→ 悬停提示在触屏失效；②所有 hover-only 的交互（图标→chevron crossfade、Inspect 药丸、diff ± 上色）在触屏上**永远不可达**，除非设计上接受"点一下才算 hover"。
- 内容列宽：`ChatView.module.css:26-32` 的 `.scroll` `padding: 16px calc(var(--dsh-composer-side-clearance) + 16px)`，`--dsh-composer-side-clearance: 16px`（`ConversationRoot.module.css:389`）→ 402pt 下 **transcript 内容宽 = 402 − 64 = 338px**；`.column` 再 `max-width: var(--dsh-chat-content-width)`（680px 起）实际不约束（`ChatView.module.css:54-59`）。注释明确写着"transcript 比输入卡窄 32px"。
- 行间距：flow gap 默认 **6px**（`ChatView.module.css:175`），assistant 回答前 **12px**（`:78-84`），turn-process 头 **16px**（`:120`）。

### 2.6 死代码/未使用资产（避免误判）

- `bash-sample.tsx` 的注册器名是 `bash-toolview-sample`，但它在 `apply.ts:45` 被 `ctx.plugin(...)` 正式装载，**是 shipped 的 bash 行，不是样例**。
- `TOOL_VARIANTS` 里刻意不含 `cordis_define`（`tool-call-model.ts:36-44` 注释），因为 keyed 视图会优先命中。
- `ToolRow` 的 `terminalBody` / `diffBody` / `readBody` 等都带 `margin: 4px 0 4px 4px`，**首行缩进 4px** 是官方统一的卡片左缩进。

## 3. iOS 现状（按 surface 列）

| # | Surface | iOS 实现（file:line） | 现在画成什么 | 行为 | 与官方的差 |
|---|---|---|---|---|---|
| 1 | 行变体 | `NativeToolCallModel.swift:7-9` | 7 个 case：`search, read, bash, write, edit, code, others` | 按工具名 switch（`:19-27`） | 与官方 `ToolRowVariant`（`tool-call-model.ts:16`）**名字与数量完全一致** ✓；但归类比官方多 5 条（`str_replace_editor`、`cordis_package_inspect`、`cordis_runtime_inspect` 等）且缺 `run_code` 之外的 `code` 生产路径 |
| 2 | 图标 | `NativeToolCallModel.swift:33-42` + `NativeChatTheme.swift:41-98` | search→DSHSearch、read→DSHRead、bash→**DSHTerminal**、write/edit→DSHEdit、code→DSHCode、others→DSHSparkle（均 14pt，16 盒） | — | 尺寸/盒 ✓；`search`/`read`/`edit`/`code`/`sparkle` 的 SVG path **与官方逐字相同**；**bash 用 `>_` 终端字形而官方是 `IconApiOutlineRegular`（三横三圆拓扑）；`grep/glob` 用 search ✓ 但 `web_search` 也用 search（官方是 Globe）；`todo_write` 用 sparkle（官方 Checklist）；37 个 details key 全用 sparkle 而非 10 种业务图标** |
| 3 | 标题 | `NativeToolCallModel.swift:44-63` | 6 条特判 + 7 条变体兜底 | — | `web_search`✓ `web_fetch`✓ `read_image`✓ `todo_write`✓；`ask_user_question`→**「向你提问」**（官方「提问」）；`subagent`→**「子 Agent」**（官方「创建子智能体」）；`grep`→**「搜索」**（官方「搜索文件内容」）；`glob`→**「搜索」**（官方「查找文件」）；37 个 details key + `skill`/`present`/`cordis_*`→**「工具调用」** |
| 4 | summary | `NativeToolCallModel.swift:84-108` | error→输出首行；stopped→「已停止」；filePath 优先；否则按 variant 的 key 顺序取首行（bash `description,command`；read `path,file_path,url`；search `query,pattern,url,queries`） | — | 与官方 `SUMMARY_KEYS`（`tool-call-model.ts:216-224`）**完全同序** ✓；但**缺官方的 `toolName · ` 前缀**（`tool-call-model.ts:321` 只对 `tool.title.generic` 加），iOS 的 `others` 用"args 第一个字符串"兜底（`:104-105`），官方用 `firstLine(argsRaw)`（`:229,240`） |
| 5 | 行骨架 | `NativeMessageRows.swift:5-55` | VStack(0) + Button + HStack(0)：ZStack 16×16 + `.padding(.trailing, 6)` + `Text(title)` 13pt `fixedSize(horizontal:true)` + `Circle` 2×2 `.padding(.horizontal, 8)` + `ShimmerText(summary)` 13pt + `Spacer` + `.frame(height: 24)` | 点击整行 toggle，`withAnimation(.easeOut(duration: 0.16))`；`expandable=false` 时 `disabled` | **几何与官方逐项吻合**（24/16+6/2×2+8+8/13pt 省略号）✓ |
| 6 | 行颜色 | `NativeMessageRows.swift:42` | `running ? NativeChatTheme.secondary : NativeChatTheme.tertiary` | 无 hover/pressed/focus 态 | 官方 light `label-tertiary = #81858C`，iOS **`#9A9AA2`**（≈官方 dark 值，昼夜**互换**）；官方 dark `#ADB2B8`，iOS **`#81858C`**。running→secondary：light `#61666B` vs iOS `#66666B`，dark `#CFD3D6` vs iOS `#A1A1AA` |
| 7 | 错误/停止色 | **无**（`NativeMessageRows.swift:42` 单一颜色） | 失败行的 summary（错误首行）与成功行**同色** | 仅 `.accessibilityValue` 里念「失败」/「已停止」（`NativeToolDetailCards.swift:33`） | 官方 error = `#EC1313`(dark `#F25A5A`)、stopped = `#DD8629`（`ToolRow.module.css:107-114`） |
| 8 | 后缀 | **无**（`grep -rn "summarySuffix" → 0`） | 没有 `{KB}`、没有 `+n`、没有 `+N −M` | — | 官方 3 类 suffix + diff totals |
| 9 | 退出码胶囊 | **无**（胶囊只在展开的 banner 内，见 §3-12） | 折叠行看不出命令失败 | — | 官方 `ExitCodeBadge` 就在折叠行（`ToolRow.tsx:247`） |
| 10 | 展开体容器 | `NativeToolDetailCards.swift:17-31` | `VStack(spacing: 6)` + `.padding(.leading, 4).padding(.vertical, 4)` | 展开/收起 | 官方每张卡自己 `margin: 4px 0 4px 4px`；iOS 额外引入 4pt 顶部空白与 6pt 段间距 |
| 11 | 文件路径行 | `NativeToolDetailCards.swift:18-27` | `Label(path, systemImage: "arrow.up.right.square")` 12pt，accent 色，`truncationMode(.middle)` | 点击 `onOpenFile` | 官方路径在 **summary 里**（下划线点线、`color: inherit`），不在展开体，且 `truncationMode: tail` |
| 12 | Terminal 卡 | `NativeToolDetailCards.swift:73-113` | VStack(0)：HStack(8) = `$` + 命令 + Spacer + `Text("exit \(code)")`（仅非 nil 时，`padding 6/2`、Capsule、成功用 `selector`、失败用 `danger.opacity(0.12)`），`padding(12)`、bg `codeBanner`；输出 `ScrollView` `maxHeight 224`、`padding(12)`；整体 bg `code`、radius **12**、描边 0.5 `border` | 命令 `fixedSize` 换行 | 官方：banner 无独立底色、有 30px 左侧 gutter + 运行状态点、状态 pill 文案「退出码 1」而非「exit 1」、输出 `white-space: pre` 横向滚动、radius 16、描边 `rgba(0,0,0,.04)`、正文 `#F9FAFB`；**且 iOS 读的 `meta.exitCode` 官方根本不写（bash 的 `presentationMeta` 只给 `{cwd}`，`tool-bash/src/index.ts:476`），官方是从结果文本 `[exit code: N]` 解析（`terminal-card-model.ts:349`）→ iOS 的胶囊实际永不出现** |
| 13 | Read 卡 | `NativeToolDetailCards.swift:115-136` | 行 = `HStack(12)`：行号 12pt `caption` + `minWidth 32` 右对齐，正文 12pt `secondary`；`prefix(200)`；`padding(.vertical,10)`、bg `code`、radius 12 | — | 官方有 banner（`read.window` + 复制 + 换行）、`maxLines 8` 的 head/tail 折叠 + 「… 其余 N 行」、行号 gutter 变量宽 + 12px 间距、radius 16 |
| 14 | Search 卡 | `NativeToolDetailCards.swift:138-169` | `VStack(8)`：`shape=='paths'` → 路径列表；否则 `files[].path`（13pt w500）+ `matches[]`（行号 caption + 行）12pt；`truncated` → 「结果已截断」12pt；`padding(12)` | — | 官方有 banner（`{shown} 处匹配 · {files} 个文件`）、组头可折叠（`<button>` 整行）、`maxLines 8`、行 `white-space: pre`、radius 16；文案「结果已截断」非官方（官方 `search.matches.truncated` = 「显示 {shown} / 共 {total} 处匹配 · {files} 个文件」） |
| 15 | Web 卡 | `NativeToolDetailCards.swift:171-195` | `VStack(10)`：`answer`(13pt) + `LabeledContent("地址"…)`/`("HTTP"…)` + `sources[]`（title 13pt w500、url 12pt accent、snippet 12pt secondary）+ 无 meta 时退原始输出；`padding(12)` | — | 官方：来源是**有序列表**（`2.5em` 缩进 + 10px gap + 320px 上限）、链接 14/20 w500 带 URL glyph、snippet 13/19、无「地址/HTTP」这种字段行（fetch 形态是 URL + `HTTP {status}` 一行）、radius 16 |
| 16 | Diff 卡 | `NativeToolDetailCards.swift:245-266` + `nativeToolDiff`（`:230-243`） | 每行 `HStack(8)`：1 字符标记（固定 12pt 宽）+ 正文，12pt；`+`→success、`-`→danger、上下文→secondary；bg 分别 `success.opacity(0.07)` / `danger.opacity(0.07)`；`padding(.horizontal,12).padding(.vertical,2)`；无行号、无 hunk、无 `… 其余 N 行`、radius 12 | — | 官方 `+ `/`- ` 用 CSS `::before`、**`inset 3px 0 0` 左侧色条**、`padding 0 22px`、`context` 前置两空格、`CHAT_DIFF_MAX_LINES = 9`、底部 `padding-bottom: 20px`；颜色 `#22C55E`/`#EC1313` vs iOS `#27865A`/`#C0392B` |
| 17 | 通用 IN/OUT 卡 | `NativeToolDetailCards.swift:197-228` | `VStack(0)`：`HStack(14)` = 标签（`caption` 色）+ `ScrollView`（`maxHeight 150`）+ `padding(12)`；段间 `Divider().overlay(border)`；bg `code`、radius 12、描边 0.5 | — | **结构几乎对齐官方**（14px 列间距 / 150px 上限 / 12px padding ✓）；差在标签不 sticky、分隔线用 `Divider()`（≈1px）而非 0.5px、radius 12 vs 16、字 12pt vs 11pt |
| 18 | Details 卡（37 key） | **无** | 落到 `NativeIOCard`（`NativeToolDetailCards.swift:67-69`） | — | 官方是结构化字段/状态/徽章/分组卡 |
| 19 | AskQuestionCard | **无** | 同上 | — | 官方有专门的已答/未答转录卡 |
| 20 | Inspect | **无** | — | — | 官方 hover 药丸 + trajectory 跳转 |
| 21 | 嵌套 subcall | **无**（§6 穷尽搜索 0 命中） | — | — | 官方 `ToolCallTree` 递归 + 22/8 缩进 + 0.5px 左轨 |
| 22 | 分组 | `ChatPage.swift:446-470`（连续 toolCall/toolResult 合成 `.tools`）、`NativeChatTimelineChrome.swift:7-20`、`ToolRunRow`（`ChatPage.swift:2349-2362`） | `VStack(spacing: 6)` 逐条 `NativeToolCallRow` | 无组头、无计数、无折叠（**官方 process group 的折叠/实时标题不在本轴，见 Axis 05**） | 组内 6pt 间距与官方 flow gap 6px **一致** ✓；进组前的行间距 iOS 8pt（`ChatPage.swift:435`）vs 官方 6px |
| 23 | 展开宽度 | `ChatPage.swift:799` `.padding(.horizontal, 16)` | 内容宽 **370pt** | — | 官方 **338px** → iOS 的 summary 少截 32px、卡片宽 32pt |
| 24 | 状态产生 | `ChatModel.swift:1717-1730`（toolCall→`.running`）、`1731-1752`（toolResult→`.ok/.error`）、`1777-1786`（turn 结束把 running 归 `.stopped`） | 只有 running/ok/error/stopped | — | **`.preparing` 全仓库 0 次赋值**（`grep -rn "\.preparing"`）→ 死枚举；**实时路径不判 `interrupted`**（`ChatModel.swift:1742` 只 `isError ? .error : .ok`，而历史投影 `NativeTranscriptProjector.swift:97` 判了）→ 同一 interrupt 在实时/历史两种态 |
| 25 | 元数据 | `NativeConversationModels.swift:28` `var toolMetadata: JSONValue?`；写入点只有 `NativeTranscriptProjector.swift:95,107` | 历史行有 `meta`，实时行没有 | — | 见 §0-2 / §6 |

### 3.1 用到的 iOS 文案（现状）与官方对照

| 场景 | 官方（zh，`ui-conversation/src/client/locales.ts`） | iOS 现状（`NativeToolCallModel.swift`） | 判定 |
|---|---|---|---|
| bash | 运行命令 | 运行命令 | ✓ |
| read | 读取 | 读取 | ✓ |
| write / edit | 写入 / 编辑 | 写入 / 编辑 | ✓ |
| code | 代码 | 代码 | ✓ |
| generic | 工具调用 | 工具调用 | ✓ |
| grep | 搜索文件内容 | 搜索 | ✗ |
| glob | 查找文件 | 搜索 | ✗ |
| web_search | 网页搜索 | 网页搜索 | ✓ |
| web_fetch | 网页获取 | 网页获取 | ✓ |
| read_image | 读取图片 | 读取图片 | ✓ |
| todo_write | 更新任务清单 | 更新任务清单 | ✓ |
| ask_user_question | 提问 | 向你提问 | ✗ |
| subagent | 创建子智能体 | 子 Agent | ✗ |
| 37 × details | 创建目标/查看目标/…/等待子智能体 | 工具调用 | ✗（37 处） |
| row.running/preparing/failed/stopped | 运行中 / 正在准备调用 / 失败 / 已停止 | 运行中 / —（无 preparing）/ 失败(仅 a11y) / 已停止(summary) | 部分 |
| row.input / row.output | 输入 / 输出 | 输入 / 输出 | ✓ |
| row.inspect | 查看 | — | ✗ |
| row.imageSize | {width}x{height}px，{bytes} 字节 | — | ✗ |
| terminal.exitCode | 退出码 {code} | `exit {code}` | ✗ |
| ask.answered / ask.skipped | {answered}/{total} 已回答 / 未回答 | — | ✗ |
| search.matches | {shown} 处匹配 · {files} 个文件 | — | ✗ |
| read.window | 显示 {shown} / {total} 行 | — | ✗ |
| todo.completed | {done}/{total} 已完成 | — | ✗ |
| tool.autoReviewRejected | Auto review 已拒绝 | — | ✗ |

## 4. 差距清单（核心交付）

> 「像素/行为对齐合同」一栏是可实现的验收口径；旧值为 iOS 现值，新值为官方值。

### P0

| ID | 严重度 | 差距 | 官方证据 | iOS 证据 | 用户可见影响 | 像素/行为对齐合同 | 数据依赖 | 实施建议 | 验证方式 |
|---|---|---|---|---|---|---|---|---|---|
| T-01 | P0 | **实时工具结果丢失 `meta`**：terminal/read/search/web/diff 卡片在会话进行中全部降级为通用 IN/OUT 卡；只有重新加载会话后才"变回"卡片 | `core/session/src/types.ts:376-386`（`tool/result.meta` 是持久字段）；读方 `read-card-model.ts:107-117`、`terminal-card-model.ts:326-329`、`search-card-model.ts`、`web-card-model.ts`、`diff-card-model.ts` | `DSHEventMapper.swift:108-116` 只映射 `message/content/isError`；`ChatModel.swift:1731-1752` 只写 `toolOutput`/`toolState`；`toolMetadata` 唯一写入点是 `NativeTranscriptProjector.swift:95,107` | 同一个工具调用，**run 时和刷新后长得不一样**；bash 退出码、read 行号、grep 命中分组、web 来源全部缺失 | `HarnessEvent` 增 `toolResultMeta: JSONValue?`（或 `toolResult(callID:isError:summary:meta:)`）；`DSHEventMapper.map` 的 `tool/result` 分支透传 `data["meta"]`；`ChatModel.handle` 的 `toolResult` 分支写 `items[index].toolMetadata = event.toolResultMeta`；与投影器共用同一个 `applyToolResult(item, data)` 消除双写 | `tool/result.meta`（已存在） | 抽 `NativeToolResultPayload` 结构，让 projector 与 ChatModel 走同一函数；补一条 `ChatWorkflowTests` 断言实时态 `toolMetadata?["lines"] != nil` | 跑一个真实 `read`：不刷新页面即应出现行号卡；kill 后重载会话肉眼一致 |
| T-02 | P0 | **嵌套 subcall 完全缺失**：官方的 PTC 子调用树（父行下缩进轨 + 子行）在 iOS 无数据、无渲染 | `ToolCallTree.tsx:61-102`（递归 `ToolCallBranch`）、`ToolCallTree.module.css:5-12`、`ui-chat/.../conversation-nodes/tool.ts:199-225`（`tool/ptc-dispatch-start` / `tool/ptc-dispatch` → `children`）、`:19` `MAX_DEPTH=256`、`contract/records.ts:167-182`（`parentCallId` / `subCalls`） | `grep -rn "ptc-dispatch\|parentCallId\|subCalls" --include=*.ts --include=*.swift --include=*.mjs Sources/ examples/probe-app/PhoneDSHProbe plugins/*/src` → **0 命中** | `workflow`/`run_code`/`ptc` 场景下，用户只看到父调用，看不到内部几十个子调用 → 整个"agent 在干什么"不可见 | `HarnessEvent.Kind` 增 `.toolDispatchStarted(parentCallID:subCallID:name:arguments:)` / `.toolDispatchSettled(...)`；`ChatItem` 增 `parentCallID`/`subCalls:[ChatItem]`；渲染：`VStack(spacing: 4)` + `.padding(.leading, 30)`（22+8）+ 左侧 `Rectangle().frame(width: 0.5)` 用 `border-l2`；子行与父行同规格；`preparing` 阶段不渲染子树；深度上限 256 | `tool/ptc-dispatch-start`、`tool/ptc-dispatch`（session 事件，`core/session/src/known-event-types.ts` 已含） | 先在 `DSHEventMapper` 加两条映射，再在 `NativeTranscriptProjector` 把子调用挂到父 item（按 `parentCallId` 索引），最后加一棵 `NativeToolSubCallTree` 视图；不要复用 `.tools` 分组（那是兄弟关系） | 造一条含 2 层 ptc 的会话日志，断言 `parentItem.subCalls.count == 2` 且 UI 有 8pt 缩进轨 |
| T-03 | P0 | **preparing 行完全缺失**：参数流式到达期间官方已有一行"正在准备"的占位行；iOS 在全参数到齐前**什么都不显示** | `ui-chat/.../conversation-nodes/tool.ts:60-95`（`tool-call-delta` → `phase:'preparing'`）、`ToolRow.tsx:174`（preparing 不可展开）、`:110`（`row.preparing` = 「正在准备调用」）、`file-mutation-row.tsx:16-37`（`{KB}` 后缀） | `NativeToolState.preparing`（`NativeConversationModels.swift:43-45`）**全仓库无赋值**；`DSHRemoteHarness.swift:352-363` 的 `assistant-stream` 分支要求 `frame["chunk"]["text"]` 是字符串，`tool-call-delta`（字段是 `argumentsDelta`）被 `default: break` 丢弃；`DSHEventMapper` 无 `assistant/live-chunk` 分支 | 长参数的工具（写文件、edit、workflow）在"模型正在吐参数"的数秒里界面**毫无反应**，看起来像卡住 | ①`DSHRemoteHarness` 增 `tool-call-delta`（`id`/`name`/`argumentsDelta`）与 `block-start/block-end(tool-call)` 转发；②`ChatModel` 维护"按 callId 索引的临时行"，`state = .preparing`；③行渲染：与 running 完全同规格，只是 `expandable = false`（禁止展开）、`TextShimmer active`、`summary` 用已到达的 `description` 前缀；④`write`/`edit` 追加 `summarySuffix = "{ceil(KB)}KB"`（`tool.preparing.content`，`locales.ts:92`）；⑤收到 `tool/call` 时就地替换为正式行（不新增行、不闪动） | `assistant/live-chunk` 的 `chunk.type in {tool-call-delta, block-start, block-end}` | 先只做 `tool-call-delta`（覆盖 95% 场景），`block-end` 用于校正最终 args；注意行 id 必须与最终 `tool/call` 的 `callId` 相同以便原地替换 | 慢速模型 + `write` 工具：应在 `tool/call` 出现前 1s+ 就看到「写入 · 说明 · 12KB」行，且该行点不开 |
| T-04 | P0 | **Details 卡族（37 个 key）没有专用卡**：官方把 goal/schedule/job/subagent/team/terminal/session/lsp/workflow/cordis 的结果渲染成结构化"字段 + 状态徽章 + 分组列表"卡；iOS 只有原始 IN/OUT 文本 | `details-row.tsx:79-116`（37 个 key）、`ToolDetails.tsx:43-139`、`ToolDetails.module.css:1-256`、`details-card-model.ts` / `control-details-model.ts` / `inspection-details-model.ts` | `NativeToolDetailCards.swift:37-71` 的 switch 无 details 分支 → `default: NativeIOCard`（`:67-69`） | `job_output`/`list_agents`/`subagent`/`schedule_list` 等结果是一坨 JSON/文本，手机上无法扫读；这是用户点名"子 Agent 状态"的直接呈现层 | 新 `NativeToolDetailsCard`：外层 `margin 4/0/4/4`、`border 0.5px border-l1`、`radius 16`、`bg markdown-code-block`、`font 13/20`；`list maxHeight 320` + 滚动；项 `padding 10/14`，项间 `0.5px border-l2`；字段 `HStack`：label 宽 `5.5em`（≈71.5pt）`caption` 色 + value `secondary` `pre-wrap`，`gap 12`；项标题 13/20 + `gap 8`；状态徽章 12px + 5px 圆点（`success #22C55E` / `warning #F59E0B` / `info #4176E6` / `error #EC1313`）；分组用可折叠行（8pt 上边距、6pt 图标间距、展开旋转 90°） | `tool/result.meta`（多数 key 的 `presentationMeta` 已给结构化对象） | 先把 `details-card-model.ts` 的"item/fields/status/badge/groups"五元组在 Swift 里建同构模型（`NativeToolDetailItem`），再写一个通用渲染器；37 个 key 共用，不逐 key 写 UI | 用 `job_list`/`schedule_list`/`list_agents` 三份真实结果，逐像素核对项内边距与徽章点位 |

### P1

| ID | 严重度 | 差距 | 官方证据 | iOS 证据 | 用户可见影响 | 像素/行为对齐合同 | 数据依赖 | 实施建议 | 验证方式 |
|---|---|---|---|---|---|---|---|---|---|
| T-05 | P1 | 37 个 details key + `skill`/`present`/4 个 `cordis_*` key **没有专用标题**，全部显示「工具调用」 | `tool-call-model.ts:75-122`（`TOOL_TITLE_KEYS` 37 项）+ `locales.ts:89-96,146-179,324-333` | `NativeToolCallModel.swift:44-63` | 用户看到一串一模一样的「工具调用」，完全无法区分在做什么 | 建 `[String: String]` 标题表，逐字采用官方中文：创建目标/查看目标/更新目标/创建定时任务/查看定时任务/删除定时任务/修改定时任务/检查提供方/查询运行时/检查动态插件/运行工作流/运行循环工作流/读取事件/搜索事件/追踪事件/搜索会话/追踪会话/查看可用模型/创建子智能体/查看子智能体/发送消息/中断智能体/查看后台任务/读取任务输出/取消后台任务/创建终端/读取终端/查看终端/发送终端信号/关闭终端/查询代码符号/创建队友/创建团队任务/读取团队任务/更新团队任务/查看团队任务/等待子智能体 + `cordis_*` 四条 | 无（纯静态表） | 把标题表从"switch 特判"改成数据表，与 variant 表并列；`lsp` 还要按 `args.operation` 切 4 个标题（`details-row.tsx:21-26,58-60`） | 单测：对 41 个 key 逐个断言 `title` 等于官方串 |
| T-06 | P1 | `grep`/`glob` 标题被压成「搜索」 | `search-row.tsx:12-15,28-30`；`locales.ts:330-331` | `NativeToolCallModel.swift:53-54` | 分不清"搜内容"还是"找文件" | `grep`→「搜索文件内容」、`glob`→「查找文件」 | 无 | 同 T-05 | 同上 |
| T-07 | P1 | **折叠行没有退出码胶囊** | `ToolRow.tsx:247`、`ExitCodeBadge.tsx`、`ExitCodeBadge.module.css:1-14`、`Tag.module.css:5-15`、`terminal-card-model.ts:107-113` | `NativeToolCallModel.swift:84-108` 无 suffix 概念；`grep -rn "summarySuffix\|diffTotals" → 0` | 命令失败时折叠行与成功行**完全同色同样**，必须点开才知道 | 折叠行末追加胶囊：`padding 1px 8px`、`radius 999`、`font 11/17 w500`、`bg #F5F6F7`(dark `#353638`)、字 `#61666B`(dark `#CFD3D6`)、`margin-left 8`、`gap 5`、前置 4px 红点 `#EC1313`；文案「退出码 {code}」/「信号 {signal}」/「未正常退出」；`exit 0` 与 background 调用**不显示** | 需 T-01 + 新解析：从结果文本 `[exit code: N]` 解析（`terminal-card-model.ts:349` `parseExitStatus`），**不要读 `meta.exitCode`（官方从不写）** | 先补 `parseExitStatus`（正则 + `signal`），再接胶囊 | 三条 bash：exit 0 / exit 1 / killed-by-signal，折叠态分别无胶囊 / 「退出码 1」/「信号 SIGKILL」 |
| T-08 | P1 | **折叠行没有 `+N −M`** | `ToolRow.tsx:188,251-255`、`ToolRow.module.css:64-77`、`diff-card-model.ts` `diffTotals` | 无 | write/edit 之后要先点开才知道改了多大 | 折叠行末：`margin-left 10`、mono、**11pt**、`+` 用 `#22C55E`、`−` 用 `#EC1313`、`translateY(0.5)`；文案 `+{added} -{removed}`（中间一个半角空格）；error/stopped 行**不显示** | `diff-card-model` 的 totals（iOS 已有 `diffs` 但未聚合） | 在 `NativeToolCallModel` 加 `diffTotals: (Int, Int)?`，从 `toolMetadata["diffs"]` 或 args 的 old/new 计数 | 一次 `edit` 改 3 增 1 删 → 折叠行末应有绿 `+3` 红 `-1` |
| T-09 | P1 | **error/stopped 行没有语义色** | `ToolRow.module.css:107-114`（error `#EC1313`/dark `#F25A5A`，stopped `#DD8629`）、`bash-sample.module.css:188-195` | `NativeMessageRows.swift:42` 只有 secondary/tertiary 两态 | 失败行与成功行**肉眼无法区分** | 给 `NativeDisclosureRow` 增 `state` 入参：`error` → summary 用 `#EC1313`(dark `#F25A5A`)；`stopped` → `#DD8629`；图标与标题保持 tertiary（官方也只染 summary） | `toolState`（已有） | 最小改动：把 `running: Bool` 扩成 `tone: .idle/.running/.error/.stopped` | 截图对比：error 行 summary 应为红，其余部分仍灰 |
| T-10 | P1 | **实时 interrupted 不判 stopped**：`turn/end(failed/cancelled)` 或 `tool/result(error.code=='interrupted')` 在实时态显示成 `.error`（红），历史态却显示 `.stopped` | `tool-call-model.ts:315`；投影器同款判断 `NativeTranscriptProjector.swift:97` | `ChatModel.swift:1742` `items[index].toolState = isError ? .error : .ok` **无 interrupted 判定**；`DSHRemoteHarness`/`DSHEventMapper` 也不透传 `error.code` | 同一个被中断的调用，实时看是"失败"，刷新后变"已停止" | `HarnessEvent.Kind.toolResult` 增 `errorCode: String?`；`ChatModel` 用 `errorCode == "interrupted" ? .stopped : (isError ? .error : .ok)` 与投影器同式 | `tool/result.error.code` | 把 `error.code` 加入 mapper（`DSHEventMapper.swift:108-116` 目前只取 `isError`） | 中断一次 bash，实时态与重载后都应显示「已停止」 |
| T-11 | P1 | **颜色 token 系统性偏差**（light/dark 的 tertiary 互换） | `design-platform.css:214-225`（light）、`:332-343`（dark） | `NativeChatTheme.swift:8-23` | 整条 transcript 的工具/思考行都比官方**浅**（亮色）或**深**（暗色）一档，一眼看出不是官方 | 逐项改为：`label-tertiary` light `#81858C` / dark `#ADB2B8`；`label-secondary` light `#61666B` / dark `#CFD3D6`；`label-primary` light `#0F1115` / dark `#F9FAFB`；`label-caption` light `#ADB2B8` / dark `#81858C`（**此项 iOS 已对**）；`markdown-code-block` light `#F9FAFB` / dark `#1B1B1C`；`markdown-code-block-banner` light `#F9FAFB` / dark `#353638`；`border-l1` light `rgba(0,0,0,0.04)` / dark `rgba(255,255,255,0.06)`；`border-l2` light `rgba(0,0,0,0.10)` / dark `rgba(255,255,255,0.12)`；`state-error-primary` light `#EC1313` / dark `#F25A5A`；`state-success-primary` `#22C55E`（两主题）；`state-warn-label` `#DD8629`；`link` light `#4176E6` / dark `#7AAAFF` | 无 | 把 `NativeChatTheme` 改成按官方 token 名命名（`labelTertiary` 等），避免再按"感觉"取值；补一份 token 对照单测 | 单测直接断言 RGB；或截图取色 |
| T-12 | P1 | **卡片几何不对**：圆角 12 vs 16、描边 `#E4E4E8` vs `rgba(0,0,0,.04)`、卡底 `#F6F6F8` vs `#F9FAFB`、terminal 有独立 banner 底色而官方没有 | `ToolRow.module.css:181-189`、`ToolDetails.module.css:1-9`、`TerminalBlock.module.css:20-41`、`CodeCard.module.css:10-21`、`base.css:19-21`（`radius-lg: 16px`） | `NativeToolDetailCards.swift:110-111`（radius 12）、`:95`（`codeBanner`）、`NativeChatTheme.swift:15-18` | 卡片"边太重、角太方、两层色块" | 所有工具卡统一 `cornerRadius: 16`（`.continuous`）、`strokeBorder(lineWidth: 0.5)` + `border-l1`、`bg markdown-code-block`；terminal 去掉 banner 独立底色，改用 0.5px `border-l2` 下分隔线 | 无 | 抽 `NativeToolCardChrome` modifier 统一三件事 | 截图对照卡角与边框亮度 |
| T-13 | P1 | **等宽字号 12pt vs 官方 11pt**，行高也不同 | `gradient-shadow-text.css:170-179`（`code-block` 11/19、`code-block-small` 11/16）、`TerminalBlock.module.css` + `bash-sample.module.css:16-18`（11/18）、`DiffBlock`/`ReadBlock`（11/19）、`SearchBlock`（11/22） | `NativeChatTheme.swift:28` `codeFont(size: 12)`；`NativeToolDetailCards.swift:93,99,129,146,156,225,257` 均默认 12 | 终端/代码每行高约 14.3pt vs 官方 18pt；同样高度的 224pt 卡里 iOS 能多塞几行，换行点也不同 | `codeFont` 默认 **11**；按卡分别设置行高：terminal **18**、read/diff **19**、IN/OUT 与 image meta **16**、search **22** | 无 | 用 `.font(.system(size: 11, design: .monospaced))` + `.lineSpacing(18-13.1≈4.9)` 近似（或 `UIFont` metrics 精确） | 逐卡测量：14 行 terminal 输出高度应为 14×18 = 252pt（含 padding） |
| T-14 | P1 | **图标错配 3 处**：bash 用 terminal 字形（官方 api 拓扑）、web_search 用 search（官方 globe）、todo_write 用 sparkle（官方 checklist） | `GenericToolCard.tsx:17-25`（变体图标）、`web-row.tsx:21`、`todo-row.tsx:78` | `NativeToolCallModel.swift:37,20,49`；`Assets.xcassets/DSHTerminal.svg`（`>_` 字形） | 一眼可辨的"不是同一个产品" | 导入官方 SVG：`IconApiOutlineRegular`（`icons/index.tsx:858-871` 的三横三圆）、`IconGlobeOutlineRegular`（`shared-artwork.tsx:39-45`）、`IconChecklistOutlineRegular`（`icons/index.tsx:1127-1133`）、`IconGoalOutlineRegular`/`IconClockOutlineRegular`/`IconUsersOutlineRegular`/`IconBranchOutlineRegular`/`IconQuestionOutlineRegular`；全部 14pt、`stroke-width: 1` | 无 | `NativeChatIcon.Name` 扩枚举；`NativeChatPresentationTests.swift:82-96`（`model.icon == .terminal` 在 `:94`） 里断言 `.terminal` 的用例需同步改 | 图标逐个与官方 SVG path 比对（search/read/edit/code/sparkle 已逐字相同，可作模板） |
| T-15 | P1 | **通用未知工具的 summary 缺 `toolName ·` 前缀** | `tool-call-model.ts:321`：`summary = [titleKey === 'tool.title.generic' ? toolName : '', base].join(' · ')` | `NativeToolCallModel.swift:104-105` 直接返回 args 首串 | 未知工具时用户只看到「工具调用 · 3」之类，不知道是哪个工具 | `title == "工具调用"` 时 summary 前置 `name + " · "`；`base` 解析顺序保持官方：`args` 键序优先（`SUMMARY_KEYS[variant]` 为空时取**第一个字符串值**），失败则 `firstLine(argsRaw)` | 无 | 在 `summary` 开头加一段；注意 iOS 现在 `if variant == .others { return name }` 的兜底会与官方重复，需改成 `name + " · " + firstString` | 截图里的「工具调用 · Read · Package.swift」应变成「工具调用 · <wire name> · Read · Package.swift」 |
| T-16 | P1 | **read/diff/search 卡缺 banner、缺行数折叠、缺「… 其余 N 行」** | `read-card-model.ts:17`（8）、`diff-card-model.ts:8`（9）、`search-card-model.ts:12`（8）、`CodeCard.module.css:10-21`、`ReadBlock.module.css:29-39`、`DiffBlock.module.css:66-80`、`SearchBlock.module.css:92-106`、`locales.ts:340-356` | `NativeToolDetailCards.swift:120`（`prefix(200)`，无 banner）、`:251`（diff 无上限）、`:149`（search 无上限） | 读一个 200 行文件会把整条消息撑到几屏；官方是 8 行 + 「… 其余 192 行」 | banner：`padding 10/18/8/22`（read/diff，视觉上"上 10 下 8 左 22 右 18"）、`font 11/18`；左侧语言/label `label-tertiary` mono，右侧复制 + 换行 24×24 图标（`gap 4`）；body `padding 6/22/20`（diff）/`0 0 0 (gutter+12)`（read）；上限 read 8（head 4 + tail 4）/diff 9（head `ceil(9/2)`=5 + tail 4）/search 8（同一 `headTailCap`，`SearchBlock.tsx:200`）；折叠行文案「… 其余 {count} 行」（省略号是 U+2026 + 半角空格） | 无（行数可从内容算） | 先做折叠与"…其余"，banner 可后置 | 200 行 read → 卡高应约为 (4+4+1)×19 + banner 36 + padding ≈ 210pt |
| T-17 | P1 | **内容列宽 370pt vs 官方 338pt** | `ChatView.module.css:26-32` + `ConversationRoot.module.css:389` | `ChatPage.swift:799` `.padding(.horizontal, 16)` | 每条 summary 的省略点比官方晚约 4–5 个汉字；卡片宽 32pt | transcript 水平 padding 改 **32pt**（保 composer 16pt 不变），或引入 `contentWidth` 变量并在两者间共享 | 无 | 若担心"太窄"，先只对工具行/卡片加额外 16pt 缩进也可，但会与官方 flow 不一致 | 402pt 下测量卡片左右边距均应为 32pt |
| T-18 | P1 | **没有 Inspect 入口**（跳 trajectory 查看原始调用） | `ToolRow.tsx:357-366`、`ToolRow.module.css:126-167`、`locales.ts:314` | `grep -rn "inspect" examples/probe-app/PhoneDSHProbe` → 无工具行入口 | 手机上没有"看这条调用的原始记录"的路径 | 触屏版**必须常驻**（不能 hover）：`padding 2/8`、`radius 999`、`border 0.5px border-l3`、`font 11/16`、`gap 4`、`margin 4/0/2/4`，图标 `IconInspectOutlineRegular`（`CodeBracketsArtwork`，12pt）+「查看」；Details 卡内右上 `top 12 right 12` 绝对定位 | 需 trajectory 路由（iOS 已有 `NativeTrajectoryEntry`，`ChatModel.swift:1600-1613`） | 放在展开体底部（官方位置），触屏上不要 `opacity: 0` | 展开任一工具卡 → 底部应有「查看」药丸 |
| T-19 | P1 | **`ask_user_question` 行没有"回答/查看回答"行内按钮**，也没有已答/未答转录卡 | `ask-question-row.tsx:300-372`、`QuestionToolRow.tsx`、`AskQuestionCard.tsx:12-39`、`locales.ts:294-295` | `NativeToolCallModel.swift:50` 只有标题 | 用户无法从消息流里直接回答/回看已回答的问题（跨轴：面板在 Axis 03） | 行内 accessory（折叠行右侧）：`回答` / `查看回答` 两个纯文本按钮，`font 13`、`accent` 色、`padding 4/8`；summary 用 `ask.waiting`/`ask.pending`/`ask.closed`/`ask.answered` 四态；展开体用 `AskQuestionCard` 规格（`padding 16/20`、`gap 16`、`maxHeight 360`） | `user-question/*` 事件 + 已回答记录（Axis 03 负责） | 本轴只做"行"：标题改「提问」+ 行内按钮 + summary 四态；卡片交给 Axis 03 | 三个会话：待答 / 已回答 / 已超时，行内按钮分别为「回答」/「查看回答」/无 |
| T-20 | P1 | **`todo_write` 行缺 `{done}/{total} 已完成` 与 `+n` 并行计数** | `todo-row.tsx:46-62`（summary）、`:80-83`（suffix）、`locales.ts:288` | 仅标题特判 | 用户看不出清单进度 | summary = `"{done}/{total} 已完成"`；有进行中项时追加 ` · {activeContent}`；suffix = todo diff 摘要 + `+{extra}`（`extra > 0` 时），`margin-left 4`、13/24、nowrap | `todo_write` 的 `args.todos`（已在 args 里） | 本轴只做行；TodoPanel 归 Axis 02 | 5 项清单 2 完成 → 折叠行「更新任务清单 · 2/5 已完成 · 正在改卡片」 |

### P2

| ID | 严重度 | 差距 | 官方证据 | iOS 证据 | 对齐合同 |
|---|---|---|---|---|---|
| T-21 | P2 | 无 `summarySuffix` 机制（`{KB}`、`+n`、todo diff 都靠它） | `ToolRow.module.css:50-56`、`ToolRow.tsx:248-250` | `NativeDisclosureRow` 只有 `summary` 单串 | 加 `summarySuffix: String?`：`flex none`、`margin-left 4`、13/24、nowrap、**不参与省略计算**（必须单独一个 `Text`，不能拼进 summary） |
| T-22 | P2 | Shimmer 曲线不同 | `TextShimmer.module.css:61-77`：`1.5s`、`delay 0.3s`、`steps(48, end)`、`0%→66.67%` 位移后**停住** | `DSHComponents.swift:53-59`：`1.5s`、`linear`、`repeatForever`、无 delay、全程匀速 | `Animation.timingCurve` 无法表达 steps；用 `TimelineView` + 分段量化相位（48 步），并显式实现 0→2/3→保持；加 0.3s 首帧延迟 |
| T-23 | P2 | 行间距 8pt vs 6px；展开体 4pt 顶空 | `ChatView.module.css:175`（6）、`:64-73` | `ChatPage.swift:435`（8）、`NativeToolDetailCards.swift:30-31`（leading 4 + vertical 4） | 进组行距改 6；去掉展开体外层 `.padding(.vertical, 4)`，改由每张卡自带 `margin: 4/0/4/4` |
| T-24 | P2 | 无 hover/pressed/focus 视觉 | `DisclosureRow.module.css:38-48,84-98`（100ms 颜色 + 图标/chevron crossfade） | 无 | 至少补 `pressed` 态（`interactive-bg-hover` = light `rgba(38,49,72,0.06)` / dark `rgba(255,255,255,0.08)`）与 VoiceOver focus ring |
| T-25 | P2 | stopped 通用行文案被替换 | `ToolRow.tsx:182-186`（只染 warn 色，仍显示原 description）；仅 bash 换成「已停止」（`bash-sample.tsx:76-78`） | `NativeToolCallModel.swift:86` 对所有 variant 都返回「已停止」 | 只对 `bash`/`pwsh` 返回「已停止」；其他 variant 保留原 summary 并染 `#DD8629` |
| T-26 | P2 | `cordis_*` 标题 500 字重缺失 | `ToolRow.module.css:18-20`（`data-tool^='cordis_'`） | `NativeMessageRows.swift:29` 固定 regular | 在行标题加 `weight(.medium)` 当 `name.hasPrefix("cordis_")` |
| T-27 | P2 | 分隔圆点与标签配色需确认（iOS 已对，但不要被 T-11 改坏） | `ToolRow.module.css:26-33` | `NativeMessageRows.swift:32-35` | 圆点保持 `label-caption`（**不是** tertiary），2×2、`margin 0 8` |
| T-28 | P2 | Terminal 卡缺运行状态点与左侧 30px gutter | `TerminalBlock.module.css:1-27,91-96` | 无 | 加 `padding-left: 30`，状态点 `x=8`、`centered on 第一行文字盒`；`running` → `StateDot` 动画；settled → 静态 |
| T-29 | P2 | diff 缺 `inset 3px` 左侧色条与 `+ `/`- ` 前缀语义 | `DiffBlock.module.css:38-64` | `NativeToolDetailCards.swift:252-260`（1 字符标记、无左条） | 每行加 `overlay(alignment: .leading)` 的 3pt 色条；`+`/`-` 后跟一个半角空格再是内容；`context` 行前置两个空格保证列对齐 |

### P3

| ID | 严重度 | 差距 | 官方证据 | iOS 证据 |
|---|---|---|---|---|
| T-30 | P3 | `Auto review` 拒绝行：官方强制走 generic 行并替换 summary/OUT 文案 | `tool-call-model.ts:165-172`、`ToolCallTree.tsx:40-55`、`auto-review-denial.ts:29-34`、`locales.ts:334-336` | iOS 无（`grep -rn "AUTO_REVIEW\|autoReview" → 0`） |
| T-31 | P3 | `image` 卡的尺寸行文案 `{width}x{height}px，{bytes} 字节` | `ToolRow.tsx:287-303`、`locales.ts:315-316` | 无 |
| T-32 | P3 | `cordis_*`、`ralph`、`terminal_*`、`team_task_*`、`session_event_*`、`lsp` 的专用卡（低频，可后置） | `details-row.tsx:87-116`、`ui-cordis/src/client/index.ts:117-146` | 无 |
| T-33 | P3 | `read.window` / `search.paths` / `details.running` 等小文案 | `locales.ts:340-356` | 无 |

## 5. 隐藏/条件控件清单

| 控件 | 触发条件 | 官方出现位置 | iOS 是否有 | 备注 |
|---|---|---|---|---|
| 退出码胶囊 | `exitCode != 0` / `exitCode == null` / 有 `signal`，且非 background | `ToolRow.tsx:247`、`terminal-card-model.ts:107-113` | ❌ | 只在展开 banner 内以 `exit N` 形式出现，且数据源（`meta.exitCode`）官方不写 |
| `+N −M` diff totals | 有 diff 卡且非 error/stopped | `ToolRow.tsx:251-255` | ❌ | 仅 hover/展开着色 |
| `{KB}` 内容后缀 | `write`/`edit` 的 `content`/`old_string`/`new_string` 已有内容 | `file-mutation-row.tsx:16-37,47` | ❌ | 含 preparing 期 |
| `+n` 并行计数 | todo 有多个 in_progress | `todo-row.tsx:80-83` | ❌ | 用 suffix 而非 summary，避免被省略 |
| 文件路径可点链接 | `read`/`write`/`edit`/`read_image` 的 `file_path` | `ToolRow.tsx:216-224`、`tool-call-model.ts:247,309-313` | 部分（在展开体里，非 summary） | 官方 summary 本身是按钮，点线 |
| URL 外链 | `web_fetch` 的 `url` | `ToolRow.tsx:225-235`、`web-card-model.ts` `webFetchHref` | ❌ | |
| Inspect 药丸 | 有 `inspect` 回调（trajectory 可用时） | `ToolRow.tsx:357-366` | ❌ | hover-only，触屏需改常驻 |
| 子调用缩进轨 | 父调用有 `subCalls` 且非 preparing | `ToolCallTree.tsx:82-99` | ❌ | 始终可见，不在展开体内 |
| Details 卡 | 37 个 key + 结果已落定 | `details-row.tsx:60-77` | ❌ | 空态「暂无结果」 |
| AskQuestionCard | `ask_user_question` 且能解析出 questions/answers | `ask-question-row.tsx:362-383` | ❌ | 未答/已答两形态 |
| 行内「回答」/「查看回答」 | `answerable` 或 `record` 可用 | `ask-question-row.tsx:341-351` | ❌ | `QuestionToolRow` 的 accessory |
| read/search/diff 的"…其余 N 行" | 超 `CHAT_READ_MAX_LINES`(8)/`CHAT_SEARCH_MAX_LINES`(8)/`CHAT_DIFF_MAX_LINES`(9) | `ReadBlock.module.css:29-39`、`DiffBlock.module.css:66-80`、`SearchBlock.module.css:92-106` | ❌ | 可点开 |
| 搜索恢复定位行 | `searchCardModel.recovery !== undefined`（结果被上限截断） | `ToolRow.tsx:317-319`、`ToolRow.module.css:270-276` | ❌ | 卡片下方 13/20 tertiary |
| 卡片复制/换行工具条 | 所有 CodeCard/Diff/Read/Search/Terminal | `CodeCard.module.css:10-48`、各 Block 的 `copyButton` | ❌ | 24×24 命中区 |
| terminal 运行状态点 | 有 terminal 卡 | `TerminalBlock.module.css:91-96` | ❌ | 30px gutter 内 |
| Auto review 拒绝 | `error.code === 'AUTO_REVIEW_DENIED'` | `ToolCallTree.tsx:50-51` | ❌ | 走 generic 行 |
| image 图库 | `read_image` 结果为图片 | `ToolRow.tsx:275-305` | ❌ | 走 `tool.call.images` slot |
| 屏幕阅读器状态词 | 每次渲染 | `ToolRow.tsx:107-116,375` | 部分（`accessibilityValue` 只有 4 值，且缺 preparing） | 官方是 `visuallyHidden` span |

## 6. 数据链路缺口

| 事件/字段 | 官方消费方 | iOS 映射/投影 | 缺失后果 | 需要补什么 |
|---|---|---|---|---|
| `tool/result.meta` | `read-card-model.ts:107`、`terminal-card-model.ts:326-329`、`search-card-model.ts`、`web-card-model.ts`、`diff-card-model.ts`、`details-card-model.ts`、`image-card-model.ts` | 仅 `NativeTranscriptProjector.swift:95,107` 写 `data["meta"]`；`DSHEventMapper.swift:108-116` 完全丢弃；`ChatModel.swift:1731-1752` 不写 | **实时态全部卡片族降级**（T-01，P0） | `HarnessEvent.Kind.toolResult` 增 `meta`；mapper 透传；ChatModel 写入；projector 与 ChatModel 共用同一 apply 函数 |
| `tool/result.error.code` | `tool-call-model.ts:315`（`interrupted` → stopped） | `DSHEventMapper.swift:110-111` 只取 `isError`，丢 `error.code` | 实时 interrupted 被算作 error（T-10，P1） | 加 `errorCode` 字段 |
| `tool/ptc-dispatch-start` / `tool/ptc-dispatch` | `ui-chat/.../conversation-nodes/tool.ts:199-225`、`ToolCallTree.tsx:82-99` | **0 命中**（穷尽搜索见 §1.3） | 子调用树完全不可见（T-02，P0） | 两个事件 → `.toolDispatchStarted/.toolDispatchSettled`；`ChatItem.parentCallID/subCalls` |
| `assistant/live-chunk`（`tool-call-delta`/`block-start`/`block-end`） | `ui-chat/.../conversation-nodes/tool.ts:60-95` | `DSHRemoteHarness.swift:352-363` 只转 `text-delta`/`reasoning-delta`；`grep live-chunk → 0` | 无 preparing 行（T-03，P0） | 转 `tool-call-delta`，建临时 preparing 行 |
| `tool/result.meta.diffs` 的 totals 聚合 | `diff-card-model.ts` `diffTotals` | iOS 有 `diffs` 原始数据（`NativeToolDetailCards.swift:231`），未聚合 | 无 `+N −M`（T-08，P1） | 加 `diffTotals` 计算 |
| bash 的 `exitCode`/`signal` | 从结果文本 `parseExitStatus` 解析（`terminal-card-model.ts:349`） | iOS 读 `meta.exitCode` / `meta.exit_code`（**官方从不写**，`tool-bash/src/index.ts:476` 只给 `{cwd}`） | 退出码永远 nil（T-07） | 实现 `parseExitStatus`，别读 meta |
| `tool/result.meta.cwd` | `terminal-card-model.ts:327` | 未读 | terminal banner 无 `$ dir` 前缀 | 读 `meta.cwd` |
| `subagent`/`list_agents`/`job_*` 的结构化结果 | `details-card-model.ts` + `inspection-details-model.ts` | 完全无 | 子 Agent/后台任务状态只能看 JSON（T-04） | 同 T-01 + Details 卡 |

## 7. 实施顺序建议

**Wave 1（先修数据，否则上面做的 UI 有一半看不到）**
1. T-01 `tool/result.meta` 全链路（mapper → HarnessEvent → ChatModel + projector 合一）。
2. T-10 `error.code` 透传 + interrupted→stopped 统一。
3. T-07 退出码：实现 `parseExitStatus`（不要读 `meta.exitCode`）。

**Wave 2（用户一眼能看出"不是官方"的）**
4. T-05/T-06/T-15 标题与 summary 表（改动小、收益大）。
5. T-14 图标导入（bash/web_search/todo_write 三个 + details 族 10 个）。
6. T-09 状态色 + T-11 token 校正 + T-12 卡片几何；T-13 字号 12→11。
7. T-08 diff totals、T-20 todo summary、T-21 suffix 机制。
8. T-16 read/diff/search 的 banner 与行数折叠。

**Wave 3（新面）**
9. T-03 preparing 行（依赖 `assistant-stream` 帧处理）。
10. T-02 嵌套 subcall 树。
11. T-04 Details 卡族（先建 `NativeToolDetailItem` 模型，再一个通用渲染器覆盖 37 key）。
12. T-18 Inspect、T-17 列宽、T-19 ask 行内动作（与 Axis 03 协同）。

**收尾**：T-22 shimmer 曲线、T-24 pressed/focus、T-28/T-29 卡内细节、P3 族。

## 8. 未知与需确认

1. **`meta` 的具体 key 集合未穷尽核对**。已知 `read` 有 `{path, offset, lines, totalLines, lang}`（`read-card-model.ts:49-70`）、bash 只有 `{cwd}`、`web_search`/`web_fetch` 有独立 meta（`search.ts:360`、`fetch.ts:316`）、fs 系带 `diffs`/`path`。但 `diff-card-model.ts` 与 `search-card-model.ts` 的完整字段清单需要逐个 `presentationMeta` 回读才能确认，本轴只做了静态覆盖。
2. **`tool-call-delta` 在真实 wire 上是否对所有 provider 都下发**（`frame.chunk.type` 的名称与字段）：`DSHRemoteHarness` 目前只白名单两个 type，扩充前需要抓一份真实 `assistant-stream` 帧确认 `tool-call-delta` 的 `id`/`name`/`argumentsDelta` 字段名与官方 `StreamChunk` 一致（`packages/api/session-controller/src/client/sessions/assistant-stream.ts:87`）。
3. **触屏上的 hover 语义**：官方 diff ± 上色、图标→chevron crossfade、Inspect 药丸都是 hover-gated。官方自己在 402pt 下也没有触屏适配（`mobile.module.css` 无工具覆盖）。iOS 侧需要产品决策：是"点一下=hover+展开"两步，还是直接常驻。本报告按"常驻更符合手机"给合同，但这是**设计决策点，不是官方事实**。
4. **`IconApiOutlineRegular` 是否就是 bash 的最终视觉**：源码确定 `bash-sample.tsx:27` 用 `IconApiOutlineRegular`，但它的字形（三横三圆拓扑）与"运行命令"的语义关联较弱，可能官方在别处另有图标资源；建议真机截图确认后再替换 iOS 的 `DSHTerminal`。
5. **338px 内容宽 vs 370pt**：这是全 transcript 共享的宽度轴（`--dsh-chat-content-width`），改它会同时影响消息气泡、markdown 表格 breakout、composer 对齐。**归属 Axis 01/05**，本轴只登记它对本轴的影响（summary 省略点位置、卡片宽度）。
6. **`details-card-model.ts` 的 37 key 分支是否都已实现**（有没有 key 落到 `empty`）：本轴未逐个跑，需要读 `details-card-model.ts` + `control-details-model.ts` + `inspection-details-model.ts` 三个文件全文才能给"哪个 key 有几种卡"，本次只确认了入口与通用渲染器。
7. **iOS 侧是否有其他入口产生 `toolState`**：`NativeShell.swift:913,929` 在某个 preview/seed 路径里手工构造 `bash`/`edit` 的 `.ok` 与 `exitCode: 0`，需要确认该路径是否只在 `-uiPreview` 生效；若是正式路径，会污染真实会话行的状态。
