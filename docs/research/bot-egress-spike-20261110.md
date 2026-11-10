# Bot 出口安全 spike（WP3，2026-11-10）

状态：**取证完成，未修复任何生产代码**。本文的每个「能 / 不能」结论都来自本机实际运行；读代码得到的判断单独标为「推断」。
基线：`31c0cab73`（`origin/main`，含多 Bot PR #84）。工作树：`dsh-work/s0-wp3`，分支 `s0/wp3-egress-spike`。
环境：macOS 26.0（arm64）、Swift 6.3.2 / Xcode 26.5、Node 24.9.0、`PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2`。没有使用真实模型；模型回复全部由脚本/夹具发出。
凭据处理：本文只出现测试夹具值；任何真实 token 都不会被读取、打印或写入仓库。夹具值在引用输出中统一打码为 `****`。

## 0. 结论表

| 问题 | 结论 | 一句话证据 |
| --- | --- | --- |
| Q1 环境凭据 | **不能** | 模型可写的 bash / WASI python / PTC / web_fetch 都拿不到三个 token 的真值；`git` 会从 Worker `process.env` 消费 `PDSH_CHANNEL_TOKEN`，但不能读出或打印它 |
| Q2 借道宿主出口 | **能** | 真实 `curl` shim 经 `/v1/http` 到达 `/mcp`、`/identity/register`、`/identity/cancel`、`/approval`，四条路由都返回 200；宿主侧 admission 与真 bearer 注入各有既有 Swift 测试通过 |
| Q3 Task/routine 身份登记 | **能** | Task 会话登记主对话 `gb-main` 后，`UpdateMemory` 以 `source.kind=user-turn`、`sessionID=gb-main`、`trust=user` 写入共享 user / profile 记忆；直接 `/mcp` 绕过 Worker approval-gate，但宿主 `ask` 类工具仍要求 grant |
| Q4 跨 Bot | **能** | 一个 Bot 的会话用另一个 Bot 的 `gb-<botId>` 登记后，可读写对方的 agent 记忆；per-caller `tools/list` 不参与 `tools/call`，冒用主 Bot 身份可直接执行被隐藏的 `CreateTeammate` |

Q2/Q3/Q4 都是「能」，按 WP3 的要求属于应立刻另开修复工作包的高优先级问题。

---

## 1. Q1：Bot 会话里模型编写的代码能否读到环境凭据真值

### 1.1 装配事实（先标为推断，后文有运行时验证）

- 生产 Bot 装配把 `PDSH_CHANNEL_TOKEN` 和 `PDSH_DSH_LAUNCH_TOKEN` 设成同一个 **真实** loopback token（`Sources/PhoneDSH/PhoneDSHHost.swift:3514-3517` 的 `workerEnvironment`）。
- `PDSH_PHONE_MCP_TOKEN` 在 Bot 生产装配里是 **非秘密占位符** `phone-host-injects-bot-mcp-token`，真 bearer 只由宿主 `/v1/http` egress 注入（`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift:117`、`:229-233`；`Sources/PhoneDSH/PhoneMCPAccessSettings.swift:209-220`）。
- 子进程环境由 `plugins/subprocess-xl/src/local.ts:42` 的 `localEnvironment()` 从 DSH 的 `scrubbedParentEnv()` 产生；后者过滤 `/KEY|PASSWORD|SECRET|TOKEN/i` 和 `DSH_*`（`/private/tmp/dsh-0.2.2/packages/subprocess/subprocess/lib/index.js:32`、`:52`）。
- 这些是代码事实；下面逐项实跑。**注意**：`PDSH_CHANNEL_ORIGIN`、`PDSH_PHONE_MCP_URL` 不是秘密，子进程环境里仍然可见。

### 1.2 bash 的 `env` / `printenv` / `$VAR` / `/proc` / 可见文件

测试：`plugins/tests/bot-egress-spike.test.ts` 的 `Q1: the bash child environment carries no PDSH token value`。

实际运行的调用（节选，夹具已写入 `process.env`）：

```bash
printenv PDSH_CHANNEL_TOKEN
printenv PDSH_DSH_LAUNCH_TOKEN
printenv PDSH_PHONE_MCP_TOKEN
echo "$PDSH_CHANNEL_TOKEN"
cat /proc/self/environ 2>&1; cat /proc/1/environ 2>&1
ls -la /dsh/home 2>&1; cat /dsh/home/capabilities.json 2>&1
cat /dsh/home/mcp.json 2>&1; cat /dsh/home/settings.json 2>&1
```

同一夹具（`process.env` 里确实有这三个值，`PDSH_CHANNEL_ORIGIN` / `PDSH_PHONE_MCP_URL` 另设）下的实际结果：

```text
PDSH_CHANNEL_ORIGIN=http://127.0.0.1:9
PDSH_PHONE_MCP_URL=http://127.0.0.1:9/mcp
---
printenv_channel_rc=1
printenv_launch_rc=1
printenv_phone_rc=1

```

