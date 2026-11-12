<!-- SPDX-License-Identifier: MIT -->
# 第一次量測真實 app 容器（模擬器）

日期：2026-11-13
儀器：`scripts/perf/measure_container.py`（含 `fix/measure-container` 的分類修正與 `caches` 桶）
容器來源：iPhone 17 模擬器 `6B341EA5-718F-43E3-AE4A-14358D592C9B`，`dev.phone-dsh.probe`，
跑過兩個真實回合（見 [sim-io-smoke-20261113.md](sim-io-smoke-20261113.md)）

Protocol impact: none — measurement report only

## 結果

```text
total_bytes 869,504    file_count 61    hardlinks_deduplicated 0
```

| 分類 | bytes | 說明 |
| --- | ---: | --- |
| `caches` | 434,839 | `Library/Caches/**`，其中 327,680 是 `com.apple.WebKit.GPU` 的 `functions.data` / `libraries.data` |
| `other` | 224,710 | 含 `Library/Application Support/PhoneDSHBot/domain.sqlite-wal`（156,592）與其他未分類檔案 |
| `materialized` | 103,890 | 其中 sessions 77,123（單一會話 `session.v4.jsonl`）、workspace 0、其餘 26,767 |
| `wal` | 66,214 | 最大段 `Documents/chat-host/wal/00000003.000000.xlwal`（55,388） |
| `overlay` | 35,829 | |
| `response-log` | 3,990 | |
| `journal` | 32 | |

## 這份數字證明什麼

1. **W3 的分層在真實容器裡看得見**：`Library/Caches` 佔了 50%（434 KB），也就是可重建內容確實離開了
   Documents。這在合成夾具裡看不到，因為夾具不產生 WebKit 快取。
2. **兩個回合之後的持久面很小**：WAL 66 KB、journal 32 B、response-log 4 KB。回合結束已觸發 epoch close
   與回收。
3. **`measure_container.py` 的分類修正有效**：`materialized`、`wal`、`overlay`、`response-log` 都各自歸位，
   沒有互相污染。

## 兩個發現

1. **`Library/Application Support/PhoneDSHBot/domain.sqlite-wal`（156 KB）落在 `other`。** 分類器沒有
   Application Support 這個桶，Bot 的 SQLite WAL 因此不可歸因。若要讓
   `host_internal_storage_steady_state_bytes` 完整，需要新增 `app-support` 桶（或明說它被計入 `other`）。
2. **`hardlinks_deduplicated = 0`**：這個容器當下沒有 per-boot overlay 的硬連結，符合 W6 目前的邊界
   （GAP-41：overlay archive 仍是 transient 第三方副本，尚未被 hardlink 化）。

## 不能證明什麼

- **不是真機**；`spec/v1/budgets.md` §7 的三畫像欄位明文規定「不得以…模擬器數字填寫」，
  所以 `perf-targets.json` 七列**仍然是 `待基线`**，本報告不動它。
- 只有兩個回合，不是穩態；jetsam、功耗、系統回收、APFS 實體配置、真機 I/O 延遲全部未驗。
- 容器裡含 `com.apple.WebKit.GPU` 這類系統快取，真機的歸屬可能不同。
- 這是**邏輯 `st_size`**，不是 APFS exclusive blocks。

## 重現步驟

```bash
U=<simulator-udid>
xcrun simctl boot "$U" && xcrun simctl bootstatus "$U" -b
C=$(xcrun simctl get_app_container "$U" dev.phone-dsh.probe data)
cp -R "$C" /tmp/sim-container && python3 scripts/perf/measure_container.py /tmp/sim-container
```
