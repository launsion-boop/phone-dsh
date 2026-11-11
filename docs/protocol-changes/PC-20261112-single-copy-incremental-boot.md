<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-single-copy-incremental-boot — W6 單副本與增量啟動

## 0. 摘要

```yaml
change: PC-20261112-single-copy-incremental-boot
contracts: [P01, P02, P03, P16, P20]
status: frozen
breaking: true
version_decision: |
  無 wire／proto 版本變更：P01 的 VFS_MUT、P03 的 handoff 端點與 schema、manifest schema、mseq 域、
  CRC32C 值都不變。WAL 新增一種持久記錄種類（op 0xFE，wal.md §14.2），但 header `format` 不升版：
  新端永遠可讀舊 inline 記錄，舊端遇到 0xFE 依 §3 判為未知 op → WAL_CORRUPT → Failed，資料不刪不改；
  因此「新資料 → 舊版本」不是就地可讀，回滾路徑是保留/還原，不是讓舊版解讀 blob 記錄。JSON schema
  只有 plan-cases 的 vector enum 新增值（additive），schema_diff 0 breaking。
base: 488342b21b625f8be74e2e334014aa2cf9a42ba2
contract_revision: 1257395665b5b009ef01eb825c536566f6731168（spec／schema／golden 的凍結 commit；本單另存於其後的 docs commit）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  1. **單副本（P02）。** 現況：同一份位元組至少存兩份——WAL 記錄內嵌 `data`，materialized 再寫一份完整文件；overlay 快取與 response-log 又各自再存。期望：內容尋址 blob 存儲（`blobs/sha256/<hh>/<hash>`，不可變、先落盤再被引用），WAL 對 `data_len ≥ 65 536` 的 write 只寫 blob 引用（`op = 0xFE`），materialized 對**完整 write** 以 APFS `clonefile` 指向同一份 block（COW），不支援克隆時退回**拷貝**（不得硬鏈接）。**邊界（不得誇大）**：大檔是 appended chunk 鏈，clone 不能命名一個 byte range，所以它在壓縮前仍是 blob＋materialized 兩份；壓縮後 blob 被回收、只剩 materialized 一份（與現況相同的穩態）。W6 真正省下的是開啟 epoch 期間的 inline WAL 副本、重複相同 chunk 的去重，以及完整 write ≤15 MiB 的實體單副本；per-boot overlay archive 仍是 transient 第三份，直到 §8.1 可被 runtime 讀取。
  2. **materialized 關係（P02）。** 現況：materialized 是獨立的一份完整拷貝。期望：clone 是優化而非新權威；硬鏈接會讓後續 in-place append／chmod 改到 blob，禁止；Android／非 COW 檔案系統用拷貝，語義與位元組一致，只是沒有省空間。
  3. **overlay（P02/P20）。** 現況：每次 boot 把整棵 materialized 打成 ustar+gzip；快取以 watermark 為鍵，任何回合都令其失效並整棵重打包。期望（**target，本輪不可呼叫**）：改為 `{path, sha256, mode, size}` 清單 + Worker 按需向 `/blobs/sha256/<hash>` 取 blob。**阻塞點：overlay 由 pinned DSH runtime 的 `readImage` 讀取，不在本倉、不得 patch**；本倉只能產生 ustar+gzip。故此項只凍結設計、不變式與上游需求（Q1/GAP-41），不送出清單。
  4. **不可變資源快取（P01/P05/P16/P20）。** 現況：所有回應 `no-store`，loopback 端口隨機，WebKit 快取用不上。期望：只有 content-addressed 路由（`/image/lazy/<sha256>.tar.gz`、`/blobs/sha256/<hash>`）可用 `private, max-age=31536000, immutable`；版本鍵是路徑中的 sha256；URL 不得帶 per-launch token（改用 same-origin launch cookie／Bearer），不得送 `Vary: Cookie`；loopback host:port 對同一安裝固定、綁不到才退回 ephemeral（僅 cache miss，不改正確性或安全）；其餘路由維持 `no-store`；儲存等級 ≥ 2 時把這兩條路由也改回 `no-store`。
  5. **兼容與回滾（P02/P03）。** 舊 WAL（inline 記錄）與舊 materialized 永久可讀、不改寫、不遷移；新資料到舊版是 fail-loud 拒絕，回滾路徑是保留／還原。handoff 線路不變：blob 引用不得跨邊界（見 §3）。
- **Coordinator / contract owner**：`contracts-w6`。**Implementer（下一單元）**：`w6-singlecopy`（Swift `PhoneDSHLog`／`PhoneDSHLoopback`／`PhoneDSHEngine`／`PhoneDSH`、`plugins/worker-entry`、`plugins/scripts`、`shell/crates/pdsh-wal`、`android/core`、對應 tests）；不改 `spec/`。
- **Owning spec / fixtures / schema**：[wal.md](../../spec/v1/wal.md) §1／§3／§5／§5.2／§6.1／§7.2／§8／§8.1／§9／§12／§14；[budgets.md](../../spec/v1/budgets.md) §5／§9；[handoff.md](../../spec/v1/handoff.md) §4；`golden/wal/segment-blob-write.json`（真位元組向量，含完整與 appended blob write）；`golden/plan/single-copy.json`（23 valid／15 invalid），checker `spec/v1/tools/plan_cases_check.py`；`schema/plan-cases.schema.json` 的 vector enum。`channel.md`、`bridge.md`、`gateway-security.md` 無受影響條款（見 §2 自檢）。
- **受影響 producer / consumer（依登記表逐端）**：
  - **P02 Swift**：`Sources/PhoneDSHLog/**`（blob store、WAL writer/reader、materializer、GC、quota）、`Sources/PhoneDSHWire/WAL.swift`（0xFE 編解碼；`WAL.swift` 屬 P02）、`Sources/PhoneDSH/**`（boot/回收接線）。
  - **P02 Rust**：`shell/crates/pdsh-wal/**`（golden 編解碼與恢復規劃；`pdsh-wire` 不含 WAL 記錄）。
  - **P02／P03 Kotlin**：`android/core/src/main/kotlin/com/phonedsh/log/**`、`android/dsh/.../host/{HostWal,WalUplink}.kt`。
  - **P02 TS 對拍 codec**：`plugins/channel/src/wal.ts`（無生產消費者，必須讀同一 golden）。
  - **P01／P20 Swift**：`Sources/PhoneDSHLoopback/LoopbackServer.swift`（cache 標頭、cookie 認證、固定端口）、`Sources/PhoneDSHLog/OverlayPacker.swift`（`target` 清單不啟用）。
  - **P16**：`Sources/PhoneDSHEngine/WebEngineConfiguration.swift`（cacheable URL 不帶 token；固定 origin 由 host 傳入）、`plugins/worker-entry/src/{entry,web-boot}.ts`（`target` 清單讀取的前置）。
  - **P20 TS**：`plugins/scripts/pack-image.mjs`（image shard 的清單／sha256；本輪不改格式，只確認 shard 名稱仍是內容雜湊）。
  - **P03**：`Sources/PhoneDSH/Handoff/**`（snapshot 取在 `base_mseq == wal_seq`）、`android/dsh/.../host` 的 handoff 端。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| blob 存儲 | 無 → `Library/xl/<workspace_id>/blobs/sha256/<hh>/<sha256>`，mode 0600、不可變、temp→rename、永不覆寫；已存在時驗長度（非本 boot 建立者另驗 digest）後重用。依據 wal.md §14.1。 |
| WAL 記錄種類 | 只有 mutation 與 epoch close → 新增 `op = 0xFE` write-by-reference：`op u8｜mode u32｜mflags u8｜append_from u64｜blob_len u32｜blob_sha256 32｜path_len u16｜path`，CRC 仍覆蓋 `mseq ‖ body`。依據 §14.2。 |
| 門檻 | 無 → 單一 mutation 的 `data` ≥ **65 536 bytes** 的 write 寫 blob 記錄；小於門檻仍 inline；mkdir/remove/chmod 永不 by-reference；reader 兩種形式都接受。門檻是 writer 政策，不是 wire 規則。 |
| blob 語義 | 無 → 描述的是 mutation 的 `data`，不是整個檔案：`appended` 時 blob 是 `append_from` 之後的 suffix，所以大檔是一串 blob 記錄、每塊一份。`blob_len ≤ 15 MiB`（channel.md §3.1）。 |
| 寫入順序 | 只有 WAL append → blob temp→rename 先完成、再 append 記錄；level-1 在同一次 `write()` 之後（兩者都在 page cache）；epoch close 先 fsync 本 epoch 的 blob，再 append close 記錄（§5.2 step 1／§14.3）。level-1／level-2 承諾不變。 |
| materialized | 獨立完整拷貝 → 內容與 inline 形式完全相同；完整 write 可用 `clonefile`（COW，獨立 inode，後續 append/chmod 不影響 blob，實體一份）；appended chunk 以拷貝附加，壓縮前仍是兩份、壓縮後一份；**禁止硬鏈接**；無 clone 時拷貝（無空間收益，照實報告）。依據 §14.4。 |
| 引用與 GC | 無 → live set = §7.2 placement 後所有 retained blob record 的 digest；**不新增 manifest 成員、不新增 refcount 檔**（WAL 是唯一引用來源）。startup 與「丟段後的 close」各跑一次 GC；manifest 先 durable 才 unlink blob，之後 fsync shard 目錄。依據 §14.5。 |
| 恢復 | 內嵌 `data` → blob 記錄必須存在、長度等於 `blob_len`、digest 相符；否則 `WAL_CORRUPT` → `Failed`（admission 關閉）。不套用未驗證位元組、不以 materialized 當第二權威。依據 §14.5。 |
| 配額 | WAL 512 MiB 只算 segment → 算 segment + **live blob**；orphan 不計、由 GC 回收；close+compaction+GC 後仍超限才 fail loud。數字不變，涵蓋面變大。budgets.md §9 的 `hostInternalBytes` 加 blob（每份算一次；clone 共享 block 使總和成為上界）。 |
| 不可變資源快取 | 全部 `no-store`、端口隨機 → 只有 `/image/lazy/<sha256>.tar.gz` 與 `/blobs/sha256/<hash>` 可 `private, max-age=31536000, immutable`；版本鍵 = 路徑 sha256；URL 不帶 token、不送 `Vary: Cookie`；固定 origin（綁不到才 ephemeral）；其餘路由不變；等級 ≥ 2 改回 `no-store`。依據 wal.md §8、budgets.md §9。 |
| handoff | 無宣告 → 線路與 schema 不變；phone→remote 在 `base_mseq == wal_seq` 取 snapshot（segment 集為空）；若必須送非空 tail，則在**傳輸副本**把 blob 記錄展開成 pre-W6 inline 形式（同 mseq），本地 WAL 不改寫；remote→phone 不得含 blob 記錄，含則拒絕。依據 §14.7／handoff.md §4。 |
| overlay 清單 | ustar+gzip（唯一可呼叫） → `target` 清單 `{format,boot_id,materialized_upto_mseq,entries[{path,sha256,mode,size}],tombstones[]}` 經 `/image/overlay/<boot_id>.json` 提供，Worker 按需取 blob。**本輪不可呼叫**（pinned DSH `readImage` 不認）。不變式已凍結：VFS 仍是運行期權威、VFS_RESYNC 不變、每 blob 只計一次、缺 blob fail loud。依據 §8.1。 |
| 舊資料／遷移 | 無宣告 → **無需一次性遷移**：舊 inline 記錄永久可讀、不改寫（§5.1）；舊 materialized 不動，直到該路徑再次被寫入；不把既有 materialized「收養」進 blob（需要第二份持久引用，會與 WAL 的崩潰語義分叉）。唯一的遷移是 §8.1 overlay manifest（`target`），背景、可重入、驗證後才汰換舊 archive。依據 §14.8。 |
| 條款狀態 | 新增 §14 為 `implemented`（記錄／存儲／materialization／GC／配額）；§8.1 為 `target`。 |

**自檢（spec/README.md §5.1）。** 沒有新增第二種表達：blob 記錄只取代 write 的 `data`，不是第二種 envelope；`mflags` 沿用既有 bit 0/1。沒有放寬配額：512 MiB 改成涵蓋更多東西（更嚴），其他 quota 不動。沒有收緊或放寬兩端都讀的訊息：`VFS_MUT`／handoff schema／manifest schema 位元組不變；blob 記錄只在本機持久層。新增 enum 值有未知值規則（未知 `op` → `WAL_CORRUPT`，並在 §14.2 明寫）。沒有刪除或重用任何欄位名、frame type、錯誤碼。`channel.md`／`bridge.md`／`gateway-security.md` 無條款受影響：`bridge.md` 是 page↔host，W6 不新增 bridge 方法；`gateway-security.md` 只管模型 gateway 的 response-log 與轉發，靜態／鏡像路由不在其權威內；`channel.md` 的 VFS_MUT 位元組完全不變，overlay 清單是 `target` 且不經 channel。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | **全部可讀。** 舊 inline mutation 記錄、舊 close 記錄、舊 manifest、舊 materialized 樹、舊 overlay archive 都由新端照舊處理（§14.2／§14.8）。新端第一次寫 ≥ 門檻的 write 才產生 blob。實作測試：`segment-1.json`（全 inline）與 `segment-blob-write.json`（混合）都過新 decoder；舊 manifest 不變。 |
| new → old | **fail loud，不丟不改。** 舊端的 WAL decoder 只認 op 1–4；遇到 0xFE 依 §3 判未知 op → `WAL_CORRUPT` → `Failed`，admission 關閉，資料與 blob 都保留。舊端不會降級成 inline、不會刪 blob、不會偽造成功。`segment-blob-write.json` 是這條的 oracle：舊 decoder 必須拒收。 |
| new → new | 同一份 golden 過四端真實 decoder；`op 0xFE`、`blob_len`、digest、mseq 連續、threshold 由 `spec_golden.py` 與 `plan_cases_check.py` 兩層判。 |
| persisted old data → new／rollback | 新端：舊資料照讀，**沒有一次性遷移**（§14.8）；`blobs/` lazily 建立。回滾：把 pre-W6 版本指向同一 workspace 會 fail loud；唯一支援的回滾是保留舊資料／還原（blob 與 WAL 都不得刪），不是就地讓舊版解讀。若需要「新資料→舊版可讀」，必須先做一份把 blob 記錄展開成 inline 的離線匯出（本輪**沒有**實作，也不假裝有）。 |

- **版本決定**：WAL header `format` 維持 1，manifest `format` 維持 1，channel `proto 1` 不變。理由：升 `format` 會讓新端拒絕所有舊 WAL，除非同時做雙版本讀取；而 0xFE 是自描述的新 op，新端讀舊資料 100% 相容，舊端對新資料 fail loud 且不破壞資料，這是較小的 delta。`schema_diff.py --root . --base d988108c1` 對 JSON schema 應報 0 breaking（只有 vector enum 新增值）。
- **部署順序**：`w4-writepath`（已交付 `488342b2`）→ 本凍結 → `w6-singlecopy`。Swift 與 Rust／Kotlin 可分別更新，但三端要用同一 golden；任一端未改，報告必須寫「只讀舊格式、互通理由」，不得聲稱三端完成。`plugins/channel/src/wal.ts` 是對拍 codec，沒有生產消費者，仍須跟 golden。
- **`target` 與仍保留的差異**：§8.1 overlay manifest 不實作、不呼叫、不送；plan W6 的「熱恢復 ≤ 1 秒、與工作區大小無關」在清單可被 pinned runtime 讀取前**不可能達成**（每次 watermark 變更仍整棵重打包），這是 Q1／GAP-41，不是本單可以放寬的條款。`scripts/perf` 的遷移前後容器大小量測由實作單元在 macOS 上跑；Linux 容器只跑決定性檢查。

## 4. 分工與證據

- **獨占路徑（本單元）**：`spec/v1/{wal,budgets,handoff,README}.md`、`spec/v1/golden/{wal/segment-blob-write.json,plan/single-copy.json,README.md}`、`spec/v1/schema/plan-cases.schema.json`、`spec/v1/tools/{spec_golden.py,plan_cases_check.py,test_plan_cases_check.py}`、`spec/README.md` GAP-41、本單。
- **`w6-singlecopy` 路徑**：`Sources/PhoneDSHLog/**`、`Sources/PhoneDSHLoopback/**`、`Sources/PhoneDSHEngine/**`、`Sources/PhoneDSH/**`、`Sources/PhoneDSHWire/WAL.swift`（P02 專屬檔案；若 lead 不授權，則 WAL 編解碼留在 `PhoneDSHLog` 內，不得出現第二份 CRC）、`Sources/PhoneDSHGateway/ResponseLog.swift`、`plugins/worker-entry/**`、`plugins/channel/src/wal.ts`、`plugins/scripts/**`、`shell/crates/pdsh-wal/**`、`android/core/**`、`Tests/PhoneDSH{Log,Loopback,Engine,Wire,Kill}Tests/**`。**不改 `spec/`。**
- **共享 fixtures**：
  - `golden/wal/segment-blob-write.json` — 真位元組：mseq 7 完整 blob write（`blob_len = 65 536`，mflags 1）、mseq 8 appended blob write（`append_from = 65 536`，mflags 2，同一 digest）、mseq 9 inline 小 write、mseq 9 close；`blobs` map 驗證 digest 與長度。
  - `golden/plan/single-copy.json` — 23 valid／15 invalid，涵蓋門檻、mkdir/remove 不得 by-reference、blob_len/data_len、GC（引用／孤兒／manifest 未 durable）、clone/copy/hardlink、cache 路由與等級 2、handoff 空集／展開／回收、缺 blob／digest 不符、舊端拒收、無遷移、配額含 live blob。
- **各端真實 proof 命令（由 `w6-singlecopy` 執行；本單只跑 Linux 可跑的）**：
  - Swift：`swift test --filter PhoneDSHLogTests`（blob 編解碼、materializer clone/copy、GC、kill 矩陣）、`--filter PhoneDSHLoopbackTests`（cache 標頭、cookie 認證）、`--filter PhoneDSHWireTests`（WAL golden）。
  - Rust：`bash scripts/ci/check.sh --only phone-rust-tests`（`cargo test -p pdsh-wal` 讀同一 golden）。
  - Kotlin：`bash scripts/ci/check.sh --only phone-android-tests`（`NativeWalGoldenTest` 加 blob 記錄）。
  - TS 對拍：`cd plugins && node scripts/run-tests.mjs tests/*wal*`（若依賴已裝；未裝記 NOT_RUN）。
  - 本單實跑：`python3 spec/v1/tools/spec_golden.py --full`、`python3 spec/v1/tools/plan_cases_check.py`、`python3 -m unittest spec.v1.tools.test_plan_cases_check`、`python3 spec/v1/tools/plan_cases_check.py`、`python3 spec/tools/{registry_check,cross_check,schema_diff}.py`、`python3 scripts/ci/protocol_impact.py --base 488342b2 --body-file <本單的 Protocol impact 宣告>`（本單元 diff 只觸發 P01/P02/P03；宣告另含 P16/P20）、`bash scripts/ci/check.sh --only phone-spec`、`CI_PROTOCOL_BASE=d988108c1 bash scripts/ci/check.sh --only phone-cross-tree`。**Swift／xcodebuild／XCTest／真機一律 NOT_RUN**，不得寫成 PASS。
- **剩餘風險／open questions**：
  - **Q1（owner 裁定）**：overlay 清單需要 pinned DSH runtime 提供一個能讀 manifest（或可分層帶 tombstone）的 overlay reader／能力協商；本倉不得 patch DSH。在那之前 §8.1 只能 `target`，plan W6 的恢復時間驗收無法在真機上成立。已發 owner／all，並登記 GAP-41。
  - **Q2（實作細節，不需要 owner）**：固定 loopback 端口號由 P16／P20 的實作常數決定（不得用知名服務埠），文件只凍結「同一安裝固定、綁不到退回 ephemeral、token 不變」。
  - **handoff 非空 tail**：若實作選擇不把 snapshot 取在 `base_mseq == wal_seq`，就必須實作傳輸副本的展開（§14.7）；不得直接把 blob 記錄送出去。此為實作選擇，契約兩條路都允許。
  - **單副本的邊界**：完整 write（≤ 15 MiB，含整檔改寫）才是實體單副本；大檔的 appended chunk 鏈在壓縮前仍是兩份，壓縮後回到一份。plan W6 的「穩態佔用約等於工作區本體」不受影響，但任何「大檔立即只剩一份」的宣稱都是錯的，實作報告必須照 §14.4 寫。
  - **WebKit 快取與 cookie 認證**：`readImage` 的 fetch 是否帶 same-origin cookie 尚未在真機驗證；未成立時只是 cache miss（仍走 token），不是正確性問題，但必須在報告記 NOT_VERIFIED。
  - **整合風險**：本單基於 `488342b2`（含首凍結 `e654fe99`）。`contracts` 之後的修訂（`a448b020` 起的 memory-input／retention high-water）也改了 `plan-cases.schema.json`、`plan_cases_check.py`、`spec/v1/golden/plan/`；合併時必須取**向量聯集**（`memory-input`、retention 高水位、`single-copy`），不得覆蓋任一邊。
- **新發現 GAP**：GAP-41（見 spec/README.md §7）。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts-w6 | 初次凍結 W6：blob 存儲、0xFE 記錄、clone/copy、GC、配額、cacheability、handoff 規則、無遷移決策；overlay 清單列為 `target`＋Q1 | all（contract freeze 公告）、owner（Q1） |