结论：**不能**。三个值都不在 bash 子环境里；`printenv` 全部退出 1；`$PDSH_CHANNEL_TOKEN` 为空；`/proc`、`capabilities.json`、`mcp.json`、`settings.json` 也没有值。非秘密的 origin/URL 可见，这正好说明「URL 可见」不等于「token 可见」。

> 测试保真说明：Node harness 的 `localEnvironment()` 会带上宿主进程的非敏感环境变量；生产 Worker 的 `process.env` 来自页面 `?env=`，没有这套宿主变量。这个差异与本题无关，断言只针对三个具名 token。

### 1.3 `git` 传输

测试：`Q1/Q2: git can reach /v1/http but exact-path admission blocks the Bot MCP routes`。
实际调用：

```text
GIT_TRACE_CURL=1 GIT_CURL_VERBOSE=1 GIT_TRACE=1 git clone http://127.0.0.1:<bot-port>/repo
```

实际结果（关键行）：

```text
fatal: the host allow-list rejected http://127.0.0.1:<bot-port>/repo/info/refs?service=git-upload-pack (403):
the repository origin is not permitted by the Worker egress policy. Nothing was written.
pdsh-shell: exit=128 program=git reason=network-denied
```

宿主 mock 看到的请求：

```text
host /v1/http authorization: Bearer ****
target: http://127.0.0.1:<bot-port>/repo/info/refs?service=git-upload-pack
bot listener: 0 requests
```

结论：**不能读到真值，但有一个重要旁证**。`git` 的 `HostHttpTransport`（`plugins/wasi-toolbox/git/http.ts:47`）在 `token` 为 `undefined` 时会回退到 Worker 的 `process.env.PDSH_CHANNEL_TOKEN`；因此 `git` 实际拿到了夹具 channel token（生产装配里对应真实 loopback token）并发出了 `/v1/http` 请求。它没有把 token 写进 stdout/stderr（`GIT_TRACE_CURL` 在 Worker 的 JS git 实现里没有实现），且它只能发出 `/info/refs`、`/git-upload-pack` 路径，不能命中四条精确路由。这个回退行为是 Q2 修复时应该一起收紧的入口。

### 1.4 WASI `python3`

测试：`WASI python: the guest environment never carries the loopback token`。
实际结果：`createLoopbackXhrTransport` 生成一次 `POST http://127.0.0.1:1/v1/http`，请求头 `Authorization: Bearer ****`、`X-PDSH-Target-URL: http://127.0.0.1:9/identity/register`；token 只在 bridge 内部，不出现在 guest 的 `defaultEnv`。既有 `plugins/tests/wasi-http-bridge.test.ts` 也断言 `defaultEnv`/preopens 不含 token。

结论：**不能读到真值**。但 WASI python 不是「无网络」：它有一条到 `/v1/http` 的同步 XHR 桥，理论上可发任意请求，见 Q2 的说明。真实 CPython 产物不在仓库，真实 python 代码执行没有跑（见 §7）。

### 1.5 PTC / `workflow-ptc` / `tool-workflow`

测试：`PTC: the QuickJS workflow guest has no fetch, process or environment`；另跑了既有端到端 `workflow-worker.test.ts` 的 `vm scope exposes ...`（PASS）。

实际 guest 结果：

```json
{"fetch":"undefined","process":"undefined","require":"undefined","worker":"undefined","env":"blocked","token":"blocked","escape":"blocked"}
```

结论：**不能**。QuickJS guest 里没有 `fetch`、`process`、`require`、`Worker` 或环境；官方 `WorkflowExecution` 只注入 `agent`/`parallel`/`pipeline`/`phase`/`log` 钩子，实际宿主 globals 由 `hideHostGlobals()` 清除（`plugins/workflow-worker/src/isolate-ports.ts:70`）。

### 1.6 `web_fetch`

测试：`web_fetch: the DeepSeek fetch provider sends the URL to its own API, not the host route`。
实际结果（替换 `globalThis.fetch` 后捕获）：

```text
POST https://api.deepseek.test/fetch
body = {"url":"http://127.0.0.1:<bot-port>/mcp"}
host /v1/http 请求数 = 0
```

结论：**不能**。`web_fetch` 的 provider 把目标 URL 发给 DeepSeek 的 Fetch API；它不经过宿主 `/v1/http`，也不把环境变量交给模型。默认 profile 下 `tool-web` 的 `fetch` 表达式在没有 `PDSH_WEB_SEARCH_PROVIDER=deepseek-search-api` / `PDSH_WEB_FETCH_PROVIDER=deepseek-fetch-api` 时是 `false`，即默认根本不注册 `web_fetch`（`plugins/profile/phone.worker.cordis.patch.yml:903-904`，这是读配置的推断；provider 行为已实跑）。

### 1.7 Q1 结论

**不能。** 模型编写的 bash / WASI python / PTC / web_fetch 都读不到三个 token 的真值；`PDSH_PHONE_MCP_TOKEN` 在 Worker 里本来就不是真值。唯一需要记录的是 `git` 的 `resolveHostHttp()` 回退会从 `process.env` 消费 `PDSH_CHANNEL_TOKEN`，但它不打印，也不能命中 Bot MCP 的精确路径。若要彻底减少 token 在 Worker 进程里的可达面，可把 channel client 的 token 收进闭包而不是 `process.env`；这不改变 Q1 的结论。

