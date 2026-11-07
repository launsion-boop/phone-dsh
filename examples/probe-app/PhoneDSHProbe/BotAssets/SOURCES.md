<!-- SPDX-License-Identifier: MIT -->

# 大肥鱼资产来源

来源仓库：`launsion-boop/dsh-bot`
固定提交：`bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`
源目录：`src/renderer/public/assets/fish/`

用户已明确授权在 phoneDSH iOS 中使用大肥鱼形象素材及 FishDirector 语义。

- `manifest.json`：上游原版，未修改。
- `expressions/*.png`：上游 512×512 RGBA 合成图，未修改。
- `BotFishDirector.swift`：依据上游 `src/renderer/lib/fish/director.js` 的确定性状态机在 Swift 中重写，不执行 JavaScript 或 Canvas。
- `spec/bot/v1/golden/fish-director.json`：由固定提交的真实 FishDirector 导出，用于 Swift 对拍。

这里只包含当前 P0 生命周期和事件映射需要的资源；其他上游发型、分层与动画文件未复制。素材是 Image Gen 与程序分层衍生结果，不宣称为独立手绘。
