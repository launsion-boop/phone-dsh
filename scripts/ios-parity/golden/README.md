# 官方 DSH Web UI 402pt golden harness

把官方 `deepseek-harness` 的 **Web UI** 以 **CSS 402×874、DPR 3、light、mobile** 渲染并截图，
输出到 `docs/receipts/ios-session-audit/screens/official/`。除 hero / 认证闸门外，还会**打开真实本地会话**截取 chat 转录，
并用官方记录 fixture 播种 **bash 工具卡 / 已作答问答卡 / 已批准计划卡 / 子智能体头部计数 + subagent 工具行**。

这不是 iOS 截图，也不是模拟官方 UI：它启动官方 `dsh web` 服务、加载官方构建产物、由无头 Chrome 真实渲染。

## 为什么不能直接静态托管 `apps/web/dist`

`python3 -m http.server` 只返回 `index.html`，拿不到真正的 boot 流程，页面会报：

```
Failed to load plugins: web boot: window.__ModuleLoader__ bootstrap facade is missing
```

官方 `dsh web` 服务会注入 `window.__ModuleLoader__` bootstrap、插件 preload 清单和 `/plugins/...` 路由，
并在首次访问时打印带一次性 token 的 URL。本 harness 走的是这条路径。

## 为什么不用 `chrome --headless --screenshot`

Web UI 会保持一条 WebSocket；`--virtual-time-budget` 永远等不到“静止”，Chrome 不会退出（实测挂死）。
所以截图改用 **Chrome DevTools Protocol** 驱动：设置设备指标 → 等应用挂载 → `Page.captureScreenshot` → 关闭浏览器。
只依赖 Node 22 自带的全局 `WebSocket`，**没有 Playwright/Puppeteer 依赖**。

## 用法

前置条件（一次性）：

- 官方仓已构建：`apps/cli/lib/bin.js` 与 `apps/web/dist/index.html` 存在
  （`pnpm install && pnpm build`；或至少 `pnpm run build:lib && pnpm run build:web`）。
- Node ≥ 22.19（会依次尝试 `/opt/homebrew/Cellar/node@22/*/bin/node`、node@24、PATH 上的 node）。
- Google Chrome 安装在 `/Applications/Google Chrome.app`。

运行：

```bash
scripts/ios-parity/golden/capture-official.sh
```

脚本会自己启动服务（`--port 0` 随机端口）、截图、写 manifest，然后杀掉服务并删除临时 `DSH_HOME`。

- **hero / auth** 用 pristine（空）`DSH_HOME`，保证 hero 仍是“无会话”空态。
- **会话** 会把 `~/.dsh` **复制**到临时目录再起第二个服务进程；打开 V3 会话会在副本里迁移成 V4，
  真实 `~/.dsh` 只被读取，不会被写、不会被锁。
- 副本里五个单轮失败会话会被**官方记录 fixture** 替换（只改副本）：
  1. `seed-official-session.mjs` 读官方 `snapshots/session/bash-tool-turn/session.v4.jsonl`，播种出 assistant 文本 + bash 工具卡的富会话；
  2. 读官方 `snapshots/web/question-composer/session.v4.jsonl`，播种出**已作答**的 `ask_user_question` 问答卡；
  3. 读官方 `snapshots/web/plan-review/session.v4.jsonl`，播种出**已批准**的 `exit_plan_mode` 计划卡；
  4. 读官方 `snapshots/session/subagent-spawn-in-process/session.v4.jsonl`，播种出**会话头 `1 个子智能体` 计数 + 展开的 `subagent` 工具行**；
  5. 读官方 `snapshots/session/subagent-parallel/session.v4.jsonl`，播种出**`2 个子智能体` 计数 + 两张 subagent 工具行**（同一工具、只差 catalog 事件，用来证明计数来自日志）。
  五个 fixture 都带 `tool/result`，因此是**已结算态**；pending 问答面板 / pending 计划审批面板 / 实时运行中的 subagent 没有对应日志，**不伪造**。
