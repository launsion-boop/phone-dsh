# 402pt golden 状态

## 结论

**官方 Web UI 的 402×874 DPR3 截图已覆盖 9 个状态**：hero、首次认证闸门、两张真实本地会话（chat）、一张富会话（assistant 文本 + 展开的 bash 工具卡）、一张已作答问答卡、一张已批准计划卡、**一张子智能体态（会话头 `1 个子智能体` 计数 + 展开的 subagent 工具行）**、**一张并行子智能体态（`2 个子智能体` + 两张 subagent 行）**。

本轮补上的两张是 iOS 明确要求的 **会话头 / catalog 计数 + subagent 工具行**：

- `official-session-subagent-…png`：官方 `subagent-spawn-in-process` 录音播种后，会话头把日志里的 `subagent/catalog` 投影成 `1 个子智能体` 计数按钮（`button[aria-haspopup="tree"]`）；展开 turn process → `已协调子智能体` 过程组 → `subagent` 工具行后，行卡显示 `创建子智能体` / `调用结果` / prompt / `● 已启动` / `智能体 ID …-child-2`。
- `official-session-subagent-parallel-…png`：同一工具的 `subagent-parallel` 录音（两条 `subagent/catalog`）→ 头部 `2 个子智能体`、同一个过程组里两张 `subagent` 行（第一张展开、第二张折叠）。两张图**只差 catalog 事件**，因此证明头部计数是从日志派生的，不是写死的标签。

但必须说清楚来源与边界：

- **问答卡 / 计划卡不是 pending 接管态**：官方 web fixture 里 `ask_user_question` / `exit_plan_mode` 都带 `tool/result`（已作答 / 已批准），所以渲染的是**已结算**的问答卡与计划卡；`question-composer/ui.expected.md` 与 `plan-review/review.expected.md` 描述的**待回答 composer 提问面板**、**`Plan review`（Approve / Request changes）接管面板**没有对应的官方录制日志，**没有截图，也没有伪造**（没有截断 fixture、没有删 `tool/result`）。
- **`official-session-chat-tool-…png` 不是本机实时模型运行**：转录来自官方仓自带的记录 fixture `snapshots/session/bash-tool-turn/session.v4.jsonl`，由 `seed-official-session.mjs` 经官方格式读取器 + 官方 `JsonlSessionPersistence` 播种进**临时 DSH_HOME 副本**（副本里替换掉单轮失败会话，真实 `~/.dsh` 只读）。五张 fixture 图（bash / 问答 / 计划 / 子智能体 ×2）走同一条播种路径。
- **子智能体两张图不是实时运行，也不是子会话转录**：fixture 是官方仓的 `snapshots/session/subagent-spawn-in-process/session.v4.jsonl` 与 `snapshots/session/subagent-parallel/session.v4.jsonl`；`{{session:2}}` / `{{session:3}}` 被官方 realize 规则展开成 `<sessionId>-child-2` / `-child-3`，但副本里**没有**这些子会话目录，所以截图证明的是**父会话头部 catalog 计数 + 父转录里的 subagent 工具行**（`tool/result` 为 `started subagent <childId>` 的已结算态），**不是**子会话转录。工具行里的「查看」没有点击（点开也打不开不存在的子会话）。
- 本地 `~/.dsh` 的 8 个会话仍然**全部是单轮**，且都以 `MISSING_CREDENTIAL`（未配置 API Key）失败结束；两张本地 chat golden 仍只能校验页头 / user 气泡 / 时间戳 / turn-error / turn tail / composer。
- 官方会话截图来自**真实本地 DSH_HOME 的临时副本**（源目录只读）；打开 V3 会话会在原地迁移成 V4，所以服务端从不指向真实 `~/.dsh`。
- `docs/receipts/ios-baseline-screens/ios-chat-official.png` 不是官方 Web UI，是 iOS 的 `chat.official` 预览页（`INDEX.md:77`）。

## 已捕获

