<!-- SPDX-License-Identifier: MIT -->

# MCP 出口与会话凭证契约冻结（Bot 身份冒用修复，P05/P16/P26）

```yaml
change: PC-20261110-bot-mcp-egress-capability
contracts: [P05, P16, P26]
status: frozen
breaking: false
version_decision: Contract freeze only; no schema file, wire frame, route or BotEvent shape changes. The fixes are additive private fields and one Worker environment variable, shipped together in the same App bundle. Mixed old/new pairs fail closed for the Bot tools instead of claiming the fix.
base: 31c0cab73058e801fac1a145c7f6201d7428d5d2
contract_revision: spec/bot/v1/mcp-endpoint.md@mcp-egress-capability-v1 + spec/v1/native-mcp.md@mcp-egress-capability-v1 + Sources/PhoneDSH/PhoneDSH.swift@mcp-egress-capability-v1 + spec/bot/v1/golden/mcp-egress.phone.json@mcp-egress-capability-v1
```

Protocol impact: P05; P09: none — scripts/ci/check.sh 只由已合入的 WP1 评测运行器改动，本单元未改; P16; P25: none — 只新增离线 phone-only 向量及 manifest/校验器登记，event-envelope、dshbot-pin 和事件编码未改; P26; P27: none — 新向量不涉及 row/user-action/projection，同名路径由 P26 的手机专属向量批次触发。

## 1. 识别与角色

- **Trigger → 现况 → 期望。** 模型写的 `curl` 经宿主 `/v1/http` 打到 Bot MCP 四条环回路由或用户配置的精确 MCP 路由时，宿主凭精确 URL 注入真实凭据；`/identity/register` 又只相信请求体自报的 `sessionId`，于是 Task 会话可登记主对话、Bot 可登记另一个 Bot，`tools/call` 也不查 per-caller 目录。本变更冻结三层修复：A 宿主出口要求 Worker 受信 MCP 客户端携带跳内出口凭证，B 身份登记绑定宿主签发的会话凭证，C `tools/call` 按认领 principal 的目录检查工具。
- **责任。** 本单元 `s0-wpf0` 是 AGENTS.md §3.1 的 coordinator / contract owner，只冻结契约、共享向量和变更记录，不改生产实现。WPF1 是 A 的宿主＋插件实现者；WPF2 是 B、C 的宿主＋插件实现者，按修复设计等 WP4 合入后开始。
- **Owning contracts / schemas / fixtures。**
  - P26 端点与身份：[spec/bot/v1/mcp-endpoint.md](../../spec/bot/v1/mcp-endpoint.md) §1.1、§2、§3、§4、§6；[spec/bot/v1/README.md](../../spec/bot/v1/README.md) §2.2、§8.1。
  - P05 网关：[spec/v1/native-mcp.md](../../spec/v1/native-mcp.md) 的「MCP egress capability (phoneDSH App/Worker)」段（App/Worker 扩展，不进入 Kotlin `golden/gateway` 语料；完整端点条款在 `mcp-endpoint.md` §1.1）。
  - P16 Worker 环境：`PhoneDSHWorkerEnvironment.mcpEgressToken`（[PhoneDSH.swift](../../Sources/PhoneDSH/PhoneDSH.swift)）。
  - `phone/botClaimSession` 方法语义（P26）：[mcp-endpoint.md](../../spec/bot/v1/mcp-endpoint.md) §3 与 [README §2.2](../../spec/bot/v1/README.md)；P14 的 `/api/remote.mux` 传输 envelope 不变，只增加一个可选方法参数。
  - 共享向量：新增 [mcp-egress.phone.json](../../spec/bot/v1/golden/mcp-egress.phone.json)，`upstream: []`；登记进 [export-manifest.json](../../spec/bot/v1/export-manifest.json)、[validate_vectors.py](../../spec/bot/v1/tools/validate_vectors.py) 与 [check_golden.py](../../spec/tools/bot/check_golden.py) 的显式 phone-only 列表。
