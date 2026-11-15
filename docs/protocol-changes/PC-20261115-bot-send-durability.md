<!-- SPDX-License-Identifier: MIT -->

# PC-20261115-bot-send-durability — 发送先落盘、传输有界等待与队列代数围栏

## 0. 摘要（機器可讀）

```yaml
change: PC-20261115-bot-send-durability
contracts: [P25]
status: frozen
breaking: true
version_decision: Bot SQLite user_version 3 → 4。表本身是 additive（只新增 `bot_pending_actions`，v3 的 event/effect/nonce 行和位元組不動，沒有 wire/schema/event 型別/row 形狀變更），但 version bump 對 rollback 是 breaking：v4 檔案被 v3 build 以既有 `schemaTooNew` 拒絕，沒有 downgrade；rollback 只能還原更新前的 v3 副本或清除 Bot 資料，部署順序是新 build 先寫、舊 build 不再開同一檔案。
base: 484c1f99463d63424baeecd15410acfe71983823
contract_revision: this commit（凍結本單）；owning P25 條文 `spec/bot/v1/store.md` §2/§3/§7/§10/§11 與 `spec/bot/v1/golden/store.phone.json` 由 P25 outbox lane 依本單落地，commit 記在 §5。
```

本單只凍結 delta；本 lane 不修改 `spec/**`、golden、Kotlin 或 runtime code。owning 條文與 vectors 由 §4 指定的 lane 落地，任何與本單不同的欄位、版本或預設值都必須先以 `CONTRACT CHANGE REQUEST` 回到 contract owner，不能在實作裡靜默改。

Protocol impact: P25; P09: none — 本變更不改 `examples/probe-app/PhoneDSHProbe/**` 的 Bot UI、presentation、strings 或 `spec/ui/v1/**`；outbox 由背景 replay 消費，UI 沿用今天的 local echo 與既有 failure notice。顯式的 pending/retry presentation 與新 strings 是 follow-up（見 §2.3），不在本單凍結範圍; P26: none — 沒有 tool catalog、MCP endpoint、memory、wake、routine、ledger、watchdog 或 observability surface 變更，也沒有新增 durable event 型別; P27: none — `BotUserAction`/`BotActionResult` 形狀、`conversation.*` 事件型別與 data、row/projection schema、user-action/action-result schema 都沒有變，dispatcher 的 pre-dispatch outbox 寫入屬於 P25 §10.2 的提交順序，不是 P27 的 row 或 planner 變更; P14: none — `DSHRemoteTransport`/`DSHWebTransport` 與 `/api/remote.mux` bytes 不變，deadline 由 `PhoneDSHBot` 在既有呼叫外圍實施。

## 1. 識別與角色

### 1.1 Trigger → 現況 → 期望

**Trigger（bad build `484c1f994`，PR #177 整合）。** 安裝後，Bot 在 rebind 之後的 chat send 可以永遠不返回；宿主 journal 沒有這次發送對應的 `user/message`（`mseq` 不變），gateway 沒有模型請求，`domain.sqlite`/WAL 沒有 durable Bot event；kill app 後訊息消失。同一台機、同一段時間，一張 stale card answer「先到这」走 `cardAnswer`（planner 在送之前先 `performAndRecord(card.answered)`）仍然執行，證明 Worker/DSH 會話不是全域死亡，差別在 chat 的 persistence ordering 與 rebind 後的 queue/transport 等待。

**現況（base `484c1f994`）。**

- **chat 只在回合完成後才持久化。** `BotUserActionDispatcher.dispatch` 先跑 planner，`chat` planner 直接 `await remote.sendUserMessage(...)`，只有完成後才組 `conversation.turn_started` 並 `performAndRecord`（`Sources/PhoneDSHBot/Rows/BotUserAction.swift:198-222`；`BotRemoteActionPlanner.swift:70-72,154-176`）。hang/kill 發生在完成前，就沒有 durable event、沒有 nonce、沒有可重播的意圖。
- **queued turn 跨 transport generation 保留，沒有 fence。** `runTurn` 只按 sessionId 取 `queuedTurns[sessionId]?.work ?? coordinators[sessionId]?.work` 並 `await predecessor.value`（`BotDSHRemoteRuntime.swift:2534-2550`）；`attachTransport` adopt 時明文「keep every coordinator/queued entry」（`:312-343`），只有 coordinators 有 2 s bounded settle（`:396-412`）。queued Task 仍 suspend 在舊 predecessor 的 `Task.value` 上；`work.cancel()` 不能打斷一個 suspend 在 `mux.receive()` 或 transport 呼叫上的 task。新 send 因此在同一 session 上等到一個永遠不 settle 的舊 Task。
- **transport operation 沒有 deadline，`transportIsAttached` 不是 liveness。** `openMux`、`session/follow` snapshot、`session/prompt`、`collectTurn`、claim/create/page 都是無界 await（`:2578-2604,2649-2665,2667+`）。`transportIsAttached` 只由 adopt/detach 設定（`:197,278-280,316`），Worker 死後仍是 `true`；`BotRebindScope` 因此把該 unit 當 live 保留（`BotRebindScope.swift:38-49,77-83`；`BotRuntimeUnit.swift:308-312`），下一次 send 仍打在同一個死 transport 上。
- **UI 只有記憶體回顯。** `BotChatModel.send` 建立 `local-<nonce>` row 後呼叫 driver（`examples/probe-app/PhoneDSHProbe/Bot/BotChatModel.swift:611-657`）；`markAwaitingTurn` 的 120 s 只是隱藏狀態行（`:856-867`）。kill 後 local row 消失，沒有東西可以重播。

**期望。**