---

## 2. Q2：模型代码能否经宿主 `/v1/http` 触达 Bot MCP 的四条环回路由

### 2.1 生产链路

- Worker 侧：`curl` shim 没有 socket，只把请求变成 `POST <loopback>/v1/http`，用 `X-PDSH-Target-URL` / `X-PDSH-Target-Method` 指定上游，并把 channel token 放在 loopback hop 的 `Authorization`（`plugins/shell-ext/src/curl.ts:91-115`、`:329-342`）。
- 宿主 loopback：`/v1/http` 去掉 Worker 的 `Authorization`，把 `X-PDSH-Upstream-Authorization` 保留给上游（`Sources/PhoneDSHLoopback/LoopbackServer.swift:590-611`）。
- 宿主 gateway：`egressAuthorizer?.allowsEgressHost(url)` 是 MCP 精确授权的入口（`Sources/PhoneDSHGateway/ModelGateway.swift:679`）；`makeURLRequest` 丢掉 Worker 凭证后注入 host credential（`:1145-1172`）。
- Bot 装配把 `MCPEgressPolicy` 同时交给 `egressAuthorizer` 和 `PhoneMCPCredentialProvider`，并用 `grantBotRuntimeEndpoint` 为四条路径登记真 bearer（`Sources/PhoneDSH/PhoneMCPAccessSettings.swift:209-220`、`:316-330`；`examples/probe-app/PhoneDSHProbe/ChatModel.swift:1252-1257`、`:1281`）。

### 2.2 实际运行：curl shim 打到四条路由

测试：`plugins/tests/bot-egress-spike.test.ts` 的 `Q2 known failure: model-written curl reaches the four Bot MCP routes`（当前标 `todo`，因为断言的是「应当被拒绝」）。

实际调用（`runCurl` 的真实 production shim；四个路径各一次，body 按路由形状分别构造）：

```text
curl -sS -X POST --data-raw '{"jsonrpc":"2.0","id":"wp3","method":"tools/call"}' \
  http://127.0.0.1:<bot-port>/mcp
curl -sS -X POST --data-raw '{"runtimeId":"phone-worker","sessionId":"gb-main","callId":"wp3","name":"UpdateMemory","argsDigest":"00"}' \
  http://127.0.0.1:<bot-port>/identity/register
curl -sS -X POST --data-raw '{"id":"registration-1"}' \
  http://127.0.0.1:<bot-port>/identity/cancel
curl -sS -X POST --data-raw '{"callId":"wp3"}' \
  http://127.0.0.1:<bot-port>/approval
```

实际结果（原样摘录，token 打码）：

```text
model-written curl reached ["/mcp","/identity/register","/identity/cancel","/approval"];
results=[
 {"path":"/mcp","stdout":"{\"jsonrpc\":\"2.0\",\"id\":\"spike\",\"result\":{\"structuredContent\":{\"ok\":true}}}","exitCode":0},
 {"path":"/identity/register","stdout":"{\"ok\":true,\"id\":\"registration-1\"}","exitCode":0},
 {"path":"/identity/cancel","stdout":"{\"ok\":true,\"allowed\":false}","exitCode":0},
 {"path":"/approval","stdout":"{\"ok\":true,\"allowed\":false}","exitCode":0}
];
seen=[
 {"route":"host","url":"/v1/http","authorization":"Bearer ****","target":"http://127.0.0.1:<bot-port>/mcp"},
 {"route":"bot","url":"/mcp","authorization":"Bearer ****"},
 ... 其余三条同形 ...
]
```

该测试的 host 端是一个**按生产语义搭建的 Node loopback 夹具**：校验 channel bearer、只放行四个精确路径、丢掉 Worker Authorization、注入 Bot bearer，再转发到 Bot 监听器。它证明的是 `curl` shim 的请求形状和四条路径的通过性；**宿主真实 loopback + gateway 的 admission/注入**由下面的既有 Swift 测试分别证明。

### 2.3 宿主侧真实 Swift 证据（实际运行）

```bash
swift test --disable-sandbox --filter \
  'PhoneMCPAccessSettingsTests/testBotRuntimeEndpointRoutesTokenOnlyToExactLocalPaths|MCPEgressPolicyTests/testExactURLAccessDropsTheWorkerPlaceholderAndInjectsScopedHeaders|BotMCPHTTPTests/testIdentityCancelAndApprovalRoutesAreUsableOverHTTP'
```

实际结果：

```text
Test Case '-[PhoneDSHTests.PhoneMCPAccessSettingsTests testBotRuntimeEndpointRoutesTokenOnlyToExactLocalPaths]' passed
Test Case '-[PhoneDSHGatewayTests.MCPEgressPolicyTests testExactURLAccessDropsTheWorkerPlaceholderAndInjectsScopedHeaders]' passed
Test Case '-[PhoneDSHBotTests.BotMCPHTTPTests testIdentityCancelAndApprovalRoutesAreUsableOverHTTP]' passed
Executed 3 tests, with 0 failures
```

