<!-- SPDX-License-Identifier: MIT -->

# PC-20261120-engine-first-launch — engine-first launch, wake leases and ReadySweep

## 0. 摘要（機器可讀）

```yaml
change: PC-20261120-engine-first-launch
contracts: [P05, P06, P08, P09, P26]
status: frozen
breaking: false
version_decision: No version bump. host gains a new normative section §10.2 over the existing contract 1; cloud-tasks goes v1.5 to v1.6 as a documentation revision only (payload, routes, ack and limits are byte-identical); external-admission goes v1.1 to v1.2 with one clarifying sentence; bot v2 held-inbox-item gains two new closed connector-update variants while every existing variant and field is unchanged and an older reader keeps rejecting the unknown kind (fail-closed); proactive-decision gains connector-update as an additive kind and proactive-settings accepts it in deliveryKinds (old build skips the unknown kind in fuse restore, and no default copy is added); connector-cursor is a new host-private record whose GitHub cursor is {since,lastModified}. No wire field, Worker env, push payload or Android contract changes. Revision 3 adds host §10.3 (host-owned time: WakeDemand, wake projection, OS channels), two WakeReasons, two ReadySweep steps and engine-launch golden revision 2; it adds UIBackgroundModes `fetch` for BGAppRefreshTask.
base: 87a2486edb715f8bff959c94621abe423163a951
contract_revision: docs/protocol-changes/PC-20261120-engine-first-launch.md@3
```

## 1. 識別與角色

- **Trigger → 現況 → 期望.**
  - 現況：iOS 的 `ChatModel.start()` 把 `prepareBotRuntime()`（打開 Bot SQLite）與
    `makeHostLaunch()`（要求 anchor 在窗口）綁在一起；Bot 頁用 40×250 ms 輪詢等 engine 並自己
    調 `chat.start()`，超時顯示「Bot 運行時還沒有準備好。請先啟動引擎，然後重試。」；雲端推送只
    做 pull → admit → ack，`spec/v1/cloud-tasks.md` §8 明文說背景推送不啟動引擎；外部准入
    journal 只投遞給已運行的 Bot unit；bot v2 §3.2 第 4 級把推送中繼列為「本輪不實現」。
  - 期望：App 一被打開或被遠端喚醒，先顯示已持久化內容，再由**唯一編排者**在執行資格成立時
    靜默啟動引擎，並在系統授予的喚醒租約內按固定順序跑 ReadySweep（含 Bot 的 held inbox 重放、
    錯過 routine 補跑與 Gmail/GitHub 增量掃描）。每個喚醒通道只做「先 durable 寫入、再呼叫編排
    者」，不直接啟引擎。
- **Roles.** `contracts` 單元兼任 contract owner 與 reviewer；`ios-launch`／`ios-bot` 為 iOS
  implementers；`integration-review` 為 reviewer-integrator；Android 由同事按本凍結版本另行實作。
- **Owning contracts / shared fixtures.**
  - P06：[spec/host/v1/README.md](../../spec/host/v1/README.md) §10.1（eligibility 加入租約分支）
    與新增 §10.2；shared vectors
    [spec/host/v1/golden/engine-launch.json](../../spec/host/v1/golden/engine-launch.json) +
    [schema](../../spec/host/v1/schema/engine-launch.schema.json)。
  - P06：[spec/host/v1/external-admission.md](../../spec/host/v1/external-admission.md)（一句澄清）。
  - P05：[spec/v1/cloud-tasks.md](../../spec/v1/cloud-tasks.md) §8 v1.6；shared cases 只改
    `revision` 字串，無新增／刪除用例（見 §3）。
  - P26：[spec/bot/v2/README.md](../../spec/bot/v2/README.md) §3.2 第 4 級、新增 §3.3；
    [held-inbox-item.schema.json](../../spec/bot/v2/held-inbox-item.schema.json)、
    [connector-cursor.schema.json](../../spec/bot/v2/connector-cursor.schema.json)、
    [proactive-decision.schema.json](../../spec/bot/v2/proactive-decision.schema.json)、
    [proactive-settings.schema.json](../../spec/bot/v2/proactive-settings.schema.json) 與
    [golden/held-inbox.phone.json](../../spec/bot/v2/golden/held-inbox.phone.json)、
    [golden/connector-cursor.json](../../spec/bot/v2/golden/connector-cursor.json)、
    [golden/proactive.json](../../spec/bot/v2/golden/proactive.json)。
  - P09：[spec/ui/v1/bot/ui-state.md](../../spec/ui/v1/bot/ui-state.md) §1.1、
    [pages/bot-chat.md](../../spec/ui/v1/pages/bot-chat.md) 與
    [strings.json](../../spec/ui/v1/bot/strings.json)。
  - P08：[spec/platform/README.md](../../spec/platform/README.md) §14。
