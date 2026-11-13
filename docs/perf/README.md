<!-- SPDX-License-Identifier: MIT -->
# W0 效能基線夾具與量測手冊

本目錄是 plan W0 在 Linux 上可完成的部分：三個畫像的合成 App 容器夾具、容器大小統計工具，以及真機採集步驟。**這裡沒有任何真機數字**；`spec/v1/budgets.md` §7 的數值仍是 `待基线`，只有調用方在真機上跑出的報告才能填。

- 夾具生成器：`scripts/perf/generate_container.py`
- 容器統計：`scripts/perf/measure_container.py`
- 每回合 fsync／寫入位元組（程式內計數器）：`scripts/perf/read_io_counters.py`
- 單元測試：`scripts/perf/test_*.py`
- 契約：`spec/v1/budgets.md` §7、`docs/protocol-changes/PC-20261112-w0-baseline-budgets.md`

## 1. 三個畫像

定義照 plan §1.3。`workspace` 指 `materialized/workspace` 的檔案位元組；`最長會話` 指單一 `session.v4.jsonl` 的位元組。

| 畫像 | 會話數 | 工作區 | 最長會話 | 連續運行 | 用途 |
|---|---|---|---|---|---|
| `light` | 20 | 50 MiB | 1 MiB | 每天幾次 | 回歸下限 |
| `typical` | 150 | 150 MiB | 7 MiB | 每天 1–2 小時 | 主要驗收口徑 |
| `heavy` | 500 | 288 MiB（配額上限） | 20 MiB | 連續 8 小時不殺進程，30 天不重裝 | 穩定性與存儲上限 |

夾具另外固定：

- 其餘會話：`light` 24 KiB、`typical` 48 KiB、`heavy` 64 KiB。這是夾具設計常數，不是效能預算。
- 工作區本身是一個只有一個 commit 的真 git 倉庫（純標準庫寫 loose object、ref 與 index），加上 `assets/bulk-*.bin` 大文件。工作區總位元組精確等於畫像值。
- 最長會話的檔案位元組精確等於畫像值；會話事件在最後一個 `assistant/message` 補齊到目標大小，仍以合法 `step/end`、`turn/end` 收尾。

## 2. 生成的目錄

```text
<container>/
  perf-fixture.json                         # 夾具 manifest（不屬於任何儲存配額）
  Library/xl/<workspace-id>/
    materialized/home/sessions/--dsh-workspace--/<session-id>/session.v4.jsonl
    materialized/workspace/                 # git 倉庫 + assets/bulk-*.bin
  Documents/transcript-snapshots/           # 只有 --store-stubs 才建立
```

預設**不**偽造 WAL、journal、steps、response-log 或 overlay 位元組。它們由宿主在 App 實際跑起來後建立；夾具只提供 DSH 會話副本與工作區本體。需要空跑統計工具時可加 `--store-stubs`，它會寫入確定性的位元組佔位檔；manifest 的 `"storeStubs": true` 明示這些檔案**不是可重放的協定資料**，不要把它們餵給真實宿主。

### 2.1 會話 JSONL 的來源

格式照倉庫既有 fixture 與讀取器，不是臆造：

- `scripts/ci/bot-e2e/fixtures/record/session.v4.jsonl`（header 與 `user/message`、`tool/call`、`tool/result`、`compaction/summary` 的真實欄位）
- `Sources/PhoneDSHBot/Rows/BotSessionLogProjection.swift`（v4 header 與 event envelope 解碼）
- `Sources/PhoneDSH/PhoneDSHAbort.swift`（`session.v4.jsonl` header、`turn/start`、`turn/end` 的實際欄位）
- `Tests/PhoneDSHTests/PhoneDSHDrainRecoveryContractTests.swift`、`Tests/PhoneDSHBotTests/Rows/RowHistoryTests.swift`（header 形狀與事件資料）

生成的 header 是 `{"type":"session","version":4,"id":"session-<uuid>","createdAt":...,"cwd":"/dsh/workspace","isSeeded":false,"delegationDepth":0}`；事件只使用以下既有 type：

`turn/start`、`step/start`、`user/message`、`assistant/message`、`tool/call`、`tool/result`、`step/end`、`turn/end`。

- `seq` 從 0 連續遞增；`time` 單調遞增（毫秒）。
- 表面事件（`user/message`、`assistant/message`、`tool/result`）帶根層 `surfaceOp: "append"`。
- `user/message` 帶 `data.message.role/content` 與 `data.source.kind=user`、`rpcId`；`tool/result` 帶 `data.message.role=tool`、`toolCallId` 與 `data.source.kind=tool`。
- `tool/call.arguments` 是原始 JSON 字串，不是物件。

