<!-- SPDX-License-Identifier: MIT -->
# DEC-20261112-gap41 — W6 overlay manifest：卡在哪個上游能力，以及若不改上游 W6 的實際上限

Protocol impact: none — documentation only

Status: **proposal（供 contracts-w6／upstream 與 P02、P16 owner 簽核）**
對應 GAP: [GAP-41](../../spec/README.md)（P02、P20，open）
權威變更單: [PC-20261112-single-copy-incremental-boot.md](../protocol-changes/PC-20261112-single-copy-incremental-boot.md)（§1.1 與 §3 的 `target` 與 Q1）
前置閱讀: [決策備忘](perf-stability-open-gaps-20261112.md) §2 的 D4

---

## 1. 一句結論

`readImage` 只認「gzip 包住的 ustar」，而且 overlay 是**整檔取代**；本倉不得 patch 它
（`scripts/ci/no_dsh_patch.py` 與 AGENTS §6）。因此 W6 的「熱恢復 ≤ 1 秒、與工作區大小無關」
**在上游給出 manifest（或可分層＋tombstone）reader 之前不可能達成**，這不是本倉可以放寬的條款。
可用的 adapter 只有「用既有的 ordered `overlays` 做分層增量」，但 **tar 表達不了刪除**，所以任何刪除
都會退回整棵重打包——adapter 只能把成本從 O(工作區) 降到 O(自上次完整打包以來的變動)，不能消掉它。

---

## 2. 現況與證據

| # | 證據 | 說明 |
|---|---|---|
| E1 | `spec/v1/wal.md:412-425` | §8.1 的 manifest 是 `target`、**not callable**；`readImage` 在 pinned checkout，本倉不得 patch；今天送 manifest 會 boot 失敗 |
| E2 | `spec/v1/wal.md:380-395` | §8 的現況：**ustar 格式 ＋ 單一 gzip envelope**；裸 ustar 不被容忍，會 boot 失敗；entries 只允許 `home/`、`workspace/`，拒絕 symlink 與特殊檔 |
| E3 | `Sources/PhoneDSHLog/OverlayPacker.swift:1-13` | 為什麼要 gzip：pinned runtime 的 `storage/image-gzip` 對每個 image／overlay 都做 gzip inflate |
| E4 | `Sources/PhoneDSHLog/OverlayPacker.swift:150-196` | packer 遞迴走完 `materialized/home` 與 `materialized/workspace`，**沒有任何排除清單**（所以 `home/sessions/**` 這類路徑若被 materialize 就會進 archive） |
| E5 | `Sources/PhoneDSHLog/WorkspaceLogService.swift:493-517` | 每個 boot 重打包的成本被 watermark-keyed 快取擋住：watermark 未變 → 只做 hard link（O(1)）；watermark 一變 → **整棵重打包** |
| E6 | `Sources/PhoneDSHLog/WorkspaceLogService.swift:590-599` | 快取有效性只看 `format` 與 `watermark` |
| E7 | `Sources/PhoneDSHLog/WorkspaceLogService.swift:493-495` | 檔內註解記錄「100 MB 工作區約 10 秒重打包（手機上實測）」——**本輪未重量測**，只當歷史紀錄引用 |
| E8 | `Sources/PhoneDSHLoopback/LoopbackServer.swift:415-424` | `/image/overlay/<boot_id>.tar` 只服務 `*.tar`，且 boot id 是 32 hex（**per boot，不是內容定址**） |
| E9 | `spec/v1/wal.md:396-402` | cacheability 條款：只有 `/image/lazy/<sha256>.tar.gz` 與 `/blobs/sha256/<hash>` 可以是 `immutable`；`/image/overlay/*` 一律 `no-store` |
| E10 | `Sources/PhoneDSHEngine/WebEngineConfiguration.swift:97-98`、`:223`、`:234-236` | 引擎**支援多個 overlay**（`overlays: [String]`，每個都變成一個 `overlay=` query item），且單一 boot overlay 是另一個 query item |
| E11 | `Sources/PhoneDSH/PhoneDSHHost.swift:4084` | 宿主把 `engineConfiguration.overlays = []` 清空——多層能力存在但**被政策關掉** |
| E12 | `plugins/worker-entry/src/entry.ts:301-302`、`:339-341`、`:583` | Worker 端把 overlays 當**有序陣列**，順序是 `[profileOverlay, ...hostOverlays]`，後者勝 |
| E13 | `plugins/worker-entry/src/web-boot.ts:219-223` | page 端保序解析 `overlay` 與 `overlay[]` 兩種拼寫 |
| E14 | `docs/upstream/0002-overlay-merge-home-patch.patch`（含 `docs/upstream/README.md` 的說明） | upstream 的實際語義：overlay 的 entry **整檔取代** base 的同名檔（連 `home/cordis.patch.yml` 都只能靠 packer 先合併） |
| E15 | `plugins/worker-entry/README.md:308` | data overlay 與 base image 共用同一個 `readImage` envelope |
| E16 | `scripts/ci/no_dsh_patch.py:1-30` | 零 patch 規則的機器強制（`createWorkerHost`／`loadVfsImage`／`MemoryVfs` 等名稱不得出現定義） |
| E17 | `docs/protocol-changes/PC-20261112-single-copy-incremental-boot.md:24` | 變更單自述：**per-boot overlay archive 仍是 transient 第三份**，直到 §8.1 可被 runtime 讀取 |
| E18 | `docs/protocol-changes/PC-20261112-single-copy-incremental-boot.md:73` | 變更單自述：plan W6 的「≤1 秒、與工作區大小無關」在清單可被讀取前**不可能達成** |

