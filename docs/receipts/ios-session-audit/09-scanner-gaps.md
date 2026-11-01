# 09b — 脚本补扫发现（官方 surface 覆盖复核）

> 生成方式：`python3 scripts/ios-parity/audit.py`
> 官方基线：`deepseek-harness` @ `7be5505b0b`（`0.2.1-rc.2`）
> 输出：`docs/receipts/ios-session-audit/parity/`（`coverage.md`、`official-tokens.json`、`official-components.json`、`official-inventory.json`、`ios-inventory.json`、`comparison.json`、`summary.json`）
> 目的：在 8 份轴报告之外，用脚本独立扫一遍官方注册表，检查“方案有没有整块漏项”。
>
> **实施状态（2026-11-01）：** `conversation.view` 的「对话 / 轨迹」tab 曾实现，后按产品决策移除（D-04：移动端不做轨迹）；页头回到 50pt。header 贡献已统一收进 more（…）菜单，`open-in-app` 记 N/A，`sidebar-right` 为 sheet 适配。见 [10-wave0-implementation.md](10-wave0-implementation.md) §3 与 [DECISIONS.md](DECISIONS.md)。

---

## 0. 结论

- **Chat node kind：20 / 20 被 01–08 报告按名字覆盖，0 漏。**
- **Toolview key：54 / 54 被 06 报告按名字覆盖，0 漏。**
- **Slot：35 个注册点；去掉布局/子 seat 后，可见 slot 全部被报告按名字或同义词覆盖。**
- **Projection：29 个 key；可见 projection 全部被报告覆盖。**
- 但“按名字/同义词覆盖”不等于“真的审到了”。脚本标出了 16 个 **同义词覆盖**的 slot 和 1 个项目 `agentPreset`，逐一人工复核后，发现 **1 个整块漏项 + 1 组 header 控件漏项**：
  1. **`conversation.view` 的「对话 / 轨迹」双 tab + Trajectory view**：8 份报告只提到了 trajectory 数据/调试，没有把“轨迹 tab”当作会话页 surface 审；iOS 也没有 tab，`NativeTrajectoryRow` 是死代码、`refreshTrajectory` 数据无出口。
  2. **Header 的 `agent-preset` / `job-list` / `schedule-catalog` / `open-in-app` / `session-log-download` / `sidebar-right corner`**：08 报告审了 header 的四个**槽位几何**，但没有逐个审这些**贡献控件**；`agentPreset` projection 也未被任何报告提到。
- 这两个漏项**不改变 24 条 P0 的结论**（它们属于 P1/P2），但会改变 Wave 2/3 的范围和验收矩阵。已在 master 中补入。

---

## 1. 脚本扫描到的官方注册表

| 项 | 数量 | 报告覆盖 |
|---|---:|---|
| Chat node kind | 20 | 20 / 20 |
| Toolview key | 54 | 54 / 54 |
| Conversation slot（注册点） | 35 | 可见 slot 全部有名字/同义词覆盖 |
| Session projection key | 29 | 可见 key 全部有名字/同义词覆盖 |
| 官方组件 surface | 23 | — |
| Light token | 405 | — |
| Dark token | 193 | — |
| iOS ChatItem.Kind | 12 | — |
| iOS tool variant | 7 | — |
| iOS generic toolview | 42 / 54 | 见 06 报告，已知 |

脚本还解析出：
- **View tabs**：`chat`（`ui-chat`）、`trajectory`（`ui-trajectory`）。
- **Header contributions**：`subagent-catalog`、`agent-preset`、`job-list`、`schedule-catalog`、`open-in-app`、`session-log-download`、`mobile-menu`、`sidebar-right corner`，以及 experimental 的 `agent-team`。
- **Dock contributions**：`todo`、`queue`、`goal`、`activity`、`usage`、`slash-menu`、`command-popup`、`feedback-dialog`，以及 experimental 的 `claude-code-mods`/模板示例。

---

## 2. 漏项 A：`conversation.view` — 对话 / 轨迹双 tab（P1）

### 官方

- `ui-chat` 注册 `conversation.view`，`id: 'chat'`，`order: 0`，label `view.chat`（`packages/client/ui-chat/src/client/apply.ts:227-235`）。
- `ui-trajectory` 注册 `conversation.view`，`id: 'trajectory'`，`order: 10`，label `view.trajectory`，children `conversation.trajectory.images`（`packages/client/ui-trajectory/src/client/index.ts:79-86`）。
- `ConversationSession` 在 `tabs.length > 1` 时渲染 `role="tablist"` 的 tab strip（`ConversationSession.tsx:66,140-157`）。
- `ui-trajectory` 在 shipped web-app 里（`packages/bundle/web-app/package.json:122`），不是 experimental。
- 官方 tab 样式：`ConversationRoot.module.css` 的 `.tabs` / `.tab` / `.tabActive`（35px strip、gap 36、pad-left 8、active bar 覆盖 header rule）。
- `ui-mobile` 没有隐藏 tabs 的覆盖；402pt 下是否与 breadcrumb/actions 挤压，未实测（见 §4）。