| 文件 | 尺寸 | 状态 |
|---|---|---|
| `screens/official/official-hero-sessionless-402x874-dpr3.png` | 1206×2622 | 官方 sessionless hero（pristine DSH_HOME）；PWA banner / 预览版说明 / 开始使用弹窗均已关闭 |
| `screens/official/official-auth-gate-402x874-dpr3.png` | 1206×2622 | 官方首次认证闸门：登录 DeepSeek 账号 / 添加 API Key |
| `screens/official/official-session-chat-402x874-dpr3.png` | 1206×2622 | **官方真实会话（chat）**：标题 `reply with the single word`，user 气泡 + `10月21日 11:02` + `处理失败 / 本轮运行失败 … MISSING_CREDENTIAL` + composer + `1 轮 1 步` |
| `screens/official/official-session-chat-long-user-turn-402x874-dpr3.png` | 1206×2622 | 官方长 prompt 会话，滚动到 turn tail：代码块 user 气泡 + 时间戳 + 失败卡 + composer |
| `screens/official/official-session-chat-tool-402x874-dpr3.png` | 1206×2622 | **官方富会话（fixture 播种）**：标题 `Use the bash tool to`；user 气泡 + 展开的 `已完成，用时 1秒` turn process + 展开的 `执行了命令` 工具组 + **bash 工具卡**（`deepseek-harness` / `echo TERMINAL_OK` / `TERMINAL_OK` / 复制）+ assistant 文本 `DONE` + turn tail + composer + `1 轮 2 步` |
| `screens/official/official-session-question-402x874-dpr3.png` | 1206×2622 | **官方问答卡（fixture 播种，已作答态）**：标题 `Use the ask_user_question tool to`；user 气泡 + `9月1日 13:30` + 展开的 `已完成，用时 2秒` turn process + 展开的 `向用户提出了问题` 组 + **`提问 · 1/1 已回答` 卡**（`Which color do you prefer?` / `Blue` / `Include accessibility notes` / `查看`）+ `DONE` + turn tail + composer + `1 轮 2 步`；**不是**待回答的 composer 提问面板 |
| `screens/official/official-session-plan-402x874-dpr3.png` | 1206×2622 | **官方计划卡（fixture 播种，已批准态）**：标题 `Plan a small change: add`；`plan · Plan mode on. Use /plan off to leave.` 命令行 + user 气泡 + `9月1日 13:29` + 默认折叠的 `已完成，用时 5秒` turn process + `DONE` + **turn tail 计划卡**（`Add \`--greeting\` flag to CLI` / `计划 · Markdown` / `打开`，`data-plan-card`）+ turn tail 时间 `9月1日 13:30` + composer + `1 轮 2 步`；**不是**待审批的 `Plan review` 接管面板 |
| `screens/official/official-session-subagent-402x874-dpr3.png` | 1206×2622 | **官方子智能体态（fixture 播种）**：标题 `Use the subagent tool exactly`；**会话头 `1 个子智能体` 计数按钮**（`button[aria-haspopup="tree"]`，aria-label 同文案）+ user 气泡末行（`stop. Do not use the bash tool.`）+ `7月6日 23:35` + 展开的 `已完成，用时 1秒` turn process + 展开的 `已协调子智能体` 组 + `思考 · The user wants me to:` + **展开的 `创建子智能体` 工具行**（`调用结果` / `Reply with exactly the word CHILD_OK and nothing else.` / `● 已启动` / `智能体 ID session-ff9414c5-…-child-2`）+ `思考 · The subagent returned "CHILD_OK" as e…` + `PARENT_DONE` + **`子任务状态更新` turn trigger 卡** + 第二个 `已完成，用时 1秒` + `PARENT_DONE` + composer + `2 轮 3 步 · 181000 tok/s` / `6.2K tok · 缓存命中 49%` |
| `screens/official/official-session-subagent-parallel-402x874-dpr3.png` | 1206×2622 | **官方并行子智能体态（fixture 播种）**：标题 `Use the subagent tool TWICE`；**头部 `2 个子智能体`** + user 气泡 + `7月6日 23:35` + 展开的 turn process + `已协调子智能体` 组 + 第一张 `subagent` 行展开（`调用结果` / `Reply with exactly the word ALPHA and nothing else.` / `● 已启动` / `智能体 ID …-child-2`）+ 第二张 `subagent` 行折叠（`创建子智能体 · Reply with exactly the word ALP…`）+ `PARENT_DONE` + composer + `1 轮 2 步` |

环境：

- 官方仓：`deepseek-harness` @ `7be5505b0be06009d74891c869063c9cf19a0df0`（0.2.1-rc.2）
- 视口：CSS 402×874，DPR 3，light，mobile；PNG 1206×2622
- Node `v22.22.1`，Google Chrome `156.0.8078.79`
- 九张图 console error / 未捕获异常 / warning / 网络失败 / HTTP error **全部为 0**（见 `screens/official/reports/*.json`）；问答 / 计划 / 两个子智能体共四张还启用了 `--fail-on-console-error` 硬闸门（`consoleGate: {enabled: true, errorCount: 0, exceptionCount: 0}`）；两个子智能体图另外启用 `--fail-on-network-error`（`networkGate: {enabled: true, failureCount: 0, httpErrorCount: 0}`）
- 九张图全部 `1206×2622`；七张会话图 `drawerClosed: true`（抽屉在截图前已真实关闭）
- 截图不含 iOS 状态栏（09:41/信号/电量），状态栏是 iOS 叠加层
- hero / auth / 原有五张会话图的 SHA-256 与本轮之前**逐字节一致**（`9020fa01…` / `1806a5d7…` / `1d0aabf7…` / `108a9bad…` / `6a9263ff…` / `c9adc5f8…` / `d22a8139…`）：新增两张子智能体状态没有污染既有 golden
- 两张新图 SHA-256：
  - 子智能体 `40d61bcbe9c946f75d9515ed2e7c4602a44444cdad7094e918fa67c7c6455d5a`（256739 bytes）
  - 并行子智能体 `e1ce41be38603eb87f1fd90721e313447b69830e28561e1c5b9a57119e6e6d2d`（304623 bytes）
