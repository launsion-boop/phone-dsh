<!-- SPDX-License-Identifier: MIT -->
# DEC-20261112-gap42 — model-purpose 執行點：三條路線與一條補充路線

Protocol impact: none — documentation only

Status: **proposal（供 P05／P12／P26 owner 簽核）**
對應 GAP: [GAP-42](../../spec/README.md)（P05、P12、P26，open）
權威變更單: [PC-20261112-model-purpose-gap.md](../protocol-changes/PC-20261112-model-purpose-gap.md)
前置閱讀: [決策備忘](perf-stability-open-gaps-20261112.md) §2 的 D2

---

## 1. 一句結論

**先加載體、再談接線；否則一接線就等於拒絕全部模型請求。** 本備忘另外指出一條題目沒列、
但成本最低且不反轉依賴方向的路線：把 `BotModelPurpose*` 這組純型別**下沉到 `PhoneDSHAgentCore`**
（`PhoneDSHGateway` 與 `PhoneDSHBot` 都已經依賴它），再在 P05 加一個 additive 的 purpose 標頭。
三條原本的路線中，**「只對 Bot 發起的請求做宿主側攔截」在今天的 wire 上不可實作**，理由見 §4。

---

## 2. 現況與證據

| # | 證據 | 說明 |
|---|---|---|
| E1 | `Sources/PhoneDSHBot/Ledger/BotModelPurposePolicy.swift:5-20` | `BotModelPurpose` 枚舉與 `largeModelAllowed` |
| E2 | `Sources/PhoneDSHBot/Ledger/BotModelPurposePolicy.swift:46-118` | `BotModelPurposePolicy.frozen`（`smallModel = "deepseek-flash"`、`largeModel = "deepseek-v4-pro"`）、`assertModelAllowed`、`modelTier` |
| E3 | `Sources/PhoneDSHBot/Ledger/BotModelPurposePolicy.swift:139-166` | `BotModelRequest`（含 `purpose`／`purposeName`／`model`／`provider`） |
| E4 | `Sources/PhoneDSHBot/Ledger/BotModelPurposePolicy.swift:169-212` | `BotModelPurposeGate.authorize`；`:178-186` **缺 purpose 直接 throw**（fail-closed） |
| E5 | `spec/README.md:235` | 三個前提：(i) 模組依賴、(ii) wire 無 purpose 載體、(iii) pinned adapter 不保留 purpose；並明列本輪「不授權清單」 |
| E6 | `Package.swift:53` | `PhoneDSHGateway` 依賴 `PhoneDSHAgentCore`＋`PhoneDSHStandardError` |
| E7 | `Package.swift:74-75` | `PhoneDSHBot` 依賴 `PhoneDSHAgentCore`；**測試** target 依賴 `PhoneDSHGateway` |
| E8 | `Sources/PhoneDSHGateway/ModelGateway.swift:182-207` | `GatewayRequest` 只有 `method`／`url`／`headers`／`body` |
| E9 | `Sources/PhoneDSHLoopback/Loopback.swift:119-131` | `HTTPEgressRequest` 同樣只有那四個欄位 |
| E10 | `Sources/PhoneDSHGateway/ModelGateway.swift:1420` | 所有 `x-pdsh-*` 在送上游前被剝除（唯一例外 `x-pdsh-idempotency-key` 到 loopback，`:1446-1450`） |
| E11 | `spec/v1/gateway-security.md:68-85` | header-strip 的權威條款與向量 `gw-hop-001`／`:004`；Kotlin 對端 `GatewayRequestHeaders.isDropped`（`android/net/src/main/kotlin/com/phonedsh/gateway/GatewayHeaderPolicy.kt:41`） |
| E12 | `plugins/llm-bridge/src/install.ts:355-400` | Worker 的 `fetch` 被包裹，`extraHeaders(url, …)` 可在送 `/v1/http` 前加標頭 —— **現成的載體接縫** |
| E13 | `plugins/worker-entry/src/model-route.ts:47`、`:56` | `PDSH_MODEL_ROUTE`、`DEEPSEEK_BASE_URL` 都是**每 boot 一次**的環境值（不是 per-request） |
| E14 | `spec/bot/v1/golden/model-purpose-enforcement.phone.json` | 正反例只有 allowed／denied／default／unknown；**沒有任何「purpose 缺席」的向量** |
| E15 | `spec/bot/v1/golden/model-purpose-enforcement.phone.json` 的 `delta` | 本向量是 phone-only overlay（`upstream: []`），可在不碰 dsh-bot 的前提下擴充 |

