Protocol impact: none — measurement report only
<!-- SPDX-License-Identifier: MIT -->

# W0 合成夾具基線（synthetic fixture）— 2026-11-12

- 量測時 base commit：`59e5af95fb73f71e8c267dfd407020e1b1eb3cfa`（`main@59e5af95f`）
- 量測時分支：`docs/perf-baseline`
- 量測日期：2026-11-12（Asia/Taipei）
- 畫像／seed：`light`、`typical`、`heavy` / `1`（`--seed` 未給時預設為 1）
- 量測工具：`scripts/perf/generate_container.py`、`scripts/perf/measure_container.py`（本報告未修改這兩個腳本）
- 本報告只新增本檔；沒有改 `spec/`、`scripts/perf/`、`Sources/`、`.github/`，也沒有改 `spec/v1/golden/plan/perf-targets.json`。

> **一句話結論**：在 arm64 macOS host、seed=1、預設不產生 store stubs 的設定下，三個畫像的夾具邏輯位元組是 light **53,944,900**、typical **171,950,678**、heavy **355,664,500** bytes。這是**夾具基線**，不是真機基線，不能填入 `perf-targets.json` 的任何 `待基线`。

## 1. 這份基線的定位

### 1.1 它是什麼

這是 W0 合成容器夾具的第一份可重現位元組基線：

- 三個畫像由同一份生成器在 seed=1 下產生，目錄放在 `/tmp`，不進 repo。
- 每個畫像用同一份統計工具量一次；本文的 `total_bytes`、`categories`、`breakdown` 全部來自實際 stdout，沒有估算。
- 它可作為日後修改 `generate_container.py` 或 `measure_container.py` 後的回歸下限；比較時必須固定 profile、seed、工具 commit 與 `--store-stubs` 設定。
- 它同時記錄了機器、Python、Xcode、命令與每一步的 wall-clock 耗時，讓另一個人在同一 host 上可以重跑。

### 1.2 它不能證明什麼

以下全部**沒有**被這次量測覆蓋：

- **真機 I/O**：沒有 App process、沒有檔案系統 syscall，因此沒有 `fsync`、`F_FULLFSYNC`、寫放大、I/O 排隊、APFS 寫入行為或真實的每回合寫入成本。
- **jetsam／記憶體**：沒有 resident set、memory pressure、背景凍結或終止；不能證明重度畫像連續 8 小時不進 `Failed`、不被 jetsam。
- **功耗／喚醒**：沒有 timer、CPU wakeup、能源或背景執行；不能證明 `idle_10m_wakeups` 或 `idle_10m_bytes_written`。
- **系統回收**：沒有 `Library/Caches` 被系統清除、低儲存狀態、volume headroom 或 APFS clone/compression 行為；不能證明 W3 的回收或「系統回收後可重建」。
- **延遲**：沒有 UI、WebView、loopback、模型或網路；不能證明 `cold_start_to_sendable_ms` 或 `first_token_latency_ms`。
- **真實 store 佈局**：預設夾具只建立 `materialized/` 會話與工作區，以及一個 manifest；WAL、journal、steps、exec ledger、response-log、overlay、轉錄快照都不存在。它不能證明宿主實際的 store 大小或目錄配額。
- **實體空間**：`measure_container.py` 量的是 `st_size` 邏輯位元組，不是 APFS 配置的區塊；hardlink 去重數為 0，clone/共享區塊、稀疏檔、壓縮都沒有被建模。這個 `total_bytes` 不能當獨佔空間。
- **耐久性／崩潰一致性**：夾具的 JSONL 沒有被真實 App 載入或 replay；沒有 kill、power-loss、torn write 或多程序競態。
- **機型／iOS 矩陣**：只有這一台 macOS host；沒有 iPhone 型號、iOS 版本、散熱、低電量模式或儲存壓力的差異。

### 1.3 讀數字時的三個限制

1. **`total_bytes` 含 manifest**：`perf-fixture.json` 也是一般檔案，會被算進 `other`；三個畫像的 `other` 分別是 580、598、628 bytes。因此 `total_bytes = sessions + workspace + manifest`，不是恰好等於兩個 profile 目標的和。
2. **預設沒有 store stubs**：本文沒有用 `--store-stubs` 當基線。`--store-stubs` 產生的 WAL/journal/steps/response-log/overlay 檔案是「確定的位元組佔位」，大小由生成器常數決定（例如 WAL 取 workspace 的 1/12），不是量測值；把它們填進 `categories` 只會得到生成器的算式，不能當真機或 W3 的證據。
3. **只和同口徑比較**：同一 profile、同一 seed、同一工具 commit、同一 `--store-stubs` 設定才有可比性。生成器一旦改動文字長度、git object 或 padding，`total_bytes` 會變；不能拿舊數字直接比新夾具。

## 2. CLI、輸出結構與畫像定義

### 2.1 `generate_container.py --help`（實際輸出，exit 0）

```text
usage: generate_container.py [-h] --profile {heavy,light,typical}
                             --output OUTPUT [--seed SEED]
                             [--workspace-id WORKSPACE_ID]
                             [--sessions SESSIONS] [--workspace-mib MIB]
                             [--longest-session-mib MIB]
                             [--short-session-mib MIB] [--store-stubs]
                             [--force]

Generate a deterministic phone-dsh W0 app-container fixture.

options:
  -h, --help            show this help message and exit
  --profile {heavy,light,typical}
  --output OUTPUT       container directory to create
  --seed SEED           deterministic seed (default: 1)
  --workspace-id WORKSPACE_ID
                        Library/xl/<workspace-id> name (default:
                        perf-<profile>-<seed>)
  --sessions SESSIONS   override the profile's session count
  --workspace-mib MIB   override workspace size in MiB
  --longest-session-mib MIB
                        override longest session size in MiB
  --short-session-mib MIB
                        override the other sessions' size in MiB
  --store-stubs         also write size-only WAL/journal/steps/response-
                        log/overlay stubs
  --force               replace an existing output directory
```

