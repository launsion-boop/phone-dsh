# 2026-11-13 工具/相册图片进入模型上下文回执（R7/R8 调整版）

<!-- SPDX-License-Identifier: MIT -->

Base: `a2bb79dfe`（PR #159 合并后）
Branch: `feat/vision-model-attachments`
Protocol impact: **P26**（additive `attach_to_model`）；**P19: none**（用户附图不注入 prompt image part）；**P18: none**.

## 1. 方向调整

按真机使用反馈，用户不需要在输入框附图：**Agent 自己读相册**，需要把图片送给 LLM 时调用一次 `attach_to_model`，走一次审批。用户附件仍按原来的文本/路径块提交，不自动带图。

## 2. 已实现

- `BotModelImage` / `BotModelImagePreparer`：ImageIO 解码/方向/缩放（长边 1568px）/JPEG 质量阶梯，编码上限 1 MiB；MCP 图片块形状单独生成。
- `attach_to_model`（P26 additive；不在 P0 名单）：
  - `path`（materialized workspace）、`fileId`（`OfficeArtifactStore`，camera）、`photoId`（Photos localIdentifier）三选一；
  - `page` 可选（1–8），PDF 用 PDFKit 栅格化该页；
  - 返回 MCP `image` content block，DSH MCP client 检查当前模型 `inputModalities` 并 admit；
  - 每回合最多 2 张；Task 会话拒绝。
- 审批：Host `BotToolEffects` 与 Worker `approval-gate` 都分类为 `model.image.attach / external-send / ask`；Worker 资源的 path/fileId/photoId 与 Host 一致，避免 `stale:always_scope`。DSH 内置的 `read_image` 也在 Worker gate 中被分类并拦截——否则工作区图片可以绕过审批直接进模型；该拦截只作用于 Bot session，普通 DSH 工作台保持原行为。
- Photos 导出：`isNetworkAccessAllowed=false`，不在后台拉 iCloud；缺失/不可用返回 `image_unavailable`。
- 用户附件仍只提交原有文本/路径块；模型需要像素时对附件路径调用 DSH 内置 `read_image`，或调用 `attach_to_model(path:)`。两者都经过同一张审批卡；`read_image` 的 identity registration 也已加入允许名单，否则审批会因 `unattributed` 失败。

## 3. 验证

| 命令 | 结果 |
| --- | --- |
| `swift test --filter BotModelImageTests` | **PASS** 4（缩放/1 MiB/JPEG/非图片） |
| `swift test --filter BotModelImageToolTests` | **PASS** 7（catalog/effect、read_image identity、无审批 grant 拒绝、无 reader、image block、path/fileId/photoId/purpose/page） |
| `swift test --filter "BotGoldenVectorTests|BotMCPRPCCasesTests|BotCardPayloadTests|BotTeamToolsTests"` | **PASS** 48（tool-effects 28、allDefinitions +1、tools/list +1） |
| `xcodebuild build -scheme PhoneDSH`（iPhone 17 Pro 模拟器） | **PASS**（移除用户附图 prompt 路径后重新构建） |
| `npm run typecheck`（plugins） | **PASS** |
| `node --test tests/bot-model-image-approval.test.ts` | **PASS** 4（含 read_image 与 Worker/Host golden） |
| Bot UI capture（22 个 XCUITest） | **PASS** — `** TEST SUCCEEDED **`，61 张 fixture 截图；本版移除了用户附图同意对话框测试 |
| `python3 spec/bot/v1/tools/validate_vectors.py` / `phone-cross-tree` / `phone-bundle-fresh` | **PASS**（重建 bundle 后） |

## 4. 未验证 / 风险

- **真机端到端**：**NOT_VERIFIED**。模拟器没有可用的 vision 模型 route；`inputModalities` 检查、真实模型看图、camera `fileId`、Photos localIdentifier、PDF 页面栅格化均需真机。
- **PDF OCR**：未做 OCR 文本；当前按页栅格化给 vision 模型，文本型 PDF 也走图像。若模型不支持 vision，MCP client 会返回文字 diagnostic。
- **审批粒度**：一次工具调用一次审批；每回合最多两张。若“本会话都允许”被用户选择，之后的调用沿用现有 grant 规则。
- 全量 `PhoneDSHBotTests` 偶发既有 `approval-pending-expired`（50ms 合同夹具）计时失败；本 diff 相关测试稳定通过。
