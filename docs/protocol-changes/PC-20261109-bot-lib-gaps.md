# 库层缺口：按调用方 `tools/list` 与按 Bot 取消审批（P26）

```yaml
change: PC-20261109-bot-lib-gaps
contracts: [P26]
status: implemented
breaking: false
version_decision: Additive Swift library APIs, one optional request header on the existing App MCP `/mcp` route, and per-Bot prompt tool-surface filtering through the scoped tool registry in the Worker. No P25 envelope field, no MCP JSON field or method, no schema enum widening, no new version field, and no persisted-data migration.
base: dc823973e5bfa9dcb9bab1e0b6c00d35982812e7
contract_revision: docs/protocol-changes/PC-20261109-bot-lib-gaps.md@bot-lib-gaps-v1
```

Protocol impact: P26 — per-caller `tools/list` and per-Bot approval cancel; P25: none — envelope unchanged; P14: none — no `/api/remote.mux` change; P09: none — no app/UI change.

## 1. 識別與角色

- **Trigger → 現況 → 期望.** `PC-20261109-bot-multi-app` §4/§9 留下兩個庫層缺口：
  1. `BotMCPHandler.rpc("tools/list")` 固定編碼 `BotToolCatalog.allDefinitions`。`SendToAgent`/`CreateTeammate` 的名冊行只存在於 App 的 `BotToolCatalog.allDefinitions(roster:callerBotID:)`，但沒有任何 wire 入口；非主 Bot 也看到 `CreateTeammate`，`SendToAgent` 描述也沒有排除呼叫者與隱藏 Bot。
  2. 刪除 Bot 的級聯沒有 per-Bot 取消審批 API，App 只能掃 durable `approval.requested` 事件逐條 `resolve(.deny)`。
  本變更補上兩者，讓 App 只要照既有 `runtime.registerTeamTools(BotTeamTools(host:))` 接線，不需要新增 catalog provider 或刪除掃描。
- **Coordinator / contract owner / implementer / reviewer-integrator:** `bm-lib` 單元（本工作樹）。Owning contract 仍是 P26 `spec/bot/v1/**`；本單元不修改 `spec/**`、`examples/probe-app/**` 或 `plugins/profile/**`。
- **Affected ends:** Swift `Sources/PhoneDSHBot/{MCP,Team}`；Worker `plugins/bot-runtime/src/{identity-bridge,caller-catalog}.ts`。Android/Rust/firmware 沒有 Bot 頁或 Bot MCP consumer，不變。
- **Base / head:** `dc823973e5bfa9dcb9bab1e0b6c00d35982812e7` / 本單元工作區（未提交，按沙箱要求）。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| `tools/list` 呼叫方身份 | `tools/call` 只憑 App 已登記的呼叫者身份歸屬：Worker 在 `tools/pre-execute` 先 POST `/identity/register`（`runtimeId`、`sessionId`、`callId`、`name`、`arguments`、`argsDigest`），App 以 `gateway.tokens.lookupSession(sessionId)` 取得 `principal.botId`，再由 `BotGateway.resolveToolCall` 以 tool name + arguments digest claim。`tools/list` 沒有 tool call identity，因此新增**可選 HTTP header** `x-pdsh-bot-session`；App 用同一個 `gateway.tokens.lookupSession` 解析同一個 App-minted session principal。沒有 header、空值、未知 session 或非 Bot session 時回退到既有靜態目錄。 |
| `BotToolCatalog.allDefinitions(roster:callerBotID:)` | 有呼叫者且 `roster.mainBotID != callerBotID` 時不再包含 `CreateTeammate`；`SendToAgent`/`CreateTeammate` 的 `Available bots:` 行仍使用 `roster.visibleBots` 排除呼叫者與 `hiddenByUser`。`callerBotID == nil` 保留原本兩個 team tool 的靜態可發現性；執行路徑的主 Bot 檢查不變。 |
| App 接線 | `BotMCPRuntime.registerTeamTools(_:)` 在 handler 同時 conform `BotTeamToolCatalogProviding`（`BotTeamTools` 已 conform）且沒有顯式 provider 時，自動把該 handler 的 roster-aware 目錄安裝成 `tools/list` provider。App 不需要改代碼；`setToolCatalogProvider` 只保留給需要覆寫的宿主/測試。 |
| `BotMCPRuntime.toolDefinitions(callerBotID:)` | 新公開方法；有呼叫者時使用 provider，沒有 provider/呼叫者或 provider 回 `nil` 時回傳靜態 `BotToolCatalog.allDefinitions`。 |
| `BotMCPRuntime.callerBotID(forSession:)` | 新公開方法；只做 `gateway.tokens.lookupSession(sessionID)?.botId`，不接受模型參數或 tool argument 推導。 |
| Worker 逐會話目錄 | DSH 的 `@deepseek-ai/dsh-mcp-client` 對每個 Worker 只建立一個 MCP 連線：初始 sync 與 `notifications/tools/list_changed` 都用 `listTools(undefined, {cacheMode: 'refresh'})`，目錄是**全域**的，不是每 agent/每 session。DSH 0.2.2 又在 `system-prompt/assemble` waterfall **之前**收集 tool schemas、waterfall 之後才接回，所以 waterfall 改不到當回合的 `tools`。Worker 因此在 `agent/created`（serial、第一次 prompt 之前）與 status／assemble／team tool result 事件以 header 拉取同一 session 的 App `tools/list`，並套用 **scoped tool registry**：`SendToAgent` 以 description getter 的 scoped shadow 更新名冊；`CreateTeammate` 先 scoped shadow（description getter），非主 Bot 用 `restrict({deny})` 隱藏 global，並以 `when` gate 讓 clone 不進入 step admission，主 Bot 則解除 restriction。目錄有 `Available bots:` 行（代表 App 已識別呼叫者）才生效；拉取失敗、無 marker、非 Bot-owned session 或 workbench session 都保留原 surface。 |
| `BotApprovalCoordinator.cancelAll(botID:reason:)` | 新公開 API：只取消 `principal.botId == botID` 的 pending approval；每張卡寫一條 `approval.decided`（`status:"cancelled"`、`reason`、`decision:"deny"`）與一條 `ui.notice`（`kind:"approval_cancelled"`、`reason`、`text`），等待者收到 `ok:false, allowed:false, message:"approval unavailable"`。全域 `cancelAll(reason:)` 保留原語義與預設 reason。 |