`--profile` 的 choices 是 `heavy, light, typical`（help 依字母排序）；本文使用 `light`、`typical`、`heavy`。`--output` 與 `--profile` 都是必填。`--workspace-mib`、`--longest-session-mib`、`--short-session-mib` 的單位是 MiB，型別是浮點數，程式會換算成整數 bytes。

### 2.2 `measure_container.py --help`（實際輸出，exit 0）

```text
usage: measure_container.py [-h] [--output OUTPUT] [--pretty] root

Report the byte footprint of a phone-dsh app container.

positional arguments:
  root             container directory to measure

options:
  -h, --help       show this help message and exit
  --output OUTPUT  write the JSON report here instead of stdout
  --pretty         indent the JSON (default: one line)
```

`root` 必須是目錄；不存在或不是目錄時回傳 exit 2。`--output` 會建立父目錄並寫檔，`--pretty` 只影響縮排，不影響數字。

### 2.3 `generate_container.py` 的 manifest 結構

成功時 stdout 是一個 JSON object，欄位如下：

| 欄位 | 意義 |
|---|---|
| `schemaVersion` | manifest schema 版本，目前是 1 |
| `fixture` | 固定是 `phone-dsh-w0-container` |
| `profile` | `light` / `typical` / `heavy` |
| `seed` | 生成 seed |
| `workspaceID` | `Library/xl/` 下的 workspace 目錄名 |
| `workspaceRoot` | `Library/xl/<workspaceID>` |
| `projectKey` | 固定是 `--dsh-workspace--` |
| `sessionCwd` | 固定是 `/dsh/workspace` |
| `sessions` | `count`、`longestSessionID`、`longestSessionBytes`、`shortSessionBytes`、`totalBytes` |
| `workspaceBytes` | 工作區所有一般檔案的目標位元組（精確值） |
| `storeStubs` | 是否寫入 size-only store stubs |
| `continuousRun` / `purpose` | 畫像的用途說明 |

`workspaceBytes` 與 `sessions.totalBytes` 是生成器的目標；實際檔案總和會再加上 `perf-fixture.json`。

### 2.4 `measure_container.py` 的 JSON 結構

成功時 stdout 是一個 JSON object：

| 欄位 | 意義 |
|---|---|
| `schemaVersion` | 目前是 1 |
| `root` | 解析後的容器根目錄（macOS 上 `/tmp` 會顯示成 `/private/tmp`） |
| `total_bytes` | 所有一般檔案 `st_size` 的總和；不含 symlink、不含目錄本身 |
| `file_count` | 不同位元組來源的檔案數；hardlink 的重複路徑不重複計 |
| `hardlinks_deduplicated` | 因 `st_nlink > 1` 而跳過的額外路徑數 |
| `categories` | 互斥分類：`wal`、`materialized`、`response-log`、`overlay`、`journal`、`steps`、`exec`、`transcript-snapshots`、`other`；總和等於 `total_bytes` |
| `file_counts` | 每個分類的檔案數 |
| `breakdown` | `materialized` 的子集拆分：`sessions`、`workspace`、`materialized_other`；另有 `other`。這些是子集，不是額外位元組 |
| `subdirectories` | 以 plan 的目錄名直接列出，**重疊視圖**；`sessions`／`workspace` 已包含在 `materialized` 內，不可再加總 |
| `largest_files` | 最大的 20 個檔案（相對路徑與 bytes） |

`_classify()` 是先看路徑中有沒有 store 目錄名，再看 `materialized`；這個順序在真實使用者工作區有同名子目錄時會出錯，見 §8.1。

### 2.5 三個畫像的定義

定義來源是 `scripts/perf/generate_container.py` 的 `PROFILES` 與 `docs/perf/README.md` §1：

| 畫像 | 會話數 | 工作區（MiB / bytes） | 最長會話（MiB / bytes） | 其餘會話（KiB / bytes） | 連續運行 | 用途 |
|---|---:|---:|---:|---:|---|---|
| `light` | 20 | 50 / 52,428,800 | 1 / 1,048,576 | 24 / 24,576 | 每天幾次 | 回歸下限 |
| `typical` | 150 | 150 / 157,286,400 | 7 / 7,340,032 | 48 / 49,152 | 每天 1–2 小時 | 主要驗收口徑 |
| `heavy` | 500 | 288 / 301,989,888 | 20 / 20,971,520 | 64 / 65,536 | 連續 8 小時不殺進程，30 天不重裝 | 穩定性與存儲上限 |

- 會話總目標：light 1,515,520 bytes、typical 14,663,680 bytes、heavy 53,673,984 bytes（最長會話 + 其餘會話）。
- 最長會話的檔案位元組精確等於表上的值；工作區所有一般檔案的精確總和也等於表上的值。這兩個等式由生成器內部的 assertion 保證，本次三個畫像都通過。
- plan §1.3 寫的是「50 MB / 150 MB / 288 MB」；本 repo 的 README 與生成器用 **MiB**。本報告的位元組是 MiB 口徑。若 plan 的 MB 是十進位，heavy 夾具（288 MiB）會比 288 MB 大 4.86%；這個差異需要契約 owner 確認，不能由本報告擅自改 profile。這一點見 §8.3。

## 3. 環境、可重現命令與耗時

### 3.1 機器與工具鏈（實際輸出）

```text
$ sw_vers
ProductName:		macOS
ProductVersion:		26.3.1
ProductVersionExtra:	(a)
BuildVersion:		25D771280a

$ uname -m
arm64

$ python3 -V
Python 3.14.7

$ xcode-select -p
/Applications/Xcode.app/Contents/Developer

$ xcodebuild -version
Xcode 26.5
Build version 17F42

$ sysctl -n machdep.cpu.brand_string
Apple M5 Pro

$ sysctl -n hw.memsize
25769803776

$ sysctl -n hw.ncpu
18

$ git rev-parse HEAD
59e5af95fb73f71e8c267dfd407020e1b1eb3cfa
```