- **受影響的 producer／consumer（逐端）**
  - iOS host（Swift，本輪實作）：launch orchestrator、`WakeSource` 適配器、ChatModel 階段 A、
    Bot 頁、推送／BGProcessing／解鎖／板子接線。
  - 雲端 `phone-dsh-cloud`（不屬於本倉）：**無需改動**；推送 payload、路由、ack、limits 未變。
  - Android（Kotlin，本輪不實作）：同一份 §10.2、`engine-launch.json`、`connector-cursor` 與
    held-inbox golden；Android 交接文檔由 integration-review 寫在
    `docs/handoffs/engine-first-launch-android.md`。
  - Worker／TS：無改動；沒有新 wire 欄位、`PDSH_*` 環境變數或能力名。
  - Rust：無改動（launch 不在 wire／WAL／codec 邊界）。
  - HarmonyOS：沒有 launch orchestrator，維持 partial，不主張已實作。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| 執行資格（host §10.1） | 「前台，或已有音頻保活」→ 「前台，或已有音頻保活，**或持有有效 `WakeLease` 且剩餘時間 ≥ 對應門檻**」。其餘每一條（手動恢復、顯式 stop 暫停排隊準備、首次 UI 發送需前台會話、存儲可用性由 outbox 寫入決定、submitting→outcomeUnknown→queued 分支）逐字保留。 |