---

## 3. 卡在 pinned checkout 的哪個能力（四項，缺一不可）

| # | 缺少的能力 | 今天的事實 | 對應證據 |
|---|---|---|---|
| C1 | **manifest reader**：接受「路徑 → sha256／mode／size」清單並把它當成一層 VFS | 只有「gzip → ustar → 整檔掛載」 | E1、E2、E15 |
| C2 | **blob 按需取**：worker 第一次讀某路徑時才向 `/blobs/sha256/<hash>` 取 bytes | 只有 image shard 的 lazy 機制（`lazy/<sha256>.tar.gz`），**屬打包期概念**，每 boot 不能變 | E1、E9 |
| C3 | **tombstone／whiteout**：刪掉「繼承自前一層」的路徑 | overlay 只能新增／整檔取代，**沒有刪除語義** | E14 |
| C4 | **能力字串協商**：宿主問 runtime「你支援 manifest 嗎」 | 沒有；今天只能靠「送了就 boot 失敗」發現 | E1 |

**C3 是最容易被忽略的一項。** 即使 C1／C2 都到位，只要沒有 C3，每次删檔（session 抹除、修剪、
`tmp` 清理以外的任何移除）都得退回整棵重打包，W6 的目標仍然不成立。

> **NOT_VERIFIED**：本輪沒有重讀 pinned checkout（`PDSH_DSH_CHECKOUT` 在本 worktree 未設定）。
> C1–C4 是依 `spec/v1/wal.md` 與 `docs/upstream/` 的既有記載整理，**不是**本輪對
> `storage/image-gzip` 原始碼的重新核對。

---

## 4. 能不能用 adapter？三個候選，如實標上限

### A1（唯一有實際收益）分層增量 ustar overlay

**做法**：不動格式。把「每次 boot 一整棵」改成「一層一層」：以最近一次完整打包為 base，之後每次
watermark 推進只產生**變動路徑**的 ustar，經既有的 ordered `overlays`（E10–E13）依序套用。定期
（層數或位元組達門檻）做一次完整打包並丟掉舊層。

| 面向 | 內容 |
|---|---|
| 能測到／能達到什麼 | 沒有刪除時，boot 成本 = O(自上次完整打包以來的變動位元組)，通常遠小於 O(工作區) |
| 測不到／達不到什麼 | **刪除**（C3）。任何落在 `home/` 或 `workspace/` 的移除都無法用一層 tar 表達 → 必須立刻完整重打包；因此「與工作區大小無關」**仍不成立** |
| 要動的契約 | **P02**：`wal.md` §8 要新增「分層 overlay」條款（層序、層數上限、何時強制完整打包、刪除即失效）；§8.1 保持 `target`。**P16/P20**：`PhoneDSHHost.swift:4084` 的 `overlays = []` 政策要改（多層 URL 要進 boot URL）；且因為 `/image/overlay/*` 是 `no-store`（E9），**要嘛每層重傳、要嘛新增內容定址的 overlay 路由（P20 的 cacheability 條款要跟著改）** |
| 成本 | 中高：packer 差量、層簿記（哪一層是 base、層數上限）、宿主 URL 產生、四端 decoder（Rust／Kotlin／TS 對拍）＋真機量測 |
| 風險 | ①層膨脹 → boot 要 inflate N 個 archive，可能比一次大 archive 更慢（**未量測**）；②刪除頻率決定收益上限，而 `home/sessions` 這類路徑本來就常變（E4）；③多一層簿記＝多一個可出錯的持久狀態（層清單必須與 WAL 一致，否則 boot 到錯的組合） |

