<!-- SPDX-License-Identifier: MIT -->
# PC-20261112-model-purpose-gap — W5 §2.10 enforcement point deferred

## 0. 摘要

```yaml
change: PC-20261112-model-purpose-gap
contracts: [P05, P12, P26]
status: frozen
breaking: false
version_decision: 無 wire／schema／持久化格式變更。§2.10 的 model-purpose 執行點由「宿主唯一模型請求入口、解析憑據／開 socket 前必須執行」改記為 `target`；enforcer 與既有 golden 不變，Gateway 接線記 `NOT_IMPLEMENTED`，本輪行為與基線相同。
base: fad9984567ab939ec8ff1a240ccad701db41cc58
contract_revision: 本檔所屬的 contracts-union 修訂；不改任何 schema／golden。
```

## 1. 裁定（owner (a)）

本輪只交付 `w5-model` 已完成的 enforcer（`BotModelPurposeGate`／`BotModelRequest`，位於
`Sources/PhoneDSHBot/Ledger/BotModelPurposePolicy.swift`）與測試。`ModelGateway` 的接線記為
`NOT_IMPLEMENTED`，登記 [GAP-42](../README.md)。模型用途策略本輪未生效，**與基線行為相同，非回歸**。

## 2. 為什麼不能在本輪接線

1. **依賴方向。** enforcer 在 `PhoneDSHBot`，而 `Package.swift` 只讓 `PhoneDSHGateway` 依賴
   `PhoneDSHAgentCore`；Gateway 要呼叫它必須調整模組依賴（P12 契約面）。
2. **purpose 載體。** `GatewayRequest`／`HTTPEgressRequest` 只有 method／url／headers／body；wire 上
   沒有 purpose／session／turn，請求本身無法證明它服務哪個用途。
3. **上游保留。** pinned 模型適配器不保留、也不傳遞上游 purpose。

## 3. 不授權清單

不新增 Worker→host purpose 標頭；不改 `Package.swift` 依賴；不新增任何 wire 欄位或錯誤碼；不
fail-closed；不以預設值放行；不按模型名推斷 purpose；不在 Gateway 複製 policy（第二個權威，
AGENTS.md §2.1）。上述任一項都需要新的契約修訂與 owner 授權，不得由實作自行加入。

## 4. 兼容性

| 邊界 | 本輪行為 |
| --- | --- |
| old → new | enforcer 新增但無呼叫方；`ModelGateway` 請求路徑與基線相同，沒有新欄位或新錯誤碼。 |
| new → old | 沒有新資料格式或 wire 變更；回滾不涉及遷移。 |
| new → new | 兩端都不依賴未接線的執行點；enforcer 的 allowed／denied／default／unknown 語義仍由 `model-purpose-enforcement.phone.json` 描述。 |
| persisted data → new／rollback | 無持久化格式變更；不影響帳本以外的資料。 |

## 5. 關閉條件

GAP-42 關閉需要三者同時具備，並有 golden 與兩端測試：

1. Gateway↔Bot 依賴方向確定（或 `Package.swift` 調整，P12）；
2. 可靠的 per-request purpose 載體；
3. pinned adapter 保留／傳遞 purpose。

## 6. 用戶可見變化

**無。** 沒有新增或去掉任何提示、限制、文案；本輪沒有模型請求被新的檢查攔截或放行。