- **受影响 producer / consumer。**
  - Swift 宿主：`PhoneDSHHost`（Worker 环境下发）、`PhoneMCPAccessSettings`（`MCPEgressPolicy`/`PhoneMCPCredentialProvider`）、`PhoneDSHGateway`（出口校验与注入）、`PhoneDSHBot`（会话凭证、身份登记、`tools/call` 目录）。
  - Worker/TS：`plugins/profile` 两份 profile 的 `mcp-phone` 挂载、`plugins/phone-mcp/src/manager.ts`（用户 MCP 挂载）、`plugins/bot-runtime/src/{identity-bridge,approval-gate,sandbox-approval,caller-catalog}.ts`；`volatile-mcp` 经 `mcp-phone` 挂载，不单独加头。
  - App 装配：`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift` 与 `ChatModel.swift` 的 Worker env / Bot 出口接线。
  - Android / HarmonyOS：没有 Bot runtime，A/B/C 均 `not started`；非 Bot 的 `/v1/http`、Worker env 行为不变。

## 2. 第一步实测：用户配置的 MCP 路由会不会注入用户凭据

**结论：会。** 不是读代码推断。

测试：[Tests/PhoneDSHTests/BotMCPEgressCredentialInjectionTests.swift](../../Tests/PhoneDSHTests/BotMCPEgressCredentialInjectionTests.swift)。

- `testUserConnectorRouteResolvesTheStoredHostHeader`（通过）：真实 `PhoneMCPAccessSettings` → `MCPHostConfiguration.apply` → `MCPEgressPolicy` → `PhoneMCPCredentialProvider`，精确用户 URL 的 `Credential.kind` 就是 Keychain 里存的 header map。
- `testKnownFailureModelWrittenRequestGetsTheUserConnectorCredential`（`XCTExpectFailure`，当前按设计失败）：真实 `ModelGateway` 收到一个按 curl shim 形状构造的 `POST /v1/http` 请求（Worker `Authorization: Bearer <loopback>`、固定 JSON body），目标正是用户登记的精确 MCP URL。实测结果是 **200**，本地 connector 收到 1 个请求，且带上：
  - `authorization: Bearer wpf0-fixture-user-connector-token`
  - `x-connector-key: wpf0-fixture-connector-key`

即：用户保存的凭据被宿主注入，模型写的 `curl` 不需要知道它。WPF1 翻转该测试后应得到 403 `mcp_egress_forbidden`、0 个上游请求，不应再看到这两个值。实际运行输出见 §6。

Worker 侧形状测试：[plugins/tests/bot-egress-spike-connector.test.ts](../../plugins/tests/bot-egress-spike-connector.test.ts) 用真实 `runCurl` 与同一类 `/v1/http` 夹具，确认 `curl -X POST --data-raw ... <user-connector>/mcp?session=...` 发出的是生产形状：`POST /v1/http`、`x-pdsh-target-url` 保持精确用户 URL（含 query）、loopback `Authorization` 是 channel bearer、body 原样到达。该测试通过。

**代码依据（与实测一致，不是单独推断）：**

- `Sources/PhoneDSH/PhoneMCPAccessSettings.swift:120-310` 的 `MCPEgressPolicy` 只按 scheme/host/effective-port/normalized-path 授权；`:316-336` 的 `PhoneMCPCredentialProvider` 对任何命中的 route 返回其 header map。用户 route 与 Bot 四条 route 共用同一个 policy/provider（`:209-220`）。
- `Sources/PhoneDSHGateway/ModelGateway.swift:679` 把 `egressAuthorizer.allowsEgressHost(url)` 记为 `admittedByMCPGrant`；`:695-705` 解析 credential；`:1145-1172` 的 `makeURLRequest` 丢掉 Worker 的 `Authorization`、注入 host credential，并丢掉所有 `x-pdsh-*` 头。注入路径不区分调用方。
- 因此修复 A 必须覆盖 `MCPEgressPolicy` 命中的**所有**精确 MCP route，而不只是 Bot 四条；否则用户连接器仍可被模型 `curl` 借用用户凭据。这也是本契约 §1.1 的写法。