### A2 Worker 自播（boot 後用 VFS 寫入檔案）

**做法**：不靠 overlay reader；Worker 啟動後自己向宿主取 blob，用普通 VFS 寫入建立工作區。

| 面向 | 內容 |
|---|---|
| 能達到什麼 | 真的只取用到的 bytes（首次讀取才抓） |
| 為什麼不可行 | ①`MemoryVfs` 的 seeding 是「靜默」的（`docs/upstream/0001-worker-host-pass-sink.patch` 的語義：image／overlay 掛載不進 mutation sink），而 boot 後的一般寫入**會**進 sink → 變成 WAL mutation／journal 記錄 → 直接破壞「boot 不是使用者編輯」這個前提；②每一次寫入都是一次 channel 往返，開銷遠大於一次 archive inflate；③要修掉①必須在 P02 新增「boot seeding 不進 WAL」的條款，或改 upstream 的 sink 語義 |
| 契約 | P02（新增 seeding 例外）＋P04/P01（大量 VFS 寫入）＋upstream |
| 成本／風險 | 高／高。**不建議**，列出來是為了讓 review 明確排除它 |

### A3 把打包移出 boot 臨界路徑（純工程，不改契約）

**做法**：boot 只 hard link 現有快取，同時在背景為「下一個」watermark 預打包。

| 面向 | 內容 |
|---|---|
| 能達到什麼 | boot 的**阻塞**時間下降（今天的 hard link 已經 O(1)，所以只有「watermark 剛變的那一 boot」受益） |
| 達不到什麼 | 總打包量不變；且每回合都推進 watermark，背景打包永遠追不上（E5），最壞情況是白做 |
| 契約 | 無（純私有實作）。**但**它會讓「上一次失敗的預打包」變成新的持久狀態，需要自己的崩潰規則 |
| 成本／風險 | 低／中（白工、額外 I/O 與電量）。可與 A1 併用，不能取代 A1 |

### A4 接受現況，改寫驗收（什麼都不改）

見 §5；這是**唯一不需要 upstream、也不需要 P02 修訂**的路。

---

## 5. 若上游不改，W6 的實際上限

今天可以如實聲明的上限（每一句都有證據）：

1. **watermark 未變的 boot：與工作區大小無關。** 快取命中 → hard link（E5、E6），成本 O(1)。
2. **watermark 已變的 boot（任何有 mutation 的回合之後）：O(materialized bytes)。** 整棵重打包
   （E5）。歷史紀錄是 100 MB ≈ 10 秒（E7，本輪未重量測）。
3. **per-boot overlay archive 仍是 transient 第三份。** 變更單自己這樣寫（E17）：archive 必須存在，
   因為 runtime 只會讀 archive。
4. **因此 plan W6 的「熱恢復 ≤ 1 秒、與工作區大小無關」不可達**（E18）。可達的最強聲明是：
   「無 mutation 的 boot ≤ 1 秒；有 mutation 的 boot 與工作區大小成正比」。
5. **單副本目標部分成立**：W6 已交付的 inline WAL 副本消除、重複 chunk 去重、完整 write ≤15 MiB 的
   實體單副本仍然有效；不成立的是「overlay 不再是第三份」。

**若採 A1**，第 2 點可以改寫成：「有 mutation 的 boot = O(自上次完整打包以來的變動位元組)；**任何刪除**
退回 O(工作區)」。這仍然不是 plan 的那句話，但比現況誠實且可量測。

---

## 6. 建議