- **三次完整 harness 运行（各含 5 次 fixture 播种）九张 PNG 全部逐字节一致**；两张新图另外与此前在**另一份临时 DSH_HOME**上做的探针截图也逐字节一致（`40d61bcb…` / `e1ce41be…`）。计划 fixture 的 `createdAt` 固定为 `1788240594856`，两个 subagent fixture 的 `createdAt` 直接来自各自 v4 header（`1783352119267` / `1783352126000`），所以时间戳（`9月1日 13:29/13:30`、`7月6日 23:35`）稳定

### 会话状态（精确交互）

会话截图走的是真实用户路径，不是隐藏 DOM、不是改样式、不是注入假消息：

1. `button[aria-label="关闭提示"]` — 关 PWA 安装横幅
2. `button[aria-label="关闭"]` — 关「开始使用」认证弹窗（必须先关，否则进不了列表）
3. `button[aria-label="菜单"]` — 打开 402px 抽屉
4. `[data-row-key="workspace:"]` — 展开「未分组」（默认折叠）
5. `[data-row-key="overflow:"]` — 仅当目标行在列表折叠区时：展开其余会话
6. `[data-row-key="session:<id>"]` — 打开会话
7. `button[aria-label="关闭面板"]` — 关闭抽屉，让转录铺满 402px
8. 断言：`[data-conversation-session]` = 会话 id；`[data-chat-node-key]` 行数 > 0；抽屉已关闭
9. 滚动转录容器到 `scrollHeight`（跟随 turn tail），再截图（问答卡例外，见下）

本地真实会话与富会话的额外展开（三次真实展开点击，不是改 CSS）：

- 富会话：`button[data-turn-process]` → `[data-chat-group-key] > div > button[aria-expanded]` → `div[data-sample="bash"]`；断言 `assistant-step` 与 `tool-call` 两种行**可见**

问答卡与计划卡的额外步骤（同样全是真实点击/滚动）：

| 状态 | 真实交互 | 断言 |
|---|---|---|
| 问答卡 | `button[data-turn-process]` → `button[data-process-activity="questions"]` → `[data-tool="ask_user_question"] [data-disclosure-row]`；`scrollIntoView({block: "center"})` 把卡片滚进视口 | `[data-chat-node-key] [data-tool="ask_user_question"]` 可见；`body.innerText` 含 `Include accessibility notes`（该文本只存在于展开后的已作答卡片） |
| 计划卡 | 打开会话后不点任何 disclosure（turn process 保持默认折叠） | `[data-chat-node-key] [data-plan-card]` 可见；`body.innerText` 含 `Add \`--greeting\` flag to CLI`；转录 flow kinds 含 `command` + `tool-call` + `turn-tail`（本轮由 `/plan` 命令开启，**没有 user 行**） |
| 子智能体 | `button[data-turn-process]` → `[data-chat-group-key] > div > button[aria-expanded]`（`已协调子智能体` 组）→ `[data-tool="subagent"] [data-disclosure-row]`；随后跟随 turn tail | 会话头 `button[aria-haspopup="tree"]` 可见且文案/aria-label = **`1 个子智能体`**；`[data-chat-node-key] [data-tool="subagent"]` 1/1 可见；`body.innerText` 含 `1 个子智能体`；转录 flow kinds 含 `user` + `assistant-step` + `tool-call`（另有 `turn-process` / `turn-tail` / `turn-trigger`） |
| 并行子智能体 | 同上三次展开，但会话开的是 `subagent-parallel` | 头部文案 = **`2 个子智能体`**；`[data-tool="subagent"]` **2/2 可见**；其余同上 |

会话 id / 标题 / 转录：

