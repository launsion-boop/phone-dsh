# 官方 DSH Web UI 截图清单

生成时间：`2026-11-01T06:56:12Z`

## 来源

- 官方仓：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`
- commit：`7be5505b0be06009d74891c869063c9cf19a0df0`（读取 `.git/HEAD` 校验）
- 版本：`0.2.1-rc.2`
- 启动命令：`node apps/cli/lib/bin.js --profile web --no-open --host 127.0.0.1 --port 0 (cwd: /Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness, DSH_HOME=<temp pristine>)`
- 实际地址（hero/auth）：`http://127.0.0.1:56230/?token=<redacted>`（token 已脱敏；每次启动由 `dsh web` 打印）
- 实际地址（会话）：`http://127.0.0.1:56316/?token=<redacted>`（独立进程 + 独立 DSH_HOME 副本）
- 运行环境：Node `v22.22.1`，`Google Chrome 156.0.8078.79`

## 视口合同

- CSS 视口 **402×874**，DPR **3**，light，mobile 模拟
- 输出 PNG **1206×2622**（CSS px × DPR）

## 截图

| 文件 | 尺寸 | 状态 | SHA-256 |
|---|---|---|---|
| `official-hero-sessionless-402x874-dpr3.png` | 1206×2622 | 官方 Web UI 会话空态（hero）：未登录、未配置模型、无会话；已按用户操作关闭 PWA 安装提示、预览版说明、开始使用弹窗 | `9020fa013ff662a9…` |
| `official-auth-gate-402x874-dpr3.png` | 1206×2622 | 官方 Web UI 首次使用认证闸门：开始使用弹窗（登录 DeepSeek 账号 / 添加 API Key） | `1806a5d7c3d838db…` |
| `official-session-chat-402x874-dpr3.png` | 1206×2622 | 官方 Web UI 已打开的记录会话（真实 chat）：短 user 气泡 + 时间戳 + 本轮运行失败（MISSING_CREDENTIAL）+ composer；抽屉、分组、会话行均为真实点击 | `1d0aabf77e7b8d99…` |
| `official-session-chat-long-user-turn-402x874-dpr3.png` | 1206×2622 | 官方 Web UI 已打开的长 prompt 会话（滚动到 turn tail）：长文本/代码块 user 气泡 + 时间戳 + 本轮运行失败 + composer | `108a9bad03153cf7…` |
| `official-session-chat-tool-402x874-dpr3.png` | 1206×2622 | 官方 Web UI 富会话（官方记录 fixture 经 JsonlSessionPersistence 播种）：assistant 文本 `DONE` + 展开的 turn process / 工具组 / bash 工具卡（cwd + `echo TERMINAL_OK` + 输出 `TERMINAL_OK`）+ composer；所有展开均为真实点击 | `6a9263ff685a2d8d…` |
| `official-session-question-402x874-dpr3.png` | 1206×2622 | 官方问答卡（fixture 已作答态）：展开 turn process → 提问组 → 提问行后，`提问 · 1/1 已回答` 卡显示问题 `Which color do you prefer?` 与录音答案 `Blue` + 自定义回答 `Include accessibility notes`；**不是**待回答的 composer 提问面板（日志里没有未结算的 ask_user_question） | `c9adc5f8255d1cf6…` |
| `official-session-plan-402x874-dpr3.png` | 1206×2622 | 官方计划卡（fixture 已批准态）：turn tail 中的计划卡 `Add `--greeting` flag to CLI` / `计划 · Markdown` / `打开`（`data-plan-card`），turn process 保持默认折叠；**不是**待审批的 `Plan review`（Approve / Request changes）接管面板 | `d22a81394d2c414c…` |
| `official-session-subagent-402x874-dpr3.png` | 1206×2622 | 官方子智能体态（fixture 经 JsonlSessionPersistence 播种）：会话头把日志里的 `subagent/catalog` 投影成 **`1 个子智能体`** 计数按钮（`button[aria-haspopup="tree"]`，aria-label 同为 `1 个子智能体`）；展开 turn process → `已协调子智能体` 过程组 → `subagent` 工具行后，行卡显示 `创建子智能体` / `调用结果` / prompt 文本 / `● 已启动` / `智能体 ID`（`<sessionId>-child-2`）；另有 `思考` 推理行、`PARENT_DONE`、`子任务状态更新` turn trigger 卡、composer；所有展开均为真实点击 | `40d61bcbe9c946f7…` |
| `official-session-subagent-parallel-402x874-dpr3.png` | 1206×2622 | 官方并行子智能体态（同一 fixture 家族的 `subagent-parallel` 录音）：日志里有两条 `subagent/catalog`，同一会话头因此渲染 **`2 个子智能体`**；同一个 `已协调子智能体` 过程组里有两张 `subagent` 工具行（第一张展开显示 `智能体 ID …-child-2`，第二张保持折叠摘要），另有 `PARENT_DONE` 与 composer。与 `session-subagent-spawn` 只差 catalog 事件，用来证明头部计数是从日志派生的、不是写死的标签 | `e1ce41be38603eb8…` |