1. **立刻做（P02／owner，零 upstream 依賴）**：把 W6 的驗收改寫成 §5 的 1–4（無 mutation ≤1 s；
   有 mutation = O(位元組)），並在 `wal.md` §8.1 的 `target` 段落補一句「tombstone 是 upstream 需求，
   不是本倉可以事後補的細節」。**不要**把 §8.1 改成 `implemented`，也不要把驗收留著讓下一個人去撞。
2. **對 upstream（contracts-w6／upstream owner）**：把 C1–C4 寫成一份正式需求（照
   `docs/upstream/README.md` 的既有流程：暫存 clone → `git format-patch` → `git apply --check`），
   內容至少包含：manifest 的 schema、blob 路由、**tombstone 語義**、能力字串。今天 `docs/upstream/`
   已有三份 draft 與一份 proposal 的先例，不需要新的機制。
3. **A1 只在 owner 明確要「部分收益」時才做**：它需要 P02＋P16/P20 兩個契約面（含 overlay 路由的
   cacheability），成本不低，而收益被 C3 卡住。若 owner 選它，**必須同時**接受「刪除即完整重打包」
   寫進契約，否則就是第二種語義。
4. **A2 明確不做**（理由見 §4）。
5. **A3 可做但不算 W6 的解法**：它只減少阻塞，不減少總量。

---

## 7. 兼容性與 breaking

| 邊界 | A4（只改驗收） | A1（分層） |
|---|---|---|
| old → new | 無 wire／schema 變更 | 舊 runtime 讀多層 overlay：**每一層都還是合法 ustar**，所以能讀；但層序由宿主決定，舊宿主只有一層 |
| new → old | 無 | 新宿主產生的多層組合在舊 Worker 上仍是一串合法 archive（reference 端 `entry.ts:583` 本來就吃陣列）；風險在**舊宿主 + 新層簿記**不存在 |
| new → new | 同一份 archive 兩端讀 | 需要「層清單與 WAL 一致」的新不變式 + 對應測試 |
| 舊資料 | 無 | 升級後第一次 boot 必須先做一次完整打包（因為沒有 base 層） |
| breaking | **否** | **是**（P02 §8 的語義新增；且 overlay 路由若改內容定址，P20 的 cacheability 條款要改） |

---

## 8. 需要誰授權什麼

| 授權者 | 要授權的具體事項 | 不做會怎樣 |
|---|---|---|
| **owner（計畫）** | 改寫 W6 驗收（§6-1）；接受「與工作區大小無關」在現行 runtime 上撤回 | W6 永遠無法驗收，或有人用假的量測讓它變綠 |
| **P02 owner（contracts-w6）** | §8 的現況條款維持；§8.1 的 `target` 加上 upstream 需求清單（C1–C4，尤其 C3） | 下一個 agent 會以為「補一個 schema 就好」 |
| **P16／P20 owner** | 只有選 A1 時：`overlays` 陣列政策（`PhoneDSHHost.swift:4084`）與 overlay 路由的 cacheability | A1 無法落地（或每層都重傳） |
| **upstream（DSH maintainer）** | manifest reader ＋ blob 按需取 ＋ tombstone ＋ 能力字串 | GAP-41 永久 open；W6 只到 §5 的上限 |
| **（不由本倉）** | 真機恢復時間量測（W0 的畫像夾具） | 「≤1 秒」永遠只是口號 |

---

## 9. 未量測 / 開放問題

- **未量測**：重打包的實測秒數（只有 E7 的歷史註解）；A1 的層數—時間曲線；`home/sessions`
  在 archive 中的位元組佔比（E4 證明它**在** archive 裡，但沒有量佔比）。
- **未量測**：WebKit 連續 inflate N 個 overlay 的行為（記憶體峰值、失敗模式）。
- **NOT_VERIFIED**：pinned checkout 的 `readImage` 原始碼（§3 的註記）。
- **開放**：`/image/overlay/*` 若改成內容定址（`<sha256>.tar`），是否符合「URL 不得帶 per-launch
  token」與 `no-store` 的既有分類？這是 P20 的 cacheability 決定，不是本備忘能定的。
- **開放**：刪除在實務中的頻率（決定 A1 的實際收益）。這需要一次帶畫像的量測，不是估算。
