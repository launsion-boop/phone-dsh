<!-- SPDX-License-Identifier: MIT -->
# DEC-20261112-gap40 — pc backend 的 durable outbox：schema rev、scope 條款、fail-closed 邊界

Protocol impact: none — documentation only

Status: **proposal（供 P06 owner 簽核）**
對應 GAP: [GAP-40](../../spec/README.md)（P06，open）
權威變更單: [PC-20261112-w1-browse-outbox.md](../protocol-changes/PC-20261112-w1-browse-outbox.md)（Rev 5 已凍結「只涵蓋 local」）
前置閱讀: [決策備忘](perf-stability-open-gaps-20261112.md) §2 的 D3

---

## 1. 一句結論

GAP-40 的登記文字有一處需要修正：pc backend **不是沒有權威歷史**，而是**權威歷史在對端、且只在線
可讀**，而且 outbox entry **沒有記錄是哪一台 PC**。所以覆蓋 pc 的最小 delta 不是重做狀態機，而是
**一個 additive 欄位（`backendRef`）＋一段 backend scope 條款＋四條 fail-closed 邊界**。真正會阻擋
它的是**使用者可見決定**（pc 離線時要不要收下並顯示「排队中」），不是技術。

---

## 2. 現況與證據

| # | 證據 | 說明 |
|---|---|---|
| E1 | `spec/host/v1/README.md:259-270` | §10 的 scope 條款（W1 rev 5）：durable outbox／狀態機／`rpcId`／delete condition **只適用 local**；`pc` 留在 pre-W1 直送、**非 crash-durable**；`backend: "pc"` 只是 forward compatibility、沒有 durable 保證 |
| E2 | `spec/host/v1/README.md:342-345` | 「只有 `backend: local` 在本輪的 durable outbox 上；pc 等 GAP-40 定義 authoritative-history 等價物」 |
| E3 | `spec/host/v1/schema/outbox-entry.schema.json:64-69`、`:192-197` | `backend` enum 只有 `local`／`pc`；**不是 required**（`required` 清單見 `:21-30`），而且**沒有機器識別** |
| E4 | `examples/probe-app/PhoneDSHProbe/ChatModel.swift:3451-3457` | `send()` 在 `pcRuntime != nil` 時直接 `sendDirect`（pre-W1 直送），local 才 `enqueueSend` |
| E5 | `examples/probe-app/PhoneDSHProbe/ChatModel.swift:3628-3629` | `drainSendOutbox()` 第一行就是 `guard pcRuntime == nil`：pc 完全不進入佇列 |
| E6 | `examples/probe-app/PhoneDSHProbe/ChatModel.swift:758-766` | `canAcceptSend`：local 永遠收；**「The PC backend keeps its existing online/ready gate」**（pc 離線＝不能送） |
| E7 | `examples/probe-app/PhoneDSHProbe/ChatModel.swift:358-365`、`:730` | outbox 是**單一目錄**（`Application Support/phone-dsh/send-outbox`），不含 backend 維度 |
| E8 | `examples/probe-app/PhoneDSHProbe/ChatModel.swift:3700-3732` | `authoritativeHistoryContains` 走 `session/page` 讀回，**不走本地快取**（「the engine must be the source; a local cache is never proof」） |
| E9 | `examples/probe-app/PhoneDSHProbe/ChatModel.swift:1312-1314` | 讀回用的 transport 是 `workspaceBackend.transport()` → **pc 也有**（回傳 relay transport） |
| E10 | `examples/probe-app/ProbeKit/Backends/PCWorkspaceBackend.swift:178-184` | pc 的 `transport()` 在離線時 **throw**（`unavailable`）——這就是「權威歷史只在線可讀」 |
| E11 | `examples/probe-app/ProbeKit/Backends/WorkspaceBackend.swift:14-26` | `BackendID` 有 `.pc(machineId:)`，`storageScope` 產生 `"pc:<machineId>"`，但檔內自述 **"Persistence does not use this yet"** |
| E12 | `examples/probe-app/ProbeKit/Outbox/SendOutbox.swift:230-262` | entry decoder 是**封閉成員集**：未知成員 → `dataCorruptedError`（所以新增欄位＝舊版建置拒收） |
| E13 | `examples/probe-app/ProbeKit/Outbox/SendOutbox.swift:340-360`、`:368` | `SendOutbox(directory:)` 無 backend 參數；`enqueue(..., backend: = .local)` |
| E14 | `docs/protocol-changes/PC-20261112-w1-browse-outbox.md:286-288`、`:313-316` | Rev 5 的 CCR 原文：pc transport 沒有 local `materialized/home/sessions` 的權威歷史，delete condition 在 pc 沒有 defined referent |
| E15 | `spec/host/v1/README.md:300-305`、`:333-341` | attachment 生命週期與五個 crash 點；**pc entry 若永不被確認，其 bytes 永不被回收**（本輪沒有任何到期規則） |
| E16 | `docs/protocol-changes/PC-20261112-w1-browse-outbox.md:175-198` | Rev 4 已凍結的 crash/digest 規則（pc 覆蓋時必須沿用，不得另寫一套） |