**安全前提（Q1）复核：** WP3 的 `plugins/tests/bot-egress-spike.test.ts` Q1 实测 bash 子进程、WASI python、PTC、web_fetch 都拿不到现有 token 真值；DSH 的子进程环境过滤 `/KEY|PASSWORD|SECRET|TOKEN/i`（`/private/tmp/dsh-0.2.2/packages/subprocess/subprocess/lib/index.js:32,52`，`plugins/subprocess-xl/src/local.ts` 使用它）。新变量名含 `TOKEN`，同样被过滤。`curl`、`git`、WASI XHR 桥、PTC guest 都不会替模型加 `X-PDSH-MCP-Egress`。本单元没有发现可读途径；若 WPF1/WPF2 发现，按 §1.1 停下报告，不加 fallback。

## 3. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| A 出口凭证值 | 无 → `PDSH_MCP_EGRESS_TOKEN`，宿主每次启动生成至少 128-bit 随机值，经与 `PDSH_CHANNEL_TOKEN` 相同的 `?env=` 机制下发（`PhoneDSHHost.workerEnvironment`；P16 `PhoneDSHWorkerEnvironment.mcpEgressToken`）。不是 loopback/channel token、Bot bearer 或占位符。 |
| A 跳内头 | 无 → `X-PDSH-MCP-Egress: <value>`。必须带的客户端：profile `mcp-phone`（两份 profile）、`phone-mcp` 用户挂载、`identity-bridge`（register/cancel）、`approval-gate` 的共享 `postApproval`（覆盖 sandbox-approval）、`caller-catalog`（tools/list）；`volatile-mcp` 经 `mcp-phone`。通用 `/v1/http`、curl shim、git、WASI XHR、PTC 不得加。 |
| A 宿主校验 | 无 → 目标命中 `MCPEgressPolicy` 精确 route 时，在 credential 解析和 `makeURLRequest` 之前常量时间比较；缺失/空/错/占位符/大小写变化 → 403 `X-PDSH-Proxy-Error: mcp_egress_forbidden`，body `{"error":{"code":"mcp_egress_forbidden","message":"the MCP egress credential is missing or invalid"}}`；不解析/不注入凭据、不开 socket、不写 response log。成功时该头由既有 `x-pdsh-*` 规则剥离，绝不进上游。 |
| A 覆盖范围 | Bot 四条 → Bot 四条 ＋ 所有用户配置的精确 MCP route（实测理由见 §2）。 |
| A 秘密边界 | 无真实值进 Worker → 真值只存在宿主内存和 Worker `process.env`；不进日志/事件/审计/持久化设置/上游请求。宿主重启或 loopback 重启轮换；同一 host run 内的 Worker 重启/引擎重建不轮换并重新下发。`PDSH_PHONE_MCP_TOKEN` 的 placeholder 语义保留，且永不被当作出口凭证。 |
| B 会话凭证 | 无 → 宿主签发 principal 时已有随机 token（`BotTokenRegistry`，`dshg_`），通过 `phone/botClaimSession` 的新可选请求字段 `sessionToken` 交给 Worker；Worker 只在插件内存按 session 保存；`identity-bridge` 在 `/identity/register` body 上送 `sessionToken`。宿主按 token 解析 principal，`principal.sessionId` 必须等于 body `sessionId`；缺失/未知/撤销/过期/不一致 → HTTP 200 `{"ok":false,"error":"unauthorized"}`，不登记。body `sessionId` 不自证。 |
| B 生命周期 | `issueSession` 重签先撤销旧 token；`revoke`/`revokeSession`/`revokeBot`/过期/Bot 删除使 token 失效；Worker 重启丢失内存凭证，宿主必须带当前 token 重新 claim 活跃 session，否则 fail-closed；`gb-` 前缀只表示命名空间归属，claim 前没有凭证 → 登记失败 → fail-closed（与「MCP 目录不可达」注释一致）。 |
| B Remote 字段 | `phone/botClaimSession` request: `{sessionId}` → `{sessionId, sessionToken?}`；response 仍 `{ok, sessionId}`。RPC 仍只是 Worker 本地归属登记，不是独立认证边界。 |
| C `tools/call` | 只做 attribution → attribution 后还要检查 bare tool 是否在 `toolDefinitions(callerBotID: principal.botId)`（与 `tools/list` 同一 per-caller 目录）；不在 → `isError:true`、`structuredContent.error.code="permission_denied"`，不执行 effect/handler。未知工具仍 `unknown_tool`；native 转发工具保持 native 授权；`CreateTeammate` 主 Bot 检查保留为第二道。 |
| 兼容 | 不加 schema、路由、JSON-RPC method、frame。新增字段均可选；新 App＋旧 Worker 全部 Bot/MCP 精确 route fail-closed（无出口头/无会话 token）；旧 App＋新 Worker 修复不生效但无数据损坏；App 与 Worker 同 bundle 升级。旧 `/dsh/home/mcp.json`、BotEvent、session log、SQLite Bot store 不变。 |

