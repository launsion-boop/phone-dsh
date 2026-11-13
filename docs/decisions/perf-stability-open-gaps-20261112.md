<!-- SPDX-License-Identifier: MIT -->
# 決策備忘：perf-stability 四項未完成缺口＋bot-context 小模型衝突（2026-11-12）

Protocol impact: none — documentation only

Status: **proposal（供簽核，不是契約）**。本文件不是變更單，不改任何 `spec/`、`Sources/`、
`plugins/`、`scripts/` 或 `.github/`。每一項的契約修訂仍須由該項 owner 依
[AGENTS.md](../../AGENTS.md) §3 另開變更單並凍結契約修訂；本文件只把選項、代價與授權範圍寫到
「可以直接拍板」為止。

```
Base:        59e5af95f（main，PR #139 merged）
Worktree:    docs/gap-proposals
Scope:       文件；五份附錄各自可單獨閱讀
Owner 名單:   P03/P04（GAP-39）、P05/P12/P26（GAP-42）、P06（GAP-40）、
             contracts-w6／upstream（GAP-41）、P26（bot-context）
```

---

## 1. 這份備忘在處理什麼

`perf-stability-20261111` 已合入 `main`（PR #139）。W0／W1／W2／W3／W4／W5／W7 都有變更單（`docs/protocol-changes/PC-20261112-w*.md`），
`spec/README.md` §7 仍開著 **GAP-39／40／41／42**。這四項都不是「再跑一次測試就會綠」的工作：每一項
都卡在一個**需要 owner 裁定的語義選擇**或**外部依賴**上。另有一項（bot-context 與小模型壓縮）不在
GAP 表內，但它與同一工作包的 W5 驗收直接衝突，且現況已經是「同一設定兩個權威」，必須一併裁定。

本備忘對每一項寫齊：**證據（`file:line` 或變更單節號）→ 選項（能測到／測不到／動哪條契約／成本／
風險）→ 建議 → 需要誰授權什麼**。沒有量測數據的地方一律寫「未量測」。

---

## 2. 五項決策一覽（給 owner 的拍板頁）

