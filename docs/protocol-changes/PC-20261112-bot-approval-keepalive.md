# 交互审批等待不再被 60 s 投递看门狗打断；调用结束时同步收起审批卡（P26）

```yaml
change: PC-20261112-bot-approval-keepalive
contracts: [P26]
status: implemented
breaking: false
version_decision: No new route, field, header, status, reason, error code, environment variable or wire frame. `/approval` reuses the long tool-call SSE answer form of PC-20261110 when the Worker explicitly accepts text/event-stream; `/identity/cancel` additionally cancels the call's interactive approvals with the existing `consumer_cancelled` decision.
base: 20ef5ca4
contract_revision: spec/bot/v1/mcp-endpoint.md §2 "Long approvals", §3 cancel cascade, §6 + spec/v1/golden/mcp-long-call/cases.json `approval` block @ d6939722
```

Protocol impact: P26; P05: none — llm-bridge's delivery watchdog and the host egress are unchanged, the fix relies on their existing SSE pass-through and byte-arrival idle timers proven by PC-20261110; P25: none — no BotEvent type or field is added, the cascade writes the existing approval.decided cancelled/consumer_cancelled shape; P27: none — row projection is untouched, a cancelled card already projects as a non-pending row

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 真机（iPhone Air，2026-11-12，会话 `gb-main-29ecd59a…`）：Bot 回合 12:50:37 `bash`（`rm -f` + `curl`）触发结构审批，App 写 `approval.requested`（approval-205cefaa…）。Worker `postApproval` 用的是 llm-bridge 装的全局 `fetch`，请求经宿主 `/v1/http` 转到 Bot listener `/approval`；listener 要等用户决定才回响应头，于是 llm-bridge `withHeadDeadline` 60 s 先触发，12:51:37 工具结果为 `[structural approval gate] llm-bridge: model response headers delivery stalled for 60000 ms (PDSH_DELIVERY_TIMEOUT) The tool call was NOT executed.`。宿主出口在 Worker 放弃后仍保持上游请求（P05 response-log 规则），App 看不到消费者离开；Worker 随后按 §3 发 `/identity/cancel`，但 App 的 `cancelIdentity` 不碰审批，卡片一直 pending，直到 12:55:38 300 s 超时记为 deny（timedOut）——点了也没用的殭屍卡。用户感受：Bot 卡一分钟才回复。
  期望：(A) 审批等待只受审批自身 300 s 超时约束；(B) 调用已失败或取消时，对应交互审批同步进入 cancelled，卡片收起。
- **Roles.** Claude 兼 coordinator／contract owner／reviewer；本机 DSH worker 为两端 implementer（同一 worktree，路径不交叉见 §4）。
- **Ends.** Producer：Bot listener `/approval`（`Sources/PhoneDSHBot/MCP/BotMCPHTTPServer.swift`）与审批协调（`BotApprovalCoordinator.swift`、`BotMCPRuntime.swift` 的 `cancelIdentity`）。Consumer：`plugins/bot-runtime/src/approval-gate.ts` 的 `postApproval`（`sandbox-approval` 共用）。中转：宿主出口与 llm-bridge 不改。

## 2. Delta

| 项 | Before → After |
| --- | --- |
| Worker `postApproval` 请求头 | 无 `Accept` → `Accept: application/json, text/event-stream` |
| `/approval`，显式接受 SSE，5 s 内无结果 | 等结果后一次 JSON（>60 s 必被看门狗判死）→ 5 s 时回 `200 text/event-stream`（无 `Content-Length`、无 `Mcp-Session-Id`），每 15 s `: keepalive\n\n`，最后恰好一个 `event: message\ndata: <审批结果 JSON 对象>\n\n`，关闭 |
| 5 s 内有结果（常设授权、持久待办 `pending:true`、无效请求）、未显式接受 SSE | 不变（JSON） |
| Worker 解析流 | — → 只认恰好一个 `event: message`、一行 `data:`、JSON 对象；否则 transport failure，fail closed（`ok:false`，工具不执行） |
| `/identity/cancel` | 只删登记 → 另外取消该登记 (principal sessionId, callId) 下所有**交互**待审批：`approval.decided` `deny`/`cancelled`/`consumer_cancelled`，等待中的请求得 `{ok:false,allowed:false,message:"approval cancelled"}`；持久待办不动 |
| 总时限 | 不变：App 300 s，Worker 330 s |

为什么不放宽 60 s 看门狗：它同时守模型请求，放宽会让真正卡死的投递要几分钟才暴露（与 PC-20261110 同理）。为什么不靠断线检测收卡：宿主出口在消费者离开后仍读完上游（P05），listener 感知不到；Worker 的配对 `/identity/cancel` 是唯一可靠信号。

