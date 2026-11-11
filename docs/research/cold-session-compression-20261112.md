# 冷會話壓縮與 `/dsh/transfers` 清理可行性（W3 調研）

- 日期：2026-11-12
- 基線：`d988108c1`（本方案）＋ contracts freeze `2e1f63e4`／W3 `PC-20261112-w3-storage-watermark-tiers`
- 範圍：只調研，不實現；不改 `spec/`、DSH 源碼或 Worker profile。
- 證據：本倉庫代碼與 `spec/`；DSH 側結論引用既有 `docs/research/bot-session-erasure-spike-20261112.md` 對 pinned DSH `66491b0` 的抽查。

## 1. 結論

1. **冷會話壓縮在本輪不可行。** 會話由 Worker 內的 DSH 擁有；宿主只持有 `materialized/home/sessions` 的 WAL 派生副本。上游沒有「導出／導入／物理刪除一個 session」的 RPC，只有 `workspace/archiveSession` / `unarchiveSession`，而它們只把 id 放進 registry-global 的隱藏集合，不刪除、不關閉、不改寫 session 檔案（`docs/research/bot-session-erasure-spike-20261112.md` §2.3）。
2. 若宿主自行壓縮 `materialized/` 裡的會話副本，下一個 epoch 的 WAL replay、overlay pack、`VFS_RESYNC`、materialized invariant 仍要求原始 bytes；壓縮後的檔案既不是 WAL 記錄，也不是 VFS 內容，會直接破壞 `wal.md` §6/§7/§10 的「materialized 只由 WAL 派生」與恢復不變量。**不能把宿主端壓縮當成透明快取。**
3. `/dsh/transfers` 沒有清理、過期或啟動回收邏輯。它是一個無上限的本地檔案存放區（每檔 1 GiB 上限、沒有總量或 TTL），只能由使用者以一般檔案操作刪除；中斷的 pull 會刪掉 `.partial`，但成功檔案永久保留。

## 2. 冷會話壓縮需要什麼

要讓「長期未打開的會話整體壓縮、打開時透明解壓」成立，至少需要下列之一，且必須是上游正式契約：

| 需要的能力 | 為什麼現有介面不夠 | 建議歸屬 |
|---|---|---|
| 上游 session 的 export/import（或 close + compact）RPC | `archiveSession` 只改可見性；`session/list`/history 仍可打開原檔，壓縮副本無法被 DSH 當成同一 session | DSH upstream（`docs/upstream/` 記錄需求），P06/P14 |
| 一個「已封存、可延遲載入」的 session 狀態與 generation 規則 | 現在 generation 選擇、resume、`record://session` 都假設檔案完整可讀；沒有 tombstone/冷段指標 | P02/P06/P17 契約修訂 |
| 可重建索引：冷會話的 metadata、最後訊息、標題留在宿主，正文在壓縮段 | 沒有索引就無法在不打解壓縮的情況下顯示抽屜/列表 | 新契約（P02/P18） |
| 壓縮格式、完整性、密鑰與崩潰一致性 | 需要 CRC/長度、原子替換、可重入解壓、回滾到舊版 | `wal.md` 新節 + golden |
| 與 WAL/overlay/handoff 的相容規則 | 冷會話不能在 replay 時被當成已丟失；handoff snapshot 需帶冷段引用 | P02、P05、P17 |

在缺少上述能力時，唯一安全的替代是**只壓縮不屬於 VFS/權威資料的宿主快取**（例如 response-log 的舊 body、transcript snapshot），而這已由 W3 的分層與 LRU 覆蓋；它不是冷會話壓縮。

### 2.1 建議的上游問題單

1. 是否有計畫提供 `session/export`、`session/import` 或 `session/compact`？若有，generation 與 active handle 的語義是什麼？
2. `workspace/archiveSession` 是否可能增加 `releaseStorage` 或等價選項？目前註釋與實作都只做隱藏。
3. 冷會話被解壓後，DSH 的 `list()` 是否接受「只有 metadata + 冷段引用」的 entry，還是要求完整檔案？
4. handoff 的 snapshot 是否能表達「這個 session 的正文在宿主冷段」？

## 3. `/dsh/transfers` 的清理現況

證據：

- `Sources/PhoneDSHADB/ADBExecProvider.swift`：native store 預設 `Documents/adb-transfers`；pull 先寫 `.adb-<uuid>.partial`，成功後 `fsync` + `rename`，失敗 `defer unlinkat` 刪 partial。
- `Sources/PhoneDSHADB/ADBNativeFiles.swift`：只驗證 path、regular file、單檔 ≤ 1 GiB；沒有 TTL、總量、列舉或清理 API。
- `spec/v1/native-mcp.md`「Worker ADB file transfer bridge」：只規定單檔上限、併發拒絕、`adb stat` 的 running/saved；沒有保留或過期條款。
- 宿主儲存預算（`budgets.md` §9）列舉 WAL、materialized、journal、steps、exec、response-log、overlay、transcript；`/dsh/transfers` 不在其中，也不在 §5 的 quota 表。

| 問題 | 現況 | 風險 |
|---|---|---|
| 總量上限 | 無 | 多個 1 GiB 檔案可佔滿容器；目前只能靠系統／使用者清理 |
| 過期 | 無 | 舊 pull 永久保留 |
| 啟動回收 | 無 | 程序重啟不會掃描 `adb-transfers` |
| 中斷 pull | partial 由 `defer` 刪除 | 程序被殺時 `defer` 不執行，`.partial` 會殘留 |
| 使用者可見狀態 | `adb stat` 只回 running/saved | 沒有「這個檔案佔多少空間」 |
| 與 W3 總預算 | 未計入 | 會低估宿主實際 footprint |

### 3.1 若要納入 W3，最小契約 delta（本輪未做）

1. 把 `Documents/adb-transfers` 計入 `hostInternalBytes`（唯讀大小統計），但**不得**自動刪除已 `saved` 的檔案；它是使用者資料。
2. 啟動時只回收 `*.partial` 且無 running transfer 的孤兒；回收前必須確認 `nativeTransfers` 不含該路徑。
3. 可選：對超過 N 天未 `stat`/未使用的 `saved` 檔案，在 level 3 卡片列出，由使用者一鍵刪除；level 0–2 仍不得自動刪。
4. 為 partial 的命名、崩潰後辨識與 `adb stat` 的 running 狀態補 golden/測試；不得把 running 當成 saved。

以上需要 P16/P05 或 native-mcp 契約新 revision，不能由 W3 實現單元自行加清理規則。

## 4. 本輪 W3 已做／未做

- 已做：WAL 每次 epoch close 回收 droppable 段；response-log 的 128 MiB LRU、可選 `bodyLocation`、cache 目錄、in-flight resume 保護與刪除 API；overlay/transcript 分層與可重入遷移；`Budgets.swift` 的 `hostInternalBytes`/`budgetedBytes` 與五級 policy；ProbeKit 掃描器把 outbox 附件計入總量且任何級別都不刪。
- 未做：冷會話壓縮（本報告 §1–2）；`/dsh/transfers` 自動清理（§3.1，需契約）；真機 Caches 被系統清空、30 天等效負載、容器大小統計（見 W3 報告的 NOT_RUN）。
