# 长时间的原生工具调用：SSE keepalive，免得 60 s 空闲超时把成功的调用报成失败（P05／P26）

```yaml
change: PC-20261110-mcp-long-call-keepalive
contracts: [P05, P26]
status: implemented
breaking: false
version_decision: No new route, JSON-RPC method, environment variable or wire frame. A `tools/call` still running after 5 s, from a client that accepts text/event-stream, is answered in MCP Streamable HTTP's SSE form with keepalive comments. Every other request keeps its JSON answer byte for byte.
base: 6f4bed1f
contract_revision: spec/bot/v1/mcp-endpoint.md §2 "Long tool calls" + spec/v1/golden/mcp-long-call/cases.json; spec/v1/native-mcp.md iPhone agent tool; spec/README.md GAP-36 @ this PR head
```

Protocol impact: P05; P26; P09: none — IPhoneAgentHost.swift gains one DEBUG recorder field, no page or copy changes; P25: none — BotMCPHTTPServer.swift changes only the HTTP answer form of /mcp, no BotEvent is written or read differently; P27: none — PC Link is untouched, the listener file and IPhoneAgentHost.swift are shared but their PC paths are unchanged

P05 — native tool calls through the host egress may now carry an SSE body with keepalive comments (the gateway already streamed and sanitized event streams; a regression proves keepalives pass unchanged); GAP-36 records that `/mcp/native` still answers JSON only. P26 — the Bot MCP listener's `/mcp` answers a long single `tools/call` as SSE.

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 真机：语音「打开设置 APP」→ `iphone_agent_run` 实际成功（原生记录：「已打开「设置」App并停在设置首页」），但 UI 任务约 60 s 才答，这期间没有任何字节：host 出口对 loopback 的 60 s 空闲超时（`-1001`，`connect_timeout host 127.0.0.1`）或 Worker llm-bridge 的 60 s 投递超时（`PDSH_DELIVERY_TIMEOUT`）先到，模型看到超时，告诉用户「打不开」。期望：真在运行的调用不会被空闲超时判死，结果送回模型。
- **Roles.** 单一 agent 兼 coordinator／contract owner／implementer／reviewer（AGENTS.md §3）。
- **Ends.** Producer：Bot MCP listener（`Sources/PhoneDSHBot/MCP/BotMCPHTTPServer.swift`）。中转：host 出口（`Sources/PhoneDSHGateway`，不改代码，只加回归）。Consumer：Worker 的 `@deepseek-ai/dsh-mcp-client`（MCP SDK `StreamableHTTPClientTransport`，读得了 POST 的 SSE 响应；不改 DSH 源码）与 `plugins/llm-bridge` 的投递包装（按到达字节计空闲，不改）。

## 2. Delta

| 项 | Before → After |
| --- | --- |
| Bot `/mcp` 单个 `tools/call`，客户端 `Accept` 含 `text/event-stream`，5 s 内未完成 | 等结束后一次 JSON → 5 s 时回 `200 text/event-stream`（含 `Mcp-Session-Id`，无 `Content-Length`），每 15 s 一行 `: keepalive`，最后恰好一个 `event: message`（data 一行是 JSON-RPC 响应），然后关闭。 |
| 5 s 内完成、其他方法、批量、通知、不接受 SSE 的客户端 | 不变（`application/json`）。 |
| `/mcp/native` | 不变，仍只回 JSON（GAP-36）。 |
| 总时限 | 不变：Worker 的 `toolCallTimeoutMs` 130 s。 |

为什么不放宽超时：两个 60 s 空闲限是为卡死的连接设的（模型请求也用）；放宽会让真正卡死的调用要几分钟才被发现。keepalive 只证明「还在跑」，不携带进度或结果。

## 3. 相容性

| Producer → Consumer | 行为 |
| --- | --- |
| 新 listener → 现有 Worker | MCP SDK 本就接受 POST 的 SSE 响应；`: keepalive` 是 SSE 注释，解析器忽略。 |
| 新 listener → 不接受 SSE 的客户端 | 仍是 JSON，和以前一样会在长调用上超时。 |
| 旧 listener → 新 Worker | 无变化。 |
| 连接中途断开 | 调用继续跑完，回执（`iphone_agent_run` 的收据库）仍是权威；不重放。 |

## 4. 证据

- Swift：`swift test --filter 'BotMCPLongCallTests|BotMCPHTTPTests|BotMCPNativeForwardingTests'` → 15 passed（新增 5：共享决策表、常量、真实 HTTP 下慢调用 = SSE 头 + ≥1 个 keepalive + 恰好一个 message 事件且 data 为一行、快调用仍 JSON、不接受 SSE 的客户端仍 JSON）；`swift test --filter SensitiveSSEKeepaliveTests` → 2 passed（keepalive 经凭据过滤原样、即时转发；之后的 message 仍脱敏）。
- `check.sh --only phone-spec,phone-cross-tree` → PASS；`protocol_impact.py` → PASS。
- 设备（longshu 上的 iPhone，镜像到 PhoneAgent-7356）：Worker 的 MCP 客户端实际发送 `Accept: application/json, text/event-stream`（DEBUG 记录器），故超过 5 s 的调用都走 SSE；`iphone_agent_run` 17 s（打开设置）与 58 s（15 步）两次都把结果送回模型，模型据实报告。
- 未验证：设备上超过 60 s 的单次调用（UI 代理 15 步上限约 60 s，造不出更长的真实调用；>60 s 由 HTTP 测试覆盖帧格式，空闲计时器以到达字节计）；`/mcp/native`（GAP-36）。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知 |
| --- | --- | --- | --- |
| 1 | Claude | 初版 | Bot listener；gateway 只加回归；Worker 不变 |
