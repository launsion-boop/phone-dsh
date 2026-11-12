<!-- SPDX-License-Identifier: MIT -->
# DEC-20261112-bot-context — bot-context 目錄、byte-exact golden 與小模型壓縮的衝突

Protocol impact: none — documentation only

Status: **proposal（供 P26 owner 簽核）**
登記狀態: **不在 GAP 表內**（本項沒有 GAP 編號；若要登記，由 P26 owner 決定是否新開一條）
前置閱讀: [決策備忘](perf-stability-open-gaps-20261112.md) §2 的 D5
相關工作包: W5 模型層效率（plan W5 的「壓縮、標題、驗證器走小模型」）

---

## 1. 一句結論

**衝突目前只存在於文件面，不在行為面。** 真正生效的 compaction 設定是 platform row
（`phone.worker.cordis.patch.yml`，已是 `deepseek-official`／`deepseek-flash`）；被 byte-exact golden
釘住的 `bot-context.cordis.patch.yml` 是 **upstream dsh-bot 模板的鏡像**，而它在本倉**沒有任何 runtime
消費者**。因此現在為它動 golden 是零行為收益的契約 churn；正確做法是**先把「哪一個是權威」寫清楚**，
等 WP7 真的把目錄 materialize 成 patch 層時，再依 repo 自己工具給的指示改成 `.phone.json` overlay。

---

## 2. 現況與證據

| # | 證據 | 說明 |
|---|---|---|
| E1 | `plugins/profile/bot-context.cordis.patch.yml:15-16`、`:41-42` | 兩個 profile（`default`／`conservative`）的 `summarizationProvider: ""`、`summarizationModel: ""` |
| E2 | `plugins/profile/phone.worker.cordis.patch.yml:1274-1275` | **生效的** platform row：`summarizationProvider: "deepseek-official"`、`summarizationModel: "deepseek-flash"`；檔內註解寫明這是「WP12 default context profile, materialized as patch rows (not the two-scalar catalog)」 |
| E3 | `spec/bot/v1/golden/context-profiles.json:16-17`、`:40-41` | `valid.profiles.*.compaction` 的兩個欄位都是 `""` |
| E4 | `spec/bot/v1/golden/context-profiles.json:59-60` | `valid.yaml.default`／`conservative` 是**整段字串**，內容與 E1 逐字對應（含 `summarizationProvider: ""`） |
| E5 | `spec/tools/bot/export-vectors.mjs:48` | golden 的 `yaml` 欄位不是本倉產生，而是從 pinned dsh-bot 的 `src/main/prompt/assemble.cjs` 取 `contextConfigYaml` |
| E6 | `spec/bot/v1/export-manifest.json:17`、`:50`、`:93` | `context-profiles.json` 屬 **upstream** 分區（不是 `.phone.json` overlay），且 sha256 被 manifest 釘住 |
| E7 | `spec/tools/bot/check_golden.py:179-186` | `--checkout` 模式要求 upstream golden 與「新匯出」**逐位元組相同**；不符時的錯誤訊息直接寫 **「move phone cases to `<name>.phone.json`」** |
| E8 | `spec/tools/bot/golden_overlay.py:1-9`、`:43-62` | overlay 的合併語義：只能新增或**以同 identity 取代**，不能移除；scalar 值會被 overlay 覆蓋 |
| E9 | `Sources/PhoneDSHBot/Watchdog/BotContextProfiles.swift:74-93`、`:99-109`、`:111-153` | Swift 的 frozen profile 是 `""`／`""`，並用 `render` **重新產生**同一段 YAML 字串 |
| E10 | `Tests/PhoneDSHBotTests/Watchdog/BotContextProfilesTests.swift:7-18`、`:20-28` | ①frozen 必須等於 golden 的 `valid`；②`plugins/profile/bot-context.cordis.patch.yml` 的兩個 literal scalar 必須**逐位元組**等於 golden 的 `yaml` |
| E11 | `git show 6ab994256`（`fix(profile): pair the compaction provider with its model after the main merge`） | 這個 commit 把目錄從 `""`／`deepseek-flash` **改回** `""`／`""` 以恢復 byte-exact；同時把 platform row 的 provider 補成 `deepseek-official`。訊息原文：「bot-context stays a byte-exact mirror of the frozen golden; the phone worker profile names the provider DSH requires alongside the small model」 |
| E12 | `Sources/PhoneDSHBot/Watchdog/BotContextProfiles.swift` 之外沒有任何 `BotContextProfile*` 的使用者（全倉 grep 只命中該檔） | **本倉沒有把 profile 目錄 materialize 成 patch 層的程式碼**；檔頭「WP7 selects one scalar」的 WP7 未落地（或不在本倉） |
| E13 | `plugins/tests/bot-persona.test.ts:91` | 另有一條測試斷言 `phone.worker.cordis.patch.yml` **不得**包含 `bot-context.cordis.patch.yml` 這個路徑字串（即 platform row 不是由該目錄展開的） |
| E14 | `spec/bot/v1/context-profiles.schema.json:30-37` | schema 只要求兩個欄位是 `string`；**沒有定義空字串的語義**（空＝跟隨 session 模型？＝不壓縮？本倉未寫） |