| # | 項目 | 一句話問題 | 本備忘建議 | 需要誰授權 | 否決時的替代 | 詳見 |
|---|---|---|---|---|---|---|
| D1 | **GAP-39** engine heap 取樣 | 宿主讀不到 WebContent 的 heap，而 GAP-39 登記的關閉路徑（Worker JS `performance.memory`）在 WebKit **不存在**。要不要把契約從「sampled engine heap」改成「可量測的代理＋結果型訊號」？ | 改契約：§3／§4 的 engine-memory 輸入改為「系統記憶體警告 ＋ WebContent 終止次數 ＋ 宿主 `phys_footprint`／`os_proc_available_memory` 代理（明示為 proxy、不與 App process 列重複計帳）」，並**刪掉不可實作的 `performance.memory` 關閉路徑**。sampled heap 維持 `target`。 | P03（`budgets.md` §3／§4）＋ P04（是否加 bridge kind）＋ owner 接受「代理」語義 | 維持 rev 2 現狀（warning 為唯一生產輸入），把 GAP-39 標為「等 Apple 或 upstream 開放 API」，不放進任何里程碑 | [DEC-39](DEC-20261112-gap39-engine-heap-signal.md) |
| D2 | **GAP-42** model-purpose 執行點 | 三個前提缺一不可，但**先接線會拒絕全部模型請求**（gate 對缺 purpose 是 fail-closed）。要不要先做 carrier、再把型別下沉，接受長期 `partial`？ | 兩步：①把 `BotModelPurpose*` 型別下沉到 `PhoneDSHAgentCore`（兩端已依賴，**不必反轉依賴方向**，P12 additive）；②新增 P05 的 `x-pdsh-model-purpose`（**additive、非 breaking**，既有 `x-pdsh-*` strip 規則已覆蓋），由 Worker 端 `llm-bridge` 的既有 fetch 接縫填值；**缺值時不 fail-closed**（沿用基線），GAP-42 維持 open 直到 pinned adapter 保留 purpose。 | P12（模組歸屬）＋ P05（新標頭）＋ P26（policy 權威）＋ owner 接受第三個前提只能靠 upstream | 只做 P12 下沉，不加 wire 載體（enforcer 仍無呼叫方，GAP-42 原樣 open） | [DEC-42](DEC-20261112-gap42-model-purpose-wiring.md) |
| D3 | **GAP-40** pc backend 的 durable outbox | 登記文字說 pc「沒有 authoritative-history 等價物」，但**實際有**：pc 走 `session/page` 遠端讀回，只是離線不可讀、且 entry 沒記錄機器身分。要不要在 entry 補上機器身分（`backendRef`）並把 pc 納入 outbox？ | 擴 v1（additive）：entry 新增 `backendRef`（`local` 或 `pc:<machineId>`），`backend: "pc"` 只有帶 `backendRef` 才合法；pc 也 enqueue，delete condition 用**在線**的 `session/page` 讀回；離線＝停在 `outcomeUnknown`、不重送、不刪、不降級直送；機器不符 fail-closed 保留。 | P06（`spec/host/v1/README.md` §10＋`outbox-entry.schema.json` 新 rev）＋ owner 決定「pc 離線時要不要顯示 queued」 | 維持 Rev 5（pc 直送、非 crash-durable），把 GAP-40 只收窄成「已知限制」而非待辦 | [DEC-40](DEC-20261112-gap40-pc-outbox-durability.md) |
| D4 | **GAP-41** W6 overlay manifest | 上游 `readImage` 只吃 gzip'd ustar，本倉不得 patch。要不要用既有「ordered overlays」做**分層增量** adapter，並改寫 W6 驗收？ | 先承認上限、再選 adapter：①（建議先做）W6 驗收改寫成「無 mutation 的 boot ≤ 1 s；有 mutation 的 boot = O(變動位元組)（分層）或 O(工作區位元組)（現況）」，§8.1 保持 `target`；②若要往前推，採**分層增量 overlay**（改 P02 §8.1／§14.8＋P16 的 `overlays` 政策），但**刪除不可表達**，任何刪除仍退回整棵重打包。 | upstream（DSH maintainer）給 manifest reader／能力字串；P02 owner 修 §8.1；P16 owner 開放 `overlays`；owner 接受驗收改寫 | 只改驗收、不做 adapter：W6 的「與工作區大小無關」目標正式撤回，單副本只保留已交付部分 | [DEC-41](DEC-20261112-gap41-overlay-manifest-upstream.md) |
| D5 | **bot-context** 與小模型壓縮 | 有效設定（platform row）已是 `deepseek-official`／`deepseek-flash`；但 bot profile 目錄被 byte-exact golden 釘在 `""`／`""`，而該目錄**目前沒有任何 runtime 消費者**。要不要為一個沒有消費者的欄位動 golden？ | **現在不動 golden**：維持目錄 `""`／`""`，並在契約／註解寫明「有效值在 `phone.worker` 的 platform row；目錄是 upstream 鏡像，不是第二個權威」。等 WP7 真的 materialize 目錄時，同一變更內改成 `context-profiles.phone.json` overlay（additive，不動 upstream 檔）。 | P26（決定鏡像語義與是否加 guard）＋ owner 接受「Bot profile 的小模型壓縮本輪未生效」登記 | 立刻改 golden（overlay 覆蓋 `valid.yaml.*`）＋改 Swift frozen，代價是動一個沒有消費者的契約面 | [DEC-BC](DEC-20261112-bot-context-small-model.md) |

---

## 3. 建議的決策順序

1. **D1（GAP-39）先做**：它決定 §4 的「Engine heap」列還算不算一個可執行的預算。其他四項都不依賴它，
   但 W2 的閉環驗收與 `RestartPolicy` 的 `heapPressure` 觸發都在等這個答案。
2. **D5（bot-context）第二**：零成本、零程式碼，只是把「哪一個是權威」寫清楚；先做可避免 WP7 落地時
   把已生效的小模型悄悄覆蓋回大模型。
3. **D3（GAP-40）第三**：唯一有明確 schema delta 的一項，且 delta 很小（additive 一個欄位＋一段條款）。
4. **D4（GAP-41）第四**：需要 upstream 回覆，先凍結「上限」共識，adapter 與否可以後續再定。
5. **D2（GAP-42）最後**：三個前提裡有一個（pinned adapter 保留 purpose）本倉無法獨立滿足；先做 carrier
   與型別歸屬，才有資格談關閉。

---

## 4. 簽核欄

每一列由對應 owner 填寫；「決定」欄只接受 `核准建議`、`改採 <選項>`、`延後（日期／條件）` 三種寫法。
否決建議時請直接寫明改採哪一個選項，以便另開變更單。