### iOS

- `ChatPage` 没有 tab strip；header 只有标题 + 状态点 + `...` 菜单（`ChatPage.swift:113-171`）。
- `ChatModel` **已经在拉 trajectory 数据**：`refreshTrajectory()`（`ChatModel.swift:459-499`）、`loadEarlierTrajectory()`（`:502-529`）、`NativeTrajectoryEntry`（`:72-90`）。
- `NativeTrajectoryRow` 在 `ChatPage.swift:2781` 定义，但**全仓库没有调用点**（`grep "NativeTrajectoryRow("` → 0）。
- 因此 iOS 有“轨迹数据 + 行视图”，但没有“轨迹 tab/入口”，用户看不到。

### 影响

- 官方会话页是「对话 / 轨迹」两个视图；iOS 只有对话。用户想按事件序列排查一轮 agent 的执行过程时，没有官方那个入口。
- 这不是核心聊天路径，但属于 session 页的一整块 surface，**P1**。
- 与 `SessionActivityPage`/`SessionQueuePage` 一样，iOS 已有数据/视图但**没有入口**——这是本仓库的一个重复模式。

### 建议

- 在页头下方加 tab strip，`对话` / `轨迹` 两个 tab；`轨迹` 复用 `NativeTrajectoryRow` + `trajectoryEntries` + `loadEarlierTrajectory`。
- 官方 tab 几何：35pt strip、gap 36、pad-left 8、active bar 2px 覆盖 header 0.5px 线；文字 13/20？以 `ConversationRoot.module.css` 解析值为准（脚本 §3 `header`/`tabs` 只有 `.header`，没有 `.tab`；下一版把 `.tab`/`.tabActive` 加进 surface 表）。
- 402pt 下如果 tabs + breadcrumb + header actions 挤压，按官方“标题先截断、chip 不塌陷”的策略处理；需要真机确认。

---

## 3. 漏项 B：Header 贡献控件（P1/P2）

08 报告审了 `conversation.session.header.actions / utilities / corner / lineage` 的**槽位布局**，但没有逐个审“谁注册了什么控件”。脚本列出 shipped 贡献：

| slot | id | 官方文件 | iOS 现状 | 优先级 |
|---|---|---|---|---|
| `header.lineage` | `subagent-catalog` | `ui-subagent/src/client/index.ts` | 无 breadcrumb/catalog（04 SB-05） | P0（已覆盖） |
| `header.actions` | `subagent-catalog` | 同上 | 无 | P0（已覆盖） |
| `header.actions` | `agent-preset` | `ui-agent-preset/src/client/index.ts` | 已读 projection + `agentPresets/list` 名称，页头只读标签；无切换器 | P1（已接只读） |
| `header.actions` | `job-list` | `ui-jobs/src/client/index.ts` | 有 job 时页头 `list.bullet` + sheet | P1（已接） |
| `header.actions` | `mobile-menu` | `ui-mobile/src/client/index.ts` | iOS 是 `...` 菜单，功能不同 | P1/P2（部分覆盖） |
| `header.utilities` | `schedule-catalog` | `ui-schedule/src/client/index.ts` | 有 schedule 时页头 `calendar.badge.clock` + sheet | P2（已接） |
| `header.utilities` | `open-in-app` | `ui-open-in-app/src/client/index.ts` | iOS 无宿主进程/目录；官方谓词恒空，**N/A**，见 [DECISIONS.md](DECISIONS.md) D-01 | N/A（已决） |
| `header.utilities` | `session-log-download` | `session-query/session-log-export/src/client/index.ts` | 导出在本会话 `...` 菜单（页头预算不足，未放独立键） | P2（适配） |
| `header.corner` | `sidebar-right` | `ui-sidebar-right/src/client/index.ts` | 官方 <768px 本就全屏抽屉；iOS 为 `.large` sheet，入口收进 more（…）菜单（右上只留一个 icon），见 [DECISIONS.md](DECISIONS.md) D-02 | P2（适配，已接菜单） |
| `header.actions` | `agent-team` | `experimental/client-ui-agent-team` | 不随附；不补 | P3 |

