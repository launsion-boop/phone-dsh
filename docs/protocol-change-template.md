# 協議變更單

協調者在**任何依賴它的實作開始之前**填寫本單，它就是 [AGENTS.md](../AGENTS.md) §3.1 所說的
contract freeze。放進任務或 PR 正文即可；跨多個 PR 的變更另存為 `docs/protocol-changes/<change-id>.md`
並互相連結。無邊界行為變更的重構不填本單，但每個觸發 ID 仍須寫 `ID: none — <理由>`；只有零觸發可寫整體 `Protocol impact: none — <理由>`。

## 0. 摘要（機器可讀，保持這個格式）

```yaml
change: PC-YYYYMMDD-<slug>      # 唯一，不重用
contracts: [P01]                # 依 spec/README.md §3
status: draft                   # draft → frozen → implemented → verified；或 rejected
breaking: false                 # 依 spec/README.md §5；true 時必須填版本決定
version_decision: <具體版本／adapter 決定> # breaking 時必填；也在 §3 說明遷移
base: <commit sha>
contract_revision: <commit sha 或 file@sha>   # frozen 之後才填
```

schema diff 的 breaking 豁免只接受本次 diff 新增或修改的變更單，比較起點為 `git merge-base <base> HEAD`；變更單的 `base` 也須經同一規則解析到該共同祖先，
`status` 為 frozen／implemented／verified，且 `contracts` 涵蓋受影響 ID；舊單不會永久豁免未來變更。

`frozen` 之後，契約只能由 contract owner 透過新 revision 修改，並在本單的「修訂紀錄」寫明。

## 1. 識別與角色

- 具體 trigger → 現況 → 期望：
- 協調者兼 contract owner／各端 implementer／reviewer-integrator：
- Owning spec 或 code contract、schema、shared fixtures：
- 所有受影響的 producer／consumer（依登記表逐端列出，含 Rust 與 Kotlin）：

## 2. 契約 delta

只列改動；未變語義引用 owning clause，不複製整份協議。

| 項目 | Before → After／依據條款 |
| --- | --- |
| fields／encoding／number domain／limits／default／null | |
| capability／version／unknown field／unknown method／unknown enum | |
| correlation／sequence scope／ordering／terminal outcome | |
| error code／retryable／deadline／cancel／late response | |
| idempotency／side effect unknown／ACK／durability／recovery | |
| origin／auth／scope／path／redaction／backpressure | |
| 條款狀態變化（target → implemented 等） | |

自檢（對照 spec/README.md §5.1）：是否新增了第二種表達？新欄位是否可選且定義缺省？
是否收緊或放寬了兩端都讀的訊息？新增 enum 是否有未知值規則？是否刪除或重用了任何名稱或編號？

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | |
| new → old | |
| new → new | |
| persisted old data → new／rollback | 不適用需註明原因 |

- 版本／adapter 決定，依據哪條 owning version rule：
- bundle／image／native artifact 更新順序、回滾限制、移除舊路徑的條件：
- `target`／`draft` 條款中，本次實作與仍保留的差異：

## 4. 分工與證據

- 每個 implementer 的獨占路徑（不可重疊）及各自驗收命令：
- 共享 fixtures 位置（正例、反例、數值邊界、未知值，以及本次涉及的取消／重連／恢復案例）：
- 各端真實 producer／consumer 測試（區分 spec checker、unit、integration、device）：
- Exact commands → `PASS／FAIL／SKIP／INCOMPLETE／NOT_RUN`，環境及證據位置：
- 剩餘風險、未支援平台、新發現的 GAP 及其關閉條件：

## 5. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