自检（`spec/README.md` §5.1）：没有第二种 envelope、别名或错误码；`mcp_egress_forbidden` 与既有 `forbidden`/`host_not_allowed` 语义不同（前者是「调用方没有出口能力」，后者是「主机不在 allow-list」）；新增字段都有缺省/旧读者行为；没有删除或重用名称。

## 4. 兼容性与发佈

| Producer → Consumer | 行为 |
| --- | --- |
| 旧 App + 旧 Worker（回滚） | 保持漏洞现状：宿主继续注入精确 route 凭据，`/identity/register` 继续相信自报 `sessionId`。回滚不迁移任何新数据。 |
| 新 App + 旧 Worker | 旧 Worker 不送 `X-PDSH-MCP-Egress`、不送 `sessionToken`。所有精确 MCP route 在出口 403（Bot 工具、identity/approval、用户连接器均 fail-closed），身份登记 `unauthorized`。native-only 且从不使用精确 MCP route 的配置不受影响。此组合不得宣称已修复。 |
| 旧 App + 新 Worker | 旧宿主不校验，仍注入凭据；新 Worker 多送的出口头被旧宿主 `x-pdsh-*` 规则丢弃，多送的 `sessionToken` 被旧 `/identity/register` 忽略。漏洞仍在，但无数据损坏；不是支持的安全部署。 |
| 新 App + 新 Worker | A/B/C 全部生效。 |
| 旧持久化数据 → 新／回滚 | 出口凭证与会话凭证都是 host/Worker 内存；不新增持久字段。`/dsh/home/mcp.json`、BotEvent 行、session log、SQLite Bot store 不变。回滚只需换回旧 build，不会留下可被新 build 复用的旧凭证。 |
| Android / HarmonyOS | 无 Bot runtime；A/B/C `not started`，不要求 `PDSH_MCP_EGRESS_TOKEN`。非 MCP `/v1/http` 与 P16 既有 env 行为不变；未来若承载 Worker Bot runtime，必须实现本契约后才能声明支持。 |

## 5. 共享向量与校验

- `spec/bot/v1/golden/mcp-egress.phone.json`（`upstream: []`）：
  - `egress`：Bot 四条正确值、用户 route 正确值、query 正确值、头名大小写、非 MCP 目标、不同端口/sibling path；无效：无头、query 无头、错值、两种 placeholder、值大小写、空值、尾随空格、`Bearer ` 前缀。
  - `identity`：正确主对话/Task、轮换后的新值；无效：无/空/别的会话/`sessionId` 不一致/已撤销/过期/虚构/placeholder/大小写/轮换旧值。所有拒绝都是 `unauthorized`。
  - `tools-call`：非主 Bot `SendToAgent`、主 Bot `CreateTeammate`、普通 P0、`FishAction`；无效：非主 Bot `CreateTeammate`（含 `mcp__phone__` 前缀）、未知工具、大小写变化、空工具。
