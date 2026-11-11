# Bot agent.comm 持久事件型別（P25/P27）

```yaml
change: PC-20261111-bot-agent-comm-envelope
contracts: [P25, P26, P27]
status: implemented
breaking: false
version_decision: Additive durable event type `agent.comm` in the existing P25 envelope. No envelope field, error code, origin value, version field or storage format is added; old readers keep ignoring the new type and old data stays readable.
base: 871488cfe
contract_revision: spec/bot/v1/event-envelope.schema.json@agent-comm-v1 + spec/bot/v1/golden/event-envelope.phone.json
```

Protocol impact: P25 — additive `agent.comm` durable type in the frozen envelope enum; P26 — one additive cross-reference in `spec/bot/v1/README.md`, no tool/memory/wake behaviour change; P27 — registered the phone event-envelope overlay, no row schema or projector change

## 1. 識別與角色

- **Trigger → 現況 → 期望.** `SendToAgent` 在真實模型冒煙中回報 `BotEventValidationError(code: "INVALID_EVENT", field: "origin.source")`，訊息沒有送到目標 Bot。第一個錯誤是 `BotRuntimeComposition.recordAgentComm` 寫入未登記的 local source `team-tools`；同一路徑的第二個錯誤是 `agent.comm` 從未登記為 durable event type，修正 origin 後 `SQLiteDomainStore.append` 會以 `UNKNOWN_REQUIRED_EVENT` 拒絕寫入。期望：outbound/inbound `agent.comm` 都能進 P25 envelope、落盤並解碼。
- **Coordinator / contract owner / implementer / reviewer-integrator:** 本單元 `s1-fix` 依 AGENTS.md §3 完成 P25 增量。
- **Affected ends:** Swift `Sources/PhoneDSHBot/{Journal,Team,Rows,Wake}` 與 App `examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift`。Worker/Android/Kotlin/Rust 只消費 row 投影，不驗證 BotEvent envelope，不變。
- **Upstream reference:** dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6` 的 `events/envelope.cjs`；`agent.comm` 是 phoneDSH P27 的 additive UI event type，上游 envelope 檔案本身保持原樣導出。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| `event-envelope.schema.json` type enum | 新增 `agent.comm`；其他 62 個既有 type 不變。 |
| Swift `BotEventEnvelopeCodec.durableEventTypes` | 新增 `agent.comm`，與 schema enum 完全一致；不新增 error code。 |
| origin | 維持封閉集合。Bot 間訊息寫入已登記的 `local/comm-service`；不改 `localOriginSources`，不把宿主工具名 `team-tools` 加入契約。 |
| Fixtures | `event-envelope.phone.json` 以 append-only overlay 新增 2 個 valid（outbound/inbound）與 1 個 invalid（`team-tools` origin）向量；上游 `event-envelope.json` 及其 sha256 不變。 |

Self-check（`spec/README.md` §5.1）：沒有第二種 envelope、欄位別名或錯誤碼；`agent.comm` 與既有 row 投影共用同一 type；origin 集合仍 fail-closed；舊資料可直接解碼，未知 type 的舊 reader 仍按 P25 規則忽略。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 舊事件與舊 origin 全部照舊解碼；新增 type 只影響寫入端。 |
| new → old | 舊 reader 沒有 `agent.comm` 的 durable 分支時按未知 required type 拒絕整批事件，這是 P25 既有的 fail-closed 行為；不因此放寬 enum。舊 UI 的 row projector 對未知 type 不產生 row，rollback 後既有 `agent.comm` 事件留在 journal，不刪除。 |
| new → new | `agent.comm` 由 `SQLiteDomainStore` 指派 `commitSeq`；outbound/inbound 同一 thread 的 `correlationId` 相同；解碼與重放使用同一 codec。 |
| persisted old data → new／rollback | 沒有 schema 版本提升或遷移；event payload 形狀不變。 |

- 版本／adapter 決定：P25 envelope 的 additive enum 增量，不升 major、不新增 wire version。
- 不改 `team-tools` origin：契約列的是宿主子系統，`comm-service` 已承載 Bot 間訊息（`WakeInbox` 亦使用），語義匹配。

## 4. 驗證

- `python3 spec/bot/v1/tools/validate_vectors.py` → PASS（含新 phone overlay）。
- `python3 spec/tools/bot/check_golden.py` → PASS（30 files, 22 upstream, 8 overlays）。
- `swift test --disable-sandbox --filter PhoneDSHBotTests` → PASS（431 tests）。新增 `BotTeamCommPersistenceTests` 以真實 `SQLiteDomainStore` + `BotTeamTools` 寫入 outbound/inbound 並重新開啟解碼；`BotEventEnvelopeTests` 以 phone golden 驅動真實 codec。
- `scripts/ci/bot-e2e/harness` 的 `BotTeamCommProductionTests` 直接驅動 `BotRuntimeComposition.recordAgentComm` → PASS（1 test）。
- `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/catalog.json --only BOT-E08 --upstream mock` → gate PASS；`BOT-E08/bot-events.jsonl` 的 outbound `agent.comm` 為 `commitSeq=13`、`origin=local/comm-service`、`data.direction=outbound`，inbound 也為同一 origin。
- `CI_PROTOCOL_BASE=871488cfe bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS。
- App build：`xcodegen generate` 後以 `IDEPackageSupportDisableManifestSandbox=YES` + `OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` 建置 `PhoneDSHProbe` → `** BUILD SUCCEEDED **`。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| `agent-comm-v1` | `s1-fix` | `agent.comm` 已在 P27 定義但漏登記 P25 durable enum；同時修正生產 origin 寫入點。 | Swift、App；Worker/Android/Rust 無 consumer 變更 |