## 会话 fixture（只读源 → 临时副本）

- 源：`/Users/leilangsheng/.dsh`（**只读**；打开 V3 会话会原地迁移，所以服务端不指向真实目录）
- 短会话：`session-ca5b4ecd-da54-488a-b11b-2df2dcae94f2`
- 长 prompt 会话：`session-d81de3d6-526a-4894-b3aa-1520db906f62`
- 富会话（被 bash fixture 替换）：`session-4f117741-269b-464e-a2cc-4c121c50531c`
- 问答卡会话（被 question fixture 替换）：`session-08d252dc-f487-42c1-9b87-68467f70f1e2`
- 计划卡会话（被 plan fixture 替换）：`session-1b0222d8-77f1-40b2-9ff4-13ee4a69164c`
- 子智能体会话（被 subagent-spawn-in-process fixture 替换）：`session-ff9414c5-36db-4327-955e-84d7fa18547c`
- 并行子智能体会话（被 subagent-parallel fixture 替换）：`session-d6126d5c-82a0-4de9-9f58-14205fcc27fb`
- 处理：copied into a separate temporary DSH_HOME and served by its own dsh web process; the source is only read (opening a V3 session migrates it in place, so no server ever runs against the real home)
- 会话里的 user 文本来自本地历史记录；截图与 body text 取证都只用于本次 402pt 审计。

### 播种的官方记录 fixture：`bash-tool-turn`

- fixture：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/snapshots/session/bash-tool-turn/session.v4.jsonl`
- fixture SHA-256：`38b8cbd68dae0d5e9d0331e412a73d0101775d073c44dfe7bf7ff6aae56327a5`（24 行）
- 播种器：`scripts/ios-parity/golden/seed-official-session.mjs`
- 写入方式：official @deepseek-ai/dsh-session-persistence-jsonl: new Context + plugin({root}) + create(meta) + append(events) + close()
- 替换的会话：`session-4f117741-269b-464e-a2cc-4c121c50531c`，cwd `/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`（来源：header:session.v3.jsonl.zstd）
- 副本里被删除的旧日志：`session.v3.jsonl.zstd`
- 写入后的标题：`Use the bash tool to`；assistant 文本：`DONE`
- 事件：23 条（seq 0..22），类型：`permission/preset`×1、`sandbox/mode`×1、`approval/policy`×1、`agent/inbox/spliced`×2、`turn/start`×1、`step/start`×2、`system/message`×1、`user/message`×2、`request/header`×1、`request/context`×1、`session/title`×1、`assistant/message`×2、`tool/call`×1、`job/registered`×1、`job/settled`×1、`tool/result`×1、`step/end`×2、`turn/end`×1
- 生成的日志：`session.v4.jsonl.zstd`，SHA-256 `bb7c420d59c1b2aabe65cf51150a32d409a85ffb3919e22d7b194bbe33631029`（2523 bytes，list status `current`）
- 会话头：`{"version":4,"id":"session-4f117741-269b-464e-a2cc-4c121c50531c","createdAt":1783352050748,"isSeeded":false,"cwd":"/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness","delegationDepth":0}`（createdAt 来源：fixture-header）
- 工具调用：`bash` result=true；turn end：`turn/end` / `completed`

> 该 fixture 是官方仓自带的记录，经官方格式读取器迁移后用官方 `JsonlSessionPersistence` 写入；`{{tools}}` schema 侧车未被记录，按官方 web e2e 的同一口径省略。

### 播种的官方记录 fixture：`question-composer-answered`

- fixture：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/snapshots/web/question-composer/session.v4.jsonl`
- fixture SHA-256：`b63acbe065e1cd582b7ad44ed0e38ae116572fa1a552912d066ad4784e232a0b`（23 行）
- 播种器：`scripts/ios-parity/golden/seed-official-session.mjs`
- 写入方式：official @deepseek-ai/dsh-session-persistence-jsonl: new Context + plugin({root}) + create(meta) + append(events) + close()
- 替换的会话：`session-08d252dc-f487-42c1-9b87-68467f70f1e2`，cwd `/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`（来源：projcache）
- 副本里被删除的旧日志：`session.v3.jsonl.zstd`
- 写入后的标题：`Use the ask_user_question tool to`；assistant 文本：`DONE`
- 事件：22 条（seq 0..21），类型：`permission/preset`×1、`sandbox/mode`×1、`approval/policy`×1、`agent/inbox/spliced`×2、`turn/start`×1、`step/start`×2、`system/message`×1、`user/message`×3、`request/header`×1、`request/context`×1、`session/title`×1、`assistant/message`×2、`tool/call`×1、`tool/result`×1、`step/end`×2、`turn/end`×1
- 生成的日志：`session.v4.jsonl.zstd`，SHA-256 `5263eb065222bb0622fe540c01855c4b455504441bd6737865b06fca17aa3437`（3304 bytes，list status `current`）
- 会话头：`{"version":4,"id":"session-08d252dc-f487-42c1-9b87-68467f70f1e2","createdAt":1788240617068,"isSeeded":false,"cwd":"/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness","delegationDepth":0}`（createdAt 来源：fixture-header）
- 工具调用：`ask_user_question` result=true；turn end：`turn/end` / `completed`
- 已渲染状态的官方 a11y 契约：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/snapshots/web/question-composer/answered-expanded.expected.md`（SHA-256 `759e7d7deef0cd13bfa201f9b709f3c4629f9b62535c2b8bfe2a3c8ab0494a1a`）
- **未渲染**的 pending 契约：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/snapshots/web/question-composer/ui.expected.md`（SHA-256 `48705e915128823e0f827d6c6b233b132bba29d44a83777ef377d176444743c2`）；fixture 日志带 `tool/result`，没有 pending 请求，故未伪造
- 保留字面量的展示占位符：`{{clientTimeZone}}`、`{{sourceRoot}}`、`{{webUrl}}`、`{{timeContextTimestamp}}`、`{{elapsed}}`（官方 `realizeSeedFixture` 同样不替换；位于折叠的 context 行）