- `PhoneMCPAccessSettingsTests`：四条精确路径都被 `allowsEgressHost` 放行，且 `PhoneMCPCredentialProvider` 对这四条返回真实 bearer（`testBotRuntimeEndpointRoutesTokenOnlyToExactLocalPaths`）。
- `MCPEgressPolicyTests`：gateway 对精确 MCP URL 丢掉 Worker 的 `Authorization`，注入 scoped header（`testExactURLAccessDropsTheWorkerPlaceholderAndInjectsScopedHeaders`）。
- `BotMCPHTTPTests`：`/identity/register`、`/identity/cancel`、`/approval` 以及 `/mcp` 在带上真 bearer 时可用（另有 20 个工具、405/404/401 的既有覆盖）。

**未跑的一环**：没有在 iOS Simulator 里把「生产 `BotRuntimeComposition` + 真 Worker」这一整套端到端跑一遍。分段证据覆盖了 shim → loopback → gateway → Bot listener 的每一段，但严格说不是单进程端到端。列为 §7 的未验证项。

### 2.4 审批正则的绕过（Q2 的前置障碍）

所有 `bash` 调用都会经过结构化审批：`needsStructuralApproval('bash')` 恒为 `true`（`plugins/bot-runtime/src/approval-gate.ts:200-203`），所以模型不能「零审批」执行 shell。问题在于审批 payload 里的**网络效果分类**可以绕过：

实际调用与结果：

```text
phoneEffectsForApproval('bash', { command: "curl -sS -X POST --data-raw '{\"jsonrpc\":\"2.0\"}' http://.../identity/register" })
→ [{"operation":"curl-post", ...}]                    # 直白写法被识别

"printf '%s\n' 'curl ... -X POST --data-raw ...' > /tmp/wp3.sh; bash /tmp/wp3.sh"
→ []                                                   # 脚本文件：operations=[]

c=cur; l="${c}l"; "$l" -sS -X POST --data-raw '{}' http://.../identity/register
→ []                                                   # 变量拼接：operations=[]
```

Swift 侧同样：

```text
BotApprovalPatternAnalyzer.effects(tool:"bash", command:<直接 curl POST>)  → ["curl-post"]
BotApprovalPatternAnalyzer.effects(tool:"bash", command:<脚本文件/变量拼接>) → []
BotApprovalPatternAnalyzer.effects(tool:"bash", command:"python3 /tmp/wp3.py") → []
```

这些对应 `BotEgressSpikeApprovalPatternTests.swift` 的 1 个通过测试和 3 个 `XCTExpectFailure`，以及插件测试的 1 个通过 + 2 个 `todo`。正则位置：`plugins/bot-runtime/src/approval-gate.ts:153-176`、`Sources/PhoneDSHBot/Authz/BotApprovalPatterns.swift:53-66`。

结论：**审批门禁需要一次 bash 批准，但网络 POST 的「curl-post/network-egress」效果可以被脚本文件、变量拼接、或 `python3 /tmp/x.py` 隐藏**。审批卡仍然出现，卡片上的 command 只有外层文本；人看到的不是真实的 POST URL。Q2 的「能」是「在一次 bash 批准之后能」，不是零交互。

> **审查者更正（主会话，2026-11-10）**：上面这句不准确。Worker 的 approval-gate 对每个 bash 调用都会向宿主发一次 `/approval` 请求，但宿主在效果列表为空时直接返回 `auto-policy`、不出审批卡（`Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift:414`；bash 的效果只来自 `BotApprovalPatternAnalyzer`，`:701-707`）。本文 §2.4 已实测脚本文件和变量拼接两种写法的效果列表为空，所以这两种写法**不会出现审批卡，用户没有任何交互**。「宿主对空效果返回 auto-policy」这一步是读代码得出的，没有单独跑完整的审批处理函数；其余各段有实测。同样需要修正 §2.6 和 §0 里「需要一次 bash 审批」的说法。

### 2.5 其他手段

- **git**：见 §1.3。真实 token 能用，但只能发 `/info/refs` / `/git-upload-pack`；精确路径政策拒绝，**不能**命中四条路由。既有测试 `Q1/Q2: git can reach /v1/http but exact-path admission blocks the Bot MCP routes` 通过。
- **WASI python3**：bridge 测试通过（§1.4），与 curl 走同一个 `/v1/http`；真实 CPython 代码执行未跑（§7）。因此 python 的结论是「桥接层能，真实解释器未验证」。
- **PTC / workflow-ptc / tool-workflow**：guest 没有 `fetch`/`process`，**不能**。
- **web_fetch**：默认不注册；启用后把 URL 发给 DeepSeek API，**不能**触达 loopback。
- **bash `env`/`printenv`/`/proc`**：**不能**读到 token；`curl` shim 自身能用 token，但 token 不向模型暴露。

### 2.6 Q2 结论

**能。** 真实 `curl` shim 经宿主 `/v1/http` 到达四条 Bot MCP 环回路由；宿主的精确授权、真 bearer 注入和 Bot 端路由都有实跑证据。攻击需要一次 `bash` 审批；审批里的网络效果分类可被脚本/变量隐藏。完整生产装配的单进程端到端未跑（§7）。