**E8＋E9＋E10 合起來是本備忘與 GAP-40 登記文字的唯一實質差異：** pc 的 delete condition 有 referent
（`session/page`），只是它是**遠端且在線**的。真正缺的是 entry 上的「哪一台 PC」與「離線時怎麼辦」。

---

## 3. 需要的 schema rev

兩個選項；建議 **S1**。

### S1（建議）在 `v: 1` 內 additive 新增 `backendRef`

```json
"backendRef": {
  "type": "string",
  "pattern": "^(local|pc:[A-Za-z0-9._-]{1,64})$"
}
```

- 位置：兩個 `oneOf` 分支各加一次（text 版與 attachment-only 版），與 `backend` 相鄰。
- 機器識別不用新發明：PCLink v1 已凍結 `machineId = lower(base32_nopad(sha256(E)))[0:26]`
  （`spec/pclink/v1/README.md:219`），所以 pc 的 `backendRef` 可以收緊成 `^pc:[a-z2-7]{26}$`，
  而不是我上面那個寬鬆的 pattern。寬鬆版只是「不想在本備忘凍結格式」的預設；**實際 pattern 由
  P28 的 machineId 規則決定**。
- 條件約束：`backend: "pc"` ⇒ `backendRef` 必須存在且以 `pc:` 開頭；`backend: "local"` ⇒ 可省略。
  JSON Schema 用 `if/then` 表達，或比照 F1（`PC-20261112-w1-browse-outbox.md:329-331`）記為 store 層
  law 並在 `test_outbox_contract.py` 加正反例 —— 兩種都可以，但**只能選一種**，不得兩邊各寫一半。
- 舊資料：現存 entry 一定帶 `"backend":"local"`（E13 的預設值，非 nil 會被寫出），沒有 `backendRef`
  → 新 consumer 視為 `local`。**沒有遷移**。
- **回滾邊界（重要）**：E12 的封閉 decoder 會讓舊建置拒收帶 `backendRef` 的新 entry。這與 W1 Rev 4
  對 `attachments` 已記錄的 App-only 邊界同型：**舊 consumer 拒收是 fail loud，不是資料損壞；回滾時
  不得刪除、不得文字化降級、不得改寫 `rpcId`**。這條要寫進 §10，不是留給實作決定。

### S2 升 `v: 2`，用 `oneOf` 分 local 版／pc 版

- 好處：pc 版可直接把 `backendRef` 設成 required，語義最乾淨。
- 代價：`v` 的 `const` 從 1 變 2 ⇒ 所有舊 entry 要走雙版讀取；`SendOutbox.validateDecoded`
  （E12）與 Kotlin 端都要同時接受 1 與 2；schema `oneOf` 三→四分支。
- **不建議**：換來的只是「required」這一點語義，卻要付一次版本矩陣。

### S3（不建議）把 `backend` 的 enum 擴成 `["local","pc:<machineId>"]`

- 這是**同一個欄位第二種意義**（AGENTS §2.1），並且直接破壞既有 enum 的封閉性（`backend` 已是
  wire 上的欄位）。列出來只為了在 review 時明確否決它。

