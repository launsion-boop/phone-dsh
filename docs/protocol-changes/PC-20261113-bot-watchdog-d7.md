<!-- SPDX-License-Identifier: MIT -->

# PC-20261113-bot-watchdog-d7 — freeze D7 watchdog config, flag payload and context lint

## 0. 摘要（機器可讀）

```yaml
change: PC-20261113-bot-watchdog-d7
contracts: [P26]
status: frozen
breaking: false
version_decision: no wire/schema version bump; watchdog config tightens an existing optional object with defaults, and watchdog.flagged.data gains two optional members. No durable event type, SQLite schema, route or frame changes. Kotlin B4 is not started in this lane.
base: c4847abad7d21409f779468e78793294cc12e199
contract_revision: spec/bot/v1/watchdog.schema.json + spec/bot/v1/watchdog.md + spec/bot/v1/observability.md + spec/bot/v1/context-lint.schema.json + spec/bot/v1/golden/{watchdog,context-lint}.phone.json @ working tree on c4847aba (uncommitted)
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。** D7 在 port plan 仍是 `spec-partial`：`watchdog.schema.json`
  的 `config` 是無約束 object；unit/flag/mobile 語義只在 Swift；context lint 的六條規則、thresholds
  與 location keys 只在 Swift，`observability.md` 不存在。期望：把上述行為凍結成 Android 可實作的
  schema/doc/vectors，並用真實 Swift 對拍。本 lane 不寫 Kotlin。
- **Coordinator / contract owner：** C9（本 lane）。**Implementers：** Swift 對拍在本 lane；
  Kotlin W1/B4 為 `not started`，只讀契約與 golden。**Reviewer-integrator：** 下一個整合 head 的
  reviewer。
- **Owning spec / schema / fixtures：**
  - `spec/bot/v1/watchdog.schema.json`（config named properties + `$defs.flagData`）。
  - 新 `spec/bot/v1/watchdog.md`（config 錯誤碼、units、evaluation、flag payload、mobile）。
  - 新 `spec/bot/v1/observability.md`（六條 lint 規則、thresholds、evidence/location、P0 caller）。
  - `spec/bot/v1/context-lint.schema.json`（每條規則的封閉 location shape）。
  - `spec/bot/v1/golden/watchdog.phone.json`、`golden/context-lint.phone.json`（上游檔不改）。
  - `spec/bot/v1/tools/validate_vectors.py`（reference monitor、config/error/lint 檢查與 mutation）。
  - `Tests/PhoneDSHBotTests/Watchdog/BotWatchdogVectorsTests.swift`、
    `BotContextLintVectorsTests.swift`（class `BotWatchdogContextLintVectorsTests`）。
- **受影響 producer/consumer：**
  - P26 Swift `Sources/PhoneDSHBot/Watchdog/*`：config 缺省/錯誤語義、flag data 的 `sessionId`/`at`。
  - P26 Kotlin B4 `android/bot`：未開始；必須用同一 schema/golden，不得另寫 fixture。
  - P18/P08：本 lane 不改持久化或平台通知實作；mobile host signal 只凍結語義與 Android 映射建議。
  - HarmonyOS：無 Bot runtime，不受影響。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| watchdog config | `{type:object}` → 13 個具名 optional 成員、預設、`minimum:0`、關閉物件；`watchdog.md §2` |
| config 缺省/錯誤 | 舊 Swift decoder 要求 13 欄全在；D7 改為缺欄用預設。負數/型別/`null`/未知成員 reject，錯誤碼/路徑見 `watchdog.md §2`；`0` 合法且關閉對應檢查 |
| unit | 凍結 `turn|task|routine|goal`、`deadlineAt=startedAt+deadline`、goal 無預設 deadline、start 冪等、finish 刪除 unit/seen；`watchdog.md §3` |
| evaluation | 每 `tickMs` caller tick 與每個 observed event 評估；once per `(unit,check)`；durable event id 去重；append 失敗可重試；`watchdog.md §4` |
| flag data | 固定 `check,unitKind,unitId,botId,sessionId,at,evidence`；新增 `sessionId`、`at`；`$defs.flagData`、`watchdog.md §5` |
| checks | deadline（嚴格 `>`）、heartbeat（嚴格 `>` 且 pending approval 抑制）、repeated signature/error（`>=`）、quota（嚴格 `>`）、三 mobile（observe-only、once）；`watchdog.md §6` |
| mobile | WebContent terminated 是 host event；thermal/battery 是 host signal；不可用不 flag、不偽造讀數；Android 映射見 §4 |
| context lint | 六規則、20000/32000、4096/12000、8000/16000、40、2、500/20；finding `rule/severity/evidence/location`；每規則精確 location keys；`observability.md §3–§6` |
| lint caller | P0 無 production caller；Android 若新增是 new behaviour，需 budget/limit；`observability.md §1` |
| context profiles | 只作 DSH compaction 資料；Bot runtime 不重作，Android 不要求實作；`observability.md §1` |
| 條款狀態 | D7 由 `spec-partial` 轉為 `frozen`（schema/doc/vectors/Swift 對拍）；Kotlin 仍是 `not started` |

**自檢（spec/README.md §5.1）：** 沒有新增第二種 event envelope、durable type、route 或 SQLite
schema；config 收緊只影響一份沒有 production persisted instance 的設定物件；flag data 是既有開放
`data` 物件的新增 optional 成員；lint 是獨立診斷 shape，不進 `watchdog.flagged`；沒有刪除或重用
既有名稱/編號。

### 2.1 CCR（以 Swift 為準）

| CCR | Prose（pre-freeze） | Swift（行號） | Fixture | 裁定 |
| --- | --- | --- | --- | --- |
| CCR-1 durable once 勝過 finish/restart | D7 outline 只說 `finishUnit` 刪除 unit 及其 seen 集合（`android-bot-spec-deltas.md:713-714`） | `finishUnit` 刪除 unit/seen（`BotWatchdogMonitor.swift:80-84`），但 `emit` append 前按 event id 查 durable store（`:198-234`, `:262-278`）；同 `(kind,id,check)` 重啟後只重建 seen，不發第二條 | `base-and-mobile-once` 第二次 `tick(211)` 期望 `[]` | 照 Swift。actual once-per-unit 是 store 內的 durable event id，不是 unit 記憶體壽命；`watchdog.md §3–§4` 已明寫 |
| CCR-2 mobile 不繼承 unit identity | outline 說 flag payload 有 `botId?/sessionId?`，未說來源 | `observeMobile` 直接使用 caller 傳入的 `botId/sessionId`，不從 tracked unit 補（`BotWatchdogMonitor.swift:169-190`） | mobile steps 顯式帶 `botId`/`sessionId` | 照 Swift。host caller 必須給 identity；不建立第二個隱式來源 |
| CCR-3 config 的 `null` 不是缺省 | outline 只說 optional/default；「非正數 reject 或 coerce 由 owner 決定」 | 舊 synthesized decoder 缺欄即失敗；D7 custom decoder 缺欄預設、`null`/負數/未知成員 reject（`BotWatchdog.swift:56-139`） | `missing-all-uses-defaults`、`null-is-not-absent`、`negative-deadline`、`unknown-field` | owner 決定 reject 負數/未知；`0` 保留為 disable。生產沒有 persisted config，無 migration |
| CCR-4 lint threshold coercion | outline 只凍結數值，未說非正 input | warn/error 用 `positive` + `max`（`BotContextLintRules.swift:18-20`, `:58-61`, `:140-143`, `:197-200`; `BotContextLint.swift:143-145`） | `persona-coerced-zero-thresholds` | 照 Swift：非正 warn→缺省 warn；非正 error→當期 warn；error<warn→warn。不是 reject |
| CCR-5 goal 總額度未執行 | outline 只列 `goalMaxTotal*` config，沒有 goal check | `BotWatchdogChecks` 只檢查 per-unit quota（`BotWatchdogChecks.swift:74-97`） | `zero-disables-active-thresholds`、`full-explicit` | P0 只 freeze config 形狀；goal-wide quota enforcement 是未來 PC，不得把這兩個欄位當成已執行 |
| CCR-6 lint 無 production caller | outline 要求明說 on-demand/per-turn/not at all | `BotContextLint.lint` 無 production 呼叫（`grep` 只命中測試） | `context-lint.phone.cases` 全部由測試直接驅動 | P0 是 explicit on-demand only；Android 加 caller 另開 PC 並定 budget |

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old config → new | 13 欄皆 optional，缺欄取預設；既有 13 欄值不變。新增 negative/unknown 的 reject 只影響 malformed 文件，且沒有 persisted production config |
| new config → old | 舊 Swift decoder 要求全欄；未升級 reader 讀缺欄文件會 fail-closed，不會誤用 0。writer（目前只有 `.default`/測試）寫全欄時舊 reader 可讀 |
| new flag data → old reader | `data` 是開放 object；舊 reader 忽略新增 `sessionId`/`at`，仍讀 `check/unitKind/unitId/botId/evidence`。event type/id/once 語義不變 |
| new lint finding → old reader | 新 schema 收緊 location keys；P0 沒有 caller/持久化，沒有 old data。舊 reader 若只讀 `rule/severity` 可忽略 location |
| persisted old data → new／rollback | `bot_event_payloads` 不改；舊 `watchdog.flagged` 事件沒有 `sessionId/at` 仍是合法歷史資料。rollback 不刪事件；新 reader 對缺 `at` 的舊資料不得補造 |
| context-profiles | 檔案/schema/golden 不動；仍只作 DSH compaction 資料，未知 profile 解析 default |

- **版本決定。** 不升 schema/wire version。watchdog config 的收緊是 optional object 的 additive
  defaulting + stated rejection；flag data 新增 optional members；context lint 是 target 診斷 shape。
- **bundle/image/native artifact。** 不涉及 Worker bundle、native ABI 或 image。
- **target/draft 差異。** D7 契約 frozen；Swift 單元層 implemented；Kotlin B4 未開始；真機
  thermal/battery/WebContent 未驗。

## 4. 分工與證據

- **本 lane 獨占路徑：** `spec/bot/v1/**`、`Tests/PhoneDSHBotTests/Watchdog/**`、
  `docs/protocol-changes/PC-20261113-bot-watchdog-d7.md`、`result.md`，以及
  `Sources/PhoneDSHBot/Watchdog/**` 的三個最小修正（見 §5）。沒有改 `spec/ui/**`、
  `spec/bot/v2/**`、`android/**`、`docs/design/**`。
- **Shared fixtures：**
  - `golden/watchdog.phone.json`：4 valid / 5 invalid config；6 unit cases；3 monitor scenarios
    / 26 steps；9 flag payload cases；`contextProfiles` read-only block。
  - `golden/context-lint.phone.json`：11 cases / 11 valid findings / 5 invalid findings；10 個
    default thresholds；2 個 invalid threshold；六規則與 warn/error boundary。
  - 上游 `golden/watchdog.json`、`context-lint.json`、`context-profiles.json` 不改；新案例只在
    `.phone.json` overlay，`export-manifest.json` 已同步 44 files / 16 upstream / 28 overlays。
- **真實 producer/consumer 測試：**
  - `BotWatchdogVectorsTests`：真實 `BotWatchdogConfig` decode、`BotWatchdogMonitor.startUnit/
    tick/observe*/finishUnit`、`SQLiteDomainStore` 的 durable event 與 flag data。
  - `BotWatchdogContextLintVectorsTests`：真實 `BotContextLint.lint`、`BotContextLintThresholds`、
    `BotContextLintFinding`；profiles 用真實 `BotContextProfileDocument`。
  - `validate_vectors.py`：reference config defaults/errors、unit deadline、monitor state machine、
    flag payload、lint location keys/thresholds、12 個 mutation。
- **Exact commands → result（worktree @ c4847aba，uncommitted）：**
  - `python3 spec/bot/v1/tools/validate_vectors.py` → **PASS**（watchdog 4 valid / 5 invalid
    configs、6 units、3 scenarios / 26 steps / 9 payloads、7 mutations；context-lint 11 cases /
    11 valid / 5 invalid、5 mutations）。
  - `python3 spec/tools/bot/check_golden.py --root .` → **PASS**（44 files，16 upstream，
    28 overlays）。
  - `python3 spec/tools/registry_build.py --root . --check` → **PASS**（byte-identical）。
  - `swift test --filter Watchdog` → **PASS**（20 tests，0 failures）。
  - `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → **PASS**（two stages；
    phone-spec 含 v1/v2 vectors、golden、PCLink；cross-tree 8/8、registry、schema diff 0 breaking）。