量測前 `/tmp` 所在卷有 926 GiB 容量、130 GiB 可用（`df -h /tmp`）。Xcode 只用於 §7 的真機建置命令；本次夾具量測不需要 Xcode、模擬器或真機。

### 3.2 完整命令

以下命令在 worktree 根目錄執行；輸出重導到 `/tmp`，不進 repo。

```bash
mkdir -p /tmp/pdsh-perf-baseline-20261112 /tmp/pdsh-perf-artifacts-20261112

TIMEFORMAT='real %3R s | user %3U s | sys %3S s'
for p in light typical heavy; do
  { time python3 scripts/perf/generate_container.py \
      --profile "$p" \
      --output "/tmp/pdsh-perf-baseline-20261112/$p" ; } \
    > "/tmp/pdsh-perf-artifacts-20261112/generate-$p.json" \
    2> "/tmp/pdsh-perf-artifacts-20261112/generate-$p.time"

  { time python3 scripts/perf/measure_container.py \
      "/tmp/pdsh-perf-baseline-20261112/$p" ; } \
    > "/tmp/pdsh-perf-artifacts-20261112/measure-$p.json" \
    2> "/tmp/pdsh-perf-artifacts-20261112/measure-$p.time"
done
```

這次使用預設 `--seed 1` 與預設 `--store-stubs=false`；manifest 的 `seed` 欄位是 `1`，`storeStubs` 是 `false`。`--workspace-id` 也使用預設 `perf-<profile>-1`。

### 3.3 每一步的耗時

| 步驟 | light | typical | heavy |
|---|---:|---:|---:|
| `generate_container.py`（wall） | 0.283 s | 0.826 s | 1.941 s |
| `measure_container.py`（wall） | 0.052 s | 0.043 s | 0.067 s |

這些是單次 wall-clock，包含 Python 啟動，**不是** median、min/max，也不是真機或 CI 的效能承諾。每個畫像只量一次；W0 的真機延遲項目才需要 5 次重複取 median。

### 3.4 重現性檢查

同一 seed 重新生成一次，逐位元組比較：

```bash
for p in light typical heavy; do
  python3 scripts/perf/generate_container.py \
    --profile "$p" \
    --output "/tmp/pdsh-perf-baseline-20261112/$p-repro"
  diff -r "/tmp/pdsh-perf-baseline-20261112/$p" \
          "/tmp/pdsh-perf-baseline-20261112/$p-repro"
done
```

三個 `diff -r` 都是空輸出（exit 0），代表重生成的樹逐位元組相同。重生成耗時（只算生成，不含 diff）：light 0.274 s、typical 0.722 s、heavy 1.976 s。這個檢查是在任何 `git` 命令進入夾具之前做的；`docs/perf/README.md` §2.2 提醒：若在夾具內跑 `git status`，git 可能重寫 `.git/index`，之後就不再逐位元組相同。

## 4. 生成輸出（三個 manifest，真實 stdout）

### 4.1 light

```json
{
  "continuousRun": "a few uses per day",
  "fixture": "phone-dsh-w0-container",
  "profile": "light",
  "projectKey": "--dsh-workspace--",
  "purpose": "regression floor",
  "schemaVersion": 1,
  "seed": 1,
  "sessionCwd": "/dsh/workspace",
  "sessions": {
    "count": 20,
    "longestSessionBytes": 1048576,
    "longestSessionID": "session-ceead5b5-6199-40c2-a531-6e1d9be2a04c",
    "shortSessionBytes": 24576,
    "totalBytes": 1515520
  },
  "storeStubs": false,
  "workspaceBytes": 52428800,
  "workspaceID": "perf-light-1",
  "workspaceRoot": "Library/xl/perf-light-1"
}
```

### 4.2 typical

```json
{
  "continuousRun": "1-2 hours per day",
  "fixture": "phone-dsh-w0-container",
  "profile": "typical",
  "projectKey": "--dsh-workspace--",
  "purpose": "primary acceptance profile",
  "schemaVersion": 1,
  "seed": 1,
  "sessionCwd": "/dsh/workspace",
  "sessions": {
    "count": 150,
    "longestSessionBytes": 7340032,
    "longestSessionID": "session-ceead5b5-6199-40c2-a531-6e1d9be2a04c",
    "shortSessionBytes": 49152,
    "totalBytes": 14663680
  },
  "storeStubs": false,
  "workspaceBytes": 157286400,
  "workspaceID": "perf-typical-1",
  "workspaceRoot": "Library/xl/perf-typical-1"
}
```

### 4.3 heavy

```json
{
  "continuousRun": "8 hours without a kill, 30 days without reinstall",
  "fixture": "phone-dsh-w0-container",
  "profile": "heavy",
  "projectKey": "--dsh-workspace--",
  "purpose": "stability and storage ceiling",
  "schemaVersion": 1,
  "seed": 1,
  "sessionCwd": "/dsh/workspace",
  "sessions": {
    "count": 500,
    "longestSessionBytes": 20971520,
    "longestSessionID": "session-ceead5b5-6199-40c2-a531-6e1d9be2a04c",
    "shortSessionBytes": 65536,
    "totalBytes": 53673984
  },
  "storeStubs": false,
  "workspaceBytes": 301989888,
  "workspaceID": "perf-heavy-1",
  "workspaceRoot": "Library/xl/perf-heavy-1"
}
```

### 4.4 manifest 摘要

| 畫像 | `sessions.count` | `sessions.totalBytes` | `workspaceBytes` | `storeStubs` | `workspaceID` |
|---|---:|---:|---:|---|---|
| light | 20 | 1,515,520 | 52,428,800 | false | `perf-light-1` |
| typical | 150 | 14,663,680 | 157,286,400 | false | `perf-typical-1` |
| heavy | 500 | 53,673,984 | 301,989,888 | false | `perf-heavy-1` |

