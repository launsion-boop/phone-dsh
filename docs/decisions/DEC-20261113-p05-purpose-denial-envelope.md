<!-- SPDX-License-Identifier: MIT -->
# DEC-20261113-p05 — model-purpose 拒絕要怎麼穿過 P05 的失敗封套

Protocol impact: none — documentation only

Status: **proposal（供 P05 owner 簽核）**
對應 GAP: [GAP-42](../../spec/README.md)（P05、P12、P26，open）
權威變更單: [PC-20261113-p12-model-purpose-sink.md](../protocol-changes/PC-20261113-p12-model-purpose-sink.md)
相關條款: [gateway-security.md](../../spec/v1/gateway-security.md) §7 `failure-surface`、[bot/v1/README.md](../../spec/bot/v1/README.md) §2.10

---

## 1. 問題

執行點已於 2026-11-13 上線（`Sources/PhoneDSHGateway/ModelPurposeEnforcement.swift`），位置在 MCP
egress gate／shutdown guard 之後、Bot 審批接縫與憑据解析之前。契約凍結了兩個分支：purpose 缺席只記
`purpose_absent`，purpose 存在則真的呼叫 enforcer，deny 即拒絕該交換。

一旦有宿主組合安裝 `ModelPurposeProviding`，deny 就必須**穿過 P05 的 `/v1/http` 失敗封套**回到呼叫方。
今天這條映射不存在：enforcer 拋出的 `BotModelPurposeError` 不屬於 §7 任何一列，因此落到既有的
unknown-error 路徑，表現為 `upstream_failed`／502。

## 2. 為什麼 502 是錯的類別

| 面向 | 502 `upstream_failed` 的後果 |
| --- | --- |
| 語義 | 看起來像上游/網路故障，實際是宿主策略的主動拒絕 |
| 重試 | 客戶端與 Worker 會把 5xx 視為可重試；策略拒絕重試一萬次也不會通過 |
| 可診斷性 | 真正的拒絕原因（purpose／model）在封套裡完全消失 |
| 一致性 | 同類的兩個宿主策略拒絕（`egress_approval_denied`、`task_network_write_denied`）都是 403，這個卻變 5xx |

## 3. 既有事實（不是提案，是現況）

- §7 已凍結的映射：`host_not_allowed` → 403、`invalid_request` → 400、`credential_unavailable` → 502、
  `egress_approval_denied` → 403/`egress_approval_denied`。
- **最接近的先例**：`task_network_write_denied`「is the same 403 class, keeps its specific
  `error.code`/`X-PDSH-Proxy-Error`」——也就是說 P05 已經接受「403 類別下保留各自的具體代碼」這個模式。
- enforcer 已凍結兩個代碼：`EPURPOSE_MODEL_DENIED`、`EPURPOSE_MODEL_REQUIRED`
  （`Sources/PhoneDSHAgentCore/BotModelPurposePolicy.swift:100,105,188,196`）。
- 兩個既有 403 都保證「no credential, socket or response log」，與 deny 的實際行為一致。

## 4. 選項

| 選項 | 內容 | 代價 | 風險 |
| --- | --- | --- | --- |
| **A** | 維持現狀：落入 unknown-error → 502 `upstream_failed` | 0 | 類別錯、可重試、原因遺失（§2） |
| **B（建議）** | 403，沿用 `task_network_write_denied` 先例：`error.code` 與 `X-PDSH-Proxy-Error` 直接帶 enforcer 既有的 `EPURPOSE_MODEL_DENIED`／`EPURPOSE_MODEL_REQUIRED`；不解析憑据、不開 socket、不寫 response log | 一條 §7 映射列 ＋ 一個共用 golden 向量（`gw-fail-003`：purpose denied） | 舊客戶端會首次看到這個 403；但 403 政策拒絕類別已存在，不是新類別 |
| **C** | 403 ＋ 另立一個 P05 專用代碼（如 `model_purpose_denied`） | 同 B 再加一個代碼 | 為 P26 已經命名的意思再造第二個名字，違反 AGENTS.md §2.1（單一權威） |
| **D** | 在進入 Gateway 之前由宿主工具層攔掉 | 較小 | 覆蓋不到 Bot worker 經 `/v1/http` 的路徑，等於兩個權威 |

## 5. 建議

**選 B。** 理由：它沒有發明任何新東西——403 類別、保留具體 `error.code` 的模式、兩個 enforcer 代碼，
全部已經凍結存在；缺的只是 §7 映射表裡的一列與一支向量。

需要的**最小 delta**：

1. `gateway-security.md` §7 新增一列：`EPURPOSE_MODEL_DENIED`／`EPURPOSE_MODEL_REQUIRED` → 403，保留具體
   `error.code`／`X-PDSH-Proxy-Error`，並註明不解析憑据、不開 socket、不寫 response log。
2. 共用 golden 向量：`gw-fail-003`（deny）與對應的 allow 正例；`cross_check.py` 的 `GOLDEN_READERS` 若需要
   才加列。
3. 兼容矩陣：old→new（舊客戶端首次遇到此 403，屬既有 403 政策類別）、new→old（無 wire 變更）、
   new→new、舊資料（無持久化影響）。
4. Kotlin／Android 端：`gw-*` golden 若鏡像，需同步（目前 Kotlin 無 Bot runtime，預期不變）。

## 6. 本備忘沒有做什麼

沒有改 `spec/`、沒有改 `Sources/`、沒有新增錯誤碼、沒有動 golden。P05 的裁決屬於 owner；在裁決前，
**不得**為了讓來源可上線而臨時用 502 或自創代碼。

## 7. 關閉條件

- §7 有一列明確映射，且共用向量涵蓋 deny 與 allow 兩態；
- `ModelPurposeProviding` 的生產實作落地時，deny 回傳 §7 指定的 403 與代碼；
- GAP-42 的「來源」部分另案處理（本備忘只解封套，不解來源）。