| `WakeReason`（host §10.2.1，新） | 封閉 11 值：`coldLaunch`、`foreground`、`unlock`、`cloudTaskPush`、`boardWake`、`bleRequest`、`lanRequest`、`pcLinkRequest`、`bgProcessing`、`routineNotificationTap`、`engineRecovered`。新增通道只能經契約修訂加值並更新 golden，不得用自由字串。 |
| `WakeSource` 適配器（host §10.2.2，新） | 每個通道：先 durable 寫入 journal／outbox／wake inbox → 以 lease 呼叫唯一 orchestrator → 返回。適配器不得啟引擎或直接調 Bot。Bot 側沿用 `WakeSignalSource`。 |
| `WakeLease`（host §10.2.3，新） | `{wakeId, reason, grantedAtMs, deadlineMs}`；deadline 來自系統（背景時間、expiration handler、Worker stop signal）。 |
| 門檻常量（host §10.2.3，新，暫定） | `minLeaseForColdBootMs = 20000`、`minLeaseForResumeMs = 8000`、`parkMarginMs = 5000`；標註暫定、由 `ios-wake-spike` 真機重定。 |
| 決策函數（host §10.2.4，新） | `decide(reason, foreground, residentAudio, hostState, leaseRemainingMs, userStopped, needsReset) → boot｜resume｜ready｜nativeOnly｜defer｜needsAttention`，固定求值順序；`reason` 只選租約來源、不加分支。 |
| ReadySweep（host §10.2.5，新） | 七步固定順序：`userOutbox` → `externalAdmission` → `cloudTaskPull`（同 wake 30 s 內已 pull 則跳過）→ `botHeldInbox` → `missedRoutines` → `connectorScan` → `approvalReminderSync`；**ownership split**：host orchestrator 跑 1–3，`BotRuntimeComposition.runReadySweep(_:)` 跑 4–7，合併成同一份 `ReadySweepReport`；步開始前 `remainingMs ≥ parkMarginMs + stepBudgetMs(step)`；每步冪等、跳過不做半步；同一 `(engineIncarnation, wakeId)` 只跑一次、可合併。`EngineLaunchOutcome` 屬 app-internal，只有 `decision` 值是契約。 |
| 可見性（host §10.2.6，新） | 編排者發起的 boot/resume 不寫 transcript 狀態行（含 `Booting the Worker…`）、不顯示錯誤；只有用戶操作正在等待且最終失敗時沿用現有錯誤。Bot 頁階段 A 直接顯示持久化內容。 |
| 推送喚醒（cloud-tasks §8 v1.6） | 「不從背景推送啟動引擎」→ 「先做既有 pull→admit→ack，再以本次回調時間申請喚醒租約；租約足夠才由編排者啟動引擎並跑 ReadySweep，不足時行為與 v1.5 完全相同」。**payload、路由、ack、limits 一個字不改**；雲端無需改動。 |
| 外部准入（external-admission §4） | 「journal 從不自行啟動引擎」保留，補一句「由 orchestrator 在喚醒租約內啟動」。admission／stages／順序／上限不變。 |
| Bot 在場第 4 級（bot v2 §3.2） | 「BGTask 補跑；推送中繼只保留接口、本輪不實現」→ 「推送、板子、BGTask 三者都經編排者；适配器先 durable 寫入，再以 `WakeReason` + 租約呼叫；引擎就緒後跑 §3.3 三步」。 |
| Bot ReadySweep 四步（bot v2 §3.3，新） | `botHeldInbox`（write-before-enqueue + `requestId` 去重）、`missedRoutines`（多次錯過只補一次；`nextRunAt` 前進到嚴格晚於 now；`quietDefer` 保留原 `scheduledFor`）、`connectorScan`（只取元數據、首次只建 cursor、cursor 回退／損壞靜默重設）、`approvalSync`（reconcile durable 待審批）。**沒有**重新引入 PC-20261111-bot-v2-unwired 刪除的每日預算、分類配額、冷卻、TTL、去重窗口、模型 triage 或 idle-checkin。 |
| `held-inbox-item`（bot v2 schema，新分支） | 新增兩個封閉變體 `connector-update`（`connector` = `gmail`｜`github`）；欄位 `cursorFrom`、`cursorTo`、`count`（1–20）、`items[]`（≤20，每項 id/at，Gmail 另 from/subject、GitHub 另 repo/title，**不含正文**）；`count == len(items)`、`requestId == <connector>:<cursorFrom>:<cursorTo>`、`cursorFrom != cursorTo` 為語義規則。既有三個變體逐字未動。 |
| `connector-cursor`（bot v2 schema，新） | app-global per (account, connector)；Gmail `cursor` 是十進位 historyId 字串，GitHub `cursor` 是 `{since: RFC 3339 UTC 秒, lastModified: IMF-fixdate HTTP-date|null}`。記錄為 `{version:1, connector, cursor, updatedAt, status: established|reset, lastError?: cursor-invalid|cursor-regressed|scan-failed}`；封閉、host-private、缺席＝從未掃描；只有 `lastModified` 改變不產生 `connectorUpdate`。 |
| `proactive-decision` / `proactive-settings`（bot v2 schema，新值） | `kind`（含 notification.kind 與 candidate.kind）與 `deliveryKinds` 新增 `connector-update`；候選必須自帶非空 `title`／`body`（無缺省文案）；使用 §3.0 既有 mode／deliveryKinds／feedback／dnd／安靜時段／fuse，不新增預算、配額、冷卻或 TTL。 |
| `[connector]` held 行（bot v2 §3.3.1，新） | `HeldMessages.block` 必須有獨立 `[connector]` 分支（connector、count、cursorFrom → cursorTo、item 元數據摘要），每個外部字串先經 `escapedHeldField`；held 開頭說明在存在 connector 項時列出「连接器更新」；不得落進 `[agent]` 預設分支。Swift 實作位置由 ios-bot 負責。 |
| UI（P09） | 刪除 `runtime.notReady`（「Bot 运行時还没有准备好。请先启动引擎，然后重试。」）這一條 string；新增 ui-state §1.1 與 bot-chat 條款：階段 A 顯示已持久化內容、頁面不自啟引擎、編排者啟動不顯示 Booting 狀態行。**只刪這一條等待文案**，其他 UI 文案與 token 不變。 |
| 平台（P08） | 新增 §14：iOS 離屏 anchor 窗口（不 makeKeyAndVisible、alpha 0.01、2×2、scene 連上後移回 overlay）、不為後台任務延長音頻、只加一個 BGProcessing identifier、不加 UIBackgroundModes；Android 無推送、WorkManager 最小 15 分鐘、Android 14+ 背景啟動 `dataSync` FGS 的限制與降級。 |