1. **Durable before dispatch。** `chat`/`cardAnswer` 在呼叫 planner 與任何 transport await 之前，先以一個 transaction 把待送 action 寫進 `bot_pending_actions`；寫入成功才開始 dispatch。kill/hang/rebind 造成的 retryable 中斷都留下 row，launch 後以同一 nonce/requestId 重播一次。
2. **Bounded transport awaits。** 每個 blocking transport operation 都有 deadline；逾時回一個可重試的 typed error，不再讓 rebind 或 send 永久 suspend。取消在 runtime 邊界生效，不依賴底層 transport 自願配合。
3. **Generation-fenced queues。** queue 只 join 同一 `transportGeneration` 的前驅；generation 變更時舊世代 queued turn 在下一次 20 ms 輪詢內以 `interrupted`/`transport_generation_changed` 結束（同步 fence，不等舊 predecessor），絕不 await 舊 predecessor。被丟棄的意圖由 outbox 在新 transport 上重播。
4. **Liveness 是掙來的、會失去的。** `hasLiveTransport()` 只有在 attached 且未被 quarantine 時為 true；mux 級失敗立即 quarantine，unary transport 連續兩次失敗 quarantine。下一個 bind 會重啟該 unit。
5. **UI 本輪不變。** outbox 由背景 replay 消費；UI 沿用今天的 local echo 與既有 failure notice。重播不得產生第二則訊息；retryable 失敗必須走既有的可重試 notice/header 路徑。顯式的 pending/retry presentation 與新 strings 是 follow-up，不在本單凍結範圍。

### 1.2 角色

- **Coordinator / contract owner：** 本 lane（`docs/bot-send-durability`，worktree `/private/tmp/pdsh-fix-docs`）。只寫本變更單與 receipt，不碰 `spec/**`、golden、Kotlin、runtime。
- **Implementer（transport liveness）：** `fix/bot-transport-liveness`，worktree `/private/tmp/pdsh-fix-transport`；獨占 `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`、必要的 `BotRebindScope.swift` 與其 tests。
- **Implementer（P25 outbox / store）：** `fix/bot-chat-outbox`，worktree `/private/tmp/pdsh-fix-outbox`；獨占 Swift store/dispatcher、`spec/bot/v1/store.md`、`spec/bot/v1/golden/store.phone.json`，以及 Android `:bot` store schema/migration（與 Swift 同一個 DDL，不含 replay 使用）。
- **Implementer（integration / replay wiring）：** `fix/bot-send-durability`，worktree `/private/tmp/pdsh-fix-integration`；只接 replay 啟動（composition/unit）與 P25 的 outbox wiring；不改 Bot UI、presentation、strings 或 `spec/ui/v1/**`（P09 本輪 none）。
- **Reviewer-integrator：** 父整合 head；必須在一個 head SHA 上確認 store v4、transport deadlines/queue fence、integration replay wiring、Android schema 四者對齊同一 revision；P09 UI 不在本輪 acceptance。

### 1.3 觀測證據（bad build）

以下為 2026-11-14 診斷時已在裝置上觀察到的事實，不是推論：

- 在 rebind 後送出的 chat 文字，**沒有**出現在 `PhoneDSHBot/domain.sqlite` 或其 WAL 的 event payload / nonce row 中；`bot_event_headers` 的 head 沒有為它增加。
- 宿主 journal 的 `mseq` 在發送前後不變，沒有這次發送的 `user/message`；gateway 沒有收到模型請求。也就是說，不是模型慢，也不是回合失敗，而是請求根本沒有被宿主接受。
- 同一段時間內，一張 stale card answer「先到这」走了 `cardAnswer`：planner 在送之前已寫入 `card.answered`，該回合確實執行。這排除了「Worker/DSH 全域死亡」，把差異收斂到 chat 的 persistence ordering 以及 rebind 後的 queue/transport 等待。
- kill app 後重開，該 chat 文字不出現在 transcript；card answer 的 durable `card.answered` 仍在。

### 1.4 Owning spec / fixtures / producer-consumer

- **P25 owning：** `spec/bot/v1/store.md` §2（open/user_version）、§3（DDL）、§7（migration）、§10（user-action transaction）、§11（vectors）；`spec/bot/v1/golden/store.phone.json`、`user-action-transaction.phone.json`。由 outbox lane 依本單更新。
- **P09：** 本輪 none。沒有 UI 狀態、`BotRuntimePresentation`、strings 或 `spec/ui/v1/**` 變更；outbox 由背景 replay 消費，UI 沿用既有 local echo/notice。pending/retry presentation 是 follow-up（§2.3），不是本單的 frozen 契約。
- **P27：** 不變；`BotUserAction`/`BotActionResult`、`user-action.schema.json`、`action-result.schema.json`、`conversation.*` 事件、row/projection schema 都不改。
- **Producer / consumer：**
  - P25 Swift：`Sources/PhoneDSHBot/Store/{SQLiteDomainStore.swift,SQLiteDomainStore+UserAction.swift}`、`Sources/PhoneDSHBot/Rows/BotUserAction.swift`（dispatcher）、`Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`（deadline/queue fence）。
  - P25 integration（replay wiring）：`examples/probe-app/PhoneDSHProbe/Bot/{BotRuntimeComposition.swift,BotRuntimeUnit.swift}` 接 launch/bind 後的 replay；不改 `BotRuntimePresentation`/`BotChatModel`/strings。
  - Kotlin：`android/bot/src/main/kotlin/com/phonedsh/bot/store/{BotDomainStore,BotStoreSchema}.kt` 只做 v4 schema/migration；本輪沒有 replay/outbox 使用，也沒有 Bot UI pending 變更。
  - DSH Worker / host / gateway / `Plugins`：不變。這是 App 本地的 store 與 runtime 排程，不是 wire。

## 2. 契約 delta

只列改動；未變語義引用 owning clause，不複製整份協議。