> 该 fixture 是官方仓自带的记录，经官方格式读取器迁移后用官方 `JsonlSessionPersistence` 写入；`{{tools}}` schema 侧车未被记录，按官方 web e2e 的同一口径省略。

### 播种的官方记录 fixture：`plan-review-approved`

- fixture：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/snapshots/web/plan-review/session.v4.jsonl`
- fixture SHA-256：`531d6d9c6495fc4021d47d7d6d534cb8a5a372207056df31dbb95639b82ac73d`（29 行）
- 播种器：`scripts/ios-parity/golden/seed-official-session.mjs`
- 写入方式：official @deepseek-ai/dsh-session-persistence-jsonl: new Context + plugin({root}) + create(meta) + append(events) + close()
- 替换的会话：`session-1b0222d8-77f1-40b2-9ff4-13ee4a69164c`，cwd `/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`（来源：header:session.v3.jsonl.zstd）
- 副本里被删除的旧日志：`session.v3.jsonl.zstd`
- 写入后的标题：`Plan a small change: add`；assistant 文本：`Since the user has explicitly asked me not to read or write any files and to go straight to planning, I'll proceed with `exit_plan_mode`.`、`DONE`
- 事件：28 条（seq 0..27），类型：`permission/preset`×1、`sandbox/mode`×1、`approval/policy`×1、`command/run`×1、`plan/mode`×2、`agent/inbox/spliced`×2、`turn/start`×1、`command/done`×1、`step/start`×2、`system/message`×2、`user/message`×3、`request/header`×2、`request/context`×1、`session/title`×1、`assistant/message`×2、`tool/call`×1、`tool/result`×1、`step/end`×2、`turn/end`×1
- 生成的日志：`session.v4.jsonl.zstd`，SHA-256 `f11254190d51c0d2588f62c07125fbea14e7e97a42a77ac60e1de3b625fc47dd`（4276 bytes，list status `current`）
- 会话头：`{"version":4,"id":"session-1b0222d8-77f1-40b2-9ff4-13ee4a69164c","createdAt":1788240594856,"isSeeded":false,"cwd":"/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness","delegationDepth":0}`（createdAt 来源：argument）
- 工具调用：`exit_plan_mode` result=true；turn end：`turn/end` / `completed`
- 已渲染状态的官方 a11y 契约：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/snapshots/web/plan-review/approved.expected.md`（SHA-256 `c95fd99e8b7b9d5fd303b21c30a3a2a69f3bd72a3fa5245fe23c95eadcfd8939`）
- **未渲染**的 pending 契约：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/snapshots/web/plan-review/review.expected.md`（SHA-256 `e20e38b075254c95ea06bfc3bfcd26355777927df59463a898ab6d513bc1e312`）；fixture 日志带 `tool/result`，没有 pending 请求，故未伪造
- 保留字面量的展示占位符：`{{sourceRoot}}`、`{{webUrl}}`、`{{timeContextTimestamp}}`、`{{clientTimeZone}}`、`{{elapsed}}`（官方 `realizeSeedFixture` 同样不替换；位于折叠的 context 行）

> 该 fixture 是官方仓自带的记录，经官方格式读取器迁移后用官方 `JsonlSessionPersistence` 写入；`{{tools}}` schema 侧车未被记录，按官方 web e2e 的同一口径省略。

### 播种的官方记录 fixture：`subagent-spawn-in-process`

