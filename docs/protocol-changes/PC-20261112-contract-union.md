<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-contract-union — W0–W7 與 W6 契約的單一聯集 spec 樹

## 0. 摘要

```yaml
change: PC-20261112-contract-union
contracts: [P01, P02, P03, P05, P06, P16, P17, P18, P20]
status: frozen
breaking: "true（繼承 W6 的 op 0xFE 新持久記錄種類；本單不新增 breaking delta）"
version_decision: 本單只把兩條已凍結的 spec 血緣疊成一份樹；不新增欄位、不改 schema、不改任何數字配額，也不改寫任一變更單的既有決定。整體 breaking 狀態沿用兩邊：W6 的 `0xFE` 記錄使「新資料→舊版」為 fail-loud 拒絕，其餘七份變更單為非 breaking。
base: d988108c1ec0c56903d6087c282cc9278bbdfd19
parents:
  contracts-w6: 31bb4e0c502a25e13725ef5a013f5526de0b16be（spec/schema/golden 凍結 1257395665b5b009ef01eb825c536566f6731168）
  contracts: b5143e9491e86e19fbbc79ef9e37333af6a5ea52（rev 5）
```

## 1. 為什麼需要聯集

兩條血緣各自只帶一部分條款，任一單獨交付都會靜默丟掉另一邊：

- `contracts`（base `d988108c1`）帶 W0/W1/W2/W3/W4/W5/W7 的七份變更單，以及 `budgets.md` §7 target 列、`wal.md` §11–§13、`exec.md` §7–§8、`gateway-security.md` §11–§13、host outbox schema rev 4/§10/GAP-40、bot tool-catalog／volatile-context／model-purpose vectors，和 `golden/plan/` 的 perf-targets／append-records／response-log-key／retention／storage-levels／streaming／memory-input。
- `contracts-w6`（建在 `w4-writepath` `488342b2` 之上）帶 `wal.md` §8.1／§14、`handoff.md` §4、`budgets.md` §9 的 blob 計入、`golden/wal/segment-blob-write.json`、`golden/plan/single-copy.json` 與 GAP-41；但它的 `spec/` 樹只到第一版凍結 `e654fe99`。

本單的 commit 是這兩條血緣的**唯一合併 spec 樹**。`w6-singlecopy` 的實作 base 與調用方的驗收都以本 commit 的 `spec/` 為 head；不是 `b5143e94`，也不是 `12573956`。

## 2. 合併的檔案

- `contracts` 側（相對 `e654fe99`）：`PC-20261112-w1-browse-outbox.md`、`PC-20261112-w2-journal-step-pruning.md`、`spec/README.md`、`spec/host/v1/README.md`、outbox schema／四個附件 golden／`outbox_invalid_cases.json`／`test_outbox_contract.py`、`budgets.md`（§3 engine-memory、§8 high-water retention）、`golden/plan/memory-input.json`、`golden/plan/retention.json`、`plan-cases.schema.json`、`plan_cases_check.py`、`test_plan_cases_check.py`。
- `contracts-w6` 側（相對 `e654fe99`）：`PC-20261112-single-copy-incremental-boot.md`、`spec/README.md`（GAP-41）、`spec/v1/README.md`、`budgets.md` §9、`golden/README.md`、`golden/plan/single-copy.json`、`golden/wal/segment-blob-write.json`、`handoff.md` §4、`plan-cases.schema.json`、`plan_cases_check.py`、`spec_golden.py`、`test_plan_cases_check.py`、`test_spec_golden.py`、`wal.md` §8/§14。
- 其餘 `spec/**`、`docs/protocol-changes/**` 由兩邊祖先共同帶入，原樣保留；`docs/research/cold-session-compression-20261112.md` 等實作單位的文件不在本單寫入範圍，保持不變。

## 3. 衝突與解決方式