| 項目 | Before → After／依據條款 |
| --- | --- |
| P25 schema 版本 | `user_version` 3 → **4**。`0` = 新庫（直接建 v4）、`1/2` = 既有 v1/v2→v3 migration 後再 v4、`3` = v3→v4、`4` = current、`>4` = `schemaTooNew`。既有 `>3` 的 future-version 向量改成 `>4`（用 5 測）。 |
| P25 新表 | 只新增 `bot_pending_actions`（§2.1 的精確 DDL）。v3 的 headers/payloads/effects/nonces 行不重寫、不改 bytes、不改 `commit_seq`。 |
| durable-before-dispatch | `chat`/`cardAnswer` 在 planner 與任何 transport await 之前，先 commit outbox row；terminal 結果（accepted/duplicate/validation/planner stale 或 rejected/cancelled）清除，retryable rejected（rebind interrupt/timeout/unavailable/未知）與 throw/kill 保留。`cardDismiss`/`approval`/`stopTask` 不寫 outbox，維持原路徑（它們的 RPC/durable event 本身就是權威，自動重播可能重複副作用）。 |
| replay | launch 後、該 Bot 的 transport ready 之後，一次 launch 對每個 row 最多重播一次；同一 nonce、同一 requestId；nonce dedupe + DSH `requestId` dedupe；本輪不做 TTL / attempt cap：row 保留到 terminal outcome；`attempts` 僅供診斷；TTL/耗盡刪除＋`send-expired` notice 列為 follow-up（本輪不寫 notice）。 |
| P25 事件 | **沒有新增 event type**；`conversation.turn_started`/`card.answered` 的型別、eventId、data、寫入時機都不改。outbox 不消耗 `commitSeq`，不是第二種 event log。 |
| transport deadline | `openMux` 10 s、snapshot 15 s、`session/prompt` unary 20 s、turn-start 20 s、control unary 10 s、main-session recovery 30 s、collect idle 300 s、turn-start 20 s、adopt settle 2 s、queue fence 0 ms（§2.2，同步）。逾時回既有 `BotMCPError.unavailable`/`ProviderError.unavailable` 的可重試路徑，不新增 wire error code。 |
| queue fence | queued turn 攜帶 `transportGeneration`；只 join 同世代 predecessor；generation 變更時舊世代 queued turn 同步 settle `interrupted`/`transport_generation_changed`（queued 任務 20 ms 輪詢），不送 prompt，由 outbox 重播。 |
| liveness | `hasLiveTransport()` = attached && !quarantined。mux 級失敗立即 quarantine；unary transport 失敗連續 2 次 quarantine；成功 unary 呼叫或新 `attachTransport` 清除。quarantine 的 unit 在下一個 bind 被重啟。 |
| P09 | **none**。本輪沒有 UI/presentation/strings/vector 變更；outbox 由背景 replay 消費，UI 沿用今天的 local echo/notice。顯式 pending/retry presentation 是 follow-up（§2.3），不進 frozen 契約。 |
| 條款狀態 | `store.md` 的 v4 條文與 `ui-state.md` 的 pending 條文在本單 frozen 後由各 lane 落地；落地前維持 `frozen`，不得以 `implemented` 宣稱。 |

**自檢（spec/README.md §5.1）：** 沒有新增第二種 event、envelope、error code 或 alias。新表只有一個用途（本機待送副本），不參與 wire，也不改 nonce/event 的權威。新欄位都是新表的新欄位，沒有讓既有 producer 送新欄位；舊 consumer 不會讀這張表。沒有收緊或放寬任何兩端都讀的訊息。`>4` 的拒絕是既有 `schemaTooNew` 規則的版本值更新，不是新錯誤。唯一「刪除」是 outbox row 在 terminal outcome 後刪除，這不是協議資料。

### 2.1 P25：`bot_pending_actions`（SQLite v4）

精確 DDL（column/type/constraint/PK 名稱均為 normative；不得加 `state`、`expires_at`、`request_id` 等第二種表達）：

```sql
CREATE TABLE IF NOT EXISTS bot_pending_actions (
    bot_id TEXT NOT NULL,
    nonce TEXT NOT NULL,
    payload BLOB NOT NULL,
    created_at_ms INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (bot_id, nonce)
);
```

| Column | 語義 | 規則 |
| --- | --- | --- |
| `bot_id` | action 的 Bot | 非空；與 `payload.botID` 相同。與 `nonce` 組成 PK，同一 nonce 在兩個 Bot 是兩列。 |
| `nonce` | `BotUserAction.nonce` | 非空；PK 另一半；與 `payload.nonce` 相同。requestId 由 kind 決定：`chat` = `user-action:<nonce>`，`cardAnswer` = `card-answer:<nonce>`（既有 `BotTurnOrigin` 規則，不新增）。 |
| `payload` | `BotUserAction` 的 canonical JSON bytes | 與 `spec/bot/v1/user-action.schema.json` 同一形狀；`JSONEncoder` `.sortedKeys` + `.withoutEscapingSlashes`；不新增欄位。decode 失敗、`botID`/`nonce` 不匹配 = corrupt。 |
| `created_at_ms` | 首次 insert 的 runtime 時鐘（ms） | 預留 TTL（本輪未啟用）；不做 commitSeq。 |
| `attempts` | 已嘗試 dispatch 的次數 | insert 時 = 1（DEFAULT）；每次 replay 送出前 `attempts = attempts + 1`；最大 3。不是重試次數的獨立欄位。 |

**Retention / TTL / attempts（normative）：**

| 情況 | 行為 |
| --- | --- |
| insert | 在 planner 前、於 `SQLiteDomainStore` 的單一 transaction 內 `INSERT ... ON CONFLICT(bot_id, nonce) DO NOTHING`；commit 後才 dispatch。重複 nonce 保留第一筆 payload（第一筆是權威）。 |
| 非 throwing 結果 | **只清除 terminal 結果**：`accepted`/`duplicate`，以及 validation/planner 的 terminal `stale`/`rejected`（例如 `card_expired`、`already_answered`、`missing_text`、`untrusted_action`）和 `cancelled`（使用者主動停止）。**retryable rejected 必須保留**：`transport_replaced`、`turn_not_completed`、`turn_not_started`、`collect_idle_timeout`、`snapshot_timeout`、`transport_timeout`、`unavailable`、`runtime recovering`、`unit_detached`，以及任何未知 reason（fail safe）。這些是「回合沒完成」而不是「action 無效」；清掉 row 就等於把 rebind 後中斷的訊息丟掉。 |
| throw / kill | 保留 row；不寫任何「失敗」狀態，row 的存在就是 pending。 |
| TTL | **本輪未啟用（follow-up）**。row 保留到 terminal outcome；未來 TTL 到期才可刪 row 並寫 idempotent `send-expired:<botID>:<nonce>` notice。 |
| attempts 耗盡 | **本輪未啟用（follow-up）**。`attempts` 只做診斷，不因次數丟棄；未來才加 cap 與 `attempts_exhausted` notice。 |
| corrupt payload | 刪 row + notice（`reason:"corrupt_payload"`）；不因一筆壞 outbox 阻擋 launch/open。 |
| Bot 刪除 / erasure | 刪除該 `bot_id` 的所有 rows。`payload` 含使用者文字/附件路徑，erasure 必須覆蓋這張表（P25 erasure 新增一項；沒有新 event type）。 |
| 完整性掃描 | open 時不掃這張表；replay 逐列驗證。`payload` 不是歷史，壞列可以直接丟棄。 |

