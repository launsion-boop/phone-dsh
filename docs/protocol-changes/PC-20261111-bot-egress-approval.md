<!-- SPDX-License-Identifier: MIT -->

# Bot 出口写审批、工作区根与文件 Grant 粒度契约冻结（P05/P26）

```yaml
change: PC-20261111-bot-egress-approval
contracts: [P05, P26]
status: implemented
breaking: false
version_decision: Additive host-composition seam and phone-only vectors. No wire field, route, JSON-RPC method, frame, schema or BotEvent shape changes. New App + new Worker is the supported pair; mixed old/new pairs keep an approval layer (old host keeps its command-pattern card; new host asks at the exit for the live bash registration).
base: 0bbe253f62f22f8ab99f31a11dd1121ab65c15da
contract_revision: spec/bot/v1/README.md@PC-20261111-bot-egress-approval@2 + spec/v1/gateway-security.md@PC-20261111-bot-egress-approval@2 + spec/bot/v1/golden/mcp-egress.phone.json@PC-20261111-bot-egress-approval@2 + spec/bot/v1/golden/approval-patterns.phone.json@PC-20261111-bot-egress-approval
```

Protocol impact: P05; P16: none — the Worker environment is unchanged (no new token or variable); P26; P27: none — the new `approval.requested`/`approval.decided` events reuse the existing P25/P27 shapes and the existing approval row, and no row/user-action/projection field changed; P09: none — no UI page or eval catalog assertion changed.

## 1. 识别与角色

- **Trigger → 现况 → 期望。**
  - WP3 取证显示 `phoneEffectsForApproval('bash')` / `BotApprovalPatternAnalyzer` 对脚本文件、变量拼接、`python3 /tmp/x.py` 的网络写返回空效果；宿主对空效果直接 `auto-policy`，模型可在“一次 bash 批准”后静默发出 POST。即使正则命中，命令文本也不是安全边界。
  - 现在要求：任何经宿主 `/v1/http` 的 `POST`/`PUT`/`PATCH`/`DELETE`，不论命令怎么写，都在**宿主出口**按“主机 + 方法”判断；无 Grant 就挂起现有 Bot 审批卡，拒绝/超时/取消 fail-closed。`GET`/`HEAD` 维持 allow-list。
  - 同时把 `write`/`edit` 的结构审批从“参数摘要”改成“目录粒度”，并让 Bot 自己工作区根内的写不再出结构审批卡；根外写仍按目录授权，DSH 文件沙箱是执行边界。
- **责任。** 本单元 `s2-s4a` 兼任 contract owner 与 implementer；本文件是契约冻结与实施记录，不是独立 reviewer 的验收。
- **Owning contracts / schemas / fixtures。**
  - P05 出口：[spec/v1/gateway-security.md](../../spec/v1/gateway-security.md) §5.1、§7；实现 `Sources/PhoneDSHGateway/{ModelGateway,GatewaySession}.swift`、`Sources/PhoneDSHLoopback/HTTPEgressFailure.swift`、`Sources/PhoneDSH/PhoneMCPAccessSettings.swift`、`Sources/PhoneDSH/PhoneDSHHost.swift`（接线）。
  - P26 审批/Grant/效果：[spec/bot/v1/README.md](../../spec/bot/v1/README.md) §2.4；实现 `Sources/PhoneDSHBot/Authz/{BotApprovalPatterns,BotEgressEffects}.swift`、`Sources/PhoneDSHBot/MCP/{BotApprovalCoordinator,BotMCPRuntime}.swift`、`plugins/bot-runtime/src/approval-gate.ts`、`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift`（接线）。
  - 共享 fixtures：[golden/mcp-egress.phone.json](../../spec/bot/v1/golden/mcp-egress.phone.json) 新增 `egress-approval` / `grant-directory`；[golden/approval-patterns.phone.json](../../spec/bot/v1/golden/approval-patterns.phone.json) 登记网络模式降级；[export-manifest.json](../../spec/bot/v1/export-manifest.json) 与 [validate_vectors.py](../../spec/bot/v1/tools/validate_vectors.py) 已更新。
