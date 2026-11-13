<!-- SPDX-License-Identifier: MIT -->
# 決策紀錄：perf-stability 五項缺口——owner 裁決與凍結（2026-11-13）

Protocol impact: none — documentation only（本檔不改 `spec/`、`Sources/`、`Package.swift`、`scripts/`、`plugins/`、`.github/`；契約修訂與其 delta 在對應變更單）

Status: **ruled / frozen**。五項裁決由 owner 於 **2026-11-13** 授權並定案；由 contract owner（`contracts-1113` worktree，分支 `spec/perf-decisions-20261113`）凍結成契約修訂。未定案前的前置文件是 [perf-stability-open-gaps-20261112.md](perf-stability-open-gaps-20261112.md) 與五份 `DEC-*.md`；本檔只記錄「裁決了什麼、為什麼、誰批准、哪一項延後到什麼條件」，不重述提案的選項分析。

```
Base:        f6b447dfbc83f6e768a5c802184013d2c9b67e26（origin/main）
Worktree:    contracts-1113（spec/perf-decisions-20261113）
裁決者:      owner（計畫／產品），2026-11-13 授權
凍結者:      contracts-1113（本輪唯一 contract owner）
契約落點:    PC-20261113-gap39-host-footprint-memory、PC-20261113-w6-recovery-acceptance、
             PC-20261113-p12-model-purpose-sink、docs/upstream/2026-11-13-overlay-manifest-reader.md
```

---

## 1. 背景與本檔的範圍

`perf-stability-20261111` 工作包已合入 `main`（PR #139），留下 GAP-39／40／41／42，另有一項 bot-context 小模型衝突不在 GAP 表內。PR #143 的五份決策備忘把每一項的證據、選項、代價寫到「可直接拍板」。本檔是拍板後的紀錄：**裁決已定，不再重開方向**；每一項的契約修訂由對應變更單凍結，本檔只做交叉索引與延後條件的登記。

**本檔明確不做的事**：不改任何 GAP 的狀態（那是每個變更單與 `spec/README.md` §7 的責任）、不改 `spec/`、不改任何實作、不 push、不開 PR、不動其他 worktree。

---

## 2. 五項裁決一覽

| # | 項目 | 裁決（一句話） | 主要理由 | 契約落點 | 裁決後狀態 |
|---|---|---|---|---|---|
| R1 | **GAP-39** engine-memory 輸入 | 改成**宿主進程 `phys_footprint`（`task_info`／`TASK_VM_INFO`）＋記憶體壓力警告**；刪掉不可實作的 `performance.memory` 路徑；sampled engine heap **永久 `target`**，不得當成已實現 | WebContent 是獨立進程、宿主無公開 API，WebKit 也沒有 `performance.memory`（MDN／`browser-compat-data`：`memory.support.safari = false`，`measureUserAgentSpecificMemory` 同樣 `false`）。留著一條做不到的關閉路徑，下一個 agent 會照著做然後卡住 | [PC-20261113-gap39-host-footprint-memory](../protocol-changes/PC-20261113-gap39-host-footprint-memory.md)；[budgets.md](../../spec/v1/budgets.md) §3／§4；`memory-input.json`；GAP-39 | GAP-39 **open**（關閉路徑改為等 OS／runtime 讀數）；契約已改寫 |
| R2 | **GAP-41** W6 恢復驗收 | 改寫成兩段式：**無 mutation 的熱恢復 ≤ 1 秒（`target`）**；**有 mutation 時 = O(位元組)，只保證線性、不承諾常數**。§8.1 維持 `target`，另寫 upstream 需求 | overlay 由 pinned DSH `readImage` 讀取、本倉不得 patch；每次 watermark 變更仍整棵重打包，原句「與工作區大小無關」在現行 runtime 上**不可能達成**。與其留一句不可達的驗收，不如把可達的最強聲明寫死 | [PC-20261113-w6-recovery-acceptance](../protocol-changes/PC-20261113-w6-recovery-acceptance.md)；[wal.md](../../spec/v1/wal.md) §8.1；[docs/upstream/2026-11-13-overlay-manifest-reader.md](../upstream/2026-11-13-overlay-manifest-reader.md)；GAP-41 | GAP-41 **open**，由「不可達」改記「**已改寫驗收、待上游**」 |
| R3 | **GAP-42** model-purpose 執行點 | **不新增任何 wire 欄位／header**（`x-pdsh-model-purpose` 否決）；enforcer 純策略型別**下沉 `PhoneDSHAgentCore`**（P12 依賴圖變更，`Package.swift` 本輪不改）；凍結**分階段語義**：purpose 缺席 → 只記錄、行為與今天完全相同；purpose 存在 → 真的執行 allow/deny | 新標頭要四端同步、舊版要容忍，而 pinned 上游 adapter 不保留 purpose，加了也觀察不到；型別下沉不反轉依賴方向（`PhoneDSHGateway` 已依賴 `PhoneDSHAgentCore`），是唯一不製造第二個權威的走法 | [PC-20261113-p12-model-purpose-sink](../protocol-changes/PC-20261113-p12-model-purpose-sink.md)；[spec/bot/v1/README.md](../../spec/bot/v1/README.md) §2.10；GAP-42 | GAP-42 **open**（語義與依賴方向已凍結，執行點仍 `target`） |
| R4 | **GAP-40** pc backend outbox | **本輪不做契約變更**（延後，見 §4） | 新增「排队中」可見狀態超出計畫允許的兩處；closed schema 加 `backendRef` 對舊版是兼容斷崖；收益僅覆蓋 pc backend | 無（維持 GAP-40 現行登記；決策備忘 [DEC-40](DEC-20261112-gap40-pc-outbox-durability.md) 的方案保留為未採用） | GAP-40 **open**，內容不變（本輪零 delta） |
| R5 | **bot-context golden** | **不動 golden**（延後，見 §5） | 該欄位目前沒有 runtime 消費者；為一個沒有消費者的欄位動 byte-exact golden 是本末倒置。等 WP7 真的 materialize 目錄時，連同「有效值在 platform row」的條款一起改 | 無（golden／`spec/bot/v1/context-profiles*` 不動） | 非 GAP；維持現狀（小模型壓縮本輪未生效，已登記） |