---

## 3. Q3：Task/routine 会话冒充主对话身份与审批绕过

### 3.1 身份登记与 user-turn 记忆

测试：`Tests/PhoneDSHBotTests/Security/BotEgressSpikeIdentityTests.swift` 的
`testTaskSessionCanRegisterMainChatIdentityAndWriteUserTurnMemory`（`XCTExpectFailure`，现在会失败）。

实际调用：

```text
POST /identity/register
{"runtimeId":"phone-worker","sessionId":"gb-main","callId":"wp3-q3-impersonate",
 "name":"UpdateMemory",
 "arguments":{"action":"write","fact":"WP3-Q3 task session wrote this as a user turn",
              "scope":"user","tier":"profile"},
 "argsDigest":"<sha256>"}

POST /mcp
{"jsonrpc":"2.0","id":"wp3-q3-impersonate","method":"tools/call",
 "params":{"name":"UpdateMemory","arguments":{...同上...}}}
# HTTP 头 x-pdsh-bot-session: gb-task-1（tools/call 不使用；仅证明调用者身份没有参与）
```

实际结果（关键行，原样摘录）：

```text
XCTAssertEqual failed: ("Optional(bool(true))") is not equal to ("Optional(bool(false))")
  - UpdateMemory accepted the foreign-session registration
XCTAssertNil failed: "BotMemoryFact(factID: "fact-...", text: "WP3-Q3 task session wrote this as a user turn",
  learnedAtMS: 1000, tier: .profile, scope: .user, trust: Optional(string("user")),
  source: Optional(BotMemorySource(kind: .userTurn, sessionID: Optional("gb-main"),
  turnID: nil, role: Optional("chat"))), ...)"
  - the fact was persisted under the shared user scope
XCTAssertNotEqual failed: (.userTurn) is equal to (.userTurn) - the persisted fact is attributed to a user turn
XCTAssertNotEqual failed: ("gb-main") is equal to ("gb-main") - the persisted fact names the main chat session
```

结论：**能**。写入确实以 `source.kind = user-turn`、`sessionID = gb-main`、`trust = user` 落在共享 `scope:user` / `tier:profile`。Task 会话自己的 id 本来不能写 user/profile；问题在于 `/identity/register` 允许任意已签发的 sessionId，且 `/mcp` 的归属只按 `name + argsDigest` 认领（`Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift:261`、`:429`；`Sources/PhoneDSHBot/Gateway/BotGateway.swift:87`）。同一条路径对 routine 会话相同（只差 `BotSessionKind`）；本次用 Task 实跑，routine 未单独跑。

### 3.2 审批绕过

- Worker approval-gate 不在 HTTP 路径上：直接 `/mcp` 不会经过 `plugins/bot-runtime/src/approval-gate.ts` 的 `tools/pre-execute`。
- 宿主仍会执行 `BotExecutionAuthorizer`：`memory.forget`（`scope:user`）的 effect 是 `policy: ask`，没有 grant 时返回 `missing-grant`。实际测试 `testDirectMCPCallCannotBypassTheHostGrantForAskPolicyTools` 通过，输出：

```text
result.isError = true
error.code = "permission_denied"
```

- `UpdateMemory` 的 `write` effect 是 `policy: auto`（`Sources/PhoneDSHBot/Authz/BotToolEffects.swift:303-317`），所以 Q3.1 的写入根本不需要审批；`ask` 类工具（user forget、BLE 外发等）仍被宿主 grant 拦截。
- 如果之前已有有效 grant，宿主会放行；本次测试没有 grant。

结论：**Q3 的「user-turn 写入」能；「直接调用需要审批的工具并成功」不能**（Worker gate 被绕过，但宿主 grant 检查仍在）。两者要分开报告，不能把「绕过 Worker 门禁」说成「绕过所有审批」。

---

## 4. Q4：跨 Bot 身份登记与 per-caller 工具列表

测试：`Tests/PhoneDSHBotTests/Security/BotEgressSpikeIdentityTests.swift`。

### 4.1 读写另一个 Bot 的 agent 记忆

测试 `testCrossBotIdentityCanWriteAndReadAnotherBotsAgentMemory`（`XCTExpectFailure`）：

```text
POST /identity/register  sessionId: "gb-bot-b"  name: "UpdateMemory"  scope: "agent"
POST /mcp                tools/call UpdateMemory
POST /identity/register  sessionId: "gb-bot-b"  name: "RecallMemory"
POST /mcp                tools/call RecallMemory query: "WP3-Q4"
```

实际结果：

```text
XCTAssertEqual failed: ("Optional(bool(true))") is not equal to ("Optional(bool(false))")
  - the cross-Bot write was accepted
XCTAssertFalse failed - the fact was persisted in bot-b's agent memory
XCTAssertEqual failed: ("Optional(number(1.0))") is not equal to ("Optional(number(0.0))")
  - the cross-Bot read returned the other Bot's fact
```