- `validate_vectors.py`：参考实现精确 route 匹配、header 常量值比较、token 登记表 principal 解析（含 revoked/expired/rotate）、per-caller 目录；强制每个 suite 的 valid/invalid 边界覆盖；11 个 mutation（改 host token、placeholder 被接受、删用户 route、撤销被接受、session 不一致被接受、token 大小写折叠、hidden tool 被接受、未知工具改成已知、重复 case、翻转 valid、删边界）必须被拒绝。
- `check_golden.py` 只在 `PHONE_ONLY_VECTORS` 登记新文件；`export-manifest.json` 的 `files`/`phoneOverlays`/`sha256` 同时登记。
- 手机专属向量不替代 runtime conformance：WPF1/WPF2 必须用真实 `MCPEgressPolicy`、`PhoneMCPCredentialProvider`、`ModelGateway`、`BotMCPRuntime`/`BotGateway` 和真实插件代码跑正反向。

## 6. 运行与证据（本单元实际执行）

```text
swift test --disable-sandbox --filter BotMCPEgressCredentialInjectionTests
  PASS: 2 tests, 0 failures; 1 test carries 5 expected failures recording the
  current injection (200 + the user connector header reached the local server).

cd plugins && node scripts/run-tests.mjs "tests/bot-egress-spike-connector.test.ts"
  PASS: 1 test.

python3 spec/bot/v1/tools/validate_vectors.py
  PASS: turn-origin 8/27 + 7 mutations; mcp-egress 16/25 + 11 mutations.

python3 spec/tools/bot/check_golden.py --root .
  PASS: 29 files, 22 upstream, 7 overlays.

python3 spec/tools/bot/check_golden.py --root . --checkout /tmp/phonedsh-bot-spec --sha bf4075b0a2e8092b04b726c59a7b085d5a37e6f6
  FAIL (NOT_RUN for the byte-identical claim): /tmp/phonedsh-bot-spec is not a
  git checkout; export-vectors.mjs aborts at `git rev-parse HEAD`. The offline
  --root check above passed. No upstream file was changed.

CI_PROTOCOL_BASE=31c0cab73 bash scripts/ci/check.sh --only phone-spec,phone-cross-tree
  PASS: phone-spec (latest run 15s), phone-cross-tree (latest run 25s) (8/8 invariants, registry byte-identical,
  registry 27 contracts, schema diff 89 schemas / 0 breaking, 87 cross-check tests OK).

python3 scripts/ci/protocol_impact.py --base 31c0cab73 --body-file docs/protocol-changes/PC-20261110-bot-mcp-egress-capability.md
  PASS: 6 triggered IDs (P05, P09, P16, P25, P26, P27), 52 changed paths.

bash scripts/ci/check.sh --only phone-license
  PASS: 1s.
```

## 7. WPF1 / WPF2 路径与验收

### WPF1 出口凭证（A；依赖本冻结）