自檢（spec/README.md §5.1）：沒有第二種表達（WakeReason/decision/step 都是封閉集合，沒有自由字串或
第二個 envelope）；新增的 held-inbox 變體是選擇性的，既有輸入的有效性完全不變（不是收緊或放寬既有
變體）；沒有刪除或重用任何既有名稱／編號；`cloud-tasks` 的 payload／ack 未動，因此沒有「新增 enum
需要未知值規則」的問題（`pdsh.kind`/`pdsh.v` 未知仍忽略，逐字保留）。`connector-update` 的
`kind` 對舊 held-inbox reader 是未知值：舊 reader 以 fail-closed 拒收，item 留在 inbox，不丟失、
不誤讀；對舊 proactive reader，`restoreAccounting` 既有的「未知 kind 跳過」語義保留，fuse 記帳
不失敗。`proactive-decision` 的 `kind` 與 `deliveryKinds` 只是新增值（additive），既有值域與
未知值處理不變；沒有新增缺省通知文案。

**`cloud-tasks` cases 的實際處置。** 逐條檢查
`spec/v1/golden/cloud-tasks/cases.json` 後確認它**沒有**任何「推送不啟動引擎」的斷言（`push` 只
出現在 registration 的欄位驗證與 `constants.push`）。因此沒有新增、修改或刪除任何 cloud-tasks 行為
用例；唯一改動是把 `revision` 字串由 `cloud-tasks-v1.5` 更新為 `cloud-tasks-v1.6`，讓 shared cases
與文件修訂一致。原本的踰越行為（無租約的推送）不需要「租約不足」新用例，因為新規則下它與 v1.5
完全相同，且已在 `engine-launch.json` 以 `cloud-push-cold-boot-lease-minus-one` 與
`lan-request-without-lease-is-native-only` 覆蓋。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 舊 App（沒有 orchestrator）照 v1.5 行為：推送只做 native pass，Bot 頁仍輪詢；新的 spec 不要求舊 client 送任何新欄位。雲端與舊 client 的請求和 ack 完全不變。 |
| new → old | 新 App 對雲端送出的 registration／submit／pull／ack 與 v1.5 相同（`push` 欄位、payload、路由、limits 未動），舊雲端無需認識租約。新 App 寫出的 `connector-update` held item 在舊 reader 是未知 `kind`：舊 reader 拒收（fail-closed）、item 留待新版本重放，不會被誤讀成別種通知。`proactive.considered` 的 `kind = connector-update` 對舊 build 是未知值：既有 `restoreAccounting` 跳過未知 kind（fuse 記帳不因此失敗），舊 schema checker 會拒絕新向量但不影響 runtime；這是 additive 值，不是改寫既有 kind。 |
| new → new | Swift 與 Kotlin 直接讀同一份 `engine-launch.json` 與 `connector-cursor.json`；`spec/host/v1/golden/engine-launch.json` 的 schema 是閉合物件，兩端實作同一決策與步進函數。golden 是判準，不允許手抄向量。 |
| persisted old data → new／rollback | 舊 held inbox 沒有 `connector-update`，新 reader 照舊讀；舊 `connector-cursor` 不存在＝從未掃描，首次只建立 cursor。若先前已有 GitHub cursor 以字串形式落盤（未發布的中間實作），新 reader 視為 invalid、重設到上游 head 且不產生 `connectorUpdate`（fail-closed，不猜測）。回滾到舊 build：已寫入的 `connector-update` 與 cursor 檔不被讀取／不被刪除，留在原處；不影響既有 send-outbox、admission journal、routine 資料與 proactive 記帳。 |