**Durable-before-dispatch 的精確順序（`BotUserActionDispatcher.dispatch`）：**

1. 既有 in-flight task / `bot_user_action_nonces` / `BotUserActionValidation` 檢查（不寫）。
2. 建立 in-flight task；task 的第一個 awaited step 是 outbox `INSERT`（在 planner 與任何 transport await 之前 commit），然後才呼叫 planner。`inFlight[key]` 在 actor 的第一個 await 之前註冊，第二個同 nonce 呼叫等待同一個 task。
3. planner 照舊（chat 仍等回合完成才寫 `conversation.turn_started`；cardAnswer 仍先寫 `card.answered` 再送）。
4. terminal 的非 throwing 返回（accepted/duplicate/validation/planner stale 或 rejected/cancelled）→ `DELETE` outbox row。
5. retryable rejected（`transport_replaced`、`turn_not_completed`、timeout/unavailable、未知 reason）或 throw（deadline、transport、planner error）→ 保留 row，讓 caller 看到錯誤；下一次 launch 重播。

這個順序保證：**planner 或 transport 的第一個 await 之前，意圖已經在 disk 上**。反過來不成立：`dispatch` 被呼叫前的 UI 本地回顯仍是記憶體；那個窗口（send 到 driver 之間）不在本契約內。

**Replay-on-launch（normative）：**

1. 只在该 Bot 的 unit 已 attach 且 `awaitRuntimeReadiness()` 為 true 後啟動；runtime 未 ready 時不碰 rows、不增加 attempts，留給下一個 bind。
2. `SELECT ... WHERE bot_id = ? ORDER BY created_at_ms ASC, nonce ASC LIMIT 20`；一個 Bot 同時只有一個 replay task，逐列處理。launch 不被 replay 阻塞。
3. 驗證 payload；corrupt → 刪除 + notice，繼續下一列。
4. terminal/retryable 分類（上表）；TTL / attempt cap 本輪未啟用。
5. `attempts = attempts + 1`（durable）。
6. **已 committed nonce 的處理：**
   - `chat`：`conversation.turn_started` 只在回合完成後才寫，nonce 已存在代表回合已完成（或 replay 已成功）；直接刪 row，不再送 prompt。
   - `cardAnswer`：`card.answered` 在送 prompt 之前就寫，nonce 已存在但 prompt 可能沒送出。以 `store.event(withId: "action:<nonce>")` 讀回該 event 的 `data.value`（planner 在 `BotRemoteActionPlanner.cardPlan` 寫入的 option value；old data 缺 `value` 時退回 `data.label`，兩者都缺 → 刪除 + notice），以同一 `card-answer:<nonce>` requestId **只 submit `session/prompt`**（20 s unary deadline），不等待回合、不呼叫 `sendUserMessage` 的 collect 部分；unary accepted 後刪 row。回合本身由既有 live projection/journal 接管；若 unary 逾時或 throw，row 保留。
7. **未 committed nonce：** 以 payload 重建 `BotUserAction`，呼叫 `dispatcher.dispatch(action)`；同一 nonce，planner 會導出同一 requestId。DSH `session/prompt` 的 requestId dedupe 保證同一個 prompt 最多開一個回合（the pinned runtime's `hasPromptRequest`；`plugins/tests/session-resume.test.ts`）。
8. 非 throwing → dispatcher 已刪 row；如果因競態還在，再刪一次。throw → 保留，下一 launch。
9. **不做的事：** 不為 `approval`/`stopTask`/`cardDismiss` 建 row；不用新 nonce 重播；不並行重播同一 row；不在 runtime 未 ready 時消耗 attempts；不把 outbox 當 event log（不分配 `commitSeq`）。

**已知語義邊界（必須在 §3/§4 保留）：** DSH 對重複 `requestId` 回 `{accepted:true}` 且不開新回合。若 kill 發生在 prompt 已被接受、但回合尚未開始/完成之間，replay 的同 requestId 不會再造一個回合；若宿主 journal 已經有該 `user/message`，訊息不會遺失（transcript 會由 projection 恢復），但 replay 可能等到 collect idle deadline 才結束，並在 attempts 耗盡時寫一則「未能送出」的 notice。本契約保證 **intent 不遺失、同 requestId 最多一個回合**；不宣稱 exactly-once 的模型回合或「一定还会有新回合」。

### 2.2 傳輸有界等待、queue fence 與 liveness

**Deadline 預設值（單一常數表，不得在呼叫點各自複製）：**

| Operation | Deadline | 逾時行為 |
| --- | --- | --- |
| `openMux` | 10_000 ms | 取消/關閉該 mux；mux 級 quarantine；throw `unavailable`（bool `transport_timeout` 診斷，不是新 wire code）。 |
| `session/follow` snapshot | 15_000 ms | 同上；attempt settle `interrupted`/`snapshot_timeout`。 |
| `session/prompt` unary | 20_000 ms | outcome unknown；throw；**不得**換新 requestId 重送；outbox 保留用同一 requestId replay。 |
| control unary（`session/create`、`session/page`、`phone/botClaimSession`、`session/cancel`、`workspace/archiveSession`、`workspace/unarchiveSession`） | 10_000 ms each | throw；unary failure 計數 +1；claim 可用同一 token 冪等重試；`session/create` 逾時不得盲目重 create。 |
| main-session recovery（`ensureMainSession` 整體） | 30_000 ms | cancel `mainSessionTask`、清 nil、throw `unavailable`；下一次 send/retry 重新 recovery。 |
| `collectTurn` idle（沒有任何 frame） | 300_000 ms | 關閉 mux；回 `interrupted`/`collect_idle_timeout`；**不**送 `session/cancel`，Worker 回合可能仍在跑，之後由 journal 接管。 |
| adopt interrupted settle | 2_000 ms（既有） | 保留：只 cancel/drop 被標記 interrupted 的 coordinator，不碰 queued。 |
| queue fence | 0 ms（同步） | 舊世代 queued turn 立即 lease 給新世代；queued 任務每 20 ms 輪詢 settle/generation，不送舊 prompt。 |

