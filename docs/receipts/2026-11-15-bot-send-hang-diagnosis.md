# 2026-11-15 — Bot send 在 rebind 後永久等待：診斷回執

<!-- SPDX-License-Identifier: MIT -->

Base: `484c1f994`（bad build，PR #177 整合）
Good build: `7a11fd5b7`（PR #170）
Device: 真機安裝 bad build 的同一台裝置；機型/iOS 版本以當次 run log 為準（本回執不重新宣稱）。
Scope: 只讀診斷與契約凍結；本 lane 沒有改 runtime/spec/golden，也沒有重跑真機。

## 1. 時間線

| 時間（+0800） | 事件 |
| --- | --- |
| 2026-11-14 17:43 | good build `7a11fd5b7`（PR #170）。Bot 正常 send/reply。 |
| 2026-11-14 19:27 | PR #175（`fc3460aba`，streaming performance / row-service 改動）進 main。 |
| 2026-11-14 19:53 | PR #173（`80cbf7983`）進 main，帶入 transport adoption / rebind scope / live watch：`6d57913cd`、`bb685ff21`、`2703c5d49`。 |
| 2026-11-14 21:56 | PR #174（`e67183067`）進 main。 |
| 2026-11-14 22:06 | bad build `484c1f994`（PR #177，`restore/pr174-authored`）。 |
| 當晚 | 安裝 bad build。Bot 在 rebind 後送出的 chat 永久等待；kill app 後訊息消失。 |
| 當晚 | 取證：`domain.sqlite`/WAL 沒有這次發送的 durable event/nonce；宿主 journal `mseq` 不變、沒有 `user/message`；gateway 沒有模型請求。同一段時間，stale card answer「先到这」走 cardAnswer，durable-first，回合同樣執行。 |
| 2026-11-15 | 收斂成三個 gap，凍結 `PC-20261115-bot-send-durability`，交由 transport/outbox/P09 lanes 實作。 |

## 2. File/line evidence（base `484c1f994`）

