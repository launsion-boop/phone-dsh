# @phone-dsh/dsh-phone-mcp — phone Worker 的 HTTP MCP 管理

MIT。为 **Streamable HTTP MCP** 提供 phone 侧唯一注册表：Host 启动时读取
`/dsh/home/mcp.json`，用官方 `@deepseek-ai/dsh-mcp-client` 动态挂载 enabled 项，
并在现有 `phone` Remote 命名空间提供 `phone/mcp`（通用 action 分发）以及
`phone/mcpList`、`phone/mcpUpsert`、`phone/mcpRemove`、`phone/mcpReconnect`。浏览器端只向
`settings.plugins.tab` 注册一个 MCP 标签页，通过同一个 DSH Connection 调用。

不做 stdio、不拉子进程、不接远端 PC、不另写协议。JSON 永远只保存
Header 名 → 环境变量名；手机 App 中 `hostManagedHeaders` 里的 Header 只发送
非秘密占位值 `phone-host-injects-mcp-key`，由原生网关按精确 URL 丢弃占位值并
注入独立 Keychain 中的真实值。没有原生 bridge 时仍沿用 `process.env` 解析。
Header 值不写入文件、日志或错误消息。

## 配置

`/dsh/home/mcp.json`（或 `$DSH_HOME/mcp.json`），带版本、严格校验：

```json
{
  "version": 1,
  "servers": [
    {
      "serverName": "github",
      "url": "https://mcp.example.invalid/mcp",
      "headersFromEnv": { "Authorization": "GITHUB_MCP_TOKEN" },
      "hostManagedHeaders": ["Authorization"],
      "enabled": true,
      "toolCallTimeoutMs": 60000
    }
  ]
}
```

写入/挂载前强制校验：

- `serverName` 必须匹配 `[A-Za-z0-9_-]{1,32}`；
- `url` 必须是绝对 http(s) URL，拒绝内嵌账号密码；
- `headersFromEnv` 的值必须是环境变量名；缺失/为空时拒绝 upsert/reconnect，
  并明确指出变量名，绝不发送空 Header；`hostManagedHeaders` 中的 Header 必须同时
  出现在 `headersFromEnv` 中，发送占位值而不是读取环境变量；
- 拒绝未知字段（`transport`、`command`、`headers`、`token` 等）；
- 拒绝重复 `serverName`；
- 写文件使用同目录私有临时文件 + rename，失败时旧文件和旧挂载都保留。

## 行为

- `list` 返回持久化行、真实子 fiber 挂载状态，以及每个 mount 自己注册的精确
  `mcp__<serverName>__<tool>` 集合（通过注册 disposer 跟踪）；不伪造工具，也不按
  字符串前缀猜归属，因此 `a` 与 `a__b` 不会互相串工具。`authentication` 明确区分
  无认证（`none`）、Worker 环境变量（`headers-env`）和主机独立 Keychain 注入
  （`host-managed`）。
- `upsert` 先校验、解析环境变量，再用 `failOnStartupError: true` 挂载官方
  `dsh-mcp-client`；只有初次连接和工具同步都成功后才写文件。serverName 冲突或
  连接失败会返回已脱敏、有长度上限的诊断，不写文件。
- 官方 client 的连接失败信息可能包含服务器 HTTP 响应 body。行错误、抛出的错误
  和官方 client 自己的日志都会按已解析的 header 值脱敏并截断，原始 transport
  cause 不会继续挂到错误对象上。
- `remove` 先 dispose 子 fiber（工具立刻从注册表消失），再改文件；写失败会恢复旧挂载。
- `reconnect` 先卸载再重挂，并重新读取环境变量。
- 启动只挂 enabled 项。文件损坏或单行连接失败会作为快照错误返回，不会拖垮 Host；
  之后一次合法 upsert 可以修复文件。
- 初次挂载后的断线重连/退避由官方 client 负责；这里展示的是初次连接后的状态与
  实时工具投影，官方包没有单独导出“静默重连中的 transport 健康状态”。

## 导出与集成契约

| 导出 | 含义 |
|---|---|
| `.` | Host Cordis 插件（`name`、`inject: ['tools']`、`apply`）与 `PhoneMcpManager` |
| `./client` | 浏览器入口，向 `settings.plugins.tab` 注册 id 为 `phone-mcp` 的标签页 |
| `protocol.ts` | Host/Client 共享类型，无运行时依赖 |

最终集成任务负责 profile、workspace 和 build：

1. 把 `phone-mcp` 加入 `plugins/package.json` workspaces；
2. 在 phone profile 加一行 `@phone-dsh/dsh-phone-mcp`（Host+Client 同一个包）；
3. 用 DSH 自己的 client bundle 构建 `./client`，让 `react` /
   `react/jsx-runtime` / `@deepseek-ai/dsh-client-*` 复用共享 module loader。
   `scripts/pack-image.mjs` 当前的通用 ESM staging 会把 React 打进页面包，
   不能直接作为最终 page asset。

## 测试

```sh
cd plugins
node --test tests/phone-mcp.test.ts
npx tsc -p phone-mcp/tsconfig.json
```

Node 测试会启动本地带认证的 Streamable HTTP MCP fixture，验证
`add → list → 真实工具调用 → reconnect → remove`、工具消失，以及错误
URL/重复 serverName/缺失 env 被拒绝且不写文件、JSON 不含 token；另一个 fixture
验证 host-managed Header 只发送占位值且不持久化真实值。测试运行在 Node，不是
WKWebView；Mac/iPhone 验收仍是 NOT_RUN。

手机客户端会在 upsert 前通过原生 `pdshMcpControl` bridge 提交精确 URL 授权事务，
并 upsert bridge 返回的 canonical `grant.url`。原生按 canonical endpoint
（scheme/host/有效端口/规范化 path/query；fragment 不参与）比较，尾斜杠或默认端口
不会被误判成旧行。upsert 成功才 commit；失败时只有真实 registry 明确仍是上一份
旧行（或新行确认不存在）才回滚旧授权/旧 Keychain 值；回包丢失/页面退出/崩溃/超时
只把持久 staging 标记为 abandoned，留待下一次真实 `phone/mcpList` 或 materialized
registry 决定。upsert 已成功而 commit/cleanup 失败只进入 commitPending，绝不重新
获得回滚已提交 Worker 行的能力。仍缺认证值的行会先回滚，再带着非秘密字段打开
**MCP 网络与密钥** 页填写真实值。删除成功后 revoke。
完整流程见仓库根目录 the maintainer guide。

## Mac 验收（Linux 为 NOT_RUN）

在 Mac 构建并运行 phone App，打开 Settings → Plugins → **MCP**，添加一个本地
Streamable HTTP MCP，确认模型工具列表出现 `mcp__<server>__<tool>`；删除后确认
工具消失。带认证的服务器需打开 **设备网络与密钥** 输入 header 值后重连；未授权
host 必须仍被拒绝（不接受 `*`、不改全局 allowlist）。Linux 上此验收为 NOT_RUN。