- 所有 deadline 都是 **runtime 外圍的 race**（`withTaskGroup`/timer + child cancel），不要求 `DSHRemoteTransport` 自己 timeout；底層若不配合取消，runtime 仍然返回，只是 orphan task 可能晚到，其結果被 generation/attemptId 丟棄。
- 每個 await 邊界 `Task.checkCancellation()`；取消回 `CancellationError` 或 typed `interrupted`，不得變成 hang。
- `session/create` 逾時的 outcome 是 unknown：下一次 recovery 必須先以 deterministic id（`gb-<botID>`）`session/page` 探測，存在就 claim，不存在才 create；禁止把 `session/conflict` 當成可重試的 create。
- `session/cancel` 逾時不阻塞 stop 的本地狀態；回可重試錯誤。

**Queue fence（`BotDSHRemoteRuntime.runTurn`/`attachTransport`）：**

- `QueuedTurn` 增加 `generation: UInt64`（enqueue 時的 `transportGeneration`）與 `requestId`/nonce 診斷欄位。
- `runTurn` 先 capture `generation = transportGeneration`；只在 predecessor 的 generation 等於目前 generation 時 join。predecessor 是舊世代時不 join，直接在新 transport 上開回合（或若仍在 adopt 窗口，回 `interrupted`）。
- queued Task 的等待必須同時 race「predecessor settle」與「generation change」；generation 一變，queued Task 在下一次 20 ms 輪詢回 `interrupted`/`transport_generation_changed`，不送 prompt，並從 `queuedTurns` 移除。
- `attachTransport` adopt 時：`transportGeneration &+= 1` → 標記 running coordinators interrupted（既有）→ 對所有舊世代 queued entries 發 generation 訊號/取消，並移除。**不得**只靠 2 s 的 coordinator settle 順便處理 queued。
- 被 fence 掉的 queued turn 不得留下 in-flight 語義：它回 typed result，該 action 的 outbox row 仍在，由新 transport replay。
- detach（`BotUnattachedTransport`）維持既有語義：取消所有 coordinators 與 queued，因為 unit 正在拆除；outbox 仍保留，下一次 attach 重播。

**Liveness（`transportIsAttached` 不再是答案）：**

- 新增 `transportQuarantined` 與 `consecutiveUnaryTransportFailures`；`hasLiveTransport()` 回 `transportIsAttached && !transportQuarantined`。
- **mux 級失敗**（`openMux`、snapshot、mux send/receive、follow EOF 非正常關閉）→ 立即 quarantine。
- **unary transport 失敗**（timeout、`ProviderError.unavailable`、401 重取後仍 unauthorized）→ 連續 2 次 quarantine；成功 unary 呼叫 reset 為 0。應用層 `DSHRemoteError`（`session/conflict`、`session/not-found` 等）不算 transport failure。
- `attachTransport`（adopt）清除 quarantine 與計數；detach 也清除（下一次 attach 重新開始）。
- `hasLiveTransport()` 被 composition 的 rebind 讀取（`BotRebindScope`）；quarantine 後的下一個 bind 必須 restart 該 unit，而不是 keep。本變更不新增自動 rebind timer；既有 watch/可見「重試」/host HELLO 路徑觸發 bind。
- `transportGeneration` 仍是唯一的 transport 身分；liveness 是它的觀察值，不是第二個 generation。

### 2.2.1 Prompt 被接受但 turn 永不启动（2026-11-15 真机追加）

真机复现：`session/prompt` 返回 ok，但 `session/follow` 在 20 s 内没有任何 `turn/start`/`user/message`；旧的主 session（`gb-main-29ecd...`）在重启后被 host 接受 prompt 却不再开 turn，模型网关也无请求。此时只加 transport deadline 不够：transport 是活的，死的是 session/agent。

修复：`collectTurn` 在**首个 turn frame** 前使用 20 s turn-start deadline（不是 300 s idle）；超时返回 retryable `turn_not_started`，`sendUserMessage` 对同一 prompt **重建 main session（新 epoch，`runtime.started`）并重试一次**，requestId 不变；仍失败则 outbox 保留并显示可重试错误。历史仍由 `runtime.started` epoch 链投影，不删除旧 row。

验收：真机旧 session 复现 → 20 s 内返回 `turn_not_started` → `rebuildMainSession` 新 id → 重试的 prompt 收到 `turn/start` → assistant 回复落库 → pending row 清空。

### 2.3 P09：none（follow-up，不 frozen）

本輪**不**新增或修改 Bot UI 狀態、`BotRuntimePresentation`、`BotUIPendingAction`、local-echo 重建、strings 或 `spec/ui/v1/**`。沒有 code lane 在這次變更實作這些介面；把它們寫成 frozen 契約會讓 doc 與實作不一致。

- outbox 是背景 durable；replay 由 composition/unit 在 launch/bind 後啟動，不依賴 UI。
- UI 沿用今天的行為：send 立即顯示 `local-<nonce>` 回顯；durable `user/message` 出現時由既有 `chatActionNonce` 規則退休；retryable 失敗走既有的 failure notice/header problem line。
- 行為要求（屬 P25 replay，不是 P09 契約）：replay 不得產生第二則相同訊息（nonce/requestId dedupe）；retryable 失敗必須以既有 notice 顯示，不能靜默丟棄。
- **Follow-up（not frozen）**：由 outbox 投影的 pending/retry presentation、`BotRuntimePresentation.pendingActions`、`BotUIPendingAction`、`composer.send.pending`/`composer.send.retrying` 與對應 `ui-state-vectors`，留給後續 P09 變更單；本單不承諾名稱、欄位或文案。
## 2.5 架構決定：保留 transport adoption，修正 liveness/queue，而不是 revert #173/#177

本單**明確保留** PR #173 的 transport adoption 與 PR #177 的整合結果：

- `attachTransport` 對 live Worker transport 仍然是 adopt：標記執行中的 attempt `interrupted`、保留其 requestId、不送 cancel；placeholder 仍然是 teardown/cancel。
- `BotRebindScope` 仍然以「live unit 不被無關 bind 重啟」為政策：這是修掉「切換 Bot 會斷開另一個 Bot」的核心。`BotRuntimeUnit.rebindState()` 仍把 live transport + started 當作 keep 的條件。
- fix 改的是 adoption 的兩個缺口：**adoption 後沒有 liveness**（死 transport 仍被 keep）與 **adoption 保留 queued entries 但沒有 generation fence**（新 send 等舊 predecessor）。加上 outbox 後，fence 掉的 queued turn 不再等於丟訊息。

