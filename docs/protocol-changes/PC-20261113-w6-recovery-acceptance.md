<!-- SPDX-License-Identifier: MIT -->
# PC-20261113-w6-recovery-acceptance — R2：W6 恢復驗收改寫成兩段式

## 0. 摘要

```yaml
change: PC-20261113-w6-recovery-acceptance
contracts: [P02]
status: frozen
breaking: false
version_decision: 無版本變更。`proto 1`、WAL `format 1`、manifest schema、overlay envelope（gzip 包住的 ustar）、任何 schema／golden／持久化位元組都不動；改的是一條**驗收措辭**：把「熱恢復 ≤ 1 秒、與工作區大小無關」拆成「無 mutation ≤ 1 秒（`target`）」與「有 mutation = O(位元組)，只保證線性、不承諾常數」。§8.1 維持 `target`，本輪不把任何東西宣告成 `implemented`。
base: f6b447dfbc83f6e768a5c802184013d2c9b67e26
contract_revision: 本單所屬 commit（R2 freeze）——`spec/v1/wal.md` §8.1（Recovery acceptance 段）、`spec/README.md` §7 GAP-41、`docs/upstream/2026-11-13-overlay-manifest-reader.md`
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。** plan W6 的驗收原本是一條單一承諾：「熱恢復 ≤ 1 秒、與工作區大小無關」。但 boot overlay 由 pinned DSH runtime 的 `readImage`（`storage/image-gzip`，倉外，`scripts/ci/no_dsh_patch.py` 不允許 patch）讀取，只接受 gzip 包住的 ustar；本倉的 `OverlayPacker` 也只能產生 ustar+gzip。只要 watermark 變更（任何回合的 mutation），每次 boot 就得整棵重打包，時間是 O(materialized bytes)。因此原驗收在 upstream 提供 manifest reader 之前**不可能達成**——留著它只會讓下一個人去撞或造假。期望：改寫成**可達成的兩段式**，並把「上游要提供什麼」寫成正式需求。
- **Coordinator / contract owner**：`contracts-1113`（本 worktree）。**Implementer（下一單元）**：`perf-plan-r2`——**不改任何程式碼與 golden**，只把 plan 的 W6 驗收文字換成本單的兩段式（並引用 §8.1）；另由 `contracts-w6`／upstream owner 依 [`docs/upstream/2026-11-13-overlay-manifest-reader.md`](../upstream/2026-11-13-overlay-manifest-reader.md) 對 DSH maintainer 提需求。
- **Owning spec / fixtures**：[wal.md](../../spec/v1/wal.md) §8（boot overlay、cacheability）與 §8.1（`target` manifest）；§14.8 的「唯一一次性遷移是 §8.1 manifest」不變。**沒有新 schema、沒有新 golden 位元組**：本修訂只改驗收語義與其文字；既有 `golden/plan/single-copy.json` 的 overlay／recovery／migration 向量仍有效且不改。
- **受影響 producer／consumer**：
  - **P02 Swift**：`Sources/PhoneDSHLog/OverlayPacker.swift`、`WorkspaceLogService.swift`（watermark-keyed 快取：未變時 hard link，變更時整棵重打包）——**本輪不改**；它們的行為正是 §8.1 描述的現況。
  - **P20 TS**：`plugins/scripts/pack-image.mjs` 只負責 image shard（內容雜湊），不受影響。
  - **P16**：boot URL 的 `overlay=` 參數與 `PhoneDSHHost` 的 `overlays = []` 政策**本輪不改**（那屬於「分層增量」選項，需要另一張變更單；本單不授權）。
  - **plan 文件（倉外／計畫層）**：W6 的驗收文字由實作單更新為兩段式；那是本次唯一要改的文字，**不改任何 gate**。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| 恢復驗收（單一承諾） | 「熱恢復 ≤ 1 秒、與工作區大小無關」→ 撤回。理由與事實寫入 §8.1（每次 watermark 變更仍整棵重打包；plan 的原句不可達）。 |
| 無 mutation 的熱恢復 | 無此分項 → **(1) watermark 未變（快取命中、hard link）的 boot MUST 在 ≤ 1 秒內恢復；`target`，不是量測值**，今日是 O(1)。這是唯一保留的「與工作區大小無關」情形，且只對無 mutation 成立。 |
| 有 mutation 的恢復 | 被原句隐含為「也 ≤ 1 秒、與大小無關」→ **(2) 任何 mutation 後的 boot 是 O(bytes)**：對「必須重打包或重取的位元組」線性；契約**不承諾**與大小無關，也**不再承諾**一個與大小無關的常數。「≤ 1 秒不論大小」是**撤回**，不是延後。 |
| 唯一的數字恢復預算 | `budgets.md` §4 的 `a + k·MB`（`a ≤ 3 s`、`k ≤ 0.05 s/MB`）→ **不變**，仍是唯一數字預算；§8.1 只引用 §4 的公式，不新增第二組數字，並明寫它是 `target` bound，不是量測值。 |
| §8.1 狀態 | `target`、not callable → **仍 `target`、not callable**；新增 tombstones 是 upstream 需求、不是本倉可事後補的細節。 |
| 上游需求 | 散落在 Q1／GAP-41 的敘述 → 正式需求文件：[`docs/upstream/2026-11-13-overlay-manifest-reader.md`](../upstream/2026-11-13-overlay-manifest-reader.md)（C1 manifest reader、C2 blob 按需取、C3 tombstone、C4 能力字串、C5 缺 blob／digest 不符 fail loud）。 |
| GAP-41 登記 | 「plan W6 的熱恢復 ≤ 1 秒、與工作區大小無關在 Linux 容器與現行 runtime 上無法成立」→ 「已改寫驗收、待上游」：無 mutation ≤ 1 秒是 `target`；有 mutation 只承諾 O(位元組)；GAP-41 保持 open。 |
| 條款狀態 | §8／§8.1 本輪沒有 `target → implemented` 的變動；`implemented` 只在第 4 節的驗收證據齊備後才可宣告。 |

**自檢（spec/README.md §5.1）。** 沒有新增第二種表達：仍然只有一個 boot overlay、一種 archive 格式、一條恢復預算（§4）。沒有放寬任何配額或數字：§4 的 `a ≤ 3 s`／`k ≤ 0.05 s/MB`／heap／VFS／quota 全部不動，也沒有把 `≤ 1 秒` 變成 gate。沒有收緊或放寬兩端都讀的訊息：本修訂沒有 wire 訊息（channel／handoff／gateway schema 不動）。沒有新增 enum 或錯誤碼。沒有刪除或重用任何名稱；被改寫的只有一條不可達的驗收句，其「上游阻塞」與「O(materialized bytes)」的事實被保留在新段落（Q1／GAP-41 仍在）。`wal.md` 仍在 D16 的 736 行上限內（實測 735 行）。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | **無資料語義變化。** 舊 host 照舊產生 gzip'd ustar overlay 並照舊 boot；新文件只是不再宣稱一個從未達成的常數。沒有任何 runtime 會讀到本修訂的差異。 |
| new → old | **無影響。** 本修訂不產生新的 archive／manifest／header；舊版讀到的位元組與今天完全相同。回滾不需要遷移。 |
| new → new | 同一份 §8 流程；`golden/plan/single-copy.json` 的 `overlay-manifest-background-build`、`recovery-applies-verified-blob`、`no-wal-migration` 等向量不變且仍必須通過 `plan_cases_check.py`。 |
| persisted old data → new／rollback | **不適用**：沒有持久化格式變更。既有 overlay 快取（watermark-keyed）與 materialized 樹照舊；§14.8 的「唯一一次性遷移是 §8.1 manifest」仍然只是 `target`，本輪不執行、不送清單。 |

- **版本決定**：不升任何版本。`proto 1`、WAL `format 1`、manifest `format` 不變；overlay 仍只有 gzip'd ustar 一種可呼叫格式。理由：這是驗收措辭與上游需求的修訂，沒有跨端位元組被新舊端同時讀取；為它加版本欄位只會製造沒有消費者的版本。
- **部署順序**：spec（本 commit）→ 實作單更新 plan 的 W6 驗收文字（不改碼）→ upstream 依需求文件提供 reader ＋能力字串 → 本倉四端讀同一 manifest schema／golden → 真機量到無 mutation 熱恢復 → 才可把 §8.1 由 `target` 改 `implemented` 並關閉 GAP-41。
- **`target` 與仍保留的差異**：§8.1 manifest 不實作、不呼叫、不送；per-boot overlay archive 仍是 transient 第三份（W6 變更單自述）；`home/sessions/**` 仍在 archive 裡。任何「W6 已把 overlay 變成單副本」或「恢復與大小無關」的宣稱都不成立，實作報告必須照 §8.1 的兩段式寫。

## 4. 分工與證據

- **本單獨占路徑（已在本 commit 完成）**：`spec/v1/wal.md` §8.1、`spec/README.md` §7 GAP-41、`docs/upstream/2026-11-13-overlay-manifest-reader.md`、本單。
- **下一實作單（`perf-plan-r2`）路徑**：**只有 plan 的驗收文字**（W6 段改成兩段式並引用 §8.1）；**不改** `spec/`、`Sources/`、`scripts/`、`plugins/`、`.github/`。若 plan 文字與 §8.1 不一致，以 §8.1 為準並回頭修 plan，不是反過來。
- **共享 fixtures**：本修訂沒有新 golden（驗收是量測與排程語義，spec checker 不能斷言秒數）。既有 `spec/v1/golden/plan/single-copy.json` 的 overlay／recovery／migration／handoff 向量是本單的相鄰 fixture，全部保留、不改、不放寬；`plan_cases_check.py` 與 mutation tests 是本單實際跑的 gate。
- **各端真實 proof 命令（由後續單元執行；本單只跑 spec 檢查）**：
  - `python3 spec/v1/tools/plan_cases_check.py`（本單實跑）
  - `python3 -m unittest spec.v1.tools.test_plan_cases_check`（本單實跑）
  - `bash scripts/ci/check.sh --only phone-cross-tree`、`--only phone-spec`（本單實跑）
  - 真機恢復量測（W0 畫像夾具）：**NOT_RUN / NOT_VERIFIED**——本單不改碼，也不宣稱 ≤ 1 秒已量到。
  - upstream `readImage` 原始碼重讀：**NOT_VERIFIED**——`PDSH_DSH_CHECKOUT` 在本 worktree 未設定，沿用 §8／§8.1 與 `docs/upstream/README.md` 的既有記載。
- **剩餘風險**：與大小無關的承諾撤回後，plan 若仍有「熱恢復 ≤ 1 秒」的字樣，會與 §8.1 衝突——由實作單更新 plan 文字關掉這個風險；分層增量 ustar（A1）若 owner 要，需另開 P02／P16／P20 變更單並接受「任何刪除仍整棵重打包」，本單不授權；per-boot archive 仍是 third copy，屬 W6 已登記的邊界，不因本單改變。

### 4.1 命令 → 結果（本 commit 實跑）

```bash
python3 spec/v1/tools/plan_cases_check.py
python3 -m unittest spec.v1.tools.test_plan_cases_check
python3 spec/v1/tools/spec_golden.py --full
bash scripts/ci/check.sh --only phone-cross-tree
bash scripts/ci/check.sh --only phone-spec
wc -l spec/v1/wal.md
```

結果見交付回報（原樣記錄；未能執行的記 `NOT_RUN`）。

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts-1113（contract owner） | owner 於 2026-11-13 裁定 R2：改寫 W6 驗收為「無 mutation ≤ 1 秒（`target`）／有 mutation = O(位元組)，只保證線性」，GAP-41 由「不可達」改記「已改寫驗收、待上游」，並新增 upstream 需求文件；§8.1 維持 `target`。 | all（contract freeze 公告）；P02／P20（受影響端）；upstream（manifest reader＋tombstone＋能力字串需求）；plan owner（W6 驗收文字） |