- fixture：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/snapshots/session/subagent-spawn-in-process/session.v4.jsonl`
- fixture SHA-256：`28e34c235d2f6bc55360fbd11abb0a2e9a9ab012977b3c0cdfc88e48c1f782bf`（31 行）
- 播种器：`scripts/ios-parity/golden/seed-official-session.mjs`
- 写入方式：official @deepseek-ai/dsh-session-persistence-jsonl: new Context + plugin({root}) + create(meta) + append(events) + close()
- 替换的会话：`session-ff9414c5-36db-4327-955e-84d7fa18547c`，cwd `/private/tmp/swarm-cwdtest.YQvc`（来源：projcache）
- 副本里被删除的旧日志：`session.v4.jsonl.zstd`
- 写入后的标题：`Use the subagent tool exactly`；assistant 文本：`PARENT_DONE`、`PARENT_DONE`
- 事件：30 条（seq 0..29），类型：`permission/preset`×1、`sandbox/mode`×1、`approval/policy`×1、`agent/inbox/spliced`×4、`turn/start`×2、`step/start`×3、`system/message`×1、`user/message`×3、`request/header`×1、`request/context`×1、`session/title`×1、`assistant/message`×3、`tool/call`×1、`subagent/catalog`×1、`tool/result`×1、`step/end`×3、`turn/end`×2
- 生成的日志：`session.v4.jsonl.zstd`，SHA-256 `7260f78ca533a9ef82f63b66cdd484cd2ffee157c939113d4f11584b2ef71e9c`（2867 bytes，list status `current`）
- 会话头：`{"version":4,"id":"session-ff9414c5-36db-4327-955e-84d7fa18547c","createdAt":1783352119267,"isSeeded":false,"cwd":"/private/tmp/swarm-cwdtest.YQvc","delegationDepth":0}`（createdAt 来源：fixture-header）
- 工具调用：`subagent` result=true；turn end：`turn/end` / `completed`

> 该 fixture 是官方仓自带的记录，经官方格式读取器迁移后用官方 `JsonlSessionPersistence` 写入；`{{tools}}` schema 侧车未被记录，按官方 web e2e 的同一口径省略。

### 播种的官方记录 fixture：`subagent-parallel`

- fixture：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/snapshots/session/subagent-parallel/session.v4.jsonl`
- fixture SHA-256：`c4cceb414831cecd3286f9a14573c68a6d1781efd5fa0da8e428c4e3f85334fe`（31 行）
- 播种器：`scripts/ios-parity/golden/seed-official-session.mjs`
- 写入方式：official @deepseek-ai/dsh-session-persistence-jsonl: new Context + plugin({root}) + create(meta) + append(events) + close()
- 替换的会话：`session-d6126d5c-82a0-4de9-9f58-14205fcc27fb`，cwd `/private/var/folders/c3/3ztcq8l52sbfmgpjxc3398bh0000gn/T/swarm-doctor-mGDtoE`（来源：projcache）
- 副本里被删除的旧日志：`session.v4.jsonl.zstd`
- 写入后的标题：`Use the subagent tool TWICE`；assistant 文本：`PARENT_DONE`
- 事件：30 条（seq 0..29），类型：`permission/preset`×1、`sandbox/mode`×1、`approval/policy`×1、`agent/inbox/spliced`×5、`turn/start`×1、`step/start`×2、`system/message`×1、`user/message`×4、`request/header`×1、`request/context`×1、`session/title`×1、`assistant/message`×2、`tool/call`×2、`subagent/catalog`×2、`tool/result`×2、`step/end`×2、`turn/end`×1
- 生成的日志：`session.v4.jsonl.zstd`，SHA-256 `e57c860183b196d00839469907f2b225894ac5e3e46d08feab51a8df50161af6`（2373 bytes，list status `current`）
- 会话头：`{"version":4,"id":"session-d6126d5c-82a0-4de9-9f58-14205fcc27fb","createdAt":1783352126000,"isSeeded":false,"cwd":"/private/var/folders/c3/3ztcq8l52sbfmgpjxc3398bh0000gn/T/swarm-doctor-mGDtoE","delegationDepth":0}`（createdAt 来源：fixture-header）
- 工具调用：`subagent` result=true、`subagent` result=true；turn end：`turn/end` / `completed`

> 该 fixture 是官方仓自带的记录，经官方格式读取器迁移后用官方 `JsonlSessionPersistence` 写入；`{{tools}}` schema 侧车未被记录，按官方 web e2e 的同一口径省略。

### `official-hero-sessionless-402x874-dpr3.png`

- 状态：官方 Web UI 会话空态（hero）：未登录、未配置模型、无会话；已按用户操作关闭 PWA 安装提示、预览版说明、开始使用弹窗
- 最终 URL：`http://127.0.0.1:56230/?token=<redacted>`
- 运行时视口：`402×874@3`
- 交互：**pwa-install-banner-close** → `关闭提示`；**preview-notice-continue** → `继续`；**get-started-dialog-close** → `关闭`
- Console error：0，未捕获异常：0，warning：0；网络失败：0，HTTP error：0
- 报告：`reports/official-hero-sessionless-402x874-dpr3.json`

### `official-auth-gate-402x874-dpr3.png`