**為什麼 revert 會復發「切換 Bot 斷開另一個 Bot」：** #173 之前，bind 會對每個 unit 重建 transport、`cancelTurn(includeQueued: true)`、重新 claim session；`select()` 也被當成 rebind。任何 App 側的 rebind（切換 Bot、背景 park、watch 重連）都會取消所有 Bot 的 running turn 與 queued turn。把 #173 的 `attachTransport`/`BotRebindScope` revert 掉，等於把這個 blast radius 還原：選中 Bot A 會 cancel Bot B 的回合。這正是 #173 的 regression test `BotRuntimeLifecycleRebindTests` 與 `PhoneDSHParkHoldTests` 在保護的行為。本單只把「被保留的 live unit」判定收緊為真正的 liveness，並把「被保留的 queued entry」加上 generation fence；不 revert adoption。

**為什麼不用「每個 bind 都重建 transport」的簡單修法：** 那會把 rebind 變成 cancellation，與 #173 的 user-visible 契約（rebind 不是 cancel）衝突，且会让 in-flight turn 的 requestId/結果無法延續。正確方向是 bounded await + fence + durable replay，讓 rebind 可以安全地換 transport，而使用者訊息不靠 in-memory queue 存活。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old build（v3）→ new store（v4） | 舊 build 只認 `user_version <= 3`；新 build 首次 open 會把 v3 升級到 v4。升級後同一個檔案被舊 build 打開會以既有 `schemaTooNew` 拒絕，**在任何 schema statement 或寫入之前**，檔案不被改寫。部署順序必須是新 build 先寫；要 rollback 必須還原更新前的 v3 副本（見下）。測試：`store.phone.json` 的 v4 future-version case（5 → `schemaTooNew`）由 `BotStoreVectorTests` 讀同一份檔案。 |
| new build（v4）→ old data（v1/v2/v3） | v1/v2 先跑既有 v3 migration，再跑 v4；v3 直接跑 v4。v3 的 headers/payloads/effects/nonces 行不重寫、不改 `commit_seq`；`bot_pending_actions` 對舊資料是空表。migration 在同一個 `BEGIN IMMEDIATE` 內 `CREATE TABLE IF NOT EXISTS` + `PRAGMA user_version=4` + COMMIT；失敗 rollback，`user_version` 留在原值，open 回報底層錯誤，重開重試。測試：`store.phone.json` 的 v1/v2→v3→v4 rows 與 v3→v4 case；`BotStoreVectorTests`（Swift）與 `BotDomainStoreV4Test`（Kotlin）跑同一份；Kotlin `BotStoreVectorTest` 在 golden v4 更新前 expected-red，更新後必須原樣通過。 |
| new → old persist | 舊 build 拒絕 v4（`schemaTooNew`）；沒有 downgrade migration。v4 只多一張 additive 表，理論上 `DROP TABLE bot_pending_actions; PRAGMA user_version=3` 可以 downgrade，但**沒有 shipped build 實作**，不得在裝置上手工執行；rollback 的代價是 pending 意圖遺失，歷史 event 不受影響。 |
| new → new | 同一 v4 DDL；migration idempotent；outbox replay 以 nonce/requestId 冪等。測試：Swift `BotStoreVectorTests`/`BotUserActionTransactionVectorTests`/新增 `BotPendingActionOutboxTests`；Kotlin `BotDomainStoreV4Test`，`BotStoreVectorTest` 在 golden v4 更新前 expected-red。 |
| iOS v4 ↔ Android v4 | 兩端各自是本機檔案，**不共享資料**；DDL 與 v3→v4 migration 必須逐字相同，Android 只建立表、不使用 replay。沒有跨平台 wire。測試：Swift store vector + Android `:bot` v3→v4 migration case 都必須通過；Android instrumented test 仍可另跑。 |
| old/new Worker / host / gateway | Worker、host journal、gateway、`/api/remote.mux`、`session/prompt` 的 requestId 規則都不變；舊/新 App 可以接同一個 Worker。沒有新 header、env、capability、frame。測試：既有 pinned runtime resume test（`plugins/tests/session-resume.test.ts`）不改；transport lane 的 fake 不得要求 Worker 新行為。 |
| P27 / P26 / P09 | 沒有 `conversation.*`、row/projection、user-action/action-result、tool/MCP/memory/wake/ledger/watchdog 或 UI/presentation/strings 變更；P27/P26/P09 的舊/新組合與今天相同。 |

- **版本／adapter 決定。** 依 P25 `store.md` §2 的 `user_version` policy：新版本 additive、forward-only；沒有 adapter，也沒有「同時接受 3 和 4 寫入」的第二條路徑。`>4` 才 `schemaTooNew`。
- **bundle/image/native artifact 更新順序。** App 本機 store，不涉及 Worker bundle/image/native artifact。App 更新先落地；rollback 限制如上。
- **`target`／`draft` 條款。** 無。`bot_pending_actions` 從 frozen 起就是 normative；Android 的 replay 使用仍是 future work，store schema 先對齊。

## 4. 分工與證據

### 4.1 獨占路徑（不可重疊）