结论：**能**。`BotMCPRuntime.memory(for: call.principal.botId)` 使用登记时的 session 所属 Bot；`gb-bot-b` 可以被任意持有 Bot bearer 的 HTTP 调用者登记。攻击者不需要知道 bearer（host 会从 `/v1/http` 注入），只需要知道 Bot 的 `gb-<botId>` 命名；主对话 id 是确定性的 `gb-<botId>`（`Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:965-968`），Task/routine id 是 `gb-task-*` / `gb-routine-*`。

### 4.2 per-caller `tools/list`

- `tools/list` 通过 `x-pdsh-bot-session` 解析调用者，非主 Bot 的工具列表中隐藏 `CreateTeammate`（`Sources/PhoneDSHBot/MCP/BotMCPHandler.swift:58-70`；既有 `BotToolCatalogCallerTests` 的 `testHTTPHeaderSelectsTheCallerCatalog` 已覆盖）。
- 实际测试 `testPerCallerToolsListIsNotEnforcedOnToolsCall`：`gb-bot-b` 的列表确实没有 `CreateTeammate`；直接 `tools/call` 以 `gb-bot-b` 登记后，返回的是 `permission_denied`，而不是 `unknown_tool`。这说明 `tools/call` **不读取** per-caller catalog，真正的边界是 `BotTeamTools.createTeammate` 的主 Bot 检查（`Sources/PhoneDSHBot/Team/BotTeamTools.swift:290`）。该测试通过。
- 实际测试 `testImpersonatingTheMainBotBypassesThePerCallerToolList`（`XCTExpectFailure`）：先作为 `gb-bot-b` 看到隐藏列表，再登记 `gb-bot-a`（主 Bot）并直接调用 `CreateTeammate`。结果：

```text
XCTAssertEqual failed: ("false") is not equal to ("true") - CreateTeammate executed as the main Bot
XCTAssertTrue failed - the hidden tool created a teammate
```

结论：**per-caller `tools/list` 能被绕过**。它只是显示层；`tools/call` 没有调用者归属校验。单靠列表不能保护主 Bot 专属工具；主 Bot 检查是最后一道，但一旦攻击者冒用主 Bot 的 sessionId，这道也失效。

### 4.3 Q4 结论

**能。** 跨 Bot 身份登记可以读写对方的 agent 记忆；per-caller 工具列表不参与 `tools/call`，冒用主 Bot 身份可以执行隐藏工具。

---

## 5. 修复建议与估计改动范围（不实施）

按 WP3 的「只取证」要求，以下只是建议，没有改任何生产代码。

### 5.1 根因

1. **`/identity/register` 的 `sessionId` 是调用者自报的**，HTTP 层没有「这个请求来自该 session」的证明；`sessionId` 本身是确定性的 `gb-<botId>`，可猜。
2. **`/mcp` 的 `tools/call` 没有调用者身份**，只按 `name + argsDigest` 从注册表认领；`x-pdsh-bot-session` 只用于 `tools/list`。
3. **Worker 与宿主 Bot MCP 之间只有一条共享 bearer**，Worker 侧任何能发 `/v1/http` 的代码都能登记任意 session；模型编写的 bash/curl 就是这样的代码。
4. 审批 regex 是命令文本匹配，脚本文件/变量拼接/`python3 script` 可以隐藏网络效果。

### 5.2 建议

- **Q2/Q3 共用修复（最高优先级）**：让宿主 `/v1/http` egress 为「Bot MCP」目标加上一个只由宿主生成、且绑定到当前 Worker 会话的不可伪造凭证；`/identity/register` 和 `/mcp` 都要求并校验它。模型写的 curl 即使拿到 channel token 也拿不到这个 per-session 凭证。或者把 Bot MCP 的四条路由从 Worker 的 `/v1/http` 可达集合里移除，只允许 Worker 内的 MCP client 走带签名头的专用通道。
- **Q3/Q4 身份绑定**：`BotMCPRuntime.registerIdentity` 必须用宿主签发的 session 证明（不是 body 里的 `sessionId`）；`execute` 必须校验注册的 session 证明与当前 `tools/call` 一致；`tools/list` 与 `tools/call` 共用同一个调用者解析。`BotMCPHandler` 的 `callerSessionHeader` 不能再只用于列表。
- **Q4 工具目录**：`tools/call` 也要按调用者 catalog 检查工具是否对调用者可见；`CreateTeammate` 的主 Bot 检查保留为第二道。
- **审批 regex**：网络 POST 的判定改为基于宿主侧 effect/authorization 表，而不是只看命令字符串；至少在 bash 审批里展开脚本文件内容/解释器参数；`python3 script.py` 不能只因为外层字符串没有 `urllib` 就当作无网络效果。
- **Q1/`git`**：`git/http.ts` 的 `resolveHostHttp` 不应在显式 `token: undefined` 时回退到 `process.env`；显式传入空值要能被区分。若接受 Q2 的 per-session 凭证方案，这个回退自然失效。
- **可选**：把 channel/launch token 从 `process.env` 收进 channel client 闭包，减少「任何同一 JS realm 的代码都能读」的面；这不改变当前 Q1 的结论，但降低未来 JS 执行类漏洞的收益。

