<!-- SPDX-License-Identifier: MIT -->

# PC-20261113-bot-proactive — freeze B4 proactive settings, decisions and routine-due separation

## 0. 摘要（機器可讀）

```yaml
change: PC-20261113-bot-proactive
contracts: [P26, P18, P08]
status: frozen
breaking: false
version_decision: no wire/schema version bump; additive v2 settings/decision schemas and a phone-only golden freeze the existing Swift behavior. The persisted UserDefaults key and six-field ProactiveSettings blob are unchanged, and no Kotlin implementation is started in this lane.
base: 26cf933553e2e2821abaa0a9ef11942e29027c0e
contract_revision: spec/bot/v2/README.md §3 + spec/bot/v2/proactive-settings.schema.json + spec/bot/v2/proactive-decision.schema.json + spec/bot/v2/golden/proactive.json @ working tree on 26cf9335 (uncommitted)
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。** P26 / S5 proactive 在 port plan 中仍是 `spec-missing`：
  `spec/bot/v2/README.md` §3 只有 prose，沒有 schema 或共享 golden；Swift 已有
  `Sources/PhoneDSHBot/Proactive/*` 與五組測試。期望：把 §3 凍結成可實作的
  settings/decision schema、共享 vectors 與 Swift 對拍；B4 Kotlin 依同一份 vectors 實作，
  不在本 lane 寫 Kotlin。
- **Coordinator / contract owner：** C7（本 lane）。**Implementers：** Swift 對拍在本 lane；
  Kotlin B4 為 `not started`，只讀契約。**Reviewer-integrator：** 下一個整合 head 的 reviewer。
- **Owning spec / schema / fixtures：**
  - `spec/bot/v2/README.md` §3（本變更新增 §3.0 判定鏈、通知形狀、持久事件與 CCR 接縫）。
  - 新 `spec/bot/v2/proactive-settings.schema.json`（有效設定：持久化六欄 +
    `fuseWindowMs`/`fuseMaxWakeups` + `deliveryKinds`）。
  - 新 `spec/bot/v2/proactive-decision.schema.json`（`ProactiveDecision`、`ProactiveNotification`、
    `ProactiveDeliveryResult` 與 `$defs.proactiveCandidate`）。
  - 新 phone-only `spec/bot/v2/golden/proactive.json`（`upstream: []`）；不重用或改寫
    `golden/routine-notification.json` 的既有案例。
  - `spec/bot/v2/tools/validate_vectors.py` 新增 §3 參考判定鏈、正反例與 mutation。
  - Swift 對拍：`Tests/PhoneDSHBotTests/Proactive/ProactiveVectorTests.swift`。
- **受影響 producer/consumer：**
  - P26 Swift `Sources/PhoneDSHBot/{Proactive,Routines}`：本 lane 只讀真實型別，不改行為。
  - P18 持久化：`ProactiveSettings` 的 UserDefaults key 與六欄 Codable JSON 形狀不變；
    新 schema 是「有效設定」的組合文件，不是第二份持久化格式。
  - P08 平台通知：`ProactiveNotification`/`ProactiveDeliveryResult` 與 §3.1 routine-due
    本地通知的 Swift 介面被文件化；UNUserNotification 實作不改。
  - Kotlin B4 `android/bot`：`not started`；Android 本地通知對應待 owner 決定（見 §4）。
  - HarmonyOS 無 Bot runtime：不受影響。

## 2. 契約 delta

只列改動；未變語義引用 owning clause。

| 項目 | Before → After／依據條款 |
| --- | --- |
| settings 形狀 | §3 prose 只列 `mode`/`dnd`/`quietStart`/`quietEnd`/fuse 常數 → `proactive-settings.schema.json` 明定九欄、缺省、`deliveryKinds` enum、關閉物件與八個錯誤碼；§3.0 |
| decision 形狀 | §3 只說「記 `mode-off`/`fuse`/`delivery-failed`」→ `decision` 固定 `did|would|skip`，上述名稱改為 `reason` enum；`proactive-decision.schema.json`；§3.0 |
| 判定順序 | prose 的三道硬限制沒有精確順序 → routine-held/quiet → mode-off → policy → fuse → delivery；§3.0 |
| 保險絲 | prose「最多 N 次 did/would」→ 嚴格 `< window`、第 4 次允許/第 5 次拒絕、per-Bot、只計 `did` 或 `would` 模式的 `would`；§3.0 |
| deliveryKinds 過濾 | prose 只說 `on` 對清單內類別投遞 → 清單外記 `would`/`would-only-kind`，不投遞、不消耗保險絲；§3.0 |
| dedupeKey | prose 只說「穩定標識」→ 明定 trim/fallback 演算法，並冻结「替換而非抑制」；§3.0 |
| 通知文案 | prose 未定 → 三種 kind 的缺省 title/body、trim、title 120/body 500 截斷、`rowId`↔`deepLink` 成對；§3.0 |
| 持久事件 | 未在 §3 寫明 → `proactive.considered.data` 至少 `decision`/`reason`/`kind`/`botId`/`mode`/`channel`/`fuseRecorded`/`dedupeKey`，並凍結 restore 只讀 `did`/`would`；§3.0 |
| routine-due | §3.1 已有欄位契約 → 本變更只加 `golden/proactive.json.routineDue` 的跨路徑斷言：不是 proactive、不消耗保險絲；欄位正反例仍屬 `routine-notification` |
| schema 錯誤路徑 | 未定 → `proactive-settings-*` 與 `proactive-candidate-*` 的 code/path 由 golden invalid 明定；§3.0 |
| 條款狀態 | §3 仍是 `target`；Swift 實作 + 向量在 iOS 上 `implemented`（單元層），Kotlin `not started`；真機通知未驗 |

**自檢（spec/README.md §5.1）：** 沒有新增第二種 settings 持久化格式或第二個 decision envelope；
新 schema 只描述既有 Swift 型別，沒有新增 wire frame/route/durable event type；`deliveryKinds`
與 `reason` 都是關閉 enum，未知值 fail-closed；沒有刪除或重用既有名稱/編號；P18 key 與
`routine-notification.schema.json` 均未改。

### 2.1 CCR（以 Swift 為準）

| CCR | Prose（pre-freeze 行號） | Swift（行號） | Golden | 為何不能照 prose |
| --- | --- | --- | --- | --- |
| CCR-1 decision 名稱 | §3 item 4 說「記 `fuse`」、模式段說「只記 `mode-off`」「記 `delivery-failed`」（README:297-298, 304-305） | `ProactiveDecisionKind` 只有 `did`/`would`/`skip`（`ProactiveModels.swift:139-143`）；`mode-off`/`fuse`/`delivery-failed` 是 `reason`（`ProactiveEngine.swift:139-141,150-152,166-168`） | 所有 `decisions.valid` 的 `decision`+`reason` | Swift 的 durable `proactive.considered.data.decision` 已是 `did|would|skip`；新增 `mode-off` 等 decision kind 會改寫既有事件語意，且沒有 consumer |
| CCR-2 on-mode 過濾不計保險絲 | §3 item 4「最多 N 次 did/would 決策」（README:297-298）與模式段 `deliveryKinds`（README:304-305） | `deliverable` 才檢查/提交；`would-only-kind` 以 `fuseRecorded=false` 提交（`ProactiveEngine.swift:143,149-153,177-178`） | `delivery-kinds-filter-records-would-only-kind`（max=1，3 個 task-done 仍全 `would`） | 照 prose 會讓「預覽」消耗保險絲，實際 routine 通知被自己的預覽餓死；Swift 的 on-mode 過濾是 no-op 而非 wakeup |
| CCR-3 routine 預過濾先於 mode-off | §3 item 1 只說 held/quiet 不通知（README:291-292）；模式段說 off 只記 `mode-off`（README:304） | routine 的 `delivery != interrupt` / `quiet` 在 mode 檢查之前（`ProactiveEngine.swift:129-142`） | `held-and-quiet-routine-are-filtered-before-mode-off`（settings off，期望 `routine-held`/`routine-quiet`） | off 模式下若先記 `mode-off`，會丟掉「這條 routine 本來就不該進通知」的原因，與 Swift 既有事件/測試不符 |
| CCR-4 ProactiveSources 只收成功終態 | §3 item 1「成功的 routine 結果（或失敗終態）」（README:291-292） | `ProactiveSources.routineCandidate` 要求 `status == "succeeded"`（`ProactiveSources.swift:90-99`）；`RoutineScheduler.considerInterrupt` 另行處理 failed/timed-out/cancelled（`RoutineScheduler.swift:610-632`） | `failed-routine-terminal-can-notify`（直接驅動 engine，期望 `did`） | 兩個 Swift 入口不一致：production 走 RoutineScheduler，能通知失敗終態；`ProactiveSources` adapter 不能。契約以 engine+RoutineScheduler 為準，B4 不可只移植 `ProactiveSources` 而宣稱失敗終態已覆蓋 |
| CCR-5 reminder 缺 row/deep link | §3 item 2 的 reminder 豁免（README:293-294）與 §3 item 5 的 `row` 深鏈（README:299-301） | `ProactiveSources.tick` 建的 reminder 候選沒有 `rowId`（`ProactiveSources.swift:59-69`）；`UNUserNotificationProactiveDelivery` 對 nil 深鏈拋 `missingDeepLink`（`UNUserNotificationProactiveDelivery.swift:33-36`） | `dnd-blocks-and-explicit-reminder-bypasses` / `quiet-hours-blocks-and-explicit-reminder-bypasses` 在 policy 層用帶 `rowId` 的 reminder | 豁免能通過 policy，但 production UN deliverer 會回 `delivery-failed`；這是 producer 缺資料，不是 engine 規則，B4 接線前必須補 reminder 行/深鏈 |

### 2.2 澄清（prose 未定，Swift 已定）

- `quietStart == quietEnd` = 沒有安靜窗口（`ProactiveSettings.swift:72`）；golden
  `equal-quiet-endpoints-are-not-quiet`。
- fuse 窗口比較是嚴格 `<`（`ProactivePolicy.swift:60`）；golden/Policy 測試覆蓋第 4/5 次與
  邊界時間。
- 顯式 title/body 先 trim，空白才用缺省；通知 title 截 120、body 截 500
  （`ProactiveModels.swift:85-86`、`ProactiveEngine.swift:239-255`）；golden
  `notification-copy-trims-and-clips`。
- `ProactiveSettings()` 的 mode 缺省是 `would`，production store 是 `on`
  （`ProactiveSettings.swift:19-22`、`ProactiveSettingsStore.swift:17-19`）；schema 要求顯式
  寫出 mode，不把兩者混成一個缺省。
- 引擎的 `deliveryKinds` 缺省是 `[task-done, routine-result]`
  （`ProactiveEngine.swift:29`），production 裝配是 `[routine-result]`
  （`BotRuntimeUnit.swift:114`）；golden 的 `production-default` 用後者，
  `on-empty-delivery-kinds` 證明空清單合法。
- 未知成員：schema 關閉；Swift `JSONDecoder` 對本地持久化 blob 忽略未知成員，但不回寫。
  這是持久化恢復，不是共享文件的新 unknown-field 規則。
- `fuseWindowMs < 1`、`fuseMaxWakeups < 1`、未知/重複 `deliveryKinds` 由 canonical schema 拒絕；
  Swift `ProactivePolicyConfiguration`/`ProactiveEngine` 接受原始值。這些 golden 標為
  `contract-only`，是 writer/validator 邊界，不是執行時 fallback。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 沒有舊 wire producer。舊版 App 的六欄 `ProactiveSettings` blob 仍被新 Swift 解碼；新 schema 是有效設定的組合文件，不會被寫進 UserDefaults。舊 `proactive.considered` 事件（含 `cost`/`spendBudget`/缺 `fuseRecorded`）仍可 restore（`ProactiveRestoreDurabilityTests`）。 |
| new → old | 本 lane 沒有改 runtime 或持久化格式；舊 App 讀同一 key/六欄 JSON，不認識新 schema/golden，但不受影響。若舊 App 回滾，fuse 計數照舊事件重建。 |
| new → new | Python §3 參考判定鏈與 Swift `ProactiveVectorTests` 讀同一 `golden/proactive.json`；15 個 decision case / 38 steps 全部一致。Kotlin B4 必須用同一 golden，不得另寫 fixture。 |
| persisted old data → new／rollback | 不適用 migration：key `phone-dsh.bot.proactive-settings.v1` 與六欄 Codable 形狀不變；`proactive.considered` 沒有新增 durable type 或 SQLite schema。 |

- **版本決定。** 不升 wire/schema version、不新增 route/env var、不新增 durable event type。
  `proactive-settings.schema.json` 與 `proactive-decision.schema.json` 是 v2 target 的 additive
  凍結；`golden/proactive.json` 是 phone-only（`upstream: []`），不進 v1 exporter manifest。
  Kotlin 若要新增欄位，先開 PC，不得在 B4 私下加。
- **bundle/image/native artifact。** 不涉及 Worker bundle、native ABI 或 image 產物。
- **target/draft 差異。** §3 仍是 `target`；真機 `UNUserNotificationCenter` 權限/DND/低電量行為
  未驗；Android/HarmonyOS 未實作。P08 的 Android Notifier 對應是 owner 待決（§4）。

## 4. 分工與證據

- **本 lane 獨占路徑：** `spec/bot/v2/**`、`Tests/PhoneDSHBotTests/Proactive/**`、
  `docs/protocol-changes/PC-20261113-bot-proactive.md`、`result.md`。沒有改
  `Sources/PhoneDSHBot/**`（現有 Swift 已符合向量）、`spec/bot/v1/**`、`spec/ui/**`、
  `android/**`、`docs/design/**`。
- **共享 fixtures：**
  - `golden/proactive.json.settings`：4 valid、11 invalid（缺欄、型別、未知 enum、時間格式、
    時區、range、重複 deliveryKind、未知成員）；另 2 個時間/時區 normalization 案例。
  - `golden/proactive.json.decisions.valid`：15 個 case / 38 steps，覆蓋 off/would/on、
    routine-held/quiet 優先級、DND、quiet、顯式 reminder、fuse 第 4/5 次、deliveryKinds 過濾、
    delivery failure/throw/unavailable、dedupeKey 替換與 fallback、文案 trim/截斷、
    missing-bot、失敗 routine 終態。
  - `golden/proactive.json.decisions.invalid`：5 個非法候選（未知 kind、缺 botId、
    attempt 型別、未知成員、空 rowId），每個都有 error code/path。
  - `golden/proactive.json.routineDue`：1 個 routine-due case；欄位由
    `routine-notification.schema.json` 驗證，跨路徑 flag 為 `proactive: false`、
    `consumesFuse: false`。
- **真實 producer/consumer 測試：**
  - `Tests/PhoneDSHBotTests/Proactive/ProactiveVectorTests.swift` — 真實
    `ProactiveSettings`（Codable decode + `normalized()`）、`ProactivityPolicy`、
    `ProactiveEngine`、`RoutineScheduledNotification`/`BotRoutineDeepLink`；routine-due
    另用真實 `RoutineScheduler.syncNotifications()` 登記 5 條，再跑 shared fuse case。
  - `spec/bot/v2/tools/validate_vectors.py` — §3 參考判定鏈逐條復算、設定/候選錯誤碼、
    routine-due 參考實作與 10 個 mutation。
- **Exact commands → result（本 worktree，26cf9335）：**
  - `python3 spec/bot/v2/tools/validate_vectors.py` → **PASS**（proactive settings 4 valid /
    11 invalid；decisions 15 cases / 38 steps / 5 invalid / 1 routine-due / 10 mutations）。
  - `python3 spec/tools/registry_build.py --root . --check` → **PASS**。
  - `swift test --filter Proactive` → **PASS**（21 tests，0 failures）。
  - `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → **PASS**（both stages；
    8/8 cross-tree invariants；registry byte-identical；schema diff 0 breaking）。
- **未驗證：** Kotlin B4 實作；真機 `UNUserNotificationCenter` 權限/DND/低電量/64 條上限；
  Android Notifier 對應；模型 E2E。單元測試不能升級成真機 claim。
- **Owner 待決：**
  1. **P08/P26：** iOS 的 `ProactiveDelivering` 與 routine-due 本地通知在 Android 是否走
     P08 Notifier（`notifier.*` capabilities），或需要新的 Android 排程契約；本 lane 不寫 Kotlin。
  2. **P26/P09：** reminder 的 row/deep link 由誰產生（CCR-5）；在補齊前不得把
     `ProactiveSources.tick` 直接接到 production UN deliverer。
  3. **P26：** `ProactiveSources` 是否擴充 failed/timed-out/cancelled 終態（CCR-4），或正式
     文件化它只覆蓋成功結果、production 只走 `RoutineScheduler.considerInterrupt`。
  4. **P26 registry：** `spec/README.md` P26 authority 的 explicit schema 清單尚未加入兩個新
     schema（本 lane 邊界只允許 `spec/bot/v2/**`）；下一個 registry/owner 變更應補上，
     `spec/tools/registry_build.py --check` 目前仍 PASS。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| PC-20261113-bot-proactive | C7 coordinator | P26/S5 proactive `spec-missing`；凍結 §3 settings/decision/notification、routine-due 分離與 CCR-1..CCR-5 | Swift（本 lane 對拍）、Kotlin B4（not started，讀 golden）、P08/P18 owner |
