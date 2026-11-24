# 设计稿：Phone DSH 第三方连接器（MCP + OAuth）

- 日期：2026-11-24
- 状态：建议稿，未实施
- 基线：phone-dsh `8374cee7f`；DSH pin `0.2.1-rc.2`（[`plugins/dsh-pin.json`](../plugins/dsh-pin.json)）；上游参照 deepseek-harness `dsh-v0.2.3-alpha.2`（`4b399c39a6`）
- 范围：Linear、Notion、腾讯文档三个托管 MCP 连接器；飞书、钉钉、企业微信、腾讯会议四个 CLI 连接器只做结论与后续评估
- 验证边界：本文基于源码阅读，没有真机、没有对各厂商 OAuth 服务做过实测。第 9 节列出的假设必须先用 spike 证实

## 1. 决策摘要

1. **采用宿主侧 OAuth（方案 B）**：OAuth 授权、令牌保存和刷新全部放在原生宿主，令牌只存 Keychain。Worker 继续通过现有的 [`phone-mcp`](../plugins/phone-mcp/README.md) 行挂载 MCP 服务器，并用已有的 `hostManagedHeaders` 占位符机制，由网关注入 `Authorization`。
2. **不挂载上游的 `dsh-linear` / `dsh-notion` / `dsh-tencent-docs` 插件**，也不在 Worker 里启用 `ctx.credentials`、`ctx.authorization`。这样能保住 phone DSH 的不变量：机密不进 Worker。
3. **和 DSH runtime 升级解耦**：方案 B 不依赖 DSH 0.2.3，可以在当前 pin 上交付。runtime 升级作为独立项目推进；升级后，上游连接器行在 phone profile 中保持禁用（见第 8 节）。
4. **CLI 类连接器在 iOS 不可用**，本期不做，第 7 节给出逐个评估的路径。

## 2. 现状

### 2.1 上游 DSH 2.3 的连接器

上游 `packages/connector/` 有两类插件：

| 类别 | 插件 | 机制 |
|---|---|---|
| MCP + OAuth | `linear`、`notion`、`tencent-docs` | 约 60 行插件：向 `ctx.mcpManager` 注册托管 streamable-http 服务器，带 `oauth.credentialKey`；向 `ctx.systemPrompt` 加称呼指引；向 `ctx.mcpAccounts` 注册插件页账号 |
| 厂商 CLI | `feishu`、`dingtalk`、`wecom`、`tencent-meeting` | 下载或安装厂商原生二进制（`lark-cli`、`dws`、`wecom-cli`、`tmeet`），经 subprocess 执行；`cli-account` 管账号，`upstream-skills` 下载技能 |

上游托管端点：

| 连接器 | 端点 |
|---|---|
| Linear | `https://mcp.linear.app/mcp` |
| Notion | `https://mcp.notion.com/mcp` |
| 腾讯文档 | `https://docs.qq.com/openapi/mcp` |

上游 OAuth 流程（`packages/mcp/mcp-client/src/oauth.ts`）依赖三项服务：

- `ctx.authorization`：注册并驱动授权 flow；
- `ctx.webServer`：回调地址为 `webServer.getOrigin() + '/mcp/oauth/callback/<sha256(credentialKey)>'`；
- `ctx.credentials`：通过 `readRecord` / `modifyRecord` 保存授权记录，刷新令牌在 `modifyRecord` 的锁内完成。

### 2.2 phone DSH 的约束