- 只要 `~/.dsh` 或指定 session / fixture 不存在，脚本会**报错退出**（不静默降级）；只想要 hero+auth 时用 `SKIP_SESSION=1`。

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_OFFICIAL_REPO` | `/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness` | 官方仓路径 |
| `DSH_GOLDEN_OUT_DIR` | `docs/receipts/ios-session-audit/screens/official` | 输出目录 |
| `NODE_BIN` | 自动探测 | 指定 node |
| `CHROME_BIN` | `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` | 指定 Chrome |
| `DSH_GOLDEN_PORT` | `0` | 固定端口（默认交给系统分配） |
| `KEEP_WORK_DIR=1` | 关 | 保留临时 `DSH_HOME`、服务日志、cookie |
| `DSH_GOLDEN_SESSION_HOME` | `~/.dsh` | 会话 fixture 的源 DSH_HOME（只读，复制后使用） |
| `DSH_GOLDEN_SESSION_ID` | `session-ca5b4ecd-…` | 要打开的短会话 id |
| `DSH_GOLDEN_SESSION_LONG_ID` | `session-d81de3d6-…` | 要打开的长 prompt 会话 id |
| `DSH_GOLDEN_TOOL_SESSION_ID` | `session-4f117741-…` | 被 bash fixture 替换的会话 id（只改副本） |
| `DSH_GOLDEN_TOOL_FIXTURE` | `<repo>/snapshots/session/bash-tool-turn/session.v4.jsonl` | bash 工具卡 fixture 路径 |
| `DSH_GOLDEN_QUESTION_SESSION_ID` | `session-08d252dc-…` | 被问答 fixture 替换的会话 id（只改副本） |
| `DSH_GOLDEN_QUESTION_FIXTURE` | `<repo>/snapshots/web/question-composer/session.v4.jsonl` | 已作答问答卡 fixture 路径 |
| `DSH_GOLDEN_QUESTION_EXPECTED` | `<repo>/snapshots/web/question-composer/answered-expanded.expected.md` | 已渲染状态的官方 a11y 契约（记入 manifest） |
| `DSH_GOLDEN_QUESTION_PENDING_EXPECTED` | `<repo>/snapshots/web/question-composer/ui.expected.md` | fixture **不**渲染的 pending 契约（记入 manifest） |
| `DSH_GOLDEN_PLAN_SESSION_ID` | `session-1b0222d8-…` | 被计划 fixture 替换的会话 id（只改副本） |
| `DSH_GOLDEN_PLAN_FIXTURE` | `<repo>/snapshots/web/plan-review/session.v4.jsonl` | 已批准计划卡 fixture 路径 |
| `DSH_GOLDEN_PLAN_CREATED_AT` | `1788240594856` | 计划 fixture 的时钟锚点（v4 header 的 `createdAt` 被重置为 0；该值是同一 scenario 官方 v2 记录） |
| `DSH_GOLDEN_PLAN_EXPECTED` | `<repo>/snapshots/web/plan-review/approved.expected.md` | 已渲染状态的官方 a11y 契约（记入 manifest） |
| `DSH_GOLDEN_PLAN_PENDING_EXPECTED` | `<repo>/snapshots/web/plan-review/review.expected.md` | fixture **不**渲染的 pending 契约（记入 manifest） |
| `DSH_GOLDEN_SUBAGENT_SESSION_ID` | `session-ff9414c5-…` | 被 subagent-spawn-in-process fixture 替换的会话 id（只改副本） |
| `DSH_GOLDEN_SUBAGENT_FIXTURE` | `<repo>/snapshots/session/subagent-spawn-in-process/session.v4.jsonl` | 子智能体头部计数 + 工具行 fixture 路径 |
| `DSH_GOLDEN_SUBAGENT_PARALLEL_SESSION_ID` | `session-d6126d5c-…` | 被 subagent-parallel fixture 替换的会话 id（只改副本） |
| `DSH_GOLDEN_SUBAGENT_PARALLEL_FIXTURE` | `<repo>/snapshots/session/subagent-parallel/session.v4.jsonl` | 并行子智能体（两条 catalog）fixture 路径 |
| `SKIP_SESSION=1` | 关 | 只截 hero + auth，不复制 DSH_HOME |

## 捕获的状态

| 文件 | 状态 | 说明 |
|---|---|---|
| `official-hero-sessionless-402x874-dpr3.png` | 会话空态（hero） | 未登录、未选模型、无会话；官方首次运行浮层已按用户操作关闭 |
| `official-auth-gate-402x874-dpr3.png` | 首次使用认证闸门 | “开始使用”弹窗：登录 DeepSeek 账号 / 添加 API Key |
| `official-session-chat-402x874-dpr3.png` | 已打开会话（chat） | 会话 `reply with the single word`：user 气泡 + 时间戳 + 本轮运行失败 + composer |
| `official-session-chat-long-user-turn-402x874-dpr3.png` | 长 prompt 会话 | 同一 harness 打开长 user prompt 会话并滚到 turn tail |
| `official-session-chat-tool-402x874-dpr3.png` | 富会话（官方 fixture 播种） | assistant 文本 `DONE` + 展开的 turn process / 工具组 / bash 工具卡（cwd + `echo TERMINAL_OK` + 输出 `TERMINAL_OK`）+ composer |
| `official-session-question-402x874-dpr3.png` | **已作答问答卡**（官方 fixture 播种） | 展开 turn process / `向用户提出了问题` 组 / `提问 · 1/1 已回答` 行后：`Which color do you prefer?` + `Blue` + 自定义回答 `Include accessibility notes`；**不是**待回答 composer 面板 |
| `official-session-plan-402x874-dpr3.png` | **已批准计划卡**（官方 fixture 播种） | turn tail 计划卡 `Add \`--greeting\` flag to CLI` / `计划 · Markdown` / `打开`；turn process 保持默认折叠；**不是**待审批 `Plan review` 接管面板 |
| `official-session-subagent-402x874-dpr3.png` | **子智能体态**（官方 fixture 播种） | 会话头 `1 个子智能体` 计数按钮（`button[aria-haspopup="tree"]`，来自日志里的 `subagent/catalog`）+ 展开 turn process / `已协调子智能体` 组 / `subagent` 工具行：`创建子智能体` / `调用结果` / prompt / `● 已启动` / `智能体 ID …-child-2`；另有 `思考`、`PARENT_DONE`、`子任务状态更新` turn trigger、composer；**不打开**头部 catalog 下拉树 |
| `official-session-subagent-parallel-402x874-dpr3.png` | **并行子智能体态**（官方 fixture 播种） | 同一工具/配置、两条 `subagent/catalog` → 头部 `2 个子智能体`；一个 `已协调子智能体` 组里两张 `subagent` 行（第一张展开、第二张折叠）+ `PARENT_DONE` + composer；用来证明头部计数由日志派生 |