| 文件 | session id | 标题 | 转录 |
|---|---|---|---|
| `official-session-chat-402x874-dpr3.png` | `session-ca5b4ecd-da54-488a-b11b-2df2dcae94f2` | `reply with the single word` | 4 行（user / turn-process / turn-error / turn-tail）；1 轮 1 步；`MISSING_CREDENTIAL` 失败卡 |
| `official-session-chat-long-user-turn-402x874-dpr3.png` | `session-d81de3d6-526a-4894-b3aa-1520db906f62` | `You are the evidence-reading and` | 4 行；1 轮 1 步；长 user prompt 滚到 tail；`MISSING_CREDENTIAL` 失败卡 |
| `official-session-chat-tool-402x874-dpr3.png` | `session-4f117741-269b-464e-a2cc-4c121c50531c` | `Use the bash tool to` | **7 行**（user / turn-process / assistant-step / tool-call / turn-tail）；1 轮 2 步；assistant 文本 `DONE`；bash 工具卡展开显示 `echo TERMINAL_OK` → `TERMINAL_OK` |
| `official-session-question-402x874-dpr3.png` | `session-08d252dc-f487-42c1-9b87-68467f70f1e2` | `Use the ask_user_question tool to` | **7 行**（user / turn-process / assistant-step / tool-call / turn-tail）；1 轮 2 步；assistant 文本 `DONE`；`ask_user_question` 行展开为 `1/1 已回答` 卡 |
| `official-session-plan-402x874-dpr3.png` | `session-1b0222d8-77f1-40b2-9ff4-13ee4a69164c` | `Plan a small change: add` | **9 行**（command / steering / turn-process / assistant-step / tool-call / turn-tail）；1 轮 2 步；assistant 文本 `DONE`；turn tail 有计划卡（`data-plan-card`） |
| `official-session-subagent-402x874-dpr3.png` | `session-ff9414c5-36db-4327-955e-84d7fa18547c` | `Use the subagent tool exactly` | **11 行**（user / turn-process / assistant-step / tool-call / turn-tail / turn-trigger）；2 轮 3 步；**头部 `1 个子智能体`**；展开的 `subagent` 行 = `创建子智能体` + `调用结果` + `● 已启动` + `智能体 ID …-child-2`；`PARENT_DONE`；`子任务状态更新` 卡 |
| `official-session-subagent-parallel-402x874-dpr3.png` | `session-d6126d5c-82a0-4de9-9f58-14205fcc27fb` | `Use the subagent tool TWICE` | **6 行**（user / turn-process / tool-call ×2 / assistant-step / turn-tail）；1 轮 2 步；**头部 `2 个子智能体`**；两张 `subagent` 行（1 张展开 + 1 张折叠） |

两张本地会话都显示 `data-signed-out="true"`、composer `请选择模型`；失败卡原文：
`llm-deepseek: no API key for provider route "deepseek-official"; store DEEPSEEK_API_KEY through the credentials service (the web Models page writes it), or export DEEPSEEK_API_KEY in the launching environment`。

## 富会话的 fixture 播种（来源与写法）

fixture：`<official>/snapshots/session/bash-tool-turn/session.v4.jsonl`
SHA-256 `38b8cbd68dae0d5e9d0331e412a73d0101775d073c44dfe7bf7ff6aae56327a5`，24 行。

它是一条官方记录转录：user 指令、runtime-context、`request/header`、`session/title`、带 reasoning + bash `tool/call` 的 assistant message、`job/registered`/`job/settled`、`tool/result`（`TERMINAL_OK`）、第二个 assistant message（文本 `DONE`）、`turn/end completed`。

播种脚本 `scripts/ios-parity/golden/seed-official-session.mjs` 走的是**官方自己的写入口**，不是手写日志：

1. `realizeSeedFixture` 的等价替换：`{{session:1}}` → 目标 session id，`{{cwd}}` → 目标 cwd，`{{message:N}}`/`{{id:N}}` → 与官方 `fixtureIdentity` 相同的 sha256 确定性 UUID；`{{tools}}` 保留给读取器。
2. 官方格式读取器：`prepareSessionSnapshotFixtureForComparison` + `parseSessionLog`（`@deepseek-ai/dsh-llm-replay` 构建产物）→ 迁移到当前 V4 物理格式并做 released-format 校验。
3. 与 `apps/web/tests/scaffold.ts:seedSession` 相同的 materialize：time anchor = header `createdAt`（可由 `--created-at` 固定），逐事件 +1ms，assistant 内嵌 stream 重基到事件时间。
4. `new Context()` + `ctx.plugin(JsonlSessionPersistence, { root: <home>/sessions })` + `handle = await create(meta)` + `handle.append(events)` + `handle.close()`。**header/frame 边界、seq envelope、zstd 编码全部由官方 backend 负责**。
5. 写后自检：`list()` 必须列出该 id（`formatStatus: current`）、`open('read')` 重读必须得到原事件数、必须有 `session/title`/`user/message`/`assistant/message`/`tool/call`/`tool/result`/`turn/end`，且 turn 必须以 `turn/end completed` 结束，否则非零退出。
6. 本轮新增：fixture 中的展示型占位符 `{{timeContextTimestamp}}` / `{{clientTimeZone}}` / `{{elapsed}}` / `{{sourceRoot}}` / `{{webUrl}}` **按官方 `realizeSeedFixture` 的同一口径保持字面量**（它们位于折叠的 context 行，不出现在卡片画面）；未知占位符仍会失败。seed summary 还会记录 `toolCalls`（名称 / 是否有 `tool/result` / result 文本）与 `turnEnd`，供 manifest 生成**由日志推导**的状态标签。

