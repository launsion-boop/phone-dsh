# PC-20261114-card-superseded-and-pending — 一张卡只有一条过期真相、可见的待送与提前的回答

## 0. 摘要（機器可讀）

```yaml
change: PC-20261114-card-superseded-and-pending
contracts: [P27, P09]
status: implemented
breaking: false
version_decision: no wire/schema/event-type/version bump. `status:"superseded"` 与 `supersededBy` 是 row body 里的两个值，`row.schema.json` 的 body 本就 `additionalProperties: true`；`chatActionNonce = card-answer:<nonce>` 只在内存里，不落 JSON、不进 durable 事件。旧 reader 不认识新 `status` 时按原样渲染完整卡片，planner 仍以既有 `card_expired` 拒绝点击（旧错误码，未新增枚举或第二个码）。
base: 139d1026d5cc6f31fa92d890f47c563c43106580
contract_revision: spec/bot/v1/projection.md §4.4 step 15 + §6.4, spec/ui/v1/bot/ui-state.md §3.1 + §4.3 + §4.4 @ fix/spec-sync（本 commit 凍結）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。** 真机 Bot 页与 `BotRemoteActionPlanner` 各有一套 question/steps 过期规则：
  planner 在更新的提问/步骤卡出现时拒绝所有更旧的卡（`card_expired`），页面却只把「最后一条用户文字之前」
  的卡灰掉。结果是同一张卡可以看起来可点却被拒，或者看起来过期却仍可回答；点击后到整个回合结束前没有任何
  反馈，durable `card.answered` 只在回合最后一帧之后才写入（真机测量：01:44:15 点击，01:46:21 才提交，
  比回合结束还晚一秒）。**期望**：一张 choice card 的过期只有一条真相（更新的 question/steps 卡在同一个
  Bot 流里永久取代它），页面与 planner 读同一个判定；点击立刻可见（spinner + 「正在送出…」），乐观回显
  `local-<nonce>` 由 durable 用户行退休、失败回滚；拒绝原因以人话显示在卡片上，不进头部问题行；checklist
  保留原有的发送时提示，question/steps 不再由本地启发式静音。
- **Coordinator / contract owner：** 本 lane（`fix/spec-sync`，worktree `/tmp/pdsh-fix-spec`）。
  **Implementers：** 代码已由 `fix/card` lane 在 `2703c5d49` 合入 `integrate/all`；本 lane 只补
  owning spec、strings anchor、共享向量与 checker。**Reviewer-integrator：** 父整合 head，须在本 commit
  的 head SHA 上确认 Swift projection/planner/App 与 `ui-state-vectors.json`、`strings.json` 处在同一 revision。
- **Owning spec / schema / shared fixtures：** `spec/bot/v1/projection.md`（§4.4 step 15、§6.4）、
  `row.schema.json`（body 仍开放，未改）、`spec/ui/v1/bot/ui-state.md`（§3.1、§4.3、§4.4）、
  `spec/ui/v1/bot/strings.json`、`spec/ui/v1/bot/golden/ui-state-vectors.json`、
  `spec/ui/v1/bot/tools/{check_bot_ui.py,test_check_bot_ui.py}`、`spec/ui/v1/pages/bot-chat.md`。
- **受影響 producer/consumer：**
  - P27 Swift projection：`Sources/PhoneDSHBot/Rows/BotSessionLogProjection.swift`
    （`BotChoiceCardStaleness.supersededCards(in:botID:)`、`status/supersededBy` 写入、
    `chatActionNonce` 增加 `card-answer:`）。
  - P27 Swift planner：`Sources/PhoneDSHBot/Rows/BotRemoteActionPlanner.swift:233` 复用同一 predicate。
  - P09 iOS reference：`Sources/PhoneDSHBot/UI/BotChoiceCardUI.swift`（新文件：pending/refusal/echo 纯值）、
    `examples/probe-app/PhoneDSHProbe/Bot/{BotChatModel.swift,BotCardView.swift}`。
  - P09 向量/checker：上列 spec 文件（本 commit）。
  - Android/Kotlin：`android/lib/.../ui/bot/state/BotDerivedState.kt` 仍是旧 settlement 规则（见 §4 剩余风险）；
    `BotUiStrings.kt` 是 `strings.json` 的生成物，新增 id 后必须重生成。
  - P25/P26：无 durable 事件类型、schema、工具面或 card payload 变更；`tool.unclassified` 的审批范围是另一张单
    （`PC-20261114-approval-once-scope`）。

## 2. 契約 delta

只列改動；未變語義引用 owning clause，不複製整份協議。

| 項目 | Before → After／依據條款 |
| --- | --- |
| choice card 過期判定 | 頁面本地「最後一條用戶文字之前」+ planner「更新的卡出現」兩套 → **一條**：同一個 Bot 流裡，新的 question/steps `card.presented` 永久 supersede 所有更早仍開著的 choice card；在更新的卡之前已回答/關閉的卡本來就閉合，不標記；其他 Bot 忽略；只對 question/steps（`projection.md` §6.4）。 |
| row body | `status:"answered"` 之外新增 `status:"superseded"` 與 `supersededBy:"<newer card id>"`；**answered > superseded**（有 answer 的卡寫 answered，不帶 supersededBy）；dismissed 仍直接不投影。兩者都只是 body `additionalProperties`，schema 不改（`projection.md` §6.4）。 |
| 卡片 id/kind 來源 | `payload.id|rowID|card.id|card.rowID`，否則 `e-ui-<eventId>`；kind 取 `payload.cardType|kind|card.cardType|card.kind`。與 planner 讀同一組成員（`projection.md` §6.4）。 |
| planner 一致性 | `card_expired` 由同一個 `BotChoiceCardStaleness.supersededCards` 推導（`BotRemoteActionPlanner.swift:233`），灰掉的卡與被拒絕的卡不可能再分歧（P09 §4.3）。 |
| `chatActionNonce` | 原本只認 `user-action:<nonce>` → 現在同時認 `card-answer:<nonce>`（`source.kind == "user"`、nonce 至少一個非空白 scalar）。卡片點選因此與打字訊息用同一條 `local-<nonce>` 退休規則（`projection.md` §4.4 step 15；P09 §3.1/§4.3.2）。 |
| settlement 順序 | question/steps：superseded（durable，**即使本地 tap 是 pending/failed 也收）→ dismissed（本地 id 或 durable `dismissed`）→ answered（durable）→ `pending|failed` 保持完整卡片 → accepted（本地）→ 否則 nil。`mutedCardIDs` 不再參與 question/steps（`ui-state.md` §4.3）。 |
| `.pending` 形狀 | 完整卡片保留，被點的選項打勾，選項下顯示 spinner + 「正在送出…」；不 settle（`ui-state.md` §4.3.2）。 |
| 樂觀回顯 | 點擊立即插入 `local-<nonce>` 使用者行（`sendMessage`/`user`、trust `owner_direct`、`provenance ["local:<nonce>"]`、body 為 option value 否則 label、`seq = max+1`）；host 以 `card-answer:<nonce>` 發送選項值，durable user row 的 `chatActionNonce` 以同一 upsert 規則退休回顯；失敗回滾（`ui-state.md` §4.3.2）。 |
| 拒絕文案 | planner 拒絕碼（`card_expired`/`already_answered`/`answer_in_flight`/`card_dismissed`/`unknown_card`/`unknown_option`）→ 卡片上的人話；**禁止**寫入 `runtimeNotice`/頭部問題行。其他失敗仍是「未能送出：<reason>」。文案在 `BotChoiceCardUI` 並鏡像進 `strings.json`（`ui-state.md` §4.3.3）。 |
| 靜音 | `mutedCardIDs` 覆蓋 question/steps/checklist → **只覆蓋 checklist**；question/steps 的過期只由 durable `status` 決定（`ui-state.md` §4.4）。 |
| 條款狀態 | `projection.md` §4.4/§6.4 與 `ui-state.md` §4.3/§4.4 為 `implemented`（Swift reference + 共享向量經 checker 與 Swift 純函式）；Android 仍是 `partial`（settlement/strings 未跟隨，見 §4）。 |

**自檢（spec/README.md §5.1）：** 沒有新增 wire 欄位、事件類型、錯誤碼、enum 或工具名；`status`/`supersededBy`
是 row body 的值（body 早已開放額外成員），舊 reader 可忽略；`chatActionNonce` 從不序列化。沒有把「過期」
做成第二種表達——它是同一個 row 的 `status`，planner 用的是同一個函式。唯一「收緊」是 question/steps 不再被
本地啟發式靜音；這正是本次要修的兩套真相。checklist 的舊行為完整保留。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old reader → new projection | 舊 App/Kotlin 不認識 `status:"superseded"`，按原樣渲染完整卡片；點下去 planner 仍以既有 `card_expired` 拒絕，舊 reader 依既有失敗路徑顯示。沒有新欄位是 required，也沒有新事件。`ui-state-vectors` 的 superseded 案例驅動 checker；Swift `BotChoiceCardStalenessTests` 驅動真實 predicate。 |
| new reader → old projection | 舊 projection 不寫 `superseded`；新 view 因而看不到「被更新卡取代」的灰線，卡片保持完整可點——與舊行為一致（新 view 不再自己發明本地規則）。`card-answer:` nonce 只有新 projection 會帶；舊 projection 的點選回顯由 durable answered status 收掉（既有路徑）。 |
| new → new | projection、planner 同一個 predicate；App 依 durable status settle；`ui-state-vectors.json`（47 個投影案例 + 9 個 intentCases）與 `check_bot_ui.py` 的獨立實作 + Swift 純函式測試讀同一批資料。`BotChoiceCardStalenessTests`、`BotRemoteActionPlannerTests`、`BotChoiceCardUITests`、`BotUIProjectionVectorTests` 全綠。 |
| persisted old data → new／rollback | 不遷移：projection 是純函式、歷史在內存重建，舊 `card.presented`/`card.answered` 事件按同一規則重算；回滾到舊 App 仍能讀同一批事件與 row body（額外成員被忽略）。`chatActionNonce` 不落盤。 |

- **版本／adapter 決定。** 不升 P27 row schema、Bot event schema、SQLite schema 或 MCP 版本；`status` 是自由字串值。
- **bundle／image／native artifact。** 不涉及。
- **`target`／`draft` 條款中保留的差異。** 無；`projection.md` §6.4 與 `ui-state.md` §4.3/§4.4 直接改為現行 Swift 行為。

## 4. 分工與證據

- **本 lane 的獨占路徑：** `spec/bot/v1/projection.md`；`spec/ui/v1/bot/{ui-state.md,strings.json,
  golden/ui-state-vectors.json,tools/check_bot_ui.py,tools/test_check_bot_ui.py}`；
  `spec/ui/v1/pages/bot-chat.md` 的 settlement/文案兩句；本變更單。程式端（`Sources/**`、
  `examples/probe-app/**`）由 `fix/card` lane 在 `2703c5d49` 完成，本 lane 不重複修改。
- **共享 fixtures：** `ui-state-vectors.json` 新增 `question-superseded`、`question-superseded-pending`、
  `question-pending`、`question-answered-pending`、`checklist-muted` 五個案例；把舊的 `question-muted`/
  `steps-muted` 改名為 `question-before-user-text-open`/`steps-before-user-text-open` 並改期望（不再靜音、
  不再 settle、attention 各 +1）。`strings.json` 新增 `settlement.superseded`、`choice.pending` 與六個
  `choice.refusal.*` anchor，全部指向 `Sources/PhoneDSHBot/UI/BotChoiceCardUI.swift`；同時修好
  `BotChatModel.swift`/`BotChatPage.swift` 漂移的行號 anchor（本 lane 之前 `check_bot_ui` 在 base 即紅）。
- **各端真實 producer/consumer 測試：**
  - `python3 spec/ui/v1/bot/tools/check_bot_ui.py --root .` → **PASS**（491 checks/records，含 47 個投影案例 + 9 個 intentCases、
    126 條 string anchor、14 個 schema）。
  - `python3 -m unittest discover -s spec/ui/v1/bot/tools -p 'test_*.py'` → **PASS**（含新的
    `test_only_checklists_are_muted`、`test_superseded_card_settles_even_with_a_pending_tap` 與 mutation 測試）。
  - `swift test --filter 'BotChoiceCardStalenessTests|BotChoiceCardUITests|BotRemoteActionPlannerTests|BotUIProjectionVectorTests|RowProjectionGoldenTests|BotGoldenVectorTests'`
    → **PASS**（42 tests / 0 failures）：真實 predicate、planner 拒絕與向量純函式同一批資料。
  - App wiring（`BotChatModel.swift`/`BotCardView.swift`）是 app code，非 SwiftPM target；本 lane **NOT_RUN**
    App 編譯（見 §4 剩餘風險）。
- **剩餘風險／未支援平台：**
  - **Android 未跟隨：** `android/lib/.../ui/bot/state/BotDerivedState.kt` 的 settlement 仍是舊順序
    （pending 先於 durable status、question/steps 仍可被本地靜音）；`BotUiStrings.kt` 由 `strings.json`
    生成，本次新增 8 個 id（`settlement.superseded`、`choice.pending`、6 個 `choice.refusal.*`）後
    `BotUiStringsGoldenTest` 會因 id 集合不等而失敗。必須由 Android lane 重新生成該檔並按本 revision 實作
    settlement；本 lane 的規則不修改 `android/**`。
  - **App 端行為未由測試覆蓋：** `BotChatModel.choiceSettlement`、`appendChoiceEcho`、refusal 不進
    `runtimeNotice` 都在 `examples/probe-app/**`（非 SwiftPM target）；本 lane 只以 spec 向量 + strings anchor
    固定契約，未跑 iOS 編譯或真機。
  - **舊 anchor：** `ui-state.md` 其他章節仍有 freeze-base 行號（例如 §4.1/§4.5 的 `BotChatModel.swift`
    區間），本次只修 §4.3/§4.4 與 strings.json 的 live anchor；其餘行號未逐一重算。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | `fix/spec-sync`（contract owner） | 把已合入的 `2703c5d49` 行為補進 owning spec、strings/向量/checker；無 CCR | P27 Swift（已實作，無需改動）；P09 iOS（已實作）；P09 Android（需跟隨，見 §4）；父整合 head |