- 状态：官方 Web UI 首次使用认证闸门：开始使用弹窗（登录 DeepSeek 账号 / 添加 API Key）
- 最终 URL：`http://127.0.0.1:56230/?token=<redacted>`
- 运行时视口：`402×874@3`
- 交互：**explicit** → `关闭提示`；**explicit** → 未命中
- 断言文本：`开始使用` → 命中
- Console error：0，未捕获异常：0，warning：0；网络失败：0，HTTP error：0
- 报告：`reports/official-auth-gate-402x874-dpr3.json`

### `official-session-chat-402x874-dpr3.png`

- 状态：官方 Web UI 已打开的记录会话（真实 chat）：短 user 气泡 + 时间戳 + 本轮运行失败（MISSING_CREDENTIAL）+ composer；抽屉、分组、会话行均为真实点击
- 最终 URL：`http://127.0.0.1:56316/?token=<redacted>`
- 运行时视口：`402×874@3`
- 交互：**pwa-install-banner-close** → `关闭提示`；**get-started-dialog-close** → `关闭`
- 会话：`session-ca5b4ecd-da54-488a-b11b-2df2dcae94f2`，标题 `reply with the single word`
- 打开路径：**open-drawer** → `button[aria-label="菜单"]`；**expand-group** → `[data-row-key="workspace:"]`；**open-session** → `[data-row-key="session:session-ca5b4ecd-da54-488a-b11b-2df2dcae94f2"]`；**close-drawer** → `button[aria-label="关闭面板"]`
- 抽屉已关闭：是；跟随 turn tail：是
- 转录断言：4 行（flow kinds：user / turn-process / turn-error / turn-tail；可见：user / turn-process / turn-error；turns：1）
- Console error：0，未捕获异常：0，warning：0；网络失败：0，HTTP error：0
- 报告：`reports/official-session-chat-402x874-dpr3.json`

### `official-session-chat-long-user-turn-402x874-dpr3.png`

- 状态：官方 Web UI 已打开的长 prompt 会话（滚动到 turn tail）：长文本/代码块 user 气泡 + 时间戳 + 本轮运行失败 + composer
- 最终 URL：`http://127.0.0.1:56316/?token=<redacted>`
- 运行时视口：`402×874@3`
- 交互：**pwa-install-banner-close** → `关闭提示`；**get-started-dialog-close** → `关闭`
- 会话：`session-d81de3d6-526a-4894-b3aa-1520db906f62`，标题 `You are the evidence-reading and`
- 打开路径：**open-drawer** → `button[aria-label="菜单"]`；**expand-group** → `[data-row-key="workspace:"]`；**open-session** → `[data-row-key="session:session-d81de3d6-526a-4894-b3aa-1520db906f62"]`；**close-drawer** → `button[aria-label="关闭面板"]`
- 抽屉已关闭：是；跟随 turn tail：是
- 转录断言：4 行（flow kinds：user / turn-process / turn-error / turn-tail；可见：user / turn-process / turn-error；turns：1）
- Console error：0，未捕获异常：0，warning：0；网络失败：0，HTTP error：0
- 报告：`reports/official-session-chat-long-user-turn-402x874-dpr3.json`

### `official-session-chat-tool-402x874-dpr3.png`

- 状态：官方 Web UI 富会话（官方记录 fixture 经 JsonlSessionPersistence 播种）：assistant 文本 `DONE` + 展开的 turn process / 工具组 / bash 工具卡（cwd + `echo TERMINAL_OK` + 输出 `TERMINAL_OK`）+ composer；所有展开均为真实点击
- 最终 URL：`http://127.0.0.1:56316/?token=<redacted>`
- 运行时视口：`402×874@3`
- 交互：**pwa-install-banner-close** → `关闭提示`；**get-started-dialog-close** → `关闭`
- 会话：`session-4f117741-269b-464e-a2cc-4c121c50531c`，标题 `Use the bash tool to`
- 打开路径：**open-drawer** → `button[aria-label="菜单"]`；**expand-group** → `[data-row-key="workspace:"]`；**expand-overflow** → `[data-row-key="overflow:"]`；**open-session** → `[data-row-key="session:session-4f117741-269b-464e-a2cc-4c121c50531c"]`；**close-drawer** → `button[aria-label="关闭面板"]`；**expand-transcript** → `button[data-turn-process]`；**expand-transcript** → `[data-chat-group-key] > div > button[aria-expanded]`；**expand-transcript** → `div[data-sample="bash"]`
- 抽屉已关闭：是；跟随 turn tail：是
- 转录断言：7 行（flow kinds：user / turn-process / assistant-step / tool-call / turn-tail；可见：user / turn-process / assistant-step / tool-call / turn-tail；turns：1）
- Console error：0，未捕获异常：0，warning：0；网络失败：0，HTTP error：0
- 报告：`reports/official-session-chat-tool-402x874-dpr3.json`

### `official-session-question-402x874-dpr3.png`