| 項目 | Owner | 決定 | 契約修訂單號 | 日期 |
|---|---|---|---|---|
| D1 GAP-39 engine-memory 輸入 | P03／P04 |  |  |  |
| D2 GAP-42 purpose carrier 與型別歸屬 | P05／P12／P26 |  |  |  |
| D3 GAP-40 pc outbox 與 `backendRef` | P06 |  |  |  |
| D4 GAP-41 W6 上限與 adapter | contracts-w6／upstream |  |  |  |
| D5 bot-context 權威歸屬 | P26 |  |  |  |

---

## 5. 共用證據與限制（細節在各附錄，此處只列會跨項引用的事實）

| 事實 | 位置 |
|---|---|
| `PhoneDSHHost.reportEngineHeapBytes` 的唯一呼叫者是測試 | `Sources/PhoneDSH/PhoneDSHHost.swift:5426`、`Tests/PhoneDSHTests/BigFileBudgetTests.swift:254`、`:271` |
| sampled engine heap 在 W2 rev 2 已被降級為 `target`，warning 是唯一生產輸入 | `spec/v1/budgets.md:76-83` |
| GAP-39 登記的關閉路徑要求「Worker JS `performance.memory`」 | `spec/README.md:232` |
| purpose gate 對缺 purpose 是 fail-closed | `Sources/PhoneDSHBot/Ledger/BotModelPurposePolicy.swift:178-186` |
| `PhoneDSHGateway` 只依賴 `PhoneDSHAgentCore`；`PhoneDSHBot` 也只依賴 `PhoneDSHAgentCore` | `Package.swift:53`、`Package.swift:74-75` |
| wire 請求只有 method／url／headers／body | `Sources/PhoneDSHGateway/ModelGateway.swift:196-206`、`Sources/PhoneDSHLoopback/Loopback.swift:119-131` |
| 所有 `x-pdsh-*` 在送上游前被剝除（唯一例外是 loopback 的 journal key） | `Sources/PhoneDSHGateway/ModelGateway.swift:1420`、`spec/v1/gateway-security.md:68-85` |
| outbox schema 的 `backend` enum 已接受 `pc`，但沒有機器身分 | `spec/host/v1/schema/outbox-entry.schema.json:64-69`、`:192-197` |
| pc backend 目前的送出路徑是 `sendDirect`，drain 對 pc 直接 return | `examples/probe-app/PhoneDSHProbe/ChatModel.swift:3455`、`:3629` |
| pc 的權威歷史讀回其實可用（走 `session/page`），只是要 online | `examples/probe-app/PhoneDSHProbe/ChatModel.swift:3704-3732`、`examples/probe-app/ProbeKit/Backends/PCWorkspaceBackend.swift:178-184` |
| overlay 是 watermark-keyed 快取；未變更時只 hard link，變更時整棵重打包 | `Sources/PhoneDSHLog/WorkspaceLogService.swift:488-527`、`:590-599` |
| 上游 `readImage` 只接受 gzip；overlay 是整檔取代 | `Sources/PhoneDSHLog/OverlayPacker.swift:1-13`、`spec/v1/wal.md:412-425`、`docs/upstream/0002-overlay-merge-home-patch.patch` |
| runtime 的 overlays 是**有序陣列**，宿主已支援多個但主動清空 | `plugins/worker-entry/src/entry.ts:301-302`、`Sources/PhoneDSHEngine/WebEngineConfiguration.swift:97-98`、`Sources/PhoneDSH/PhoneDSHHost.swift:4084` |
| bot-context 目錄被 byte-exact 測試釘住，golden 由 pinned dsh-bot 匯出 | `Tests/PhoneDSHBotTests/Watchdog/BotContextProfilesTests.swift:20-28`、`spec/tools/bot/export-vectors.mjs:48`、`:235-238` |

**範圍限制。** 本備忘只讀得到本倉。pinned DSH checkout（`PDSH_DSH_CHECKOUT`）在本 worktree 未設定，
因此「上游 `readImage` 只認 gzip ustar」與「pinned 模型適配器不保留 purpose」兩條**沿用既有變更單與
`spec/` 的記載**，本輪沒有重新打開 checkout 原始碼核對（見 §7）。

---

## 6. 本文件明確不做的事

- 不改 `spec/README.md` §7 的 GAP 表，也不改任何 GAP 的狀態（那是契約 owner 的）。
- 不改 `budgets.md`、`wal.md`、`host/v1/README.md`、`gateway-security.md`、任何 schema／golden。
- 不改 `Package.swift`、不改任何 Swift／TS／Kotlin 實作、不改 profile patch。
- 不開 PR、不 push。
- 不把任何「建議」寫成「已決定」：本文所有建議在簽核前都只是選項之一。