浮层关闭是对真实控件的点击，不是隐藏 DOM / 改样式：

| 浮层 | 触发 |
|---|---|
| PWA「安装到主屏幕」横幅 | `button[aria-label="关闭提示"]` |
| 「预览版说明」弹窗 | 文本为 `继续` 的按钮 |
| 「开始使用」认证弹窗 | `button[aria-label="关闭"]`（仅 hero 截图） |

关闭后脚本会断言这些浮层都不再存在（`leftoverOverlays: []`），否则放弃这次截图并报错，避免把浮层当 hero 交差。

会话截图同样是真实点击（不是隐藏 DOM / 改样式 / 注入假消息）：

| 步骤 | 选择器 |
|---|---|
| 打开抽屉 | `button[aria-label="菜单"]` |
| 展开「未分组」 | `[data-row-key="workspace:"]`（默认折叠） |
| 展开其余会话（长 prompt 会话需要） | `[data-row-key="overflow:"]` |
| 打开会话 | `[data-row-key="session:<id>"]` |
| 关闭抽屉 | `button[aria-label="关闭面板"]` |
| 展开 turn process（仅富会话 / 问答卡） | `button[data-turn-process]` |
| 展开工具组（仅富会话） | `[data-chat-group-key] > div > button[aria-expanded]` |
| 展开 bash 工具卡（仅富会话） | `div[data-sample="bash"]` |
| 展开「向用户提出了问题」组（仅问答卡） | `button[data-process-activity="questions"]` |
| 展开问答行（仅问答卡） | `[data-tool="ask_user_question"] [data-disclosure-row]` |
| 把问答卡滚进视口（仅问答卡） | `scrollIntoView({block: "center"})` on `[data-tool="ask_user_question"]` |
| 展开 turn process（仅子智能体） | `button[data-turn-process]` |
| 展开 `已协调子智能体` 过程组（仅子智能体） | `[data-chat-group-key] > div > button[aria-expanded]` |
| 展开 subagent 工具行（仅子智能体） | `[data-tool="subagent"] [data-disclosure-row]` |

计划卡不做额外展开：turn tail 的计划卡默认可见，截图时跟随 turn tail（与计划 fixture 的 `approved.expected.md` 一致）。

随后断言 `[data-conversation-session]` 等于请求的 session id、抽屉已关闭，且 `[data-chat-node-key]` 至少有一行
`data-chat-flow-kind="user"`（可用 `--transcript-require-flow-kind` 换成别的 flow kind；计划会话由 `/plan` 命令开启，
没有 user 行，所以要求 `command` + `tool-call` + `turn-tail`）；否则失败，不把会话列表或空 chat 当“会话截图”。
富会话还要求 `assistant-step` 与 `tool-call` 两种行都**可见**（`visibleFlowKinds`），即真的有 assistant 文本和工具卡。

