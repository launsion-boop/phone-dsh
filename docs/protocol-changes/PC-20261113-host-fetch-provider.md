<!-- SPDX-License-Identifier: MIT -->
# PC-20261113-host-fetch-provider — `web_fetch` uses the host-routed provider

## 0. 摘要

```yaml
change: PC-20261113-host-fetch-provider
contracts: [P05]
status: draft
breaking: false
version_decision: 不升版本。`PDSH_WEB_FETCH_PROVIDER` 的值在独立搜索模式下由 `deepseek-fetch-api` 改为 `phone-host-fetch`；旧值 `deepseek-fetch-api` 仍被 Worker profile 接受（legacy 条件保留），所以旧 host + 新 Worker 不中断。没有 wire/envelope/schema 字段变化。
base: 4864dfdc66dbcb4b8fd9efc83bb05dacaeb7e173
contract_revision: 本单所属 commit（draft）——`spec/v1/gateway-independent-search.md` §3 表、`plugins/profile/phone.worker.cordis.patch.yml` 的 `web`/`tool-web`/`web-fetch-host` 行
```

## 1. 识别与角色

- **Trigger → 现况 → 期望。** 真机 `web_fetch https://raw.githubusercontent.com/...` 三次复测均返回 `DeepSeek API error (HTTP 404): … unsupported content type, or have no extractable Markdown`，同一 URL `curl` 200 / 23,532 字节 `text/plain`。独立模式的 fetch 走远端 `deepseek-fetch-api`，它要求可抽取 Markdown，原始文本文件不满足；`WebSearchHostConfiguration` 的 follow-model 计划也发布了 `deepseek-fetch-api`。期望：`web_fetch` 通过 Worker 已有的 host-routed `fetch` 取回纯文本，返回 200 与原始正文。
- **Coordinator / contract owner**：本 worktree（P05 的 independent-search spec 与 Worker profile）。**Implementer**：同一 commit 的 `plugins/web-fetch-host`、Worker profile、App 的 `PhoneWebSearchSettings`/`WebSearchHostConfiguration`。
- **Owning spec / fixtures / schema**：`spec/v1/gateway-independent-search.md` §3；无独立 schema/golden 字段（该表只声明环境变量值）。测试：`plugins/tests/web-fetch-host.test.ts`、`plugins/scripts/profile.test.mjs`、`Tests/PhoneDSHTests/PhoneWebSearchSettingsTests.swift`、`examples/probe-app/PhoneDSHSimTests/WebSearchHostConfigurationSimTests.swift`。
- **受影响的 producer / consumer**：
  - **Host**：`PhoneWebSearchSettings.fetchProviderID` / `WebSearchHostConfiguration` 发布新值；独立模式的 base/key 仍用于 search。
  - **Worker**：`web` row 选 `phone-host-fetch`；新 `web-fetch-host` row 注册 `ctx.web` provider；`tool-web` 的 `fetch` 条件允许 host provider 或 legacy pair。
  - **DSH `web-deepseek-api`**：仍注册 `deepseek-search-api` 与 `deepseek-fetch-api`；独立 `/fetch` 操作与凭据路由保留，但在 phone host 上不被选中。`gateway-official-web.md` 的 `/fetch` reuse grant 也保留（follow-model 的 credential plan 仍证明它可用），只是不再被 `web_fetch` 选中。
  - **未被要求**：官方 `/fetch` API 的 `text/plain` 行为（仍记在 `docs/upstream/2026-11-13-web-fetch-raw-text.md`）；Android 的 fetch provider；`web-fetch-http`（仍禁用，undici 无 host route）。

## 2. 契约 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| `PDSH_WEB_FETCH_PROVIDER`（独立模式） | `deepseek-fetch-api` → `phone-host-fetch`。依据 §3 表。 |
| `PDSH_WEB_FETCH_PROVIDER`（follow-model 计划） | `deepseek-fetch-api` → `phone-host-fetch`；官方 `/fetch` grant 仍保留但 `web_fetch` 不再选它。 |
| Worker fetch provider | 远端 Fetch API → Worker-local `phone-host-fetch`，使用 `llm-bridge` 安装的 global `fetch`（host `/v1/http` + egress allow-list）。 |
| `web_fetch` 的 body 分类 | 远端 API 返回 `content`（要求可抽取 Markdown）→ host provider 按 DSH local-provider 规则分类：`text/html`/XHTML=`html`，其它 `text/*`/JSON/XML=`text`；`text/plain` 原文返回。 |
| `tool-web.fetch` | 仅 `search==deepseek-search-api && fetch==deepseek-fetch-api` → `fetch==phone-host-fetch` **或** 该 legacy pair。 |
| 非 2xx 语义 | 远端 provider 抛 `DeepSeek API error (HTTP N)` → host provider 返回 `statusCode` 结果；`tool-web` 渲染 `Fetched <url> (HTTP N)`，只有网络/类型/URL 失败才抛 `WebError`。 |
| 独立 `/fetch` 操作 | 仍是已定义的 provider 行为 → **保留**（`web-deepseek-api` 仍注册），但 phone host 不选它；spec §3 明写。 |
| P05 envelope / gateway 路由 | **不变**。`/v1/http` 的请求/响应 envelope、凭据路由、egress 规则均未改。 |