Self-check（`spec/README.md` §5.1）：沒有第二個 envelope、MCP JSON 欄位、錯誤碼或審批狀態；header 是既有 `/mcp` 路由上的可選傳輸提示，舊 client 不送就維持靜態目錄。非主 Bot 的 `CreateTeammate` clone 以 `when` 排除於 step admission，global 以 scoped restriction 隱藏；執行仍由 `BotTeamTools.createTeammate` 的 `permission_denied` 把關。審批事件沿用既有 type/`ui.notice` kind，沒有新增持久化 kind。

## 3. DSH `tools/list` 快取結論

- **粒度：全域。** `dsh-mcp-client` 的 `syncTools` 在連線建立時呼叫 `client.listTools(undefined, { cacheMode: 'refresh' })`，之後只由 server 的 `notifications/tools/list_changed` 觸發重新 sync；`createMcpToolDefinition` 把 `tools/call` 綁到同一 client，但沒有 per-agent 或 per-session 的 list。phone Worker 只有一個 `mcp-phone` instance，所以所有 Bot 與 workbench session 共享同一份 MCP tool list。
- **後果：** 只改 server 的 `tools/list` 回應（即使有 header）不會讓不同 Bot 看到不同目錄，因為 DSH 的單次 list 沒有 Bot session identity。本變更因此讓 Worker 自己拉 per-caller 目錄，並在該 Bot 的 scoped tool registry 套用；App server 的 per-caller `tools/list` 是同一份權威（同一個 `BotToolCatalog`/roster），不是另一套目錄。
- **未採用的處理：** 每 Bot 獨立 MCP 連線需要 per-Bot URL/Worker 或 profile 改動，超出本單元允許路徑；以 `notifications/tools/list_changed` 全域翻轉目錄會在並行 Bot 回合間競態。兩者都留給需要真正 per-session MCP transport 的後續工作。

## 4. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old Worker → new App | 不送 `x-pdsh-bot-session`；`tools/list` 回傳既有靜態目錄，所有 Bot 行為與變更前相同。舊 Worker 的 identity/approval 流程不變。 |
| new Worker → old App | header 被忽略，App 回靜態目錄；Worker 目錄沒有 `Available bots:` marker，`planCallerCatalog` 回 `undefined`，Worker 不改動 tool surface。角色檢查仍在執行路徑。 |
| new → new | 主 Bot 看到兩個 team tools 與排除自己/隱藏 Bot 的名冊；非主 Bot 的 prompt tool surface 不含 `CreateTeammate`，`SendToAgent` 描述排除自己/隱藏 Bot。App 用同一個 session principal。 |
| persisted old data → new／rollback | approval/team 事件格式不變；`cancelAll(botID:)` 只影響記憶體 pending 卡，寫入既有 `approval.decided`/`ui.notice` 形狀。rollback 後舊 App 仍可掃 durable 事件逐條 deny；沒有 schema 或版本提升。 |