| 檔案 | 衝突 | 聯集解決 |
| --- | --- | --- |
| `spec/README.md` | 兩邊各自新增 GAP 列 | GAP-38、GAP-39、GAP-40、GAP-41 全部保留，按編號排序。 |
| `spec/v1/schema/plan-cases.schema.json` | `vector` enum 與 description 各只列自己那組 | enum 取聯集：`perf-targets`、`retention`、`storage-levels`、`append-records`、`response-log-key`、`streaming`、`single-copy`、`memory-input`；description 同時記 W6 與 W2 rev 2。 |
| `spec/v1/tools/plan_cases_check.py` | `VECTORS`、`CHECKS`、兩組 law 函式互相覆蓋 | `VECTORS` 與 `CHECKS` 同時含 `single-copy`、`memory-input`；`check_single_copy` 與 `check_memory_input` 兩組完整保留。 |
| `spec/v1/budgets.md` | 自動合併成功，但聯集後 322 行超過既有 D16 `budgets.md` 上限 320 | 只壓縮 §3 W2 engine-memory 段的散文行寬（10 行→8 行），條款、動作順序 `clearTmp → plannedRestart`、`target` 狀態與所有數字都不變；最終 320 行，未調高上限。 |
| `wal.md`／`handoff.md`／`golden/README.md`／`spec_golden.py` | 只有 W6 一側改動，無文字衝突 | 原樣保留；W1/W3/W4 的 §11–§13 與 W6 的 §8/§14 同時存在。 |

沒有放寬任何 schema、校驗、fixture 或配額；沒有刪除任一 GAP；沒有改寫任何既有變更單的決定。

## 4. 聯集後的案例數

| 項目 | 數量 |
| --- | --- |
| `spec/v1/golden/plan/` case 檔 | 8（perf-targets、retention、storage-levels、append-records、response-log-key、streaming、single-copy、memory-input） |
| plan case valid／invalid | 56／45 |
| `spec/v1` golden／schema／文件（`--full`） | 105 檔 |
| host golden／schema（`host_check`） | 49 檔 |
| 契約 registry | 28 contracts／499 references |
| schema | 110（相對 base 0 breaking） |

## 5. 實際檢查輸出（Linux，無 Xcode／swift／cargo）

| 命令 | 結果 |
| --- | --- |
| `python3 spec/v1/tools/spec_golden.py --full` | `105 files checked, 0 error(s)` → PASS |
| `python3 spec/v1/tools/plan_cases_check.py` | `8 plan case file(s) checked, 0 error(s)` → PASS |
| `python3 -m unittest spec.v1.tools.test_plan_cases_check` | `Ran 18 tests ... OK` → PASS |
| `python3 spec/host/v1/tools/host_check.py --root .` | `49 files checked, 0 error(s)` → PASS |
| `python3 -m unittest spec.host.v1.tools.test_outbox_contract` | `Ran 5 tests ... OK` → PASS |
| `python3 spec/tools/registry_check.py` | `PASS registry: 28 contracts, 499 path/glob references` → PASS |
| `python3 spec/tools/cross_check.py` | `8 invariants: 8 ok, 0 fail` → PASS |
| `python3 spec/tools/schema_diff.py --root . --base d988108c1` | `PASS schema diff: 110 schemas; 0 breaking` → PASS |
| `python3 scripts/ci/protocol_impact.py --base d988108c1 --body-file …` | `PASS ... 14 triggered ID(s), 119 changed path(s)` → PASS |
| `bash scripts/ci/check.sh --only phone-license,phone-no-dsh-patch` | 兩階段 PASS |
| `bash scripts/ci/check.sh --only phone-spec` | PASS |
| `CI_PROTOCOL_BASE=d988108c1 bash scripts/ci/check.sh --only phone-cross-tree` | PASS |

失敗（既有基線）：

- `bash scripts/ci/check.sh --only phone-hygiene` 的 362 條 finding 全部落在 `git diff --name-only d988108c1..HEAD` 之外的檔案（`spec/v1/tono-account*`、`spec/v1/golden/tono-account/`、`CloudVoice`、`TonoAccount`、Android 測試等），本單沒有改動其中任何一檔，屬 base 既有債。
- `bash scripts/ci/check.sh --only phone-p0-conformance` 失敗於 `page-structure` 的 7 處 baseline 外差異（既有 UI 頁面與 `SettingsPage.swift` 等，全部不在本單 diff）；其餘 P0 檢查 PASS。同一組 7 處差異在 `contracts` 首次凍結時已記錄為既有基線，本單未改 UI 或 page 契約。

未執行：`swift build`／`swift test`（`swift: command not found`）、`xcodebuild`、XCTest、模擬器與真機（環境沒有 Xcode／裝置）；`cargo test`、`npm test`（工具鏈未安裝）。契約單元不產生 runtime 證據，也不宣稱任何裝置、功耗或遷移結果。

## 6. 邊界聲明

- 本 commit 不含任何實現代碼；它只保證 `spec/` 與 `docs/protocol-changes/` 的聯集完整。
- 舊資料、回滾、blob 單副本、outbox 附件、快取分層等語義仍分別由各自的凍結變更單與 GAP-40／GAP-41 管轄。本單不改變它們的狀態，也不把任何 `target` 升級為 `implemented`。