- 状态：官方问答卡（fixture 已作答态）：展开 turn process → 提问组 → 提问行后，`提问 · 1/1 已回答` 卡显示问题 `Which color do you prefer?` 与录音答案 `Blue` + 自定义回答 `Include accessibility notes`；**不是**待回答的 composer 提问面板（日志里没有未结算的 ask_user_question）
- 最终 URL：`http://127.0.0.1:56316/?token=<redacted>`
- 运行时视口：`402×874@3`
- 交互：**pwa-install-banner-close** → `关闭提示`；**get-started-dialog-close** → `关闭`
- 断言文本：`Include accessibility notes` → 命中
- 会话：`session-08d252dc-f487-42c1-9b87-68467f70f1e2`，标题 `Use the ask_user_question tool to`
- 打开路径：**open-drawer** → `button[aria-label="菜单"]`；**expand-group** → `[data-row-key="workspace:"]`；**open-session** → `[data-row-key="session:session-08d252dc-f487-42c1-9b87-68467f70f1e2"]`；**close-drawer** → `button[aria-label="关闭面板"]`；**expand-transcript** → `button[data-turn-process]`；**expand-transcript** → `button[data-process-activity="questions"]`；**expand-transcript** → `[data-tool="ask_user_question"] [data-disclosure-row]`
- 抽屉已关闭：是；跟随 turn tail：否；滚动定位：`[data-tool="ask_user_question"]`（scrollTop 175）
- 转录断言：7 行（flow kinds：user / turn-process / assistant-step / tool-call / turn-tail；可见：user / turn-process / assistant-step / tool-call / turn-tail；turns：1）
- 内容断言：`[data-chat-node-key] [data-tool="ask_user_question"]` 1/1 可见 → "提问\n1/1 已回答\nWhich color do you prefer?\nBlue\nInclude accessibility notes\n查看"
- Console error：0，未捕获异常：0，warning：0（console gate 已启用并通过）；网络失败：0，HTTP error：0
- 报告：`reports/official-session-question-402x874-dpr3.json`

### `official-session-plan-402x874-dpr3.png`

- 状态：官方计划卡（fixture 已批准态）：turn tail 中的计划卡 `Add `--greeting` flag to CLI` / `计划 · Markdown` / `打开`（`data-plan-card`），turn process 保持默认折叠；**不是**待审批的 `Plan review`（Approve / Request changes）接管面板
- 最终 URL：`http://127.0.0.1:56316/?token=<redacted>`
- 运行时视口：`402×874@3`
- 交互：**pwa-install-banner-close** → `关闭提示`；**get-started-dialog-close** → `关闭`
- 断言文本：`Add `--greeting` flag to CLI` → 命中
- 会话：`session-1b0222d8-77f1-40b2-9ff4-13ee4a69164c`，标题 `Plan a small change: add`
- 打开路径：**open-drawer** → `button[aria-label="菜单"]`；**expand-group** → `[data-row-key="workspace:"]`；**open-session** → `[data-row-key="session:session-1b0222d8-77f1-40b2-9ff4-13ee4a69164c"]`；**close-drawer** → `button[aria-label="关闭面板"]`
- 抽屉已关闭：是；跟随 turn tail：是
- 转录断言：9 行（flow kinds：command / steering / turn-process / assistant-step / tool-call / turn-tail；可见：command / steering / turn-process / assistant-step / turn-tail；turns：1）
- 内容断言：`[data-chat-node-key] [data-plan-card]` 1/1 可见 → "Add `--greeting` flag to CLI\n计划 · Markdown\n打开"
- Console error：0，未捕获异常：0，warning：0（console gate 已启用并通过）；网络失败：0，HTTP error：0
- 报告：`reports/official-session-plan-402x874-dpr3.json`

### `official-session-subagent-402x874-dpr3.png`

- 状态：官方子智能体态（fixture 经 JsonlSessionPersistence 播种）：会话头把日志里的 `subagent/catalog` 投影成 **`1 个子智能体`** 计数按钮（`button[aria-haspopup="tree"]`，aria-label 同为 `1 个子智能体`）；展开 turn process → `已协调子智能体` 过程组 → `subagent` 工具行后，行卡显示 `创建子智能体` / `调用结果` / prompt 文本 / `● 已启动` / `智能体 ID`（`<sessionId>-child-2`）；另有 `思考` 推理行、`PARENT_DONE`、`子任务状态更新` turn trigger 卡、composer；所有展开均为真实点击
- 最终 URL：`http://127.0.0.1:56316/?token=<redacted>`
- 运行时视口：`402×874@3`
- 交互：**pwa-install-banner-close** → `关闭提示`；**get-started-dialog-close** → `关闭`
- 断言文本：`1 个子智能体` → 命中
- 会话：`session-ff9414c5-36db-4327-955e-84d7fa18547c`，标题 `Use the subagent tool exactly`
- 打开路径：**open-drawer** → `button[aria-label="菜单"]`；**expand-group** → `[data-row-key="workspace:"]`；**expand-overflow** → `[data-row-key="overflow:"]`；**open-session** → `[data-row-key="session:session-ff9414c5-36db-4327-955e-84d7fa18547c"]`；**close-drawer** → `button[aria-label="关闭面板"]`；**expand-transcript** → `button[data-turn-process]`；**expand-transcript** → `[data-chat-group-key] > div > button[aria-expanded]`；**expand-transcript** → `[data-tool="subagent"] [data-disclosure-row]`
- 抽屉已关闭：是；跟随 turn tail：是
- 转录断言：11 行（flow kinds：user / turn-process / assistant-step / tool-call / turn-tail / turn-trigger；可见：user / turn-process / assistant-step / tool-call / turn-tail / turn-trigger；turns：1, 2）
- 内容断言：`[data-chat-node-key] [data-tool="subagent"]` 1/1 可见 → "创建子智能体\nReply with exactly the word CHILD_OK and nothing else.\n调用结果\nReply with exactly the word CHILD_OK and nothing else.\n已启动\n智能体 ID\nsession-ff9414c5-36db-4327-"；`button[aria-haspopup="tree"]` 1/1 可见 → "1 个子智能体"
- Console error：0，未捕获异常：0，warning：0（console gate 已启用并通过）；网络失败：0，HTTP error：0（network gate 已启用并通过）
- 报告：`reports/official-session-subagent-402x874-dpr3.json`