- 版本／adapter 決定：P26 additive library/Worker consumer change；不升 major，不新增 MCP JSON 欄位或版本協商。App 不需要改代碼。
- 已知限制：Worker 目錄快取 2 秒；名冊在快取視窗內變更時，下一個 assembly 會更新。App UI 變更名冊後，Bot 下一回合的 tool surface 才反映（與一般 prompt 重新組裝一致）。
- Golden：不需要修改 `spec/bot/v1/golden/tool-catalog.phone.json`。該 golden 的主 Bot `team.tools`（兩個工具）與名冊行不變；非主 Bot 的 `CreateTeammate` 移除由 Swift 測試直接斷言。若 `bm-spec` 要擴充 phone delta，建議新增 `team.teammateCallerTools`（僅 `SendToAgent`）與 `rosterLine.teammateCaller` 已存在；不需要改 schema。

## 5. 分工與證據

- Swift implementer：`Sources/PhoneDSHBot/MCP/{BotMCPHandler,BotMCPRuntime,BotMCPTypes,BotToolCatalog,BotApprovalCoordinator}.swift`、`Sources/PhoneDSHBot/Team/BotTeamTools.swift`、`Tests/PhoneDSHBotTests/MCP/{BotToolCatalogCallerTests,BotApprovalCancelTests}.swift`。
- Worker implementer：`plugins/bot-runtime/src/{identity-bridge,caller-catalog}.ts`、`plugins/tests/bot-caller-catalog.test.ts`。
- App consumer：無需改代碼；既有 `runtime.registerTeamTools(BotTeamTools(host: composition))` 會自動安裝 catalog provider。刪除級聯在整合時把「掃 durable 事件逐條 deny」換成 `await runtime.approvals.cancelAll(botID: botID, reason: "bot_deleted")`。
- Shared fixtures：不新增 spec golden；Swift handler 測試驅動真實 `BotMCPHandler`/`BotTeamTools`/`FakeBotTeamHost`，Worker 測試驅動真實 `SystemPrompt`/`ToolRuntime` scoped registry 與 `planCallerCatalog`。
- Exact commands → result / Not verified：見 §6。

## 6. 驗證記錄

實作於 base `dc823973e5bfa9dcb9bab1e0b6c00d35982812e7` 的工作樹，未提交。

| 檢查 | 命令 | 結果 |
| --- | --- | --- |
| Swift build | `swift build --target PhoneDSHBot --disable-sandbox` | PASS（Build complete）。 |
| Swift focused | `swift test --disable-sandbox --filter 'BotToolCatalogCallerTests|BotApprovalCancelTests'` | PASS，8 tests，0 failures（6 catalog + 2 approval，含 HTTP header 路徑）。 |
| Swift full Bot tests | `swift test --disable-sandbox --filter PhoneDSHBotTests` | PASS，384 tests，0 failures。 |
| Plugin typecheck | `cd plugins && npm run typecheck` | PASS（`tsc -p tsconfig.json`，無輸出）。 |
| Plugin focused | `cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"` | PASS，56 tests（55 pass、1 skipped、0 fail）；含 `bot-caller-catalog` 4 tests。 |
| Spec/CI | `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | PASS（phone-spec 12s、phone-cross-tree 13s；8/8 invariants、87 mutation tests）。 |

- **Not verified:** iOS device/simulator runtime, real Worker E2E with a live model, actual App deletion cascade invocation (integration), and a running WKWebView Worker. The cache conclusion was checked against the installed pinned `@deepseek-ai/dsh-mcp-client@0.2.2-rc.1` / `@deepseek-ai/dsh-system-prompt@0.2.2-rc.1` packages from `plugins/package-lock.json`; no on-device Worker run was performed. Not upgrading unit tests to device claims.
- **Remaining risks:**
  1. DSH's global MCP list remains the source for tools that are not in the App's caller catalog; this change only filters the two team tools. A future per-session MCP transport would make the server-side list authoritative end-to-end.
  2. The Worker catalog cache (2 s) can make a roster change visible one model step later; no correctness impact because execution still checks the main-Bot pointer.
  3. `available bots` is parsed from the library-owned description marker; if the P26 description contract changes, `planCallerCatalog` must change with it (Swift tests assert the marker-bearing descriptions).
