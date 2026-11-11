<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-w0-baseline-budgets — W0 target performance budgets

## 0. 摘要

```yaml
change: PC-20261112-w0-baseline-budgets
contracts: [P03]
status: frozen
breaking: false
version_decision: 無版本變更。只在 budgets.md 新增 `target` 狀態的 §7 效能預算列，數值一律寫 `待基线`；不改任何既有行、既有配額或既有 schema。`target` 不可被當成已實現的門檻。
base: d988108c1ec0c56903d6087c282cc9278bbdfd19
contract_revision: 見交接 head（本單與 spec 同一 commit）
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  - Trigger：plan W0 需要先有冷啟動到可發送、首 token、每回合 fsync／寫入位元組、空閒 10 分鐘、宿主內部存儲穩態這幾條量測口徑，否則後續每個工作包沒有共同驗收基準。
  - 現況：`spec/v1/budgets.md` §4／§5 只有靜態常數（heap、VFS、quota、recovery、loopback p95），沒有上面這些 target 列，也沒有「同一指標怎麼量」的定義。
  - 期望：`budgets.md` 新增 §7，逐列固定 **metric、unit、三個畫像欄、collection point**；三個畫像欄的值一律是字面 `待基线`，不得填入估算、代測或其他裝置的數字。W0 的真機報告才把某一列從 `待基线` 變成有依據的 target。
- **Coordinator / contract owner**：本單元 `contracts`。**Implementers**：`w0-baseline` 只改 `scripts/perf/`、`docs/perf/`，不改 `spec/`。**Reviewer**：lead／呼叫方在本機與真機上跑門禁。
- **Owning spec / schema / fixtures**：[budgets.md](../../spec/v1/budgets.md) §7（新增）。此變更沒有 schema（不是 wire 或持久化格式），shared fixture 是 `golden/plan/perf-targets.json`：valid 列全部 `待基线`，invalid 列是一個發明的數字與一個非 target 狀態。
- **受影響 producer / consumer**：P03 controller/host 的預算讀取端（Swift、Kotlin）；W0 的 `scripts/perf/` 產生器與 `docs/perf/README.md`。沒有任何 wire、schema、持久化 bytes 改變。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| 效能預算列 | §4／§5 的靜態常數之外，新增 §7 七列：cold start to sendable、first token latency、fsync calls per turn、bytes written per turn、idle 10 min wakeups、idle 10 min bytes written、host internal storage steady state。 |
| 數值 | 新列的三個畫像欄一律 `待基线`。不得以 token 估算、舊裝置數字或模擬器數字填寫；不得把 `target` 列當成已實現門檻。 |
| 量測口徑 | 每列固定 unit 與 collection point；turn 列以一次普通使用者回合為單位；latency 列是 wall-clock，**NOT_VERIFIED** 直到真機報告。 |
| 既有內容 | §4／§5／§6 一行都不改；WAL 512 MiB、journal 64 MiB、response log 128 MiB 等配額不變。 |
| 條款狀態 | 新增 §7 為 `target`（plan W0）。`target → implemented` 需要三畫像的真機基線報告，不是 spec checker 通過。 |
| sequence／error／ACK／durability | 不涉及。 |

自檢（baseline §5.1）：沒有第二種表達、沒有新欄位、沒有收緊或放寬任何兩端訊息、沒有新增 enum；只新增一段不與既有條款衝突的 target 文本與一組 fixture。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；測試 |
| --- | --- |
| old → new | 舊實作不讀 §7，行為不變。新 checker 只驗證 §7 的存在與 `待基线` 字面；不要求舊實作填數。 |
| new → old | 新實作若讀 §7，只會看到 `target` 列；讀不到數字時必須回到既有 §4／§5 常數，不能把 `待基线` 當成 0 或無限大。 |
| new → new | 兩端都讀同一 §7 欄名與 collection point；報告以同一 fixture 畫像（light/typical/heavy）比較。 |
| persisted old data → new／rollback | 不適用：沒有保存格式、沒有 migration。回滾只是不再讀 §7。 |

- **版本決定**：無版本變更。`proto 1`、WAL format 1、manifest、Bot schema、PCLink 全部不動。D16 文件上限由 200 調到 320，理由與 W2／W3 共用，記在 `spec/v1/README.md` §5.2（2026-11-12 條）。
- **部署順序**：spec 與 W0 工具可獨立落地；真機報告後只把對應列的值改掉，不新增第二個表。
- **仍保留的差異**：所有數字都還是 `待基线`；本單不宣稱任何實測。

## 4. 分工與證據

- **獨占路徑**：`spec/v1/budgets.md`、`spec/v1/schema/plan-cases.schema.json`、`spec/v1/golden/plan/perf-targets.json`、`spec/v1/tools/plan_cases_check.py`、`spec/v1/tools/test_plan_cases_check.py`、`spec/v1/README.md` §5.2、本單。
- **W0 實作端（另一單元）**：`scripts/perf/`、`docs/perf/`；不得改 `spec/`。
- **共享 fixtures**：`golden/plan/perf-targets.json`（7 valid、2 invalid）；checker 拒絕任何非 `待基线` 的數字與非 `target` 狀態。
- **Exact commands → result**（本單實際執行，Linux 容器）：
  - `python3 spec/v1/tools/spec_golden.py --full` → PASS（102 files，0 error）。
  - `python3 spec/v1/tools/plan_cases_check.py` → PASS（6 plan case files，0 error）。
  - `python3 -m unittest spec.v1.tools.test_plan_cases_check` → PASS（8 tests）。
- **未執行**：任何真機量測、Xcode、模擬器、`xcodebuild`、XCUITest 一律 NOT_RUN；本單沒有數字可宣稱。
- **風險／GAP**：`target` 列在真機報告前沒有回歸價值；若 W0 填數時改了 collection point，必須以新 revision 修改 §7，不能只在報告裡另寫一份口徑。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | contracts | 初次凍結 W0 §7 與 perf-targets fixture | all（contract freeze 公告） |