### `official-session-subagent-parallel-402x874-dpr3.png`

- 状态：官方并行子智能体态（同一 fixture 家族的 `subagent-parallel` 录音）：日志里有两条 `subagent/catalog`，同一会话头因此渲染 **`2 个子智能体`**；同一个 `已协调子智能体` 过程组里有两张 `subagent` 工具行（第一张展开显示 `智能体 ID …-child-2`，第二张保持折叠摘要），另有 `PARENT_DONE` 与 composer。与 `session-subagent-spawn` 只差 catalog 事件，用来证明头部计数是从日志派生的、不是写死的标签
- 最终 URL：`http://127.0.0.1:56316/?token=<redacted>`
- 运行时视口：`402×874@3`
- 交互：**pwa-install-banner-close** → `关闭提示`；**get-started-dialog-close** → `关闭`
- 断言文本：`2 个子智能体` → 命中
- 会话：`session-d6126d5c-82a0-4de9-9f58-14205fcc27fb`，标题 `Use the subagent tool TWICE`
- 打开路径：**open-drawer** → `button[aria-label="菜单"]`；**expand-group** → `[data-row-key="workspace:"]`；**expand-overflow** → `[data-row-key="overflow:"]`；**open-session** → `[data-row-key="session:session-d6126d5c-82a0-4de9-9f58-14205fcc27fb"]`；**close-drawer** → `button[aria-label="关闭面板"]`；**expand-transcript** → `button[data-turn-process]`；**expand-transcript** → `[data-chat-group-key] > div > button[aria-expanded]`；**expand-transcript** → `[data-tool="subagent"] [data-disclosure-row]`
- 抽屉已关闭：是；跟随 turn tail：是
- 转录断言：6 行（flow kinds：user / turn-process / tool-call / assistant-step / turn-tail；可见：user / turn-process / tool-call / assistant-step / turn-tail；turns：1）
- 内容断言：`[data-chat-node-key] [data-tool="subagent"]` 2/2 可见 → "创建子智能体\nReply with exactly the word ALPHA and nothing else.\n调用结果\nReply with exactly the word ALPHA and nothing else.\n已启动\n智能体 ID\nsession-d6126d5c-82a0-4de9-9f58-1"；`button[aria-haspopup="tree"]` 1/1 可见 → "2 个子智能体"
- Console error：0，未捕获异常：0，warning：0（console gate 已启用并通过）；网络失败：0，HTTP error：0（network gate 已启用并通过）
- 报告：`reports/official-session-subagent-parallel-402x874-dpr3.json`

## 已知限制