| Lane | 路徑 | 驗收 |
| --- | --- | --- |
| P25 outbox（Swift + spec） | `Sources/PhoneDSHBot/Store/{SQLiteDomainStore.swift,SQLiteDomainStore+UserAction.swift}`；`Sources/PhoneDSHBot/Rows/BotUserAction.swift`（dispatcher）；`spec/bot/v1/store.md` §2/§3/§7/§10/§11；`spec/bot/v1/golden/store.phone.json`；`Tests/PhoneDSHBotTests/Store/{BotStoreVectorTests,BotUserActionTransactionVectorTests,BotPendingActionOutboxTests}.swift` | `validate_vectors.py` + Swift store/outbox tests；v3→v4 migration、TTL/attempts、insert-before-plan、**terminal-only clear**（retryable `transport_replaced`/`turn_not_completed`/timeout/unknown 保留）、cardAnswer event-value replay |
| P25 Android store | `android/bot/src/main/kotlin/com/phonedsh/bot/store/{BotDomainStore,BotStoreSchema}.kt`；`android/bot/src/test/kotlin/com/phonedsh/bot/store/BotDomainStoreV4Test.kt`（真實 class 名稱） | `:bot:testDebugUnitTest` + `:bot:test`；同 DDL/`user_version`/migration；**不做 replay/UI**。`BotStoreVectorTest` 在 golden v4 更新落地前 expected-red，落地後必須原樣通過（不是不存在的新 class）。 |
| transport liveness | `Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`；必要的 `BotRebindScope.swift` 註解/決策；`Tests/PhoneDSHBotTests/MCP/{BotTransportDeadlineTests,BotQueueFenceTests,BotRuntimeLifecycleRebindTests}.swift` | hanging transport、old-generation queue、dead transport/quarantine、adopt-vs-cancel |
| integration / replay wiring（P25） | `examples/probe-app/PhoneDSHProbe/Bot/{BotRuntimeComposition.swift,BotRuntimeUnit.swift}`；只接 launch/bind 後的 replay 啟動與 store 查詢；不改 `BotRuntimePresentation`/`BotChatModel`/strings（P09 none） | outbox replay 恰好一次、不重複訊息；retryable failure 走既有 notice；App compile |
| docs | 本單 + `docs/receipts/2026-11-15-bot-send-hang-diagnosis.md` | 只讀路徑；不改 spec/runtime |

### 4.2 共享 fixtures

- `spec/bot/v1/golden/store.phone.json`（outbox lane 更新）至少要覆蓋：
  1. v3→v4：v3 的 headers/payloads/effects/nonces 在 migration 後逐位元組/逐 row 不變，`user_version=4`，`bot_pending_actions` 空表；重開 idempotent。
  2. future-version：`user_version=5` → `schemaTooNew`，檔案不被寫入（原本測 4 的 case 改成 5）。
  3. pending row round-trip：insert（`attempts=1`）→ reopen → row 仍在；`attempts` 遞增；delete 後 absent。migration 不觸碰 v3 rows。
  4. corrupt payload 的 fail-safe（TTL/attempt cap 本輪未啟用，列 follow-up）。
- **Outbox store vector 的 clear 條件必須是 terminal-only。** `store.phone.json` 若仍寫「任何 non-throwing 結果都刪 row」是錯的；必須保留 `transport_replaced`/`turn_not_completed`/timeout/unavailable/未知 reason。這一行由 outbox lane 修正，本單 §2.1 的分類是權威。
- **P09 vectors：** 本輪沒有 `ui-state-vectors`/`check_bot_ui.py`/strings 的新增或修改；pending presentation 是 follow-up，不在 acceptance 內。
- 兩端跑同一份 store vector：Swift `BotStoreVectorTests` 讀 disk 上的 `store.phone.json`；Kotlin `BotDomainStoreV4Test` 跑同一份 v4 migration，`BotStoreVectorTest` 在 golden v4 更新前 expected-red、更新後必須原樣通過。

### 4.3 各端測試（code agents 必須提供）

| 測試 | 必須證明的行為 |
| --- | --- |
| hanging transport fails within deadline | `openMux` 永不返回（且忽略 cancellation）時，`sendUserMessage`/`runTurn` 在 deadline 內回 typed error；`coordinators`/`queuedTurns` 清空；bind 不 hang；`hasLiveTransport()` 變成 false（mux 級 quarantine）。以注入的短 deadline 測，不睡 10 s。 |
| old-generation queue not awaited | gen 1 開 turn，第二個 send queue；`attachTransport(gen 2)` 後，queued 在下一次 20 ms 輪詢回 `interrupted`/`transport_generation_changed`；不等待 gen 1 predecessor；gen 2 上沒有為該 stale attempt 送 prompt。再驗證：gen 2 的新 send 不 join 舊 entry。 |
| dead transport | `call`/`openMux` 以 `ProviderError.unavailable` 失敗：unary 連續 2 次 → `hasLiveTransport()==false`；`BotRebindScope` 下一次 bind 選 restart；不會 keep 一個死 unit。 |
| pending action survives kill and replays once | 真實 store 寫 outbox row → 重建 store/runtime（模擬 kill）→ replay 恰好呼叫 dispatcher 一次，nonce/requestId 與原 action 相同，成功後 row 不存在；第二次 launch 不再 replay。另測：dispatcher throw → row 保留、attempts 遞增；第三次仍失敗 → row 刪除 + 一筆 `send-expired` notice。 |
| rebind interrupted retains the intent | gen 1 的 chat planner 回 `.rejected("transport_replaced")`/`turn_not_completed`（non-throwing）時，outbox row **不得**被清除；replay 在新 transport 上以同一 nonce/requestId 送出一次。對照：validation/stale/cancelled 的 rejected 必須清除。這是防止「rebind 後中斷被當成 action 無效」的回歸測試。 |
| cardAnswer commit→dispatch window | 先 `performAndRecord(card.answered)`（模擬 kill 在送 prompt 前），outbox row 仍在；replay 從 `action:<nonce>` event 讀 `value`，以 `card-answer:<nonce>` 送一次，row 清除；不重複開回合（fake 驗 requestId 與次數）。 |
| v3→v4 migration | Swift `BotStoreVectorTests` 讀 `store.phone.json`：v3 fixture 的 event/effect/nonce rows 不變、`user_version=4`、outbox 空表、重開 idempotent、v5 拒絕、migration 注入錯誤時留在 v3 且 open 失敗。 |
| Android migration | `:bot:testDebugUnitTest` + `:bot:test` 的 `BotDomainStoreV4Test`（真實 class）：DDL/`user_version`/rows 不變；Android 只建表，無 replay 測試。`BotStoreVectorTest` 在 golden v4 更新前 expected-red，更新後必須原樣通過。 |
| replay 不重複 / retryable notice | replay 成功後只有一則 durable `user/message`/一個 requestId 回合；同一 nonce 第二次 replay 不會再送 prompt。retryable 失敗（`transport_replaced`/`turn_not_completed`/timeout）保留 row 並透過既有 `ui.notice`/header problem 顯示；不得靜默丟棄，也不得新增 UI state/string。 |