- **受影响的 producer / consumer。**
  - Swift 宿主：`PhoneDSHGateway`（出口审批 seam、错误、重定向拒绝）、`PhoneDSHLoopback`（403 分类）、`PhoneDSHBot`（活动 `bash` 归属、审批/Grant、目录效果）、`PhoneDSH`（policy 安装、gateway 接线）、probe app 装配。
  - Worker/TS：`approval-gate.ts`（网络正则降级、`write`/`edit` 目录效果与根内跳过）、`bot-runtime` 测试。
  - Android / HarmonyOS：没有 Bot runtime，不安装 `BotEgressWriteApproving`，不实现 `egress-approval` / `grant-directory` 手机专属向量；其 `/v1/http` 行为不变。
  - 未改：Routine、Task、记忆、主动提醒、UI 页面、eval selftest 场景数。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 出口方法集合 | 无 → `POST`/`PUT`/`PATCH`/`DELETE` 进入 Bot 出口审批；`GET`/`HEAD` 不变；精确模型推理端点 `POST` 走模型路径；精确 MCP 路由由既有 `X-PDSH-MCP-Egress` 门禁负责，不在出口审批，避免审批 `/approval` 请求递归。依据 §5.1、P26 §2.4。 |
| 归属（A：job 生命周期） | 命令文本/正则 → 当前存活的 `bash` identity registration。普通调用在 `tools/execute` 返回时释放；DSH job registry 保留的调用（`run_in_background` / 超时转后台）由 Worker 持有登记，每 120 秒重发同一 call/digest 续期，宿主在原 id 上延长 TTL（受会话 token 过期约束），直到 `job/settled`/`removed`、Worker 代次轮换或 24 小时硬上限。 |
| 归属（分组） | 同一 Bot 的多个活动登记（多个后台 job 或 chat/task 会话）按 Bot 归组，选一条送审；只有不同 Bot 之间才用外层命令主机文本消歧，仍不唯一 → `bot_egress_ambiguous`。会话凭证失效 → `bot_egress_unattributed`。 |
| 归属（B：失败关闭兜底） | 无存活登记时，宿主读取 `PhoneDSHHost` 的 journal turn state（排除活动 Bot 会话）：有工作台回合 → `notBot`（工作台不变）；无工作台回合且恰好 1 个活动 Bot → 该 Bot 送审；多个活动 Bot → `bot_egress_ambiguous` 拒绝；无活动 Bot → `bot_egress_unattributed` 拒绝。已归属的 job 写不经过 B。 |
| 后台 job 续期 | Worker `identity-bridge` 在 `tools/execute` 识别 `background`/`promoted` bash 结果；不再在返回边界 cancel，改为 `ctx.jobs.events` 监听 settled/removed、heartbeat 续期、24 小时上限和插件 dispose 清理。宿主 `BotAttributionRegistry.refresh` 只延长同一 id，不发布第二个登记。 |
| 审批卡 / Grant | `tool=egress`、`operation=egress.<lowercase method>`、`resource=host=<lowercase host>`；`alwaysScope=until`。同一主机+方法复用 `until` Grant；`allow_once` 在放行后立即消费。 |
| 拒绝/超时/取消 | 明确错误：HTTP 403；`xl_error.code`/`X-PDSH-Proxy-Error` 统一 `egress_approval_denied`，`error.code` 保留具体原因（拒绝/超时/取消 `egress_approval_denied`，歧义 `bot_egress_ambiguous`，未归属 `bot_egress_unattributed`）。不解析凭据、不开 socket、不写 response log。审批默认 300 s。 |
| 取消传播 | 消费者取消 → `BotApprovalCoordinator.cancel` 写 `approval.decided`（`status=cancelled`、`reason=consumer_cancelled`）；`workerRestarted`/Bot 删除沿用 `cancelAll`（`approval unavailable`）。 |
| 重定向 | 被批准的写不跟随 3xx；原 3xx 返回，调用方对新目标重新走审批。GET/HEAD 与非 Bot 写不变。 |
| Bot 工作区根 | 契约值 = `BotWorkspaceLayout.botRoot(botId:)` = `/dsh/workspace/.dshbot/agents/<safe botID>`；chat/task/routine 共享该 Bot 根，不同 Bot 隔离。根内 `write`/`edit` 无结构审批卡；根外是跨出口。 |
| 文件 Grant | `write`/`edit` 的 resource 从含参数摘要的 `unclassified` 改为 `dir=<标准化绝对父目录>`；operation `file.write`/`file.edit`；同一目录复用 `until` Grant。`..` 在包含判断前解析；缺失 `file_path` 为 `tool.unclassified`、`known=false`、session 作用域、fail-closed。 |
| 网络正则 | `curl-post`/`network-egress` 从安全判断改为提示/移除；`rm -rf`、`git reset --hard`、`find -delete` 保留为审批卡提示。 |
| 兼容 | 无新 schema/路由/字段。旧 App + 新 Worker：旧宿主仍按自己的命令分析器出卡，但不支持续期（重复注册只返回旧 id），job 超过 330 秒仍落入旧行为；新 App + 旧 Worker：没有 job 登记续期，但新宿主 B 兜底在无工作台回合时按单/多 Bot 处理；旧 App + 旧 Worker 保持原状。App/Worker 同 bundle 是支持组合。 |