替换与产物（只发生在临时副本）：

- bash 会话：目标 `session-4f117741-269b-464e-a2cc-4c121c50531c`，cwd `…/deepseek-harness`（从原 `session.v3.jsonl.zstd` header 读出，保持原 workspace 分组）；删除副本里的 v3 日志，写入 `session.v4.jsonl.zstd`（2523 bytes，SHA-256 `bb7c420d59c1b2aabe65cf51150a32d409a85ffb3919e22d7b194bbe33631029`），共 23 条事件（seq 0..22）
- 清理目标会话的 projcache 与锁文件
- `{{tools}}` schema 侧车没有被记录：官方读取器按 web e2e 的同一口径省略了 `request/header.tools`；工具行来自录音里的 `tool/call` + `tool/result`，不是伪造 DOM

**失败证据（已保留）**：早期 `seed-session-fixture.mjs` 手写拼接 zstd 帧；会话能出现在侧栏并被打开，但转录 0 行、标题 `未命名`。该脚本已标记为 SUPERSEDED，保留在 `scripts/ios-parity/golden/`，不再被 harness 调用。

## 问答卡 / 计划卡（fixture 播种，来源与状态）

两个官方 web fixture 都经同一个 `seed-official-session.mjs`、同一组官方 reader + `JsonlSessionPersistence` 写入口播种；除 fixture 与时钟锚点外与富会话完全同构。

| 状态 | fixture | fixture SHA-256 | 行数 | 写入事件 | 播种日志 SHA-256 | 日志 bytes | 被替换会话 | 时钟锚点 |
|---|---|---|---|---|---|---|---|---|
| 问答卡（已作答） | `<official>/snapshots/web/question-composer/session.v4.jsonl` | `b63acbe065e1cd582b7ad44ed0e38ae116572fa1a552912d066ad4784e232a0b` | 23 | 22（seq 0..21） | `5263eb065222bb0622fe540c01855c4b455504441bd6737865b06fca17aa3437` | 3304 | `session-08d252dc-f487-42c1-9b87-68467f70f1e2`（cwd 来自 projcache） | `1788240617068`（fixture header，2026-09-01 13:30:17 +08） |
| 计划卡（已批准） | `<official>/snapshots/web/plan-review/session.v4.jsonl` | `531d6d9c6495fc4021d47d7d6d534cb8a5a372207056df31dbb95639b82ac73d` | 29 | 28（seq 0..27） | `f11254190d51c0d2588f62c07125fbea14e7e97a42a77ac60e1de3b625fc47dd` | 4276 | `session-1b0222d8-77f1-40b2-9ff4-13ee4a69164c`（cwd 来自原 header） | `1788240594856`（`--created-at` 固定；见下） |

计划 fixture 的 v4 header `createdAt` 在迁移时被重置为 `0`。官方 web scaffold 在 `createdAt === 0` 时用 `Date.now() - 60_000`，会让时间戳每次运行都变；本 harness 改用**同一 scenario 官方 v2 fixture 记录的 `1788240594856`**（2026-09-01 13:29:54.856 +08）固定时钟，因此转录时间戳稳定为 `9月1日 13:29/13:30`。

### 状态标签与官方 a11y 契约

标签不是从 `.expected.md` 抄来的，而是从**播种后重读的日志**推导（`seed report.toolCalls`）：