## 5. 量測輸出（真實數字）

以下數字取自附錄 A 的 `measure_container.py` stdout；表格只是把同一份 JSON 的欄位抄出來，沒有估算或補值。

### 5.1 總量與檔案數

| 畫像 | `total_bytes` | `materialized` | `sessions` | `workspace` | `other` | `file_count` | `hardlinks_deduplicated` |
|---|---:|---:|---:|---:|---:|---:|---:|
| light | 53,944,900 | 53,944,320 | 1,515,520 | 52,428,800 | 580 | 53 | 0 |
| typical | 171,950,678 | 171,950,080 | 14,663,680 | 157,286,400 | 598 | 188 | 0 |
| heavy | 355,664,500 | 355,663,872 | 53,673,984 | 301,989,888 | 628 | 538 | 0 |

核對：

- light：52,428,800 + 1,515,520 = 53,944,320；53,944,320 + 580 = 53,944,900。
- typical：157,286,400 + 14,663,680 = 171,950,080；171,950,080 + 598 = 171,950,678。
- heavy：301,989,888 + 53,673,984 = 355,663,872；355,663,872 + 628 = 355,664,500。

`other` 就是 `perf-fixture.json`（580 / 598 / 628 bytes）。`file_counts` 是 `materialized` 52 / 187 / 537 檔、`other` 1 檔，合計 53 / 188 / 538；三個畫像的 `hardlinks_deduplicated` 都是 0。

### 5.2 `categories`（互斥分類）

| 畫像 | `wal` | `materialized` | `response-log` | `overlay` | `journal` | `steps` | `exec` | `transcript-snapshots` | `other` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| light | 0 | 53,944,320 | 0 | 0 | 0 | 0 | 0 | 0 | 580 |
| typical | 0 | 171,950,080 | 0 | 0 | 0 | 0 | 0 | 0 | 598 |
| heavy | 0 | 355,663,872 | 0 | 0 | 0 | 0 | 0 | 0 | 628 |

`categories` 的總和逐列等於 `total_bytes`（工具內部也有 `sum(categories.values()) == total` 的 assertion）。除了 `materialized` 與 `other`，其餘分類都是 0，因為預設夾具不偽造 WAL、journal、steps、exec、response-log、overlay 或轉錄快照。這不是量測失敗，是夾具的設計；真機量測才會有這些 store。

### 5.3 `breakdown`（materialized 的子集）

| 畫像 | `sessions` | `workspace` | `materialized_other` | `other` |
|---|---:|---:|---:|---:|
| light | 1,515,520 | 52,428,800 | 0 | 580 |
| typical | 14,663,680 | 157,286,400 | 0 | 598 |
| heavy | 53,673,984 | 301,989,888 | 0 | 628 |

`materialized` 等於 `sessions` + `workspace`；`materialized_other` 是 0。`breakdown.other` 與 `categories.other` 是同一個 manifest 位元組，不是額外的一份。

### 5.4 最大的檔案

工具輸出前 20 大檔案；各畫像的最大者是：

| 畫像 | 最大檔案 | bytes |
|---|---|---:|
| light | `workspace/assets/bulk-010.bin` | 4,454,561 |
| typical | `workspace/assets/bulk-015.bin` | 9,556,264 |
| heavy | `home/sessions/--dsh-workspace--/<longest-session>/session.v4.jsonl` | 20,971,520 |

這裡的路徑省略了共同前綴 `Library/xl/<workspaceID>/materialized/`。heavy 的最大者是 20 MiB 的最長會話；light/typical 的最大者是工作區的 bulk 檔。`bulk-000` 到 `bulk-014` 之間可能相差 2 bytes，這是把剩餘位元組整除後最後一塊拿餘數造成的，不是分類錯誤；完整 20 項見附錄 A。

## 6. 與 `perf-targets.json` 的逐條對照

`spec/v1/golden/plan/perf-targets.json` 的七條 valid 指標目前全部是 `待基线`。這份夾具基線**沒有一條**可以直接填。逐條如下：

| # | metric | 真機採集點（budgets §7） | 夾具能不能量 | 本次狀態 |
|---:|---|---|---|---|
| 1 | `cold_start_to_sendable_ms` | process start → 第一條使用者訊息被 outbox 接受並投影 | **不能**：沒有 App process、UI、WebView，也沒有 outbox；這是 wall-clock，必須真機。 | NOT_RUN |
| 2 | `first_token_latency_ms` | prompt 被接受 → 第一個 model token 到達頁面 | **不能**：沒有模型、loopback 或頁面渲染。 | NOT_RUN |
| 3 | `fsync_calls_per_turn` | 一個普通回合、所有 store，計 `fsync`/`F_FULLFSYNC` | **不能**：夾具是靜態檔案，沒有 syscall；本分支也缺 per-turn 儀器（§7.5）。 | NOT_RUN |
| 4 | `bytes_written_per_turn` | 一個普通回合，WAL + materialized + journal + steps + exec + response-log | **不能**：同上；不能拿夾具 `total_bytes` 或日誌行數代替。 | NOT_RUN |
| 5 | `idle_10m_wakeups` | 背景 10 分鐘、沒有回合；計宿主 CPU wakeups | **不能**：沒有背景 process、timer 或能源資料。 | NOT_RUN |
| 6 | `idle_10m_bytes_written` | 同一窗口；所有 store，含週期 epoch close | **不能**：同上。 | NOT_RUN |
| 7 | `host_internal_storage_steady_state_bytes` | WAL + materialized + journal + steps + exec + response-log + caches（§9 公式） | **只能部分**：`measure_container.py` 能量 `materialized`（sessions + workspace）與 manifest；預設夾具沒有其他 store，也沒有 caches 或 APFS 實體配置。 | PARTIAL（target 仍 NOT_RUN） |

