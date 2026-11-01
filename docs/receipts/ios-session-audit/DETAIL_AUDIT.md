# iOS ⇄ 官方 DSH 细节验收（Session 线）

对照基准：`deepseek-harness` `7be5505b0b`，官方 402×874@3 截图 `screens/official/official-session-chat-tool-402x874-dpr3.png`（真实 seed fixture，assistant-step + tool-call + bash 卡 + turn tail）。
iOS 截图：`screens/current/sample-chat.png`（浅色）、`sample-chat-dark.png`（深色）。

## 1. 行盒 / 行距

| 元素 | 官方 | iOS | 证据 |
|---|---|---|---|
| 正文 | 14/24 | 14/24；`NativeChatTheme.messageLineSpacing` 随字号计算，默认 7.3pt 补足 24 行盒 | `NativeMarkdownBody` |
| 用户气泡 | 14/22，padding 10×16，radius 20，max 277 | 同 | `NativeMessageRows` / `ChatPage` |
| ToolRow（标题/摘要） | 13/24，leading 16 + gap 6，dot 2 + margin 8 | `NativeDisclosureRow` 24 高，16 + 6，dot 2 + 8 | `NativeMessageRows` |
| ProcessGroupHeader | 14/24，expanded +8 | 固定 24 行盒 + `padding(.bottom, 8)` | `NativeProcessGroupHeader` |
| Process 成员间距 | 6 | 6（`ToolRunRow.processRows`） | `ChatPage` |
| Header→第一个成员 | 8（header 自带） | 8；`ToolRunRow` 外层 VStack 已从 6 改为 0，避免 8+6=14 | `ChatPage` |
| Assistant response 两侧 | 12 | 12 | `NativeTranscriptRow.spacing` |
| 其他 flow | 6 | 6 | 同上 |
| TurnProcess 上下 | 16 | 16 | 同上 |
| TurnTail | 16 + actions 4 | 12/6 + tail 自带 4 | 同上 |

## 2. 宽度 / 对齐

- 内容列 338pt（402 − 2×32），左右 32；正文、tool row、工具卡、turn control 共用同一左缘。
- Tool row 的 leading 16 盒与文字行左缘对齐；标题从 +22 开始，和官方一致，不是“缩进错位”。
- Bash 卡：`margin: 4 0 4 4`，宽 = 内容列 − 4；header padding 12；code 11/18；与官方 `TerminalBlock` 口径一致。
- Composer 370×98、radius 28、16pt 输入；由 `NativeComposer` 统一。

## 3. 本轮修正

1. `ToolRunRow` 外层 `VStack` 6 → 0：删除 header 与 body 之间多加的 6pt（官方 header 已带 8pt）。
2. `NativeProcessGroupHeader` 固定 24pt 行盒：组头与 24pt 的 tool/正文行同高。
3. `NativeTranscriptRow.spacing` 20/12/8 → 官方 6/12：Assistant response 前后 12，其余 6。
4. `NativeChatTheme.messageLineSpacing` 固定 5 → 按 24 行盒动态计算；默认 14pt 下是 7.3，不再出现正文 22pt / 工具 24pt 的行距错位。
5. PR11 `NativeMarkdownBody` 全量融合：段落 20、列表 10、表格 `ViewThatFits`（网格/卡片）。

## 4. 仍不是逐像素的部分

- 官方 402pt 仍有「对话/轨迹」tab 与左侧标题；iOS 按 D-04 移除 tab、标题居中（产品决策）。
- 官方 tool 行使用自家 SVG 图标；iOS 用 SF Symbol 近似（几何 14×14 一致）。
- 官方会话头把 subagent 计数做成 `1/2 个子智能体` chip；iOS 按产品决策收进 more 菜单（无头部 chip）。
- 官方 question 已拿到 **answered** 卡、plan 已拿到 **approved** turn-tail PlanCard、subagent 已拿到 1/2 子智能体 + subagent 行 + turn-trigger；pending 的 composer 接管/Plan review 面板与官方深色仍缺。
- 深色：session 页、设置/文件/搜索/模型/插件/计划页、sessions drawer/SessionsPage 已切语义色；固定 402pt chrome 未做 AX。