- 会话截图来自**真实本地 DSH_HOME 的副本**（源目录只读，临时副本在截图后删除）：打开 V3 会话会在原地迁移成 V4，所以服务端从不指向真实 ~/.dsh。
- `session-chat-tool` 的 assistant 文本 / 工具卡**不是本机实时模型运行**产生的：它来自官方仓记录 fixture `snapshots/session/bash-tool-turn/session.v4.jsonl`，由 `seed-official-session.mjs` 通过官方格式读取器（`prepareSessionSnapshotFixtureForComparison` + `parseSessionLog`）和官方 `JsonlSessionPersistence.create/append/close` 写入副本；副本里被替换的是一个单轮 `MISSING_CREDENTIAL` 失败会话。
- 该 fixture 的 `{{tools}}` 工具 schema 侧车没有被记录，官方读取器按 web e2e 的同一口径省略了 `request/header` 的 `tools`；工具行本身来自录音里的 `tool/call` + `tool/result` 事件，不是伪造的 DOM。
- 本地其余记录会话都是**单轮**且以 `MISSING_CREDENTIAL` 失败结束；turn trigger 的其他形态 / 深色 仍没有官方像素。
- `session-subagent-spawn` 与 `session-subagent-parallel` 的子智能体内容**不是**本机实时运行：它们来自官方仓记录 fixture `snapshots/session/subagent-spawn-in-process/session.v4.jsonl` 与 `snapshots/session/subagent-parallel/session.v4.jsonl`，经官方格式读取器与官方 `JsonlSessionPersistence` 播种进临时 DSH_HOME 副本。
- 两个 subagent fixture 的子会话 id 是**占位符实现**：`realizeSeedFixture` 把 `{{session:2}}` / `{{session:3}}` 展开成 `<sessionId>-child-2` / `-child-3`，而副本里并不存在这些子会话目录。因此截图证明的是**父会话头部计数 + 父转录里的 subagent 工具行**（`已启动` 的已结算状态），**不是**子会话转录；行内 `查看` 按钮对应的子会话在本地存储中不可打开，本轮没有点击它。
- 头部计数是官方 projection 的产物：`subagent/catalog` 事件经 `subagentCatalog` projection 变成 `button[aria-haspopup="tree"]` 的 `N 个子智能体` 文案；计数断言（`1 个子智能体` / `2 个子智能体`）依赖当前中文界面，若 Web UI 切到英文会变成 `N subagent(s)`。
- 两个 subagent 截图**没有打开**头部的 catalog 下拉树（`role="tree"` 子智能体会话面板）：截图证明的是计数按钮存在且可见，该下拉面板本身没有对应像素，也未伪造。
- 子智能体截图里出现的 `已启动` / `智能体 ID` 卡片来自 fixture 的 `tool/result` 文本 `started subagent <childId>`；`turn/end` 为 `completed`，所以是**已结算**的工具行，不是运行中的 pending 行。
- `session-question-answered` 与 `session-plan-approved` 是**已结算**状态，不是 pending 接管态：官方 web fixture 的 `ask_user_question` / `exit_plan_mode` 都带 `tool/result`（已作答 / 已批准），因此只能证明已作答问答卡与已批准计划卡。待审批的 `Plan review`（Approve / Request changes）与待回答的 composer 提问面板没有对应的官方录制日志，**未截图，也未伪造**。
- `session-plan-approved` 的 turn process 保持默认折叠：`exit_plan_mode` 工具行位于折叠组内，截图证明的是 turn tail 的计划卡本身；`review.expected.md` 描述的待审批接管不在该日志中。
- 两个 web fixture 里的 `{{timeContextTimestamp}}` / `{{clientTimeZone}}` / `{{elapsed}}` / `{{sourceRoot}}` / `{{webUrl}}` 是官方快照保留的展示占位符（官方 `realizeSeedFixture` 同样不替换），位于被折叠的 context 行，不出现在截图的卡片画面中。
- plan fixture 的 v4 header `createdAt` 在迁移时被重置为 0；播种时固定为同一 scenario 官方 v2 fixture 记录的 `1788240594856`，保证重复运行时转录时间戳与 PNG 一致。
- 仍未登录：`data-signed-out="true"`，composer 显示「请选择模型」；首次使用弹窗必须先被真实关闭，才能进入会话列表。
- 网页截图不含 iOS 状态栏（09:41/信号/电量）；状态栏属于 iOS 侧叠加层，不是 Web UI 的一部分。
- 视口为 CSS 402×874、DPR3、light、mobile；截图是 1206×2622 物理像素，没有按 @3x 再乘一次。
- 截图由无头 Chrome（DevTools Protocol）生成，字体回退到 macOS 系统栈（-apple-system / PingFang），与 iPhone 真机字形可能有细微差异。

## 复现

```bash
scripts/ios-parity/golden/capture-official.sh
# hero + auth + 七个会话状态（需本机 ~/.dsh 里有对应 session；其中五个会话由官方 fixture 播种）
SKIP_SESSION=1 scripts/ios-parity/golden/capture-official.sh   # 只做 hero + auth
# 可选环境变量：DSH_OFFICIAL_REPO / CHROME_BIN / NODE_BIN / DSH_GOLDEN_OUT_DIR
#             DSH_GOLDEN_SESSION_HOME / DSH_GOLDEN_SESSION_ID / DSH_GOLDEN_SESSION_LONG_ID
#             DSH_GOLDEN_TOOL_SESSION_ID / DSH_GOLDEN_TOOL_FIXTURE / KEEP_WORK_DIR=1
#             DSH_GOLDEN_QUESTION_SESSION_ID / DSH_GOLDEN_QUESTION_FIXTURE / DSH_GOLDEN_QUESTION_EXPECTED
#             DSH_GOLDEN_PLAN_SESSION_ID / DSH_GOLDEN_PLAN_FIXTURE / DSH_GOLDEN_PLAN_CREATED_AT / DSH_GOLDEN_PLAN_EXPECTED
#             DSH_GOLDEN_SUBAGENT_SESSION_ID / DSH_GOLDEN_SUBAGENT_FIXTURE
#             DSH_GOLDEN_SUBAGENT_PARALLEL_SESSION_ID / DSH_GOLDEN_SUBAGENT_PARALLEL_FIXTURE
```
