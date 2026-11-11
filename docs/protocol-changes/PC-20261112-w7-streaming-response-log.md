<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-w7-streaming-response-log — W7 streaming channel relief

## 0. 摘要

```yaml
change: PC-20261112-w7-streaming-response-log
contracts: [P04, P05, P17]
status: frozen
breaking: false
version_decision: 無 wire／proto 版本變更。response-log 鍵的 recipe 不變，只允許換成 crypto 實作並要求位元級一致；舊鍵因此直接兼容，無 migration。streaming 只改轉發時機與合併上限，SSE/NDJSON 的 bytes 與順序不變；startup probe 只提早斷開 observer、console 加級別/限速，錯誤級別保留。
base: d988108c1ec0c56903d6087c282cc9278bbdfd19
contract_revision: 見交接 head（本單與 spec 同一 commit）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  - **response-log 鍵（P05）。** 現況：`ResponseLog.cacheKey` 每次模型請求把整個 body 解析、按鍵排序重編碼，再用手寫標量 SHA-256（`GatewaySHA256.swift`）算哈希；`ModelGateway` 每次無條件調用，重複整體拷貝。期望：改用 CryptoKit（Linux 用 swift-crypto 或保留現實作作 fallback），**位元級結果一致**；preimage recipe 不變，所以新舊鍵完全相同、無 migration。加新舊實作一致的測試。
  - **流式轉發（P05/P17）。** 現況：`StreamingForward.swift` 逐位元組迭代 AsyncBytes，攢滿 16 KiB 或流結束才下發，`/mcp` SSE 與 `/v1/exec` NDJSON 被延遲。期望：資料到達即轉發；完整 SSE event（終止空行）或 NDJSON line 立即寫出；合併只能在同一 frame 內、最多 100 ms／4 KiB；第一個事件不被 16 KiB 批次延遲。
  - **SSE 路徑（P05）。** 現況：`GatewaySession` 所有上游共用 `maxConcurrentOperationCount=1` 的 delegate 隊列；`ModelGateway` 每個 chunk 在泵裡 await 一次 response-log 寫入、無緩衝；`HTTPTransport` 約 595 行每 chunk 拷貝。期望：response-log 寫入帶緩衝且不阻塞下發；流有界、有明確 backpressure；每 chunk 拷貝次數減少；記錄內容與重放語義不變（只記完整流，partial 不記）。
  - **Worker llm-bridge（P05）。** 現況：`install.ts` 每個 chunk 兩個 `setTimeout` 加 `Promise.race` 再包 ReadableStream。期望：不改變 60 秒靜默恢復語義的前提下，去掉每 chunk 定時器開銷。
  - **啟動探測（P04）。** 現況：`WebEngineScripts.swift` 的 MutationObserver 監聽整個文檔且從不斷開，console 每個 `console.*` 字符串化後發給原生。期望：探測成功後斷開 observer；console 轉發加級別過濾或限速，但 error 級別必須保留。
  - **靜態文件（P05）。** 現況：`LoopbackServer.swift` 在 actor 上用 `Data(contentsOf:)` 整讀檔案，阻塞其他路由。期望：不阻塞 actor 的讀取。
  - **delta 合併上限（P05）。** 現況：無上限。期望：同一 response item 的連續文字 delta 可合併，上限 32 KiB UTF-8 或 100 ms，先到者；不跨 item、不跨 tool_call/finish/error、不重排。
- **Coordinator / contract owner**：`contracts`。**Implementer**：`w7-stream`（`Sources/PhoneDSHGateway`、`Sources/PhoneDSHLoopback`、`Sources/PhoneDSHEngine/WebEngineScripts.swift`、`plugins/llm-bridge`、對應 tests）；不改 response-log 的保留與回收策略（`w3-storage`）、不改 `Sources/PhoneDSH`。
- **Owning spec / fixtures**：[gateway-security.md](../../spec/v1/gateway-security.md) §12（鍵 recipe）、§13（streaming 與 delta 上限）；`golden/plan/response-log-key.json`（3 valid／5 invalid）、`golden/plan/streaming.json`（3 valid／5 invalid），checker `plan_cases_check.py`。
- **受影響 producer / consumer**：P05 Swift gateway/loopback 與 TS `plugins/llm-bridge`；P17 `/v1/exec` NDJSON；P04 WebEngine 探測。Kotlin `android/net` 沒有這個 response-log 鍵與 WebEngine probe，記 `not started`。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| response-log 鍵 preimage | 未成文 → 固定為 `UPPERCASE(method)\n canonical-URL\n` + 選定 header（小寫名升序、`name:trimmed-value\n`）+ `\n` + canonical-body；canonical-URL 去 fragment；canonical-body 為 JSON 排序鍵／無多餘空白／`/` 不轉義／整數，否則原始 bytes。 |
| 鍵算法 | 手寫 scalar SHA-256 → CryptoKit／swift-crypto／硬體／切片都必須輸出**位元級一致**；shared key vectors 是 oracle。 |
| 舊鍵兼容 | 未寫 → recipe 不變，所以新舊鍵相同；若未來改 recipe，先讀 legacy key 再讀新 key，legacy entry 在刪除條件成立前不得刪，不能安全 re-key 的留給 LRU。碰撞／hash 失敗 fail-closed。 |
| 流式轉發 | 攢 16 KiB → 到達即發；完整 SSE event 或 NDJSON line 立即寫出；不在流結束才 flush。 |
| 合併窗口 | 無 → 同一 frame 內或最多 100 ms／4 KiB；不跨 event boundary；完整 frame 不額外延遲。 |
| delta 合併 | 無上限 → 同 item 連續文字 delta，最多 32 KiB UTF-8 或 100 ms；不跨 item、不跨 tool_call/finish/error、不重排。不 merge 也合規。 |
| response-log 寫入 | 每 chunk await → 可緩衝、非阻塞下發；只記完整流，partial 永不記；記錄 bytes 與 replay 語義不變。 |
| backpressure | 未寫 → 下游隊列有界；滿時 reader 等待、不丟；upstream 連線施加 backpressure；丟 frame 不得靜默。 |
| Worker 60 s 恢復 | 每 chunk setTimeout/race → 去掉每 chunk 定時器，保留 60 秒靜默恢復語義。 |
| 啟動探測 | observer 永不斷、console 全量 → 成功後斷開；console 級別過濾或限速，error 保留。 |
| 靜態檔 | actor 上 `Data(contentsOf:)` → 不阻塞 actor。 |
| 用戶可見 | 無新增；首 token 與 MCP 首事件只會更早，不新增提示。 |

自檢（baseline §5.1）：鍵 recipe 沒有第二種表達；沒有改 response log 的保留／回收（W3 另有條件）；streaming 不改 payload bytes 或順序；沒有新增 frame、header 或錯誤碼；沒有放寬 partial stream 的「不記錄」規則。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；測試 |
| --- | --- |
| old → new | 舊鍵與新鍵 byte-identical，舊 response entry 可直接命中；舊 SSE/NDJSON bytes 不變，新 forwarding 只改時機。舊 Worker 每 chunk timer 仍可運作，新宿主不依賴它。 |
| new → old | 新端沒有新增 wire bytes 或 header；舊客戶端收到相同的 SSE event/NDJSON line，只是更早。舊 response log 讀同一 key。 |
| new → new | 兩端用同一 key vectors；streaming 的 first-event 不被批次延遲；delta merge 不超 32 KiB／100 ms；response log 只記完整流。 |
| persisted old data → new／rollback | 無 migration：鍵 recipe 不變，舊 entry 照讀。若 response body 已由 W3 移到 Caches，舊版 replay missing（cache 非權威），不影響回滾。rollback 不需要 re-key。 |

- **版本決定**：無 proto／wire 版本變更。Key 是 host 私有 cache key，recipe 已凍結；streaming 是傳輸時機；delta merge 是 client 合併上限；W3 的 response-log 位置另有變更單。
- **部署順序**：`w7-stream` 可在 W3 之前插空做；App 與 Worker 可獨立更新。response-log 的保留／回收策略由 `w3-storage` 改，本單不動。
- **仍保留的差異**：Kotlin/Android 沒有這個 gateway response-log 與 SSE 路徑；本輪 `not started`。arm64 硬體 SHA 與 CryptoKit 的實測只在呼叫方真機；Linux 只能驗演算法一致。

## 4. 分工與證據

- **獨占路徑（contracts）**：`spec/v1/gateway-security.md` §12/§13、`spec/v1/README.md` §5.2、`golden/plan/response-log-key.json`、`golden/plan/streaming.json`、checker、本單。
- **w7-stream 路徑**：`Sources/PhoneDSHGateway/**`、`Sources/PhoneDSHLoopback/**`（`StreamingForward`、`LoopbackServer`、`HTTPTransport`）、`Sources/PhoneDSHEngine/WebEngineScripts.swift`、`plugins/llm-bridge/**`、`Tests/PhoneDSH{Gateway,Loopback,Engine}Tests`。不得改 `Sources/PhoneDSH`。
- **共享 fixtures**：response-log-key 3 個 preimage（JSON 排序、空 body 去 fragment、非 JSON）、5 個 mutation（method 大小寫、volatile header、header 順序、缺 header terminator、缺 blank separator）；streaming 3 正向、5 負向（16 KiB batch、長窗口、delta 超限、首事件延遲、跨 event boundary）。
- **Exact commands → result**（Linux 容器）：
  - `python3 spec/v1/tools/plan_cases_check.py` → PASS（response-log-key 3 valid/5 invalid、streaming 3 valid/5 invalid）。
  - `python3 -m unittest spec.v1.tools.test_plan_cases_check` → PASS（含 key mismatch 與 16 KiB mutation）。
  - `python3 spec/v1/tools/spec_golden.py --full` → PASS（102 files，0 error）。
  - `cd plugins && node scripts/run-tests.mjs "tests/*llm-bridge*"` → NOT_RUN（依賴未安裝）。
  - `swift test --filter 'PhoneDSHGatewayTests|PhoneDSHLoopbackTests'` → NOT_RUN（Linux 無 Apple Swift 工具鏈）。
- **未執行**：首 token 實測、流式 CPU、真機硬體 SHA、MCP 長調用首事件、XCTest/Xcode——一律 NOT_RUN，由 `w7-stream` 與呼叫方執行。
- **風險／GAP**：`GatewaySession` 的共用 delegate 隊列與 response-log 寫入仍是同一 actor 的競爭點；只改 forwarding 不會自動消除所有延遲。CryptoKit 與 scalar 實作的位元級一致必須有跨實作測試，不能只靠 known-answer。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts | 初次凍結鍵 recipe、streaming 到達即發、delta 上限與探測規則 | all（contract freeze 公告） |