- **机密不进 Worker。** worker profile 故意禁用 `authorization` 和 `credentials`（[`phone.worker.cordis.patch.yml:196-199`](../plugins/profile/phone.worker.cordis.patch.yml)）。模型密钥、搜索密钥、MCP 请求头都由原生网关注入。
- **MCP 已有宿主注入路径。** [`phone-mcp`](../plugins/phone-mcp/README.md) 的行里，被列入 `hostManagedHeaders` 的请求头只发送占位符 `phone-host-injects-mcp-key`（[`ModelGateway.swift:1028`](../Sources/PhoneDSHGateway/ModelGateway.swift)）。网关丢弃占位符后，由 [`PhoneMCPCredentialProvider`](../Sources/PhoneDSH/PhoneMCPAccessSettings.swift)（第 303 行）按精确 URL 注入 Keychain 中的值。
- **宿主凭据协议本来就支持刷新。** [`CredentialProvider`](../Sources/PhoneDSHAgentCore/Credentials.swift)（第 89 行）的约定是：`credential(for:)` “在需要时刷新”；`invalidate(_:for:)` 之后，下一次调用必须刷新或抛 `unauthorized`。但目前 `PhoneMCPCredentialProvider.invalidate` 对 MCP 路由直接返回（第 319 行），网关也没有在 401 时调用 `invalidate`。
- **Worker 的 webserver 不绑定真实 socket。** 它是被截获的监听器，经原生 loopback 转发，端口是虚拟的（`PDSH_DSH_PORT`）。上游回调地址依赖 `getOrigin()`，在手机上能否被外部浏览器回调命中，没有证据。

## 3. 目标与非目标

### 3.1 目标

- 用户在原生“连接器”页点一下连接，完成 OAuth 授权后，对话中可以使用 Linear、Notion、腾讯文档的 MCP 工具。
- 令牌只存在 Keychain；Worker、VFS、WAL、日志、`mcp.json` 里都不出现令牌。
- 访问令牌过期时自动刷新；刷新失败时界面显示“需要重新授权”，模型看到的是明确的未连接状态。
- 断开连接时删除本地授权，撤回 MCP 行。

### 3.2 非目标

- 不运行 CLI 类连接器（第 7 节）。
- 每个连接器只支持一个账号。
- 不在 Worker 里实现 DSH 的 `ctx.credentials` 存储。
- 不改上游 DSH 源码（保持 zero DSH patch，`scripts/ci/no_dsh_patch.py`）。
- 本期不做远端令牌吊销（RFC 7009）；断开连接只删除本地授权，和上游 `signOut` 的行为一致。

## 4. 方案比较

| | A：挂载上游连接器插件 | B：宿主侧 OAuth（推荐） |
|---|---|---|
| Worker 内 | `mcp-manager`、`mcp-account`、三个连接器插件、`authorization`，以及新的 `ctx.credentials` 提供方 | 不变，只是多几行 `phone-mcp` |
| 令牌位置 | Worker 内存中持有明文访问令牌和刷新令牌；落盘由 Keychain 代理完成 | 只在宿主 Keychain 和网关里 |
| OAuth 回调 | 外部浏览器要回调 Worker 的虚拟 loopback 源，可行性未知 | `ASWebAuthenticationSession` 直接拿到回调 URL |
| 新协议面 | `ctx.credentials` 的跨进程代理：`modifyRecord` 的异步 mutate 回调要跨 Worker 和宿主持锁，需要新的 Remote 方法和租约语义 | 网关遇到 401 时 invalidate 并重试一次；新增宿主连接器目录。Worker 侧不新增字段 |
| 依赖 DSH 升级 | 需要升到 ≥0.2.3 | 不需要 |
| 和上游的一致性 | 高：账号 UI、称呼指引、`toolLoading` 都现成 | 要在原生侧重做连接器目录、账号 UI 和称呼指引 |

**选 B 的理由**：A 会打破“机密不进 Worker”这一条最核心的安全不变量，还要新造一个带跨边界锁的凭据协议，并且必须先完成工作量很大的 runtime 升级。B 复用已经存在并经过测试的注入路径，新增的部分都在宿主内部。B 的代价是 UI 和称呼指引要自己写，但每个连接器在上游也只有约 60 行，复制成本很低。

## 5. 方案 B 详细设计

### 5.1 组件

