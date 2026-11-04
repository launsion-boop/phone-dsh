# phoneDSH 協議標準化：GitHub 一手實踐調研

查閱日期：2026-11-03（Asia/Taipei）。僅讀公開來源；未對外提交 issue/PR。以下是從原始文件及 Git tree/blob 查證的實踐；phoneDSH 採用方式是本報告建議，不能視為 phoneDSH 已實作。

## 可證實的實踐與可採用範圍

| 來源 / 固定版本 | 已證實的做法 | 對 phoneDSH 的建議 | 不應照搬 |
| --- | --- | --- | --- |
| [MCP AGENTS.md](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/3c4d91b7e832d9b74338d56eed03403ccc662123/AGENTS.md) | 指定 TypeScript schema 是權威來源，JSON/schema reference 由命令生成；examples 按 schema type 分目錄並驗證；released 與 draft 分開。 | 每一個協議邊界指定唯一 owning source，其他語言型別、fixture、文件必須有同步方式和檢查。現有 Swift/TS 型別若沒有生成器，先登記兩端與測試，不新增一份未被 runtime 使用的「權威 schema」。 | 不必採用 MCP 的日期版本格式；不必為內部 bridge 換成 MCP、引入其 SDK 或整套生成工具。 |
| [MCP lifecycle（released 2025-11-25 樣本）](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/3c4d91b7e832d9b74338d56eed03403ccc662123/docs/specification/2025-11-25/basic/lifecycle.mdx) | 初始化協商版本與能力，正常操作只用協商成功的能力；所有請求有 timeout 建議；progress 可延時但仍需最大時限。 | 將握手、ready、操作、恢復、關閉寫成狀態轉移；明確指出哪些既有 bridge 有握手、哪些沒有。任何新增 negotiation 是有遷移成本的 runtime 變更，不能靠文件宣稱已存在。 | MCP 的 initialize/initialized、HTTP header、stdio shutdown 是它的協議語義，不能無條件加到現有 Worker wire format。 |
| [LSP 3.17 specification](https://github.com/microsoft/language-server-protocol/blob/112d978951f2223a962bf19516637862f587bf55/_specifications/lsp/3.17/specification.md) | 區分 request/response/notification；request 有對應 response，notification 無 response；取消後仍要結束請求；明確 result/error 互斥及標準錯誤類型。 | 每種訊息定義方向、correlation ID、成功/失敗、取消後終態；說清楚 progress/transport ACK/持久化 ACK/業務完成的差別。 | 不要把現有非 JSON-RPC envelope 在文件中重新命名成 JSON-RPC；不要照搬 LSP framing 與錯誤碼。 |
| [LSP initialize](https://github.com/microsoft/language-server-protocol/blob/112d978951f2223a962bf19516637862f587bf55/_specifications/lsp/3.17/general/initialize.md) | 初始化有訊息順序約束；未知 capability 忽略；缺失 optional capability 表示不支持。 | 相容性需按 boundary 逐一指定：未知 optional key、未知 message type/enum、缺少欄位/null、舊端新端矩陣；嚴格校驗必要欄位，安全相關未知能力不能默認批准。 | 「忽略未知 capability」不能擴張成任何未知內容都放行；更不能把 absence 當 true。 |
| [Protobuf 官方 best practices](https://github.com/protocolbuffers/protocolbuffers.github.io/blob/c4bd0dfa0cd755aedccdf001814a99017003c32a/content/best-practices/dos-donts.md) | 不假設 client/server 同步升級，需考慮 rollback；不重用已發布的欄位編號，不任意換欄位型別。 | 預設做 additive 變更；移除/重命名/型別/語義改動要有遷移計畫與舊資料 fixture，考慮已落盤與歷史 log。 | 不引入 protobuf 只是為了「有標準」。tag number 規則是 protobuf 的機制，JSON 需用自己的 key/enum 相容規則。 |
| [Protobuf proto3 guide](https://github.com/protocolbuffers/protocolbuffers.github.io/blob/c4bd0dfa0cd755aedccdf001814a99017003c32a/content/programming-guides/proto3.md) | 特別區分 wire-safe 與應用程式相容；新增 enum 在 wire 可讀，仍可能使 exhaustive switch 編譯或行為失效；ProtoJSON 安全性另有規則。 | 「新增 optional 欄位」也需證明接收端容忍；新增 enum 需測舊端 fallback。禁止僅因 TypeScript 編譯成功就宣稱 Swift/Kotlin/落盤相容。 | 不可從 protobuf 二進位相容直接推論 JSON bridge 相容。 |
| [Protobuf stale generated-code smoke tests](https://github.com/protocolbuffers/protobuf/blob/ab41516b5544f53090eadd8d8282994b0d4fb725/compatibility/smoke/README.md) | 保留舊版生成產物，對新 runtime 做相容 smoke 測試；正常構建偏向從 source 生成。 | 保留少量真實舊 payload/record 作 fixtures，在現有 TS/Swift 測試中解碼與往返，而不是只測新型別自己 encode/decode。 | 不需搬整個歷史版本矩陣或引入 Bazel；先覆蓋實際跨語言與落盤風險。 |
| [Zed .rules（AGENTS/CLAUDE 的共同來源）](https://github.com/zed-industries/zed/blob/504a7f2cf25b817cda3998cab93473adef15f93c/.rules) | 對新增規則要求非顯然、重複遇到、可採取行動；局部規則放局部；避免把容易過時的整體架構地圖塞進每次都讀的規則文件。 | 根 AGENTS/CLAUDE 只放強制入口、改協議步驟與交付證據；細節放協議 baseline。保留現有 runner，對觀察到的 drift 加小檢查。 | Zed 的 Rust/GPUI 特定規則、外部 repo 的提交政策、README 人工確認要求不適用 phoneDSH。 |

## 雙入口只維護一份規則：已查證的 Git 物件

- MCP commit `3c4d91b7e832d9b74338d56eed03403ccc662123`：[`CLAUDE.md`](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/3c4d91b7e832d9b74338d56eed03403ccc662123/CLAUDE.md) 的 tree mode 是 `120000`，blob `47dc3e3d863cfb5727b87d785d09abf9743c0a72` 內容是 `AGENTS.md`。
- Zed commit `504a7f2cf25b817cda3998cab93473adef15f93c`：[`AGENTS.md`](https://github.com/zed-industries/zed/blob/504a7f2cf25b817cda3998cab93473adef15f93c/AGENTS.md) 與 `CLAUDE.md` 的 mode 都是 `120000`，共同 blob `8a63b64bdb0afcda986ba715cb39849ac574e096` 內容是 `.rules`。
- 這證明兩者使用 symlink 共享規則，並不證明所有 agent 工具或 Windows checkout 都支持同一讀取方式。phoneDSH 現以 `AGENTS.md` 為主，`CLAUDE.md` 普通檔首行 `@AGENTS.md` import；若需要兩個普通檔，主規則仍只一份，檢查連結與引用不漂移。

## 建議的最小協議基線（本報告的推論）

1. **協議登記表**：每個跨模組/跨語言/落盤邊界有穩定 ID，列 producer、consumer、owning source、version/handshake、正常與失敗語義、可執行測試。保留事實與待修差距，不把提案登記為既成事實。
2. **變更先寫 delta**：agent 開始改協議前先列新增/移除/改語義，哪一端先上、舊端如何反應、落盤如何遷移、如何回滾；不涉及協議者直接標 `none`，避免把所有 PR 變成重流程。
3. **一個整合 owner 管共享契約**：平行 agent 先共用同一 base SHA 與協議 delta；由 owner 固定 contract revision，producer/consumer 各自實作；需要變動先回報新 delta，不私下新增 alias、第二種 envelope、不同錯誤分類。檔案所有權與 handoff 是任務協作紀律，並非上述外部 repo 直接證明的流程。
4. **同一組 fixtures 測兩端**：正常、缺必要欄位、未知 optional 欄位、未知 enum、重複/過期 ID、取消/timeout、舊持久化資料；測真實 decoder 和狀態機，避免只用正則檢查字串或測試自製 schema。
5. **沿用現有 CI runner**：從最有風險的一條 bridge 開始補 consumer/provider contract check；用小型離線 baseline check 檢查 registry 的 source/test 連結和版本，不新增 generic hook、通用 policy engine、強制 network 才能執行的 gate。
6. **交付說實話**：列 exact base/head、改過的 contract ID、相容結論、實跑命令與 `PASS/FAIL/NOT_RUN/BLOCKED`；機械 drift 檢查通過不能宣稱 E2E 或真機通過。

最低可接受交付是：權威入口文件 + 實際 source 對應的 baseline/registry + 一個現有執行路徑上的有效 drift/fixture 檢查。只有長篇規則文件，沒有 consumer/provider 證據，仍會讓 agent 各自解釋。

## 狀態與研究限制

- 這是官方 repo 與官方規格的源文件審閱，不是各方案在 phoneDSH 的性能或產品驗證。
- LSP 3.17 與 MCP 2025-11-25 是明確標記的已發布樣本；未宣稱它們是目前最新 protocol revision。
- GitHub connector 成功讀取 pinned 文件及 Git tree/blob。一次 `content/programming-guides/dos-donts.md` 定位 404，已從 tree 找到實際 `content/best-practices/dos-donts.md` 並完成閱讀。
- 尚未對 phoneDSH 實作進行本子任務的本地驗收，也未運行任何測試。

## 第二輪調研（2026-11-03，baseline revision 2）

本輪由子 agent 查閱公開一手來源；下列結論已用於修訂 [協議基線](../../spec/README.md) 與
[AGENTS.md](../../AGENTS.md)。引用的 commit 與 URL 由調研 agent 記錄，未逐條二次復核。

### 協議治理

| 來源 | 做法 | phoneDSH 採用 |
| --- | --- | --- |
| [Kubernetes API changes](https://github.com/kubernetes/community/blob/8ed8a77f/contributors/devel/sig-architecture/api_changes.md) | 新增欄位必須可選且有缺省；合法↔非法都不能翻轉；新增 enum 值不自動相容；同一特性不能同時用多個欄位表達 | 基線 §5.1 通用相容性規則 |
| [MCP SEP 指南](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/3c4d91b7/docs/community/sep-guidelines.mdx) | draft → accepted → final；作者不能自行改狀態；final 需 schema、規範與 conformance 測試 | 變更單 `draft → frozen → implemented → verified`；只有 contract owner 改 frozen 契約 |
| [MCP package.json](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/3c4d91b7/package.json) | 單一 schema.ts 生成 schema.json，CI 重新生成後逐字比對；examples 用 ajv 驗 schema | 基線 §9 路線圖：機器可讀登記表與生成／校驗 |
| buf 官方文檔的 breaking rules 頁、[oasdiff](https://github.com/oasdiff/oasdiff/blob/2daca9b2/docs/BREAKING-CHANGES.md) | 破壞性變更由 CI 對 base 比較；不穩定（alpha／draft）條目豁免；豁免需顯式標記 | §9 schema breaking diff；`draft`／`target` 條目狀態 |
| Kubernetes 倉庫 staging 下 api 模組的 testdata README（commit 915a1ba0）、[lsprotocol testdata](https://github.com/microsoft/lsprotocol/blob/24d45ab0/generator/plugins/testdata/testdata_generator.py) | 每版凍結 fixture，所有實作解同一批；正例必須成功、反例必須失敗 | §9 兩端讀同一批 golden，正反例命名 |
| [MCP conformance](https://github.com/modelcontextprotocol/conformance/blob/c37eec88/SDK_INTEGRATION.md) | 各 SDK 維護已知失敗 baseline；新失敗報錯，已知失敗轉通過也報錯 | 基線 §7 GAP 表的關閉規則 |
| [MCP CODEOWNERS](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/3c4d91b7/.github/CODEOWNERS)、[Envoy CODEOWNERS](https://github.com/envoyproxy/envoy/blob/4edefad7/CODEOWNERS) | `/schema/`、`/api/` 由固定 owner 群審 | §9 CODEOWNERS |

不採用：Kubernetes PRR 問卷、Rust 10 天 FCP、獨立 conformance 倉庫、Pact broker、全量四語言型別生成器（先從常量表與 enum 開始）。

### Agent 指令文件

| 來源 | 做法 | phoneDSH 採用 |
| --- | --- | --- |
| [openai/agents.md](https://github.com/openai/agents.md) | 最近的 AGENTS.md 優先，用戶對話指令優先於檔案 | AGENTS.md 開頭寫明優先順序 |
| Claude Code 官方文檔 memory 頁 | 建議 CLAUDE.md 用 `@AGENTS.md` import 再加 Claude 專屬內容；symlink 可用但在 Windows／未開 `core.symlinks` 時失效；單檔建議 200 行內 | 已改為普通檔首行 `@AGENTS.md` import；`cross_check.py` 強制同源入口，實際工具載入仍待驗證 |
| openai/codex、Kubernetes、MCP 的 AGENTS.md | 觸發條件寫成「改了路徑 X → 必須做 Y」；具體 NEVER 規則；分層驗證命令 | AGENTS.md §1 觸發表、§2 規則、§5 驗證；基線 §4 完整 glob |
| Claude Code 官方文檔 best practices 頁 | 每次都必須發生的事交給 hook／CI，指令檔只放指導 | 基線 §9：觸發檢查與 breaking diff 進 CI |
| CircleCI 部落格〈parallel coding agents〉（2026-10-30）、Claude Code 官方文檔 agent teams 頁 | 先凍結契約再並行；每個 agent 獨占檔案範圍；agent 不自行改契約 | AGENTS.md §3 contract freeze、獨占路徑、CONTRACT CHANGE REQUEST |

### 本地登記表核對

對 HEAD `d07bc3e6` 的只讀審計發現：revision 1 的連結全部存在，但 P01／P02 漏登 Rust codec 與 Kotlin
生產端，P03／P05 缺 Kotlin 端，P07／P09 沒有代碼路徑，P12 指錯權威（應為 `shell/include/xzshell.h`），
且有約十個跨語言邊界未登記（現登記為 P14–P22）。另發現 Rust golden 測試不在任何 CI gate 中、
`spec/exec-bridge-v1` 被引用但不存在。均已寫入基線 §3、§7。