- Swift 宿主：`Sources/PhoneDSH/PhoneDSHHost.swift`（生成/下发 `PDSH_MCP_EGRESS_TOKEN`；同一 host run 内稳定）、`Sources/PhoneDSHGateway/ModelGateway.swift`（精确 route 命中后、credential 解析前校验；新 stable error；不注入、不转发）、`Sources/PhoneDSHGateway/GatewaySession.swift`（如校验放在 coordinator 的 isAllowed 前）、`Sources/PhoneDSHLoopback/HTTPEgressFailure.swift`（把 `mcp_egress_forbidden` 映射为 403 且不泄露值）、`Sources/PhoneDSH/PhoneDSH.swift`（本单元已加常量）、`examples/probe-app/PhoneDSHProbe/ChatModel.swift`（把 token 接进 production host configuration／egress validator 的组装）。
- Worker/TS：`plugins/profile/phone.cordis.patch.yml`、`plugins/profile/phone.worker.cordis.patch.yml`（`mcp-phone` 加 `X-PDSH-MCP-Egress`）、`plugins/phone-mcp/src/manager.ts`（用户 MCP 挂载 `mount()` 加头）、`plugins/bot-runtime/src/identity-bridge.ts`、`plugins/bot-runtime/src/approval-gate.ts`（共享 `postApproval`）、`plugins/bot-runtime/src/caller-catalog.ts`；`plugins/bot-runtime/src/sandbox-approval.ts` 经 `postApproval` 覆盖，只有需要单独读取 env 时才改。不要改 `plugins/shell-ext/src/curl.ts`、`plugins/wasi-toolbox/git/http.ts`、`plugins/wasi-toolbox/src/http-bridge.ts`、PTC 去加头。
- 测试：翻转 `Tests/PhoneDSHTests/BotMCPEgressCredentialInjectionTests.swift` 的 `XCTExpectFailure`；`plugins/tests/bot-egress-spike.test.ts` 的 Q2 `todo` 翻成普通断言；新增宿主的无头/错头/正确头/用户 route 测试；`plugins/tests/bot-egress-spike-connector.test.ts` 的夹具加出口门；覆盖 profile 与用户 MCP 挂载。
- 验收：`swift test --disable-sandbox --filter 'PhoneMCPAccessSettingsTests|MCPEgressPolicyTests|BotMCPEgressCredentialInjectionTests'`；`swift test --disable-sandbox --filter PhoneDSHBotTests`；`cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"`；`bash scripts/ci/check.sh --only phone-bundle-fresh`；`bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/selftest.json --results /tmp/pdsh-bot-eval-selftest`；`bash scripts/ci/bot-e2e/run.sh --scenario production-composition`；`bash scripts/ci/check.sh --only phone-bot-eval-catalog`。

### WPF2 会话凭证与 `tools/call` 目录（B、C；等 WP4 合入后开始）

- Swift 宿主：`Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`（先 `issueSession` 再 `claimOwnedSession(sessionId, sessionToken:)`；Worker 重启后重 claim）、`Sources/PhoneDSHBot/MCP/BotMCPHandler.swift`（`registerIdentity` 取 `sessionToken`；`tools/call` 的目录检查在 attribution 后）、`Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift`（`registerIdentity` 按 token 解析 principal；`execute` 先查 per-caller 目录；`identityForApproval` 仍按当前 incarnation）、`Sources/PhoneDSHBot/Gateway/BotGateway.swift`（token/principal 解析入口与 sessionId 一致性）、`Sources/PhoneDSHBot/MCP/BotMCPTypes.swift`（复用 `permission_denied`/`unauthorized`，不新增错误码）、必要时 `Sources/PhoneDSHBot/MCP/BotMCPHandler.swift` 的 header/body 解析辅助。
- Worker/TS：`plugins/bot-runtime/src/channel.ts`（`BotClaimSessionRequest` 加 `sessionToken?`，保存到 Worker 本地 owned-session 表）、`plugins/bot-runtime/src/bot-sessions.ts`（owned-session 表按 session 保存 token，仅内存；不改变 `gb-` 只读语义）、`plugins/bot-runtime/src/identity-bridge.ts`（登记 body 带 `sessionToken`；claim 前无 token → 不发或发空 → 宿主拒绝 → fail-closed）。
- 测试：翻转 `Tests/PhoneDSHBotTests/Security/BotEgressSpikeIdentityTests.swift` 的三个 `XCTExpectFailure`；新增 TokenRegistry 重签/rotate/revoke/Worker 重启/Bot 删除、`gb-` 未 claim、`tools/call` 非主 Bot `CreateTeammate` 与未知工具回归；`plugins/tests/bot-identity-approval.test.ts` 加 claim token/缺 token 用例；`plugins/tests/bot-egress-spike.test.ts` 的 Q3/Q4 `todo` 翻成普通断言。
- 验收：`swift test --disable-sandbox --filter BotEgressSpikeIdentityTests`；`swift test --disable-sandbox --filter PhoneDSHBotTests`；`cd plugins && node scripts/run-tests.mjs "tests/bot-identity-approval.test.ts"`；`cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"`；`bash scripts/ci/check.sh --only phone-bundle-fresh`。

