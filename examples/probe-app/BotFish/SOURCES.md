<!-- SPDX-License-Identifier: MIT -->

# 大肥鱼分层素材来源

来源仓库：`launsion-boop/dsh-bot`
固定提交：`bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`
源目录：`src/renderer/public/assets/fish/`

用户已明确授权在 phoneDSH iOS 中使用大肥鱼形象素材。本目录供原生分层渲染器
（移植自上游 `src/renderer/lib/fish/` 的 Canvas2D 绘制逻辑）使用，文件均未修改：

- `base/{body,fixed,face-mask,eyes-open,eyes-white,iris-left,iris-right,blush}.png`：
  经典长卷发（`long`）、无皇冠形象的 512×512 RGBA 图层；`body.png` 为灰度，运行时按颜色 LUT 着色。
- `expressive/eyes.png`、`expressive/mouths.png`：768×512 表情 sprite（3×4，单元 256×128）；
  `expressive/atlas.json` 为单元名称索引。
- `atlas.json`：上游各状态周期等参数索引。

其他发型、皇冠、预渲染表情与动画帧未复制。本目录需在 `project.yml` 中以
`type: folder` 资源方式打包，保留子目录结构，避免与 `PhoneDSHProbe/` 下同名文件冲突。