補充：

- 第 7 條的夾具值可以當「materialized 元件的下限」，但**不是** `host_internal_storage_steady_state_bytes` 的 target 值。target 的定義還包含 WAL、journal、steps、exec、response-log、overlay 快取與轉錄快照；這些在預設夾具不存在。`--store-stubs` 可以讓分類器看到所有 key，但那些 bytes 是生成器常數，不能拿來填 target。
- 第 1、2 條是 wall-clock；`spec/v1/budgets.md` §7 明確說在真機量到之前是 NOT_VERIFIED。host 上的 Python 生成/量測耗時不是這兩個指標。
- 第 3、4 條是 W0 目前最大的缺口：per-turn fsync／寫入位元組的儀器由另一個分支補；本分支只能記 NOT_RUN。
- 本報告**沒有**把任何 `待基线` 換成數字；`spec/v1/golden/plan/perf-targets.json` 保持凍結。把 `待基线` 換掉需要真機證據與契約流程，不是這份報告的權限。

## 7. 真機版程序（本節全部 NOT_RUN）

以下步驟照 `docs/perf/README.md` §5 整理成可執行順序。**本節沒有任何一項在本次執行**：沒有真機、沒有 build/install、沒有 Instruments。`devicectl` 的旗標依 Xcode 版本可能不同，實際跑之前先用 `xcrun devicectl device copy from --help`、`xcrun devicectl device copy to --help` 核對。

### 7.1 前置

```bash
export DEVICE="<xcrun devicectl list devices 的 identifier>"
export BUNDLE_ID="dev.phone-dsh.probe"
export PROFILE=typical          # light / typical / heavy
export SEED=1
git rev-parse HEAD              # 寫進報告
```

另外記錄：iPhone 型號、iOS 版本、量測前後可用儲存、Release build 的 `xcodebuild` 摘要、畫像／seed／workspace id、操作者與日期。這些是 W0 驗收要的欄位，不是夾具能補的。

### 7.2 Release 建置與安裝（NOT_RUN）

```bash
(cd examples/probe-app && xcodegen generate)
xcodebuild -project examples/probe-app/PhoneDSHProbe.xcodeproj \
  -scheme PhoneDSHProbe -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/pdsh-build build
xcrun devicectl device install app --device "$DEVICE" \
  /tmp/pdsh-build/Build/Products/Release-iphoneos/PhoneDSHProbe.app
```

需要 linked Shell 時沿用 README 的 `PDSH_WITH_SHELL=1`。不要用 simulator 或 host build 代表真機。

### 7.3 建立 workspace、放入夾具（NOT_RUN）

1. 第一次啟動 App，讓它建立 `Library/xl/<workspace-id>/`，記下實際的 workspace id。
2. 用同一個 id 生成夾具：

   ```bash
   python3 scripts/perf/generate_container.py \
     --profile "$PROFILE" --seed "$SEED" \
     --workspace-id "<device-workspace-id>" \
     --output "/tmp/pdsh-fixture-$PROFILE"
   ```

3. 只把 `materialized/home/sessions` 與 `materialized/workspace` 放進裝置上對應的 workspace。**不要**覆蓋裝置既有的 `wal/`、`journal.xljournal`、`response-log/`、`steps/`、`exec/`、`overlay*`；也不要把夾具的 `perf-fixture.json` 複製進 App container（它只是本地 manifest，不是 App 資料）。
4. 上傳方式可用 Xcode 的 Devices and Simulators（Installed Apps → Download/Replace Container），或 `xcrun devicectl device copy to`；本報告沒有執行，旗標以 `--help` 為準。複製前先終止 App，避免邊寫邊複製得到不一致的容器。

### 7.4 冷啟動到可發送（`cold_start_to_sendable_ms`，NOT_RUN）

1. 用 `xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID"` 冷啟；讓裝置先靜置至少 2 分鐘。
2. 用 240 fps 螢幕錄影（真機用裝置錄影或外部相機；`simctl io` 不適用真機），同時記錄 process launch 時刻。
3. 從 launch 到輸入框可操作、第一條訊息被接受並投影，數影片幀；同一畫像重複 5 次，記 median、min、max。W1 之前的替代事件是「輸入框可送出且時間線出現本地訊息」。
4. 這次沒有執行，故 NOT_RUN。

### 7.5 每回合 fsync 次數與寫入位元組（`fsync_calls_per_turn`、`bytes_written_per_turn`，NOT_RUN）

**現況：缺儀器。** W0 需要的 per-turn fsync／寫入位元組計數器不在本分支；另一個分支正在補。這兩個指標本次一律 NOT_RUN，不能用夾具的 `total_bytes`、日誌行數、檔案增加量或 `measure_container.py` 的結果推算。

儀器步驟（待儀器落地後執行）：

1. Release build、一個普通使用者回合、所有 store（WAL + materialized + journal + steps + exec + response-log）。
2. 用 Instruments 的 File Activity（`xcrun xctrace record --template 'File Activity' --device "$DEVICE" --attach ...`；模板名稱依 Xcode 版本可能不同）錄一個完整回合。
3. 篩 App process 的 `fsync` 與 `fcntl(F_FULLFSYNC)` 計數；從 syscall 的資料量與檔案寫入事件加總 bytes。若 File Activity 沒有 syscall 明細，改用 System Trace；仍拿不到就記 NOT_RUN，不要估算。
4. 同一回合重跑 3 次，報告 median。

### 7.6 空閒 10 分鐘（`idle_10m_wakeups`、`idle_10m_bytes_written`，NOT_RUN）

1. App 進背景（或鎖屏）且無語音喚醒、沒有回合在跑。
2. 用 System Trace／Energy Log 錄 10 分鐘，計 App process 的 wakeup 次數；同一窗口用 File Activity 加總寫入位元組（含週期 epoch close）。
3. 重複 2 次；若期間有系統更新或低電量模式，記在報告並重跑。
4. 本次沒有真機，NOT_RUN。