**E4 是整件事的關鍵。** `BotModelPurposeGate` 的設計是「缺 purpose 就拒絕」。所以
「先把 Gateway 接上，再慢慢補 purpose 載體」不是漸進式交付，而是**一次全網斷線**：所有模型請求都
沒有 purpose，全部 `EPURPOSE_DENIED`。這也解釋了為什麼 GAP-42 的「不授權清單」第一條就是
「不得 fail-closed」——接線的形狀不能是「讓現有 gate 直接管住所有請求」。

---

## 3. 路線 1：調整模組依賴

**做法**：讓 `PhoneDSHGateway` 依賴 `PhoneDSHBot`（或把 `BotModelPurposeGate` 的呼叫搬進 Bot 再反向注入）。

| 面向 | 內容 |
|---|---|
| 契約修訂 | P12（`spec/README.md:129` 的 P12 觸發面含 `Package.swift`；模組邊界是 P12 的權威）。要新增一條「Gateway → Bot 的依賴方向」或宣告反轉。 |
| 兼容矩陣 | 沒有 wire／schema／持久化變更 → old→new／new→old／new→new 全部「無資料語義變化」；舊資料 N/A。 |
| breaking | **是**（模組圖是 P12 的契約面；且是**依賴反轉**：低層 gateway 依賴高層 agent 模組）。 |
| 成本 | 低（一行 `Package.swift` ＋ import），但把整個 Bot 模組（MCP、memory、wake、routines、watchdog）拉進 gateway 的建置圖。 |
| 風險 | 依賴反轉會被下一個變更再反轉一次；`PhoneDSHBot` 的測試 target 已依賴 `PhoneDSHGateway`（E7），加邊後 BotTests→Gateway→Bot 仍無環，但每次動 Bot 都會重建 gateway 及其消費者。**不建議**。 |
| 能單獨關閉 GAP-42？ | 否。只解掉 (i)。 |

**路線 1b（同類但更小，見 §6）**：不是 Gateway→Bot，而是把型別下沉到兩邊都已依賴的
`PhoneDSHAgentCore`。同樣是 P12 變更，但**不反轉方向**。

---

## 4. 路線 2：在 P05 請求上加 purpose 欄位（新契約修訂）

**做法**：Worker → host 的 `/v1/http` 請求新增 `x-pdsh-model-purpose`（值＝`BotModelPurpose.rawValue`），
由 `llm-bridge` 的既有 fetch 接縫填入（E12）；host 的 `ModelGateway` 在解析憑據／開 socket 前讀它，
交給 enforcer。**標頭不得到上游**：既有的 `x-pdsh-*` strip 規則（E10／E11）已經涵蓋，這是選這個形狀
而不是選 body 欄位的主要原因。

| 面向 | 內容 |
|---|---|
| 契約修訂 | **P05**：`spec/v1/gateway-security.md` 新增一節（或 §3 的 header-strip 條款加一列）說明此標頭是 host-internal、必被剝除、未知值如何處理；`spec/v1/golden/gateway/` 新增一個 `hop-*` 向量斷言「送進來 → 不出現在 `outbound_headers`、且列在 `stripped`」。**P26**：`model-purpose-enforcement.phone.json` 需要新增「purpose 缺席」與「purpose 未知值」兩類向量（現在只有 unknown，E14）。 |
| 兼容矩陣 | **old → new**：舊 Worker 不送標頭 → 新 host 看到「缺席」（見下「缺席條款」）。**new → old**：新 Worker 送標頭 → 舊 host 不認識，但舊 host 的 strip 規則本來就丟棄所有 `x-pdsh-*`，所以**不改變任何行為**（也不會洩漏到上游）。**new → new**：同一 golden 雙端跑。**舊資料**：N/A（不落盤）。 |
| breaking | **否**（additive 標頭＋strip 語義不變；`gateway-security.md:83` 已寫「default is passthrough，只有 denylist 被移除」——新標頭屬 `x-pdsh-*` denylist 覆蓋範圍）。 |
| 成本 | 中：P05 條款＋向量、Kotlin 對端 `GatewayHeaderPolicy` 對齊（E11）、Worker 端注入、enforcer 呼叫點、雙端測試。 |
| 風險 | **誰知道 purpose？** `llm-bridge` 看得到 URL／body，但推斷 purpose 是「按內容猜」，GAP-42 明文禁止「按模型名推斷」；類比地，按 prompt 內容推斷同樣是第二個權威。所以**值必須由呼叫方給**——而呼叫方在 pinned adapter 裡（前提 iii）。這條路線能交付的是「載體＋宿主端語義」，**不能**交付「值一定正確」。 |
| 能單獨關閉 GAP-42？ | 否。解掉 (ii)，並讓 (iii) 變成「唯一缺口」。 |