### 2.2 可重複性

同一 `--seed`、同一畫像、同一工具版本產生逐位元組相同的樹：沒有 wall-clock、inode、隨機 UUID 或字典迭代順序進入輸出。UUID、文字、大文件位元組都由 SHA-256 從 seed 派生。`perf-fixture.json` 也不含生成時間。

`git` 的 `.git/index` 使用全零 stat 欄位與固定 sha，因此 index 本身也可重複；代價是 git 在第一次 `status` 時可能重寫 index（不影響夾具內容，但會改變 `.git/index` 的位元組）。需要逐位元組比較時，請在跑 `git` 之前比較，或忽略 `.git/index`。

## 3. 生成命令

```bash
# 三個畫像（預設 seed=1，輸出到指定容器目錄）
python3 scripts/perf/generate_container.py --profile light   --output /tmp/pdsh-perf-light
python3 scripts/perf/generate_container.py --profile typical --output /tmp/pdsh-perf-typical
python3 scripts/perf/generate_container.py --profile heavy   --output /tmp/pdsh-perf-heavy

# 已存在時必須明確覆蓋
python3 scripts/perf/generate_container.py --profile heavy --output /tmp/pdsh-perf-heavy --force

# 指定 seed、工作區目錄名，或縮小尺寸做本機快速檢查（單位 MiB）
python3 scripts/perf/generate_container.py --profile light --output /tmp/c \
  --seed 7 --workspace-id perf-check --sessions 4 \
  --workspace-mib 2 --longest-session-mib 0.25 --short-session-mib 0.05

# 需要統計工具的空跑資料時（位元組佔位，非真實 store）
python3 scripts/perf/generate_container.py --profile light --output /tmp/c --store-stubs
```

`--workspace-id` 要和真機上 `Library/xl/` 下既有的 workspace 目錄名一致；不給時是 `perf-<profile>-<seed>`。真機採集時建議先讓 App 建立 workspace，再把夾具的 `materialized/` 內容換進去，避免 App 不認得新的 workspace id。

## 4. 容器大小統計

```bash
python3 scripts/perf/measure_container.py /tmp/pdsh-perf-heavy --pretty
python3 scripts/perf/measure_container.py /tmp/pdsh-perf-heavy --output /tmp/heavy-size.json
```

輸出是一個 JSON object，重要欄位：

| 欄位 | 意義 |
|---|---|
| `total_bytes` | 容器內所有一般檔案位元組總和（不含 symlink、不含目錄本身） |
| `categories` | 互斥分類，總和等於 `total_bytes`：`wal`、`materialized`、`response-log`、`overlay`、`journal`、`steps`、`exec`、`transcript-snapshots`、`other` |
| `breakdown` | `materialized` 的子集拆分：`sessions`、`workspace`、`materialized_other`；另有 `other` |
| `subdirectories` | 以 plan 的目錄名直接列出（`wal`、`materialized`、`response-log`、`overlay`、`journal`、`steps`、`exec`、`sessions`、`workspace`、`transcript-snapshots`、`other`）。這是**重疊視圖**：`sessions`／`workspace` 是 `materialized` 的子集，不可再加總 |
| `file_count`、`file_counts` | 不同位元組來源的檔案數（硬鏈接重複路徑不重複計） |
| `hardlinks_deduplicated` | 因 `st_nlink > 1` 而被跳過的額外路徑數 |
| `largest_files` | 最大的 20 個檔案（相對路徑與位元組），供 W3 級別 3 信號參考 |

注意：

- 硬鏈接只算一次；symlink 不跟隨。
- 這是**邏輯檔案位元組**，不是 APFS 配置的實體區塊。APFS `clonefile` 共享的區塊在同一個檔案系統上不會反映在 `st_size`；W6 之後若要量「實體佔用」，需另用 `du`/`stat` 的 block 數或裝置側工具，不能拿本工具的 `total_bytes` 當獨佔空間。本工具在 W0 的用途是同一口徑的相對比較。
- `other` 包含 `perf-fixture.json` 這類夾具檔；真機容器量測時通常為 0 或只有未知檔案。

## 5. 真機採集步驟

以下命令由調用方在本機／真機執行。Fleet 容器沒有 Xcode、模擬器與真機，本單元只驗證生成器與統計工具；所有真機項目在本單元記 `NOT_RUN`。

### 5.1 前置