| 状态 | 日志证据 | 渲染结果 | 对应官方 `.expected.md`（SHA-256） | 未渲染的 pending 契约（SHA-256） |
|---|---|---|---|---|
| 问答卡 | `ask_user_question` result=true，result 文本 `{"answers":[{"id":"color","selected":["Blue"],"custom":"Include accessibility notes"}]}`；`turn/end completed` | 已作答卡 `提问 · 1/1 已回答`，问题 `Which color do you prefer?`，答案 `Blue` + `Include accessibility notes` | `question-composer/answered-expanded.expected.md`（`759e7d7deef0cd13bfa201f9b709f3c4629f9b62535c2b8bfe2a3c8ab0494a1a`） | `question-composer/ui.expected.md`（`48705e915128823e0f827d6c6b233b132bba29d44a83777ef377d176444743c2`，待回答 composer 面板） |
| 计划卡 | `exit_plan_mode` result=true，result 文本 `Plan approved — plan mode exited; carry out the plan starting with your next step.`；`turn/end completed` | turn tail 计划卡 `Add \`--greeting\` flag to CLI` / `计划 · Markdown` / `打开` | `plan-review/approved.expected.md`（`c95fd99e8b7b9d5fd303b21c30a3a2a69f3bd72a3fa5245fe23c95eadcfd8939`） | `plan-review/review.expected.md`（`e20e38b075254c95ea06bfc3bfcd26355777927df59463a898ab6d513bc1e312`，`Plan review` 待审批接管） |

**为什么 pending 不可达**：`Plan review`（Approve / Request changes）与待回答的 composer 提问面板是**运行时 `user-questions/request` 交互态**，由 live 请求驱动；这两个官方 fixture 是**已提交的会话日志**，里面已经有 `tool/result`（批准 / 回答）。要截 pending 只能截断 fixture 或删掉 result —— 那就是伪造，本轮明确**不做**。因此本轮交付的是可复现的**已作答问答卡**与**已批准计划卡**，并在文件名/状态标签/manifest 中逐字标明。

### 问答卡 / 计划卡断言（失败会非零退出）

- PNG 必须为 **1206×2622**（`cdp-capture.mjs` 自己校验）
- `[data-conversation-session]` 必须等于请求的 session id；抽屉必须已关闭
- 问答卡：`[data-chat-node-key] [data-tool="ask_user_question"]` 至少 1 个**可见**（1/1），且 `body.innerText` 含 `Include accessibility notes`（只有展开后的已作答卡片才会出现）
- 计划卡：`[data-chat-node-key] [data-plan-card]` 至少 1 个**可见**（1/1），且 `body.innerText` 含 `Add \`--greeting\` flag to CLI`；转录 flow kinds 必须含 `command` / `tool-call` / `turn-tail`（`/plan` 命令开启，无 user 行，所以不能沿用“必须有 user 行”的旧断言）
- 问答卡/计划卡两张：`--fail-on-console-error`，console error 或未捕获异常 > 0 直接失败
- 播种阶段：`assert_seed_state` 重新读取 seed report，要求 `ask_user_question` / `exit_plan_mode` / `subagent` 确有 `tool/result` 且 `turn/end completed`；fixture 若变成 pending，harness 会拒绝把它标成 answered/approved/settled
- 子智能体两张的断言见下一节（头部 `button[aria-haspopup="tree"]` 计数 + 可见的 `subagent` 行）

## 子智能体（fixture 播种，来源与状态）

两条录音来自官方仓的 `snapshots/session/`，经同一个 `seed-official-session.mjs`、同一组官方 reader + `JsonlSessionPersistence` 写入口播种（与富会话 / 问答 / 计划完全同构；`createdAt` 直接使用 v4 header，无需额外锚点）。

| 状态 | fixture | fixture SHA-256 | 行数 | 写入事件 | 播种日志 SHA-256 | 日志 bytes | 被替换会话 | cwd | 时钟锚点 |
|---|---|---|---|---|---|---|---|---|---|
| 子智能体（spawn） | `<official>/snapshots/session/subagent-spawn-in-process/session.v4.jsonl` | `28e34c235d2f6bc55360fbd11abb0a2e9a9ab012977b3c0cdfc88e48c1f782bf` | 31 | 30（seq 0..29） | `7260f78ca533a9ef82f63b66cdd484cd2ffee157c939113d4f11584b2ef71e9c` | 2867 | `session-ff9414c5-36db-4327-955e-84d7fa18547c` | `/private/tmp/swarm-cwdtest.YQvc`（projcache） | `1783352119267`（fixture header） |
| 并行子智能体 | `<official>/snapshots/session/subagent-parallel/session.v4.jsonl` | `c4cceb414831cecd3286f9a14573c68a6d1781efd5fa0da8e428c4e3f85334fe` | 31 | 30（seq 0..29） | `e57c860183b196d00839469907f2b225894ac5e3e46d08feab51a8df50161af6` | 2373 | `session-d6126d5c-82a0-4de9-9f58-14205fcc27fb` | `/private/var/…/T/swarm-doctor-mGDtoE`（projcache） | `1783352126000`（fixture header） |