---

## 3. 各項裁決的理由與落地

### R1 — 把 engine-memory 換成可量測的量

- **裁決內容。** `budgets.md` §3／§4 要求的記憶體輸入改為**宿主進程 `phys_footprint`**（`task_info`／`TASK_VM_INFO`）＋**記憶體壓力警告**（`DispatchSource.makeMemoryPressureSource`／`didReceiveMemoryWarning`）；footprint **只記一次、記在 §4 `App process` 列**，不與 Engine heap 列相加（避免重複計帳與錯的門檻語義）。sampled engine heap **永久留在 `target`**；`performance.memory` 關閉路徑刪除。**動作順序 `clearTmp → plannedRestart` 與所有既有數字不變。**
- **為什麼不是「補一個 producer」。** WebContent 進程記憶體不可觀測：WKWebView 把 WebContent 跑在獨立進程，宿主沒有公開 API；WebKit 沒有 `performance.memory`，替代的 `measureUserAgentSpecificMemory` 在 Safari 也不支援。就算今天寫出 `PhoneDSHEngine` 的公開 probe，也只能回 nil 或一個不是 WebContent 的數字。
- **落地。** §3 的 input-source 段落、§3 signal 表的 memory proxy 列、§4 的 memory-proxy bullet 改寫；`memory-input.json` 由 2 valid／6 invalid 改成 2 valid／12 invalid（新增「舊單一輸入集合不足」「只給 footprint」「footprint 記到 engine-heap-row／相加」「來源不是 `task_info/TASK_VM_INFO`」「缺 footprint 帳」等負例）；`plan_cases_check.py` 的 law 同步。GAP-39 的關閉路徑改為「等 Apple／upstream 提供可觀測的 WebContent 讀數」。
- **不是什麼。** 不是「engine heap 預算已生效」；不是「sampled heap 已接線」；不是放寬任何數字。

### R2 — 把不可達的驗收改成可達的兩段式