**缺席條款（必須現在就定，否則等於偷偷 fail-closed）**：`gateway-security.md` 與 golden 都沒有
「請求沒帶 purpose」的語義（E14）。本備忘建議在 P26 的 golden 新增一列，明確選一種：

- **(a) 缺席＝不執行策略**（記一個 `purpose_absent` 診斷，行為與基線相同）；或
- **(b) 缺席＝拒絕**（等於 fail-closed，與 GAP-42 的「不得 fail-closed」衝突，除非 owner 另行授權）。

選 (a) 才能「先接線、後補值」而不斷線；選 (b) 就必須等 pinned adapter 先改。**這是本次最需要
owner 拍板的一句話。**

---

## 5. 路線 3：只對 Bot 發起的請求做宿主側攔截

**做法（題目原意）**：不動 wire，只在宿主判別「這個模型請求是 Bot 發起的」，對它套 policy。

| 面向 | 內容 |
|---|---|
| 契約修訂 | 若只改宿主內部判別：P06／P26（不動 P05）。若要新的 Bot 專用模型路由：**P05 新路由**（較大 delta）。 |
| 可行性 | **今天不可行。** 模型請求從 Worker 走同一個 `/v1/http` 進來（E8／E9），欄位裡沒有任何 session／turn／bot 身分；`DEEPSEEK_BASE_URL` 是每 boot 一次的環境值（E13），**同一個 boot 內無法用端點區分** Bot 與非 Bot。Bot 自己的 loopback listener（`Sources/PhoneDSHBot/MCP/BotMCPHTTPServer.swift`）是**入站工具面**，不是模型請求路徑。 |
| 唯一可實作的形式 | **事後審計**：Bot 的 `BotLLMLedger`（`Sources/PhoneDSHBot/Ledger/BotLLMLedger.swift:5-56`）記錄了 purpose；但 wire 上沒有 request id 可與 gateway 的用量對帳，**無法歸屬**。要做就得先有載體＝回到路線 2。 |
| 兼容矩陣 | 若只做審計：不動 wire，old→new／new→old 皆「無變化」。 |
| breaking | 否。 |
| 成本 | 低（審計）／高（新路由）。 |
| 風險 | **會製造第二個權威**：宿主按 URL／時序猜測誰是 Bot，猜錯就放行或誤拒。GAP-42 已明文禁止「按模型名推斷」，同一邏輯適用。 |
| 能單獨關閉 GAP-42？ | 否。它要嘛退化成路線 2，要嘛只是審計。 |

---

## 6. 建議：路線 1b ＋ 路線 2，absent 選 (a)

**步驟（每一步都可以獨立 review、獨立回滾）：**

1. **P12（路線 1b）**：把 `BotModelPurpose`／`BotModelPurposePolicy`／`BotModelRequest`／
   `BotModelPurposeGate`／`BotModelPurposeError` 從 `Sources/PhoneDSHBot/Ledger/` 移到
   `Sources/PhoneDSHAgentCore/`（純型別、無 Bot 依賴——E2 的實作只用到 `String`／`Double`／`Int`）。
   `PhoneDSHGateway` 與 `PhoneDSHBot` 都已經依賴 AgentCore（E6／E7），因此**不需要新增任何依賴邊**，
   也沒有反轉。`PhoneDSHBot` 以 `@_exported import` 或 typealias 保留對外名稱（P12 要寫清楚是哪一種，
   避免兩個型別名）。**breaking：否**（沒有 wire／資料；Swift 的公開 API 位移是 P12 變更，需在 delta 記明）。