两条日志都带 `tool/result`（`started subagent <childId>`）与 `turn/end completed`，所以工具行是**已结算的已启动态**；播种日志的事件计数、seq 区间、标题与工具调用由 seeder 重读日志后记录，manifest 从 seed report 取值（`assert_seed_state` 会在播种后再次校验 `subagent` 有 result 且 turn completed）。官方 `snapshots/session/` 下这两个 scenario **没有** `.expected.md` a11y 契约（不同于 `snapshots/web/question-composer` / `plan-review`），因此断言全部来自真实渲染的 DOM / report，没有可引用的官方契约文件。

### 头部计数是 projection，不是写死的文案

官方 `packages/subagent/subagent/src/catalog.ts` 的 `subagentCatalog` projection 把父日志里的 `subagent/catalog` 事件折成 `subagentCatalog`，`SubagentHeaderLineage.tsx` 再把条目数渲染成会话头的 `N 个子智能体` 按钮（`aria-haspopup="tree"`）。因此：

- spawn 录音（1 条 catalog）→ 头部 `1 个子智能体`；
- parallel 录音（2 条 catalog）→ 头部 `2 个子智能体`；
- 两张图只差 fixture 与 catalog 事件数，头部计数随之变化——这是“计数来自日志”的证据。

### 从真实 DOM 发现的官方钩子

- 工具行：`div[data-tool="subagent"]`，带 `data-state="ok"`（已启动）与 `data-chat-call-id="call_…"`；展开控件是行内的 `[data-disclosure-row]`。
- 过程组：`[data-chat-group-key]` 组头按钮带 `data-process-activity="subagents"`；turn process 按钮是 `button[data-turn-process]`，并记录 `data-turn-process-subagents="1"`（并行图为 `2`）。
- 会话头计数：`button[aria-haspopup="tree"]`，文案与 `aria-label` 都是 `N 个子智能体`；**这个按钮没有任何 `data-*` 钩子**，所以断言只能用 `aria-haspopup="tree"` + 文案。

### 子智能体断言（失败会非零退出）

- 会话头：`button[aria-haspopup="tree"]` ≥1 个**可见**，且 `body.innerText` 含 `1 个子智能体` / `2 个子智能体`（report 同时记录该按钮的 `text` 与 `aria-label`）
- 工具行：`[data-chat-node-key] [data-tool="subagent"]` ≥1 个**可见**（spawn 1/1、parallel 2/2），`data-state="ok"`，行卡记录 `调用结果` / `已启动` / `智能体 ID`
- 转录：flow kinds 含 `user` + `assistant-step` + `tool-call`（spawn 另有 `turn-trigger`），`tool-call` 必须**可见**
- 抽屉已关闭、`[data-conversation-session]` = 会话 id、PNG 1206×2622
- 两张图都启用 `--fail-on-console-error` 与 `--fail-on-network-error`：console error / 未捕获异常 / 网络加载失败 / HTTP ≥ 400 任一 > 0 直接失败

### 已知边界（子智能体）

- **子会话不存在**：`{{session:2}}` / `{{session:3}}` 被官方 realize 规则展开成 `<sessionId>-child-2` / `-child-3`，副本里没有对应子会话目录；截图证明的是父会话头部计数与父转录工具行（`已启动` 的已结算态），**不是**子会话转录；行内「查看」没有点击（点开也打不开不存在的子会话）。
- **没有打开头部 catalog 下拉树**：截图只证明计数按钮存在且可见；`role="tree"` 的子智能体树面板没有对应像素，也未伪造。
- **计数文案依赖中文界面**：断言是 `1 个子智能体` / `2 个子智能体`；英文界面会变成 `1 subagent` / `2 subagents`。

## 复现

```bash
scripts/ios-parity/golden/capture-official.sh
```

脚本分两个服务阶段（同一个官方 `dsh web`，`--port 0`）：

1. **pristine DSH_HOME** → hero + auth 两张图。hero 必须是“无会话”的空态，所以这一步不加载本地会话。
2. **DSH_HOME 副本** → 七个会话状态。先 `cp -R ~/.dsh <temp>`（源只读）、删掉复制来的 `session.lock`，再用 `seed-official-session.mjs` 依次播种 bash / question / plan / subagent-spawn / subagent-parallel 五个官方 fixture，然后起第二个 `dsh web` 进程；打开 V3 会话的迁移只发生在副本里。
3. 每个状态都由 CDP 设 402×874@3、等 `[data-dsh-boot]` 挂载、执行真实点击、断言状态后截图；问答卡要求展开后的已作答卡可见，计划卡要求 turn tail 的计划卡可见，两个子智能体图要求头部 catalog 计数按钮 + 可见的 `subagent` 行。
4. `write-manifest.mjs` 汇总 9 份 report + 5 份 seed summary → `manifest.json` / `manifest.md`（含 session id/标题/交互/内容断言/转录/fixture provenance/日志与 fixture sha256/console gate）。
5. 校验 PNG 为 1206×2622；失败会非零退出，不把 boot skeleton / 会话列表 / 空 chat / 未展开的隐藏卡片当截图。