- **裁決內容。** "hot recovery ≤ 1 s, independent of workspace size" **撤回**。新的 §8.1 acceptance：(1) watermark 未變（無 mutation）的 boot MUST ≤ 1 秒、`target`（今日 O(1) hard link）；(2) 任何 mutation 後的 boot 是 **O(bytes)**、只保證線性、**不承諾**與大小無關。唯一的數字恢復預算仍是 `budgets.md` §4 的 `a + k·MB`（`a ≤ 3 s`、`k ≤ 0.05 s/MB`），它是 `target` bound，不是量測。
- **為什麼不是「等上游就好」。** 沒有 upstream 的 manifest reader／tombstone，原句永遠不成立；而留著它，下一個里程碑只能造假或卡死。可達的最強聲明必須先寫進契約，upstream 需求才有驗收對象。
- **落地。** `wal.md` §8.1 新增 Recovery acceptance 段；§8.1 維持 `target`；GAP-41 由「不可達」改記「已改寫驗收、待上游」；新增 [upstream 需求文件](../upstream/2026-11-13-overlay-manifest-reader.md)（C1 manifest reader、C2 blob 按需取、C3 tombstone、C4 能力字串、C5 缺 blob／digest 不符 fail loud），並明確拒絕「先送清單」與「分層 ustar 假裝是解法」（tar 表達不了刪除）。
- **不是什麼。** 不是「W6 已完成」；不是「≤ 1 秒已量到」（真機 NOT_MEASURED）；不是把 `§8.1` 改 `implemented`。

### R3 — 不加載體，改下沉型別並凍結分段語義

- **裁決內容。** (a) **不新增任何 wire 欄位／header**（`x-pdsh-model-purpose` 之類被否決）。(b) enforcer 的純策略型別（`BotModelPurpose`／`BotModelPurposePolicy`／`BotModelRequest`／`BotModelPurposeGate`／`BotModelPurposeError` 等）**下沉到 `PhoneDSHAgentCore`**；`PhoneDSHGateway` 與 `PhoneDSHBot` 都已依賴該模組（`Package.swift:53`／`:74`），所以這是**不反轉依賴方向**的 P12 變更；`PhoneDSHBot` 保留對外名稱，不得出現兩個型別名。**本輪不改 `Package.swift`**（實作單做）。(c) **分階段執行語義**：purpose **缺席** → 只記錄一筆 `purpose_absent` 診斷、行為與今天完全相同（不 fail-closed、不放行新權限）；purpose **存在** → 真的呼叫 enforcer，allow／deny 生效。
- **為什麼否決新標頭。** 要四端同步、舊版要容忍未知標頭，而 pinned 上游 adapter 不保留 purpose，加了也觀察不到值——那只是一個無法被填充的新欄位（第二種空表達，AGENTS.md §2.1）。**為什麼型別下沉而不是 Gateway→Bot**：把整個 Bot 模組拉進 gateway 的建置圖是依賴反轉，卻沒有多解任何一個前提。
- **落地。** [spec/bot/v1/README.md](../../spec/bot/v1/README.md) §2.10 改寫成「載體否決＋型別歸屬＋兩分支」；GAP-42 改記三項凍結與仍缺的 purpose 來源；`model-purpose-enforcement.phone.json` **不改**（缺席向量等執行點接線時才加）。P05 的 wire 條款、P17 的 `HTTPEgressRequest` 均無 delta。
- **不是什麼。** 不是「purpose 策略已生效」；不是「GAP-42 可關」；不是 `Package.swift` 已改。

### R4 — GAP-40（pc backend outbox）：本輪不做契約變更

- **裁決。** 維持 GAP-40 現行登記與 Rev 5 行為（pc 走 direct path、非 crash-durable）；**不新增「排队中」可見狀態、不在 closed schema 加 `backendRef`**。理由三條：
  1. **超出計畫允許的可見面。** 新增「排队中」是第三處使用者可見狀態，計畫本輪只允許兩處；多一個狀態要多一組 UI、文案與跨端 golden。
  2. **兼容斷崖。** outbox entry schema 是 closed 的（`additionalProperties: false`）；新增 `backendRef` 對舊 consumer 不是「忽略未知欄位」而是拒收或降級，回滾路徑得另外設計。
  3. **收益只覆蓋 pc backend。** 手機 backend 已有 authoritative-history 等價物；為單一 backend 付全矩陣（schema／golden／Swift producer／Kotlin consumer／崩潰矩陣）的成本不划算。
- **延後不是關閉。** GAP-40 保持 open，內容不變；[DEC-40](DEC-20261112-gap40-pc-outbox-durability.md) 的方案（`backendRef` additive、pc enqueue、離線停在 `outcomeUnknown`）保留為未採用，重開時從該文件起步，不需要重新蒐證。

### R5 — bot-context golden：不動 golden