---

## 7. 未量測 / NOT_VERIFIED

| 項目 | 狀態 | 影響 |
|---|---|---|
| WebContent 進程的真實記憶體讀數 | **未量測**（本倉無 producer；WKWebView 無公開 API） | D1 只能給代理方案；任何「sampled heap 已接線」的說法都不成立 |
| 宿主 `phys_footprint` 與 jetsam 的相關性 | **未量測**（`examples/probe-app/ProbeKit/ProcessMetrics.swift:13-14` 自述 NOT_VERIFIED） | D1 的代理方案不能宣稱能預測 jetsam |
| 代理門檻是否會誤觸 `heapPressure` 重啟 | **未量測** | D1 建議先以「只記錄、不觸發動作」上線一輪再談 enforcement |
| `performance.memory` 在 WebKit | **已查證不存在**（MDN：非標準、deprecated、僅 Chromium；`mdn/browser-compat-data` `api/Performance.json` 的 `memory.support.safari = false`；`measureUserAgentSpecificMemory` 同樣 `safari: false`） | GAP-39 的登記關閉路徑不可實作，必須改寫 |
| pinned DSH checkout 的 `readImage` 原始碼 | **NOT_VERIFIED**（checkout 未設定；沿用 `spec/v1/wal.md:412-425` 的記載） | D4 的「卡在哪個能力」是依據既有記載，不是本輪重讀 |
| pinned 模型適配器是否保留 purpose | **NOT_VERIFIED**（同上；沿用 `PC-20261112-model-purpose-gap.md` §2.3） | D2 的第三個前提只能標 open |
| overlay 重打包的實測秒數 | **未量測**（`WorkspaceLogService.swift:493-495` 的註解記錄「100 MB 工作區約 10 秒」，本輪未重量測） | D4 的上限用「O(位元組)」描述，不引用秒數當承諾 |
| pc backend 上 outbox 的 crash 矩陣 | **未量測**（尚未實作） | D3 的 fail-closed 邊界只是設計，不是證據 |
| Bot profile 的小模型壓縮是否真的生效 | **未量測**（`BotContextProfile*` 在本倉沒有 runtime 消費者） | D5 的「維持現狀」建立在「目錄不生效」這個觀察上 |

---

## 8. 驗證（本文件自身）

本文件只新增 `docs/decisions/` 下的 Markdown，沒有跑任何建置或行為測試（也不該有）。

```
bash scripts/ci/check.sh --only phone-hygiene
git status --short
```

結果見交付回報。**注意：`phone-hygiene` 在 base `59e5af95f` 上本來就是 FAIL**（既有 `spec/v1/tono-account.md`
等檔案的 `banned-word`／`hostname` 命中，與本文件無關）；本文件的驗證標準是「不新增任何 finding」，
而不是「讓這個 stage 變綠」。`phone-hygiene` 的掃描根確實包含 `docs`（`scripts/ci/common.py:71-79`），
所以這是一個有效檢查，不是空跑。

---

## 9. 附錄索引（每份都可單獨閱讀）

| 檔案 | 內容 |
|---|---|
| [DEC-20261112-gap39-engine-heap-signal.md](DEC-20261112-gap39-engine-heap-signal.md) | GAP-39：五個 engine-memory 輸入方案、各自能測到什麼、要動哪條契約、建議的雙軌做法 |
| [DEC-20261112-gap42-model-purpose-wiring.md](DEC-20261112-gap42-model-purpose-wiring.md) | GAP-42：三條路線（＋一條型別下沉）的契約修訂、兼容矩陣、是否 breaking、建議順序 |
| [DEC-20261112-gap40-pc-outbox-durability.md](DEC-20261112-gap40-pc-outbox-durability.md) | GAP-40：schema rev、backend scope 條款草稿、fail-closed 邊界、兼容矩陣 |
| [DEC-20261112-gap41-overlay-manifest-upstream.md](DEC-20261112-gap41-overlay-manifest-upstream.md) | GAP-41：卡住的上游能力、兩種 adapter 的實際上限、若上游不改 W6 的極限 |
| [DEC-20261112-bot-context-small-model.md](DEC-20261112-bot-context-small-model.md) | bot-context 目錄與小模型壓縮：三個選項與代價、建議的 gating 條件 |