### 7.7 宿主內部存儲穩態（`host_internal_storage_steady_state_bytes`，NOT_RUN）

跑完一個典型回合與一次背景 epoch close、終止 App 後，把整個 App 容器抓回本機：

```bash
xcrun devicectl device copy from --device "$DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source . \
  --destination "/tmp/pdsh-container-$PROFILE"

python3 scripts/perf/measure_container.py \
  "/tmp/pdsh-container-$PROFILE" --pretty \
  --output "/tmp/pdsh-size-$PROFILE.json"
```

三個畫像各做一次，報告貼 `total_bytes`、`categories`、`breakdown`、`largest_files`，並註明這是邏輯位元組，不是 APFS 獨佔區塊。這一步可以產生真機的容器大小，但只有在所有 store 與 caches 都存在、且複製完整時才有資格叫 `host_internal_storage_steady_state_bytes`；本次沒有執行，NOT_RUN。

### 7.8 真機報告應包含

- 裝置型號、iOS 版本、可用儲存（前／後）、日期與操作者。
- commit、Release build 設定、profile、seed、workspace id。
- 七條 metric 各自的結果或 NOT_RUN；重複次數與 median/min/max；使用的儀器與模板名稱。
- `measure_container.py` 的原始 JSON（不要只貼 total）。
- 任何偏離：重試、低電量模式、系統更新、背景其他 App、容器複製時的 App 狀態。

## 8. 腳本觀察（未修改 `scripts/perf/`）

### 8.1 `measure_container.py` 的 workspace 同名目錄會分類錯誤（bug／邊界案例）

`_classify()` 先看路徑中有沒有 `wal`、`steps`、`exec`、`journal`、`overlay`、`response-log`、`transcript-snapshots`，最後才看 `materialized`。因此，如果使用者的工作區裡有同名子目錄，裡面的 bytes 會被算成 store，而不是 workspace。

實際重現（在 `/tmp` 建立 7 個 10-byte 檔案，路徑都在 `materialized/workspace/<store-name>/asset.bin`）：

```text
total_bytes = 70
categories = {"exec": 10, "journal": 10, "materialized": 0, "other": 0, "overlay": 10, "response-log": 10, "steps": 10, "transcript-snapshots": 10, "wal": 10}
breakdown = {"materialized_other": 0, "other": 0, "sessions": 0, "workspace": 0}
```

影響：

- 本次三個畫像的工作區只有 `README.md`、`src/`、`tests/`、`docs/`、`.git/`、`assets/`，沒有這些同名目錄，所以 §5 的數字不受影響。
- 真實使用者的工作區可能包含 `steps/`、`exec/` 或其他同名目錄；那時 `measure_container.py` 會把 workspace bytes 記到 store，讓 `host_internal_storage_steady_state_bytes`、`breakdown.workspace` 與百分比全部偏掉。這是真機量測前應該先修的。
- 建議修法（由 `scripts/perf/` 的 owner 決定，本報告不動手）：先判斷路徑是否在 `materialized` 之下，若是就一律算 `materialized`，再分 `sessions`/`workspace`；或只把 store 目錄匹配在 `<workspaceRoot>/` 這一層，而不是任何路徑元件。單元測試目前沒有覆蓋這個碰撞。

### 8.2 沒有 `Library/Caches` 的專屬分類（工具限制，非本次 bug）

`measure_container.py` 的 `categories` 沒有 `caches`。W3 把 overlay 快取、轉錄快照等可重建內容移到 `Library/Caches` 之後，只有名稱含 `overlay`／`transcript-snapshots` 的檔案還會被認出來；其他 cache 會落在 `other`。`host_internal_storage_steady_state_bytes` 的定義包含 caches，所以 W3 之後用這個工具量測時要另外檢查 `Library/Caches` 的位置與分類，不能假設 `other` 等於 0 就代表沒有 cache。W0 的預設夾具沒有 `Library/Caches`，本次不受影響。

### 8.3 MB 與 MiB 的定義差異（文件層級，需 owner 確認）

plan §1.3 寫「50 MB / 150 MB / 288 MB」；repo 的 `docs/perf/README.md` §1 與 `generate_container.py` 的 `PROFILES` 用 MiB。本次 288 畫像的 `workspaceBytes` 是 301,989,888（288 MiB）。若 plan 的 MB 是十進位，兩者差 4.86%；若 plan 只是把 MiB 寫成 MB，則沒有問題。這個差異不影響本次量測的內部一致性，但會影響「288 MB 配額上限」的解讀，應由契約 owner 確認，不應由本報告改 profile 或 golden。

### 8.4 生成器參數與 README 的其餘對照

本次檢查過的 `--profile`、`--output`、`--seed`、`--sessions`、`--workspace-mib`、`--longest-session-mib`、`--short-session-mib`、`--store-stubs` 都與 `docs/perf/README.md` §3 相符；`--workspace-id` 使用預設值，`--force` 由單元測試覆蓋、基線命令沒有使用。沒有發現生成器的參數名稱或單位與 README 不符。`python3 -m unittest discover -s scripts/perf -p 'test_*.py' -v` 的 20 個測試全部通過（見 §9），但如上所述，測試沒有覆蓋 §8.1 的 workspace 同名目錄碰撞。

## 9. 驗證

本報告寫入後、commit 前實際跑過的命令（`git status` 一列是 commit 後）：

| 命令 | 結果 |
|---|---|
| `python3 scripts/perf/generate_container.py --help` | PASS（exit 0；輸出見 §2.1） |
| `python3 scripts/perf/measure_container.py --help` | PASS（exit 0；輸出見 §2.2） |
| 三個 `generate_container.py --profile ...` | PASS（exit 0；manifest 見 §4） |
| 三個 `measure_container.py ...` | PASS（exit 0；JSON 見附錄 A） |
| `python3 -m unittest discover -s scripts/perf -p 'test_*.py' -v` | PASS（20 tests，OK） |
| `bash scripts/ci/check.sh --only phone-hygiene` | **FAIL（pre-existing）**：385 條 findings；`docs/perf/` 0 條。見下方說明。 |
| `git status --short` | commit 後空輸出（clean） |

