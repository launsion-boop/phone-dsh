<!-- SPDX-License-Identifier: MIT -->

# PC-20261107-bot-mcp-single-endpoint

```yaml
change: PC-20261107-bot-mcp-single-endpoint
contracts: [P05, P16, P25, P26]
status: frozen
base: f5e47b2bcc3bc4ae5ca9db598e1cbea09faf5581
contract_revision: PC-20261107-bot-mcp-single-endpoint@1
version_decision: 复用既有 Worker env、MCP Streamable HTTP、BotEvent v1 与 Task 工具结果形状；同 App bundle 配对升级，不新增 wire/env/route。
```

Protocol impact: P05; P16; P25; P26。

## 1. 触发与现状

- P16：`PhoneDSHHost` 在 `nativeMCP != nil` 时把 App 注入的
  `PDSH_PHONE_MCP_URL/TOKEN` 改写为 `/mcp/native` + loopback token，覆盖了
  `BotRuntimeComposition` 的 Bot 端点。生产环境因此永远看不到 Bot 工具。
- P05/P16：Bot MCP listener 监听 `.any`，未检查 Origin/query/大小写/`..`，
  `DELETE` 对任意路径返回 200，token 非常量时间比较。
- P26：身份登记在 `tools/execute`，审批在 `tools/pre-execute`，因此
  `bash`/`write`/`edit` 的结构审批必然 `unattributed`；认领只按
  `runtimeId+argsDigest`，不同工具可互相冒领；登记 30 s 短于 300 s 审批窗口；
  Worker 重启没有代次，旧登记可被新 Worker 领取。
- P25/P26：Task 只在内存；重启后 `AwaitTask`/`StopSubagent` 返回
  `unauthorized`；`session/prompt` 每次随机 `requestId`，崩溃重放会重复开回合。
- P26/P16：Worker 环境携带真实 Bot token（进入 page `?env=` URL），profile 也把
  它写进 `Authorization`，与 `plugins/README.md` 的“Worker 只送 placeholder、
  宿主 egress 注入”约定不符。

## 2. 契约冻结（current → expected）

| 项 | current | expected |
| --- | --- | --- |
| Worker `phone` MCP env | native MCP 覆盖 Bot 端点 | Bot 端点唯一；Bot server 聚合 native `tools/list`/`tools/call`；仅没有 App 端点时保留 `/mcp/native` |
| Worker token | 真 token 进 env/profile/page URL | non-secret placeholder；`MCPEgressPolicy.grantBotRuntimeEndpoint` 在宿主 egress 注入真 bearer |
| Bot HTTP 监听 | `.any` | IPv4 loopback only |
| Bot HTTP 校验 | Origin 不查、query 被忽略、DELETE 200、token 逐字节早退 | Origin 精确、路径精确、POST only、常量时间 token |
| 身份/审批顺序 | execute 登记、pre-execute 审批 | pre-execute 登记先于审批；execute 清理；abort/超时/拒绝成对取消 |
| 登记 TTL | 30 s | 330 s（300 s 审批 + 30 s 余量）；定期清理 |
| 认领键 | runtimeId + argsDigest | runtime generation + bare tool name + argsDigest + 当前 principal incarnation |
| Worker 重启 | 无接口 | `workerRestarted()` 取消审批并通知 UI、清登记、旋转代次 |
| Task 持久化 | 仅内存 | SQLite `task.created`/`task.updated` + `persistedTask`；未完成项 `interrupted`/`worker_restarted`；父对话一次唤醒 |
| prompt 幂等 | 随机 requestId | 由 held item/routine runId/task/action nonce 派生 |

## 3. 兼容性

| 场景 | 结论 |
| --- | --- |
| old Worker → new App | 新 App 仍接受旧 env：未配置 Bot env 时注入 `/mcp/native`；旧 Worker 的 `/mcp/native` 直连路径不变。 |
| new Worker → old App | 旧 App 继续把 `/mcp/native` 写进 env；新 Worker 的 Bot server 不存在时仍走 native。不要求旧 App 理解新字段。 |
| new ↔ new | Worker 只看到 Bot 端点；`tools/list` 增加 native 工具（名称冲突 Bot 优先），`tools/call` 对 native 原样转发；native receipts/`X-PDSH-Idempotency-Key` 不变。 |
| 旧 BotEvent 数据 | 新增 `persistedTask` 是 `task.*` data 内的可选字段；旧 reader 忽略。状态 `interrupted` 是既有自由字符串的新增取值，未知状态按保守 UI 处理。 |
| 审批卡片 | 旧卡片仍可 resolve；重启时新增 `approval.decided(status=cancelled)` 与 `ui.notice`，不改成新的错误码。 |
| token 轮换 | placeholder 不含秘密，旧 token 不再是 Worker 可见状态；宿主 route 注入按精确 path 生效，不放宽其它出站地址。 |

没有新增 HTTP route、JSON-RPC method、环境变量、wire frame 或公共结构字段。

## 4. 验收

- `swift test --filter PhoneDSHBotTests`：真实 SQLite、真实 Bot MCP HTTP、真实 Cordis
  hook 顺序对应的 Swift 状态机（审批/认领/重启/Task/requestId）。
- `swift test --filter PhoneDSHWorkerEnvironmentTests`：同时配置 nativeMCP 与 Bot
  时 Worker env 仍指向 Bot；native-only 仍走 `/mcp/native`。
- `plugins/tests/bot-identity-approval.test.ts`：真实 `ToolRuntime` 下水fall
  顺序验证登记先于审批、允许后执行、native/内置工具不误登记。
- `python3 spec/bot/v1/tools/validate_vectors.py`。
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`。
- `bash scripts/ci/check.sh --only phone-plugins,phone-image,phone-no-dsh-patch,phone-compat,phone-license,phone-modules`。
- 模拟器 bot-e2e 由主会话统一运行；真机、真实模型、真实 ADB 仍为 NOT_RUN。

## 修訂（PR #60 集成）

- identity bridge 對 `needsIdentityRegistration` 為真的工具（`bash`/`write`/`edit`/`mcp__phone__*`）在 App 回 `unknown_tool` 時不再 `next()`：身份登記是這些工具的前置授權步驟，App 不認識工具就不能未登記執行；改為 deny，令本次調用 fail-closed，工具 body 不執行。已登記工具的原有順序與撤銷不變。
- 回歸：`plugins/tests/bot-identity-approval.test.ts` 的 `identity unknown_tool fails closed for every registration-required tool`，逐個工具斷言 `isError` 且 body 執行次數為 0。