估计范围（仅估计，未改）：

```text
Sources/PhoneDSH/PhoneMCPAccessSettings.swift            (grant / credential routing)
Sources/PhoneDSHGateway/{ModelGateway,GatewaySession}.swift (egress admission)
Sources/PhoneDSHLoopback/LoopbackServer.swift             (/v1/http 入口)
Sources/PhoneDSHBot/MCP/{BotMCPHTTPServer,BotMCPHandler,BotMCPRuntime}.swift
Sources/PhoneDSHBot/Gateway/BotGateway.swift              (claim/identity)
plugins/bot-runtime/src/{identity-bridge,approval-gate,caller-catalog}.ts
plugins/wasi-toolbox/git/{http,remote}.ts                 (process.env fallback)
```

## 6. 未能验证 / NOT_RUN

| 项 | 状态 | 原因与验证条件 |
| --- | --- | --- |
| 生产装配（`BotRuntimeComposition` + 真 Worker + 真 WKWebView）端到端跑一次 Q2 | **NOT_RUN** | 需要 iOS Simulator / `xcodebuild` 与生产 app 目标；本次优先 macOS `swift test` + plugins 测试。分段证据已覆盖 shim/loopback/gateway/Bot listener；若要单进程端到端，需要模拟器构建和磁盘预算（本轮磁盘一度低于 8 GiB）。 |
| 真实 CPython WASI 的 `urllib`/socket 实际行为 | **NOT_RUN** | 仓库不含 `python.wasm`/`python313.zip`；`ensurePythonArtifacts` 会触发 30 MB 级构建。已跑 bridge 层和 guest 环境断言；要跑真实解释器需先准备 `PDSH_PYTHON_ARTIFACTS`。 |
| 真实模型 | **NOT_RUN** | 按通用规则禁止；全部用脚本化/mock 上游。 |
| 真机 / Android / HarmonyOS | **NOT_RUN** | 本任务只在 macOS 本机取证；其他端未验证。 |
| `web_fetch` 在用户显式开启独立 Search/Fetch 后的完整工具挂载 | **部分** | provider 层实跑；`tool-web` 完整挂载未跑。 |
| `routine` 会话冒充 | **部分** | 与 Task 共用同一 `registerIdentity`/`resolveToolCall` 路径；本次只对 Task 实跑。 |

## 7. 新增测试与运行结果

### 7.1 新增文件

```text
docs/research/bot-egress-spike-20261110.md
Tests/PhoneDSHBotTests/Security/BotEgressSpikeSupport.swift
Tests/PhoneDSHBotTests/Security/BotEgressSpikeIdentityTests.swift
Tests/PhoneDSHBotTests/Security/BotEgressSpikeApprovalPatternTests.swift
plugins/tests/bot-egress-spike.test.ts
```

### 7.2 已知失败（安全断言，当前会失败）

1. `plugins/tests/bot-egress-spike.test.ts`
   - `Q2 known failure: model-written curl reaches the four Bot MCP routes` — `todo`
   - `approval known failure: a script-file curl POST is still classified` — `todo`
   - `approval known failure: a concatenated-command curl POST is still classified` — `todo`
2. `Tests/PhoneDSHBotTests/Security/BotEgressSpikeIdentityTests.swift`
   - `testTaskSessionCanRegisterMainChatIdentityAndWriteUserTurnMemory` — `XCTExpectFailure`
   - `testCrossBotIdentityCanWriteAndReadAnotherBotsAgentMemory` — `XCTExpectFailure`
   - `testImpersonatingTheMainBotBypassesThePerCallerToolList` — `XCTExpectFailure`
3. `Tests/PhoneDSHBotTests/Security/BotEgressSpikeApprovalPatternTests.swift`
   - `testScriptFileCurlPostIsClassified` — `XCTExpectFailure`
   - `testVariableConcatenatedCurlPostIsClassified` — `XCTExpectFailure`
   - `testScriptFilePythonNetworkProgramIsClassified` — `XCTExpectFailure`

这些断言在修复后应改为普通断言（或删除 `XCTExpectFailure` / `todo`）；当前的「预期失败」就是漏洞存在的回归标记。

### 7.3 通过的回归

- `plugins/tests/bot-egress-spike.test.ts`：Q1 子环境、非 MCP 目标 403、直接 curl-post 分类、git 精确路径拒绝、WASI python 无 token、web_fetch 不触达 host、PTC 无 host globals。
- Swift：own-task 不能写 user scope；直接 `/mcp` 对 `ask` 工具返回 `permission_denied`；per-caller 列表隐藏 `CreateTeammate` 且 `tools/call` 直达 handler 后被主 Bot 检查拒绝。

### 7.4 实际运行的命令与结果