### 9.1 `phone-hygiene` 的 FAIL 是 base 就存在的

在乾淨的 base commit（量測前 `git status --short` 為空）上，`bash scripts/ci/check.sh --only phone-hygiene` 就已經 exit 1。findings 分佈在既有的 `spec/`、`Sources/`、`android/`、`docs/`、`plugins/`、`Tests/` 檔案；`docs/perf/` 沒有 finding。這些檔案不是本報告新增的，本報告的任務範圍也不允許修改它們（尤其是 `spec/`），所以不能把這個 FAIL 修掉，也不會把它寫成 PASS。

把本檔 `git add` 後重跑同一個命令，findings 總數仍是 385、`docs/perf/` 仍是 0；也就是本報告沒有新增 hygiene finding。這個 FAIL 是倉庫既有狀態，應由 owner 另外處理，不是本量測報告的驗證失敗。

## 10. 未驗證清單與剩餘風險

### 10.1 未驗證（NOT_RUN）

- `cold_start_to_sendable_ms`：沒有真機、UI、outbox。
- `first_token_latency_ms`：沒有模型、loopback 或頁面。
- `fsync_calls_per_turn`：缺 per-turn 儀器；另一個分支補。
- `bytes_written_per_turn`：同上。
- `idle_10m_wakeups`：沒有背景 process 與能源資料。
- `idle_10m_bytes_written`：同上。
- `host_internal_storage_steady_state_bytes`：只有 materialized 元件；WAL/journal/steps/exec/response-log/caches 未量，APFS 實體配置未量。
- jetsam／8 小時連續運行、30 天等效負載、電源、系統回收、低儲存、W1/W3/W4 行為、崩潰/斷電恢復、iPhone 機型與 iOS 矩陣：全部 NOT_RUN。
- 真機建置、安裝、`devicectl` 上傳/下載、Instruments 錄製：本節命令都只是程序，沒有執行。

### 10.2 剩餘風險

- **分類碰撞**（§8.1）：真機 workspace 若有 `wal`/`steps`/`exec` 等目錄，`measure_container.py` 會把 workspace bytes 記成 store；在修好之前，真機的 `host_internal_storage_steady_state_bytes` 可能偏高或偏低。
- **沒有 caches 分類**（§8.2）：W3 之後 `Library/Caches` 的可重建內容可能落在 `other`，需要人工核對。
- **MB/MiB**（§8.3）：288 畫像的配額語意需要 owner 確認。
- **manifest 計入 `total_bytes`**：`other` 不是 0；跨工具比較時要扣掉或說明。
- **夾具不是真機**：即使夾具的會話 JSONL 格式與 repo fixture 一致，也沒有被真實 App replay；不能從這裡推論 recovery、jetsam 或 I/O。
- **生成器變更會移動基線**：任何文字、padding、git object 或 store stub 的改動都會改變 `total_bytes`；比較前要固定 commit 與 seed。
- **hygiene 基礎失敗**：base 已有 385 條 findings；合併前應由 owner 決定是否先修，否則 CI 會一直是 FAIL。本報告只負責證明自己沒有新增。

### 10.3 下一個可執行動作

1. 等真機可用：照 §7 對三個畫像各跑一次容器大小，補齊冷啟動、首 token、fsync、每回合寫入、idle 10 分鐘。
2. 等 per-turn 儀器分支落地：再跑 §7.5，否則這兩條保持 NOT_RUN。
3. 真機數字有了之後，由契約 owner 依 `spec/v1/budgets.md` §7 與 `perf-targets.json` 的流程更新 target；本報告不代為填數字。
4. 把 §8.1 的分類碰撞交給 `scripts/perf/` owner 修，並補一個 workspace 同名目錄的單元測試。

## 附錄 A：`measure_container.py` 原始 stdout

以下是三次執行未經 `--pretty` 的完整 stdout（每行一個 JSON object）。`root` 的 `/private/tmp/...` 是 macOS 對 `/tmp` 的解析結果；量測目錄就是 `/tmp/pdsh-perf-baseline-20261112/<profile>`。

### A.1 light

