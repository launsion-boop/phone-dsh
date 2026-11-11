<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-w1-browse-outbox — W1 read-only session projection and durable send outbox

## 0. 摘要

```yaml
change: PC-20261112-w1-browse-outbox
contracts: [P02, P06, P18]
status: frozen
breaking: false
version_decision: 無 proto 版本變更。W1 rev 3 在 host 私有 `send-outbox` entry 新增可選 `attachments[]`（引用＋metadata，非 inline bytes）；W1 rev 4 允許 `text:""` 當且僅當 attachments 非空，並把 `attachments` 上限改為 20（鏡像 host `imageLimits.maxImagesPerMessage` 的 fallback）。舊 text-only entry 仍合法可讀；舊 consumer 的 closed schema 會拒絕帶 attachments 的新 entry，這是同容器 App-only 邊界；回滾不得刪除或文字化降級排隊中的 attachment entry。materialized 寫入禁令、outbox 狀態機與 `rpcId` 不變，不改 P01 frame、P06 event 或 P18 既有設定鍵。
base: d988108c1ec0c56903d6087c282cc9278bbdfd19
contract_revision: spec/host/v1/README.md@2026-11-12-rev4 + spec/host/v1/schema/outbox-entry.schema.json@rev4 + spec/README.md@GAP-40 + spec/host/v1/{golden,tools}/outbox*@rev4（rev 1 spec commit 773fa69d081917adefc2a6ad114ee6d88b5832ce；rev 2/3/4 freeze commit 見交接 head）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  - **只讀投影（P02/P18）。** 現況：W1-A 需要瀏覽會話時直接讀宿主 `materialized/home/sessions/`，但 v3 的硬約束是「禁止直接操作 materialized/」，沒有任何條款登記例外的讀者、範圍與新鮮度；各端只能猜。期望：在 `wal.md` §11 登記唯一的只讀投影：只有 App 的 UI／model 層與既有 Bot `phone record` 路徑可讀，只讀 `materialized/home/sessions/**`，絕不寫入、刪除、移動、rename、chmod；資料是 materialized 快照，可能落後 WAL／Worker 內存最多一個 epoch，不是進行中回合的權威；引擎就緒後用既有 `session/list`、`session/page` 增量對齊，引擎為準。
  - **持久 outbox（P06）。** 現況：發送先落內存陣列 `queuedPromptsDuringRecovery`；引擎未起或傳輸中斷時消息可能不在時間線，崩潰會丟失。期望：發送先落盤並立即顯示 `queued`，以入隊時生成的 UUIDv4 `rpcId` 投遞；狀態機 `queued → submitting → accepted → durable` 加 `outcomeUnknown`；只有在權威歷史看到同一 `rpcId` 的 user_message 才刪；傳輸中斷先回讀核對再決定，不盲目重送。
- **Coordinator / contract owner**：本單元 `contracts`。**Implementers**：`w1-browse` 只改 probe app 的 Chat／Session／抽屜與 `ProbeKit/Transcript`、`ProbeKit/Outbox`、`ProbeKit/Lifecycle`、`PhoneDSHSimTests`；不改 `spec/`、不改 `Sources/`。
- **Owning spec / schema / fixtures**：
  - [wal.md](../../spec/v1/wal.md) §11（只讀投影）。
  - [host/v1/README.md](../../spec/host/v1/README.md) §10（持久 outbox）；[outbox-entry.schema.json](../../spec/host/v1/schema/outbox-entry.schema.json)；正向 golden `outbox-entry-queued.json`、`outbox-entry-outcome-unknown.json`；負向 `tools/outbox_invalid_cases.json` 與 `tools/test_outbox_contract.py`（UUID、欄位、五個非法轉移）。
  - `spec/v1/tools/spec_golden.py` 的 §5.2 上限修訂（wal.md 416 → 510，W1／W3／W4 共用）。
- **受影響 producer / consumer**：
  - App/Swift：`ChatModel`、`SessionsPage`、`DSHManagementModel`、`ProbeKit/Transcript`、`ProbeKit/Outbox`、`ProbeKit/Lifecycle`；引擎 RPC 仍由 host 提供。
  - host contract P06：Kotlin `android/core/**` 目前沒有這個 outbox，另一支 App 端必須跟隨；本輪不宣稱 Kotlin 已實作。
  - P18：`materialized/` 不是設定檔；新增的 outbox 不寫進 UserDefaults，也不是 `dsh/home/*.json`。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| 只讀投影的讀者 | 無 → App 的 UI／model 層（`ProbeKit/Transcript`）與既有 Bot `phone record`。Worker、device、remote host、任意進程不可透過此例外讀。 |
| 只讀範圍 | 無 → `materialized/home/sessions/**`；`materialized/workspace/**` 不在例外內。開啟方式只讀，禁止 create/write/append/truncate/delete/move/rename/chmod。 |
| 新鮮度語義 | 無 → materialized 快照，可能落後 WAL 與 Worker 內存最多一個 open epoch；不是進行中回合的權威；torn final line 忽略；檔案被 rename/remove 時重試或回退；不修復、不對账。 |
| 引擎對齊 | 無 → 引擎 ready 後用既有 `session/list`、`session/page` 增量對齊；引擎與投影不一致時以引擎為準；starting/failed/absent 不阻塞投影。 |
| 不作為輸入 | 無 → 投影不得用於重建 VFS mutation、WAL record、journal 決策或 durable marker。 |
| outbox 檔案 | 內存陣列 → `send-outbox/<rpcId>.json`，每筆一檔；temp + fsync + rename + dir fsync，先落盤再投遞。 |
| `rpcId` | 無 → 入隊時生成的 lowercase UUIDv4，終身不變；是 user_message 的 `source.rpcId`，權威端用它去重。 |
| 狀態機 | 無 → `queued → submitting → accepted → durable`，加 `submitting → outcomeUnknown`；只允許 `outcomeUnknown → accepted`（回讀找到）與 `outcomeUnknown → queued`（回讀證明不存在）。`durable` 之後刪檔。 |
| 刪除條件 | 無 → 僅當權威歷史出現同 `rpcId` 的 user_message 且 entry 為 `durable`；本地 accepted 不夠；`outcomeUnknown` 未解決不刪。 |
| outcomeUnknown | 無 → 傳輸中斷後不自動重送；先回讀權威歷史，找到 → accepted/durable，可證明不存在 → 同 `rpcId` 回 queued，回讀不可用 → 停留並停止重送。 |
| 排序與崩潰點 | 無 → 同 session 按 `createdAtMs` FIFO；session 間獨立；五個 kill 點（落盤前、落盤後未投遞、投遞中、accepted 未 durable、durable 未刪）不丟不重。啟動掃描 `send-outbox/` 續跑，不生成新 `rpcId`。 |
| 用戶可見 | 無 → 只新增既有的「排队中」投影；不再以「引擎还没启动」或「请先等待当前回合结束」拒絕查看／發送。這兩條文案的移除由 W1 實作端完成，但契約只登記 outbox 狀態與投影邊界。 |
| unknown field／version | outbox 是新增 host 私有格式 `v:1`；舊 App 沒有這個目錄，忽略即可。無 enum／錯誤碼新增。 |

自檢（baseline §5.1）：投影不是第二份會話權威，而是 §6 materialized 副本的視圖；outbox 沒有第二個 envelope、沒有第二個 idempotency key（就是 `source.rpcId`）；沒有刪除或改名任何既有 member；沒有放寬 materialized 的寫入禁令。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；測試 |
| --- | --- |
| old → new | 舊 App 不讀投影、不寫 `send-outbox/`；新 App 讀舊 `materialized/` 與舊 UserDefaults 不受影響。舊 App 沒有 outbox 時，新 App 也不會假造一筆。 |
| new → old | 新 App 產生的 materialized 檔案仍是同一 v1 會話 JSONL；舊 App 照舊讀。`send-outbox/` 是舊 App 不認得的新目錄：舊 App 忽略它，不刪、不動；回滾後新 App 的排隊訊息不會由舊 App 投遞，但檔案仍在，重新升級可續跑。 |
| new → new | 兩端都遵守同一 `rpcId` 與 state machine；權威端以 `source.rpcId` 去重，崩潰後重播同一個 `rpcId` 不會重複。 |
| persisted old data → new／rollback | materialized 沒有 migration，仍是 §6 格式。outbox 是新資料：升級時目錄不存在即空；回滾不刪除它，但舊 App 不投遞。不得把內存 `queuedPromptsDuringRecovery` 遷移成 outbox 而不經使用者可見的 queued 狀態（本輪不遷移，舊陣列清空）。 |

- **版本決定**：無 proto／wire 版本變更；`proto 1`、P06 event、P18 既有鍵、materialized v1 不變。outbox 是 host 私有 `v:1`，不是 P01 frame。
- **部署順序**：App 與 Worker 可獨立更新；投影與 outbox 只在 App 端，Worker 不需要知道。PC 工作區（`pcRuntime != nil`）行為不變。
- **仍保留的差異**：Kotlin/Android 沒有這個 outbox 與投影讀取器，本輪 `not started`；不得用 Swift 測試宣稱 Kotlin 已實作。

## 4. 分工與證據

- **獨占路徑**：`spec/v1/wal.md` §11、`spec/host/v1/{README.md,schema/outbox-entry.schema.json,golden/outbox-entry-*.json,tools/outbox_invalid_cases.json,tools/test_outbox_contract.py}`、`docs/protocol-changes/PC-20261112-w1-browse-outbox.md`。
- **w1-browse 路徑**：`examples/probe-app/PhoneDSHProbe/{ChatModel,ChatPage,ChatEngineStoppedNoticePolicy,HomeDrawer,HomeDrawerNewSessionPolicy,HomeDrawerSwitchPolicy,SessionsPage,DSHManagementModel}.swift`、`examples/probe-app/ProbeKit/{Transcript,Outbox,Lifecycle}`、`examples/probe-app/PhoneDSHSimTests`。不得改 `Sources/` 或 `spec/`。
- **共享 fixtures**：outbox 正向 6 筆（2 text、1 個 attachment、2 個 attachments、1 個 attachment-only、1 個 20 attachments）、負向 18 筆（10 schema、5 transition、3 attachment law：duplicate id／missing store／digest mismatch）；`test_outbox_contract.py` 同時驗 schema、狀態機與 attachment reference 法律。
- **Exact commands → result**（Linux 容器）：
  - `python3 spec/host/v1/tools/host_check.py --root .` → PASS（49 files，0 error）。
  - `python3 -m unittest spec.host.v1.tools.test_outbox_contract` → PASS（5 tests）。
  - `python3 spec/v1/tools/spec_golden.py --full` → PASS（103 files，0 error）。
  - `swift test --filter PhoneDSHSimTests` → NOT_RUN（Linux 沒有 Xcode/Swift Apple 工具鏈；由呼叫方在本機執行）。
- **未執行**：iOS 真機的 0.5 秒切換、10 連切、5 崩潰點實測；XCTest、xcodebuild、XCUITest 一律 NOT_RUN。
- **風險／GAP**：投影的新鮮度只到「最多一個 epoch 落後」，進行中回合的顯示仍可能落後；W1 驗收需真機證明。outbox 的 `outcomeUnknown` 回讀來源必須是與 `durable` 判定相同的權威歷史，不得用本地快取冒充。

## 5. Rev 2 — attachment scope amendment, 2026-11-12（已被 Rev 3 取代）

Status: **superseded by Rev 3**. Trigger: `w1-browse` 的 CONTRACT CHANGE REQUEST（lead 已接受）。
Scope: 只改契約文字與一個負向 fixture；不改實作、不改 schema、不改狀態機／`rpcId` 語義、不新增用戶可見字串。Rev 2 的「text-only」限制由 Rev 3 的 owner override 撤銷；以下保留為歷史。

### 5.1 Trigger → 現況 → 期望

- **Trigger.** `host/v1/README.md` §10 說「每次 send 建一筆 durable outbox entry」，但 `outbox-entry.schema.json` 沒有 attachment member（`additionalProperties: false`），只有 text 語義；App composer 可以送 `HarnessAttachment[]`。
- **現況.** 文字 prompt 走 durable outbox；attachment send 沒有符合 schema 的持久表示，因此保留 pre-W1 的直接路徑，**不是 crash-durable**。`w1-browse` 沒有發明欄位、別名或平台分支。
- **期望.** 本輪把 §10 的 durable 要求明確限定在 **text prompts**；attachment send 留在 pre-W1 直接路徑並在契約中如實標為 non-crash-durable；attachment 的持久表示另立邊界與 GAP-40，不在本輪擴 schema。

### 5.2 CCR 原文（w1-browse → lead/all，已接受）

```text
CONTRACT CHANGE REQUEST (W1, P06 @ e654fe99 / host/v1 README §10)
Problem: §10 says every send creates one durable outbox entry, but spec/host/v1/schema/outbox-entry.schema.json has no attachment member (additionalProperties:false) and text-only semantics. The App composer can send HarnessAttachment[]; there is no conforming way to persist them, so attachment sends cannot use the durable queue.
Current implementation: text sends use the outbox; attachment sends keep the pre-W1 direct path and are not crash-durable. No schema/field was invented.
Proposal: either register attachment references in the entry schema (e.g. attachment metadata/blob refs) with a compatibility rule, or state in §10 that the durable outbox covers text prompts only and attachment sends are out of scope for W1. Affects: App Swift + Kotlin/P06 consumers + schema/golden.
w1-browse head 5ea9e987; this is the only known W1 contract gap.
```

### 5.3 決定

1. **本輪 durable outbox 只覆蓋 text prompts。** 文字訊息仍走 `queued → submitting → accepted → durable` + `outcomeUnknown`，`rpcId` 與刪除條件完全不變。
2. **Attachment sends 保留 pre-W1 直接路徑，且本輪不是 crash-durable。** 這是明示限制，不是靜默降級；不得把它描述成 durable outbox 的一部分。
3. **不擴 schema。** 不新增 attachment field、alias、fallback、blob ref、平台分支或第二種 entry；`additionalProperties: false` 不動。
4. **GAP-40 已登記**（`spec/README.md` §7）：缺少 attachment 在本邊界的持久表示；關閉需要新的 attachment/blob reference 邊界、schema/golden、P06 consumer、Kotlin 端與兼容矩陣。
5. **用戶可見變化：無。** 不新增、不改寫任何提示、限制、文案或禁用態；attachment send 的行為與 pre-W1 相同。

### 5.4 為何擴 schema 不在本輪（out of scope）

把 attachment 放進 outbox entry 不是加一個陣列欄位就結束，而是建立一個新的持久化邊界：

- **attachment/blob reference 語義**：引用什麼（路徑、內容哈希、大小、MIME）、檔案被使用者刪除或覆蓋時 entry 還是否有效、是否要複製 bytes、清理／erasure 責任；
- **P06 consumer**：Kotlin/Android 目前沒有這個 outbox；一個新的 entry shape 需要 consumer 實作與兼容策略，不能只改 Swift producer；
- **崩潰與冪等**：attachment 與 text 的投遞是否同一個 `rpcId`、部分 attachment 遺失時可否重送、authority 如何確認；
- **兼容矩陣**：舊 App 沒有 attachment entry、新 App 寫入後舊 App 回滾要能忽略還是拒絕；base 從來沒有 attachment durability，不能假裝有 migration；
- **schema/golden**：需要新的有效／無效 fixtures 與兩端真實 decoder，不能只放寬 `additionalProperties`。

因此本輪採最小 delta：narrow §10，不擴 schema；attachment 的持久化由 GAP-40 單獨追蹤。

### 5.5 兼容性

| Producer → Consumer | 支援／拒絕方式及理由 |
| --- | --- |
| old → new | 舊版的 attachment send 本來就走直接路徑、不是 crash-durable；新契約把事實寫明，不改變舊版行為。文字 outbox 不變。 |
| new → old | 沒有新增 wire member、schema、環境變數或持久化欄位；舊版看不到 attachment outbox entry（因為新版本輪不產生），文字 entry 照舊。 |
| new → new | 兩端都只把 text prompt 當 durable outbox；attachment send 兩端都走 pre-W1 直接路徑，不得一端自行加 attachment entry 並要求另一端。 |
| persisted old data → new／rollback | 不適用：沒有 attachment entry、沒有格式或 migration。回滾只需忽略本註記；文字 outbox 的既有 entry 不受影響。 |

**版本決定**：無版本變更。`host/v1/README.md` §10 只新增 scope／limitation 段落；`outbox_invalid_cases.json` 只加一個 schema 負例；`spec/README.md` 只加 GAP-40。沒有新 field、沒有放寬 schema、沒有刪除或弱化既有條款。

## 6. Rev 3 — attachment durability (owner override), 2026-11-12（`maxItems: 8` 與 text `minLength: 1` 已被 Rev 4 取代；store/lifecycle/crash 規則不變）

Status: **frozen**（rev 3）。Trigger: **owner override（sequence 40830）**，明確撤銷 Rev 2 的
「text prompts only」裁定。Scope: 把 attachment send 接入同一個 durable outbox；這是
**owner 授權的明確 scope expansion**，不是靜默 widening。只改契約、schema、golden 與文檔，不改實作。

### 6.1 Trigger → 現況 → 期望

- **Trigger.** Rev 2 把 §10 的 durable 要求限定在 text prompts；owner 現在要求 attachment send 也必須 crash-durable。先前的 text-only 裁定作廢。
- **現況.** 文字 prompt 走 durable outbox；attachment send 保留 pre-W1 直接路徑、不是 crash-durable。`outbox-entry.schema.json` 沒有 attachment member，`additionalProperties: false`。
- **期望.** 文字與 attachment **共用同一個 outbox、同一個狀態機、同一個 `rpcId`、同一個刪除條件**。Entry 只帶 attachment references + minimal metadata，bytes 存在 outbox 自己的 durable store；附件 bytes 在 entry 提交前已落盤並驗證 digest。沒有 inline bytes、沒有第二個 queue、沒有平台分支。

### 6.2 Schema delta（host 私有 `v1`，additive optional）

`spec/host/v1/schema/outbox-entry.schema.json` 新增可選 `attachments`（`additionalProperties: false`
保持）：

| 欄位 | 形狀 | 語義 |
| --- | --- | --- |
| `attachments` | array，至多 8，optional | 缺席 = text-only entry；舊 entry 因此仍合法。 |
| `attachments[].id` | `^[A-Za-z0-9._-]{1,64}$` | entry 內唯一的 attachment id；不接受重複。 |
| `attachments[].kind` | `image|file|audio|video|document` | 封閉枚舉；未知 kind fail-closed。 |
| `attachments[].byteSize` | integer ≥ 0 | bytes 長度，用於 dispatch 前與檔案大小比對。 |
| `attachments[].sha256` | 64 lowercase hex | bytes 的 SHA-256；dispatch 前重算比對。 |
| `attachments[].contentType` | 1–200 chars | MIME；不作為信任邊界。 |
| `attachments[].filename` | 1–255 chars | 顯示用名稱，不是 store path。 |
| `attachments[].storePath` | `^attachments/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,64}$` | 相對 `send-outbox/` 的引用；第一段是 `rpcId`，第二段是 attachment id。 |

沒有 `dataBase64`、`data`、`bytes` 或任何 inline bytes 成員；`additionalProperties: false` 會拒絕它們。

### 6.3 Store 位置與生命週期

- **Root.** Entry 是 `send-outbox/<rpcId>.json`；attachment bytes 是
  `send-outbox/attachments/<rpcId>/<attachmentId>`，與 entry 在**同一個 durable app-container tree**。
  不在 `Library/Caches`、不在 Worker-volatile `/dsh/tmp`、不在 `/dsh/workspace`。
- **Durability.** 先寫 attachment 檔案、fsync、驗證 `sha256` 與 `byteSize`，再以 §7 原子順序提交
  entry。至少 level-1：進程被殺不丟；只有裝置容器被銷毀或使用者刪除才會失去 bytes。
- **Reference.** `storePath` 必須正好是 `attachments/<entry.rpcId>/<attachment.id>`；不接受絕對路徑、
  `..`、第二個 root 或跨 entry 共享。每個 entry 擁有自己的 attachment 目錄，避免 refcount 與
  「刪了別的 entry 還在用的 blob」。
- **Deletion.** 只有 entry 依刪除條件被刪除後，才 unlink 它的 `attachments/<rpcId>/`。Entry 存在時
  永不刪 attachment；entry 不存在時啟動 GC 可移除孤兒目錄（entry 刪除後 crash、或 entry 寫入前
  crash 留下的部分檔案）。GC 不得反向刪 entry。
- **No orphans.** 沒有 entry 的 attachment 目錄是孤兒，啟動時移除；有 entry 的 attachment 檔案
  缺失則是 §6.4 的 consistency failure，不是 GC 對象。

### 6.4 崩潰／一致性規則（dispatch 時 bytes 缺失或 digest 不符）

- 在第一次 submit 前、以及任何 retry 前，逐一驗證每個 `storePath` 存在、`byteSize` 相符、
  `sha256` 相符。
- 缺失或 digest 不符時：**不得提交**該 entry、**不得**退回 text-only send、**不得**刪除或重建 entry。
  Entry 維持目前狀態（`queued`；若之前 submit 已進入 `outcomeUnknown`，維持 `outcomeUnknown`），
  內部 `lastError` 記 `attachment_missing` 或 `attachment_digest_mismatch`。只有在檔案恢復並重新驗證後
  才可再 dispatch。
- 之前已 submit 的 entry 不得用新 `rpcId` 重送；若權威歷史已有該 `source.rpcId`，照正常
  `accepted → durable` 路徑。不得用 text-only 版本冒充已送出。
- **用戶可見：** 不新增任何 prompt、banner、錯誤或禁用態；唯一允許的可見狀態是既有的「排队中」。
  內部診斷只進 `lastError`／run log，不是用戶文案。

### 6.5 兼容性（四格）

| Producer → Consumer | 支援／拒絕方式及理由 |
| --- | --- |
| old → new | 舊 entry 沒有 `attachments`，member 可選，仍合法可讀；新端把它當 text-only。無 migration。 |
| new → old | 帶 `attachments` 的新 entry 會被舊 consumer 的 closed schema 拒絕（`additionalProperties: false`）。這是**同容器 App-only 邊界**：App 與其 outbox consumer 同 bundle 發布，混合版本不是支援的 runtime pair。舊 consumer 在回滾時 MUST NOT 刪除、改寫或文字化（text-only）降級它看不懂的 entry；留在 `send-outbox/`，等相容版本回來再投遞。 |
| new → new | 文字與 attachment 同一個 queue／state machine／`rpcId`／刪除條件；attachment 先落盤驗證再提交 entry；dispatch 前重驗 digest。 |
| persisted old data → new／rollback | 無 migration：舊 entry 照讀（text-only），舊 attachment 不存在（base 沒有 attachment durability）。回滾到舊版時，text entry 照舊；帶 attachment 的排隊 entry 不被刪除或降級，重新升級後投遞。回滾不需要、也不得重建已刪除的 attachment。 |

**版本決定**：host 私有 outbox entry 由 `v:1` 加 optional member，無 proto bump；舊 entry 仍合法。舊 consumer 拒絕新 entry 是可接受的同容器 App-only 邊界，代價是回滾期間 attachment queue 暫停，不是資料遺失。`breaking: false`（additive optional；舊資料可讀），但兼容矩陣明示 old consumer 的拒絕行為。

### 6.6 實作歸屬與驗收

- **Contract/spec（本單元）**：`spec/host/v1/{README.md,schema/outbox-entry.schema.json,golden/outbox-entry-*.json,tools/outbox_invalid_cases.json,tools/test_outbox_contract.py}`、`spec/README.md` GAP-40、本變更單。
- **w1-browse（實作）**：`examples/probe-app/ProbeKit/Outbox/**`（store layout、atomic write、GC、digest 驗證）、`ChatModel.swift`／`ChatPage.swift` 的 composer 接線、`PhoneDSHSimTests`。不得改 `Sources/` 或 `spec/`。
- **P06 consumer（另一單元）**：Kotlin/Android 的 outbox consumer 必須照同一 schema 實作，否則 `not started`；不得只改 Swift producer。
- **共享 fixtures**：正向 `outbox-entry-attachment.json`（1 個）、`outbox-entry-attachments-multiple.json`（2 個）；負向 inline bytes、未知 kind、缺 storePath、legacy shape、duplicate id、missing store file、digest mismatch；transition cases 不變。
- **驗收命令**：`python3 spec/host/v1/tools/host_check.py --root .`、`python3 -m unittest spec.host.v1.tools.test_outbox_contract`、`python3 spec/v1/tools/spec_golden.py --full`，以及 Linux 可跑的 spec gates。Swift/XCTest 與真機 crash/digest 測試在本環境 NOT_RUN。

## 7. Rev 4 — attachment-only sends and attachment-count bound, 2026-11-12

Status: **frozen**（rev 4）。Trigger: `w1-browse-attachments` 的 CONTRACT CHANGE REQUEST（lead 已接受）。
Scope: 只放寬兩個 composer 邊界（empty text 條件、attachment 上限），不改 Rev 3 的 store／lifecycle／crash 規則。這是 additive contract amendment，不是 schema 放寬到無界。

### 7.1 Trigger → 現況 → 期望

- **Trigger.** `ChatPage.canSubmit` 已允許 image-only send（空 draft、pending attachment 非空），`ChatModel.send` 已允許 attachments 存在時空 prompt；Rev 3 的 `text` 仍是 `minLength: 1`，image-only 訊息沒有合法 entry。Rev 3 的 `attachments` 上限是 8，但 host 已暴露 `imageLimits.maxImagesPerMessage`（`NativeImageLimits.fallback = 20`），9–20 張的 send 沒有合法 entry。
- **現況.** 若不放寬，App 只能新增「請輸入文字」或「最多 8 張」的 user-visible refusal，或偽造 caption；兩者都違反 plan §1.2 的「不新增限制／提示」與「不偽造」原則。
- **期望.** `text` 可以 `""` **當且僅當** `attachments` 非空；text-only entry 仍必須 `minLength: 1`。`attachments` 上限改為 20，鏡像 host 宣告的 `maxImagesPerMessage` fallback；App 不得超過 host 宣告值，也不得靜默丟棄附件。沒有第二種 entry kind、沒有 synthetic caption、沒有新提示。

### 7.2 CCR 原文（w1-browse-attachments → lead/all，已接受）

```text
CONTRACT CHANGE REQUEST (w1-browse-attachments, P06 @ rev3 / outbox-entry.schema.json)

1) text minLength 1 vs attachment-only send. ChatPage.canSubmit allows idle image-only sends (empty draft, pendingAttachments non-empty) and ChatModel.send permits empty prompt when attachments exist. Rev3 schema still requires text 1..1000000, so an image-only send has no valid entry and cannot go through the one durable outbox without either a new limit/refusal or a synthesized text value. Proposal: allow text:"" iff attachments is non-empty (schema: text minLength 0 + conditional/description), or state that every durable attachment entry must carry a non-empty caption and accept the UI limitation. No implementation has invented a field.

2) attachments maxItems 8 vs host imageLimits.maxImagesPerMessage default 20 (NativeImageLimits.fallback 20; ChatModel imageLimits reads host projection, fallback 20). Rev3 §6.2 says at most 8, so a 9-20 image send has no valid entry and would need a new refusal. Proposal: raise maxItems to the host-declared limit (20) or state that >8 sends stay out of the durable outbox; the App cannot widen the schema itself.

3) Note: my declared checkout is base d988108c1 + w1-browse 5ea9e987 only; contracts rev3 (2e1f63e4) is not fetched, so spec/host/v1/schema/outbox-entry.schema.json is still the rev1 text-only file in my tree. I am implementing against the published PC-20261112-w1-browse-outbox@3 text and will not edit spec/. If the unit is expected to run schema checks against rev3, please make that commit available or tell me the assembly plan.

I am proceeding with the store/GC/digest/deletion work that is unambiguous; these two composer edge cases are stopped until decided.
```

第 3 點是單元的 checkout 事實，不是契約 delta；本 rev 4 只回應第 1、2 點。實作端必須 fetch 本 freeze commit 後再跑 schema 檢查，不得用舊的 text-only schema 冒充 rev 4。

### 7.3 決定

1. **Empty text 條件。** `text` MAY be `""` iff `attachments` non-empty；text-only entry MUST keep `minLength: 1`。以 root `oneOf` 的兩個 closed variants 表達（見 §7.4），不新增第二種 entry、不新增 synthetic caption、不新增 UI 文案。
2. **Attachment count。** `attachments` `maxItems` 由 8 改為 **20**，鏡像 host `imageLimits.maxImagesPerMessage` 的 fallback 20。若 host 宣告更低的上限，App 以 host 值為準；App 不得超過 host 宣告值，也不得靜默丟棄超出的附件。21 個附件是 invalid entry，不是新的 UI refusal path。
3. **為什麼不是 refusal。** Plan §1.2 明確禁止用新增限制／提示換效能；image-only 已經是合法 composer 狀態，加「請輸入文字」或「最多 8 張」會直接違反 plan。Synthetic caption 則是偽造用戶內容，同樣禁止。
4. **Rev 3 其餘不變。** Store 位置、entry/bytes 落盤順序、lifecycle、orphan GC、dispatch 前 digest 驗證、缺檔／digest 不符的 no-submit/no-text-only/no-new-rpcId/no-prompt 規則全部保持；只取代 Rev 3 §6.2 的 `maxItems: 8` 與 text `minLength: 1` 兩個限制。
5. **GAP-40 不關閉。** 跨裝置同步、at-rest 抹除、cross-entry dedupe/refcount、store 配額/清理、Kotlin/P06 consumer、回滾處理仍不在本 amendment。

### 7.4 Schema excerpt（implementation target）

```json
"oneOf": [
  {
    "type": "object",
    "required": ["v", "rpcId", "sessionId", "text", "createdAtMs", "state", "attempts"],
    "properties": {
      "text": {"type": "string", "minLength": 1, "maxLength": 1000000},
      "attachments": {"type": "array", "maxItems": 20, "items": {"...": "..."}}
    },
    "additionalProperties": false
  },
  {
    "type": "object",
    "required": ["v", "rpcId", "sessionId", "text", "createdAtMs", "state", "attempts", "attachments"],
    "properties": {
      "text": {"const": ""},
      "attachments": {"type": "array", "minItems": 1, "maxItems": 20, "items": {"...": "..."}}
    },
    "additionalProperties": false
  }
]
```

兩個 variants 都保留完整欄位集合與 `additionalProperties: false`；attachment item 的 required／pattern／enum 與 Rev 3 相同。Exact schema：`spec/host/v1/schema/outbox-entry.schema.json`。

### 7.5 兼容性（四格 impact）

| Producer → Consumer | 支援／拒絕方式及理由 |
| --- | --- |
| old → new | 舊 text-only entry（text 非空、無 attachments）仍匹配第一個 variant，可讀可投遞；沒有 migration。 |
| new → old | 文字 relaxation 對舊 consumer 沒有新 member；舊 consumer 仍會拒絕帶 `attachments` 的 entry（closed schema），同 Rev 3 的同容器 App-only 邊界。回滾不得刪除／改寫／text-only 降級 attachment entry。 |
| new → new | Empty text 只在 attachments 非空時合法；attachment-only 與 text-only 共用同一 queue／state machine／`rpcId`／刪除條件；上限 20 與 host 宣告一致。 |
| persisted old data → new／rollback | 沒有持久化資料改變語義：舊 entry 仍是 text-only；新 attachment entry 只是新增可選 member 的使用。回滾見 new → old；不得把空 text 的 entry 轉成新 caption。 |

**版本決定**：無 proto bump。`text` 的 relaxation 只對 new→new 有效；old consumer 本來就拒絕 attachment entry。`maxItems` 由 8→20 是 host-declared image limit 的鏡像；沒有無界放寬。`breaking: false`（舊資料可讀、member additive），但矩陣明示 old consumer 的拒絕與回滾限制。

## 8. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts | 初次凍結只讀投影與持久 outbox | all（contract freeze 公告） |
| 2（本檔） | contracts | 接受 w1-browse 的 CONTRACT CHANGE REQUEST：text-only scope；新增 GAP-40 | all（amendment 公告） |
| 3（本檔） | contracts | **owner override（sequence 40830）**：撤銷 text-only，attachment send 接入同一 durable outbox（optional `attachments`、outbox-owned store、crash/digest 規則、四格兼容矩陣）；GAP-40 改為跨端／抹除未覆蓋項 | all（amendment 公告） |
| 4（本檔） | contracts | 接受 w1-browse-attachments 的 CCR：`text:""` iff attachments 非空（oneOf），`attachments` 上限 8→20（鏡像 host `maxImagesPerMessage` fallback），不加 UI refusal／synthetic caption | all（amendment 公告） |