1. 固定 commit（用 `git rev-parse HEAD` 記錄）與 `--profile`、`--seed`。
2. 用 Release 設定建置並安裝（`PhoneDSHProbe.xcodeproj` 不進倉庫，先用 xcodegen 生成；需要 linked Shell 時沿用 README 的 `PDSH_WITH_SHELL=1`）：
   ```bash
   (cd examples/probe-app && xcodegen generate)
   xcodebuild -project examples/probe-app/PhoneDSHProbe.xcodeproj \
     -scheme PhoneDSHProbe -configuration Release \
     -destination 'generic/platform=iOS' -derivedDataPath /tmp/pdsh-build build
   xcrun devicectl device install app --device "$DEVICE" \
     /tmp/pdsh-build/Build/Products/Release-iphoneos/PhoneDSHProbe.app
   ```
3. 第一次啟動讓 App 建好 `Library/xl/<workspace-id>/`，記下目錄名。
4. 生成夾具（`--workspace-id` 用第 3 步的名字），把 `materialized/home/sessions` 與 `materialized/workspace` 放進該 workspace；或直接把整個 `<container>/Library/xl/<workspace-id>/` 複製進去。**不要**覆蓋真機上已有的 `wal/`、`journal.xljournal`、`response-log/`。
5. 每次量測前用 `xcrun devicectl device process launch --terminate-existing ...` 冷啟，並讓裝置至少靜置 2 分鐘。

### 5.2 冷啟動到可發送（`cold_start_to_sendable_ms`）

採集點：process start → 第一條使用者訊息被 outbox 接受並投影出來（W1 之後；W1 之前以「輸入框可送出且時間線出現本地訊息」為同一事件）。

1. 用 240 fps 螢幕錄影（QuickTime／`xcrun simctl io` 不適用真機；用裝置錄影或外部相機），同時用 `xcrun devicectl device process launch --console` 記啟動時刻。
2. 從 icon 點擊／`process launch` 到第一幀可操作輸入框，數影片幀。
3. 同一 profile 重複 5 次，記 median、min、max；不要只取一次。

### 5.3 首 token 延遲（`first_token_latency_ms`）

採集點：prompt 被接受 → 第一個 model token 到達頁面。

1. 240 fps 錄影同時錄製輸入框送出與第一個可見 token。
2. 5 次一般回合（不是合成 loop），記 median；若上游 retry，從第一次請求開始算，並在報告註明 retry 次數。

### 5.4 每回合 fsync 次數與寫入位元組（`fsync_calls_per_turn`、`bytes_written_per_turn`）

採集點：一個普通使用者回合，所有 store（WAL + materialized + journal + steps + exec + response-log）。

1. 用 Instruments 的 File Activity（`xcrun xctrace record --template 'File Activity' --device "$DEVICE" --attach ...`；模板名稱依 Xcode 版本可能不同）錄一個完整回合。
2. 篩選 App process 的 `fsync` 與 `fcntl(F_FULLFSYNC)`，計數；從 `fsync` 的資料量與檔案寫入事件加總位元組。
3. 若 Xcode 版本的 File Activity 不提供 syscall 明細，改用 System Trace；仍無法取得時記 `NOT_RUN`，不要用日誌行數推算。
4. 同一回合重跑 3 次，報告 median。

#### 5.4.1 程式內計數器（宿主建置）

`Sources/PhoneDSHLog/LogIOCounters.swift` 在 `LogSupport.swift` 實際發出 `write()`、`fsync`、`F_FULLFSYNC` 的位置累加，涵蓋 `PhoneDSHLog` 擁有的 store：WAL 段、journal、materialized 副本、blob store、overlay、manifest。計數只是 `Int` 累加，不改變任何寫入順序、同步點、CRC 或檔案格式；它**永遠開啟**，沒有 Release 開關，也不需要先設定環境變數。以 `FileManager.copyItem` 複製既有檔案的路徑（overlay cache 升級、recovery staging）不經過 `write()`，不計入位元組。

| 呼叫 | 意義 |
|---|---|
| `WorkspaceLogIOCounters.current()` | 目前窗口的 `fsyncCalls` 與 `bytesWritten` |
| `WorkspaceLogIOCounters.settle()` | 回傳目前窗口並重置；回合結束或 epoch close 時呼叫 |
| `WorkspaceLogIOCounters.reset()` | 丟棄目前窗口；回合開始時呼叫 |

宿主端的 turn 邊界在 `Sources/PhoneDSH`，不在這個計數器模組內；接線時在 `turn/start` 呼叫 `reset()`、在 `turn/end` 呼叫 `settle()` 並把回傳的兩個數字寫進診斷／報告。若同一回合中途發生 epoch close，也可以在該邊界 `settle()` 後累加，語意都是「自上次結算以來的持久化工作」。

