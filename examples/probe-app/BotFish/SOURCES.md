<!-- SPDX-License-Identifier: MIT -->

# 大肥鱼分层素材来源

来源仓库：`launsion-boop/dsh-bot`
固定提交：`bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`
源目录：`src/renderer/public/assets/fish/`

用户已明确授权在 phoneDSH iOS 中使用大肥鱼形象素材。本目录供原生分层渲染器
（移植自上游 `src/renderer/lib/fish/` 的 Canvas2D 绘制逻辑）使用，文件均未修改：

- `base/{body,fixed,face-mask,eyes-open,eyes-white,iris-left,iris-right,blush}.png`：
  经典长卷发（`long`）、无皇冠形象的 512×512 RGBA 图层；`body.png` 为灰度，运行时按颜色 LUT 着色。
- `hair/{twin-tail,bob,side-braid}/{body,fixed,face-mask}.png`：另外 3 种发型的同尺寸
  RGBA 图层；`long` 继续使用 `base/`，因此 4 种发型共用同一套眼睛、虹膜、腮红和表情 sprite。
- `expressive/eyes.png`、`expressive/mouths.png`：768×512 表情 sprite（3×4，单元 256×128）；
  `expressive/atlas.json` 为单元名称索引。
- `atlas.json`：上游各状态周期等参数索引。

皇冠、预渲染表情与动画帧未复制。本目录需在 `project.yml` 中以
`type: folder` 资源方式打包，保留子目录结构，避免与 `PhoneDSHProbe/` 下同名文件冲突。

## 原生打包与加载

- `examples/probe-app/project.yml` 以 `type: folder` / `buildPhase: resources`
  打包本目录，App 内路径保持 `BotFish/...`。
- `BotFishAssets` 通过 `Bundle.main.url(forResource:withExtension:subdirectory: "BotFish/base")`
  （表情 sprite 用 `"BotFish/expressive"`，其余发型用 `"BotFish/hair/<style>"`）加载；
  缺失时回退 `BotAvatar`。每种发型首次访问时懒加载 body/fixed/face-mask 并缓存。
- `body.png` 是灰度图，运行时按 `BotFishAppearance.color` 的 hex 构建 LUT 着色；
  着色结果按（发型, 颜色, 显示尺寸档位）缓存并进程内共享，多个头像/画廊实例不会
  逐帧重复着色。`BotFishView` 的 `appearance` 默认 `.classic`（blue + long），
  变化时立即重绘。
- 渲染器按 SwiftUI `displayScale` 把 416px 圆形裁切区栅格化到 `size × scale`
  的复用位图/上下文，不再先画 512×512 再缩放；`BotFish/` 原始 512 源空间
  坐标保持不变。
- `BotFishView` 读取 `EnvironmentValues.botFishPaused`（默认 false）；为 true
  时暂停时间线并保留最后一帧。Bot 页在非 Bot tab 上设置它。
- 截图工程 `scripts/ci/bot-ui/capture.sh` 同样把本目录作为 folder 资源打包，
  生成全部状态的静态画廊（`gallery`）、thinking/working/speaking/alerting/
  celebrate 的 3 帧动态连拍（`dynamic`，间隔约 150ms），以及 15 色 × 4 发型
  idle 静帧的外观网格（`appearanceGrid`，40pt）。

## 发型图层（第 3 轮追加）

- `hair/{twin-tail,bob,side-braid}/{body,fixed,face-mask}.png`：原样复制自上游
  `src/renderer/public/assets/fish/base/hair-v3/<style>/`（同一固定提交 bf4075b）。
  `long` 继续使用 `base/` 下的同名图层；眼睛、虹膜、腮红、表情 sprite 所有发型共用。
