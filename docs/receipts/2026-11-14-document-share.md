# 2026-11-14 文档预览分享入口

<!-- SPDX-License-Identifier: MIT -->

- `BotDocumentPreview`（文档卡打开后的 sheet）新增导航栏分享按钮 `bot.document.share`：
  - 内嵌 `content`：分享 `title + 正文`；
  - 仅 `path`：分享解析后的文件 URL；
  - sandbox 无关，仍受 `PreviewPathResolver` 的工作区解析约束。
- 通用文件预览 `BotFilePreviewSheet`/`PreviewSurface` 原有分享入口保持不变；这次补齐的是内嵌文档卡这条没有走 PreviewSurface 的路径。
- 回归：Bot UI capture 的 `testDocumentAndSafeLinkActions` 增加 share 按钮存在断言，capture **TEST SUCCEEDED**。