```json
{"breakdown": {"materialized_other": 0, "other": 580, "sessions": 1515520, "workspace": 52428800}, "categories": {"exec": 0, "journal": 0, "materialized": 53944320, "other": 580, "overlay": 0, "response-log": 0, "steps": 0, "transcript-snapshots": 0, "wal": 0}, "file_count": 53, "file_counts": {"exec": 0, "journal": 0, "materialized": 52, "other": 1, "overlay": 0, "response-log": 0, "steps": 0, "transcript-snapshots": 0, "wal": 0}, "hardlinks_deduplicated": 0, "largest_files": [{"bytes": 4454561, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-010.bin"}, {"bytes": 4454559, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-000.bin"}, {"bytes": 4454559, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-001.bin"}, {"bytes": 4454559, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-002.bin"}, {"bytes": 4454559, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-003.bin"}, {"bytes": 4454559, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-004.bin"}, {"bytes": 4454559, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-005.bin"}, {"bytes": 4454559, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-006.bin"}, {"bytes": 4454559, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-007.bin"}, {"bytes": 4454559, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-008.bin"}, {"bytes": 4454559, "path": "Library/xl/perf-light-1/materialized/workspace/assets/bulk-009.bin"}, {"bytes": 1048576, "path": "Library/xl/perf-light-1/materialized/home/sessions/--dsh-workspace--/session-ceead5b5-6199-40c2-a531-6e1d9be2a04c/session.v4.jsonl"}, {"bytes": 893780, "path": "Library/xl/perf-light-1/materialized/workspace/src/fixture.py"}, {"bytes": 595898, "path": "Library/xl/perf-light-1/materialized/workspace/docs/notes.md"}, {"bytes": 595889, "path": "Library/xl/perf-light-1/materialized/workspace/src/helpers.py"}, {"bytes": 595889, "path": "Library/xl/perf-light-1/materialized/workspace/tests/test_fixture.py"}, {"bytes": 298007, "path": "Library/xl/perf-light-1/materialized/workspace/README.md"}, {"bytes": 133660, "path": "Library/xl/perf-light-1/materialized/workspace/.git/objects/cc/824fc9a22c5e981ed38d1a9efdcd7edfa08498"}, {"bytes": 89652, "path": "Library/xl/perf-light-1/materialized/workspace/.git/objects/cd/7d309bbc742b6347f4cf2c121b82077fc2c3f7"}, {"bytes": 89632, "path": "Library/xl/perf-light-1/materialized/workspace/.git/objects/f5/8b08fa6d21df47a8967a1e184b865680ee05b9"}], "root": "/private/tmp/pdsh-perf-baseline-20261112/light", "schemaVersion": 1, "subdirectories": {"exec": 0, "journal": 0, "materialized": 53944320, "other": 580, "overlay": 0, "response-log": 0, "sessions": 1515520, "steps": 0, "transcript-snapshots": 0, "wal": 0, "workspace": 52428800}, "total_bytes": 53944900}
```

### A.2 typical

```json
{"breakdown": {"materialized_other": 0, "other": 598, "sessions": 14663680, "workspace": 157286400}, "categories": {"exec": 0, "journal": 0, "materialized": 171950080, "other": 598, "overlay": 0, "response-log": 0, "steps": 0, "transcript-snapshots": 0, "wal": 0}, "file_count": 188, "file_counts": {"exec": 0, "journal": 0, "materialized": 187, "other": 1, "overlay": 0, "response-log": 0, "steps": 0, "transcript-snapshots": 0, "wal": 0}, "hardlinks_deduplicated": 0, "largest_files": [{"bytes": 9556264, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-015.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-000.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-001.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-002.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-003.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-004.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-005.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-006.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-007.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-008.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-009.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-010.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-011.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-012.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-013.bin"}, {"bytes": 9556262, "path": "Library/xl/perf-typical-1/materialized/workspace/assets/bulk-014.bin"}, {"bytes": 7340032, "path": "Library/xl/perf-typical-1/materialized/home/sessions/--dsh-workspace--/session-ceead5b5-6199-40c2-a531-6e1d9be2a04c/session.v4.jsonl"}, {"bytes": 1144009, "path": "Library/xl/perf-typical-1/materialized/workspace/src/fixture.py"}, {"bytes": 762717, "path": "Library/xl/perf-typical-1/materialized/workspace/docs/notes.md"}, {"bytes": 762708, "path": "Library/xl/perf-typical-1/materialized/workspace/src/helpers.py"}], "root": "/private/tmp/pdsh-perf-baseline-20261112/typical", "schemaVersion": 1, "subdirectories": {"exec": 0, "journal": 0, "materialized": 171950080, "other": 598, "overlay": 0, "response-log": 0, "sessions": 14663680, "steps": 0, "transcript-snapshots": 0, "wal": 0, "workspace": 157286400}, "total_bytes": 171950678}
```

### A.3 heavy

```json
{"breakdown": {"materialized_other": 0, "other": 628, "sessions": 53673984, "workspace": 301989888}, "categories": {"exec": 0, "journal": 0, "materialized": 355663872, "other": 628, "overlay": 0, "response-log": 0, "steps": 0, "transcript-snapshots": 0, "wal": 0}, "file_count": 538, "file_counts": {"exec": 0, "journal": 0, "materialized": 537, "other": 1, "overlay": 0, "response-log": 0, "steps": 0, "transcript-snapshots": 0, "wal": 0}, "hardlinks_deduplicated": 0, "largest_files": [{"bytes": 20971520, "path": "Library/xl/perf-heavy-1/materialized/home/sessions/--dsh-workspace--/session-ceead5b5-6199-40c2-a531-6e1d9be2a04c/session.v4.jsonl"}, {"bytes": 18600232, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-015.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-000.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-001.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-002.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-003.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-004.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-005.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-006.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-007.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-008.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-009.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-010.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-011.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-012.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-013.bin"}, {"bytes": 18600230, "path": "Library/xl/perf-heavy-1/materialized/workspace/assets/bulk-014.bin"}, {"bytes": 1144009, "path": "Library/xl/perf-heavy-1/materialized/workspace/src/fixture.py"}, {"bytes": 762717, "path": "Library/xl/perf-heavy-1/materialized/workspace/docs/notes.md"}, {"bytes": 762708, "path": "Library/xl/perf-heavy-1/materialized/workspace/src/helpers.py"}], "root": "/private/tmp/pdsh-perf-baseline-20261112/heavy", "schemaVersion": 1, "subdirectories": {"exec": 0, "journal": 0, "materialized": 355663872, "other": 628, "overlay": 0, "response-log": 0, "sessions": 53673984, "steps": 0, "transcript-snapshots": 0, "wal": 0, "workspace": 301989888}, "total_bytes": 355664500}
```

## 附錄 B：這次沒有貼進 repo 的暫存證據

量測的完整檔案在 `/tmp/pdsh-perf-baseline-20261112/`（三個夾具與三個 `-repro`）與 `/tmp/pdsh-perf-artifacts-20261112/`（manifest、measure JSON、time、hygiene 輸出）。它們是暫存檔，不進 repo；本文的數字在附錄 A 已完整保存。

碰撞測試的暫存夾具在 `/tmp/pdsh-perf-collision-20261112/`；它只用來證明 §8.1，不是三個畫像的一部分。