**兩件事必須分開講：**

1. **行為面**：生效的是 E2（platform row）。`phone.worker` 的 provider＋model 是一對完整的小模型設定，
   W5 想要的效果**已經在生效路徑上**（但是否真的被 compaction 採用，**未量測**）。
2. **文件／契約面**：E1 的目錄被 E10 的測試釘在 E3/E4 的 golden 上；而 E5 說 golden 來自 upstream 模板。
   所以「把目錄改成 `deepseek-official`」等於**宣告 phone 與 dsh-bot 模板不同**，不是改一個常數。

---

## 3. 三個選項

### O1 改 golden ＋ 新契約修訂（走 `.phone.json` overlay）

**做法**：新增 `spec/bot/v1/golden/context-profiles.phone.json`（`upstream: ["context-profiles.json"]`），
只覆蓋 `valid.yaml.default`／`valid.yaml.conservative` 兩個 scalar 與對應的 `valid.profiles.*` 欄位；
**upstream 檔一個 byte 都不動**（所以 E7 的 `--checkout` 仍會過）。同步改 E1 目錄、E9 的 Swift frozen。

| 面向 | 內容 |
|---|---|
| 契約修訂 | P26：新 overlay golden＋`export-manifest.json` 的 `phoneOverlays` 清單＋`delta` 說明「phone 的 compaction 指名 provider／小模型，upstream 模板留空」。**不動** pinned SHA、不動 `--checkout` 的 upstream 集合。 |
| 兼容矩陣 | old → new：舊 consumer 讀不到新 overlay → 仍看到 `""`（無害，因為本來就沒有消費者）。new → old：新 overlay 不影響舊端（它只加檔案）。new → new：兩端讀同一份 merged fixture。舊資料：無持久化格式。 |
| breaking | **否**（沒有 wire／資料格式；只是 golden 分區多了 `.phone.json`）。 |
| 成本 | 中：動 P26 契約面（golden 分區＋manifest＋delta）、Swift frozen＋render、兩條測試（E10）、Kotlin 對端若也讀此 golden 需同步（本輪未確認）。 |
| 風險 | ①**現在沒有任何消費者**（E12），所以收益是 0，卻永久留下「phone 與 dsh-bot 模板不同」的紀錄；②E9 的 `render` 與 golden 的 `yaml` 必須同時改，兩者失真就是第二個權威；③若 upstream 之後改模板（例如也開始填 provider），overlay 會變成過時的覆蓋。 |
| 何時值得做 | **WP7 真的落地時**（把目錄 materialize 成 patch 層的那一刻）。在那之前做，是為未來鋪路，不是修現在的行為。 |

### O2 維持現狀，只在 worker 生效（＋把權威寫清楚）

**做法**：E1 目錄保持 `""`／`""`；把「`bot-context.cordis.patch.yml` 是 upstream 鏡像，有效 compaction
設定在 `phone.worker.cordis.patch.yml` 的 platform row」寫成契約／檔頭註解；**不新增** golden 覆蓋。

| 面向 | 內容 |
|---|---|
| 契約修訂 | P26：一句話的權威宣告（可寫在 `spec/bot/v1/README.md` 的 context-profiles 段，或目錄檔頭）。**不動 golden、不動 schema、不動測試。** |
| 兼容矩陣 | 全部「無變化」。 |
| breaking | 否。 |
| 成本 | 極低（一段文字）。 |
| 風險 | **WP7 落地時會把小模型悄悄換回空值**——因為目錄一旦成為有效來源，`""` 就會蓋掉 platform row（或反之，取決於套用順序）。所以 O2 必須配一個 guard：在 WP7 的變更單裡**同時**做 O1，或加一條測試斷言「目錄不是有效來源」。 |
| 何時值得做 | 現在。它是零成本的，而且把「別在這裡改小模型」講明白。 |

### O3 把 bot-context 排除在 golden 之外

**做法**：刪掉 E10 的第 2 條測試、把 `context-profiles.json` 從 `export-manifest.json` 的
`upstream` 移到（或新增）一個不與 upstream 對拍的類別；目錄自由改。