---

## 4. backend scope 條款（草案，可直接貼進 `spec/host/v1/README.md` §10）

> **Scope（W1 Rev 6 / GAP-40 Rev A）。** The durable outbox covers `backend: "local"` and
> `backend: "pc"` when the entry carries `backendRef`. For the `pc` backend the authoritative history is
> the paired PC runtime's `session/page` projection, which is readable **only while the pairing
> connection is online**. Therefore, for a pc entry:
>
> 1. enqueue is the durable fact, exactly as for local (one entry, one `rpcId`, same state machine);
> 2. a transport acknowledgement never makes an entry `durable`; only the online read-back does;
> 3. an offline or failing read-back leaves the entry in its current state (`queued` or
>    `outcomeUnknown`) with **no resend**, exactly the local rule;
> 4. an entry whose `backendRef` machine id does not match the currently paired machine is **not
>    submitted, not deleted and not rewritten**; its internal `lastError` is `backend_machine_mismatch`
>    and it is retried only after that machine is paired again;
> 5. a backend switch never moves an entry to another backend or another session; the local and pc
>    queues share one store directory and one `rpcId` namespace, so a `rpcId` is unique across both.
>
> The pre-W1 direct path is removed for pc only when rules 1–5 are implemented and tested on both the
> enqueue and the read-back side; until then §10's Rev 5 scope paragraph stays in force.

條款刻意**不**回答「pc 離線時能不能收下訊息」（E6）。那是產品決定，放在 §7。

---

## 5. fail-closed 邊界（pc 專屬，四條，全部「保留資料」方向）

| # | 情況 | 必須 | 不得 |
|---|---|---|---|
| F-1 | pc 離線／relay 斷線（E10） | 保留 entry、保留 attachment bytes、維持現狀態、不重送 | 不得降級成 `sendDirect`、不得刪 entry、不得改 `rpcId`、不得把 entry 轉 local |
| F-2 | 讀回成功但沒有該 `rpcId`（權威說沒有） | 依狀態機：`outcomeUnknown → queued`（可重送，同 `rpcId`） | 不得新建第二個 `rpcId`、不得把「沒讀到」當成「不存在」（`ChatModel.swift:3742-3744` 已是這個語義） |
| F-3 | 配對換機器（`backendRef` 與現行 machine 不符） | 凍結 entry、內部診斷 `backend_machine_mismatch` | 不得送到新機器、不得刪除、不得改寫 `backendRef` |
| F-4 | store 超配額／attachment bytes 缺失 | 拒絕新 enqueue（可見錯誤，屬 budgets §9 level 4 類型）、既有 entry 不動 | 不得丟棄舊 entry 來騰空間、不得把缺失 bytes 當 inline 送出 |

**儲存風險（E15）**：pc entry 若永遠等不到確認，bytes 永不回收。本輪**沒有**到期規則，所以 F-4 的
「拒絕新 enqueue」是唯一安全的壓力閥。要不要加 pc 專屬保留期，屬 GAP-40 的 blob/store 配額項
（`spec/README.md:233` 已登記），本備忘不決定。

---

## 6. 四格兼容矩陣

| 邊界 | old → new | new → old | new → new | 舊資料 → new／rollback |
|---|---|---|---|---|
| schema（S1） | 舊 entry（無 `backendRef`、`backend:"local"`）→ 讀成 local，語義不變 | 新 entry（帶 `backendRef`）→ **舊 decoder 拒收**（E12，封閉成員集）＝ fail loud，資料與 bytes 都保留 | 同一 golden／`test_outbox_contract.py` 讀同一組正反例 | 無遷移；回滾＝保留或還原，**不得刪除** |
| pc 的 delete condition | 舊行為：直送、無 entry、無 durable 承諾 | 新 pc entry 在舊版建置裡不存在 | 兩端都在線才可能 `durable`；離線時**兩端都不會**誤判成功 | 舊 pc 訊息沒有 entry，回滾後也不會突然出現 |
| 使用者可見 | **取決於 §7 的決定**：若 pc 也 enqueue，離線送訊會從「被拒絕」變成「排队中」 | 舊版沒有「排队中」的 pc 語義 → 回滾後仍走直送 | 同左 | 無持久化語義變化（entry 是新的） |
| Kotlin／P06 consumer | 本輪 **沒有** Kotlin consumer（`android/` 無 `send-outbox` 命中） | 舊 Android 不讀此 store | 需另一個變更單（GAP-40 已登記） | N/A |