```text
┌──────────── 原生 App ─────────────────────────────────────────┐
│ ConnectorsPage（发现 → 连接器）                                │
│        │ connect / disconnect / status                          │
│ PhoneConnectorService ── PhoneConnectorCatalog（静态目录）     │
│        │                    linear / notion / tencent-docs      │
│        ├── PhoneMCPOAuthClient                                  │
│        │     发现 → 动态注册 → PKCE → ASWebAuthenticationSession│
│        │     → 换取令牌 → 刷新                                  │
│        ├── Keychain：connector.<id>.v1（令牌 + 客户端注册信息） │
│        ├── PhoneMCPAccessSettings / MCPEgressPolicy（放行该 URL）│
│        └── phone/mcpUpsert、phone/mcpRemove（现有 Remote 方法） │
│                                                                 │
│ ModelGateway ── PhoneMCPCredentialProvider                      │
│        路由命中连接器 → 取有效令牌（快过期时先刷新）            │
│        → 注入 Authorization: Bearer …                           │
│        401 → invalidate → 刷新 → 重试一次                       │
└─────────────────────────────────────────────────────────────────┘
┌──────────── Worker（不变）────────────────────────────────────┐
│ phone-mcp 行：{serverName:"linear", url, headersFromEnv:        │
│   {Authorization:"PDSH_CONNECTOR_LINEAR"},                      │
│   hostManagedHeaders:["Authorization"]}                         │
│ → 官方 dsh-mcp-client 只发送占位符                              │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 连接器目录

`PhoneConnectorCatalog` 是原生侧的静态表。每项包含：`id`、`serverName`（与上游同名：`linear`、`notion`、`tencent-docs`，让工具名 `mcp__linear__*` 和上游一致）、`url`、显示名、图标、可选的预注册 `clientId` 和 `scope`、称呼指引文本。

- 目录随 App 发布，不能通过 Worker 修改。
- `serverName` 进入保留名单：Web MCP 页的 `mcpUpsert` 如果用这些名字手动加行，宿主应拒绝授予访问，避免和连接器抢同一个 Keychain 路由。这是 `PhoneMCPAccessSettings` 内部的校验，Worker 的 schema 不变。

### 5.3 OAuth 客户端

`PhoneMCPOAuthClient` 实现 MCP 授权规范要求的客户端流程：

1. **发现**：先请求 MCP 端点；从 401 的 `WWW-Authenticate` 头或 `/.well-known/oauth-protected-resource`（RFC 9728）读到授权服务器，再取它的 `/.well-known/oauth-authorization-server`（RFC 8414）元数据。
2. **客户端注册**：目录里有 `clientId` 就用；否则做动态客户端注册（RFC 7591）。注册结果（client_id 和可能有的 client_secret）存进 Keychain，按 `(serverURL, issuer, redirectURI)` 复用，和上游 `clientKey` 的做法一致。
3. **授权**：PKCE S256，加 `state` 和 `resource`（RFC 8707）。用 `ASWebAuthenticationSession` 打开授权页，`prefersEphemeralWebBrowserSession = false`，以便复用 Safari 的登录状态。
4. **回调**：首选自定义 scheme `phonedsh-oauth://callback/<id>`。如果某个厂商的动态注册拒绝自定义 scheme，退而使用 Universal Link 的 https 回调（iOS 17.4+ 的 `ASWebAuthenticationSession.Callback.https`）。这需要逐个厂商实测（第 9 节）。
5. **换取令牌**：用 code + verifier 换令牌；校验 `state`，以及 `iss`（如果返回了的话）。
6. **保存**：一次 Keychain 写入记录 `{accessToken, refreshToken?, expiresAt, scope, issuer, clientRef}`。写成功之后才授予访问、挂载 MCP 行（顺序见 5.6）。

所有 OAuth 请求都走宿主自己的 `URLSession`，不经过 Worker；要求 HTTPS，禁止跟随重定向，和上游 `oauth-credentials.ts` 的约束保持一致。

### 5.4 注入与刷新

- `MCPEgressPolicy.Route` 增加一种凭据来源：`.oauth(connectorID)`，与现有的静态 headers 并列。
- `PhoneMCPCredentialProvider.credential(for:)` 命中 `.oauth` 路由时：
  - 令牌在 `expiresAt - 60s` 之前，直接返回 `Authorization: Bearer <token>`；
  - 否则在每个连接器各自的 actor 锁内刷新，同一时刻只有一个刷新请求，其余调用等它的结果；
  - 刷新返回 `invalid_grant`，或没有 refresh token：把连接器标为 `needsReauth`，返回 `.none`。服务器随后会返回 401，模型看到的是工具调用失败。
