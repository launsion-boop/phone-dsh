<!-- SPDX-License-Identifier: MIT -->

# 大肥鱼分层素材来源

来源仓库：`launsion-boop/dsh-bot`
固定提交：`bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`
源目录：`src/renderer/public/assets/fish/`

用户已明确授权在 phoneDSH iOS 中使用大肥鱼形象素材。2026-11-12 起，权利人（素材作者，即上游 `launsion-boop/dsh-bot` 的所有者）将授权扩展到 phoneDSH 全部平台：iOS App、Android（`:lib` AAR 与 App APK）、HarmonyOS，以及截图/测试工程；随 phoneDSH 以 MIT 许可再分发，见仓库根 `NOTICE`。各平台只读取本目录（构建期复制或打包），不得另存手改副本。本目录供原生分层渲染器
（移植自上游 `src/renderer/lib/fish/` 的 Canvas2D 绘制逻辑）使用，文件均未修改：

- `base/{body,fixed,face-mask,eyes-open,eyes-white,iris-left,iris-right,blush}.png`：
  经典长卷发（`long`）、无皇冠形象的 512×512 RGBA 图层；`body.png` 为灰度，运行时按颜色 LUT 着色。
- `hair/{twin-tail,bob,side-braid}/{body,fixed,face-mask}.png`：另外 3 种发型的同尺寸
  RGBA 图层；`long` 继续使用 `base/`，因此 4 种发型共用同一套眼睛、虹膜、腮红和表情 sprite。
- `expressive/eyes.png`、`expressive/mouths.png`：768×512 表情 sprite（3×4，单元 256×128）；
  `expressive/atlas.json` 为单元名称索引。
- `atlas.json`：上游各状态周期等参数索引。

皇冠与 crowned 图层由多 Bot 单元追加复制（见下文「主 Bot 皇冠图层」）；预渲染表情
与动画帧未复制。本目录需在 `project.yml` 中以
`type: folder` 资源方式打包，保留子目录结构，避免与 `PhoneDSHProbe/` 下同名文件冲突。

## 原生打包与加载

- `examples/probe-app/project.yml` 以 `type: folder` / `buildPhase: resources`
  打包本目录，App 内路径保持 `BotFish/...`。
- `BotFishAssets` 通过 `Bundle.main.url(forResource:withExtension:subdirectory: "BotFish/base")`
  （表情 sprite 用 `"BotFish/expressive"`，其余发型用 `"BotFish/hair/<style>"`，
  带皇冠的 Bot 用 `"BotFish/crowned/long"` / `"BotFish/crowned/<style>"`）加载；
  缺失时回退 `BotAvatar`。每种（发型, crowned）首次访问时懒加载 body/fixed/face-mask
  并缓存；`crown.png` / `crown-crystal.png` 也只在首次冠冕渲染时解码，进程内共享。
- `body.png` 是灰度图，运行时按 `BotFishAppearance.color` 的 hex 构建 LUT 着色；
  着色结果按（发型, crowned, 颜色, 显示尺寸档位）缓存并进程内共享，多个头像/画廊实例不会
  逐帧重复着色。`BotFishView` 的 `appearance` 默认 `.classic`（blue + long），
  `crowned` 默认 false；变化时立即重绘。
- 渲染器按 SwiftUI `displayScale` 把圆形裁切区栅格化到 `size × scale`
  的复用位图/上下文，不再先画 512×512 再缩放；普通头像裁切 416px
  `{x:48,y:30}`，crowned 头像按上游改为 448px `{x:32,y:10}`，皇冠在 flat
  层内、头部变换之后绘制，随后与头部一起参与 8px 切片位移。`BotFish/`
  原始 512 源空间坐标保持不变。
- `BotFishView` 读取 `EnvironmentValues.botFishPaused`（默认 false）；为 true
  时暂停时间线并保留最后一帧。Bot 页在非 Bot tab 上设置它。
- 截图工程 `scripts/ci/bot-ui/capture.sh` 同样把本目录作为 folder 资源打包，
  生成全部状态的静态画廊（`gallery`，顶部含 crowned 行：idle/thinking/
  working/happy 96pt 与 32pt、20pt 各一格）、thinking/working/speaking/
  alerting/celebrate 的 3 帧动态连拍（`dynamic`，间隔约 150ms），以及
  15 色 × 4 发型 idle 静帧的外观网格（`appearanceGrid`，40pt）。

## 发型图层（第 3 轮追加）

- `hair/{twin-tail,bob,side-braid}/{body,fixed,face-mask}.png`：原样复制自上游
  `src/renderer/public/assets/fish/base/hair-v3/<style>/`（同一固定提交 bf4075b）。
  `long` 继续使用 `base/` 下的同名图层；眼睛、虹膜、腮红、表情 sprite 所有发型共用。

## 主 Bot 皇冠图层（多 Bot，追加）

- `crowned/long/{body,fixed,face-mask}.png`：原样复制自上游 `base/crowned/long/`。
- `crowned/{twin-tail,bob,side-braid}/{body,fixed,face-mask}.png`：原样复制自上游 `base/crowned-v3/<style>/`。
- `overlays/crown.png`、`overlays/crown-crystal.png`：原样复制自上游 `overlays/`。
同一固定提交 bf4075b。与上游一致，主 Bot（`primary`）使用 crowned 图层并叠加皇冠，
眼睛、虹膜、腮红与表情 sprite 仍共用 `base/` / `expressive/`。crowned 图层只在
`crowned == true` 时加载；`overlays` 皇冠在首次冠冕渲染时懒加载并全局共享。皇冠
盒/基线按上游显示尺寸档位取 250/138（≤40pt）、244/134（≤64pt）、240/132，默认
gold，`crown-crystal.png` 保留给后续 crownStyle 接入。