自检（`spec/README.md` §5.1）：没有第二种 envelope、别名或错误码；`egress_approval_denied` 与 `host_not_allowed`/`mcp_egress_forbidden` 语义不同（前者是“Bot 写未获用户授权”，后者是“主机不在 allow-list”，`mcp_egress_forbidden` 是“调用方没有 MCP 出口能力”）；新增效果字段复用 `tool-effects.schema.json`；没有删除/重用名称。

## 3. 兼容性与发布

| Producer → Consumer | 行为 |
| --- | --- |
| 旧 App + 旧 Worker（回滚） | 保持 WP3 现状：命令正则可被绕过。回滚不迁移任何新数据。 |
| 新 App + 旧 Worker | 旧 Worker 仍按旧正则发送 `/approval`；新宿主用新分析器计算为空效果 → `auto-policy`，但新宿主在 `/v1/http` 出口对活动 `bash` 登记发起审批。网络写仍被把关；不会静默放行。 |
| 旧 App + 新 Worker | 新 Worker 对网络 bash 发送空效果 `/approval`；旧宿主用自己的旧分析器重算命令并出卡。`write` 根内同理由旧宿主继续出卡。安全边界不低于旧宿主。 |
| 新 App + 新 Worker | 本契约完全生效：网络写在出口审批，根内写免结构卡，根外写目录 Grant。 |

- 版本决定：无 breaking；新增的是宿主内部 seam 和 phone-only 向量，不要求 Kotlin/Android 实现。混合版本不宣称修复完整性，但不新增静默放行路径。
- bundle/image 顺序：Worker 插件与 App 同 bundle；`phone-bundle-fresh` 在改动后重建。SQLite/BotEvent/会话日志/Grant 恢复格式不变，可回滚到旧 App（旧 App 忽略新效果，按旧规则重算）。

## 4. 分工与证据

