# 協議基線交付與驗證

日期：2026-11-03（Asia/Taipei）。Base：`fe33f75f46e970c051668027d85e9748b8f591ce`，
branch：`codex/protocol-baseline-20261103`。隔離工作樹建構，沒有覆蓋既有開發 checkout。

## 本輪完成

- [協議基線](../../spec/README.md)：13 類邊界、owning contract、producer／consumer、
  相容性、既有驗證矩陣、4 項仍開放的來源差異。
- [AGENTS](../../AGENTS.md) 是協作指令唯一來源；`CLAUDE.md` 是相對 symlink。
  根入口要求先定位契約、固定協作版本，再由各端實作及整合交接。
- [變更單](../protocol-change-template.md)、PR template、CONTRIBUTING／README 導航。
- 在既有 cross-tree reference invariant 內檢查 baseline／AGENTS 本地連結與規則同源；
  增加 8 個測試案例，不新增 CI stage 或通用 protocol framework。
- [研究](protocol-baseline-2026-11-03.md) 使用固定 commit 的 MCP、LSP、Protobuf、Zed
  一手來源，分開記錄外部實踐與本專案採用建議。

本輪沒有變更 runtime encoder／decoder、wire version、訊息格式、schema、golden payload
或恢復機制；屬協作規範與既有檢查的擴充，不是完成全面跨語言 interoperability。

## 實跑結果

| 驗證 | 結果與範圍 |
| --- | --- |
| 基線七階段檢查，改動前 | `phone-spec,phone-p0-conformance,phone-cross-tree,phone-no-dsh-patch,phone-hygiene,phone-license,phone-gate-contracts` 全部 PASS |
| 改動後同組七階段 | spec／P0／cross-tree／no-dsh-patch／license PASS；hygiene 及 gate-contracts 首輪 FAIL，原因為新研究的官方公開來源被 hostname scanner 誤判 |
| 修正後受影響階段 | `bash scripts/ci/check.sh --only phone-cross-tree,phone-hygiene,phone-gate-contracts` 全部 PASS；cross-tree 為 8/8 invariants，139/139 golden JSON 被既有 readers 覆蓋，43 項工具測試 PASS |
| TS runtime codec 既有測試 | 在 `plugins/` 執行 `node --experimental-strip-types --test channel/src/golden-frames.test.ts channel/src/host-hello.test.ts`：44 PASS、0 FAIL、0 SKIP，Node 22.22.1 |
| 工具回歸 | `python3 -m unittest discover -s spec/tools -p 'test_*.py' -v`：43 PASS，Python 3.14.7；新增案例包含失效來源連結、路徑逃逸、缺少入口、CLAUDE 複製漂移、合法 Markdown title／angle destination |
| Diff 與獨立審查 | `git diff --check` PASS；獨立 agent 完成來源／流程與 checker review，指出的來源節號、檔案定位、PR 連結及 Markdown 格式問題均已修正 |

首輪 FAIL 保留在原始日誌。處理方式：GitHub API blob 連結改為等價固定 commit 的檔案連結；
既有 hygiene allowlist 新增精確匹配 `protocolbuffers.github.io`，理由是官方公開文件的
GitHub repository 名稱被當作 hostname。scanner 未放寬，憑證／私人路徑檢查保留。
最終七個選定階段均有 PASS 證據；這不是全量 CI PASS 的聲明。

## 未驗證與後續

- Swift SDK 全量、Android／Rust、完整 npm typecheck／test、Worker image／bundle、
  WKWebView smoke、真機、模型 E2E、掉電與外部副作用驗收：本輪 `NOT_RUN`。
- GAP-01 unified bridge 遷移、GAP-02 HELLO 數值域、GAP-03 水位條件、GAP-04 capability
  校驗差異仍為 OPEN。TS 既有測試通過不會自動關閉這些來源審查發現。
- symlink 在本次 macOS checkout 已核對；Windows checkout／各 agent 工具載入行為
  `NOT_VERIFIED`。這些工具若不保留 symlink，需明確處理入口機制，不得複製出第二份規則。
- 沒有 push、開 PR、合併 main 或部署；交付為可審查的本地分支。
