<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-w5-tool-catalog-roundtrips — W5 model-layer efficiency

## 0. 摘要

```yaml
change: PC-20261112-w5-tool-catalog-roundtrips
contracts: [P06, P16, P17, P26]
status: frozen
breaking: false
version_decision: 無 wire／proto 版本變更。`tool-catalog.schema.json` 只新增可選 `tiers` 與 item 的可選 `tier`/`requires`（舊 catalog 省略即舊行為）；不新增工具、不改 p0/p1 enum、不改 MCP frame；volatile time 精度是渲染語義；identity/approval/cancel 只合併往返，審批次數與安全檢查不變；model-purpose 執行點是宿主既有請求入口；profile 只改配置，不改 DSH 源碼。
base: d988108c1ec0c56903d6087c282cc9278bbdfd19
contract_revision: 見交接 head（本單與 spec 同一 commit）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  - **工具目錄分層（P26/P06）。** 現況：約 67 個工具每步全量發送；`ADBMCPServer.swift` 無條件列出 26 個 Android 工具，`BotMCPHandler` 把原生工具全併入，BLE 與 `iphone_agent_run` 同理；模型在設備未連上時仍看到全部。期望：core 常駐；device 類只在該類已連接或已配置時列出；連接狀態真正變化後的下一次 `tools/list` 立即反映；discoverable 仍列出（schema 完整可呼叫）但描述壓成一行。不能出現「模型找不到工具」；設備剛連上後下一步就能用。
  - **volatile 時間塊（P26）。** 現況：`volatile-context.ts` 把時間精確到分鐘，長任務裡約每分鐘往歷史追加一份完整易變上下文；上游 `dsh-time-context` 也注入一份。期望：時間塊只精確到小時（`YYYY-MM-DD HH:00`），profile 對掛載 bot-runtime 的 scope 關閉上游 `dsh-time-context`，只由本塊注入；不改 DSH 源碼。
  - **每次工具調用的往返（P17/P26）。** 現況：`identity-bridge` 與 `approval-gate` 對 bash、write、edit 與每個 Bot 手機工具做「註冊身份 → 審批 → 執行 → 取消註冊」3–4 次串行 loopback；取消還要等完才把結果交回模型。期望：可以合併往返，但每次調用恰好一次登記、一次審批決定、一次執行；審批次數與安全檢查一條都不少；取消不阻塞結果、只投遞一次。
  - **volatile 獲取（P26）。** 現況：每步之前用一次完整手機工具調用取上下文並阻塞該步。期望：內容未變時不重取（版本或摘要判斷），不阻塞。
  - **model-purpose 策略（P26）。** 現況：`BotModelPurposePolicy.assertModelAllowed` 沒有調用方；驗證器花費記成 `worker-turn`。期望：在宿主唯一的模型請求入口、解析憑據／開 socket 之前強制執行；壓縮、標題（`triage`）、驗證器（`completion-check`）走小模型；驗證器帳本記 `completion-check`。
  - **驗證器取證（P06）。** 現況：`BotDSHRemoteRuntime` 用 `events(after: 0, limit: 1_000)` 取最舊 1000 條，新會話拿不到證據。期望：按 subject 會話取最新事件窗口；證據不足時 `uncertain`，不用舊事件冒充；加回歸。
  - **PTC 可行性（不在本輪開啟）。** 寫 `docs/research/ptc-on-phone-feasibility-20261112.md`，說明在手機 Worker 開啟 `ptc-runtime`、`workflow-ptc`、`tool-workflow` 需要什麼、風險、怎麼驗證；profile 維持 disabled。
- **Coordinator / contract owner**：`contracts`。**Implementer**：`w5-model`（`Sources/PhoneDSHBot/{MCP,Ledger}`、`Sources/PhoneDSHADB`、`BLE/DeviceMCPServer.swift`、`Sources/PhoneDSHVenus`、`plugins/{bot-runtime,profile}`、`Tests/PhoneDSHBotTests/MCP`、`Tests/PhoneDSHADBTests`、`Tests/PhoneDSHVenusTests`、`docs/research`）；不改 `Sources/PhoneDSHBot/Store`、`spec/`。
- **Owning spec / fixtures**：[bot/v1/README.md](../../spec/bot/v1/README.md) §2（分層）、§2.1（時間／單次注入）、§2.2（往返合併）、§2.9（model-purpose 與驗證器取證）；[tool-catalog.schema.json](../../spec/bot/v1/schema/tool-catalog.schema.json) 的 additive `tiers`；`golden/tool-catalog-tiers.phone.json`、`golden/volatile-context-time.phone.json`、`golden/model-purpose-enforcement.phone.json`；`validate_vectors.py` 與 `check_golden.py` 已登記為 phone-only vectors。
- **受影響 producer / consumer**：Swift 宿主（Bot MCP catalog、ModelGateway 請求入口、Ledger）、Worker/TS（identity-bridge、approval-gate、volatile-context）、Android（ADB MCP 與 device catalog）、Venus/BLE。Android/HarmonyOS 沒有 Bot runtime 的部分記 `not started`。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| Tool catalog 分層 | 全量 → `tiers.core` 常駐、`tiers.device[].class` 按連接/配置、`tiers.discoverable` 常駐但精簡描述；`p0`/`p1` 仍是完整清單，`tiers` 是 additive 分組，一個工具只屬於一層。 |
| Device 連接狀態 | 無 → 每次 `tools/list` 由當前連接/配置狀態計算；真正變化後下一次 list 立即反映；不新增 `notifications/tools/list_changed`，不因單請求抖動。description/schema 不得因分層被刪到模型無法調用。 |
| Schema 影響 | 無 → `tool-catalog.schema.json` 新增可選 `tiers` 與 item 的可選 `tier`/`requires`；舊 catalog 不帶它們仍合法，p0/p1 enum 不變。 |
| volatile 時間精度 | 分鐘 → 小時桶 `YYYY-MM-DD HH:00`，保留時區偏移；長任務最多每小時變一次。 |
| 重複注入 | 上游 `dsh-time-context` + bot-runtime 各一份 → 掛載 bot-runtime 的 profile scope 關閉上游行，只留本塊；普通工作台保留上游行。只改 `plugins/profile` 配置，不改 DSH 源碼。 |
| volatile 獲取 | 每步阻塞取一次 → 內容未變（revision/摘要相同）不重取；取不到時用空快照，不沿用可能陳舊的內容。 |
| 身份／審批／取消 | 3–4 次串行往返 → 可合併，但每次工具調用仍恰好一次 identity 登記、一次 approval 決定、一次執行；登記在審批前、審批在執行前；取消在結果之後、非阻塞、只投遞一次；審批次數與安全檢查不變。 |
| model-purpose 執行點 | `assertModelAllowed` 無調用方 → 宿主唯一模型請求入口，在解析憑據／開 socket之前；無 purpose fail-closed。`front-turn`/`worker-turn` 允許大模型；`triage`（含標題）、`memory-extract`、`reflect`、`compact`、`watchdog`、`completion-check`（驗證器）、`memory-maintenance` 只允許小模型。 |
| Ledger | 驗證器記 worker-turn → `completion-check`；未知 purpose 記錄原值、不崩潰、不放大模型。 |
| 驗證器取證 | 最舊 1000 → subject 會話最新窗口；證據不足 `uncertain`，不把舊事件當本次證據。 |
| 用戶可見 | 無新增；工具分層不得產生「工具不可用」提示；時間塊是模型上下文，不是 UI。 |
| PTC | disabled → 本輪仍 disabled，只寫可行性報告。 |

自檢（baseline §5.1）：`tiers` 是 additive、可選、有缺省（舊 catalog = 無分層）；沒有新增工具或 enum 值；沒有第二個 catalog；沒有放寬審批或跳過安全檢查；沒有任何 DSH 源碼 patch。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；測試 |
| --- | --- |
| old → new | 舊 catalog／舊 volatile 快照照舊讀：新 schema 的 `tiers` 可選，舊 producer 不送也不影響；新 consumer 省略 `tiers` 時退回全量（不因缺少分層而丟工具）。時間塊變小時桶只影響模型看到的文字。 |
| new → old | 新 catalog 帶 `tiers`，舊 consumer 忽略 unknown member，仍看到 p0/p1 全部工具；不會因為分層而少工具。新 volatile 只改文本。新 identity/approval 合併只少往返，舊宿主/舊 Worker 仍走舊管線。 |
| new → new | 兩端用同一 `tiers` 與 `catalogVersion`；連接狀態變化下一次 list 同步；同一 volatile revision 不重取；model-purpose 在請求入口一致。 |
| persisted old data → new／rollback | 沒有持久化 catalog 或 model-purpose 資料格式變更；舊 UserDefaults/JSON 照讀。回滾到舊版：舊版忽略 `tiers`，看到全量工具；時間塊回到舊分鐘精度（不是資料損壞）。PTC 仍 disabled。 |

- **版本決定**：無 proto／wire 版本變更。`tiers` 是 schema additive optional；p0/p1 enum、MCP frame、`model-purpose-policy.schema.json` enum 都不變（標題沿用 `triage`，驗證器沿用 `completion-check`）。時間精度是 Worker 渲染規則，不是 wire member。
- **部署順序**：App 與 Worker 同 bundle 是支持組合；舊 App + 新 Worker 仍看到舊 catalog 全量、舊審批管線；新 App + 舊 Worker 仍由宿主在請求入口執行 purpose 與 ledger（Worker 只送模型請求）。Tool catalog 的連接狀態變化會讓上游重啟請求序列、影響 prompt cache，因此只在真正連接變化時變，不按請求抖動。
- **仍保留的差異**：Android/HarmonyOS 沒有 Bot runtime 的分層與 model-purpose 執行點；本輪記 `not started`，不得用 Swift/TS 測試宣稱已覆蓋。PTC 只做報告，profile 保持 disabled。

## 4. 分工與證據

- **獨占路徑（contracts）**：`spec/bot/v1/README.md` §2/§2.1/§2.2/§2.9、`spec/bot/v1/schema/tool-catalog.schema.json`、三個 `.phone.json` golden、`spec/bot/v1/tools/validate_vectors.py`、`spec/tools/bot/check_golden.py`、`spec/bot/v1/export-manifest.json`、本單。
- **w5-model 路徑**：`Sources/PhoneDSHBot/MCP/**`、`Sources/PhoneDSHBot/Ledger/**`、`Sources/PhoneDSHADB/**`、`Sources/PhoneDSHBLE/DeviceMCPServer.swift`、`Sources/PhoneDSHVenus/**`、`plugins/bot-runtime/**`、`plugins/profile/**`、`Tests/PhoneDSHBotTests/MCP/**`、`Tests/PhoneDSHADBTests/**`、`Tests/PhoneDSHVenusTests/**`、`docs/research/**`。不得改 `Sources/PhoneDSHBot/Store` 或 `spec/`。
- **共享 fixtures**：`tool-catalog-tiers.phone.json`（core/device/discoverable、連接狀態、stale listing、duplicate tier）、`volatile-context-time.phone.json`（小時桶正反例）、`model-purpose-enforcement.phone.json`（小模型/大模型、空 model、未知 purpose）。
- **Exact commands → result**（Linux 容器）：
  - `python3 spec/bot/v1/tools/validate_vectors.py` → PASS（tiers 1 valid/5 invalid、volatile 1/3、purpose 6/5）。
  - `python3 spec/tools/bot/check_golden.py --root .` → PASS（34 files、16 upstream、18 overlays）。
  - `python3 spec/v1/tools/spec_golden.py --full` → PASS（102 files，0 error）。
  - `cd plugins && npm run typecheck` → NOT_RUN（依賴未安裝；由呼叫方或 `w5-model` 執行）。
  - `cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"` → NOT_RUN（同上）。
  - `swift test --filter 'PhoneDSHBotTests|PhoneDSHADBTests'` → NOT_RUN（Linux 無 Apple Swift 工具鏈）。
- **未執行**：56 場景 G2 批次、工具目錄實際 bytes、真機模型 E2E、PTC 可行性實測；一律 NOT_RUN／NOT_VERIFIED。
- **風險／GAP**：分層依賴連接狀態的單一來源；若 ADB/BLE/Venus 各自快取，會出現「剛連上但下一步還看不到」。`tiers` 與 p0/p1 可能漂移，fixture 的 duplicate/core-missing 負例是防線。manifest 的 phone-only vector 清單與 digest 必須一起更新，否則 `check_golden` 會拒絕。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts | 初次凍結工具分層、時間精度、往返合併、model-purpose 執行點與驗證器取證 | all（contract freeze 公告） |