**影响**：
- 官方页头在 402pt 下不只是“标题 + 状态”，而是一排 session 级入口：子 Agent 目录、agent preset、后台任务、定时任务、外部打开、会话日志、右侧栏。iOS 只有“标题 + 状态 + 更多”。
- 用户截图里能直接看到 `8 个子智能体`、`1 个后台任务运行中`——正是这些 header contributions。
- 这些不是核心聊天路径，但影响“会话页像不像官方”和“能不能从会话页管理会话”。P1/P2。

**建议**：
- 先把 `agent-preset` + `job-list` + `subagent-catalog` 做进 header；`schedule-catalog`/`open-in-app`/`session-log-download` 放 Wave 3；`sidebar-right` 用 iOS sheet 等价，标注设计决策。
- `agentPreset` projection 需要读 `session/projections` 的 `agentPreset`，并接 `agentPresets/list` 切换。
- 402pt 页头空间不足时，按官方手机策略：标题截断、actions 收进 `mobile-menu`；具体阈值需实测。

---

## 4. 不是缺口、但需要确认的项

| 项 | 脚本结论 | 人工判断 |
|---|---|---|
| `conversation.input.plan/permission/model/attachments` | 同义词覆盖 | 02/08 已按功能审到（Plan chip、access mode、model、attachment），不需要重开 |
| `conversation.chat.assistant-actions` | 同义词覆盖 | 07 已审 feedback/actions；不需要重开 |
| `conversation.chat.reasoning.body/content` | 同义词覆盖 | 05/07 已审 reasoning；不需要重开 |
| `conversation.hero.workspace` | 同义词覆盖 | 08 C-03 已审 hero/workspace chip；不需要重开 |
| `conversation.images.content` | 同义词覆盖 | 07 C-01 已审图片；不需要重开 |
| `conversation.user.text.node` | 同义词覆盖 | 07 已审 user text/引用；部分细节（goal command reference）可补 |
| `modelSelection` projection | 01 提到，08 审 model menu | 功能覆盖；投影解码细节可在实现时补 |
| `llmRetry` / `turnBoundary` / `timeContext` / `sandboxMode` | 脚本标 internal/experimental | 已由 07（retry）/05（turn）/07（context）/01（permissions）功能覆盖，不需要单列 |
| `agentTeam` / `subagentModelSelectionPolicy` | experimental | 不随附，不补 |
| `workingDirectory` | 脚本标 internal | 会话工作区；不属于本次会话内容线 |

---

## 5. 对 master 方案的更新

1. **P0 不变**：24 条 P0 仍然成立；新发现是 P1/P2。
2. **新增 P1 热点**：
   - `conversation.view` 对话/轨迹 tab + Trajectory view（数据已有，视图死代码）。
   - `agentPreset` header 控件 + projection。
   - `job-list` header 按钮（部分覆盖）。
3. **新增 P2 热点**：
   - `schedule-catalog`、`open-in-app`、`session-log-download`、`sidebar-right corner`。
4. **Wave 2** 增加：轨迹 tab + `NativeTrajectoryRow` 接线；header `agent-preset`/`job-list`.
5. **Wave 3** 增加：`schedule-catalog`/`open-in-app`/`session-log-download`/`sidebar-right` 等价物。
6. **验收矩阵**增加：
   - G15 轨迹 tab：官方「对话/轨迹」双 tab，切到轨迹能看到事件序列、可加载更早。
   - G16 header 贡献：子 Agent 目录、agent preset、后台任务、定时任务入口在 402pt 下可见/可收纳。

---

## 6. 脚本本身的局限

- **静态扫描**：只解析 CSS/TSX/Swift，不运行官方 Web、不渲染 402pt、不截图。`conversation.view` 在 402pt 是否真的显示、header 是否溢出，仍需 golden 截图确认。
- **注册点识别**：用 `register({ ... name: 'conversation...' })` 的正则窗口；极少数动态注册/别名可能漏。脚本已把“同义词覆盖”单独列出，避免把“没按名字提到”误判成“没审”。
- **projection 分类是人工表**：`PROJECTION_CLASS` 需要随官方新增 key 维护；未知 key 会落到 `internal`，不报警。
- **没有 iOS 运行时度量**：iOS 探针只是源码常量，不是实际渲染尺寸；像素验收仍需截图 diff。

---

## 7. 复跑方式

```bash
cd /Users/leilangsheng/Desktop/TonoTeam/phone-dsh
python3 scripts/ios-parity/audit.py
# 或指定路径
python3 scripts/ios-parity/audit.py \
  --official /path/to/deepseek-harness \
  --ios /path/to/phone-dsh \
  --out docs/receipts/ios-session-audit/parity
```

每次官方 pin 或 iOS chat 代码变化后复跑；`coverage.md` §1 的“同义词覆盖”列表是最值得人工复核的候选。