- **裁決。** 維持 bot profile 目錄的 `""`／`""` 與 byte-exact golden；**不改 golden、不改 Swift frozen、不改 schema**。
- **理由。** 該欄位目前**沒有任何 runtime 消費者**；為一個不生效的欄位動 golden（並改契約面）只有成本。有效值已經在 `phone.worker` 的 platform row（`deepseek-official`／`deepseek-flash`），目錄是 upstream 鏡像，不是第二個權威；這個「哪一個是權威」的說明**等 WP7 真的 materialize 目錄時**，連同 `valid.yaml.*` 的 overlay 條款一起改。
- **延後不是關閉。** 「Bot profile 的小模型壓縮本輪未生效」已如實登記；WP7 落地前若有人要動目錄，必須先回到本節。

---

## 4. R4 的延後條件（可重開的判準）

GAP-40 要重開並做契約變更，必須同時滿足：

1. **可見面先取得授權**：owner 明確允許第三處使用者可見的「排队中」狀態（或選一個不新增可見狀態的等價表達）。
2. **兼容方案先寫好**：closed schema 的 `backendRef` 要嘛走新 schema rev 並證明舊 consumer 的拒絕方式與回滾路徑，要嘛先讓 outbox schema 對該欄位開放未知成員（後者本身就是契約變更）。
3. **pc 的權威歷史讀回**在**離線**情況下有明確語義（今天只有 online 的 `session/page` 讀回），且 crash 矩陣（kill／掉電／重送）有測試，不是設計。

三項缺一，維持現狀。

---

## 5. R5 的延後條件（可重開的判準）

bot-context golden 要重開，必須同時滿足：

1. **WP7 真的 materialize 目錄**：`BotContextProfile*` 出現 runtime 消費者（今天沒有），否則動 golden 沒有行為依據。
2. **同一變更內**寫入「有效值在 platform row、目錄是 upstream 鏡像」的條款，並用 `context-profiles.phone.json` 的 overlay 表達差異（additive，不動 upstream 檔）。
3. **byte-exact 測試與匯出器**（`spec/tools/bot/export-vectors.mjs`）同步更新，golden 仍由 pinned dsh-bot 匯出後 overlay。

三項缺一，維持 `""`／`""`。

---

## 6. 裁決後的 GAP 狀態

| GAP | 裁決前 | 裁決後 | 追蹤 |
|---|---|---|---|
| GAP-39／P03、P04 | open：sampled heap 缺 producer；關閉路徑要求 `performance.memory` | **open**：契約已改寫（宿主 footprint＋壓力警告），sampled heap 永久 `target`，關閉路徑改為等 OS／runtime 讀數 | `spec/README.md` §7 GAP-39；PC-20261113-gap39 |
| GAP-40／P06 | open：pc 不在 durable outbox、跨端 attachment／抹除邊界 | **open，內容不變**（R4 延後，條件見 §4） | `spec/README.md` §7 GAP-40；DEC-40 |
| GAP-41／P02、P20 | open：W6 驗收不可達 | **open，已改寫驗收、待上游**（R2） | `spec/README.md` §7 GAP-41；PC-20261113-w6；upstream 需求文件 |
| GAP-42／P05、P12、P26 | open：執行點未接線、三個前提缺 | **open**：載體否決、型別歸屬與分階段語義已凍結（R3）；仍缺 purpose 來源 | `spec/README.md` §7 GAP-42；PC-20261113-p12 |
| bot-context（非 GAP） | 同一設定兩個權威的風險 | 維持現狀（R5 延後，條件見 §5） | 本檔 §5；DEC-BC |

**沒有任何 GAP 被關閉，也沒有任何 GAP 列被刪除。**

---

## 7. 本輪實際改了什麼（交叉索引）

