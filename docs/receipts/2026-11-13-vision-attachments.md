# 2026-11-13 图片进入模型上下文回执（R7 / R8 第一切片）

<!-- SPDX-License-Identifier: MIT -->

Base: `a2bb79dfe`（PR #159 合并后）
Branch: `feat/vision-model-attachments`
Protocol impact: **P19**（`session/prompt.content` image part）、**P26**（additive `attach_to_model`）；**P18: none**.

## 1. 已实现

### R7 用户附件图片

- `Sources/PhoneDSHBot/Attachments/BotModelImage.swift`：ImageIO 解码/方向/缩放（长边 1568px）/JPEG 质量阶梯，编码上限 1 MiB；prompt 与 MCP 两种 JSON 形状分开。
- `BotDSHRemoteRuntime.sendUserMessage`：通过注入的 `attachmentImagePreparer` 最多准备 2 张图片，追加到 `session/prompt` 的 `content`；文本附件块保留；准备失败的附件只丢图片 part。
- App `BotWorkspaceModelImage`：从 materialized workspace 读取附件，交给同一个编码器；`BotRuntimeUnit` 注入。
- Bot 输入框：带图片发送前弹「仅这一次 / 本会话都允许 / 取消」；取消保留草稿与附件，不产生上传。

### R8 工具产物图片

- `attach_to_model`（P26 additive；不在 P0 名单）：`path`、`fileId` 或 `photoId` 三选一 + `purpose`。
- 返回 MCP `image` content block；DSH MCP client 负责 canonical base64、模型 `inputModalities` 检查和 durable admission。
- `BotToolEffects` / Worker `approval-gate`：`model.image.attach`、`external-send`、`ask`；Task 会话直接拒绝。
- 每回合最多 2 张工具图片；`fileId` 走 `OfficeArtifactStore`（camera 产物），`photoId` 走 Photos 本地 asset（`isNetworkAccessAllowed=false`，不拉 iCloud），`path` 走 materialized workspace（用户附件/文档）。

## 2. 验证

| 命令 | 结果 |
| --- | --- |
| `swift test --filter BotModelImageTests` | **PASS** 4（3000×2000 → ≤1568、≤1 MiB、JPEG magic、非图片/空输入 fail-closed） |
| `swift test --filter BotModelImageToolTests` | **PASS** 4（catalog/effect、无 reader fail-closed、image content block、path/fileId/purpose 校验） |
| `swift test --filter PhoneDSHBotTests` | **758–760 / 760** — 多数运行全过；偶发 `approval-pending-expired`（50ms 合同夹具）计时失败，与本 diff 无关，单独重跑仍复现，属既有时间敏感用例 |
| `xcodebuild build -scheme PhoneDSH`（iPhone 17 Pro 模拟器） | **PASS** |
| `npm run typecheck`（plugins） | **PASS** |
| `node --test tests/bot-model-image-approval.test.ts` | **PASS** 2（Worker 审批分类/资源） |
| `BotGoldenVectorTests` / `BotCardPayloadTests` / `BotTeamToolsTests` / `BotMCPRPCCasesTests` | **PASS**（tool-effects 28、allDefinitions +1、RPC tools/list +1 已更新） |
| Bot UI capture：24 个 XCUITest（含 `testImageAttachmentSendAsksBeforeModelEgress`） | **PASS** — `** TEST SUCCEEDED **`，0 failures；旧一次因 capture target 不链接 ProbeKit 构建失败，已用 `canImport(ProbeKit)` 条件修复 |

## 3. 未验证 / 风险

- **真机端到端**：**NOT_VERIFIED**。本机模拟器没有可用的 vision 模型 route；MCP client 的 `inputModalities` 检查、真实模型看图、camera `fileId` 的 `OfficeArtifactStore` 读取均需真机。
- **Prompt image part**：依赖 DSH `SessionPromptRequest` 的 image 分支；未在真机 Worker 上跑通一次真实请求。
- **PDF OCR**：未实现；`attach_to_model` 对 PDF 返回 `image_unavailable`，不会假装 OCR。
- **photos.recent/search**：工具返回的是 PHAsset `id`；`attach_to_model(photoId:)` 现在按 localIdentifier 本地导出（不拉 iCloud），真机相册权限/资产可用性未验证。
- 用户主动选图按“明确动作 + 二次确认对话框”处理；工具产出的图片走审批卡。若产品要求每次图片都单独审批（包括“本会话都允许”也不允许），只需删掉 composer 的 session 选项。