- `invalidate(_:for:)` 命中 `.oauth` 路由时，把该令牌标记为失效，下次调用会强制刷新。
- **网关新行为**：一个带宿主注入凭据的 MCP 请求收到 401 时，调用 `invalidate`，然后**只重试一次**。只对请求体能完整重放的请求重试；网关能否重放 MCP 的 streamable-http POST 请求体还没有核实（见 S4）。已经开始流式传输的响应不重试。这是 P05 的行为变更，见第 6 节。

### 5.5 Worker 侧的行

连接成功后，宿主通过现有的 `phone/mcpUpsert` 写入：

```json
{
  "serverName": "linear",
  "url": "https://mcp.linear.app/mcp",
  "headersFromEnv": { "Authorization": "PDSH_CONNECTOR_LINEAR" },
  "hostManagedHeaders": ["Authorization"],
  "enabled": true,
  "toolCallTimeoutMs": 60000
}
```

- 所有字段都是现有 schema 里已有的，Worker 侧不新增字段。
- 环境变量名只作占位，`hostManagedHeaders` 中的头不会做环境变量查找（[phone-mcp README](../plugins/phone-mcp/README.md)）。
- **称呼指引**：上游通过 `ctx.systemPrompt` 告诉模型“这是 Linear 插件”。phone-mcp 目前没有这个钩子。v1 接受这个差距，依靠服务器自己的 MCP instructions。如果实测发现模型称呼混乱，再单独提一个变更：给 phone-mcp 加称呼指引字段（P11）。

### 5.6 状态机与写入顺序

```text
notConnected ──connect──▶ authorizing ──成功──▶ connected
     ▲                        │失败/取消              │
     │                        ▼                       │刷新失败
     │                   notConnected                 ▼
     └──────disconnect──────────────────────────  needsReauth ──connect──▶ authorizing
```

连接时复用 `PhoneMCPAccessSettings` 现有的 grant 事务（staged grant → Worker `phone/mcpUpsert` → commit，见该文件第 370、437、571 行）：
1. Keychain 写入授权记录；
2. 暂存（stage）`PhoneMCPAccessGrant`；
3. 调用 `phone/mcpUpsert`；
4. upsert 成功后提交（commit）grant，`MCPEgressPolicy` 开始放行。

任何一步失败都按相反顺序回滚。原生发起这个事务的路径已经存在：probe App 的 [`MCPSettingsModel`](../examples/probe-app/PhoneDSHProbe/MCPSettingsModel.swift) 直接调用 `phone/mcpList`、`phone/mcpUpsert`、`phone/mcpRemove`，并配合 grant 暂存和提交，`PhoneDSHSimTests/MCPSettingsModelTests.swift` 有测试覆盖。`PhoneConnectorService` 复用这个模型的事务逻辑，不再新写一套。断开连接时的顺序：
1. `phone/mcpRemove`；
2. 撤销 grant；
3. 删除 Keychain 记录。

这样，任一时刻都不会出现“Worker 有行、宿主却会注入陈旧令牌”的状态。这和 `PhoneMCPAccessSettings` 现有的先写 secret、再提交引用的顺序保持一致。

**Worker 冷启动**：`mcp.json` 由 WAL 持久化，连接器行会一直存在。宿主启动时用 Keychain 状态做一次对账：有行但没有授权，就把连接器标为 `needsReauth`，行保留但注入 `.none`；有授权但没有行，就补写这一行。

### 5.7 UI：放进“发现”页的连接器列表

入口是底部导航“发现”标签里的连接器页 `ConnectorsPage`（`examples/probe-app/PhoneDSHProbe/ConnectorsPage.swift`）。

> 前提：“发现”页由 `42fbd12c0`（2026-11-08）引入，已合入 `origin/main`（截至 `41879bc82`），但本设计稿所在分支基于更早的 `8374cee7f`。实现前先把分支 rebase 到最新的 `main`。Android 的 `HostShell.kt` 也有对应的“发现”页，Android 版本另行跟进。

现状：`ConnectorsPage` 用 `DiscoverConnector` 枚举列出连接器，当前有 `gmail`、`github`、`devices`、`webSearch`、`mcp` 五项。点一行会弹出半屏的 `ConnectorDetailSheet`，点其中的操作按钮再推入对应的设置页；其中 `mcp`（“自定义 MCP 服务”）推入的正是 `MCPSettingsPage`。

改动：