问答卡 / 计划卡 / 子智能体还加内容断言（`--require-visible-selector`，必须命中且可见）：

- 问答卡：`[data-chat-node-key] [data-tool="ask_user_question"]`（1/1 可见）+ 正文必须含 `Include accessibility notes`（只出现在展开后的已作答卡片）
- 计划卡：`[data-chat-node-key] [data-plan-card]`（1/1 可见）+ 正文必须含 `Add \`--greeting\` flag to CLI`
- 子智能体（spawn）：`[data-chat-node-key] [data-tool="subagent"]`（1/1 可见）+ 会话头 `button[aria-haspopup="tree"]`（1/1 可见，文案 `1 个子智能体`）+ `body.innerText` 含 `1 个子智能体`
- 子智能体（parallel）：同上，但要求 `2/2` 张 subagent 行可见、头部文案 `2 个子智能体`

四张 fixture 图都启用 `--fail-on-console-error`；两张子智能体图还启用 `--fail-on-network-error`（非取消的加载失败或 HTTP ≥ 400 直接失败）。console error / 未捕获异常 / 网络失败 / HTTP error > 0 都不产出 golden。

## 为什么会“失败得很响”

任一环节不满足都会非零退出，不会产出看似成功的图：

1. 官方仓/构建产物缺失 → 直接给出构建命令。
2. 没有 Node ≥ 22.19 / 没有 Chrome → 报具体路径。
3. `dsh web` 没打印 token URL 或提前退出 → 打印服务端日志。
4. 带 token 的 GET 失败 → 打印日志（认证链路坏了）。
5. 返回的 HTML 里没有 `__ModuleLoader__` → 判定为“静态托管失败模式”。
6. 应用没有挂载（无 `[data-dsh-boot]` 且 `#root` 空/仍显示 skeleton）、或出现 boot 失败文案 → 不截图。
7. PNG 不是 1206×2622、或生成的图尺寸不符 → 报错。
8. 浮层没关干净 → 报错。
9. 会话没出现在列表 / 点不开 / 打开的 id 不匹配 / 没有转录行 → 报错并列出侧栏里实际可用的 session id。
10. 抽屉没在截图前关掉 → 报错。
11. 问答卡 / 计划卡 / 子智能体的选择器不可见、或正文不含录音答案 / 计划标题 / 头部计数 → 报错。
12. 新图启用了 console gate：console error 或未捕获异常 → 报错；两张子智能体图还启用了 network gate：非取消的加载失败或 HTTP ≥ 400 → 报错。
13. 播种后的日志若没有 `tool/result`（fixture 变成 pending）→ `assert_seed_state` 直接失败，拒绝把它标成 answered/approved；subagent fixture 同样要求 `subagent` 有 result 且 `turn/end completed`。

## 产物与可复现性

```
docs/receipts/ios-session-audit/screens/official/
├── manifest.json                      # 机器可读：URL/状态/视口/DPR/commit/sha256/console/状态证据
├── manifest.md                        # 人读版本
├── official-hero-sessionless-402x874-dpr3.png
├── official-auth-gate-402x874-dpr3.png
├── official-session-chat-402x874-dpr3.png
├── official-session-chat-long-user-turn-402x874-dpr3.png
├── official-session-chat-tool-402x874-dpr3.png
├── official-session-question-402x874-dpr3.png
├── official-session-plan-402x874-dpr3.png
├── official-session-subagent-402x874-dpr3.png
├── official-session-subagent-parallel-402x874-dpr3.png
└── reports/                           # 每次 cdp-capture 的原始报告（含 body text 取证）
```

同一 commit、同一机器、同一会话数据上重复运行，PNG 的 SHA-256 一致。九张图在本轮**三次完整 harness 运行**中逐字节一致
（计划 fixture 的 `createdAt` 固定为 `1788240594856`；两个 subagent fixture 的 v4 header 自带非零 `createdAt`
（`1783352119267` / `1783352126000`），直接沿用，因此转录时间戳稳定）。

`manifest.json` 里的官方 commit 是**直接读 `.git/HEAD`** 得到的（审计约束：不跑 git 命令）；
如果实际 commit 不是 `7be5505b0b...`，脚本会告警并在 manifest 里记录真实值。

## 已知限制

- **没有登录态 / 没有 API Key**：`data-signed-out="true"`，composer 显示「请选择模型」。会话能打开、能渲染，
  但不能产生 assistant 内容。
- **本地会话只有单轮失败样本**：`~/.dsh` 里的会话全部以 `MISSING_CREDENTIAL` 结束，所以两张本地 chat golden
  只覆盖页头 / user 气泡 / 时间戳 / turn-error / turn tail / composer。