| 路徑 | 變更 | 由哪一項 |
|---|---|---|
| `spec/v1/budgets.md` §3／§4 | engine-memory 輸入、footprint 計帳位置、sampled heap 永久 target；數字與動作順序不變（320 行，仍在上限內） | R1 |
| `spec/v1/golden/plan/memory-input.json` | 2 valid／6 invalid → 2 valid／12 invalid | R1 |
| `spec/v1/tools/{plan_cases_check,test_plan_cases_check}.py` | law 改成 footprint＋warning，新增 3 個 mutation tests | R1 |
| `spec/v1/schema/plan-cases.schema.json` | description 記錄 R1（結構不動） | R1 |
| `spec/v1/wal.md` §8.1 | Recovery acceptance 兩段式（735 行，仍在 736 上限內） | R2 |
| `docs/upstream/2026-11-13-overlay-manifest-reader.md` | 新增 upstream 需求（C1–C5） | R2 |
| `spec/bot/v1/README.md` §2.10 | 載體否決、型別歸屬、分階段語義 | R3 |
| `spec/README.md` §7 GAP-39／41／42 | 三列改寫（不刪列、不關 GAP；GAP-40 不動） | R1／R2／R3 |
| `docs/protocol-changes/PC-20261113-*.md` | 三張凍結變更單 | R1／R2／R3 |
| `docs/decisions/perf-stability-decisions-ruled-20261113.md` | 本檔 | R1–R5 |

**沒有**改：`Sources/`、`Package.swift`、`scripts/`、`plugins/`、`.github/`、`spec/v1/README.md`、bot-context golden、任何 wire schema 或持久化格式。

---

## 8. 驗證（本檔自身）

本檔只新增 `docs/decisions/` 下的 Markdown；契約修訂的驗證在各自變更單記錄。本輪實跑：

```
bash scripts/ci/check.sh --only phone-cross-tree     → 見交付回報（PASS/FAIL 原樣）
bash scripts/ci/check.sh --only phone-spec           → 見交付回報（PASS/FAIL/NOT_RUN 原樣）
wc -l spec/v1/budgets.md                             → 320（≤ 320）
python3 scripts/ci/protocol_impact.py --base main --body-file <宣告>  → 見交付回報
git status --short                                   → 見交付回報
```

`phone-spec` 是權威；若因環境無法完成，記 `NOT_RUN` 並貼真實錯誤，**不得寫成 PASS**。

---

## 9. 未量測／NOT_VERIFIED（本輪沒有能力量測的，不假裝）

| 項目 | 狀態 | 影響 |
|---|---|---|
| WebContent 進程的真實記憶體讀數 | **未量測**（本倉無 producer；WKWebView 無公開 API） | R1 只能給宿主 footprint 代理；任何「sampled heap 已接線」的說法都不成立 |
| 宿主 `phys_footprint` 與 jetsam 的相關性 | **未量測**（`examples/probe-app/ProbeKit/ProcessMetrics.swift` 自述 NOT_VERIFIED） | R1 的代理不能宣稱能預測 jetsam；門檻需一次真機基線 |
| 代理門檻是否誤觸 `heapPressure` 重啟 | **未量測** | R1 建議第一輪只記錄、不觸發，由實作單決定 |
| `performance.memory` 在 WebKit | **已查證不存在**（MDN；`browser-compat-data` `api/Performance.json` 的 `memory.support.safari = false`，`measureUserAgentSpecificMemory` 同樣 `false`） | GAP-39 的舊關閉路徑不可實作，已刪除 |
| 無 mutation 熱恢復的實際秒數 | **未量測**（本輪不改碼；W0 畫像夾具可量） | R2 的 ≤ 1 秒是 `target`，不是量測值 |
| overlay 重打包的實測秒數 | **未量測**（只有 `WorkspaceLogService.swift` 的歷史註解「100 MB 約 10 秒」） | R2 用 O(位元組) 描述，不引用秒數當承諾 |
| 四端讀同一 manifest golden 的 runtime 證據 | **不存在**（§8.1 是 `target`，沒有可讀的清單） | GAP-41 不能因 spec checker 通過而關閉 |
| pinned DSH checkout 的 `readImage` 原始碼 | **NOT_VERIFIED**（`PDSH_DSH_CHECKOUT` 在本 worktree 未設定；沿用 §8／§8.1 與 `docs/upstream/README.md` 的記載） | R2 的「卡在哪個能力」是既有記載，不是本輪重讀 |
| pinned 模型 adapter 是否保留 purpose | **NOT_VERIFIED**（同上；沿用 `PC-20261112-model-purpose-gap.md` §2.3） | R3 只能凍結語義，GAP-42 保持 open |
| pc backend 上 outbox 的 crash 矩陣 | **未量測**（尚未實作） | R4 的延後理由不依賴它；重開時要補 |
| Bot profile 的小模型壓縮是否生效 | **未量測**（`BotContextProfile*` 在本倉沒有 runtime 消費者） | R5 的「維持現狀」建立在「目錄不生效」這個觀察上 |