环境变量：`DSH_OFFICIAL_REPO`、`DSH_GOLDEN_OUT_DIR`、`NODE_BIN`、`CHROME_BIN`、`DSH_GOLDEN_PORT`、`DSH_GOLDEN_SESSION_HOME`（默认 `~/.dsh`）、`DSH_GOLDEN_SESSION_ID`、`DSH_GOLDEN_SESSION_LONG_ID`、`DSH_GOLDEN_TOOL_SESSION_ID`、`DSH_GOLDEN_TOOL_FIXTURE`、`DSH_GOLDEN_QUESTION_SESSION_ID`、`DSH_GOLDEN_QUESTION_FIXTURE`、`DSH_GOLDEN_QUESTION_EXPECTED`、`DSH_GOLDEN_PLAN_SESSION_ID`、`DSH_GOLDEN_PLAN_FIXTURE`、`DSH_GOLDEN_PLAN_CREATED_AT`、`DSH_GOLDEN_PLAN_EXPECTED`、`DSH_GOLDEN_SUBAGENT_SESSION_ID`、`DSH_GOLDEN_SUBAGENT_FIXTURE`、`DSH_GOLDEN_SUBAGENT_PARALLEL_SESSION_ID`、`DSH_GOLDEN_SUBAGENT_PARALLEL_FIXTURE`、`SKIP_SESSION=1`（只做 hero+auth）、`KEEP_WORK_DIR=1`。

单独复现播种（HOME 必须是副本，脚本拒绝真实 `~/.dsh`）：

```bash
node scripts/ios-parity/golden/seed-official-session.mjs \
  --official-repo /Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness \
  --home /tmp/dsh-golden.XXXX/dsh-home-session \
  --fixture /Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/snapshots/web/plan-review/session.v4.jsonl \
  --session-id session-1b0222d8-77f1-40b2-9ff4-13ee4a69164c \
  --created-at 1788240594856 \
  --out /tmp/seed-plan-session.json
```

没有 Node ≥22 或没有官方 `apps/cli/lib/bin.js` / `apps/web/dist` 时，脚本会给出明确错误。

## 仍需补的官方 golden

问答卡 / 计划卡已覆盖**已结算**（已回答 / 已批准）形态，子智能体已覆盖**头部计数 + 已结算的 subagent 工具行**。仍缺：

- **待回答的 composer 提问面板**（多选选项 + 自定义输入 + Submit；`question-composer/ui.expected.md`）——需要 live pending 请求，没有已提交日志
- **待审批的 `Plan review` 接管面板**（Approve / Request changes；`plan-review/review.expected.md`）——同上
- **头部 catalog 下拉树**（点击 `N 个子智能体` 后的 `role="tree"` 子智能体面板）——可以真实打开，但本轮按“一张图只证明一种状态”的范围没有打开
- **子会话转录**（从 subagent 行「查看」或 catalog 树打开 `<sessionId>-child-n`）——需要真实子会话日志，副本里没有
- **运行中的 subagent**（`running` 态、`data-state` 非 `ok`、实时流式行）——需要 live 运行
- **计划预览侧栏**（点击计划卡 `打开` 后的 `PlanPreview`，含完整 Markdown 渲染）
- 真实登录态 / API Key → 由本机模型**实时**产生 assistant 内容（本轮全是记录 fixture，不是 live run）
- 更丰富的 assistant markdown（多级标题/列表/代码块/表格/链接）
- 多工具 ×3 与折叠/展开组合（read/search/file-mutation 等）
- 其他 turn trigger（schedule / job / 审批）；子智能体的 `子任务状态更新` 卡已在 spawn 图里覆盖
- 深色

补齐后按同一 harness 增加状态（新 fixture 用 `seed-official-session.mjs` 播种；本地失败会话用现有两个状态）。

在此之前，像素结论只到 **官方 hero + 认证闸门 + 已打开会话的页头/user 气泡/时间戳/turn-error/turn-tail/composer +（fixture 播种的）assistant 文本/turn process/工具组/bash 工具卡 + 已作答问答卡 + 已批准计划卡 + 会话头 catalog 计数 + 已结算的 subagent 工具行**；仍不能宣称聊天流逐像素一致，也**不能**把 pending 问答面板 / pending 计划审批面板 / 子会话转录 / catalog 下拉树算作已覆盖。