## 3. 相容性

| Producer → Consumer | 行为 |
| --- | --- |
| 新 App → 旧 Worker | 旧 `postApproval` 不发 SSE accept，得 JSON；>60 s 的卡仍被看门狗判死，但旧 Worker 的配对 `/identity/cancel` 会触发级联，卡片随即收起。 |
| 旧 App → 新 Worker | 旧 listener 忽略 `Accept` 回 JSON，新客户端照读；无级联，殭屍卡行为同旧版。 |
| 新 → 新 | 等待只受 300 s 审批超时约束；调用提前结束则卡片同步收起。 |
| 持久数据 / 回滚 | 无新持久字段或取值；`approval.decided` 的 `cancelled`/`consumer_cancelled` 是已有取值；回滚无需迁移。 |
| Android / HarmonyOS | 无 Bot runtime，not started；非 Bot 路径不变。 |

## 4. 文件归属与验收

- 契约（Claude，已提交）：`spec/bot/v1/mcp-endpoint.md`、`spec/v1/golden/mcp-long-call/cases.json`、本文件。
- App 端（DSH worker）：`Sources/PhoneDSHBot/MCP/{BotMCPHTTPServer,BotApprovalCoordinator,BotMCPRuntime}.swift`、`Tests/PhoneDSHBotTests/MCP/**`。
- Worker 端（DSH worker）：`plugins/bot-runtime/src/approval-gate.ts`、`plugins/tests/**`。
- 验收命令：`swift test --filter 'BotMCPLongCallTests|BotMCPHTTPTests|BotApproval|BotIdentity'`、`cd plugins && npm run typecheck && npm test`、`bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-plugins`、`python3 scripts/ci/protocol_impact.py`（按其用法）。

## 5. 证据

- Swift：`swift test --filter 'BotApprovalLongWaitTests|BotMCPLongCallTests|BotMCPHTTPTests'` → 19 passed（新增 `BotApprovalLongWaitTests` 7 例：golden 决策表；真实 HTTP 慢审批 = SSE 头（无 `Content-Length`／`Mcp-Session-Id`）+ ≥1 keepalive + 恰好一个 message；无 SSE accept 仍 JSON；常设授权快结果仍 JSON；`/identity/cancel` 使流以 `approval cancelled` 结束、恰好一条 `approval.decided` cancelled/consumer_cancelled、超时任务不再写第二条；持久待办不被取消；只取消同一 callId）。`swift test --filter PhoneDSHBotTests` → 571 passed（DSH worker 运行）。
- TypeScript：`node scripts/run-tests.mjs tests/bot-approval-long-wait.test.ts tests/bot-identity-approval.test.ts tests/bot-sandbox-approval.test.ts tests/llm-install.test.ts` → 55/56；新增 3 例全过（golden valid/invalid 流驱动 `parseApprovalEventStream`；经真实 `installNodeFetch` host route、200 ms 投递窗口，700 ms 的 keepalive 流得 allowed；对照：700 ms 才回 JSON 头仍 `PDSH_DELIVERY_TIMEOUT`，看门狗未放宽）；`bot-identity-approval` 新增 1 例（投递超时的审批 fail closed、工具不执行、登记恰好取消一次）。唯一失败 `BLE native-MCP effects match the shared golden` 为基线既有（繁简标签不符，与本改动无关）。`npm run typecheck` → PASS。
- `check.sh --only phone-spec,phone-cross-tree` → PASS；`phone-license` → PASS；`phone-plugins` → FAIL（3 个基线既有失败：上述 BLE 标签、`profile.test` preset 清单）；`phone-hygiene` → FAIL（基线 main 同样 FAIL）。`protocol_impact.py --base origin/main` → PASS（P26，P05/P25/P27 none）。
- 未验证：真机（需重建 Worker bundle 并安装后，在 Bot 里触发 bash 审批、等待 >60 s 再点允许）、模拟器 UI 卡片收起的视觉表现、宿主出口对 `/approval` SSE 的逐字节透传在真机上的表现（由 PC-20261110 的 `/mcp` 真机证据与 `SensitiveSSEKeepaliveTests` 间接覆盖）。

## 6. 修订纪录

| revision | 由谁 | 原因 | 通知 |
| --- | --- | --- | --- |
| 1 | Claude | 初版 contract freeze | App listener／协调器；Worker approval-gate |
| 1 (implemented) | DSH worker + Claude 审查 | 两端按 rev 1 实现，无 CONTRACT CHANGE REQUEST | — |
