<!-- SPDX-License-Identifier: MIT -->

# Bot 提示词对齐、队友块与会话工具面（P26）

```yaml
change: PC-20261109-bot-prompt-parity
contracts: [P26]
status: implemented
breaking: false
base: b4c3cca0901b6c08ad0c39a4012a8296a1070231
contract_revision: PC-20261109-bot-prompt-parity@1
version_decision: 不新增 wire 字段、schema、版本号或错误码。P26 volatile-context 的 `blocks` 键集合不变；`<teammates>` 是附加在既有 `automation` 块末尾的文本子块。新增 `phone-bot` 是 profile 的 Agent preset 声明，不是公共 wire。P25 事件 envelope 不变。
```

Protocol impact: P26 — Bot prompt, persona and session tool surface; P25: none — envelope unchanged

## 1. 识别与角色

- **Trigger → 现状 → 期望。** phoneDSH 的 Bot persona 只有工具边界、回复、决策、审批、记忆、例行任务和不可信内容几章；上游 zh-CN/en system prompt 里的目标验证、回复长度、文件、单一聊天线程、绝不编造、排查、未请求发送、自主性、安全、资料、用户身份、委派、内部细节、时间、队友、工作区等章节缺失。Bot 会话还沿用 `standard` preset：原生 `subagent`/`subagent_fork`、工作区 skill、`tool-schedule`、原生 ask-user、plan mode、present、workflow 等都在模型工具面里，而 phone persona 没有教它们。期望是两个语言的 phone persona 补齐这些章节并按 iOS 能力改写；例行任务变体与上游一样禁止出卡；每轮上下文有界地注入队友块；Bot 会话只看到 persona 教过的工具，DSH 工作台保持 `standard`。
- **Coordinator / contract owner / implementer / reviewer-integrator:** `bm-prompt` 单元（本工作树）依 AGENTS.md §3 产出冻结与实现证据。Owning contract 仍是 P26 `spec/bot/v1/README.md` §2 与 `volatile-context.schema.json`；本单元**不修改** `spec/**`，因为没有新的 wire/schema 增量。
- **Affected ends:** Worker 插件 `plugins/bot-runtime/{prompts,src/prompt,src/volatile-context.ts}`、`plugins/profile/phone.worker.cordis.patch.yml`、`plugins/tests`；Swift 库 `Sources/PhoneDSHBot/MCP/BotDomainVolatileContextProvider.swift` 与 `Tests/PhoneDSHBotTests/MCP/BotVolatileContextTests.swift`。App 侧的 teammates/description 闭包接线由第 3 波完成；本单元只提供注入点。`BotToolCatalog`、`approval-gate.ts`、`Authz/**` 和 app 目录未改。
- **Upstream reference:** dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6` 的 `src/main/prompts/system-prompt{,.zh-CN}.md`、`src/main/prompt/{assemble,variants,local-variants}.cjs`、`src/main/fishPersona.cjs`、`src/main/dsh/{perbot-skills,volatile-context}.mjs`。上游原文不进入公共仓库；本单元按 iOS 场景改写，没有整段照抄。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| 人设章节（zh-CN/en） | 补齐 `目标验证`、`回复长度`、`1.3 文件与视觉内容`、`1.5 单一聊天线程`、`1.6 绝不编造数据`、`1.8 排查问题`、`1.10 未经请求绝不发送消息`、`1.11 自主性`、`1.13 安全与凭据`、`1.15 个人资料`、`1.16 用户身份`、`1.17 委派与多任务`、`1.18 内部细节边界`、`1.19 时间`、`1.22 队友协作`、`1.23 你的工作区`，并把 `1.1/1.4/1.12/1.14/1.20/1.21` 改写为手机语义。桌面专有工具、macOS 本机能力、云端 Agent、GenerateImage、ReportVerification、Computer、ListMachines、CopyToBox、`mcp__dshbot__` 均不出现；`SendToAgent`/`CreateTeammate`/`FishAction` 的用法保留。 |
| FishAction | 不在 `<tools>` 声明里（当前 Bot MCP catalog 尚未注册它），正文说明：仅当宿主挂载时使用、每次回复最多一次、只改变外观、不证明完成。这样 bm-fish-react 合入时不必再改这段语义。 |
| 例行任务变体 | 「只呈现有用的卡片」→ 与上游 `wake-routine` 一致：隐藏回合不出卡、不问问题、不调用 SendToUser/SendToAgent，唯一可出的是 RequestApproval；最终助手文本是结果，安静时只写 `[quiet]`。`assemble.ts` 与 `BotDomainVolatileContextProvider.swift` 的默认文本逐字节一致（测试覆盖）。 |
| 队友块 | `BotDomainVolatileContextProvider` 新增可选 `teammates` 闭包。每轮把其他 Bot 的名字、id、description（单条截 200）、是否主 Bot 渲染为 `<teammates>...</teammates>`；排除自己，隐藏 Bot 由 App 闭包排除；总长 < 1000 字符；没有其他 Bot 时不输出。 |
| 队友块位置／传输 | P26 的 `volatile-context.schema.json` 没有 `teammates` 键，本单元不扩 schema；子块追加到既有 `automation` 块的末尾，因此渲染顺序仍是 variant → time → persona → memory → automation（队友内容在 automation 之后）。automation 与队友合计不超过 3,900 标量，给 4,000 上限留余量。 |
| 人设 description | `BotDomainVolatileContextProvider` 新增可选 `botDescription` 闭包；非空时追加在 persona 文本之后，截 300 个字符。默认 nil = 不追加，保持现有行为。`runtimePersonaBlock` 同步接受可选 `description`。 |
| Bot 会话 preset | `plugins/profile/phone.worker.cordis.patch.yml` 新增 `phone-bot` Agent preset：继承全局 phone persona（不挂 `persona` 行），只挂 `agent-instructions`、`time-context`、`tool-bash`、`tool-fs`（`readImage: false`、`applyPatch: false`）、`tool-fs-search`、`tool-jobs`、`command-goal`、`tool-goal`、`tool-todo`、`tool-web` 和 `compaction`。原生模型工具恰好是 persona 声明的 `bash/read/write/edit/glob/grep/web_search/web_fetch/job_list/job_output/job_kill/todo_write/create_goal/get_goal/update_goal`。 |
| Bot preset 选择 | `volatile-context` 插件新增 `botAgentPreset` 配置；`phone.worker.cordis.patch.yml` 设为 `phone-bot`。插件在 `agent/created` 对 `gb-` 会话、且会话尚未开始第一回合时选择该 preset；已开始回合的恢复会话返回 `agent-preset/locked` 时保留原样（DSH 只允许 blank session 切 preset），其他错误 fail-closed。DSH 工作台 `agent-preset-registry.default` 仍为 `standard`，且 phone patch 不覆盖 `preset-standard`。 |
| 工具面清单 | `PHONE_NATIVE_TOOLS` 从 11 个扩展到 15 个（新增 `todo_write/create_goal/get_goal/update_goal`）。`plugins/tests/bot-tool-surface.test.ts` 以真实 YAML patch 和 `assemblePrompt()` 做门禁：preset 的启用工具行映射必须等于 prompt 声明的原生工具集；任何多出/缺少都失败。 |
| persona 副本 | `patch.yml` 的 `personaPrefix` 由 `assemblePrompt()` 输出机械重生成，与 `bot-persona.test.ts` 的逐字节比较保持同一权威。 |
| 工具边界测试 | `bots` 工具仍由 `BotToolCatalog` 的 P0/team 列表提供；本单元没有改 `BotToolCatalog.swift`，也没有新增 MCP 工具名。`PHONE_P0_TOOLS` 仍是 18 个。 |

Self-check（`spec/README.md` §5.1）：没有第二份 schema、第二个 envelope、别名或新错误码；`<teammates>` 未新增 JSON 字段；`phone-bot` 是现有 `@deepseek-ai/dsh-agent-preset` 声明的 additive 实例；工具名没有新增或放宽 enum；没有把 macOS 工具写进 prompt。

## 3. 工具面开关与依据

上游 dsh-bot 的 Bot runtime 由 `src/main/prompt/assemble.cjs` 生成 `cordis.patch.yml`：

- `tool-subagent` / `tool-subagent-fork` 明确 `disabled: true`，因为原生 subagent 是 fire-and-forget，与阻塞式 `Task` 的语义相反；phoneDSH 的 Bot 会话同样只用 `mcp__phone__Task`。
- `skill-filesystem` 明确 `disabled: true`，改挂 per-Bot skill provider；phoneDSH 的每 Bot skill 属于下一个 PR，所以本单元把 `skill-filesystem` 与 `tool-skill` 一起关闭，避免把共享工作区 skill 广播给每个 Bot。
- `tool-schedule` 在 Bot 运行时没有对应上游语义：手机 Bot 的例行任务由 App 的 `RoutineMachine` / `automation_status` 驱动，DSH 的 `schedule_*` 会和它冲突，关闭。
- `tool-todo` 与 `command-goal`/`tool-goal`：上游 `native-tools.cjs` 把 `todo_write`、`create_goal`、`get_goal`、`update_goal` 列为 harness 原生工具，`system-prompt.zh-CN.md` §1.17 与 Environment 也教它们；上游 Bot 会话没有关闭它们，所以 phoneDSH 保留，并在 persona 里补上 `todo_write` 队列与目标验证规则。因为没有 `ReportVerification`，目标验证章按手机改写为「先取得真实证据，再 `update_goal complete`」。
- 原生 `ask_user_question`、plan mode、`present`、`workflow`、`tool-subagent-control`：phone persona 明确使用 `mcp__phone__ask_user`，不教这些原生工具，因此不挂。它们既不进入 Bot 工具面，也不影响工作台。
- `tool-fs` 的 `read_image` / `apply_patch`：persona 没有教，preset 显式 `readImage: false`、`applyPatch: false`。
- 工作台：`agent-preset-registry.default: standard` 不变，phone patch 没有 `preset-standard` 覆盖，`standard` 的全量工具仍给 DSH 工作台会话。

## 4. 兼容性与发布

| Producer → Consumer | 支持／拒绝方式及理由；对应测试 |
| --- | --- |
| 旧 Worker persona → 新 Swift volatile | `BotVolatileBlocks` 的 JSON 键不变；Swift 只是把 `<teammates>` 文本放进 `automation` 字符串，旧 volatile consumer 当作普通文本渲染。`AutomationStatus` 的 4,000 上限仍由既有 producer 校验；本单元把 automation+队友限制在 3,900。 |
| 新 Swift volatile → 旧 Worker | 旧 Worker 不解析 `<teammates>`，照常把 `automation` 展示给模型；teammates 信息仍在 prompt 里，不会丢。 |
| 旧 Bot 会话 → 新 preset | 已有第一回合的 `gb-` 会话不能被 DSH 合法切换 preset；`agent/created` 捕获 `agent-preset/locked` 后保持原样。新建会话、Task 会话和 routine 会话走 `phone-bot`。App 侧第 3 波可在创建会话时直接传 `agentPreset: "phone-bot"`；插件对已匹配的 preset 是 no-op。 |
| 新 Bot 会话 → 旧 Worker | 旧 Worker 没有 `phone-bot` preset 也不会选择它；会话按旧 `standard` 运行，行为与 rollback 前一致。 |
| 工作台 → Bot preset | `agent-preset-registry.default` 仍是 `standard`；`phone-bot` 只被 `gb-` 选择逻辑使用。工作台已有会话的 composition 不变。 |
| 工具面门禁 | `bot-tool-surface.test.ts` 以真实 `phone.worker.cordis.patch.yml` 解析 `phone-bot` 的 11 行声明，映射工具名后与 `assemblePrompt()` 的声明集合严格比较；多出/缺少都失败。它还断言 `preset-standard` 没有被覆盖、registry 默认仍是 `standard`。 |

- 版本决定：P26 的 volatile schema 没有新增字段，`phone-bot` 只是 profile 的 Agent preset，因此不需要 schema revision、不需要 P25 envelope 变更、不需要 bump Worker 参数。
- 有意差异：上游 Bot 会话没有关闭 `tool-todo`/`tool-goal`（本单元保留并教）；上游的 `skill` 由 per-Bot provider 提供，phoneDSH 在下一 PR 之前关闭；`tool-schedule` 是 phoneDSH 的额外关闭项，因为 App 的 RoutineMachine 是唯一调度权威。
- 回滚：删除 `phone-bot` preset 与 `botAgentPreset` 配置即可回到 `standard`；新会话不再选择 Bot preset；旧会话原本就是 `standard`，无需迁移。没有 on-disk 数据格式变化。

## 5. 分工与测试证据

- Worker / prompt：`plugins/bot-runtime/prompts/**`、`plugins/bot-runtime/src/prompt/assemble.ts`、`plugins/bot-runtime/src/volatile-context.ts`、`plugins/profile/phone.worker.cordis.patch.yml`。
- Worker tests：`plugins/tests/{bot-persona,bot-team-persona,bot-runtime-volatile-context,bot-tool-surface}.test.ts`。`bot-tool-surface.test.ts` 是新增门禁。
- Swift：`Sources/PhoneDSHBot/MCP/BotDomainVolatileContextProvider.swift`；`Tests/PhoneDSHBotTests/MCP/BotVolatileContextTests.swift` 新增 description/队友块/限量/转义/例行变体断言。
- 命令与结果：见下节；Swift 全量既有无关测试与 App 构建不在本单元范围，App 侧接线（teammates/description 闭包）由第 3 波完成。

运行记录：

- `cd plugins && npm run typecheck` → PASS。
- `cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"` → PASS（51 tests，50 pass，1 skip：`PDSH_DSH_CHECKOUT` 未设的 image-boot 用例；0 fail）。
- `cd plugins && npm test` → 运行器在主机高负载下没有自行退出（遗留 handle）；同一文件集合用 `--test-force-exit --test-timeout=180000` 完成：2469 tests，2417 pass，3 fail，1 cancelled，48 skip。失败中的两个就是已知基线：`phone-feature-admin`（需要 `PDSH_DSH_CHECKOUT`）与 `Node Timeout objects`（同一个 pinned checkout 条件）；第三个是 `node-fetch --jitless` 在本机 Node 22 上 `--jitless` 没有 WebAssembly（本 diff 未触及该测试）；cancelled 是 `wasi-toolbox/python/compression.test.ts` 的 artifact rebuild 超过诊断用 180 秒（本 diff 未触及）。本单元新增/修改的 `bot-*.test.ts` 全部通过。
- `swift test --disable-sandbox --filter PhoneDSHBotTests` → PASS（353 tests，0 failures）。
- `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS（phone-spec 90 files/0 errors；phone-cross-tree 8/8 invariants、registry byte-identical、89 schemas 0 breaking、87 tests OK）。

## 6. 第 3 波接线接口

```swift
public struct BotTeammateSummary: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let isMain: Bool
}

public init(
    memory: BotMemory,
    routines: RoutineMachine,
    variant: (@Sendable (String, BotSessionKind) -> String)? = nil,
    persona: (@Sendable (String, String, BotSessionKind) -> String)? = nil,
    memoryForBot: (@Sendable (String) async throws -> BotMemory)? = nil,
    teammates: (@Sendable (String) async -> [BotTeammateSummary])? = nil,
    botDescription: (@Sendable (String) async -> String?)? = nil,
    now: @escaping @Sendable () -> Int64 = { ... },
    language: String = "zh"
)
```

`personaAsync` 初始化器同样接受 `teammates` / `botDescription`。App 的第 3 波只需：

1. `teammates: { botId in roster.visibleBots.filter { $0.id != botId }.map { .init(id:..., name:..., description:..., isMain:...) } }`；隐藏 Bot 必须在这里排除。
2. `botDescription: { botId in profileStore.record(botId)?.description }`。
3. 如希望不依赖插件的 `agent/created` 选择，创建 Bot 会话时传 `agentPreset: "phone-bot"`；两条路径同时存在时插件检测到 preset 已匹配会 no-op。

## 7. 修订记录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| `bot-prompt-parity-v1` | `bm-prompt`（contract owner / implementer） | 初次实现提示词章节对齐、例程变体、队友块、persona description 与 `phone-bot` 工具面 | lead、`bm-app`（第 3 波）、`bm-fish-react`（FishAction 合入时同步 `<tools>`/P0） |