- `DiscoverConnector` 新增 `linear`、`notion`、`tencentDocs` 三项，数据来自 5.2 节的 `PhoneConnectorCatalog`，不在枚举里硬编码 URL。
- 行右侧的药丸按钮按状态显示：未连接显示“连接”，已连接显示“已连接”，需要重新授权显示“重新连接”。
- 详情弹窗沿用现有样式（图标、名称、一个操作按钮、用途说明、“关于此连接器”）。操作按钮：
  - 未连接或需要重新授权时，直接调用 `PhoneConnectorService.connect`，打开 `ASWebAuthenticationSession`，不再推入设置页；
  - 已连接时，推入一个简单的账号页，显示账号标识和工具数量，提供“断开”。
- 图标复用上游各连接器包里的 `icon.svg`（`packages/connector/<name>/icon.svg`），沿用上游的许可证；放进 Asset Catalog 前先确认许可证允许。
- “自定义 MCP 服务”这一行保持不变，仍然推入 `MCPSettingsPage`。在那个页面里用 5.2 节的保留名单过滤掉连接器的行，连接器只能在自己的卡片上断开。
- **Web MCP 页**（phone-mcp 的 `McpSettingsTab`）在手机上不作为入口，避免出现两个都能改同一份 `mcp.json` 的地方。实现时先确认手机上的 Web 设置页能不能打开它；如果能，就在 phone profile 里禁用这个客户端标签行。桌面或 Web 端照旧使用它。
- 对账依然保留（5.6 节）。如果连接器行在别处被删除，冷启动对账会把连接器标为“需要重新授权”，并在“发现”页对应的行上显示，不静默恢复。

关于 Gmail：现有的 `GmailSignIn.swift` 走 Google Sign-In SDK（`refreshTokensIfNeeded`），只适用于 Google，不能复用为通用的 MCP OAuth 客户端；它和本方案并存，互不影响。

## 6. 契约冻结

> 注：AGENTS.md 提到的 `spec/README.md` 登记表和 `docs/protocol-change-template.md` 在当前树里不存在（只有 `spec/v1/`）。下面按 AGENTS.md §3.1 列出的字段写出，ID 取自 AGENTS.md §1 的触发表。

- **基线 commit**：`8374cee7f`
- **Protocol impact**：
  - **P05**：网关新增“宿主注入凭据的请求收到 401 时 invalidate 并重试一次”；`PhoneMCPCredentialProvider` 新增 `.oauth` 凭据来源。
  - **P11**：phone-mcp 的 schema 和 Remote 方法都不变，但多了一个调用方：宿主会主动调用已有的 `mcpUpsert` / `mcpRemove`。Worker 端不改代码。按“不确定就当作有影响”的规则，声明 P11。
  - **P10 / P13：none**。插件的 contract、types 都不改。
  - **P04：none**。入口在原生“发现”页里，不经过 WebView 桥（`pdshMcpControl` 不加新消息）。
  - **P06：none**。不新增 host event。
  - **P14 / P15 / P16：none**。不新增 `/api` 路由；`PDSH_CONNECTOR_*` 只作为 `headersFromEnv` 里的占位名，不会被读取，也不注入 Worker 环境。
  - **P12：none**。不改 `Package.swift` 的产品。如果用到 `AuthenticationServices`，它只在 `PhoneDSH` 目标内部使用；若需要新增 target，再另行声明。
- **兼容矩阵**：

| 情形 | 行为 |
|---|---|
| 旧 App + 新数据（`mcp.json` 里已有连接器行，旧 App 没有连接器目录） | 旧 App 没有对应的 grant，`MCPEgressPolicy` 拒绝出站，fail-closed |
| 新 App + 旧数据 | 没有连接器行，状态为 `notConnected` |
| 新 App + 用户手动加的同名行（`linear`） | 宿主拒绝授予访问，并提示改名；不覆盖用户的行 |
| 回滚到旧 App | Keychain 里的连接器记录成为孤儿，但没人读取，不会泄露；重新升级后对账恢复 |

- **验证**：
  - 单测覆盖 OAuth 客户端的发现、注册、PKCE、刷新、刷新并发；
  - 网关 401 重试只发生一次，且只对可重放的请求体；
  - 写入顺序被打断时的故障注入；
  - Keychain 值不出现在 Worker 环境、`mcp.json`、日志和 WAL 中（扩展现有的 phone-mcp 测试）。