- 独占路径：本单元修改 `spec/**`、`docs/protocol-changes/**`、`Sources/PhoneDSHGateway/**`、`Sources/PhoneDSHLoopback/**`、`Sources/PhoneDSH/{PhoneMCPAccessSettings,PhoneDSHHost}.swift`、`Sources/PhoneDSHBot/Authz/**`、`Sources/PhoneDSHBot/MCP/{BotApprovalCoordinator,BotMCPRuntime}.swift`、`plugins/bot-runtime/src/approval-gate.ts`、probe app 接线、对应测试与 fixtures。
- Swift 真实路径：`BotEgressApprovalTests` 驱动真实 `BotMCPRuntime.registerIdentity` + `BotApprovalCoordinator`（含拒绝、always Grant 复用、取消、同 Bot 分组、不同 Bot 歧义、无工作台回合的单 Bot 送审/B 兜底、refresh 延期、GET/HEAD、WP3 的四种写法）；`BotEgressApprovalGatewayTests` 驱动真实 `ModelGateway`（拒绝不触上游、允许触上游、GET/HEAD 不调用、模型端点豁免、重定向不跟随）；`BotGoldenVectorTests` 驱动真实 `BotApprovalPatternAnalyzer`；`BotToolEffectClassifier` 目录效果由同一文件覆盖。
- Eval runner wiring：`scripts/ci/bot-e2e/harness/Tests/BotEvalTests/BotEvalRunner.swift` 现在把 mock model base 的 `ModelGatewayConfiguration.standardModelEndpoints` 传给 `replaySafeModelEndpoints`，与生产 App 一致；否则 B 兜底会把 mock 模型请求误判为 Bot 工具网络写。这是测试装配修正，不放宽契约。
- Worker 真实路径：`bot-identity-approval.test.ts` 驱动真实 `approval-gate.ts` 与 `defineTool`（根内空效果、根外目录效果、缺失路径 fail-closed）；`bot-egress-job-attribution.test.ts` 驱动真实 identity bridge + 工具管线 + fake `ctx.jobs` 与真实 `dsh-jobs-local`（background/promoted 登记跨工具返回存活、heartbeat 续期、settled 清理、foreground 立即清理）；`bot-egress-spike.test.ts` 驱动真实 `runCurl` + WorkerShell（脚本文件/变量拼接都到达 `/v1/http` 并有 POST 目标）。
- 共享 fixtures：`mcp-egress.phone.json` 的 `egress-approval` 37 valid / 43 invalid（含 Grant 命中、一次/always、GET/HEAD、模型端点、workbench、消歧、后台 job 存活登记、同 Bot 多登记、无登记单 Bot/多 Bot/无 Bot、workbench 回合、拒绝、超时、歧义、未归属、PUT/PATCH/DELETE）；`grant-directory` 同上文件（根内、同目录、session Grant、无 Grant、异目录、旧参数摘要、traversal、异工具、拒绝、缺失路径）。`approval-patterns.phone.json` 6 条降级。
- Exact commands → result（本单元实际运行）：
  - `swift test --disable-sandbox --filter 'PhoneDSHBotTests|PhoneDSHGatewayTests|BotMCPEgressCredentialInjectionTests|MCPEgressPolicyTests'` → PASS（632 tests，0 failures）。
  - `swift test --disable-sandbox --filter 'PhoneDSHLoopbackTests'` → PASS（116 tests，0 failures；八类 taxonomy 与具体 Bot 出口原因）。
  - `cd plugins && npm run typecheck` → PASS。
  - `cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"` → PASS（89 tests：88 pass，1 pre-existing skip，0 fail；0 todo）。
  - `python3 spec/bot/v1/tools/validate_vectors.py` → PASS（`mcp-egress` 37 valid / 43 invalid / 20 mutation checks；`approval-patterns` 降级 overlay PASS）。
  - `python3 spec/tools/bot/check_golden.py --root .` → PASS（31 files，22 upstream，9 overlays）。
  - `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS（phone-cross-tree 8/8 invariants，87 Python tests）。
  - `bash scripts/ci/check.sh --only phone-bundle-fresh,phone-license` → PASS（rebuilt `worker-entry.js`/`tool-worker*.js`/`image.tar.gz` first）。
  - `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/selftest.json --upstream mock` → PASS（10/10 scenarios）。
  - `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/catalog.json --only BOT-E05 --upstream mock` → PASS（approval_requests main=1；files LOCAL_OK/REVISED_MARKER；echo POST /wp2/e05=0）。
  - `xcodegen generate` + `CFFIXED_USER_HOME=/tmp/s2-s4a-home HOME=/tmp/s2-s4a-home PDSH_WITH_SHELL=1 OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/s2-s4a-dd -packageCachePath /tmp/s2-s4a-spm -clonedSourcePackagesDirPath <repo>/.build build CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` → **PASS**（`** BUILD SUCCEEDED **`）。
- 未验证：真机、Android/HarmonyOS、真实模型、锁屏/铃声、设备唤醒；跨进程 job id 对账（A 失效 + 工作台回合并发的残余风险）。

## 5. 修订记录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| PC-20261111-bot-egress-approval@1 | s2-s4a contract owner | 首次冻结：出口写审批、工作区根、目录 Grant、正则降级、向量 | Swift 宿主、Worker/plugins、docs/spec；Android/HarmonyOS 无 Bot runtime，记录为 not started |
| PC-20261111-bot-egress-approval@2 | s2-s4a contract owner | 堵 Remaining risk ①：A（job 生命周期登记续期、同 Bot 分组）+ B（无登记时按工作台回合失败关闭/单 Bot 送审/多 Bot 拒绝）；向量新增 job-lifecycle、single-bot、multi-bot、workbench-turn | Swift 宿主、Worker/plugins、docs/spec；Android/HarmonyOS 不变 |