- **版本／adapter 決定.** 依 spec/README.md §5.1 與各 owning contract 的版本規則：host 仍為
  contract 1（新增可選的 orchestrator 行為，不新增 required member）；cloud-tasks v1.6 是文件
  修訂、wire 不變；external-admission v1.2 是一句澄清；bot v2 的 `connector-update` 是封閉
  union 的新增變體（additive，舊 reader fail-closed），不升 `version` 欄位；`connector-cursor`
  是新 host-private 記錄，第一次寫入即建立。沒有 adapter 或第二 envelope。
- **發佈順序／回滾限制.** iOS 先行；Android 未實作期間互通行為不變，因為兩端唯一共用的是
  spec／schema／golden（Android 尚未讀取）與推送 payload（未改）。雲端可先行、後行或不行，
  沒有部署依賴。回滾 iOS 只影響新喚醒路徑，durable 資料均由舊路徑可讀。
- **`target`／`draft` 條款中，本次實作與仍保留的差異.** host §10.2 與 Bot §3.3 凍結為
  normative，但 iOS runtime 證據與 Android 實作尚未存在；`cloud-tasks` 整體仍是 `target`。
  `connectorUpdate` 的主動提醒仍受 §3 既有 `ProactivePolicy` 約束，不新增配額。

### 3.1 CCR（ios-bot，經 owner 轉交）裁定與五問答覆

**裁定：接受（owner position: accept）。** 這是 additive delta，不是新 wire：沒有新 HTTP 路由、
沒有新推送 payload／ack、沒有新增 `UIBackgroundModes`、音頻保活用途或推送 SDK，也沒有放寬任何
既有 fixture／quota。變更為：`proactive-decision.schema.json` 的 `kind`（含 notification.kind 與
candidate.kind）與 `proactive-settings.schema.json` 的 `deliveryKinds` 加入
`connector-update`；`spec/bot/v2/README.md` §3.0／§3.3 定義 `[connector]` held 行與既有
policy 的套用方式；golden 加 did／skip 向量。

1. **Cursor owner 與形狀.** cursor 由宿主 **app-global，每個 (已登入帳號, connector) 一份**；
   不是 per-Bot，也不從記憶／held inbox 推導。Gmail `historyId` 是**十進位字串**；GitHub 是
   `{since: RFC 3339 UTC 秒字串, lastModified: IMF-fixdate HTTP-date 字串|null}`。首次掃描
   **只建立 cursor**，不產生 `connectorUpdate`、不把歷史當新內容。
2. **held-inbox `connectorUpdate` 限制.** 只允許 `gmail`、`github`；`cursorFrom`／`cursorTo` 是
   字串（Gmail 十進位 historyId；GitHub `since` ISO 秒），不是 cursor 記錄的 GitHub 物件；
   `count` 1–20 且等於 `items` 長度；`items` 1–20；每項為 `id`＋`at`（= Gmail `date`／GitHub
   `updatedAt`，epoch ms）＋Gmail `from`／`subject` 或 GitHub `repo`／`title`；`text` 單行
   ≤1,200 scalar；`requestId = <connector>:<cursorFrom>:<cursorTo>`；**不含正文**。schema 對
   cursor 兩端加了 connector 專屬 pattern。
3. **Golden.** `spec/bot/v2/golden/held-inbox.phone.json` 保留有效 Gmail／GitHub 項，並含無效例：
   >20 items、未知 connector、缺 `cursorFrom`（missing cursor）、錯 cursor 形狀、item 含正文、
   count／requestId 不一致；測試直接讀這份 overlay（經既有合併載入器），不手抄。
4. **engine-launch sweep vectors.** 識別字維持 owner 裁定的 **committed** 七個：
   `userOutbox`、`externalAdmission`、`cloudTaskPull`、`botHeldInbox`、`missedRoutines`、
   `connectorScan`、`approvalReminderSync`。§10.2、schema、golden 三處一致；不重命名。
   只補 ownership split 句（host 1–3、Bot 4–7、合併一份 report）與 `EngineLaunchOutcome`
   app-internal 的聲明。