| 檔案:行 | 事實 |
| --- | --- |
| `Sources/PhoneDSHBot/Rows/BotUserAction.swift:198-222` | `dispatch` 先跑 `planner.plan`，只有 `.commit(plan)` 之後才 `performAndRecord`；planner 的遠端回合是 await 在 persistence 之前。 |
| `Sources/PhoneDSHBot/Rows/BotRemoteActionPlanner.swift:70-72,154-176` | chat 直接 `await remote.sendUserMessage(...)`，回合完成後才組 `conversation.turn_started`。回合 hang/kill → 沒有 durable event/nonce。 |
| `Sources/PhoneDSHBot/Rows/BotRemoteActionPlanner.swift:106-117` | cardAnswer 在送 prompt 之前先 `store.performAndRecord(card.answered)`；這是 durable-first 的既有路徑，也是「先到这」仍執行的那條。 |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:2534-2550` | `runTurn` 只按 sessionId 取 `queuedTurns[sessionId]?.work ?? coordinators[sessionId]?.work`，`await predecessor.value`；沒有任何 generation 檢查。 |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:312-343` | `attachTransport` adopt 時保留所有 `coordinators/queuedTurns`；只有 coordinator 有 2 s bounded settle。 |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:396-412` | 2 s 後只 cancel/drop 被標 interrupted 的 coordinator；queued Task 仍 suspend 在舊 predecessor 的 `Task.value`，`cancel()` 打不斷 `mux.receive()`/transport await。 |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:2578-2604` | `openMux` → snapshot → `sendPrompt` → `collectTurn` 全程無 deadline。 |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:2649-2665,2667+` | snapshot/collect 是 `while true` + `mux.receive()`；沒有 idle/total bound，只有 frame 內容判斷。 |
| `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift:197,278-280,316` | `transportIsAttached` 只由 adopt/detach 設定；dead transport 仍回 `true`。 |
| `Sources/PhoneDSHBot/MCP/BotRebindScope.swift:38-49,77-83`；`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeUnit.swift:308-312` | composition 以 `hasLiveTransport()` + `isStarted` 決定 keep/restart；`transportIsAttached` 為 true 就 keep 一個可能已死的 unit。 |
| `examples/probe-app/PhoneDSHProbe/Bot/BotChatModel.swift:611-657` | send 只建立記憶體 `local-<nonce>` row，然後呼叫 driver；沒有 durable nonce/outbox。 |
| `examples/probe-app/PhoneDSHProbe/Bot/BotChatModel.swift:856-867` | 120 s 的 `markAwaitingTurn` 只是隱藏狀態行，不持久化、不重播、不清除已丟失的訊息。 |
| `Sources/PhoneDSHBot/Store/SQLiteDomainStore.swift:101-108` | base 只認 `user_version <= 3`，current 3；沒有 pending-action table。 |

## 3. Good build vs bad build

- `git merge-base 7a11fd5b7 484c1f994` = `7a11fd5b7`；good 是 bad 的祖先，regression 在 2026-11-14 17:43–22:06 之間。
- bad build 多出的四個 PR：`fc3460aba`（#175）、`80cbf7983`（#173）、`e67183067`（#174）、`484c1f994`（#177）。其中 #173 是 transport adoption/lifecycle；`6d57913cd` 是「keep live units attached across a rebind」，`bb685ff21` 是 realtime watch/live loop，`2703c5d49` 是 card staleness/pending。
- 受影響檔案（`git diff --stat 7a11fd5b7..484c1f994 -- Sources/PhoneDSHBot examples/probe-app/PhoneDSHProbe/Bot`）：19 files，+2513/−321；`BotDSHRemoteRuntime.swift` +215、`BotRuntimeComposition.swift` +257、`BotChatModel.swift` +640、`BotSessionLogProjection.swift` +218、`BotRemoteActionPlanner.swift` +122、`BotRebindScope.swift` 新增 109。
- 關鍵行為差：pre-#173 的 `attachTransport` 對任何 replacement 都 `cancelTurn(includeQueued: true)`（見 `6d57913cd` 的 removal diff），所以 rebind 是「取消」而不是「等待」；#173 改成 adopt + keep queued，保留 running turn/排隊意圖，但沒有 generation fence、沒有 outbox、`hasLiveTransport` 也不是 liveness。這三個缺口在 bad build 同時成立，於是 new send 可以 await 一個永遠不 settle 的舊 queued Task，且 kill 後沒有 durable 意圖可重播。
- 這也是為什麼不能 revert #173/#177：revert 會把「切換 Bot 會取消另一個 Bot 的 running turn」帶回來。正確修法是 bounded await + generation fence + outbox，而不是恢復 cancel-everything。

## 4. Root cause（三個 gap）

1. **Transport operations 沒有 deadline、`transportIsAttached` 不是 liveness。** `openMux`/snapshot/`session/prompt`/claim/collect 可以永久 suspend；dead transport 仍被 composition keep。沒有錯誤能在 bounded 時間內回到 UI。
2. **Queued turns 跨 generation 保留、沒有 fence。** `runTurn` 只按 sessionId join predecessor；`attachTransport` adopt 保留 queued entries，2 s 的 settle 只覆蓋 coordinator。新 send 可以等一個舊世代的 orphan Task 到永久。
3. **Chat 只在回合完成後才持久化。** Chat planner 先送再 plan/commit；hang 或 kill 發生在完成前，就沒有 durable event/nonce，launch 後沒有東西可重播。CardAnswer 反而 durable-first，與觀察到的「先到这」仍執行一致。

## 5. Fix summary（本輪凍結的契約）

- **P25 store v4：`bot_pending_actions`。** 精確 DDL：`(bot_id, nonce, payload, created_at_ms, attempts DEFAULT 1, PK(bot_id,nonce))`；在 planner/transport 之前 commit；terminal 結果清除，retryable rejected（rebind interrupt/timeout/unavailable）與 throw/kill 保留；launch/ready 後同一 nonce/requestId 重播一次，TTL 24 h、最多 3 attempts，耗盡寫一筆 idempotent `ui.notice`；v3 rows 不動，`user_version` 3→4，`>4` 才 `schemaTooNew`。
- **Transport liveness：** openMux 10 s、snapshot 15 s、prompt unary 20 s、control unary 10 s、main-session recovery 30 s、collect idle 300 s、adopt settle 2 s、queue fence 500 ms；mux 級失敗立即 quarantine，unary transport 連續 2 次 quarantine；`hasLiveTransport()` = attached && !quarantined。
- **Queue generation fence：** queued turn 攜帶 generation，只 join 同世代 predecessor；generation 變更後舊世代在 500 ms 內 settle `interrupted`/`transport_generation_changed`，不送 prompt，由 outbox 重播。
- **P09：none（本輪不改 UI）。** outbox 由背景 replay 消費；UI 沿用既有 `local-<nonce>` 回顯與 failure notice。由 outbox 投影的 pending/retry presentation、`BotRuntimePresentation.pendingActions`、`BotUIPendingAction`、`composer.send.*` 與 `ui-state-vectors` 是後續 P09 變更單，不在本輪凍結或 acceptance。
- **保留 adoption：** #173 的 live unit keep/adopt 與 #177 的整合不 revert；修的是 liveness 判定與 queue fence。

## 6. 未驗證／交接

| 項目 | 結果 |
| --- | --- |
| 本 lane 的 code/spec/golden 修改 | **NOT_RUN（by design）**；只新增變更單與本回執。 |
| 本 lane 的 `protocol_impact.py` 宣告檢查 | **PASS**：`python3 scripts/ci/protocol_impact.py --base 484c1f994 --body-file docs/protocol-changes/PC-20261115-bot-send-durability.md` → `0 triggered ID(s), 2 changed path(s)`（docs-only diff；宣告 P25 + P09/P26/P27/P14 none 被接受）。 |
| Swift store/vector/outbox/transport tests | **NOT_RUN**（由 outbox/transport lanes 提供）。 |
| Kotlin `:bot` v3→v4 migration | **NOT_RUN**（`BotDomainStoreV4Test`；`BotStoreVectorTest` 在 golden v4 更新前 expected-red，更新後必須原樣通過；未實跑不宣稱 PASS）。 |
| P09 UI pending/retry | **N/A** — 本輪沒有 P09 UI/presentation/strings/vector 變更；pending presentation 是 follow-up。 |
| 真機 `PDSH_WITH_XZSHELL=1` + `PhoneDSHShell` + `phone info` + send/reply/kill/relaunch | **NOT_RUN**（integration lane 必須按變更單 §4.5 執行並記錄）。 |
| power-loss durability | **NOT_VERIFIED**（既有缺口；`synchronous=FULL` 不是斷電測試）。 |

交接給 code/integration agents 的 truthfulness 條件（任一改變都要先改本變更單再實作）：outbox 的欄位/版本/TTL/attempts、**terminal-only clear 的分類**（`transport_replaced`/`turn_not_completed`/timeout/unknown 必須保留；golden 的 outbox 行若寫成「任何 non-throwing 都刪」是錯的，正在 outbox branch 修正）、deadline 常數（transport lane 的最終值可能 supersede §2.2，需以新 revision 更新）、replay 是否實作 cardAnswer event-value 重送、Android `BotDomainStoreV4Test` 的真實名稱、spec/golden 的實際 commit SHA。P09 UI/pending strings 是 follow-up，不在本輪交接。真機與各端測試結果只能如實填 PASS/FAIL/SKIP/NOT_RUN，不能把 docs freeze 當 implemented/verified。