- **未驗證：** Kotlin B4/W1 實作；真機 `PowerManager` thermal/battery、WebView render-process
  termination、`onTrimMemory`；context lint 的 production caller/預算；完整 `export-vectors.mjs
  --checkout` 重匯（CI 無 private checkout）。
- **Owner 待決：**
  1. **P26/B4：** Android config reader 是否共用 Kotlin serializer 的 strict unknown 檢查；不得只
     依 schema 而 runtime 靜默忽略。
  2. **P26 → P08/P18（若真的接 mobile）：** Android 的 thermal/battery/WebContent signal 是哪個
     平台層 producer、是否走既有 `notifier.*`/platform capability；本 lane 不改 P08/P18。
  3. **P26：** context lint 的 caller、sampling/預算與 UI 呈現；在有人呼叫前保持 no production
     caller。
  4. **P26：** `goalMaxTotalTokens`/`goalMaxTotalCostUsd` 是否要做 goal 聚合檢查；P0 明確未執行。

### 4.1 Mobile signal 的 Android 對應建議（非本 lane 實作）

| Swift check | Android 真實來源（建議） | Evidence（只放真實讀數） | 不可用時 |
| --- | --- | --- | --- |
| `webcontent_terminated` | `WebViewClient.onRenderProcessGone` / render-process-gone 回調 | `{reason, didCrash}`（API 提供多少寫多少） | 不回調就不 flag，不推測 crash |
| `thermal_pressure` | `PowerManager.getCurrentThermalStatus()` / `OnThermalStatusChangedListener`（API 29+） | `{status, statusCode}`，例如 `severe`/3 | API 缺失或 listener 未註冊不 flag；不得寫 `none` 冒充 |
| `battery_pressure` | sticky `ACTION_BATTERY_CHANGED` 的 level/scale/status/plugged；可加 `isPowerSaveMode` | `{level, scale, percent, status, plugged, powerSaveMode}` | 讀不到就不 flag；不得寫 100% 或「正常」 |
| （不是 battery） | `onTrimMemory` 是記憶體壓力，不是本契約的 battery/thermal check | 不映射 | 不要為了湊 flag 把 trim memory 當 battery |