## 8. 未验证 / 剩余风险

- 真机、真实模型、Android、HarmonyOS：`NOT_RUN`；本单元只在本机 macOS 26 arm64 跑 Swift/Node 测试与 spec 校验。
- 生产 App 单进程端到端（真实 WKWebView + 真 Worker + 用户连接器）：`NOT_RUN`；WPF1 的 `bot-e2e production-composition` 场景负责补。
- 真实 CPython WASI 的任意网络代码：WP3 仍为 `NOT_RUN`；本契约只依赖其环境不含 token 的实测结论。
- 设计风险：A 把出口门放在「精确 MCP route」上，所以用户连接器也在门内；这是实测结论要求的。若 WPF1 只保护 Bot 四条，用户连接器仍可被借用凭据，不得宣称修复。
- 设计风险：B 的 `sessionToken` 是 Worker 插件内存，Worker 重启会丢；宿主必须重 claim，否则整类 Bot 工具在重启窗口 fail-closed。实现不能为了可用性放宽成「凭 `gb-` 前缀放行」。
- 设计风险：`tools/call` 目录检查与 `tools/list` 必须共用同一解析；如果 WPF2 复制一份目录，会把「显示层」变成第二权威。本契约要求同一 `toolDefinitions(callerBotID:)`。
- 实现事实（WPF2 要处理）：`BotGateway.issueSession` 只返回 `BotGatewayPrincipal`，丢弃了 `BotTokenRegistry.issueSession` 返回的 `BotIssuedToken.token`；`BotDSHRemoteRuntime.createSession` 目前先 `claimOwnedSession` 后 `issueSession`。WPF2 必须先保留/取得 token（例如改用 `issueToken` 或调整返回值），再带同一 token claim；否则 B 无法实现。
- 契约放置：`spec/v1/gateway-security.md` 恰好 240 行（D16 cap），加任何行都会让 `phone-spec` 失败；因此 P05 的 egress 扩展写在 P05 owning contract `spec/v1/native-mcp.md` 的段末，完整端点条款在 `mcp-endpoint.md` §1.1。若审查坚持要 gateway-security 本体承载，需要另开 CCR 并压缩该文件，不能靠放宽 cap 解决。
- WPF0 的 known-failure 测试直接调用 `ModelGateway`；如果 WPF1 把出口门放在 LoopbackServer 的 `/v1/http` 入口而不是 gateway，该测试需要改成 loopback harness 才能翻转。契约只规定「credential 解析之前」，不强制内部位置；两种实现都必须让 `tests/bot-egress-spike-connector.test.ts` 的夹具同步。

## 9. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| mcp-egress-capability-v1 | s0-wpf0 coordinator / contract owner | 首次冻结 A/B/C；第一步实测用户连接器注入为「会」，因此 A 覆盖全部精确 route；新增 phone-only 向量与 P05/P16 条款 | WPF1（Swift 宿主＋plugins）、WPF2（Swift Bot＋plugins）、reviewer-integrator |
| mcp-egress-capability-v1 (WPF2 vector addendum) | s0-wpf2 implementer / contract owner for this revision | 补齐 `egress.valid` 缺少的 `/identity/cancel` 有效用例（原文件只覆盖四条 Bot 路由中的三条，与 §5 不一致）；同步 `export-manifest.json` 的 sha256；未改写任何既有条款 | WPF1 / WPF2（共享向量） |