5. **Routine catch-up.** `nextRunAt` 依既有 `RoutineMachine`／`RoutineScheduleMath.nextRunAt`
   語義前進到**嚴格晚於 now** 的下一個時點（`nextAfterAttempt`）；錯過多個時點只補一次。
   **`quietDefer` 保留原本的 `scheduledFor`**：defer 只把 `nextRunAt` 暫移到安靜時段結束，
   `quietDefer.scheduledFor` 仍是原定時點；`begin` 的 run `scheduledFor` 取原定時點，claim 後
   `quietDefer` 清除；仍在 dnd／安靜時段就再 defer，不丟棄。

### 3.2 Revision 3 — host-owned time and intent (owner as contract owner)

**Trigger → current → expected.** The user requires scheduled work to wake the engine and asked for
the root cause to be fixed once. Current (revision 2): Bot routines fire only from the 1 s tick of a
composition already bound to a running engine; DSH session schedules fire only from a `setTimeout`
inside the Worker and the host cannot see their due time; engine backoff and outbox settle retries
are in-process sleeps lost on suspension; connector scans have no cadence of their own. Expected:
host §10.3 — five invariants (intent durable on the host first; time owned by the host; one way in;
one way out; project before suspending), a host-private `WakeDemand` ledger with a closed source
set, a pure wake projection with shared vectors, the iOS channel table, and ReadySweep steps 8–9.

**Delta.**
- `spec/host/v1/README.md`: §10.2 ownership split (host also runs 8–9); §10.2.1 adds `scheduledDemand`
  and `bgAppRefresh`; §10.2.3 lists every provisional constant (adds `connectorScanIntervalMs =
  1800000`, `minBackgroundDelayMs = 60000`); §10.2.5 adds `dshSchedule` (3000) and `hostRetries`
  (2000); new §10.3.
- `spec/host/v1/golden/engine-launch.json` and its schema: `revision` 2; 13 wake reasons, 9 steps,
  `demandSources` (4), `projectionVectors` (7) and `invalidProjectionVectors` (7), six new decision
  vectors, four new sweep vectors, one new invalid decision and one invalid sweep vector.
- `spec/host/v1/tools/test_engine_launch.py`: reference oracle (new).
- `spec/platform/README.md` §14: `fetch`, best-effort scheduling facts, Android channel mapping.
- `spec/bot/v2/README.md` §3.3: nine steps; routine and connector demands.

**Not a new surface.** The `dshSchedule` mirror reads the existing upstream DSH remote
`schedule/list` over the existing transport; no plugin, route, payload, Worker env or DSH patch is
added (P14: none — existing method on the existing `/api/remote.mux` transport). The ledger is
host-private storage; no other process or platform reads its bytes. The cloud-scheduled push channel
is `target` and is not called.

**Compatibility.** old→new: an App without the ledger starts with an empty ledger and fills it on
the first routine change, connector scan or engine-ready mirror refresh; nothing is lost because the
durable queues are unchanged. new→old (rollback): the ledger file is ignored; routines keep their
existing notifications. new→new: both ends read engine-launch revision 2. Android: not started; it
reads the same revision-2 golden when implemented. Old data: no migration. Engine-launch golden revision 1 existed only on this change's branch: against the PR base
`87a2486e` the schema is new (`schema_diff --base 87a2486e` reports 0 breaking findings), and the
only reader of revision 1, the iOS launch unit on the same branch, moves to revision 2 in the same PR.

**Acceptance.** `python3 spec/host/v1/tools/test_engine_launch.py`; `python3 spec/host/v1/tools/host_check.py --root .`;
`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`; iOS: the
PhoneDSHSim golden-driven tests of the launch and Bot units against revision 2.

**Ownership.** ios-launch: ledger, projection, scheduler, BGAppRefresh, `dshSchedule`/`hostRetries`
steps, the two new reasons. ios-bot: `botRoutine` and `connectorScan` demand producers.

## 4. 分工與證據