mobile campaign 的 caller 必須是 host/App 層，模型不能傳入/覆寫讀數；`observeMobile` 的
`evidence` 只是 host 已讀到的值，不是模型可偽造的工具參數。

## 5. Swift 最小修正（bug fix）

1. `BotWatchdogConfig`：synthesized decoder 要求 13 欄全在，與「optional + defaults」衝突。新增
   `init(from:)` 套缺省，並把負數/`null`/未知成員變成明確 decoding failure；`0` 保留 disable。
2. `BotWatchdogMonitor.emit`：`watchdog.flagged.data` 原本沒有 `sessionId`/`at`，與 D7 flag payload
   衝突。寫入這兩欄，`BotWatchdogFlag` 同步帶 `sessionId`；event id/once 演算法不變。
3. `BotContextLintThresholds`：加入 defaulting `Codable` decode，讓 shared fixture 的部分 thresholds
   可直接驅動真實 lint；lint 的 `positive`/`max` coercion 不變。

這三個都是把既有 Swift 行為/預設暴露成契約所需的最小修正，沒有改 watch/stop、event type、store
schema 或 lint 規則。

## 6. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| PC-20261113-bot-watchdog-d7 | C9 coordinator | D7 `spec-partial`；凍結 config/units/flags/mobile/lint 與 CCR-1..CCR-6 | Swift（本 lane 對拍）、Kotlin W1/B4（not started，讀 golden）、P08/P18 owner（mobile 接線待決） |