宿主建置可用下列指令跑一次真實寫入路徑（`WorkspaceLog` 的 append＋journal＋epoch close），取得結算值：

```bash
python3 scripts/perf/read_io_counters.py --pretty
# 解析已擷取的 swift test / console log，而不是重跑：
python3 scripts/perf/read_io_counters.py --log /tmp/swift-test.log --pretty
```

輸出 JSON 的 `fsync_calls_per_turn`、`bytes_written_per_turn` 就是 §7 的兩列口徑。**這是宿主建置的數字，不是真機基線**；真機仍照 5.4 步驟 1–4 用 Instruments 量，兩者不可互相代替。它也只涵蓋 `PhoneDSHLog` 的 store：`steps`、exec ledger 與 response log 在 `PhoneDSHGateway`／`PhoneDSHController`，目前不計入；W0 報告必須註明這個口徑差異。

### 5.5 空閒 10 分鐘（`idle_10m_wakeups`、`idle_10m_bytes_written`）

採集點：process 背景 10 分鐘、沒有回合；計入週期 epoch close。

1. 讓 App 進入背景（或鎖屏）且無語音喚醒，確認沒有回合在跑。
2. System Trace／Energy Log 錄 10 分鐘，計 App process 的 wakeup 次數；File Activity 錄同窗口，加總寫入位元組。
3. 重複 2 次；若裝置有系統更新或低電量模式，記在報告並重跑。

### 5.6 宿主內部存儲穩態（`host_internal_storage_steady_state_bytes`）

採集點：WAL + materialized + journal + steps + exec + response-log + caches（`spec/v1/budgets.md` §9）。

1. 跑完典型回合與一次背景 epoch close 後，把整個 App 容器複製回本機：
   ```bash
   xcrun devicectl device copy from --device "$DEVICE" \
     --domain-type appDataContainer --domain-identifier dev.phone-dsh.probe \
     --source . --destination /tmp/pdsh-container
   ```
2. `python3 scripts/perf/measure_container.py /tmp/pdsh-container --output /tmp/pdsh-size.json`
3. 報告貼 `total_bytes`、`categories`、`breakdown`、`largest_files`；同一份夾具在三個畫像各跑一次。這個值是邏輯位元組，不是 APFS 獨佔區塊（見 §4）。

## 6. 報告模板

```markdown
# W0 baseline — <profile> — <device model>

- Commit: <git rev-parse HEAD>
- Profile / seed: <light|typical|heavy> / <seed>
- Fixture command: <generate_container.py 的完整命令>
- Build: Release, <xcodebuild 命令摘要>
- Device: <model, iOS version, storage free before/after>
- Date / operator: <YYYY-MM-DD> / <name>

## 結果

| Metric | Unit | Result (median) | Min / Max | Command / instrument | Status |
|---|---|---|---|---|---|
| Cold start to sendable | ms | | | | PASS / NOT_RUN |
| First token latency | ms | | | | PASS / NOT_RUN |
| fsync calls per turn | count | | | | PASS / NOT_RUN |
| Bytes written per turn | bytes | | | | PASS / NOT_RUN |
| Idle 10 min: wakeups | count | | | | PASS / NOT_RUN |
| Idle 10 min: bytes written | bytes | | | | PASS / NOT_RUN |
| Host internal storage, steady state | bytes | | | | PASS / NOT_RUN |

## 容器大小

- `measure_container.py` 輸出檔：<path>
- total_bytes: <value>
- categories: `wal=… materialized=… response-log=… overlay=… journal=… steps=… exec=… transcript-snapshots=… other=…`
- breakdown: `sessions=… workspace=… materialized_other=…`
- largest_files: <貼前 5 項>

## 未執行／限制

- <哪些指標沒跑、原因、所需環境>
- <APFS clone/block 共享未計入；模擬器或 host build 不可代替真機>
```

## 7. 驗證

Linux 上可跑：

```bash
python3 -m unittest discover -s scripts/perf -p 'test_*.py' -v
bash scripts/ci/check.sh --only phone-license,phone-hygiene
```

`read_io_counters.py` 另外需要 Swift 工具鏈（它跑 `swift test --disable-sandbox`）；沒有工具鏈時記 `SKIP`／`NOT_RUN`，不要用手算或日誌行數代替。

需要 Xcode／真機才能跑的項目（`xcodebuild`、Instruments、`devicectl`、真機測量）在本單元一律 `NOT_RUN`；不要把它們寫成 PASS。