---

## 7. 建議

1. **先修登記文字**（P06 owner，純文字）：把 GAP-40 的「pc 沒有 authoritative-history 等價物」改成
   「pc 的權威歷史是對端 `session/page`，只在線可讀；entry 缺機器識別」。**這一條不改任何 schema**，
   而且它讓後續工作有一個正確的起點。
2. **採 S1**：加 `backendRef`＋§4 條款＋§5 四條邊界＋一個 `test_outbox_contract.py` 正反例
   （`backend: "pc"` 無 `backendRef` 無效；`pc:` 前綴不符無效；`local` 可省）。
3. **pc 也 enqueue ＋ 離線顯示「排队中」**（建議），理由：
   - 契約的 delete condition 已經有 referent（E8／E9），不是新發明；
   - 使用者目前離線送訊是**靜默失敗**（E6 的 `canAcceptSend` 回 false → `send` 回 false），
     W1 對 local 已經承認「靜默失敗」是缺陷並修掉；pc 沒理由維持更差的行為；
   - 風險可控：F-1～F-4 都是「保留資料」方向，最壞情況是使用者在 PC 回來後看到自己排隊的訊息。
   - **代價**：這是使用者可見變化（新的 pc「排队中」狀態），需要 owner 明確授權，且要改
     `canAcceptSend` 的 pc 分支（P18 的設定鍵不變）。
4. **不要**在這一輪順手做跨裝置 attachment 同步、blob dedupe／refcount／GC、at-rest 抹除、
   Kotlin consumer。`spec/README.md:233` 已逐條登記，把它們塞進同一個變更會讓兼容矩陣失控。

---

## 8. 需要誰授權什麼

| 授權者 | 要授權的具體事項 | 不做會怎樣 |
|---|---|---|
| **P06 owner** | ①改寫 GAP-40 的 pc 描述；②`outbox-entry.schema.json` 新 rev（`backendRef`）；③§10 的 scope 條款（§4 草案）；④四條 fail-closed 邊界進契約 | pc 永遠在 pre-W1 直送；GAP-40 的登記文字持續誤導（說「沒有等價物」） |
| **owner（產品）** | pc 離線時是否收下並顯示「排队中」（＝接受一個新的可見狀態） | 若拒絕：pc 覆蓋只能做「在線時才 enqueue」，價值大打折扣 |
| **P06／P18 owner** | `canAcceptSend` 的 pc 分支（若採「也 enqueue」） | 實作不敢改 gate，pc 永遠進不了佇列 |
| **（後續）P06＋Android** | Kotlin consumer 與跨端同步／抹除／GC（GAP-40 其餘項） | 那些項維持 open，不因本 rev 關閉 |

---

## 9. 未量測 / 開放問題

- **未量測**：pc backend 上 outbox 的 crash 矩陣（尚未實作）；pc 讀回延遲（relay RTT）對
  `outcomeUnknown` 停留時間的影響。
- **未驗證**：pc 的 `session/page` 在 PC 端重啟後是否仍保留舊 `rpcId`（若 PC 的 runtime 換了歷史，
  讀回可能永遠找不到 → entry 卡住）。這需要一次真機實驗，不在本輪。
- **開放**：pc entry 的 bytes 保留期（E15）。不加保留期就是無上限成長，加了就是新的可見語義；
  屬 GAP-40 的 store 配額項。
- **開放**：`backendRef` 用 `pc:<machineId>` 還是獨立的 `machineId` 欄位。本備忘建議前者（字串、
  可 pattern 驗證、不必新增第二個欄位），但這是 P06 的形狀選擇。
