<!-- SPDX-License-Identifier: MIT -->

# Bot web_fetch 上游诊断（P05）

```yaml
change: PC-20261111-bot-webfetch-diagnostics
contracts: [P05]
status: implemented
breaking: false
version_decision: Human-readable diagnostic text only. The HTTP status, the JSON-RPC error code (-32000), the sensitive response path, header filtering, redaction and the no-log rule are unchanged. No new field, header, error code or route is added; clients must not parse the message.
base: de47c0ee
contract_revision: spec/v1/gateway-official-web.md@webfetch-diagnostics-20261111 + spec/v1/gateway-security.md@webfetch-diagnostics-20261111
```

Protocol impact: P05. P01, P06, P08, P09: none — the change is inside the host gateway's controlled
response body; no channel frame, host event, UI projection or platform API changes. P17: none — the
`/v1/http` request/response envelope is unchanged.

## 1. 识别与角色

- **Trigger → 现状 → 期望.** Bot 的 `web_fetch` 在
  `https://raw.githubusercontent.com/launsion-boop/phone-dsh/main/README.md` 上收到
  `Error: DeepSeek API error (HTTP 404): MCP upstream returned HTTP 404; response body withheld`。
  实测目标 URL 返回 200（`text/plain`），`api.github.com` 与 `example.com` 同时 200；DeepSeek 的
  Search/Fetch API 文档把 404 定义为「Fetch could not retrieve usable page content」，包括不可用
  URL、站点策略拦截、不支持的内容类型、无可提取 Markdown。真正的上游是 DeepSeek 服务端的 Fetch
  API，不是宿主的白名单或 content-type 过滤。宿主的 controlled diagnostic 却把官方 web 调用叫作
  `MCP upstream`，且只有 `response body withheld`，无法区分目标不可取回、上游策略拒绝与上游服务
  故障。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `bot/webfetch-raw`
  兼任 contract owner 与 implementer；先在 P05 的 owning contract 冻结诊断语义，再实现 Swift
  reference 与 Kotlin `:net` parity。
- **Owning spec / fixtures.** `spec/v1/gateway-official-web.md`（官方 Search/Fetch 路由）与
  `spec/v1/gateway-security.md` §6（sensitive response）；既有 golden `resp-001` 只锁 MCP 文本，
  语义不变，因此不新增/不改 golden。MCP 的既有字节继续由 `resp-001` 固定；web tool 的新字节由
  Swift/Kotlin 单元测试逐字固定。
- **受影响的 producer／consumer.** Producer：`Sources/PhoneDSHGateway/SensitiveResponseBody.swift`
  （Swift reference）与 `android/net/src/main/kotlin/com/phonedsh/gateway/SensitiveResponseBody.kt`
  （Kotlin parity）。Consumer：Worker 内 DSH `@deepseek-ai/dsh-web-deepseek-api` 把 JSON
  `error.message` 拼进 `DeepSeek API error (HTTP <status>): <message>`；它只读 message，不解析
  其他 member。HarmonyOS 的 official web 路径目前没有 sensitive response body 实现（partial），
  本单不声称其已对齐。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| Sensitive call 种类 | 所有 sensitive call 共用 `MCP upstream returned HTTP <status>; response body withheld` → 新增 call kind：`.mcp` 与 `.webTool`。MCP 文本逐字不变；官方/独立 web Search/Fetch 使用 web tool 文本。`gateway-security.md` §6。 |
| 404 | `MCP upstream returned HTTP 404; response body withheld` → `the web tool could not retrieve usable target content: the URL may be missing, blocked by the site, an unsupported content type, or have no extractable Markdown (HTTP 404). The upstream response body was withheld by the host.` |
| 403 | 同上 MCP 文本 → `the upstream web service's security policy rejected the target (HTTP 403). The upstream response body was withheld by the host.` |
| 401/402 | 同上 MCP 文本 → 指明 API key 被拒 / 账户余额不足，并保留状态与「body withheld by the host」。 |
| 429 | 同上 MCP 文本 → 指明上游限流并建议等待后重试。 |
| 5xx | 同上 MCP 文本 → 指明上游服务故障并建议稍后重试。 |
| 其它状态 | 仍返回状态 + 原因，不再只有 `response body withheld`。 |
| Oversize（2xx） | web tool 的超限诊断不再自称 MCP；MCP 文本逐字不变。 |
| 机器可读面 | HTTP status、`X-PDSH-Proxy-Error`、JSON-RPC `code:-32000`、`jsonrpc`/`id` 均不变；只有 `error.message` 的展示文本改变。宿主自身的出口策略拒绝仍是 pre-dispatch 的 `host_not_allowed` 403 envelope，不会进入本诊断。 |
| 条款状态 | 仍是 `implemented` 的既有 P05 规则；本单不新增 target/draft 条款。 |

自检（`spec/README.md` §5.1）：没有第二种表达（仍是一个 JSON-RPC controlled error）；没有新增
wire 字段/enum/错误码；没有收窄或放宽输入；旧 reader 只读 `error.message`，新文本仍可显示；回滚
只会恢复旧文本，不影响状态、码或日志。

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 旧 Worker 收到的仍是同一 HTTP status、同一 JSON-RPC `code:-32000` 与同一 `content-type`；只显示新文本。MCP 文本逐字不变，`gw-resp-001` 继续通过。 |
| new → old | 回滚到旧 Swift/Kotlin 只恢复旧文本；没有持久化格式、没有新字段，旧 Worker 不需要迁移。 |
| new → new | Swift 与 Kotlin 用同一组状态（401/402/403/404/429/5xx/其它）固定 message 片段；MCP 默认 kind 的字节由 `gw-resp-001` 固定。 |
| persisted old data → new／rollback | 无持久化变化；response log 仍不记录 sensitive 响应，滚回无数据迁移。 |

- 版本决定：不升协议版本，不改 `proto: 1`、`/v1/http` envelope 或 gateway golden schema。
- 发布顺序：Swift host 与 Worker bundle 无需原子更新；Worker 只消费 message。Kotlin 与 Swift 同仓
  构建，发布时一起带出。
- `target`／`draft` 差异：无；P05 的响应脱敏规则原本就是 `implemented`。

## 4. 分工与证据

- Contract owner / implementer 路径：`spec/v1/gateway-official-web.md`、
  `spec/v1/gateway-security.md`、`Sources/PhoneDSHGateway/{SensitiveResponseBody,ModelGateway}.swift`、
  `android/net/src/main/kotlin/com/phonedsh/gateway/{SensitiveResponseBody,GatewaySession,OfficialDeepSeekWebTools,IndependentSearchWebTools}.kt`、
  `Tests/PhoneDSHGatewayTests/**`、`android/net/src/test/kotlin/com/phonedsh/gateway/**`、
  `plugins/tests/bot-egress-spike.test.ts`（只加 mock 回归，不改插件生产代码）。
- Shared fixtures：无新增 golden。MCP 字节继续由 `spec/v1/golden/gateway/resp-001.json` 固定；
  web tool 的状态映射由 `gateway-official-web.md` 的 normative 段落与两端测试固定。
- Runtime 测试：`swift test --disable-sandbox --filter PhoneDSHGatewayTests`；Kotlin
  `:net` 的 `OfficialDeepSeekWebToolsTest` / `GatewayRuleTest`（有 Android 构建环境时）；
  Node mock 回归证明 DSH provider 把新 message 拼进用户看到的错误。
- Exact commands 与结果：见任务报告。