2. **P05（路線 2）**：加 `x-pdsh-model-purpose` 標頭條款＋一個 `hop-*` 向量；Kotlin 對端同步。
   **breaking：否。**
3. **P26**：`model-purpose-enforcement.phone.json` 新增「缺席」與「未知值」向量；缺席選 **(a) 記錄但不執行**。
   `delta` 欄位說明這是 phone-only 的補齊（E15 已支援）。
4. **接線（`ModelGateway` 在解析憑據前呼叫 enforcer）**：只在「有 purpose」時執行；缺席走 (a)。
   此時 `ModelGateway` 的 `NOT_IMPLEMENTED` 可以改成 `partial`，**不是** `implemented`。
5. **（不由本倉決定）pinned adapter 保留／傳遞 purpose**：這是唯一本倉無法獨力完成的前提。在它到位前，
   GAP-42 **保持 open**，但狀態從「什麼都沒有」變成「載體與執行點就緒、缺值」。

**為什麼不建議路線 1（Gateway→Bot）**：只是把依賴反轉，代價是 gateway 的建置圖被整個 Bot 模組綁住，
卻沒有多解任何一個前提。

**為什麼不建議路線 3**：它在今天的 wire 上只能變成「猜」，而 GAP-42 已經禁止猜。

---

## 7. 四格兼容矩陣（建議方案的整體）

| 邊界 | old → new | new → old | new → new | 舊資料 → new／rollback |
|---|---|---|---|---|
| P12 型別位移 | 舊 `PhoneDSHBot` API 名稱保留（alias）→ 呼叫方不改 | 新 AgentCore 型別在舊模組不存在 → 舊版建置不受影響 | 同一型別、同一語義 | 無持久化格式 |
| P05 標頭 | 不送 → 缺席 → 走 (a)，行為同基線 | 送了 → 舊 host 依 `x-pdsh-*` denylist 丟棄 → 行為同基線、不洩漏 | 同一向量雙端跑 | 無 |
| 使用者可見 | **無**新提示；被拒的請求在 (a) 下不會發生；在 (b) 下會大量失敗（故不建議 (b)） |  |  |  |

**版本決定**：P05 不升版（additive 標頭，屬既有 strip 家族）；P12 是模組圖變更，需在變更單寫明
「沒有新增依賴邊」；P26 的 golden 是 phone-only overlay，不動 dsh-bot pin。

---

## 8. 需要誰授權什麼

| 授權者 | 要授權的具體事項 | 不做會怎樣 |
|---|---|---|
| **P12 owner** | 把 `BotModelPurpose*` 型別移到 `PhoneDSHAgentCore`（無新增依賴邊、公開名稱如何保留） | 路線 1b 不成立，只剩反轉依賴（不建議） |
| **P05 owner** | `x-pdsh-model-purpose` 條款＋`hop-*` 向量＋Kotlin 對端；**並確認 strip 語義不變** | 沒有載體，接線＝全拒 |
| **P26 owner** | golden 補「缺席／未知值」向量，並**選 (a) 或 (b)**；決定執行點狀態寫 `partial` 還是 `NOT_IMPLEMENTED` | 缺席語義未定，等於實作者自己選（AGENTS §2.1） |
| **owner（計畫）** | 接受「GAP-42 在 pinned adapter 改動前不會關閉」；以及「本輪仍不 fail-closed」 | 會有人為了關 GAP 而偷偷 fail-closed |
| **（不由本倉）upstream** | pinned 模型適配器保留並傳遞 purpose（值從哪裡來） | 第 (iii) 前提永久缺失 |

---

## 9. 未量測 / 開放問題

- **未驗證**：pinned 模型適配器是否真的丟掉 purpose（`PDSH_DSH_CHECKOUT` 在本 worktree 未設定；
  沿用 `PC-20261112-model-purpose-gap.md` §2.3 的記載）。
- **未量測**：若走 (b) fail-closed，會拒掉多少比例的請求（需要一次真機統計；本輪不做）。
- **開放**：`provider` 欄位（E3）在執行點要由誰填（gateway 解析憑據前看不到 provider id）。
  本備忘不決定；若要填，屬 P05 的另一個 additive 變更。
- **開放**：`BotLLMLedger` 的 purpose 與 wire purpose 是否必須一致、由誰比對。今天沒有比對機制，
  本備忘建議**先不新增**（會變成第二個權威），等載體真的有了再談。
