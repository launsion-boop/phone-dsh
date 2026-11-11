<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-w4-writepath-append — W4 persistence write path

## 0. 摘要

```yaml
change: PC-20261112-w4-writepath-append
contracts: [P02, P03, P17]
status: frozen
breaking: false
version_decision: 無 wire／proto 版本變更。WAL 記錄格式、manifest schema、mseq 域不變；watermark 只在 epoch close 推進是對 wal.md §7.1／D18 的既有解讀（結論：允許）；exec ledger 改為 append-only `v:2` NDJSON 並保留 v1 讀取；step 行格式不變；tool-journal 追加式並保留舊檔讀取；空閒 epoch 可跳過 close；CRC32C 值不變。
base: d988108c1ec0c56903d6087c282cc9278bbdfd19
contract_revision: 見交接 head（本單與 spec 同一 commit）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  - **watermark（P02）。** 現況：`WorkspaceLogService.swift` 在**每個 VFS 變更**後 `materializer.fsyncEpoch()` 再 `recordMaterializedUpto`，每次重寫 manifest（temp fsync、rename、目錄 fsync），每回合 fsync 次數與寫入位元組遠高於必要。期望：契約結論是 **watermark 只在 epoch close 推進符合 wal.md §7.1 與 D18**；in-memory watermark 仍逐筆推進，manifest 只在 close／reconcile／刪段前寫，且必須在 §5.2 step 1 之後。每變更重寫是優化缺陷，不是契約要求。
  - **exec ledger（P03/P17）。** 現況：`SideEffectLedger.appendExecEvent` 每個輸出事件把整個 entry 重寫並 fsync/rename/目錄 fsync，寫入量隨輸出長度平方增長。期望：append-only `exec/<idem_key>.ndjson`（v2 header + event lines），舊 `exec/<idem_key>.json` 仍可讀，第一次 append 時安全遷移；record-before-emit 與 replay 不變。
  - **step 記錄（P03）。** 現況：每次轉移 3–5 次 fsync，小數 id 的 step 快照寫兩次。期望：行格式不變、每轉移 append 一行；terminal 行與 epoch close 才 fsync；不重複寫 snapshot。
  - **tool-journal（P17）。** 現況：`journal.ts` 每次追加重讀並解析整個會話檔；完整結果在 executed 與 done 各存一份；`index.ts` 的 start 記錄沒有 await，與自身註解「journal start (fsync)」矛盾。期望：增量追加、結果只存一份（另一處存引用）、start 被 await 且 fsync——以契約為準是「讓程式碼符合註釋」，不是改註釋。
  - **空閒 epoch（P02）。** 現況：每 45 秒的週期 close 沒有「無變化」判斷，空閒時仍做兩次 `F_FULLFSYNC` 並新建段。期望：自上次 close 後無 mutation、無新段、無待物化、無 outstanding resync，則可跳過 close；需要 handoff／drain／teardown／planned restart 時仍按 §5.2 做該做的部分。
  - **冷啟動掃描／CRC32C（P02）。** 現況：`RecoveryManager` 與 `WALWriter` 各把整個 WAL 讀進內存一次，`sealForStop` 也整體重掃；CRC32C 逐位元組查表。期望：流式掃描、交接恢復狀態不重掃；CRC32C 可用硬體指令或切片算法，但結果必須與 Castagnoli 查表完全一致。
- **Coordinator / contract owner**：`contracts`。**Implementer**：`w4-writepath`（`Sources/PhoneDSHLog`、`Sources/PhoneDSHController`、`Sources/PhoneDSH`、`ChannelServer.swift`、`plugins/tool-journal`、`shell/crates/pdsh-wal`、`android/core`、對應 tests）；不改 `spec/`。
- **Owning spec / fixtures**：[wal.md](../../spec/v1/wal.md) §13（watermark 與空閒 epoch）；[exec.md](../../spec/v1/exec.md) §8（append 格式）；`golden/plan/append-records.json`（3 valid／4 invalid），checker `plan_cases_check.py`。
- **受影響 producer / consumer**：Swift `PhoneDSHLog`／`PhoneDSHWire/WAL.swift`／controller；Rust `shell/crates/pdsh-wal`；Kotlin `android/core/**/log` 與 `android/dsh/**/host`；TS `plugins/tool-journal`；`ChannelServer` 的 group commit。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| watermark 推進 | 每 VFS 變更重寫 manifest → **只在 epoch close 推進**（in-memory 逐筆推進）。依據：§7.1 要求 close 時寫、刪段前寫，且 §5.2 step 1 先 durable；不要求每 mutation 寫。manifest 若在 step 1 前寫會命名未 fsync 位置，禁止。 |
| watermark 崩潰 | 未寫 → 持久值落後，崩潰後從舊 watermark replay §6 冪等（apply/skip/repair），不丟不重。 |
| droppable 影響 | 未寫 → 段要到覆蓋它的 close 才 droppable；與 §9「epoch durable」完全一致，per-mutation 推進不會更早。 |
| exec ledger | 每 event 整份重寫 → `exec/<idem_key>.ndjson` v2：line 1 header、後續 `{seq,event}` 遞增 append；event 先記錄再 emit；terminal append fsync；v1 `.json` 可讀，第一次 append 寫新檔、fsync、rename 成功後才不再讀舊檔。 |
| step 記錄 | 每次 3–5 fsync、重複 snapshot → 行格式不變、append 一行；terminal + epoch close fsync；不重複快照。 |
| tool-journal | 每次追加重讀整檔、結果存兩份、start 不 await → 增量 append、結果存一份（done 存 ordinal/hash 引用）、start await + fsync；舊檔可讀、不改寫。 |
| 空閒 epoch | 每 45 秒必 close → 自上次成功 close 後無 mutation、無新段、無待物化、無 outstanding resync，可跳過（不 F_FULLFSYNC、不建段、不送 level-2 ACK）；必要 close 仍按 §5.2。 |
| group commit | `beginAppend`/`endAppend` 串行化、每批一條 → 多個變更共享一次 write；mseq 順序與 ACK 語義不變；2 ms／256 KiB 邊界不變。 |
| CRC32C | 逐位元組查表 → 硬體/切片加速，**輸出必須完全一致**；known answer `crc32c("123456789") == 0xE3069283` 與 golden 不變。 |
| 冷啟動 | 整份 WAL 讀兩次、seal 重掃 → 流式掃描、交接狀態不重掃；恢復結果與 bytes 不變。 |
| 三端 | 未寫 → Swift 在 `PhoneDSHLog`／`WAL.swift` 先做；Rust `pdsh-wal` 與 Kotlin `android/core/log` 讀同一 golden；哪端不動要寫明互通理由。 |

自檢（baseline §5.1）：watermark 結論沒有放寬 durable 順序；exec ledger v2 是新檔＋舊檔讀取，不是改寫 v1；step 行沒有新欄位；tool-journal 結果引用不是第二份結果；沒有新增 frame、manifest member 或版本欄位。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；測試 |
| --- | --- |
| old → new | 舊 WAL／manifest／step／tool-journal 檔照舊讀。舊 exec `.json` entry 由新端讀成 header+events；舊 step 行格式不變。舊 host 第一次 close 後才回收段，資料仍可讀。 |
| new → old | 新端沒有改 WAL/manifest/step bytes；舊端讀同一段與同一 manifest。新 exec `.ndjson` 是舊端不認得的檔名：舊端看不到新 entry（不會 replay、也不會重跑），因為舊端只找 `.json`；這是回滾限制，不是資料遺失——v1 `.json` 在新端遷移成功前一直保留。新 tool-journal 仍是 NDJSON，舊端可讀舊檔，新檔的結果引用可能讓舊端找不到完整結果，回滾時應保留 executed 行（本修訂要求結果只存一份，舊端讀引用需 adapter；因此回滾前必須確認沒有未完成 journal）。 |
| new → new | 兩端都遵守 append-only、單一結果、start fsync、空閒 skip、CRC 一致；shared golden 是 oracle。 |
| persisted old data → new／rollback | 無 WAL/manifest migration。exec v1→v2 是 lazy、可重入的檔案新增，舊 `.json` 在成功前不刪。step 無 migration。tool-journal 舊檔只讀、從不原地改寫。回滾到舊版：WAL 可讀；exec 新 `.ndjson` 不被舊版辨識（entry 不可 replay，但沒有重跑副作用）；tool-journal 需保留舊檔。 |

- **版本決定**：無 proto／wire 版本變更。WAL format 1、manifest schema、step 行、CRC32C 值、jseq 域不變；exec ledger 的 `v:2` 是新持久化檔版本，v1 永久可讀。
- **部署順序**：`w4-writepath` 必須在 `w3-storage` 之後（兩者都動 `PhoneDSHLog`）。Swift、Rust、Kotlin 可獨立更新，但三端要用同一 golden；任一端不改要寫明「它只讀舊格式、互通理由」。
- **仍保留的差異**：Rust／Kotlin 目前只斷言舊格式可讀，append 格式的生產端本輪不一定改；報告必須逐端寫明 not started／partial，不能說三端已完成。

## 4. 分工與證據

- **獨占路徑（contracts）**：`spec/v1/wal.md` §13、`spec/v1/exec.md` §8、`golden/plan/append-records.json`、checker、本單。
- **w4-writepath 路徑**：`Sources/PhoneDSHLog/**`、`Sources/PhoneDSHController/**`、`Sources/PhoneDSH/**`、`Sources/PhoneDSHLoopback/ChannelServer.swift`、`plugins/tool-journal/**`、`shell/crates/pdsh-wal/**`、`android/core/**`、`Tests/PhoneDSH{Log,Controller}Tests`、`Tests/PhoneDSHTests`、`Tests/PhoneDSHKillTests`。
- **共享 fixtures**：`append-records.json`（exec v2、step、tool-journal 正向；兩份結果、原地改寫、start 不 await、舊格式不可讀 negative）。
- **Exact commands → result**（Linux 容器）：
  - `python3 spec/v1/tools/plan_cases_check.py` → PASS（append-records 3 valid/4 invalid）。
  - `python3 spec/v1/tools/spec_golden.py --full` → PASS（102 files，0 error）。
  - `bash scripts/ci/check.sh --only phone-rust-tests` → NOT_RUN（容器沒有 cargo；缺失是 SKIP／INCOMPLETE，不是 PASS）。
  - `swift test --filter PhoneDSHLogTests` → NOT_RUN（Linux 無 Apple Swift 工具鏈）。
  - `cd plugins && node scripts/run-tests.mjs "tests/*tool-journal*"` → NOT_RUN（依賴未安裝；由呼叫方或 `w4-writepath` 執行）。
- **未執行**：20 次 kill 矩陣、舊格式升級、Rust/Kotlin golden、真機；一律 NOT_RUN，由 `w4-writepath` 與呼叫方執行。
- **風險／GAP**：watermark 只在 close 推進會讓 manifest 落後；依賴 §6 冪等 replay，必須有 kill 矩陣覆蓋。group commit 的 2 ms／256 KiB 邊界不能因批次變大而改。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts | 初次凍結 watermark 結論、append 格式、空閒 epoch 與三端分工 | all（contract freeze 公告） |
