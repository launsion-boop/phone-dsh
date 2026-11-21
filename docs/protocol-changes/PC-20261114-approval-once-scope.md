# PC-20261114-approval-once-scope — destructive/unclassified 审批的「总是」= 已消费的一次性

## 0. 摘要（機器可讀）

```yaml
change: PC-20261114-approval-once-scope
contracts: [P26, P27]
status: implemented
breaking: false
version_decision: no version bump. `/approval` 的请求/响应成员与枚举（`alwaysScope: until|session|none`、`scope: once|session|until`）都没有变；收紧的是「always」在 destructive / `tool.unclassified` 效果上的**有效** scope：可以是 `once`。旧 reader 只是少拿到常设 grant，下一次会再被问一次（fail-closed），不需要协商或分叉格式。
base: 139d1026d5cc6f31fa92d890f47c563c43106580
contract_revision: spec/bot/v1/mcp-endpoint.md §8.3/§8.4, spec/bot/v1/tool-contracts.md §6, spec/bot/v1/golden/identity-approval-cases.phone.json @ fix/spec-sync（本 commit 凍結）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。** baseline `139d1026d` 上 `swift test --filter BotMCPIdentityApprovalCasesTests`
  紅：`valid[5] approval-always-until` 與 `valid[6] approval-always-session` 期望 `scope: until|session`，
  實得 `once`；`BotApprovalResultTextTests` 另有 2 條斷言期望 session 文案。根因是 `b2dadbcb9`
  （`fix(authz): keep destructive and unclassified approvals one-shot`）刻意把 destructive 與
  `!effect.known` 的 `.always` 收緊成一次性，但 golden 與兩條測試文案沒跟上。**期望**：以 code 的
  一次性規則為準（安全收緊），golden/文案改成同一個口徑，並把 owning spec 寫清楚「always 何時仍給常設
  grant、何時只給一次」。
- **Coordinator / contract owner：** 本 lane（`fix/spec-sync`）。**Implementers：** Swift 端已由
  `b2dadbcb9` 合入（`BotApprovalCoordinator`、`BotToolEffects.canUseStandingGrant`、
  `BotEgressEffects`）；本 lane 只改 spec、golden/manifest、測試期望與一個與此相關的既有回歸。
  **Reviewer-integrator：** 父整合 head。
- **Owning spec / schema / shared fixtures：** `spec/bot/v1/mcp-endpoint.md` §8.3/§8.4（P26 的 `/approval` 路由；
  request/outcome 表）、`spec/bot/v1/README.md` §1.1/回執段、`spec/bot/v1/tool-contracts.md` §6
  （`RequestApproval`）、`spec/bot/v1/golden/identity-approval-cases.phone.json`、
  `spec/bot/v1/export-manifest.json`（digest）。
- **受影響 producer/consumer：** P25/P26 Swift `Sources/PhoneDSHBot/Authz/{BotToolEffects,BotEgressEffects,
  BotGrants}.swift`、`Sources/PhoneDSHBot/MCP/{BotApprovalCoordinator,BotMCPRuntime}.swift`；App 审批卡
  （`examples/probe-app/PhoneDSHProbe/Bot/BotWorkCardView.swift`，見 §4 剩餘風險）；Kotlin 尚無
  `/approval` 實作；P25 durable 事件仍是既有 `approval.requested`/`approval.decided`。

### 1.1 權威判定（證據）

1. **Commit 意圖。** `b2dadbcb9` 的訊息與 diff 明確寫著 "keep destructive and unclassified approvals
   one-shot"；同一 commit 在 `BotToolEffects.canUseStandingGrant` 的註解寫明 "Unknown tools are never
   widened. Destructive ... stay exact"；`BotApprovalCoordinator.request` 把卡片提供的 scope 改成
   `effects.allSatisfy(\.canUseStandingGrant) ? alwaysScope : "none"`，`resolve` 對 `!effect.known`
   直接強制 `.once`。
2. **變更單。** 同一 commit 更新了既有權威變更單
   [`PC-20261113-approval-scope-and-haptics`](PC-20261113-approval-scope-and-haptics.md) 的 P26 條目：
   「`canUseStandingGrant` 是安全閘門……Destructive operations and `tool.unclassified` stay
   exact-resource; **their cards offer no `always`（`alwaysScope=none`）**, and unclassified `.always`
   is forced to a consumed once.」這是 contract owner 在變更單裡已記錄的決定。
3. **Owning spec。** `mcp-endpoint.md` §8.4 在本 lane 之前已寫：「An `alwaysScope` of `"none"` is
   accepted for every tool and **resolves an `always` decision to a one-shot grant**」；§8.3 的
   outcome 表則只寫了 `always + until → until`，沒有 destructive/unclassified 的例外——**這是本 lane
   修正的規範缺口**，不是「golden 才是權威」的證據。
4. **Golden 的 delta。** `identity-approval-cases.phone.json` 的 `delta` 只說「request 的 expected scope
   是 until/session，`none` 可作一次性覆寫，sandbox escalation 要 `none`」——它描述的是 **request 驗證**，
   不是 outcome 的有效 scope；兩個案例的 `expect.scope` 才是漂移的部分。`source` 說這是 phoneDSH-only
   golden（`upstream: []`），沒有上游 exporter 可以「自動重寫」，只能由 contract owner 改並重算 manifest。
5. 因此 **code 的一次性規則是權威**；golden/測試是 stale。反向解讀（把 code 改回 until/session）會讓
   `tool.unclassified` 的「總是」重新覆蓋同一工具的所有未來呼叫，正是 `b2dadbcb9` 修掉的安全洞，
   且違反 `AGENTS.md` §2.3「不得為了讓平台變綠而放寬契約」。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| 卡片提供的 scope | 一律等於 request 的 `alwaysScope` → 只有**每個** effect 都能用常設 grant 時才等於 request；否則 `alwaysScope:"none"`（`mcp-endpoint.md` §8.4）。 |
| `canUseStandingGrant` | 新判定：`known == true` 且（`mutability == external-send` 或 `grantResource != nil`）。destructive bash/memory、missing `file_path` 的 write/edit、以及 `tool.unclassified` 都 false。 |
| always 的有效 scope | destructive 與 `known:false`：**`once`**（已消費的一次性，stored resource = exact resource）；其餘 eligible effect 維持 `until`/`session`（`mcp-endpoint.md` §8.3/§8.4）。 |
| `/approval` 的 `session` | request 層的 `session` 只成立於「所有 effect 都未知」；這些 effect 又不能拿常設 grant，所以經 `/approval` 的 outcome **不會**再出現 `scope:"session"`（表已改寫）。 |
| 使用者可見結果 | 這些卡不再提供常設答案；按「總是」= 這次放行、下一個同類呼叫再問一次。卡片結算顯示「已允許一次」（status `allowed`），不是常設回執（`README.md` 回執段不變：回執跟隨實際按下的按鈕/有效 scope）。 |
| `RequestApproval` | 工具結果文案：`always` + `once` 走預設句「用户已允许，可以继续。」；`until`/`session` 的常設句仍存在且被測試鎖住，只是這個工具不再走得到（`tool-contracts.md` §6）。 |
| golden | 兩個 always 案例的 `expect.scope` 改為 `once` 並加 `note`；新增 `approval-always-file-until`（`write` 到工作區外，`grantResource` = 父目錄）證明 eligible effect 仍拿到 `until`；delta 追加一次性規則。`export-manifest.json` 重算該檔 digest。 |
| 條款狀態 | `mcp-endpoint.md` §8.3/§8.4、`tool-contracts.md` §6 為 `implemented`（Swift）；Kotlin `not started`；App 按鈕仍是舊三選一（§4）。 |

**自檢（spec/README.md §5.1）：** 沒有新欄位、新錯誤碼、新 enum 或第二種 envelope；`alwaysScope:none` 與
`scope:once` 都早已在 §8.4/§8.3 凍結。這是**收緊**（原本非法的常設 grant 變成一次性），不是放寬；舊 client
送 `until`/`session` 仍被接受（request 驗證語義不變），只是 outcome 的 `scope` 可能是 `once`——客戶端本來就
必須讀回應的 `scope`，不能假設等於 request。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old client → new host | destructive/unclassified 卡送 `alwaysScope:until|session` 仍通過 request 驗證（expected scope 不變），但回 `approvalDecision:"always", scope:"once"`；客戶端若照舊顯示常設回執，最多是文案不符，下一次仍會被問（fail-closed，不會越權）。golden `approval-always-until`/`approval-always-session` + Swift `BotMCPIdentityApprovalCasesTests` 覆蓋。 |
| new client → old host | 舊 host 的卡可能仍給 `alwaysScope:until/session`；新 client 只渲染 host 給的卡，不改請求，得到舊的常設 scope——沒有分叉格式。 |
| new → new | 卡提供 `none` → App 以 `none` 送 always（或照舊送 until，仍被收緊）→ `scope:once`；`approval-always-file-until` 證明 eligible effect 仍是 `until`。 |
| persisted old data → new／rollback | 不遷移。既有常設 grant 仍可讀（`BotGrants` 保留讀舊 `resource="*"` 的分支，只讀不寫）；本變更不重寫任何 grant。回滾到舊 App/Worker：新寫入的一次性 exact-resource grant 仍是合法 grant，舊代碼可讀，只是「always」再次變成常設。 |

- **版本／adapter 決定。** 不升 MCP/Bot event/SQLite 版本；`/approval` 的 request/response schema 與錯誤碼不變。
- **bundle／image／native artifact。** 不涉及。
- **`target`／`draft` 條款中保留的差異。** 無。

## 4. 分工與證據

- **本 lane 的獨占路徑：** `spec/bot/v1/{mcp-endpoint.md,tool-contracts.md,golden/identity-approval-cases.phone.json,
  export-manifest.json}`；`Tests/PhoneDSHBotTests/MCP/{BotApprovalResultTextTests.swift, BotApprovalExpiryRaceTests.swift}`；
  `Sources/PhoneDSHBot/MCP/BotApprovalCoordinator.swift` 的 `expireDurable`（§4.1）；本變更單。
- **共享 fixtures：** `identity-approval-cases.phone.json` 11 valid / 17 invalid；新增
  `approval-always-file-until`，改寫 `approval-always-until`/`approval-always-session` 的期望與 delta。
  `validate_vectors.py` 的 identity 驗證與 6 個 mutation 全過（digest 按 canonical JSON 重算）。

### 4.1 同時修掉的既有回歸（非本契約 delta）

`approval-pending-expired` 在 base 也紅：durable todo 到期後 `durableStatus`/`resolve` 回 `unknown`。
根因不是「pending 記錄丟了」，而是 `BotApprovalCoordinator.expireDurable` 先 `pending.removeValue`，再
`await eventWriter.append(...)`，最後才 `record(notice)`；append 的 async hop 期間兩個讀取都看不到
pending 也看不到 decision，於是落到 `unknown_approval`（真機/測試都會撞到，非測試專屬）。

修復（最小）：先把 terminal `BotApprovalResolutionNotice` `record` 進內存，再 append durable
`approval.decided`；expiry 的真相不依賴 audit append 是否成功（失敗時內存仍是 expired，重啟由
`ensureRestored` 從 `approval.requested` 重新判定過期）。`resolve` 的「append 成功才記決定」順序不變
（失敗要撤 grants 並回 `stale(audit_failed)`）。回歸測試
`BotApprovalExpiryRaceTests.testExpiredDurableApprovalIsNeverUnknownWhileTheAuditAppendIsInFlight`
用一個會暫停 `approval.decided` append 的 `BotEventLog`，在 append 掛起時斷言 `durableStatus == .expired`、
`resolve == .stale("expired")`，append 放行後 durable 事件仍落盤。

### 4.2 Exact commands → result

- `swift test --filter 'BotMCPIdentityApprovalCasesTests|BotApprovalResultTextTests'` → **PASS**（8 tests / 0 failures）。
- `swift test --filter 'BotMCPIdentityApprovalCasesTests|BotApprovalResultTextTests|BotApprovalExpiryRaceTests'`
  → **PASS**（9 tests / 0 failures）。
- `python3 spec/bot/v1/tools/validate_vectors.py` → **PASS**（identity 11 valid / 17 invalid / 6 mutation；其餘子樹結果見整合報告）。
- `python3 spec/tools/bot/check_golden.py --root .` → **PASS**（47 files / 16 upstream / 31 overlays；identity digest 已重算）。
- `bash scripts/ci/check.sh --only phone-spec` → 見整合報告（本 lane 實測結果以該命令輸出為準）。

### 4.3 剩餘風險

- **App 審批卡仍畫「總是允許」按鈕**（`BotWorkCardView.swift:263,338` 只分 `session`/其他，沒有把
  `alwaysScope == "none"` 隱藏或改成一次性文案）。按下去得到 `scope:once`，回執顯示「已允許一次」，
  但按鈕本身仍暗示可以常設。這是 `examples/probe-app/**` 的 UI 缺口（本 lane 規則禁止改該樹），需由 App lane
  在 `alwaysScope == "none"` 時隱藏該按鈕或明示「這一次」。
- `RequestApproval` 的常設文案分支（`session`/`until`）在 `/approval` 路徑已不可達，只在工具結果的
  copy table 裡保留並由 `BotApprovalResultTextTests` 鎖住；若日後讓 `approval.weak-action` 可常設，需重開本單。
- Kotlin `/approval` 尚未實作；Harmony 無 Bot runtime。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | `fix/spec-sync`（contract owner） | 判定 `b2dadbcb9` 的一次性規則為權威，同步 §8.3/§8.4、`tool-contracts.md` §6、golden/manifest 與兩條測試文案；附帶修 `expireDurable` 的 `unknown_approval` 競態（非契約 delta）；無 CCR | P26 Swift（已實作）；App 卡（需跟隨，見 §4.3）；Kotlin（not started）；父整合 head |