- **富会话 / 问答卡 / 计划卡 / 子智能体都不是实时模型运行**：内容来自官方记录 fixture，经官方读取器与
  `JsonlSessionPersistence` 播种到 DSH_HOME 副本；fixture 没有记录 `{{tools}}` schema 侧车，官方读取器
  按 web e2e 同一口径省略。
- **问答卡 / 计划卡是已结算态**：两个 web fixture 都带 `tool/result`（已回答 / 已批准），所以只能证明已作答问答卡
  与已批准计划卡；**待回答的 composer 提问面板**与**待审批的 `Plan review` 接管面板**没有对应的官方录制日志，
  未截图、也未伪造（没有截断 fixture、没有删 result）。深色仍无官方像素。
- **子智能体态的两个 fixture 都不含子会话本身**：`{{session:2}}` / `{{session:3}}` 被展开成 `<sessionId>-child-2/-3`，
  但副本里没有对应子会话目录；所以截图证明的是**头部 catalog 计数 + 父转录里的 subagent 工具行**（`已启动` 的已结算态），
  不是子会话转录。工具行里的「查看」没有点击（点了也打不开不存在的子会话）。
- **头部计数依赖中文界面**：断言文案是 `1 个子智能体` / `2 个子智能体`（官方 `subagent` 命名空间当前语言）。
- 官方 `snapshots/session/subagent-*` **没有** `.expected.md` a11y 契约（`snapshots/web/*` 才有），所以这两个状态的断言全部来自真实渲染的 DOM / report。
- **头部 catalog 下拉树没有打开**：截图里只证明计数按钮存在且可见，`role="tree"` 子智能体树面板没有对应像素。
- 计划卡的 turn process 保持默认折叠，`exit_plan_mode` 工具行没有展开；截图证明的是 turn tail 的计划卡本身。
- 两个 web fixture 里的 `{{timeContextTimestamp}}` / `{{clientTimeZone}}` / `{{elapsed}}` / `{{sourceRoot}}` / `{{webUrl}}`
  是官方快照保留的展示占位符（官方 `realizeSeedFixture` 同样不替换），位于折叠的 context 行，不进入卡片画面。
- 五个播种状态都依赖 `DSH_GOLDEN_*_SESSION_ID` 指向的本地会话目录存在（脚本只替换其日志，保留原 cwd 分组）。
- 会话截图依赖本机 `~/.dsh` 的历史数据；换机器或删掉这些 session 后需要重设
  `DSH_GOLDEN_SESSION_ID` / `DSH_GOLDEN_SESSION_LONG_ID` / `DSH_GOLDEN_TOOL_SESSION_ID` /
  `DSH_GOLDEN_QUESTION_SESSION_ID` / `DSH_GOLDEN_PLAN_SESSION_ID` / `DSH_GOLDEN_SUBAGENT_SESSION_ID` /
  `DSH_GOLDEN_SUBAGENT_PARALLEL_SESSION_ID`。
- 截图不含 iOS 状态栏（09:41/信号/电量），那是 iOS 侧叠加层。
- 无头 Chrome 使用 macOS 系统字体栈，与 iPhone 真机字形可能有细微差异。
- 截图是 1206×2622 物理像素；CSS px 与 pt 在 402 宽下按 1:1 解释，不要再乘 @3x。

## 目录

| 文件 | 作用 |
|---|---|
| `capture-official.sh` | 一键：起 pristine 服务（hero+auth）→ 复制 DSH_HOME 起会话服务（chat + 五个 fixture 播种）→ 校验 bootstrap → 截图 → 写 manifest → 清理 |
| `cdp-capture.mjs` | 无依赖 CDP 截图器（设备指标、浮层关闭、`--open-session` 打开会话、可配置 flow kind 断言、`--require-visible-selector` 内容断言、`--fail-on-console-error`、console/网络采集） |
| `seed-official-session.mjs` | 通过官方格式读取器 + `JsonlSessionPersistence` 把官方 fixture 播种进临时 DSH_HOME 会话（**当前可用**；支持 `--created-at` 固定时钟，记录 `toolCalls`/`turnEnd` 状态证据） |
| `seed-session-fixture.mjs` | 早期手写 zstd 帧的尝试；只能让会话出现在列表，事件转录为空，保留作失败证据 |
| `write-manifest.mjs` | 汇总报告生成 `manifest.json` / `manifest.md`（token 脱敏、sha256、commit 校验、五个 fixture 的 provenance、由日志推导的 answered/approved/settled 标签） |