| 命令 | 结果 |
| --- | --- |
| `swift test --disable-sandbox --filter BotEgressSpike` | **PASS**：10 tests，0 failures；其中 6 个测试以 `XCTExpectFailure` 记录已知失败（12 条断言级 expected failure） |
| `swift test --filter PhoneDSHBotTests`（实际加 `--disable-sandbox`） | **PASS**：394 tests，0 failures |
| `cd plugins && npm run typecheck` | **PASS**（tsc 无输出，exit 0） |
| `node scripts/run-tests.mjs "tests/bot-egress-spike.test.ts"` | **PASS**：10 tests，7 pass，3 todo，0 fail |
| `node scripts/run-tests.mjs "tests/bot-*.test.ts"` | **PASS**：66 tests，62 pass，3 todo，0 fail |
| `swift test --disable-sandbox --filter 'PhoneMCPAccessSettingsTests/...|MCPEgressPolicyTests/...|BotMCPHTTPTests/...'` | **PASS**：3 tests，0 failures |
| `node --test --test-name-pattern "vm scope exposes" tests/workflow-worker.test.ts`（`PDSH_DSH_CHECKOUT` 已设） | **PASS**：1 test |
| `bash scripts/ci/check.sh --only phone-license,phone-hygiene` | **phone-license PASS；phone-hygiene FAIL**（见 §8） |

`swift` 需要 `--disable-sandbox`：本机 sandbox 下 `swift test` 报 `sandbox-exec: sandbox_apply: Operation not permitted`。这是环境限制，不是测试失败。

## 8. `phone-hygiene` 结果说明

```bash
bash scripts/ci/check.sh --only phone-license,phone-hygiene
```

实际结果：

```text
== PASS: phone-license (2s)
== FAIL: phone-hygiene (13s) — exit 1
```

失败输出是仓库既有的 Tono 账户域名相关词/主机名（例如 `Sources/PhoneDSH/TonoAccount/TonoAccountClient.swift:5`、`spec/v1/tono-account.md:9`；本文不复述被禁词），**没有**新增文件（`Tests/PhoneDSHBotTests/Security/**`、`plugins/tests/bot-egress-spike*`、`docs/research/bot-egress-spike-20261110.md`）的行。基线核验（命令里的被禁词用 `<word>` 代替；实际运行用原词）：

```bash
git show HEAD:scripts/ci/hygiene-allow.txt | grep -c '<word>'   # 0
git show HEAD:Sources/PhoneDSH/TonoAccount/TonoAccountClient.swift | grep -c '<word>'  # 1
```

即 `31c0cab73` 上的 hygiene allowlist 本来就没有该词条目；这是基线失败，不是本 spike 引入。按「不放宽/不新增 allowlist」的规则，没有改它。

## 9. 交接证据（AGENTS §3.5）

```text
Base / head:        31c0cab73 / 31c0cab73（工作区未提交）
Protocol impact:    none — 只新增研究文档和测试；未改生产代码、spec、schema、golden、协议路径
Contract revision:  N/A（没有协议变更）
Changed files:      docs/research/bot-egress-spike-20261110.md
                    Tests/PhoneDSHBotTests/Security/{BotEgressSpikeSupport,BotEgressSpikeIdentityTests,BotEgressSpikeApprovalPatternTests}.swift
                    plugins/tests/bot-egress-spike.test.ts
Status per end:     iOS/macOS 宿主: 实跑（Q3/Q4 能）；Worker/plugins: 实跑（Q1 不能，Q2 能）
                    Android/HarmonyOS/真机: NOT_RUN
Commands → result:  swift test --disable-sandbox --filter PhoneDSHBotTests → PASS (394)
                    swift test --disable-sandbox --filter BotEgressSpike → PASS (10; 6 tests / 12 assertions marked expected failures)
                    cd plugins && npm run typecheck → PASS
                    node scripts/run-tests.mjs "tests/bot-*.test.ts" → PASS (66; 3 todo)
                    bash scripts/ci/check.sh --only phone-license,phone-hygiene → license PASS, hygiene FAIL（基线既有，见 §8）
Not verified:       生产装配单进程端到端、真实 CPython WASI、真实模型、真机/其他平台
Remaining risks:    Q2/Q3/Q4 都是「能」；修复前，任何能发 /v1/http 的模型代码都可登记任意已签发 session
                    id 并读写其他 Bot 记忆/以主 Bot 身份调用工具。按 WP3 建议立即另开修复工作包。
```

建议提交信息：

```text
test(bot): add WP3 egress spike evidence and known-failure regressions

Protocol impact: none — research doc and new tests only; no production code,
spec, schema or golden touched.
```

## 10. 原样证据索引

| 证据 | 位置 |
| --- | --- |
| Q2 curl 四路由 | `/tmp/wp3-plugin-egress.log`（本机临时文件，关键行已在 §2.2 摘录） |
| Q3/Q4 Swift expected failures | `/tmp/wp3-swift-spike.log`（关键行见 §3.1、§4.1） |
| 全量 Bot tests 394 | `/tmp/wp3-final-bot-tests.log` |
| 插件 bot-* 66 | `/tmp/wp3-bot-plugin-tests.log` |
| 宿主 policy/route 3 | `/tmp/wp3-host-evidence.log` |
| PTC e2e 1 | `/tmp/wp3-ptc-e2e.log` |
| hygiene | `/tmp/wp3-hygiene.log` |