## 7. CLI 类连接器（飞书、钉钉、企业微信、腾讯会议）

上游实现依赖 spawn 厂商原生二进制。iOS 没有子进程，phone 的 `subprocess-xl` 也不提供这种能力。结论：

- 本期不做。DSH 升级以后，这四个插件行必须在 phone profile 中保持禁用。否则它们的 skill 会教模型调用一个不存在的 CLI。
- 后续按成本从低到高逐个评估：
  1. **厂商托管 HTTP MCP**：如果厂商提供 streamable-http MCP 并支持 OAuth，直接加进第 5.2 节的目录，零新增机制。各厂商是否提供，尚未核实。
  2. **handoff 远端主机**：在 PC 或 devbox 上运行 CLI，走现有的 handoff 协议。
  3. **原生封装 OpenAPI**：经 App 自有 MCP（`PDSH_PHONE_MCP_URL`）暴露原生工具。工作量最大，只对高频场景考虑。

## 8. 与 DSH runtime 升级的关系

- 方案 B 不依赖升级，可以先交付。
- runtime 升级（`0.2.1-rc.2` → `0.2.3-*`）单独立项。升级时要保证：
  - 上游七个连接器插件，以及 `mcp-manager`、`mcp-account`、`cli-account`、`upstream-skills` 在 phone profile 里都不启用，或者确认它们没有进入 phone 镜像；
  - 如果上游 MCP 客户端随升级新增了 `toolLoading: 'on-demand'` 之类的能力，可以考虑给 phone-mcp 加对应字段。那是单独的 P11 变更。
- 如果将来决定改用方案 A，第 5 节的原生 OAuth 客户端可以用来实现 Keychain 代理的 `ctx.credentials`，不会白做。但前提是先解决“机密进 Worker”的安全决策。

## 9. 待验证假设（spike 清单）

| # | 假设 | 验证方法 | 不成立时 |
|---|---|---|---|
| S1 | 三家都支持 RFC 9728 / RFC 8414 发现，并支持动态客户端注册 | 用 curl 走一遍发现和注册 | 向厂商申请预注册 `clientId`，写进目录 |
| S2 | 动态注册接受自定义 scheme 作为 redirect URI | 注册时提交 `phonedsh-oauth://…` | 改用 Universal Link 的 https 回调（需要关联域名） |
| S3 | 刷新令牌可用，并且有合理的有效期 | 真实授权后观察 `expires_in` 和刷新行为 | 没有 refresh token 时，过期后进入 `needsReauth` |
| S4 | MCP POST 请求体在网关处可以完整重放 | 读 `ModelGateway` 的 streaming 路径并加测试 | 401 时不重试，只 invalidate，下一次调用才生效 |
| S5 | 服务器的 instructions 足以让模型正确称呼和使用工具 | 真机对话抽样 | 给 phone-mcp 加称呼指引字段（P11） |
| S6 | 三家的工具数量不会撑爆上下文（当前 pin 没有按需加载工具） | 统计 `tools/list` 的条目数和 token 数 | 在 Worker 行上限制工具，或者等升级后用 `toolLoading` |

## 10. 分阶段实施与验收

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0 | S1–S4 spike，挑一家（建议 Linear）跑通 | 真机上完成授权，Worker 的 MCP 调用成功；Worker 环境和 VFS 中搜不到令牌 |
| P1 | `PhoneMCPOAuthClient`、`.oauth` 路由、网关 401 重试、连接器目录；在“发现”页的 `DiscoverConnector` 中加入连接器项（实现分支需基于最新 `main`）；先只上 Linear | 第 6 节的测试全部通过；断开后工具消失，出站被拒绝 |
| P2 | Notion、腾讯文档加入目录 | 每家一条真机授权和工具调用记录 |
| P3 | 冷启动对账、`needsReauth` 的 UX、Web MCP 页同名行的处理 | 故障注入测试；杀进程后能恢复 |
| 后续 | CLI 类逐家评估（第 7 节）；DSH runtime 升级（第 8 节） | 各自单独立项 |