### 4.4 Exact commands（各 lane 實跑後填 PASS/FAIL/SKIP/INCOMPLETE/NOT_RUN）

```sh
python3 spec/bot/v1/tools/validate_vectors.py
swift test --filter 'BotStoreVectorTests|BotUserActionTransactionVectorTests|BotPendingActionOutboxTests|BotTransportDeadlineTests|BotQueueFenceTests|BotRuntimeLifecycleRebindTests'
bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree
cd android && ./gradlew :bot:testDebugUnitTest :bot:test
```

- 目前各 lane 的實際結果見 integration head 的 handoff；本 docs lane 沒有跑 Swift/Kotlin/store/device，不能替它們宣稱 PASS。Android 若沒有實跑，記 **NOT_RUN**，不能因 `BotStoreVectorTest` 目前 expected-red 就說遷移通過。
- `python3 scripts/ci/protocol_impact.py --base 484c1f994 --body-file <this record>` 必須接受 §0 的 `Protocol impact` 宣告（本 diff 只動 docs，宣告是 P25 + P09/P26/P27/P14 none）。

### 4.5 真機 build/deploy check（integration lane 執行並記錄）

1. 以 `PDSH_WITH_XZSHELL=1` 建 Debug device build（同一條 `xcodebuild` 路徑，team/device 以本輪 run log 為準）；確認 app binary 內有 `PhoneDSHShell` 的 linked symbol（例如 `nm` 可見 `_pdsh_caps_json`/`_pdsh_version`，不是 stub）。
2. `xcrun devicectl`（或 Xcode）install + launch；Bot 頁執行 `phone info`，確認回傳真機 JSON（不是 `not_linked`）。
3. 正常 send → 收到回覆；確認宿主 journal 有 `user/message`，Bot store 有 `conversation.turn_started`（chat）或 `card.answered`（cardAnswer）。
4. **rebind 後 send**：觸發一次 rebind（或選另一個 Bot 再回來），送出 chat；必須在 deadline 內 accepted/pending，不得永久 spinner；宿主 journal 必須出現該 `user/message`。
5. **kill/relaunch**：在 send 後（planner/transport 尚未完成時）kill app，重開；`domain.sqlite` 必須有 `bot_pending_actions` row；launch 後 replay **恰一次**；transcript 不得出現兩則相同的 user message；outbox row 清除。
6. **另一個 Bot 的回合不被切斷**：Bot B 有 running turn，選中 Bot A 觸發 bind；Bot B 的 turn 必須繼續（#173 regression check）。
7. 每一項記 `PASS/FAIL/NOT_RUN`，附 build SHA、device/OS、時間與 log 位置；本 docs lane 的 device 欄位是 **NOT_RUN**。

### 4.6 剩餘風險／必須在 implemented 前確認

- **Duplicate requestId swallow。** DSH 對已記錄的 `requestId` 回 accepted 而不開新回合。`intent` 不會遺失（host journal/outbox 有），但 replay 不能強制一個新回合；若 kill 發生在 prompt 已接受、回合未完成之間，可能等到 collect idle 或 attempts 耗盡才發 notice。不得用新 requestId 盲重送（那是另一個回合，違反 §6.3「取消與超時不證明副作用沒有發生」）。
- **「非 throwing 就清除」是錯的。** Chat planner 在 rebind 時回 `.rejected("transport_replaced")`（non-throwing），若 dispatcher 清掉 row，訊息仍然會丟。§2.1 的 terminal/retryable 分類是 MUST；unknown reason 必須保留。對應回歸測試見 §4.3 `rebind interrupted retains the intent`。
- **CardAnswer 的 commit→prompt 窗口。** 若 replay 沒有實作 §2.1 第 6 步（讀 `card.answered` 的 `value` 重送），答案會 durable 但模型沒看到。此步是本單 MUST；若 outbox lane 不實作，必須以 CCR 降級並在 §5 記明，不能默默略過。
- **`payload` 的 erasure。** 若 `BotSessionErasure`/全量清除沒有刪 `bot_pending_actions`，已刪除的使用者文字會留在 outbox。這是 P25 的 MUST；若不在本輪，§4 必須列為 open risk，不能宣稱 erasure 完整。
- **P09 pending presentation 是 follow-up，不是本輪 acceptance。** 本輪 UI 不會顯示新的 pending/retry 狀態；重啟後的使用者訊息是否可見取決於 durable `user/message`/既有 local echo，不是新的 presentation。要驗證 pending 回顯，必須等後續 P09 變更單。
- **Android 只有 schema，沒有 replay/UI**；P09 Android 仍是 partial。不能因 `:bot` 遷移通過就說 Android 有 send durability。
- **Transport deadline 最終值。** §2.2 是目前凍結的預設；transport lane 的實測/最終常數可能 supersede。收到精確數字後必須以新 revision 更新 §2.2 與 §5，不能讓 code 與 doc 各自一組值。
- **沒有 power-loss 測試。** `synchronous=FULL` 是 profile，不是已測的斷電 durability；本變更不改變這個既有缺口（`store.md` §13）。
- **Deadline 預設值**（10/15/20/10/30/300/2/0.5 s）是本單凍結的預設；若 code agent 因實測調整，必須先改本單 §2.2 並在 §5 記修訂，不能在 code 裡留一組不一致的常數。
- **Outbox TTL/attempts**：本輪保留到 terminal outcome，不做 TTL/attempt cap；`attempts` 只做診斷。若未來要加 24 h/3 次，先改本單，再改 store/vector/tests。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | docs lane（contract owner） | 依 2026-11-14 bad build `484c1f994` 的診斷凍結：P25 v4 `bot_pending_actions`（精確 DDL 由 P25 outbox lane 提供）、durable-before-dispatch、terminal-only clear、replay/TTL/attempts、transport deadlines、queue generation fence、liveness quarantine。P09 經協調後縮為 **none**：本輪不改 UI/presentation/strings/vector，pending/retry presentation 是 follow-up。Android 真實 class 記為 `BotDomainStoreV4Test`；`BotStoreVectorTest` 在 golden v4 更新前 expected-red。無 CCR。 | transport lane、P25 outbox lane（含 Android store）、integration/replay wiring、reviewer-integrator |