- **獨占路徑（不可重疊）**
  - `contracts`：`spec/**`、`docs/protocol-changes/**`（本單）。
  - `ios-launch`：`examples/probe-app/PhoneDSHProbe/{EngineLaunchOrchestrator,OffscreenEngineWindow,ChatModel,PhoneDSHProbeApp,CloudTaskCenter,CloudTaskAdmissionBridge,WorkspaceModels,BackgroundKeepAlive,RootView,TonoLinkVoiceHost}.swift`、
    `examples/probe-app/ProbeKit/Lifecycle/**`、`examples/probe-app/Config/PhoneDSHProbe-Info.plist`、
    `examples/probe-app/project.yml`、`examples/probe-app/PhoneDSHSimTests/EngineLaunch/**`、
    `Sources/PhoneDSH/Background/**`。
  - `ios-bot`：`examples/probe-app/PhoneDSHProbe/Bot/**`、`ProbeKit/{GmailAPI,GitHubConnectorAPI,Bot}/**`、
    `PhoneDSHSimTests/BotReadySweep/**`、`Sources/PhoneDSHBot/{Wake,Proactive,Routines,Connectors}/**`、
    `Tests/PhoneDSHBotTests/{ReadySweep,Connectors}/**`、`Sources/PhoneDSHBot/MCP/BotMCPHTTPServer.swift`。
  - `ios-wake-spike`：`examples/probe-app/**/BotResidencySpike/**`、`scripts/ci/bot-residency/**`、
    `docs/perf/engine-wake/**`。
- **共享 fixtures（正例、反例、邊界、未知值）**
  - `spec/host/v1/golden/engine-launch.json`：29 條決策向量（六種 decision 全覆蓋）、11 條無效
    決策向量、16 條 run/skip 向量（七步各自「門檻恰好」與「門檻 −1」，另加 park margin 邊界與
    `remainingMs = 0`）、5 條無效 sweep 向量。Swift（本輪）與 Kotlin（稍後）都直接讀它。
  - `spec/bot/v2/golden/held-inbox.phone.json`：`connectorUpdateGmail`／`connectorUpdateGithub`
    正例，加上 10 條 schema 無效例（未知 connector、item 含正文、Gmail item 帶 repo、缺 cursorTo、
    缺 cursorFrom（missing cursor）、錯 cursor 形狀、count 0、21 項等）與 4 條語義無效例
    （count 不一致、requestId 不一致、空區間、重複 item id）。
  - `spec/bot/v2/golden/connector-cursor.json`：14 條有效（首次建立 ×2、增量 ×3、無變化 ×2、
    GitHub 只有 `lastModified` 改變、損壞／回退 ×4、null lastModified 等）與 13 條 schema 無效例；
    `validate_vectors.py` 用參考實作重算 cursor 與 `emitConnectorUpdate`，另有 3 個 mutation 自檢。
  - `spec/bot/v2/golden/proactive.json`：新增 `connector-update` 的 did 與 quiet-hours skip 向量
    （17 cases / 40 steps）；候選自帶 title／body，無新缺省文案。
- **Status per end.** iOS (`ios-launch`, `ios-bot`): `not started` at freeze — this commit is the
  contract freeze, the implementation follows against this revision. Android: `not started`
  (colleague; same spec/schema/golden). Cloud (`phone-dsh-cloud`): no change required, so its
  status stays as deployed. HarmonyOS: not started (no launch orchestrator).
- **各端真實 producer／consumer 測試**
  - spec checker（本輪在 Linux 實際執行）：`spec/host/v1/tools/host_check.py`、
    `spec/bot/v2/tools/validate_vectors.py`、`spec/v1/tools/test_cloud_tasks.py`、
    `spec/tools/{registry_check,cross_check,schema_diff}.py`。
  - Swift（本輪 NOT_RUN，Linux 無 Xcode／模擬器）：`EngineLaunchTests`（讀 golden）、
    `ReadySweepPolicyTests`（讀 golden）、`ConnectorCursorTests`／`ReadySweepConnectorTests`（讀
    golden）、`BotReadySweepTests`；由調用方在 Mac 執行。
  - Android（not started，無 runtime）：同事按同一份 golden 實作 `EngineLaunchCoordinator`、
    `ReadySweepPolicy`、`ConnectorCursorStore`，以 JVM tests 讀同一批檔案；不得手抄。
  - 真機（NOT_RUN）：後台冷啟動／resume WebContent 耗時、離屏 anchor 能否啟動、LAN 掛起不可達
    與推送回退，由 `ios-wake-spike` 工具在調用方 Mac + iPhone 上量測。