**自檢。** 没有新增第二种凭据路径：host provider 不带任何独立 key，只使用 `/v1/http` 的既有 host 授权。没有放宽 egress：目标仍受 host allow-list 限制。没有新增 wire 字段；provider id 是 Worker profile 的本地选择。没有删除独立 `/fetch` 的契约，只改默认选择。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| new host → new Worker | 发布 `phone-host-fetch`；`web-fetch-host` 注册并选中；`web_fetch` 返回纯文本。profile test + provider tests。 |
| old host → new Worker | 旧 host 仍发布 `deepseek-fetch-api`；profile 的 legacy 分支仍注册 `web_fetch`，行为与 2026-11-13 之前相同（远端 API 的 404 仍在）。 |
| new host → old Worker | 旧 Worker 的 `tool-web` 条件不认识 `phone-host-fetch`，`web_fetch` 不注册。Host 与 Worker 由同一 App 构建发布，不存在跨版本组合；旧 Worker 不会误用。 |
| persisted old data → new／rollback | 不適用：没有持久化格式；settings 文档只存模式/base/key，fetch provider 是派生值。回滚到旧 host 即回到 legacy。 |

- **版本決定**：不升版本；这是 Worker profile 的本地 provider 选择和 App 的派生环境值。
- **部署順序**：App/Worker 同包发布。若只换 Worker bundle 而旧 App 仍发 `deepseek-fetch-api`，legacy 分支保持旧行为；若只换 App 而旧 bundle 不认识新值，`web_fetch` 会关闭而不是静默走错 provider。
- **`target` 與仍保留的差異**：官方 `/fetch` 接受 `text/plain` 仍是 upstream proposal；phone 通过 host provider 绕开，其他客户端不受影响。

## 4. 分工與證據

- **本單獨占路徑**：`plugins/web-fetch-host/**`、`plugins/profile/phone.worker.cordis.patch.yml`、`plugins/package.json`、`plugins/package-lock.json`、`plugins/tsconfig.json`、`plugins/tests/web-fetch-host.test.ts`、`plugins/scripts/profile.test.mjs`、`Sources/PhoneDSH/PhoneWebSearchSettings.swift`、`examples/probe-app/ProbeKit/WebSearchHostConfiguration.swift`、对应 Swift tests、`spec/v1/gateway-independent-search.md` §3、`docs/architecture.md`、本单。
- **共享 fixtures**：无新增 spec golden；provider 单测用 `Response` 伪造 `text/plain`、`text/html`、`application/octet-stream`、404、超限和非法 URL。
- **各端真實 proof**：
  - `cd plugins && node --test tests/web-fetch-host.test.ts` → **PASS**（7 tests）。
  - `PDSH_DSH_CHECKOUT=… node --test scripts/profile.test.mjs` → **PASS**（11 tests，含 fetch-only 和独立模式）。
  - `npm run typecheck` → **PASS**。
  - `swift test --filter PhoneWebSearchSettingsTests` / `xcodebuild test -only-testing:PhoneDSHSimTests/WebSearchHostConfigurationSimTests` → 待跑。
  - 真机 `web_fetch <raw.githubusercontent.com URL>` → **NOT_VERIFIED**（本机模拟器）。
- **剩餘風險**：host `/v1/http` 的 egress allow-list 必须包含目标 host；`raw.githubusercontent.com` 已在 `curl` 路径上被允许。HTML→Markdown 渲染仍由 `tool-web` 完成，provider 不复制它。非 UTF-8 声明按 `TextDecoder` 处理，不保证所有编码。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | 本 worktree | 2026-11-13 R1：`web_fetch` 对 raw `text/plain` 404；把 fetch 选择切到 host-routed provider，保留独立 `/fetch` 契约与 legacy 值。 | Host/Worker；P05 owner；upstream 仍保留 `/fetch` text/plain 提案 |
