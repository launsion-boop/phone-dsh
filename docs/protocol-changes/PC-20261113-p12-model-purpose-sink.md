<!-- SPDX-License-Identifier: MIT -->
# PC-20261113-p12-model-purpose-sink — R3：purpose 載體否決、型別下沉 `PhoneDSHAgentCore`、分階段執行語義

## 0. 摘要

```yaml
change: PC-20261113-p12-model-purpose-sink
contracts: [P12, P26]
status: frozen
breaking: false
version_decision: 無版本變更，也**不新增任何 wire 欄位／header**。`x-pdsh-model-purpose` 之類的載體被 owner 否決（要四端同步、舊版要容忍，而 pinned 上游 adapter 不保留該值，加了也觀察不到）。本修訂只凍結兩件事：(a) enforcer 的純策略型別歸屬 `PhoneDSHAgentCore`（P12 依賴圖的契約陳述；本輪不改 `Package.swift`），(b) 執行點的分階段語義：purpose 缺席 → 只記錄、行為與今天完全相同；purpose 存在 → 真的執行 allow/deny。
base: f6b447dfbc83f6e768a5c802184013d2c9b67e26
contract_revision: 本單所屬 commit（R3 freeze）——`spec/bot/v1/README.md` §2.10、`spec/README.md` §7 GAP-42、本單
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。** `BotModelPurposeGate`／`BotModelRequest`（`BotModelPurposePolicy` 的 enforcer）已在 `Sources/PhoneDSHBot/Ledger/BotModelPurposePolicy.swift` 定義、可被外部呼叫，`model-purpose-enforcement.phone.json` 的 allowed／denied／default／unknown 正反例仍描述其語義；但 `ModelGateway` 在解析憑據／開 socket 前沒有任何呼叫方，策略未生效（GAP-42）。原本記了三個「缺失前提」（模組依賴、wire 沒有 purpose、pinned adapter 不保留）。owner 於 2026-11-13 裁定：**不加 wire 載體**；把型別下沉到兩端都已依賴的 `PhoneDSHAgentCore`；並把執行語義凍結成「缺席只記錄、存在才 enforce」的兩段式，讓接線可以分階段落地而不會一次拒掉所有模型請求。
- **Coordinator / contract owner**：`contracts-1113`（本 worktree）。**Implementer（下一單元，`perf-r3`）**：把純策略型別搬到 `PhoneDSHAgentCore`、保留 `PhoneDSHBot` 的對外名稱、在 `ModelGateway` 接上執行點並補測試；**由實作單改 `Package.swift`（若真的需要；見 §2）**，本單不改。實作者不改 `spec/`。
- **Owning spec / code contract / fixtures**：
  - **P26 語義條款**：[spec/bot/v1/README.md](../../spec/bot/v1/README.md) §2.10（執行點、缺席／存在兩分支、單一政策權威）。
  - **P12 依賴圖**：權威是 `Package.swift`（code contract）。本單只把它寫成契約陳述；`Package.swift` 不動。
  - **既有 golden**：`spec/bot/v1/golden/model-purpose-enforcement.phone.json`（allowed／denied／default／unknown）**不改**；它描述的是「purpose 存在時」的 enforcer 語義，仍有效。
  - **本輪沒有 `spec/v1/README.md` 的改動**：它是 wire／proto 文件的 README，P26 的權威在 `spec/bot/v1/README.md`、P12 的權威在 `Package.swift`；把 Swift 模組依賴寫進 wire README 會變成第三個權威。R3 的規範落點因此是 §2.10 ＋ GAP-42，而不是 `spec/v1/README.md`。
- **受影響 producer／consumer**：
  - **P12 Swift**：`Sources/PhoneDSHAgentCore/**`（型別新家）、`Sources/PhoneDSHBot/Ledger/BotModelPurposePolicy.swift`（保留對外名稱的 alias／re-export）、`Package.swift`（**本輪不動**；Gateway 已依賴 AgentCore，見 §2）。
  - **P05 Swift**：`Sources/PhoneDSHGateway/ModelGateway.swift`（未來執行點；**本輪不動**）、`Sources/PhoneDSHGateway/ModelProvider*`。P05 的 wire 條款（`gateway-security.md` 的 header strip、請求形狀）**無 delta**。
  - **P17**：`Sources/PhoneDSHAgentCore/ExecBridgeHosting.swift`／loopback 的 `HTTPEgressRequest` **無 delta**（仍只有 method／url／headers／body）。
  - **P26 Swift**：`Sources/PhoneDSHBot/Ledger/**`、`BotLLMLedger`（帳本 `purpose` 記錄不變）。
  - **其他三端**：本修訂沒有 wire／schema 變更，Kotlin／Rust／TS 沒有 decoder 工作；Kotlin 若日後有 gateway 執行點，必須跟同一份 policy 語義，不得複製。
- **明確不是本輪工作**：不改 `Package.swift`；不改 `ModelGateway` 的任何位元組；不加標頭／欄位／錯誤碼；不改 golden；不改 `dsh-pin`；不改 pinned checkout。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| wire 載體（P05） | 曾建議新增 `x-pdsh-model-purpose`（Worker→host，host 端 strip 規則已覆蓋）→ **否決**。理由：要四端同步、舊版要容忍未知標頭，而 pinned 模型 adapter 不保留上游 purpose，加了也觀察不到值；新增一個無法被填充的欄位是第二種空表達。`GatewayRequest`／`HTTPEgressRequest` 仍只有 method／url／headers／body。 |
| 型別歸屬（P12） | `BotModelPurpose`／`BotModelPurposePolicy`／`BotModelPurposeRow`／`BotModelPurposeDefaults`／`BotModelPurposeError`／`BotModelTier`／`BotModelRequest`／`BotModelPurposeGate` 在 `Sources/PhoneDSHBot/Ledger/` → **下沉到 `PhoneDSHAgentCore`**（純策略型別，無 Bot 依賴）。`PhoneDSHBot` 保留既有對外名稱（`@_exported import` 或 typealias，由實作單選一種並寫在程式註解），**不得出現兩個型別名**。 |
| 依賴邊（P12） | `PhoneDSHGateway` 只依賴 `PhoneDSHAgentCore` ＋ `PhoneDSHStandardError`（`Package.swift:53`）；`PhoneDSHBot` 也只依賴 `PhoneDSHAgentCore`（`Package.swift:74`）→ **不新增模組依賴邊、不反轉方向**。契約陳述：Gateway 對 policy 型別的依賴是 **AgentCore 內部公開 API** 的使用，`Package.swift` 不需為此新增 target 邊；若實作單發現真的需要（例如放進新的 target），那是另一張 P12 變更單，不得由本單推定。 |
| 執行語義（P26） | 原本沒有任何掛勾語義（enforcer 直接 fail-closed，缺 purpose 會 throw）→ **分階段凍結**：purpose **缺席** → 執行點記錄一筆 `purpose_absent` 診斷，**不呼叫** fail-closed 的 `authorize`，行為與今天完全相同；purpose **存在** → 執行點真的呼叫 enforcer，allow 放行、deny 拒絕該請求（未知 purpose 走既有 `EPURPOSE_MODEL_DENIED`）。只有這兩個分支。 |
| 單一權威 | 「不得複製 policy」 → **不變並明文化**：policy 只在 `PhoneDSHAgentCore` 一份；`ModelGateway` 不得複製 purpose 表、不得按模型名或 prompt 內容推斷 purpose、不得以預設值放行、不得 fail-closed 當預設。 |
| 證據（golden） | `model-purpose-enforcement.phone.json` 只有 allowed／denied／default／unknown → **本輪不改**。缺席分支目前由 §2.10 文字凍結；等執行點接線時，該 golden 才新增「purpose 缺席 → 只記錄」向量（實作單與 golden 同步，不得先加向量卻沒有執行點）。 |
| GAP-42 登記 | 三個「缺失前提」＋「本輪只交付 enforcer」→ 改記：載體否決、型別下沉與分段語義已凍結，實作單落地型別搬移與 Gateway 執行點；仍缺可靠的 per-request purpose 來源（pinned adapter 不保留／不傳遞）。 |
| 條款狀態 | §2.10 的執行點仍 `target`（未接線）；本修訂凍結的是「接線後必須長什麼樣」，不是宣稱它已生效。 |

**自檢（spec/README.md §5.1）。** 沒有新增第二種表達：沒有新欄位、沒有新標頭、沒有第二個 policy 副本、沒有第二個錯誤碼。沒有放寬配額或安全檢查：缺席分支只記錄（與今天相同），存在分支是**新增**的拒絕能力，不是放行。沒有收緊或放寬兩端都讀的訊息：本修訂沒有 wire 訊息變更；`model-purpose-enforcement.phone.json` 與 `model-purpose-policy.schema.json` 都不改。沒有新增 enum；`purpose` 的已知值集合不變。沒有刪除或重用任何名稱：型別搬家不改名（alias／re-export 保留 `PhoneDSHBot` 的對外名稱）。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | **無資料語義變化。** 舊版沒有 purpose 載體，新執行點看到的是「缺席」→ 只記錄、行為與今天相同；不會有請求因為這個變更被拒絕。既有 `model-purpose-enforcement.phone.json` 的 allowed／denied／default／unknown 在新舊端都必須得到同一判決。 |
| new → old | **無影響。** 本修訂不產生任何 wire／持久化位元組；舊版讀不到新格式（因為沒有新格式）。回滾＝回到舊版，行為相同。 |
| new → new | 同一份 §2.10 語義與同一份 enforcer；型別搬家後 `PhoneDSHBot` 的呼叫方不改（alias／re-export）。執行點（實作單落地後）與 enforcer 用同一份 policy。 |
| persisted old data → new／rollback | **不適用**：沒有持久化格式變更；帳本、ledger、golden 位元組不動。`BotLLMLedger` 的 `purpose` 記錄語義不變。 |

- **版本決定**：不升任何版本。`proto 1`、bot schema、gateway schema、`dsh-pin` 全部不動。理由：沒有跨端位元組被新舊端同時讀取；型別搬家是 Swift 模組內部的 P12 變更（公開 API 位移），不是 wire 版本。
- **部署順序**：spec（本 commit）→ 實作單（型別搬移＋`Package.swift` 只有在真的需要時才動＋執行點＋缺席診斷＋golden 缺席向量）→ 兩端測試 → 才可把 §2.10 的執行點由 `target` 改 `partial`（不是 `implemented`）。pinned adapter 保留 purpose 之前，GAP-42 保持 open。
- **`target` 與仍保留的差異**：`ModelGateway` 目前**沒有**呼叫 enforcer；purpose 的可靠來源（pinned adapter）仍缺。任何「模型用途策略已生效」的宣稱都不成立，實作報告必須寫「執行點就緒、值仍缺」。

## 4. 分工與證據

- **本單獨占路徑（已在本 commit 完成）**：`spec/bot/v1/README.md` §2.10、`spec/README.md` §7 GAP-42、本單。
- **下一實作單（`perf-r3`）路徑**：`Sources/PhoneDSHAgentCore/**`（型別新家）、`Sources/PhoneDSHBot/Ledger/**`（alias／re-export）、`Sources/PhoneDSHGateway/ModelGateway.swift`（執行點與缺席診斷）、`Package.swift`（**只有**在模組邊真的需要時；變更要在 PR 說明並引用本單 §2 的契約陳述）、`spec/bot/v1/golden/model-purpose-enforcement.phone.json` ＋ `spec/tools/bot/**`（缺席向量；此路徑屬 contract owner，實作單需回報由 owner 加）。
- **共享 fixtures**：`spec/bot/v1/golden/model-purpose-enforcement.phone.json`（既有，不改）；缺席分支的向量是**待加**項，加入時必須有對應執行點與測試，不得只加 golden。
- **各端真實 proof 命令（由實作單執行）**：
  - Swift：`swift test --filter PhoneDSHBotTests`（enforcer 語義與帳本 purpose 不變）、`swift test --filter PhoneDSHGatewayTests`（執行點：存在 → allow／deny，缺席 → 放行並記錄診斷）。
  - Kotlin：`bash scripts/ci/check.sh --only phone-android-tests`（若有 gateway 端對齊；本輪無 Kotlin 變更）。
  - 本單只跑 spec 檢查（見 §4.1）；**Swift／Kotlin 執行一律 NOT_RUN**。
- **剩餘風險**：型別搬家造成的公開 API 位移若沒保留 `PhoneDSHBot` 的對外名稱，會讓既有呼叫方編譯失敗——實作單必須選 alias 或 `@_exported import` 並在程式註解寫明，P12 不允許兩個型別名；「缺席只記錄」若被實作成 fail-closed，等於一次拒絕所有模型請求（GAP-42 明文禁止）；purpose 的來源仍缺，任何人不得用模型名、prompt 內容或時序推斷它（第二個權威）；`BotModelRequest.provider` 由誰填仍開放（本單不決定）。

### 4.1 命令 → 結果（本 commit 實跑）

```bash
python3 spec/bot/v1/tools/validate_vectors.py
python3 spec/tools/bot/check_golden.py --root .
bash scripts/ci/check.sh --only phone-cross-tree
bash scripts/ci/check.sh --only phone-spec
```

結果見交付回報（原樣記錄；未能執行的記 `NOT_RUN`）。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts-1113（contract owner） | owner 於 2026-11-13 裁定 R3：否決新 wire 載體；enforcer 純策略型別下沉 `PhoneDSHAgentCore`（P12 契約陳述，`Package.swift` 本輪不動）；凍結「缺席只記錄／存在才 enforce」分階段語義。 | all（contract freeze 公告）；P05／P12／P26（受影響端）；upstream（pinned adapter 需保留／傳遞 purpose 才能關 GAP-42） |