| 面向 | 內容 |
|---|---|
| 契約修訂 | P26：golden 分區變更＋manifest＋測試刪除。 |
| 兼容矩陣 | 無資料變更；但**失去與 dsh-bot 的對拍能力**。 |
| breaking | 對「golden 是 upstream 的忠實匯出」這個承諾而言是**是**（那是 P26 的核心不變式之一）。 |
| 成本 | 低（刪東西最快），但代價最高。 |
| 風險 | 這正是 AGENTS §2.3 禁止的形狀：**為了讓某個實作過而放寬契約**。而且 W1 的 `check_golden` 整個設計（upstream ＋ append-only overlay）就是為了防止這件事。 |
| 建議 | **明確不採**。列出來是為了在 review 時把它擋掉。 |

---

## 4. 三者對照

| | O1 改 golden（overlay） | O2 維持現狀（＋權威宣告） | O3 排除 golden |
|---|---|---|---|
| 現在有行為收益？ | 否（無消費者） | 否 | 否 |
| 契約面改動 | 中（新 overlay＋manifest＋Swift＋測試） | 極小（一段文字） | 大（刪測試、改分區） |
| 保留 dsh-bot 對拍 | 是（upstream 檔不動） | 是 | **否** |
| 未來的風險 | overlay 過時 | WP7 覆蓋小模型 | 失去 oracle |
| 是否符合 AGENTS §2 | 是 | 是 | **否** |

---

## 5. 建議

**O2 現在做；O1 綁在 WP7 落地時一起做。**

理由：

1. **E12** 證明目錄目前沒有消費者。為一個沒有消費者的欄位動 golden，會立刻製造一個「已偏離 upstream」
   的紀錄，卻沒有任何行為改變——而 E11 那個 commit 才剛花力氣把它恢復成鏡像。
2. **E2** 證明 W5 想要的小模型設定**已經在生效路徑上**。真正的待辦不是改目錄，而是**量測**：
   compaction 是否真的用了 `deepseek-flash`（本輪未量測）。
3. **E7** 顯示 repo 自己的工具在 golden 偏離時給的指示就是「move phone cases to `.phone.json`」——
   所以 O1 是**正確形狀**，只是**時機**應該由 WP7 決定。
4. O2 的風險（WP7 悄悄覆蓋）用一條 guard 控制：在 WP7 的變更單裡要求「先做 O1 或先加斷言」。
   本備忘建議 P26 owner 現在就把這句話寫進 `spec/bot/v1/README.md` 的 context-profiles 段。

**若 owner 希望「Bot profile 立刻用小模型」**（即不等 WP7），那就必須走 O1 並接受：
(a) 目前沒有 runtime 消費者，所以改了也看不出效果；(b) 未來 upstream 改模板時要維護 overlay。

---

## 6. 需要誰授權什麼

| 授權者 | 要授權的具體事項 | 不做會怎樣 |
|---|---|---|
| **P26 owner** | ①寫下「`bot-context.cordis.patch.yml` 是 upstream 鏡像，有效 compaction 在 platform row」的權威宣告；②決定是否現在就建 `context-profiles.phone.json`（O1）；③在 WP7 變更單加 guard | 下一個人會直接在目錄裡改值，然後被 E10 的測試擋下，再花時間猜為什麼 |
| **owner（產品／計畫）** | 接受「Bot profile 的小模型壓縮本輪未生效（因為沒有消費者）」，或要求 O1＋WP7 一起排期 | W5 的「壓縮走小模型」在 Bot 路徑上永遠只有 platform row 那一份 |
| **（可選）upstream dsh-bot** | 讓 `contextConfigYaml` 也輸出 provider（這樣連 golden 都不用 overlay） | 就只能走本倉的 `.phone.json` overlay |
| **（後續）P26＋量測** | compaction 實際使用模型的真機證據 | 「已走小模型」永遠只是設定檔上的一句話 |

---

## 7. 未量測 / 開放問題

- **未量測**：compaction 真的用了 `deepseek-flash` 嗎？需要 runtime 證據（ledger 的 model 欄位或
  upstream 請求記錄）。設定檔寫對 ≠ 生效。
- **未驗證**：`""` 的語義（E14 只說它是 string）。E11 的 commit 訊息暗示「provider 與 model 必須成對」，
  但**空字串究竟等於「跟隨 session 模型」還是「不壓縮」**，本倉沒有定義，本輪也沒有 runtime 實驗。
- **未確認**：Kotlin／Android 端是否也讀 `context-profiles.json`（若讀，O1 要同步改兩端 decoder）。
- **開放**：WP7 是否還會落地、以什麼形狀落地（`BotContextProfileDocument` 已經 frozen 但沒有使用者）。
  若 WP7 確定不做，O1 就永遠不需要，目錄可以一直當鏡像。
- **開放**：`phone.worker` 的 `deepseek-official` 這個 provider 名稱是否在 pinned runtime 中存在且可用
  （E11 的訊息說「DSH requires provider alongside the small model」，但 provider 的有效值是 runtime 的
  知識，本倉沒有清單）。