- **驗收命令（逐端）**
  - `contracts`（本輪 Linux）：`python3 spec/tools/registry_check.py`；`python3 spec/tools/cross_check.py`；
    `python3 spec/v1/tools/spec_golden.py --full`；`python3 spec/v1/tools/test_cloud_tasks.py`；
    `python3 spec/host/v1/tools/host_check.py --root .`；
    `python3 spec/bot/v2/tools/validate_vectors.py`；
    `python3 scripts/ci/protocol_impact.py --base 87a2486e --body-file <report>`；
    `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`。
  - iOS（調用方 Mac）：`cd examples/probe-app && xcodegen generate`；
    `xcodebuild test -scheme PhoneDSHSim -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
    （`PhoneDSHSimTests/EngineLaunch` 與 `BotReadySweep` 直接讀本單 golden）；
    `swift build`／`swift test --filter PhoneDSHBotTests`（Connectors／ReadySweep 讀同一批 golden）。
    真機：`bash scripts/ci/bot-residency/run-engine-wake.sh --development-team <id> --lan-host <iPhone LAN IP>`。
  - Android（not started）：`bash android/tools/with-android-toolchain.sh ./gradlew :bot:test :app:testDebugUnitTest`
    加上讀同一份 `engine-launch.json` 的 Kotlin JVM tests；本輪未執行。
  - 雲端：無命令，因為 registration／submit／pull／ack 與 v1.5 相同且未改。
- **Exact commands → 結果（Linux，本輪）**：見 §5 與最終交接；`xcodebuild`、`xcodegen`、XCUITest、
  模擬器與真機一律 `NOT_RUN`。
- **剩餘風險／未支援平台／新 GAP**
  - 三個門檻與七個 step budget 是暫定值，真機 spike 前不得當成已驗證承諾。
  - iOS 後台無 scene 時 WebContent 是否能啟動仍未驗證；若不成立，推送喚醒退化為 native pass +
    BGProcessing（契約已寫明）。
  - Android 未實作：本輪 `spec/ui/v1/bot/strings.json` 刪除 `runtime.notReady` 後，Android 既有的
    生成檔 `android/lib/.../BotUiStrings.kt` 要到 Android 實作時重新生成，`BotUiStringsGoldenTest`
    在那之前會紅；`connector-update` 也要求 Android 的 `proactive-decision`／`BotUiStrings` 生成與
    `ProactiveKind` 對齊。這些是已記錄的跨端不一致，不是本輪可修的（不改 `android/**`）。由
    Android handoff 追蹤。
  - ReadySweep 識別字已由 owner 裁定維持 committed 七個（`userOutbox`、`externalAdmission`、
    `cloudTaskPull`、`botHeldInbox`、`missedRoutines`、`connectorScan`、`approvalReminderSync`）；
    本 revision 不重命名，只補 ownership split 句。
  - 沒有新 GAP；本單不關閉任何既有 GAP。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | contracts | Initial freeze: host §10.2 + golden, cloud-tasks v1.6, external-admission v1.2, bot v2 §3.3 + connectorUpdate/connector-cursor, UI deletion, platform §14. | `ios-launch`, `ios-bot`, `ios-wake-spike`, `integration-review`, Android |
| 2 | contracts | Owner-accepted CCR from ios-bot (seq 61451/61452): `proactive-decision`/`proactive-settings` gain `connector-update` with did/skip vectors; §3.3 freezes the escaped `[connector]` held line and the `HeldMessages.block` opening description; five cursor/item/golden/routine questions answered in §3.1; `connector-cursor` GitHub cursor becomes `{since,lastModified}`. Owner ruling (seq 61474/61478): ReadySweep identifiers stay as committed, ownership split now explicit. No push payload/route/ack, UIBackgroundModes, audio-keepalive or push-SDK change. | `ios-launch`, `ios-bot`, `ios-wake-spike`, `integration-review`, Android |
| 3 | owner (coordinator as contract owner, AGENTS.md §3.1) | User requirement: scheduled tasks must wake the engine; fix the class, not the instance. Host §10.3 host-owned time and intent, engine-launch golden revision 2, reference oracle, `fetch` mode, platform and bot v2 notes (§3.2). | `ios-launch`, `ios-bot`, Android (handoff) |
